-- ─────────────────────────────────────────────────────────────────────────────
-- MedConsult — Medical aid verification workflow (run AFTER practice_access.sql)
-- Run in the Supabase SQL editor. Safe to run more than once.
--
-- Adds to patients (alongside aid_provider / aid_number / aid_plan / principal):
--   aid_status          unverified | verified | invalid  (NULL = self-pay)
--   aid_checked_at      when it was last checked
--   aid_checked_by      who checked (staff name)
--   aid_check_method    phone | portal | card | api | manual
--   aid_check_ref       call / portal reference
--   aid_dependant_code  two digits, 00 = main member
--   aid_card_path       membership card photo in storage
-- Plus:
--   medical_aid_checks        history of every check
--   practice_scheme_contacts  saved per practice: scheme phone / portal links
--   storage bucket medical-aid-cards  (private, files under <practice_id>/…)
--   record_medical_aid_check() / update_patient_medical_aid()
--     — reception can only read patients under RLS, so these functions make
--       the medical aid changes (and nothing else) after checking access.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Patient columns ─────────────────────────────────────────────────────────
ALTER TABLE patients
  ADD COLUMN IF NOT EXISTS aid_status text,
  ADD COLUMN IF NOT EXISTS aid_checked_at timestamptz,
  ADD COLUMN IF NOT EXISTS aid_checked_by text,
  ADD COLUMN IF NOT EXISTS aid_check_method text,
  ADD COLUMN IF NOT EXISTS aid_check_ref text,
  ADD COLUMN IF NOT EXISTS aid_dependant_code text,
  ADD COLUMN IF NOT EXISTS aid_card_path text;

ALTER TABLE patients DROP CONSTRAINT IF EXISTS patients_aid_status_check;
ALTER TABLE patients ADD CONSTRAINT patients_aid_status_check
  CHECK (aid_status IN ('unverified', 'verified', 'invalid'));
ALTER TABLE patients DROP CONSTRAINT IF EXISTS patients_aid_check_method_check;
ALTER TABLE patients ADD CONSTRAINT patients_aid_check_method_check
  CHECK (aid_check_method IN ('manual', 'api', 'phone', 'portal', 'card'));
ALTER TABLE patients DROP CONSTRAINT IF EXISTS patients_aid_dependant_code_check;
ALTER TABLE patients ADD CONSTRAINT patients_aid_dependant_code_check
  CHECK (aid_dependant_code ~ '^\d{2}$');

-- Patients already on medical aid start as unverified.
UPDATE patients SET aid_status = 'unverified'
WHERE nullif(trim(aid_provider), '') IS NOT NULL AND aid_status IS NULL;

