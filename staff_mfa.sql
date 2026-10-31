-- ============================================================
-- Two-factor sign-in, enforced by the database. Run after consent.sql. Safe to re-run.
--
-- Rule: a person who has set up an authenticator app can only read or write patient data
-- once their session has passed the second step (aal2). A session that only had the password gets nothing,
-- even if the app is bypassed and the API is called directly.
--
-- Staff (anyone with a doctors row) can also be made to enrol: when you are ready, run
--     UPDATE public.app_settings SET value = 'true' WHERE key = 'mfa_required_for_staff';
-- and every doctor and receptionist without a second factor is locked out of patient data until they set one up.
-- It starts OFF so nobody is locked out by surprise.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.app_settings (key text PRIMARY KEY, value text NOT NULL);
ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;     -- no policies: owner-only
REVOKE ALL ON public.app_settings FROM anon, authenticated;
INSERT INTO public.app_settings (key, value) VALUES ('mfa_required_for_staff', 'false') ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.mfa_ok() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE
    WHEN auth.uid() IS NULL THEN false
    WHEN coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2' THEN true
    WHEN EXISTS (SELECT 1 FROM auth.mfa_factors f WHERE f.user_id = auth.uid() AND f.status = 'verified') THEN false
    WHEN coalesce((SELECT value FROM app_settings WHERE key = 'mfa_required_for_staff'), 'false') = 'true'
         AND EXISTS (SELECT 1 FROM doctors d WHERE d.auth_id = auth.uid()) THEN false
    ELSE true
  END
$$;
REVOKE ALL ON FUNCTION public.mfa_ok() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mfa_ok() TO authenticated;

-- A restrictive policy is ANDed with every other policy on the table.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['patients', 'records', 'sick_notes', 'prescriptions', 'appointments', 'invoices', 'claims', 'medical_aid_checks'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS "Second factor required" ON public.%I', t);
    EXECUTE format('CREATE POLICY "Second factor required" ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING (public.mfa_ok()) WITH CHECK (public.mfa_ok())', t);
  END LOOP;
END $$;

-- Photos of medical aid cards
DROP POLICY IF EXISTS "Second factor required for card photos" ON storage.objects;
CREATE POLICY "Second factor required for card photos" ON storage.objects AS RESTRICTIVE FOR ALL TO authenticated
  USING (bucket_id <> 'medical-aid-cards' OR public.mfa_ok())
  WITH CHECK (bucket_id <> 'medical-aid-cards' OR public.mfa_ok());
