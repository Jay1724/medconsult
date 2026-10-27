-- MedConsult: security fixes 1 and 3 (27 Oct 2026)
-- Run in the Supabase SQL editor for project "med Consult". Safe to run more than once.
-- Pair with the patient.html patch, which switches the portal sign-up to the new functions.

-- ── Fix 1: patient accounts can only be linked through a valid invite ─────────
-- Removes the open INSERT policy that let any signed-in user link their login to any patient_id.
DROP POLICY IF EXISTS "Patient can create own account" ON public.patient_accounts;

-- Pre-sign-up check: is this invite usable, and which email is it for? Returns no patient data.
CREATE OR REPLACE FUNCTION public.get_patient_invite(p_token text)
RETURNS TABLE (email text, expires_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT i.email, i.expires_at
  FROM patient_invites i
  WHERE i.token = p_token AND i.status = 'pending' AND i.expires_at > now()
$$;

-- Redeem an invite as the signed-in user. Links their login to the invited patient record.
CREATE OR REPLACE FUNCTION public.accept_patient_invite(p_token text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  inv patient_invites%ROWTYPE;
  my_email text;
  confirmed timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in to accept the invite'; END IF;

  SELECT u.email, u.email_confirmed_at INTO my_email, confirmed
  FROM auth.users u WHERE u.id = auth.uid();
  IF confirmed IS NULL THEN RAISE EXCEPTION 'Please verify your email address first'; END IF;

  SELECT * INTO inv FROM patient_invites
  WHERE token = p_token AND status = 'pending' AND expires_at > now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This invite link is invalid or has expired'; END IF;

  IF lower(coalesce(my_email, '')) <> lower(inv.email) THEN
    RAISE EXCEPTION 'This invite was sent to a different email address';
  END IF;
  IF EXISTS (SELECT 1 FROM patient_accounts WHERE auth_id = auth.uid()) THEN
    RAISE EXCEPTION 'Your account is already linked to a patient record';
  END IF;
  IF EXISTS (SELECT 1 FROM patient_accounts WHERE patient_id = inv.patient_id) THEN
    RAISE EXCEPTION 'This patient record is already linked to an account';
  END IF;

  INSERT INTO patient_accounts (auth_id, patient_id) VALUES (auth.uid(), inv.patient_id);
  UPDATE patient_invites SET status = 'accepted' WHERE id = inv.id;
  RETURN inv.patient_id;
END $$;

REVOKE ALL ON FUNCTION public.get_patient_invite(text), public.accept_patient_invite(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_patient_invite(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.accept_patient_invite(text) TO authenticated;

-- ── Fix 3: signed-out visitors can no longer call internal functions ──────────
-- Postgres grants EXECUTE to PUBLIC by default, so revoke from PUBLIC as well as anon.
-- get_practice_invite stays open on purpose: it serves the invite screen before sign-up.
REVOKE ALL ON FUNCTION
  public.accept_practice_invite(text, text, text, text, text),
  public.can_access_patient(uuid),
  public.create_practice(jsonb),
  public.create_solo_practice(),
  public.my_display_name(),
  public.my_doctor_id(),
  public.my_practice_ids(text[]),
  public.my_practice_member_doctor_ids(text[], text[]),
  public.record_medical_aid_check(uuid, text, text, text, text),
  public.update_patient_medical_aid(uuid, jsonb)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
  public.accept_practice_invite(text, text, text, text, text),
  public.can_access_patient(uuid),
  public.create_practice(jsonb),
  public.create_solo_practice(),
  public.my_display_name(),
  public.my_doctor_id(),
  public.my_practice_ids(text[]),
  public.my_practice_member_doctor_ids(text[], text[]),
  public.record_medical_aid_check(uuid, text, text, text, text),
  public.update_patient_medical_aid(uuid, jsonb)
TO authenticated;

-- ── Verify (run after) ───────────────────────────────────────────────────────
-- Should return only get_practice_invite and get_patient_invite:
--   SELECT routine_name FROM information_schema.routine_privileges
--   WHERE grantee = 'anon' AND routine_schema = 'public' ORDER BY 1;
-- Should return no rows:
--   SELECT * FROM pg_policies WHERE tablename = 'patient_accounts' AND cmd = 'INSERT';
