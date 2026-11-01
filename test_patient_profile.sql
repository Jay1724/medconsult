-- run on a database with patient_access.sql + clinical stack + patient_profile.sql
DO $test$
DECLARE res text := ''; u uuid := gen_random_uuid(); pid uuid; r patients%ROWTYPE;
BEGIN
  INSERT INTO auth.users (id,email,email_confirmed_at,aud,role) VALUES (u,'p@t.local',now(),'authenticated','authenticated');
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  pid := create_my_profile('Pat','One',NULL,NULL);
  PERFORM update_my_profile('{"dob":"1990-05-01","id_number":"9005015800086","gender":"Female","blood_type":"O+","phone":"082 123 4567","whatsapp":"0821234567","address":"1 Main Rd","allergies":"Penicillin","emergency":"Sam 0831112222","aid_provider":"Discovery","aid_number":"123","aid_plan":"Classic"}'::jsonb);
  EXECUTE 'RESET ROLE'; SELECT * INTO r FROM patients WHERE id=pid; EXECUTE 'SET LOCAL ROLE authenticated';
  res := res||E'\n'||CASE WHEN r.phone='+27821234567' AND r.whatsapp='+27821234567' THEN 'PASS' ELSE 'FAIL '||coalesce(r.phone,'null') END||' 1 phone numbers are stored in international form';
  res := res||E'\n'||CASE WHEN r.dob='1990-05-01' AND r.aid_provider='Discovery' AND r.allergies='Penicillin' AND r.first_name='Pat' THEN 'PASS' ELSE 'FAIL' END||' 2 details saved, name untouched';
  BEGIN PERFORM update_my_profile('{"phone":"abc"}'::jsonb); res:=res||E'\nFAIL 3 bad phone accepted'; EXCEPTION WHEN OTHERS THEN res:=res||E'\nPASS 3 bad phone refused'; END;
  BEGIN PERFORM update_my_profile('{"id_number":"123"}'::jsonb); res:=res||E'\nFAIL 4 bad id accepted'; EXCEPTION WHEN OTHERS THEN res:=res||E'\nPASS 4 bad ID number refused'; END;
  BEGIN PERFORM update_my_profile('{"dob":"2999-01-01"}'::jsonb); res:=res||E'\nFAIL 5 future dob'; EXCEPTION WHEN OTHERS THEN res:=res||E'\nPASS 5 future birth date refused'; END;
  BEGIN PERFORM update_my_profile('{"aid_status":"verified"}'::jsonb); res:=res||E'\nFAIL 6 patient set verified'; EXCEPTION WHEN OTHERS THEN res:=res||E'\nPASS 6 patient cannot mark their own aid verified'; END;
  -- doctor verified it, patient then edits the number: verification cleared; same value keeps it
  EXECUTE 'RESET ROLE'; UPDATE patients SET aid_status='verified', aid_checked_at=now() WHERE id=pid; EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM update_my_profile('{"aid_provider":"Discovery","aid_number":"123","address":"2 Main Rd"}'::jsonb);
  EXECUTE 'RESET ROLE'; SELECT * INTO r FROM patients WHERE id=pid; EXECUTE 'SET LOCAL ROLE authenticated';
  res := res||E'\n'||CASE WHEN r.aid_status='verified' THEN 'PASS' ELSE 'FAIL' END||' 7 unchanged aid details keep the verification';
  PERFORM update_my_profile('{"aid_number":"999"}'::jsonb);
  EXECUTE 'RESET ROLE'; SELECT * INTO r FROM patients WHERE id=pid; EXECUTE 'SET LOCAL ROLE authenticated';
  res := res||E'\n'||CASE WHEN r.aid_status IS NULL AND r.aid_checked_at IS NULL THEN 'PASS' ELSE 'FAIL' END||' 8 changed aid number clears the verification';
  PERFORM update_my_profile('{"allergies":""}'::jsonb);
  EXECUTE 'RESET ROLE'; SELECT * INTO r FROM patients WHERE id=pid;
  res := res||E'\n'||CASE WHEN r.allergies IS NULL THEN 'PASS' ELSE 'FAIL' END||' 9 a field can be cleared';
  RAISE EXCEPTION 'TEST RESULTS:%', res;
END $test$;
