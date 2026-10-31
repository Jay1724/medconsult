-- MedConsult — clinical data only through logged functions (POPIA s19 safeguards)
-- Run AFTER popia_hardening.sql and staff_mfa.sql. Safe to re-run.
--
-- Before: a doctor's browser could read the records / sick_notes / prescriptions tables directly, and the
-- "who looked" log depended on the app remembering to report it.
-- After:  doctors have no direct table access to clinical rows. They call the functions below, and every
--         function checks (1) signed in with the second factor, (2) a clinician, not front desk,
--         (3) the patient approved them (or they created the patient), then writes the access log itself.
-- Patients keep reading their own rows directly (their own data; not logged).

-- A clinician is an owner/doctor of a practice, or a solo doctor with no practice membership.
CREATE OR REPLACE FUNCTION public.is_clinician() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.my_doctor_id() IS NOT NULL AND (
    NOT EXISTS (SELECT 1 FROM practice_members pm WHERE pm.doctor_id = public.my_doctor_id())
    OR EXISTS (SELECT 1 FROM practice_members pm
               WHERE pm.doctor_id = public.my_doctor_id() AND pm.role IN ('owner', 'doctor')
                 AND coalesce(pm.status, 'active') NOT IN ('suspended', 'removed', 'pending'))
  )
$$;

-- One gate used by every function below.
CREATE OR REPLACE FUNCTION public.assert_clinical_access(p_patient uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in first'; END IF;
  IF NOT public.mfa_ok() THEN RAISE EXCEPTION 'Enter your two-factor code to continue'; END IF;
  IF NOT public.is_clinician() THEN RAISE EXCEPTION 'Only doctors can open clinical records'; END IF;
  IF p_patient IS NULL OR NOT public.has_patient_access(p_patient) THEN
    RAISE EXCEPTION 'You do not have this patient''s permission to view their record';
  END IF;
  RETURN public.my_doctor_id();
END $$;

-- Logs one view; repeats of the same thing within 10 minutes count once.
CREATE OR REPLACE FUNCTION public.log_clinical_view(p_patient uuid, p_subject text, p_subject_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d uuid := public.my_doctor_id();
BEGIN
  IF EXISTS (SELECT 1 FROM access_log WHERE patient_id = p_patient AND actor_doctor = d AND action = 'view'
             AND subject = p_subject AND subject_id IS NOT DISTINCT FROM p_subject_id
             AND at > now() - interval '10 minutes') THEN RETURN; END IF;
  INSERT INTO access_log (actor_auth, actor_doctor, patient_id, action, subject, subject_id)
  VALUES (auth.uid(), d, p_patient, 'view', p_subject, p_subject_id);
END $$;

-- The whole clinical file of one patient: consultation records, sick notes, prescriptions.
CREATE OR REPLACE FUNCTION public.get_patient_file(p_patient uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d uuid := public.assert_clinical_access(p_patient); out jsonb;
BEGIN
  PERFORM public.log_clinical_view(p_patient, 'patient', p_patient);
  SELECT jsonb_build_object(
    'records',       coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.visit_date DESC, r.created_at DESC) FROM records r WHERE r.patient_id = p_patient), '[]'::jsonb),
    'sick_notes',    coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.issue_date DESC, s.created_at DESC) FROM sick_notes s WHERE s.patient_id = p_patient), '[]'::jsonb),
    'prescriptions', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.script_date DESC, x.created_at DESC) FROM prescriptions x WHERE x.patient_id = p_patient), '[]'::jsonb)
  ) INTO out;
  RETURN out;
END $$;

-- One document, e.g. to print or view full screen. kind: record | sick_note | prescription
CREATE OR REPLACE FUNCTION public.get_document(p_kind text, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid; row_ jsonb;
BEGIN
  IF p_kind = 'record' THEN SELECT patient_id, to_jsonb(t) INTO pid, row_ FROM records t WHERE t.id = p_id;
  ELSIF p_kind = 'sick_note' THEN SELECT patient_id, to_jsonb(t) INTO pid, row_ FROM sick_notes t WHERE t.id = p_id;
  ELSIF p_kind = 'prescription' THEN SELECT patient_id, to_jsonb(t) INTO pid, row_ FROM prescriptions t WHERE t.id = p_id;
  ELSE RAISE EXCEPTION 'Unknown document type'; END IF;
  IF row_ IS NULL THEN RAISE EXCEPTION 'Document not found'; END IF;
  PERFORM public.assert_clinical_access(pid);
  PERFORM public.log_clinical_view(pid, p_kind, p_id);
  RETURN row_;
END $$;

-- The doctor's issue list. No diagnosis or medicines here: reference, patient and dates only.
CREATE OR REPLACE FUNCTION public.list_my_documents(p_kind text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE d uuid := public.my_doctor_id();
BEGIN
  IF auth.uid() IS NULL OR NOT public.mfa_ok() OR NOT public.is_clinician() THEN RETURN '[]'::jsonb; END IF;
  IF p_kind = 'sick_note' THEN
    RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', id, 'patient_id', patient_id, 'ref_number', ref_number,
             'issue_date', issue_date, 'rest_from', rest_from, 'rest_to', rest_to) ORDER BY issue_date DESC, created_at DESC)
             FROM sick_notes WHERE doctor_id = d AND public.has_patient_access(patient_id)), '[]'::jsonb);
  ELSIF p_kind = 'prescription' THEN
    RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', id, 'patient_id', patient_id, 'ref_number', ref_number,
             'script_date', script_date) ORDER BY script_date DESC, created_at DESC)
             FROM prescriptions WHERE doctor_id = d AND public.has_patient_access(patient_id)), '[]'::jsonb);
  END IF;
  RAISE EXCEPTION 'Unknown document type';
