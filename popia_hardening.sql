-- ============================================================
-- POPIA hardening, batch 1. Run after print_requests.sql. Safe to re-run.
--
--  1. Removes the open "Anyone can create a practice" insert policy (practices are created by functions).
--  2. Pins the search path on four older functions.
--  3. Access log: every create / change / delete of a patient's clinical data is recorded by the
--     database itself, and doctors' views of a file are recorded too.
--  4. Patients can see who accessed their record (POPIA: transparency and the right to access).
--
-- Honest limit: writes are logged by database triggers and cannot be skipped. Views are reported
-- by the app (log_view), so a doctor who reads the API directly without the app would not appear.
-- Moving clinical reads behind functions would close that gap later.
-- ============================================================

DROP POLICY IF EXISTS "Anyone can create a practice" ON public.practices;

ALTER FUNCTION public.get_next_ref(uuid, text, text)   SET search_path = public;
ALTER FUNCTION public.get_available_slots(uuid, date)  SET search_path = public;
ALTER FUNCTION public.seed_default_availability(uuid)  SET search_path = public;
ALTER FUNCTION public.set_updated_at()                 SET search_path = public;

CREATE TABLE IF NOT EXISTS public.access_log (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at            timestamptz NOT NULL DEFAULT now(),
  actor_auth    uuid,
  actor_doctor  uuid,
  patient_id    uuid NOT NULL,      -- deliberately no foreign key: the log outlives an erased profile
  action        text NOT NULL CHECK (action IN ('view', 'create', 'update', 'delete')),
  subject       text NOT NULL CHECK (subject IN ('patient', 'record', 'sick_note', 'prescription')),
  subject_id    uuid
);
CREATE INDEX IF NOT EXISTS access_log_patient_idx ON public.access_log (patient_id, at DESC);
ALTER TABLE public.access_log ENABLE ROW LEVEL SECURITY;      -- no policies: nobody reads or edits it directly
REVOKE ALL ON public.access_log FROM anon, authenticated;

-- Trigger: the database records every change, whatever app or tool made it.
CREATE OR REPLACE FUNCTION public.log_clinical_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid; sid uuid; act text := CASE TG_OP WHEN 'INSERT' THEN 'create' WHEN 'UPDATE' THEN 'update' ELSE 'delete' END;
BEGIN
  IF TG_OP = 'DELETE' THEN sid := OLD.id; ELSE sid := NEW.id; END IF;
  IF TG_ARGV[0] = 'patient' THEN pid := sid;
  ELSIF TG_OP = 'DELETE' THEN pid := OLD.patient_id;
  ELSE pid := NEW.patient_id; END IF;
  INSERT INTO access_log (actor_auth, actor_doctor, patient_id, action, subject, subject_id)
  VALUES (auth.uid(), public.my_doctor_id(), pid, act, TG_ARGV[0], sid);
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.log_clinical_change() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS log_records ON public.records;
CREATE TRIGGER log_records AFTER INSERT OR UPDATE OR DELETE ON public.records FOR EACH ROW EXECUTE FUNCTION public.log_clinical_change('record');
DROP TRIGGER IF EXISTS log_sick_notes ON public.sick_notes;
CREATE TRIGGER log_sick_notes AFTER INSERT OR UPDATE OR DELETE ON public.sick_notes FOR EACH ROW EXECUTE FUNCTION public.log_clinical_change('sick_note');
DROP TRIGGER IF EXISTS log_prescriptions ON public.prescriptions;
CREATE TRIGGER log_prescriptions AFTER INSERT OR UPDATE OR DELETE ON public.prescriptions FOR EACH ROW EXECUTE FUNCTION public.log_clinical_change('prescription');
DROP TRIGGER IF EXISTS log_patients ON public.patients;
CREATE TRIGGER log_patients AFTER UPDATE OR DELETE ON public.patients FOR EACH ROW EXECUTE FUNCTION public.log_clinical_change('patient');

-- The doctor's app calls this when a patient's file is opened. Only doctors who may read the file can log it,
-- and repeat opens within 10 minutes count once.
CREATE OR REPLACE FUNCTION public.log_view(p_patient uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d uuid := public.my_doctor_id();
BEGIN
  IF auth.uid() IS NULL OR d IS NULL OR NOT public.has_patient_access(p_patient) THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM access_log WHERE patient_id = p_patient AND actor_doctor = d AND action = 'view'
             AND at > now() - interval '10 minutes') THEN RETURN; END IF;
  INSERT INTO access_log (actor_auth, actor_doctor, patient_id, action, subject, subject_id)
  VALUES (auth.uid(), d, p_patient, 'view', 'patient', p_patient);
END $$;

-- What a patient sees: who looked at or changed their record, newest first.
CREATE OR REPLACE FUNCTION public.list_my_access_log()
RETURNS TABLE (at timestamptz, action text, subject text, dr_name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT l.at, l.action, l.subject, d.first_name || ' ' || d.last_name
  FROM access_log l LEFT JOIN doctors d ON d.id = l.actor_doctor
  WHERE l.patient_id = public.my_patient_id()
  ORDER BY l.at DESC LIMIT 200
$$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['log_view(uuid)', 'list_my_access_log()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;
