-- MedConsult — patients complete their own profile (adds medical aid fields, checks phone numbers)
-- Run after patient_access.sql. Safe to re-run.
-- Changing medical aid details clears the verification, so a doctor's "verified" tick never
-- vouches for details the patient has since changed.
CREATE OR REPLACE FUNCTION public.update_my_profile(p_changes jsonb) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  pid uuid := public.my_patient_id();
  bad text;
  ph text; wa text; idn text; aid_changed boolean := false; cur patients%ROWTYPE;
BEGIN
  IF pid IS NULL THEN RAISE EXCEPTION 'You do not have a profile yet'; END IF;
  SELECT k INTO bad FROM jsonb_object_keys(p_changes) k
  WHERE k NOT IN ('first_name', 'last_name', 'dob', 'id_number', 'gender', 'blood_type', 'phone', 'whatsapp',
                  'address', 'allergies', 'chronic', 'emergency',
                  'aid_provider', 'aid_number', 'aid_plan', 'principal') LIMIT 1;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Field % cannot be changed here', bad; END IF;

  IF p_changes ? 'phone' AND nullif(btrim(p_changes->>'phone'), '') IS NOT NULL THEN
    ph := public.normalize_phone(p_changes->>'phone');
    IF ph IS NULL THEN RAISE EXCEPTION 'That phone number does not look right'; END IF;
  END IF;
  IF p_changes ? 'whatsapp' AND nullif(btrim(p_changes->>'whatsapp'), '') IS NOT NULL THEN
    wa := public.normalize_phone(p_changes->>'whatsapp');
    IF wa IS NULL THEN RAISE EXCEPTION 'That WhatsApp number does not look right'; END IF;
  END IF;
  IF p_changes ? 'id_number' AND nullif(btrim(p_changes->>'id_number'), '') IS NOT NULL
     AND btrim(p_changes->>'id_number') !~ '^[0-9]{13}$' THEN
    RAISE EXCEPTION 'An ID number has 13 digits';
  END IF;
  IF p_changes ? 'dob' AND nullif(p_changes->>'dob', '') IS NOT NULL
     AND ((p_changes->>'dob')::date > current_date OR (p_changes->>'dob')::date < date '1900-01-01') THEN
    RAISE EXCEPTION 'Check the date of birth';
  END IF;

  SELECT * INTO cur FROM patients WHERE id = pid;
  aid_changed :=
       (p_changes ? 'aid_provider' AND nullif(btrim(p_changes->>'aid_provider'), '') IS DISTINCT FROM cur.aid_provider)
    OR (p_changes ? 'aid_number'   AND nullif(btrim(p_changes->>'aid_number'), '')   IS DISTINCT FROM cur.aid_number)
    OR (p_changes ? 'aid_plan'     AND nullif(btrim(p_changes->>'aid_plan'), '')     IS DISTINCT FROM cur.aid_plan);

  UPDATE patients SET
    first_name = coalesce(nullif(btrim(p_changes->>'first_name'), ''), first_name),
    last_name  = coalesce(nullif(btrim(p_changes->>'last_name'), ''), last_name),
    dob        = CASE WHEN p_changes ? 'dob'        THEN nullif(p_changes->>'dob', '')::date ELSE dob END,
    id_number  = CASE WHEN p_changes ? 'id_number'  THEN nullif(btrim(p_changes->>'id_number'), '') ELSE id_number END,
    gender     = CASE WHEN p_changes ? 'gender'     THEN nullif(p_changes->>'gender', '') ELSE gender END,
    blood_type = CASE WHEN p_changes ? 'blood_type' THEN nullif(p_changes->>'blood_type', '') ELSE blood_type END,
    phone      = CASE WHEN p_changes ? 'phone'      THEN ph ELSE phone END,
    whatsapp   = CASE WHEN p_changes ? 'whatsapp'   THEN wa ELSE whatsapp END,
    address    = CASE WHEN p_changes ? 'address'    THEN nullif(btrim(p_changes->>'address'), '') ELSE address END,
    allergies  = CASE WHEN p_changes ? 'allergies'  THEN nullif(btrim(p_changes->>'allergies'), '') ELSE allergies END,
    chronic    = CASE WHEN p_changes ? 'chronic'    THEN nullif(btrim(p_changes->>'chronic'), '') ELSE chronic END,
    emergency  = CASE WHEN p_changes ? 'emergency'  THEN nullif(btrim(p_changes->>'emergency'), '') ELSE emergency END,
    aid_provider = CASE WHEN p_changes ? 'aid_provider' THEN nullif(btrim(p_changes->>'aid_provider'), '') ELSE aid_provider END,
    aid_number   = CASE WHEN p_changes ? 'aid_number'   THEN nullif(btrim(p_changes->>'aid_number'), '') ELSE aid_number END,
    aid_plan     = CASE WHEN p_changes ? 'aid_plan'     THEN nullif(btrim(p_changes->>'aid_plan'), '') ELSE aid_plan END,
    principal    = CASE WHEN p_changes ? 'principal'    THEN nullif(btrim(p_changes->>'principal'), '') ELSE principal END,
    aid_status = CASE WHEN aid_changed THEN NULL ELSE aid_status END,
    aid_checked_at = CASE WHEN aid_changed THEN NULL ELSE aid_checked_at END,
    aid_checked_by = CASE WHEN aid_changed THEN NULL ELSE aid_checked_by END,
    aid_check_method = CASE WHEN aid_changed THEN NULL ELSE aid_check_method END,
    aid_check_ref = CASE WHEN aid_changed THEN NULL ELSE aid_check_ref END
  WHERE id = pid;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.update_my_profile(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_my_profile(jsonb) TO authenticated;
