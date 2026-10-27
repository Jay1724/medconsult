-- ============================================================
-- Patient consent, stored with the version accepted and the time. Run after popia_hardening.sql. Safe to re-run.
-- The app shows the consent screen until the patient has accepted the CURRENT version; bump the version in
-- current_consent_version() (and in patient.html) whenever the privacy notice changes in a way that needs fresh consent.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.consents (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  auth_id     uuid NOT NULL,
  patient_id  uuid,                                  -- no foreign key: the proof of consent outlives an erased profile
  kind        text NOT NULL CHECK (kind IN ('privacy_notice', 'health_data_transfer')),
  version     text NOT NULL,
  accepted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (auth_id, kind, version)
);
ALTER TABLE public.consents ENABLE ROW LEVEL SECURITY;     -- no policies: functions only
REVOKE ALL ON public.consents FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.current_consent_version() RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = public AS $$ SELECT '2026-10-27'::text $$;

CREATE OR REPLACE FUNCTION public.my_consent_ok() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth.uid() IS NOT NULL AND (
    SELECT count(DISTINCT kind) FROM consents
    WHERE auth_id = auth.uid() AND version = public.current_consent_version()) = 2
$$;

-- Accept the current notice and the transfer to the UK. Only the current version can be accepted.
CREATE OR REPLACE FUNCTION public.record_consent(p_version text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in first'; END IF;
  IF p_version IS DISTINCT FROM public.current_consent_version() THEN
    RAISE EXCEPTION 'The privacy notice has been updated. Please reload the page and read it again.';
  END IF;
  INSERT INTO consents (auth_id, patient_id, kind, version)
  SELECT auth.uid(), public.my_patient_id(), k, p_version FROM unnest(ARRAY['privacy_notice', 'health_data_transfer']) AS k
  ON CONFLICT (auth_id, kind, version) DO NOTHING;
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['my_consent_ok()', 'record_consent(text)', 'current_consent_version()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;