END $$;

-- Writing. Reference numbers are made here so two browsers can never clash.
CREATE OR REPLACE FUNCTION public.next_ref(p_prefix text, p_floor int) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n int;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('ref:' || p_prefix));
  IF p_prefix = 'SN' THEN
    SELECT coalesce(max(nullif(regexp_replace(ref_number, '\D', '', 'g'), '')::int), 0) INTO n FROM sick_notes;
  ELSE
    SELECT coalesce(max(nullif(regexp_replace(ref_number, '\D', '', 'g'), '')::int), 0) INTO n FROM prescriptions;
  END IF;
  RETURN p_prefix || '-' || (greatest(n, p_floor) + 1);
END $$;

CREATE OR REPLACE FUNCTION public.create_record(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid := (p ->> 'patient_id')::uuid; d uuid := public.assert_clinical_access((p ->> 'patient_id')::uuid); r records%ROWTYPE;
BEGIN
  IF nullif(btrim(p ->> 'diagnosis'), '') IS NULL OR (p ->> 'visit_date') IS NULL THEN RAISE EXCEPTION 'Visit date and diagnosis are required'; END IF;
  INSERT INTO records (doctor_id, patient_id, visit_date, visit_type, diagnosis, icd10, vitals, notes, medication, follow_up, referral)
  VALUES (d, pid, (p ->> 'visit_date')::date, coalesce(nullif(p ->> 'visit_type', ''), 'In-Person'), p ->> 'diagnosis',
          nullif(p ->> 'icd10', ''), nullif(p ->> 'vitals', ''), nullif(p ->> 'notes', ''), nullif(p ->> 'medication', ''),
          nullif(p ->> 'follow_up', '')::date, nullif(p ->> 'referral', ''))
  RETURNING * INTO r;
  RETURN to_jsonb(r);
END $$;

CREATE OR REPLACE FUNCTION public.create_sick_note(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid := (p ->> 'patient_id')::uuid; d uuid := public.assert_clinical_access((p ->> 'patient_id')::uuid); r sick_notes%ROWTYPE;
BEGIN
  IF nullif(btrim(p ->> 'diagnosis'), '') IS NULL OR (p ->> 'issue_date') IS NULL THEN RAISE EXCEPTION 'Issue date and diagnosis are required'; END IF;
  INSERT INTO sick_notes (doctor_id, patient_id, ref_number, issue_date, rest_from, rest_to, diagnosis, icd10, instructions, sig_image)
  VALUES (d, pid, public.next_ref('SN', 2400), (p ->> 'issue_date')::date, nullif(p ->> 'rest_from', '')::date, nullif(p ->> 'rest_to', '')::date,
          p ->> 'diagnosis', nullif(p ->> 'icd10', ''), nullif(p ->> 'instructions', ''), nullif(p ->> 'sig_image', ''))
  RETURNING * INTO r;
  RETURN to_jsonb(r);
END $$;

CREATE OR REPLACE FUNCTION public.create_prescription(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid := (p ->> 'patient_id')::uuid; d uuid := public.assert_clinical_access((p ->> 'patient_id')::uuid); r prescriptions%ROWTYPE;
BEGIN
  IF (p ->> 'script_date') IS NULL THEN RAISE EXCEPTION 'Date is required'; END IF;
  INSERT INTO prescriptions (doctor_id, patient_id, ref_number, script_date, diagnosis, repeats, medications, sig_image)
  VALUES (d, pid, public.next_ref('RX', 3300), (p ->> 'script_date')::date, nullif(p ->> 'diagnosis', ''),
          coalesce(nullif(p ->> 'repeats', ''), '0'), coalesce(p -> 'medications', '[]'::jsonb), nullif(p ->> 'sig_image', ''))
  RETURNING * INTO r;
  RETURN to_jsonb(r);
END $$;

-- ── Lock the doors: doctors no longer touch the clinical tables directly ───────
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['records', 'prescriptions', 'sick_notes'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Doctor reads own ' || t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Doctor reads ' || t || ' of patients with access', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Doctor writes own ' || t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Doctor edits own ' || t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Doctor deletes own ' || t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Doctor sees own ' || replace(t, '_', ' '), t);
  END LOOP;
END $$;

-- Execute rights: signed-in users only. Gate helpers are internal.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['is_clinician()', 'assert_clinical_access(uuid)', 'log_clinical_view(uuid,text,uuid)', 'next_ref(text,int)',
    'get_patient_file(uuid)', 'get_document(text,uuid)', 'list_my_documents(text)',
    'create_record(jsonb)', 'create_sick_note(jsonb)', 'create_prescription(jsonb)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['get_patient_file(uuid)', 'get_document(text,uuid)', 'list_my_documents(text)',
    'create_record(jsonb)', 'create_sick_note(jsonb)', 'create_prescription(jsonb)'] LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;
