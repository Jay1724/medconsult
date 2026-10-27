-- ============================================================
-- Printed copies: a patient asks for a document to be printed for them at the practice.
-- Health documents stay in the app; nothing is emailed. Run after patient_access.sql. Safe to re-run.
--
-- Flow: patient requests -> doctor opens and prints it -> doctor or receptionist marks it ready
-- -> receptionist marks it collected. Receptionists see only the type, date and reference of a
-- document, never its clinical content.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.print_requests (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id  uuid NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
  doctor_id   uuid NOT NULL REFERENCES public.doctors(id),
  kind        text NOT NULL CHECK (kind IN ('sick_note', 'prescription', 'record')),
  doc_id      uuid NOT NULL,
  status      text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested', 'ready', 'collected', 'cancelled')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS print_requests_open_uq ON public.print_requests (patient_id, kind, doc_id)
  WHERE status IN ('requested', 'ready');
CREATE INDEX IF NOT EXISTS print_requests_doctor_idx ON public.print_requests (doctor_id, status);
ALTER TABLE public.print_requests ENABLE ROW LEVEL SECURITY;   -- no policies: all access goes through the functions below

-- Patient asks for a printed copy of one of their own documents.
CREATE OR REPLACE FUNCTION public.request_print(p_kind text, p_doc uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid := public.my_patient_id(); did uuid; r print_requests;
BEGIN
  IF auth.uid() IS NULL OR pid IS NULL THEN RAISE EXCEPTION 'Please sign in to your patient profile'; END IF;
  IF p_kind = 'sick_note' THEN SELECT doctor_id INTO did FROM sick_notes WHERE id = p_doc AND patient_id = pid;
  ELSIF p_kind = 'prescription' THEN SELECT doctor_id INTO did FROM prescriptions WHERE id = p_doc AND patient_id = pid;
  ELSIF p_kind = 'record' THEN SELECT doctor_id INTO did FROM records WHERE id = p_doc AND patient_id = pid;
  ELSE RAISE EXCEPTION 'Unknown document type'; END IF;
  IF did IS NULL THEN RAISE EXCEPTION 'Document not found'; END IF;

  SELECT * INTO r FROM print_requests
   WHERE patient_id = pid AND kind = p_kind AND doc_id = p_doc AND status IN ('requested', 'ready');
  IF NOT FOUND THEN
    IF (SELECT count(*) FROM print_requests WHERE patient_id = pid AND status IN ('requested', 'ready')) >= 20 THEN
      RAISE EXCEPTION 'You have too many open print requests. Collect or cancel some first.';
    END IF;
    INSERT INTO print_requests (patient_id, doctor_id, kind, doc_id) VALUES (pid, did, p_kind, p_doc) RETURNING * INTO r;
  END IF;
  RETURN jsonb_build_object('id', r.id, 'status', r.status);
END $$;

-- The patient's own requests, newest first.
CREATE OR REPLACE FUNCTION public.list_my_print_requests()
RETURNS TABLE (id uuid, kind text, doc_id uuid, status text, created_at timestamptz, dr_name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT pr.id, pr.kind, pr.doc_id, pr.status, pr.created_at, d.first_name || ' ' || d.last_name
  FROM print_requests pr JOIN doctors d ON d.id = pr.doctor_id
  WHERE pr.patient_id = public.my_patient_id()
  ORDER BY pr.created_at DESC LIMIT 100
$$;

CREATE OR REPLACE FUNCTION public.cancel_print_request(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE print_requests SET status = 'cancelled', updated_at = now()
   WHERE id = p_id AND patient_id = public.my_patient_id() AND status = 'requested';
  IF NOT FOUND THEN RAISE EXCEPTION 'That request can no longer be cancelled'; END IF;
END $$;

-- Staff queue: requests for doctors the caller is, or works for. Shows type, date and reference only.
CREATE OR REPLACE FUNCTION public.list_print_requests()
RETURNS TABLE (id uuid, patient_name text, kind text, doc_id uuid, doc_ref text, doc_date date, status text,
               created_at timestamptz, dr_name text, dr_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT pr.id, p.first_name || ' ' || p.last_name, pr.kind, pr.doc_id,
         CASE pr.kind WHEN 'sick_note' THEN sn.ref_number WHEN 'prescription' THEN rx.ref_number END,
         CASE pr.kind WHEN 'sick_note' THEN sn.issue_date WHEN 'prescription' THEN rx.script_date ELSE rc.visit_date END,
         pr.status, pr.created_at, d.first_name || ' ' || d.last_name, pr.doctor_id
  FROM print_requests pr
  JOIN patients p ON p.id = pr.patient_id
  JOIN doctors d ON d.id = pr.doctor_id
  LEFT JOIN sick_notes sn ON pr.kind = 'sick_note' AND sn.id = pr.doc_id
  LEFT JOIN prescriptions rx ON pr.kind = 'prescription' AND rx.id = pr.doc_id
  LEFT JOIN records rc ON pr.kind = 'record' AND rc.id = pr.doc_id
  WHERE public.can_manage_doctor(pr.doctor_id)
    AND (pr.status IN ('requested', 'ready') OR pr.updated_at > now() - interval '7 days')
  ORDER BY (pr.status IN ('requested', 'ready')) DESC, pr.created_at DESC LIMIT 200
$$;

-- requested -> ready (doctor has printed it) -> collected. Either staff role may move it along.
CREATE OR REPLACE FUNCTION public.mark_print_request(p_id uuid, p_status text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r print_requests;
BEGIN
  IF p_status NOT IN ('ready', 'collected', 'cancelled') THEN RAISE EXCEPTION 'Unknown status'; END IF;
  SELECT * INTO r FROM print_requests WHERE id = p_id;
  IF NOT FOUND OR NOT public.can_manage_doctor(r.doctor_id) THEN RAISE EXCEPTION 'Request not found'; END IF;
  IF r.status IN ('collected', 'cancelled') THEN RAISE EXCEPTION 'This request is already closed'; END IF;
  IF p_status = 'collected' AND r.status <> 'ready' THEN RAISE EXCEPTION 'Mark it ready before it is collected'; END IF;
  UPDATE print_requests SET status = p_status, updated_at = now() WHERE id = p_id;
END $$;

-- Only signed-in users may call these.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['request_print(text,uuid)', 'list_my_print_requests()', 'cancel_print_request(uuid)',
                           'list_print_requests()', 'mark_print_request(uuid,text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;
