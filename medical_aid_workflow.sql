-- ─────────────────────────────────────────────────────────────────────────────
-- MedConsult — Medical aid verification workflow
-- Run once in the Supabase SQL editor (Dashboard → SQL Editor), after
-- medical_aid_verification.sql.
--
-- Adds:
--   patients.medical_aid_dependant_code   two-digit dependant code (00 = main member)
--   patients.medical_aid_check_ref        call / portal reference for the last check
--   patients.medical_aid_card_path        membership card photo in storage
--   medical_aid_check_method              now also 'phone' | 'portal' | 'card'
--   medical_aid_checks                    history of every check (who, how, when)
--   practice_scheme_contacts              each practice's saved scheme phone
--                                         numbers / provider portal links
--   storage bucket medical-aid-cards      private; files under <practice_id>/…
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Patient columns ─────────────────────────────────────────────────────────
ALTER TABLE patients
  ADD COLUMN IF NOT EXISTS medical_aid_dependant_code text
    CHECK (medical_aid_dependant_code ~ '^\d{2}$'),
  ADD COLUMN IF NOT EXISTS medical_aid_check_ref text,
  ADD COLUMN IF NOT EXISTS medical_aid_card_path text;

-- Allow the new check methods (replaces the 'manual' | 'api' constraint).
DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.patients'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%medical_aid_check_method%'
  LOOP
    EXECUTE format('ALTER TABLE public.patients DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;

ALTER TABLE patients
  ADD CONSTRAINT patients_medical_aid_check_method_check
  CHECK (medical_aid_check_method IN ('manual','api','phone','portal','card'));

-- ── Check history ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS medical_aid_checks (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id  uuid NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
  status      text NOT NULL CHECK (status IN ('verified','invalid','unverified')),
  method      text NOT NULL CHECK (method IN ('manual','api','phone','portal','card')),
  reference   text,
  message     text,
  checked_by  text,
  checked_by_auth uuid DEFAULT auth.uid(),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS medical_aid_checks_patient_idx ON medical_aid_checks (patient_id, created_at DESC);

ALTER TABLE medical_aid_checks ENABLE ROW LEVEL SECURITY;

-- Staff can read and add checks for any patient they can already see
-- (the subquery runs under the caller's own RLS on patients).
DROP POLICY IF EXISTS medical_aid_checks_select ON medical_aid_checks;
CREATE POLICY medical_aid_checks_select ON medical_aid_checks FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM patients p WHERE p.id = medical_aid_checks.patient_id));

DROP POLICY IF EXISTS medical_aid_checks_insert ON medical_aid_checks;
CREATE POLICY medical_aid_checks_insert ON medical_aid_checks FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM patients p WHERE p.id = medical_aid_checks.patient_id));

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
  USING (EXISTS (SELECT 1 FROM practice_members m
                 WHERE m.practice_id = practice_scheme_contacts.practice_id
                   AND m.auth_id = auth.uid() AND m.status = 'active'))
  WITH CHECK (EXISTS (SELECT 1 FROM practice_members m
                 WHERE m.practice_id = practice_scheme_contacts.practice_id
                   AND m.auth_id = auth.uid() AND m.status = 'active'));

-- ── Membership card photos ──────────────────────────────────────────────────
-- Private bucket; objects live at <practice_id>/<patient_id>/<timestamp>.<ext>
INSERT INTO storage.buckets (id, name, public)
VALUES ('medical-aid-cards', 'medical-aid-cards', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS medical_aid_cards_rw ON storage.objects;
CREATE POLICY medical_aid_cards_rw ON storage.objects FOR ALL TO authenticated
  USING (bucket_id = 'medical-aid-cards' AND (storage.foldername(name))[1] IN (
           SELECT m.practice_id::text FROM practice_members m
           WHERE m.auth_id = auth.uid() AND m.status = 'active'))
  WITH CHECK (bucket_id = 'medical-aid-cards' AND (storage.foldername(name))[1] IN (
           SELECT m.practice_id::text FROM practice_members m
           WHERE m.auth_id = auth.uid() AND m.status = 'active'));