-- ── Check history ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS medical_aid_checks (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id  uuid NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
  status      text NOT NULL CHECK (status IN ('verified', 'invalid', 'unverified')),
  method      text NOT NULL CHECK (method IN ('manual', 'api', 'phone', 'portal', 'card')),
  reference   text,
  message     text,
  checked_by  text,
  checked_by_auth uuid DEFAULT auth.uid(),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS medical_aid_checks_patient_idx ON medical_aid_checks (patient_id, created_at DESC);

ALTER TABLE medical_aid_checks ENABLE ROW LEVEL SECURITY;
-- Read-only from the browser; rows are written by record_medical_aid_check().
DROP POLICY IF EXISTS medical_aid_checks_select ON medical_aid_checks;
DROP POLICY IF EXISTS medical_aid_checks_insert ON medical_aid_checks;
CREATE POLICY medical_aid_checks_select ON medical_aid_checks FOR SELECT TO authenticated
  USING (public.can_access_patient(patient_id));

-- ── Practice scheme contacts ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS practice_scheme_contacts (
  practice_id uuid NOT NULL REFERENCES practices(id) ON DELETE CASCADE,
  scheme      text NOT NULL,
  phone       text,
  portal_url  text,
  notes       text,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (practice_id, scheme)
);

ALTER TABLE practice_scheme_contacts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS practice_scheme_contacts_rw ON practice_scheme_contacts;
CREATE POLICY practice_scheme_contacts_rw ON practice_scheme_contacts FOR ALL TO authenticated
  USING (practice_id IN (SELECT public.my_practice_ids()))
  WITH CHECK (practice_id IN (SELECT public.my_practice_ids()));

-- ── Membership card photos ──────────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('medical-aid-cards', 'medical-aid-cards', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS medical_aid_cards_rw ON storage.objects;
CREATE POLICY medical_aid_cards_rw ON storage.objects FOR ALL TO authenticated
  USING (bucket_id = 'medical-aid-cards'
         AND (storage.foldername(name))[1] IN (SELECT public.my_practice_ids()::text))
  WITH CHECK (bucket_id = 'medical-aid-cards'
         AND (storage.foldername(name))[1] IN (SELECT public.my_practice_ids()::text));

-- ── Functions ───────────────────────────────────────────────────────────────
-- Name recorded as "checked by" for the signed-in user.
CREATE OR REPLACE FUNCTION public.my_display_name() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(
    (SELECT coalesce(nullif(trim(coalesce(first_name,'') || ' ' || coalesce(last_name,'')), ''), name, email)
       FROM doctors WHERE auth_id = auth.uid() ORDER BY created_at LIMIT 1),
    (SELECT email FROM auth.users WHERE id = auth.uid()))
$$;

-- Record a verification result and add it to the history.
CREATE OR REPLACE FUNCTION public.record_medical_aid_check( p_patient uuid, p_status text, p_method text, p_reference text DEFAULT NULL, p_message text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  who text := public.my_display_name();
  row_out patients%ROWTYPE;
BEGIN
  IF NOT public.can_access_patient(p_patient) THEN
    RAISE EXCEPTION 'You do not have access to this patient';
  END IF;
  UPDATE patients SET
    aid_status = p_status, aid_check_method = p_method,
    aid_check_ref = nullif(trim(p_reference), ''),
    aid_checked_at = now(), aid_checked_by = who
  WHERE id = p_patient
  RETURNING * INTO row_out;
  INSERT INTO medical_aid_checks (patient_id, status, method, reference, message, checked_by)
  VALUES (p_patient, p_status, p_method, nullif(trim(p_reference), ''), p_message, who);
  RETURN jsonb_build_object(
    'aid_status', row_out.aid_status, 'aid_check_method', row_out.aid_check_method,
    'aid_check_ref', row_out.aid_check_ref, 'aid_checked_at', row_out.aid_checked_at,
    'aid_checked_by', row_out.aid_checked_by);
END $$;

-- Correct medical aid details. Only these keys are accepted:
--   aid_number, aid_dependant_code, id_number, principal, aid_card_path
-- Changing the member number or dependant code resets the status to unverified.
CREATE OR REPLACE FUNCTION public.update_patient_medical_aid(p_patient uuid, p_changes jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  cur patients%ROWTYPE;
  bad text;
  reset_status boolean := false;
BEGIN
  IF NOT public.can_access_patient(p_patient) THEN
    RAISE EXCEPTION 'You do not have access to this patient';
  END IF;
  SELECT k INTO bad FROM jsonb_object_keys(p_changes) k
  WHERE k NOT IN ('aid_number', 'aid_dependant_code', 'id_number', 'principal', 'aid_card_path') LIMIT 1;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Field % cannot be changed here', bad; END IF;

  SELECT * INTO cur FROM patients WHERE id = p_patient FOR UPDATE;
  reset_status := (p_changes ? 'aid_number' AND nullif(p_changes->>'aid_number','') IS DISTINCT FROM cur.aid_number)
               OR (p_changes ? 'aid_dependant_code' AND nullif(p_changes->>'aid_dependant_code','') IS DISTINCT FROM cur.aid_dependant_code);

  UPDATE patients SET
    aid_number         = CASE WHEN p_changes ? 'aid_number'         THEN nullif(p_changes->>'aid_number', '')         ELSE aid_number END,
    aid_dependant_code = CASE WHEN p_changes ? 'aid_dependant_code' THEN nullif(p_changes->>'aid_dependant_code', '') ELSE aid_dependant_code END,
    id_number          = CASE WHEN p_changes ? 'id_number'          THEN nullif(p_changes->>'id_number', '')          ELSE id_number END,
    principal          = CASE WHEN p_changes ? 'principal'          THEN nullif(p_changes->>'principal', '')          ELSE principal END,
    aid_card_path      = CASE WHEN p_changes ? 'aid_card_path'      THEN nullif(p_changes->>'aid_card_path', '')      ELSE aid_card_path END,
    aid_status         = CASE WHEN reset_status AND aid_provider IS NOT NULL THEN 'unverified' ELSE aid_status END
  WHERE id = p_patient
  RETURNING * INTO cur;

  RETURN jsonb_build_object(
    'aid_number', cur.aid_number, 'aid_dependant_code', cur.aid_dependant_code,
    'id_number', cur.id_number, 'principal', cur.principal,
    'aid_card_path', cur.aid_card_path, 'aid_status', cur.aid_status);
END $$;

GRANT EXECUTE ON FUNCTION public.my_display_name(), public.record_medical_aid_check(uuid, text, text, text, text),
  public.update_patient_medical_aid(uuid, jsonb) TO authenticated;
