-- ─────────────────────────────────────────────────────────────────────────────
-- MedConsult — Patient-owned profiles and access requests
-- Run in the Supabase SQL editor (after practice_access.sql, medical_aid_workflow.sql
-- and medconsult_security_fixes.sql). Safe to run more than once.
--
-- Model
--   * A patient creates their own profile (patients row with doctor_id NULL) and owns it.
--   * A doctor, or a receptionist for a doctor, invites a person by email or phone number.
--     The invite is a link. The patient opens it, signs in, and APPROVES or DECLINES.
--   * Approved doctors can read the patient's profile and whole record, and add records.
--     The patient can revoke at any time. Declined or revoked means no access.
--   * Only doctors (with approval) and the patient can read clinical records.
--     Receptionists never get access to records through this model.
--   * Patients a doctor created themselves (walk-ins) stay the doctor's. The doctor can
--     invite the patient to claim the profile; the creating doctor keeps access.
--
-- Everything goes through functions. patient_access has RLS on and no policies on
-- purpose: the API cannot read or write it directly.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Table ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.patient_access (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id    uuid REFERENCES public.patients(id) ON DELETE CASCADE,  -- NULL until the invitee has a profile
  doctor_id     uuid NOT NULL REFERENCES public.doctors(id) ON DELETE CASCADE,
  requested_by  uuid NOT NULL REFERENCES public.doctors(id),            -- doctor or receptionist who sent it
  contact_email text,
  contact_phone text,
  token         text NOT NULL UNIQUE DEFAULT replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  status        text NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'approved', 'declined', 'revoked', 'cancelled')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL DEFAULT now() + interval '14 days',  -- only matters while pending
  decided_at    timestamptz,
  CHECK (patient_id IS NOT NULL OR contact_email IS NOT NULL OR contact_phone IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS patient_access_one_open
  ON public.patient_access (patient_id, doctor_id)
  WHERE patient_id IS NOT NULL AND status IN ('pending', 'approved');
CREATE INDEX IF NOT EXISTS patient_access_doctor_idx ON public.patient_access (doctor_id, status);
CREATE INDEX IF NOT EXISTS patient_access_patient_idx ON public.patient_access (patient_id, status);
CREATE INDEX IF NOT EXISTS patient_access_email_idx ON public.patient_access (contact_email) WHERE patient_id IS NULL;

ALTER TABLE public.patient_access ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.patient_access FROM anon, authenticated;

-- Invites for patients a doctor already created: allow phone-only invites.
ALTER TABLE public.patient_invites ALTER COLUMN email DROP NOT NULL;
ALTER TABLE public.patient_invites ADD COLUMN IF NOT EXISTS contact_phone text;
ALTER TABLE public.patient_invites DROP CONSTRAINT IF EXISTS patient_invites_contact_check;
ALTER TABLE public.patient_invites ADD CONSTRAINT patient_invites_contact_check
  CHECK (email IS NOT NULL OR contact_phone IS NOT NULL);

-- ── 2. Helpers ──────────────────────────────────────────────────────────────
-- The signed-in user's own patient profile.
CREATE OR REPLACE FUNCTION public.my_patient_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT patient_id FROM patient_accounts WHERE auth_id = auth.uid() LIMIT 1
$$;

-- South African numbers to +27…; other countries need the + prefix. NULL if it does not look right.
CREATE OR REPLACE FUNCTION public.normalize_phone(p text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = public AS $$
DECLARE x text;
BEGIN
  IF p IS NULL OR btrim(p) = '' THEN RETURN NULL; END IF;
  x := regexp_replace(p, '[^0-9+]', '', 'g');
  IF x ~ '^\+[0-9]{8,15}$' THEN RETURN x; END IF;
  IF x ~ '^0[0-9]{9}$' THEN RETURN '+27' || substr(x, 2); END IF;
  IF x ~ '^27[0-9]{9}$' THEN RETURN '+' || x; END IF;
  RETURN NULL;
END $$;

-- May the signed-in user send requests for this doctor? The doctor, or reception/owner/admin
-- in the doctor's practice.
CREATE OR REPLACE FUNCTION public.can_manage_doctor(p_doctor uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p_doctor IS NOT NULL AND (
    p_doctor = public.my_doctor_id()
    OR p_doctor IN (SELECT public.my_practice_member_doctor_ids(ARRAY['receptionist', 'owner', 'admin'], ARRAY['owner', 'doctor']))
  )
$$;

-- Has the patient approved the signed-in doctor?
CREATE OR REPLACE FUNCTION public.has_granted_access(p_patient uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM patient_access a
    WHERE a.patient_id = p_patient AND a.status = 'approved' AND a.doctor_id = public.my_doctor_id()
  )
$$;

-- Approved by the patient, or the doctor created this patient themselves.
CREATE OR REPLACE FUNCTION public.has_patient_access(p_patient uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_granted_access(p_patient)
      OR EXISTS (SELECT 1 FROM patients p WHERE p.id = p_patient AND p.doctor_id = public.my_doctor_id())
$$;

-- ── 3. Row-level security: who can read and write clinical data ──────────────
-- Patient reads their own profile (uses patient_accounts, the one link table the portal uses).
DROP POLICY IF EXISTS "Patient reads own profile" ON public.patients;
CREATE POLICY "Patient reads own profile" ON public.patients FOR SELECT TO authenticated
  USING (id = public.my_patient_id());

-- Doctor reads the profiles of patients who approved them.
DROP POLICY IF EXISTS "Doctor reads patients with access" ON public.patients;
CREATE POLICY "Doctor reads patients with access" ON public.patients FOR SELECT TO authenticated
  USING (public.has_granted_access(id));

-- records, prescriptions, sick_notes: the author always reads their own; approved doctors read all;
-- writing needs the patient's approval (or the doctor created the patient).
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['records', 'prescriptions', 'sick_notes'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Doctor sees own ' || replace(t, '_', ' '), t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Doctor reads own ' || t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Doctor reads ' || t || ' of patients with access', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Doctor writes own ' || t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Doctor edits own ' || t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'Doctor deletes own ' || t, t);

    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (doctor_id = public.my_doctor_id())',
                   'Doctor reads own ' || t, t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.has_patient_access(patient_id))',
                   'Doctor reads ' || t || ' of patients with access', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (doctor_id = public.my_doctor_id() AND public.has_patient_access(patient_id))',
                   'Doctor writes own ' || t, t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (doctor_id = public.my_doctor_id()) WITH CHECK (doctor_id = public.my_doctor_id() AND public.has_patient_access(patient_id))',
                   'Doctor edits own ' || t, t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (doctor_id = public.my_doctor_id())',
                   'Doctor deletes own ' || t, t);
  END LOOP;
END $$;

-- ── 4. Patient: create and edit their own profile ────────────────────────────
CREATE OR REPLACE FUNCTION public.create_my_profile(p_first text, p_last text, p_phone text DEFAULT NULL, p_dob date DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  em text; confirmed timestamptz; pid uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in first'; END IF;
  SELECT u.email, u.email_confirmed_at INTO em, confirmed FROM auth.users u WHERE u.id = auth.uid();
  IF confirmed IS NULL THEN RAISE EXCEPTION 'Please verify your email address first'; END IF;
  IF public.my_patient_id() IS NOT NULL THEN RAISE EXCEPTION 'You already have a profile'; END IF;
  IF btrim(coalesce(p_first, '')) = '' OR btrim(coalesce(p_last, '')) = '' THEN
    RAISE EXCEPTION 'Enter your first and last name';
  END IF;

  INSERT INTO patients (doctor_id, first_name, last_name, email, phone, dob, status)
  VALUES (NULL, btrim(p_first), btrim(p_last), lower(em), nullif(btrim(coalesce(p_phone, '')), ''), p_dob, 'active')
  RETURNING id INTO pid;
  INSERT INTO patient_accounts (auth_id, patient_id) VALUES (auth.uid(), pid);
  RETURN pid;
END $$;

-- Patients edit their own details. Only these keys are accepted; doctor_id, medical aid status
-- and other system fields cannot be changed here.
CREATE OR REPLACE FUNCTION public.update_my_profile(p_changes jsonb) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  pid uuid := public.my_patient_id();
  bad text;
BEGIN
  IF pid IS NULL THEN RAISE EXCEPTION 'You do not have a profile yet'; END IF;
  SELECT k INTO bad FROM jsonb_object_keys(p_changes) k
  WHERE k NOT IN ('first_name', 'last_name', 'dob', 'id_number', 'gender', 'blood_type', 'phone', 'whatsapp',
                  'address', 'allergies', 'chronic', 'emergency') LIMIT 1;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Field % cannot be changed here', bad; END IF;

  UPDATE patients SET
    first_name = coalesce(nullif(btrim(p_changes->>'first_name'), ''), first_name),
    last_name  = coalesce(nullif(btrim(p_changes->>'last_name'), ''), last_name),
    dob        = CASE WHEN p_changes ? 'dob'        THEN nullif(p_changes->>'dob', '')::date ELSE dob END,
    id_number  = CASE WHEN p_changes ? 'id_number'  THEN nullif(btrim(p_changes->>'id_number'), '') ELSE id_number END,
    gender     = CASE WHEN p_changes ? 'gender'     THEN nullif(p_changes->>'gender', '') ELSE gender END,
    blood_type = CASE WHEN p_changes ? 'blood_type' THEN nullif(p_changes->>'blood_type', '') ELSE blood_type END,
    phone      = CASE WHEN p_changes ? 'phone'      THEN nullif(btrim(p_changes->>'phone'), '') ELSE phone END,
    whatsapp   = CASE WHEN p_changes ? 'whatsapp'   THEN nullif(btrim(p_changes->>'whatsapp'), '') ELSE whatsapp END,
    address    = CASE WHEN p_changes ? 'address'    THEN nullif(btrim(p_changes->>'address'), '') ELSE address END,
    allergies  = CASE WHEN p_changes ? 'allergies'  THEN nullif(btrim(p_changes->>'allergies'), '') ELSE allergies END,
    chronic    = CASE WHEN p_changes ? 'chronic'    THEN nullif(btrim(p_changes->>'chronic'), '') ELSE chronic END,
    emergency  = CASE WHEN p_changes ? 'emergency'  THEN nullif(btrim(p_changes->>'emergency'), '') ELSE emergency END
  WHERE id = pid;
  RETURN true;
END $$;

-- ── 5. Staff: request access (invite by email or phone) ──────────────────────
-- p_doctor NULL = the signed-in doctor. A receptionist passes the doctor they work for.
-- Returns the same shape whether or not the person already has a profile, so staff cannot
-- use it to find out who is on MedConsult.
CREATE OR REPLACE FUNCTION public.request_patient_access(p_email text DEFAULT NULL, p_phone text DEFAULT NULL, p_doctor uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  me uuid := public.my_doctor_id();
  target uuid;
  em text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  ph text := public.normalize_phone(p_phone);
  pid uuid;
  r patient_access%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in first'; END IF;
  IF me IS NULL THEN RAISE EXCEPTION 'Your staff profile is not set up yet'; END IF;
  target := coalesce(p_doctor, me);
  IF NOT public.can_manage_doctor(target) THEN RAISE EXCEPTION 'You cannot send requests for that doctor'; END IF;
  -- Access is only ever granted to a doctor. Reception, nurses and admins must pick the doctor.
  IF EXISTS (SELECT 1 FROM practice_members pm WHERE pm.doctor_id = target)
     AND NOT EXISTS (SELECT 1 FROM practice_members pm
                     WHERE pm.doctor_id = target AND pm.role IN ('owner', 'doctor')
                       AND coalesce(pm.status, 'active') NOT IN ('suspended', 'removed', 'pending')) THEN
    RAISE EXCEPTION 'Requests can only be made for a doctor. Choose the doctor.';
  END IF;
  IF nullif(btrim(coalesce(p_phone, '')), '') IS NOT NULL AND ph IS NULL THEN
    RAISE EXCEPTION 'That phone number does not look right';
  END IF;
  IF em IS NULL AND ph IS NULL THEN RAISE EXCEPTION 'Enter an email address or a phone number'; END IF;
  IF em IS NOT NULL AND em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'That email address does not look right';
  END IF;
  IF (SELECT count(*) FROM patient_access WHERE requested_by = me AND created_at > now() - interval '24 hours') >= 100 THEN
    RAISE EXCEPTION 'Too many requests today. Try again tomorrow.';
  END IF;

  -- Match a profile only by a VERIFIED email. Phone numbers are not verified, so they only
  -- deliver the link.
  IF em IS NOT NULL THEN
    SELECT pa.patient_id INTO pid
    FROM auth.users u JOIN patient_accounts pa ON pa.auth_id = u.id
    WHERE lower(u.email) = em AND u.email_confirmed_at IS NOT NULL
    LIMIT 1;
  END IF;

  SELECT * INTO r FROM patient_access a
  WHERE a.doctor_id = target
    AND (a.status = 'approved' OR (a.status = 'pending' AND a.expires_at > now()))
    AND ((pid IS NOT NULL AND a.patient_id = pid)
         OR (em IS NOT NULL AND a.contact_email = em)
         OR (ph IS NOT NULL AND a.contact_phone = ph))
  ORDER BY a.created_at DESC LIMIT 1;

  IF FOUND THEN
    IF r.status = 'pending' THEN
      UPDATE patient_access SET expires_at = now() + interval '14 days' WHERE id = r.id RETURNING * INTO r;
    END IF;
  ELSE
    INSERT INTO patient_access (patient_id, doctor_id, requested_by, contact_email, contact_phone)
    VALUES (pid, target, me, em, ph) RETURNING * INTO r;
  END IF;

  RETURN jsonb_build_object('id', r.id, 'token', r.token, 'status', r.status, 'expires_at', r.expires_at);
END $$;

-- Staff list for the doctors they manage. The patient's name is shown only after approval.
CREATE OR REPLACE FUNCTION public.list_access_requests()
RETURNS TABLE (access_id uuid, dr_id uuid, dr_name text, contact_email text, contact_phone text,
               access_status text, requested_at timestamptz, request_expires_at timestamptz,
               decided_on timestamptz, link_token text, patient_name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT a.id, a.doctor_id,
         coalesce(nullif(d.name, ''), btrim(coalesce(d.first_name, '') || ' ' || coalesce(d.last_name, ''))),
         a.contact_email, a.contact_phone,
         CASE WHEN a.status = 'pending' AND a.expires_at <= now() THEN 'expired' ELSE a.status END,
         a.created_at, a.expires_at, a.decided_at,
         CASE WHEN a.status = 'pending' AND a.expires_at > now() THEN a.token END,
         CASE WHEN a.status = 'approved' THEN btrim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')) END
  FROM patient_access a
  JOIN doctors d ON d.id = a.doctor_id
  LEFT JOIN patients p ON p.id = a.patient_id
  WHERE public.can_manage_doctor(a.doctor_id) AND a.status <> 'cancelled'
  ORDER BY a.created_at DESC
  LIMIT 200
$$;

CREATE OR REPLACE FUNCTION public.cancel_access_request(p_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r patient_access%ROWTYPE;
BEGIN
  SELECT * INTO r FROM patient_access WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR NOT public.can_manage_doctor(r.doctor_id) THEN RAISE EXCEPTION 'Request not found'; END IF;
  IF r.status <> 'pending' THEN RAISE EXCEPTION 'Only a pending request can be cancelled'; END IF;
  UPDATE patient_access SET status = 'cancelled', decided_at = now() WHERE id = p_id;
  RETURN true;
END $$;

-- ── 6. Patient: see, approve, decline, revoke ────────────────────────────────
-- What the invite screen shows before sign-up. Needs the secret link token.
CREATE OR REPLACE FUNCTION public.get_access_link(p_token text)
RETURNS TABLE (dr_name text, dr_spec text, dr_hpcsa text, practice_name text, request_expires_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(nullif(d.name, ''), btrim(coalesce(d.first_name, '') || ' ' || coalesce(d.last_name, ''))),
         d.spec, d.hpcsa,
         coalesce((SELECT pr.name FROM practice_members pm JOIN practices pr ON pr.id = pm.practice_id
                   WHERE pm.doctor_id = d.id AND coalesce(pm.status, 'active') NOT IN ('suspended', 'removed', 'pending')
                   ORDER BY pm.created_at LIMIT 1), nullif(d.prac_name, '')),
         a.expires_at
  FROM patient_access a JOIN doctors d ON d.id = a.doctor_id
  WHERE a.token = p_token AND a.status = 'pending' AND a.expires_at > now()
$$;

-- Attach an invite link to the signed-in patient's profile. This does NOT approve anything;
-- it only makes the request appear in their list.
CREATE OR REPLACE FUNCTION public.accept_access_link(p_token text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  pid uuid := public.my_patient_id();
  em text;
  r patient_access%ROWTYPE;
  existing uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in first'; END IF;
  IF pid IS NULL THEN RAISE EXCEPTION 'Create your profile first'; END IF;
  SELECT lower(u.email) INTO em FROM auth.users u WHERE u.id = auth.uid() AND u.email_confirmed_at IS NOT NULL;

  SELECT * INTO r FROM patient_access WHERE token = p_token AND status = 'pending' AND expires_at > now() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This request link is invalid or has expired'; END IF;
  IF r.patient_id IS NOT NULL AND r.patient_id <> pid THEN
    RAISE EXCEPTION 'This request was sent to a different profile';
  END IF;
  IF r.contact_email IS NOT NULL AND em IS DISTINCT FROM r.contact_email THEN
    RAISE EXCEPTION 'This request was sent to a different email address';
  END IF;

  IF r.patient_id = pid THEN RETURN r.id; END IF;

  SELECT a.id INTO existing FROM patient_access a
  WHERE a.patient_id = pid AND a.doctor_id = r.doctor_id AND a.status IN ('pending', 'approved') LIMIT 1;
  IF existing IS NOT NULL THEN
    UPDATE patient_access SET status = 'cancelled', decided_at = now() WHERE id = r.id;
    RETURN existing;
  END IF;

  UPDATE patient_access SET patient_id = pid WHERE id = r.id;
  RETURN r.id;
END $$;

-- The patient's doctors and requests. Also attaches any waiting requests that were sent to
-- their verified email address.
CREATE OR REPLACE FUNCTION public.list_my_access()
RETURNS TABLE (access_id uuid, dr_id uuid, dr_name text, dr_spec text, dr_hpcsa text, practice_name text,
               access_status text, requested_at timestamptz, request_expires_at timestamptz, decided_on timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  pid uuid := public.my_patient_id();
  em text;
  w record;
BEGIN
  IF pid IS NULL THEN RETURN; END IF;
  SELECT lower(u.email) INTO em FROM auth.users u WHERE u.id = auth.uid() AND u.email_confirmed_at IS NOT NULL;
  IF em IS NOT NULL THEN
    FOR w IN SELECT pa.id AS wid, pa.doctor_id AS wdoc FROM patient_access pa
             WHERE pa.patient_id IS NULL AND pa.status = 'pending' AND pa.expires_at > now() AND pa.contact_email = em
    LOOP
      IF EXISTS (SELECT 1 FROM patient_access x WHERE x.patient_id = pid AND x.doctor_id = w.wdoc AND x.status IN ('pending', 'approved')) THEN
        UPDATE patient_access SET status = 'cancelled', decided_at = now() WHERE id = w.wid;
      ELSE
        UPDATE patient_access SET patient_id = pid WHERE id = w.wid;
      END IF;
    END LOOP;
  END IF;

  RETURN QUERY
  SELECT a.id, a.doctor_id,
         coalesce(nullif(d.name, ''), btrim(coalesce(d.first_name, '') || ' ' || coalesce(d.last_name, ''))),
         d.spec, d.hpcsa,
         coalesce((SELECT pr.name FROM practice_members pm JOIN practices pr ON pr.id = pm.practice_id
                   WHERE pm.doctor_id = d.id AND coalesce(pm.status, 'active') NOT IN ('suspended', 'removed', 'pending')
                   ORDER BY pm.created_at LIMIT 1), nullif(d.prac_name, '')),
         a.status, a.created_at, a.expires_at, a.decided_at
  FROM patient_access a JOIN doctors d ON d.id = a.doctor_id
  WHERE a.patient_id = pid
    AND a.status <> 'cancelled'
    AND NOT (a.status = 'pending' AND a.expires_at <= now())
  ORDER BY (a.status = 'pending') DESC, a.created_at DESC;
END $$;

CREATE OR REPLACE FUNCTION public.respond_access_request(p_id uuid, p_approve boolean) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE new_status text := CASE WHEN p_approve THEN 'approved' ELSE 'declined' END;
BEGIN
  UPDATE patient_access SET status = new_status, decided_at = now()
  WHERE id = p_id AND patient_id = public.my_patient_id() AND status = 'pending' AND expires_at > now();
  IF NOT FOUND THEN RAISE EXCEPTION 'This request is no longer open'; END IF;
  RETURN new_status;
END $$;

CREATE OR REPLACE FUNCTION public.revoke_access(p_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE patient_access SET status = 'revoked', decided_at = now()
  WHERE id = p_id AND patient_id = public.my_patient_id() AND status = 'approved';
  IF NOT FOUND THEN RAISE EXCEPTION 'Access not found'; END IF;
  RETURN true;
END $$;

-- ── 7. Patients a doctor created themselves: invite them to claim the profile ─
CREATE OR REPLACE FUNCTION public.invite_patient_to_claim(p_patient uuid, p_email text DEFAULT NULL, p_phone text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  em text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  ph text := public.normalize_phone(p_phone);
  owner_doc uuid;
  r patient_invites%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in first'; END IF;
  IF NOT public.can_access_patient(p_patient) THEN RAISE EXCEPTION 'You do not have access to this patient'; END IF;
  IF nullif(btrim(coalesce(p_phone, '')), '') IS NOT NULL AND ph IS NULL THEN
    RAISE EXCEPTION 'That phone number does not look right';
  END IF;
  IF em IS NULL AND ph IS NULL THEN RAISE EXCEPTION 'Enter an email address or a phone number'; END IF;
  IF em IS NOT NULL AND em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'That email address does not look right';
  END IF;
  IF EXISTS (SELECT 1 FROM patient_accounts WHERE patient_id = p_patient) THEN
    RAISE EXCEPTION 'This patient already has an account';
  END IF;

  SELECT doctor_id INTO owner_doc FROM patients WHERE id = p_patient;
  SELECT * INTO r FROM patient_invites i WHERE i.patient_id = p_patient AND i.status = 'pending' AND i.expires_at > now()
  ORDER BY i.created_at DESC LIMIT 1;
  IF FOUND THEN
    UPDATE patient_invites SET email = em, contact_phone = ph, expires_at = now() + interval '7 days'
    WHERE id = r.id RETURNING * INTO r;
  ELSE
    INSERT INTO patient_invites (doctor_id, patient_id, email, contact_phone)
    VALUES (owner_doc, p_patient, em, ph) RETURNING * INTO r;
  END IF;
  RETURN jsonb_build_object('id', r.id, 'token', r.token, 'status', r.status, 'expires_at', r.expires_at);
END $$;

-- Claim invites now also work when sent to a phone number only. The email must still match
-- when the invite was sent to an email address.
CREATE OR REPLACE FUNCTION public.accept_patient_invite(p_token text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  inv patient_invites%ROWTYPE;
  my_email text;
  confirmed timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in to accept the invite'; END IF;

  SELECT u.email, u.email_confirmed_at INTO my_email, confirmed FROM auth.users u WHERE u.id = auth.uid();
  IF confirmed IS NULL THEN RAISE EXCEPTION 'Please verify your email address first'; END IF;

  SELECT * INTO inv FROM patient_invites
  WHERE token = p_token AND status = 'pending' AND expires_at > now() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This invite link is invalid or has expired'; END IF;

  IF inv.email IS NOT NULL AND lower(coalesce(my_email, '')) <> lower(inv.email) THEN
    RAISE EXCEPTION 'This invite was sent to a different email address';
  END IF;
  IF EXISTS (SELECT 1 FROM patient_accounts WHERE auth_id = auth.uid()) THEN
    RAISE EXCEPTION 'You already have a profile. Ask the doctor to send an access request instead.';
  END IF;
  IF EXISTS (SELECT 1 FROM patient_accounts WHERE patient_id = inv.patient_id) THEN
    RAISE EXCEPTION 'This patient record is already linked to an account';
  END IF;

  INSERT INTO patient_accounts (auth_id, patient_id) VALUES (auth.uid(), inv.patient_id);
  UPDATE patient_invites SET status = 'accepted' WHERE id = inv.id;
  RETURN inv.patient_id;
END $$;

-- ── 8. Who may call what ─────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION
  public.my_patient_id(), public.normalize_phone(text), public.can_manage_doctor(uuid),
  public.has_granted_access(uuid), public.has_patient_access(uuid),
  public.create_my_profile(text, text, text, date), public.update_my_profile(jsonb),
  public.request_patient_access(text, text, uuid), public.list_access_requests(),
  public.cancel_access_request(uuid), public.get_access_link(text), public.accept_access_link(text),
  public.list_my_access(), public.respond_access_request(uuid, boolean), public.revoke_access(uuid),
  public.invite_patient_to_claim(uuid, text, text), public.accept_patient_invite(text)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
  public.my_patient_id(), public.normalize_phone(text), public.can_manage_doctor(uuid),
  public.has_granted_access(uuid), public.has_patient_access(uuid),
  public.create_my_profile(text, text, text, date), public.update_my_profile(jsonb),
  public.request_patient_access(text, text, uuid), public.list_access_requests(),
  public.cancel_access_request(uuid), public.accept_access_link(text),
  public.list_my_access(), public.respond_access_request(uuid, boolean), public.revoke_access(uuid),
  public.invite_patient_to_claim(uuid, text, text), public.accept_patient_invite(text)
TO authenticated;

-- The invite screen runs before sign-up, so it can be called signed out. It needs the secret token.
GRANT EXECUTE ON FUNCTION public.get_access_link(text) TO anon, authenticated;
