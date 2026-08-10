-- ── Add profile_status to patients ───────────────────────────────────────────
-- Run this in the Supabase SQL editor (Dashboard → SQL Editor).
-- Safe to re-run — uses IF NOT EXISTS guards.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE patients
  ADD COLUMN IF NOT EXISTS profile_status TEXT
    DEFAULT 'incomplete'
    CHECK (profile_status IN ('incomplete', 'pending_review', 'verified'));

-- Back-fill: patients who already have phone + address are considered verified.
UPDATE patients
SET profile_status = 'verified'
WHERE profile_status = 'incomplete'
  AND ph IS NOT NULL AND ph <> ''
  AND addr IS NOT NULL AND addr <> '';

-- ── Done ─────────────────────────────────────────────────────────────────────
-- After running this migration:
--   • New patients who complete the onboarding flow will have profile_status = 'pending_review'
--   • Doctors can mark them as 'verified' in the Doctor Portal → Patients tab
