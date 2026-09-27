-- ─────────────────────────────────────────────────────────────────────────────
-- MedConsult — Practice access (run FIRST, then medical_aid_workflow.sql)
-- Run in the Supabase SQL editor. Safe to run more than once.
--
-- Why: staff are linked as  auth user → doctors.auth_id → practice_members.doctor_id.
-- The existing practice_members / practices policies look up practice_members
-- from inside a practice_members policy, which Postgres rejects with
--   "infinite recursion detected in policy for relation practice_members"
-- — and because the receptionist policies on patients / appointments read
-- practice_members, that error also breaks patient and appointment queries.
--
-- This script:
--   1. adds SECURITY DEFINER helper functions (they read practice_members
--      without triggering its policies, so no recursion)
--   2. replaces the recursive policies with equivalents that use the helpers
--   3. adds the missing policies: reception reads practice doctors, registers
--      patients; owners manage invites
--   4. adds functions for steps the browser can't do under RLS: reading an
--      invite by token, accepting it, and creating a practice
--   5. allows practices.plan = 'solo' (Professional doctor + receptionist add-on)
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Helpers ──────────────────────────────────────────────────────────────
-- Signed-in user's doctors row (receptionists have one too).
CREATE OR REPLACE FUNCTION public.my_doctor_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM doctors WHERE auth_id = auth.uid() ORDER BY created_at LIMIT 1
$$;

-- Practices the signed-in user is an active member of (optionally with a role).
CREATE OR REPLACE FUNCTION public.my_practice_ids(p_roles text[] DEFAULT NULL) RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT pm.practice_id
  FROM practice_members pm JOIN doctors d ON d.id = pm.doctor_id
  WHERE d.auth_id = auth.uid()
    AND coalesce(pm.status, 'active') NOT IN ('suspended', 'removed', 'pending')
    AND (p_roles IS NULL OR pm.role = ANY (p_roles))
$$;

-- doctors.id of everyone in those practices (optionally only some roles).
CREATE OR REPLACE FUNCTION public.my_practice_member_doctor_ids(p_my_roles text[] DEFAULT NULL, p_their_roles text[] DEFAULT NULL) RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT pm.doctor_id FROM practice_members pm
  WHERE pm.practice_id IN (SELECT public.my_practice_ids(p_my_roles))
    AND (p_their_roles IS NULL OR pm.role = ANY (p_their_roles))
$$;

