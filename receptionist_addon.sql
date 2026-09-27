-- ─────────────────────────────────────────────────────────────────────────────
-- MedConsult — Receptionist add-on for solo Professional doctors
-- Run once in the Supabase SQL editor (Dashboard → SQL Editor).
--
-- When a Professional doctor adds a receptionist (R 149/month each), doctor.html
-- creates a private one-doctor practice for them:
--   practices          plan = 'solo'
--   doctors            practice_id set to that practice
--   practice_members   the doctor as 'owner'; each receptionist as 'receptionist'
--   practice_invites   role = 'receptionist', accepted via reception.html?invite=…
--
-- The only schema change is allowing 'solo' in practices.plan, if that column
-- has a CHECK constraint. The existing RLS policies for practice owners (the
-- same ones practice.html relies on) cover the reads and writes above.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.practices'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%plan%'
  LOOP
    EXECUTE format('ALTER TABLE public.practices DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;

ALTER TABLE practices
  ADD CONSTRAINT practices_plan_check
  CHECK (plan IS NULL OR plan IN ('solo','practice'));

-- Billing: receptionist seats for a solo practice
--   SELECT p.id, p.name, count(m.*) AS receptionists, 599 + 149 * count(m.*) AS monthly_zar
--   FROM practices p
--   LEFT JOIN practice_members m ON m.practice_id = p.id AND m.role = 'receptionist'
--   WHERE p.plan = 'solo'
--   GROUP BY p.id, p.name;
