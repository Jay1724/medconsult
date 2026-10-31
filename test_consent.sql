DO $test$
DECLARE res text := ''; u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); d uuid; p1 uuid; n int; v text;
BEGIN
  INSERT INTO auth.users (id,email,email_confirmed_at,aud,role) VALUES (u1,'p1@t.local',now(),'authenticated','authenticated'),(u2,'p2@t.local',now(),'authenticated','authenticated');
  INSERT INTO doctors (auth_id,name,first_name,last_name,email) VALUES (gen_random_uuid(),'D','D','D','d@t.local') RETURNING id INTO d;
  INSERT INTO patients (doctor_id,first_name,last_name) VALUES (d,'Pat','One') RETURNING id INTO p1;
  INSERT INTO patient_accounts (auth_id,patient_id) VALUES (u1,p1);
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u1,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u1::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  v := current_consent_version();
  res := res || E'\n' || CASE WHEN NOT my_consent_ok() THEN 'PASS' ELSE 'FAIL' END || ' 1 no consent until accepted';
  BEGIN PERFORM record_consent('1999-01-01'); res := res || E'\nFAIL 2 stale version accepted'; EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 2 a stale version cannot be accepted'; END;
  PERFORM record_consent(v); PERFORM record_consent(v);
  res := res || E'\n' || CASE WHEN my_consent_ok() THEN 'PASS' ELSE 'FAIL' END || ' 3 consent recorded (repeat is harmless)';
  EXECUTE 'RESET ROLE'; SELECT count(*) INTO n FROM consents WHERE auth_id=u1 AND patient_id=p1;
  res := res || E'\n' || CASE WHEN n=2 THEN 'PASS' ELSE 'FAIL' END || ' 4 two consent rows stored with the patient';
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u2,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u2::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  res := res || E'\n' || CASE WHEN NOT my_consent_ok() THEN 'PASS' ELSE 'FAIL' END || ' 5 someone else''s consent does not count';
  BEGIN PERFORM count(*) FROM consents; res := res || E'\nFAIL 6 table readable'; EXCEPTION WHEN insufficient_privilege THEN res := res || E'\nPASS 6 table cannot be read directly'; END;
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims','',true); PERFORM set_config('request.jwt.claim.sub','',true); EXECUTE 'SET LOCAL ROLE anon';
  BEGIN PERFORM record_consent(v); res := res || E'\nFAIL 7 anon can record'; EXCEPTION WHEN insufficient_privilege THEN res := res || E'\nPASS 7 anon cannot record consent'; END;
  RAISE EXCEPTION 'TEST RESULTS:%', res;
END $test$;