-- Can the signed-in user work with this patient? (their own doctor, or front
-- desk / owner in the practice of the patient's doctor)
CREATE OR REPLACE FUNCTION public.can_access_patient(p_patient uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM patients p
    WHERE p.id = p_patient
      AND (p.doctor_id = public.my_doctor_id()
           OR p.doctor_id IN (SELECT public.my_practice_member_doctor_ids(ARRAY['owner','admin','receptionist','nurse'])))
  )
$$;

GRANT EXECUTE ON FUNCTION public.my_doctor_id(), public.my_practice_ids(text[]),
  public.my_practice_member_doctor_ids(text[], text[]), public.can_access_patient(uuid) TO authenticated;

-- ── 2. Replace recursive policies ───────────────────────────────────────────
DROP POLICY IF EXISTS "Members see their practice members" ON practice_members;
CREATE POLICY "Members see their practice members" ON practice_members FOR SELECT TO authenticated
  USING (practice_id IN (SELECT public.my_practice_ids()));

DROP POLICY IF EXISTS "Owner manages practice members" ON practice_members;
CREATE POLICY "Owner manages practice members" ON practice_members FOR ALL TO authenticated
  USING (practice_id IN (SELECT public.my_practice_ids(ARRAY['owner'])))
  WITH CHECK (practice_id IN (SELECT public.my_practice_ids(ARRAY['owner'])));

DROP POLICY IF EXISTS "Practice members see their practice" ON practices;
CREATE POLICY "Practice members see their practice" ON practices FOR SELECT TO authenticated
  USING (id IN (SELECT public.my_practice_ids()));

DROP POLICY IF EXISTS "Practice owner can update practice" ON practices;
CREATE POLICY "Practice owner can update practice" ON practices FOR UPDATE TO authenticated
  USING (id IN (SELECT public.my_practice_ids(ARRAY['owner'])));

DROP POLICY IF EXISTS "Receptionist sees practice appointments" ON appointments;
CREATE POLICY "Receptionist sees practice appointments" ON appointments FOR ALL TO authenticated
  USING (doctor_id IN (SELECT public.my_practice_member_doctor_ids(ARRAY['receptionist','owner','admin'])))
  WITH CHECK (doctor_id IN (SELECT public.my_practice_member_doctor_ids(ARRAY['receptionist','owner','admin'])));

DROP POLICY IF EXISTS "Receptionist sees practice patients demographics" ON patients;
CREATE POLICY "Receptionist sees practice patients demographics" ON patients FOR SELECT TO authenticated
  USING (doctor_id IN (SELECT public.my_practice_member_doctor_ids(ARRAY['receptionist','owner','admin','nurse'])));

-- ── 3. Missing policies ─────────────────────────────────────────────────────
-- Staff can see the doctor profiles of people in their practice (names for
-- the calendar, doctor list, booking).
DROP POLICY IF EXISTS "Practice members see colleagues" ON doctors;
CREATE POLICY "Practice members see colleagues" ON doctors FOR SELECT TO authenticated
  USING (id IN (SELECT public.my_practice_member_doctor_ids()));

-- Front desk can register a patient for a doctor or owner in their practice.
DROP POLICY IF EXISTS "Reception registers practice patients" ON patients;
CREATE POLICY "Reception registers practice patients" ON patients FOR INSERT TO authenticated
  WITH CHECK (doctor_id IN (SELECT public.my_practice_member_doctor_ids(ARRAY['receptionist','owner','admin'], ARRAY['owner','doctor'])));

-- Invites: owners / admins manage their practice's invites. Reading one by
-- token (before sign-up) goes through get_practice_invite() below.
ALTER TABLE practice_invites ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Owner manages practice invites" ON practice_invites;
CREATE POLICY "Owner manages practice invites" ON practice_invites FOR ALL TO authenticated
  USING (practice_id IN (SELECT public.my_practice_ids(ARRAY['owner','admin'])))
  WITH CHECK (practice_id IN (SELECT public.my_practice_ids(ARRAY['owner','admin'])));

-- ── 4. Functions for steps RLS can't allow from the browser ─────────────────
-- Invite details for the sign-up screen (only pending, unexpired invites).
CREATE OR REPLACE FUNCTION public.get_practice_invite(p_token text)
RETURNS TABLE (email text, role text, practice_id uuid, practice_name text, expires_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT i.email, i.role, i.practice_id, pr.name, i.expires_at
  FROM practice_invites i JOIN practices pr ON pr.id = i.practice_id
  WHERE i.token = p_token AND i.status = 'pending' AND i.expires_at > now()
$$;
GRANT EXECUTE ON FUNCTION public.get_practice_invite(text) TO anon, authenticated;

-- Accept an invite as the signed-in user: creates their doctors row if needed,
-- adds them to the practice, marks the invite accepted. Returns practice id.
CREATE OR REPLACE FUNCTION public.accept_practice_invite(p_token text, p_first_name text, p_last_name text, p_spec text DEFAULT NULL, p_hpcsa text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  inv practice_invites%ROWTYPE;
  my_email text;
  doc_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in to accept the invite'; END IF;
  SELECT * INTO inv FROM practice_invites
  WHERE token = p_token AND status = 'pending' AND expires_at > now() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This invite link is invalid or has expired'; END IF;
  SELECT email INTO my_email FROM auth.users WHERE id = auth.uid();
  IF lower(coalesce(my_email, '')) <> lower(inv.email) THEN
    RAISE EXCEPTION 'This invite was sent to a different email address';
  END IF;

  SELECT id INTO doc_id FROM doctors WHERE auth_id = auth.uid() ORDER BY created_at LIMIT 1;
  IF doc_id IS NULL THEN
    INSERT INTO doctors (auth_id, first_name, last_name, name, email, spec, hpcsa)
    VALUES (auth.uid(), p_first_name, p_last_name,
            CASE WHEN inv.role = 'doctor' THEN 'Dr. ' ELSE '' END || trim(p_first_name || ' ' || p_last_name),
            inv.email,
            coalesce(p_spec, CASE WHEN inv.role = 'doctor' THEN 'General Practitioner' ELSE initcap(inv.role) END),
            p_hpcsa)
    RETURNING id INTO doc_id;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM practice_members WHERE practice_id = inv.practice_id AND doctor_id = doc_id) THEN
    INSERT INTO practice_members (practice_id, doctor_id, role, status, invite_email, invited_at, joined_at)
    VALUES (inv.practice_id, doc_id, inv.role, 'active', inv.email, inv.created_at, now());
  END IF;

  UPDATE practice_invites SET status = 'accepted' WHERE id = inv.id;
  RETURN inv.practice_id;
END $$;
GRANT EXECUTE ON FUNCTION public.accept_practice_invite(text, text, text, text, text) TO authenticated;

-- Register a multi-doctor practice with the signed-in user as owner.
-- p jsonb keys: name, address, phone, email, hpcsa_number, vat_number,
--               owner_first_name, owner_last_name, owner_spec, owner_hpcsa, owner_signature
CREATE OR REPLACE FUNCTION public.create_practice(p jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  doc_id uuid;
  pr_id uuid;
  my_email text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in first'; END IF;
  SELECT email INTO my_email FROM auth.users WHERE id = auth.uid();
  doc_id := public.my_doctor_id();
  IF doc_id IS NULL THEN
    INSERT INTO doctors (auth_id, first_name, last_name, name, email, spec, hpcsa, signature)
    VALUES (auth.uid(), p->>'owner_first_name', p->>'owner_last_name',
            'Dr. ' || trim(coalesce(p->>'owner_first_name','') || ' ' || coalesce(p->>'owner_last_name','')),
            my_email, coalesce(p->>'owner_spec', 'General Practitioner'), p->>'owner_hpcsa', p->>'owner_signature')
    RETURNING id INTO doc_id;
  END IF;
  IF EXISTS (SELECT 1 FROM practice_members WHERE doctor_id = doc_id AND role = 'owner') THEN
    RAISE EXCEPTION 'You already own a practice';
  END IF;
  INSERT INTO practices (name, address, phone, email, hpcsa_number, vat_number, plan, status, trial_ends_at, billing_email)
  VALUES (p->>'name', p->>'address', p->>'phone', p->>'email', p->>'hpcsa_number', nullif(p->>'vat_number',''),
          'practice', 'active', now() + interval '30 days', coalesce(p->>'email', my_email))
  RETURNING id INTO pr_id;
  INSERT INTO practice_members (practice_id, doctor_id, role, status, invite_email, joined_at)
  VALUES (pr_id, doc_id, 'owner', 'active', my_email, now());
  RETURN pr_id;
END $$;
GRANT EXECUTE ON FUNCTION public.create_practice(jsonb) TO authenticated;

-- Professional doctor's private one-doctor practice for the receptionist
-- add-on. Returns the existing one if already created.
CREATE OR REPLACE FUNCTION public.create_solo_practice() RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  d doctors%ROWTYPE;
  pr_id uuid;
BEGIN
  SELECT * INTO d FROM doctors WHERE auth_id = auth.uid() ORDER BY created_at LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'Your doctor profile is not set up yet'; END IF;
  SELECT pm.practice_id INTO pr_id FROM practice_members pm JOIN practices pr ON pr.id = pm.practice_id
  WHERE pm.doctor_id = d.id AND pm.role = 'owner' AND pr.plan = 'solo' LIMIT 1;
  IF pr_id IS NOT NULL THEN RETURN pr_id; END IF;
  IF EXISTS (SELECT 1 FROM practice_members WHERE doctor_id = d.id) THEN
    RAISE EXCEPTION 'Your account already belongs to a practice. Ask the practice owner to invite reception staff.';
  END IF;
  INSERT INTO practices (name, address, phone, email, plan, status, billing_email)
  VALUES (coalesce(nullif(d.prac_name, ''), coalesce(d.name, trim(d.first_name || ' ' || d.last_name)) || ' Practice'),
          d.prac_addr, d.phone, d.email, 'solo', 'active', d.email)
  RETURNING id INTO pr_id;
  INSERT INTO practice_members (practice_id, doctor_id, role, status, invite_email, joined_at)
  VALUES (pr_id, d.id, 'owner', 'active', d.email, now());
  RETURN pr_id;
END $$;
GRANT EXECUTE ON FUNCTION public.create_solo_practice() TO authenticated;

-- ── 5. Allow plan = 'solo' ──────────────────────────────────────────────────
DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.practices'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%plan%'
  LOOP
    EXECUTE format('ALTER TABLE public.practices DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;

-- NOT VALID: existing rows keep whatever plan they have; new rows are checked.
ALTER TABLE practices
  ADD CONSTRAINT practices_plan_check
  CHECK (plan IS NULL OR plan IN ('solo', 'practice', 'starter', 'pro')) NOT VALID;

-- Billing: receptionist seats for each solo practice
--   SELECT p.id, p.name, count(m.*) AS receptionists, 599 + 149 * count(m.*) AS monthly_zar
--   FROM practices p
--   LEFT JOIN practice_members m ON m.practice_id = p.id AND m.role = 'receptionist'
--   WHERE p.plan = 'solo'
--   GROUP BY p.id, p.name;
