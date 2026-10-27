-- Run after the whole sequence. Expected: anon can execute only these functions.
--   get_access_link, get_patient_invite, get_practice_invite  (token-gated by design)
--   get_available_slots, get_next_ref, seed_default_availability, set_updated_at  (not SECURITY DEFINER)
SELECT p.proname, p.prosecdef AS security_definer
FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
  AND has_function_privilege('anon', p.oid, 'EXECUTE')
ORDER BY 1;
