-- ─────────────────────────────────────────────────────────────────────────────
-- MedConsult — Phase 1 Claims Migration
-- Run in Supabase SQL Editor (Dashboard → SQL Editor).
-- ─────────────────────────────────────────────────────────────────────────────


-- ── Add practice number to doctors ───────────────────────────────────────────
ALTER TABLE doctors ADD COLUMN IF NOT EXISTS practice_number text;


-- ── Claims (one per appointment / billing event) ──────────────────────────────
CREATE TABLE IF NOT EXISTS claims (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  appointment_id uuid        REFERENCES appointments(id) ON DELETE SET NULL,
  patient_id     uuid        NOT NULL REFERENCES patients(id) ON DELETE RESTRICT,
  doctor_id      uuid        REFERENCES doctors(id) ON DELETE SET NULL,
  icd10          text,
  status         text        NOT NULL DEFAULT 'draft'
                             CHECK (status IN ('draft','ready','submitted','paid','queried','rejected')),
  total_cents    int         NOT NULL DEFAULT 0,
  notes          text,
  switch_ref     text,                        -- Healthbridge / clearinghouse ref (Phase 2)
  paid_cents     int,                         -- amount actually paid by scheme (Phase 2)
  rejection_reason text,                      -- scheme rejection reason (Phase 2)
  created_at     timestamptz DEFAULT now(),
  updated_at     timestamptz DEFAULT now()
);

-- ── Claim line items (NHRPL tariff codes, NAPPI codes for meds) ────────────────
CREATE TABLE IF NOT EXISTS claim_lines (
  id           uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id     uuid  NOT NULL REFERENCES claims(id) ON DELETE CASCADE,
  tariff_code  text  NOT NULL,
  description  text,
  quantity     int   NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_cents   int   NOT NULL DEFAULT 0 CHECK (unit_cents >= 0),
  nappi_code   text,                          -- medication billing code (Phase 2)
  modifier     text,                          -- e.g. after-hours, multiple procedures (Phase 2)
  created_at   timestamptz DEFAULT now()
);

-- ── Indexes ───────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS claims_patient_idx    ON claims(patient_id);
CREATE INDEX IF NOT EXISTS claims_appt_idx       ON claims(appointment_id);
CREATE INDEX IF NOT EXISTS claims_status_idx     ON claims(status);
CREATE INDEX IF NOT EXISTS claim_lines_claim_idx ON claim_lines(claim_id);

-- ── Auto-update updated_at ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS claims_updated_at ON claims;
CREATE TRIGGER claims_updated_at
  BEFORE UPDATE ON claims
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ── Verify ────────────────────────────────────────────────────────────────────
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'claims' ORDER BY ordinal_position;

SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'claim_lines' ORDER BY ordinal_position;
