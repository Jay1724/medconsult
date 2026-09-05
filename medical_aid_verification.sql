-- ─────────────────────────────────────────────────────────────────────────────
-- MedConsult — Medical Aid Verification columns
-- Run once in the Supabase SQL editor (Dashboard → SQL Editor).
--
-- Adds verification tracking to the patients table used by reception.html:
--   medical_aid_status        'unverified' | 'verified' | 'invalid'
--                             (NULL = no medical aid captured / self-pay)
--   medical_aid_checked_at    when the status was last set
--   medical_aid_checked_by    who set it (staff name or email)
--   medical_aid_check_method  'manual' (phoned scheme / provider portal)
--                             | 'api' (check-medical-aid edge function)
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE patients
  ADD COLUMN IF NOT EXISTS medical_aid_status text
    CHECK (medical_aid_status IN ('unverified','verified','invalid')),
  ADD COLUMN IF NOT EXISTS medical_aid_checked_at timestamptz,
  ADD COLUMN IF NOT EXISTS medical_aid_checked_by text,
  ADD COLUMN IF NOT EXISTS medical_aid_check_method text
    CHECK (medical_aid_check_method IN ('manual','api'));

-- Existing patients that already have a medical aid start as 'unverified'.
UPDATE patients
SET medical_aid_status = 'unverified'
WHERE medical_aid_provider IS NOT NULL
  AND medical_aid_status IS NULL;
