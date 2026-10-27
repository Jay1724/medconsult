-- Test harness for patient_access.sql. Append this AFTER patient_access.sql and run both together.
-- It builds fixtures, exercises every function as the real roles, then ends with an error that
-- carries the results, so the whole run (schema changes included) rolls back. Nothing is saved.
DO $test$
DECLARE
  res text := '';
  u_da uuid := gen_random_uuid(); u_db uuid := gen_random_uuid(); u_rc uuid := gen_random_uuid();
  u_p1 uuid := gen_random_uuid(); u_p2 uuid := gen_random_uuid();
  da uuid; db uuid; rc uuid; prac uuid; pid uuid; pid2 uuid; walk uuid;
  req jsonb; req2 jsonb; tok text; n int; s text; aid uuid; link_token text;
BEGIN
  -- fixtures (as the database owner)
  INSERT INTO auth.users (id, email, email_confirmed_at, aud, role) VALUES
    (u_da, 'dr.a@test.local', now(), 'authenticated', 'authenticated'),
    (u_db, 'dr.b@test.local', now(), 'authenticated', 'authenticated'),
    (u_rc, 'recep@test.local', now(), 'authenticated', 'authenticated'),
    (u_p1, 'pat1@test.local', now(), 'authenticated', 'authenticated'),
    (u_p2, 'pat2@test.local', now(), 'authenticated', 'authenticated');
  INSERT INTO doctors (auth_id, name, first_name, last_name, email, hpcsa) VALUES (u_da, 'Dr. A Doc', 'A', 'Doc', 'dr.a@test.local', 'MP0001') RETURNING id INTO da;
  INSERT INTO doctors (auth_id, name, first_name, last_name, email) VALUES (u_db, 'Dr. B Doc', 'B', 'Doc', 'dr.b@test.local') RETURNING id INTO db;
  INSERT INTO doctors (auth_id, name, first_name, last_name, email) VALUES (u_rc, 'Recep One', 'Recep', 'One', 'recep@test.local') RETURNING id INTO rc;
  INSERT INTO practices (name) VALUES ('Test Practice') RETURNING id INTO prac;
  INSERT INTO practice_members (practice_id, doctor_id, role, status) VALUES (prac, da, 'owner', 'active'), (prac, rc, 'receptionist', 'active');

  -- 1. Doctor A invites pat1 by email before pat1 has a profile
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_da, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_da::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  req := request_patient_access('Pat1@Test.local', NULL);
  tok := req->>'token';
  res := res || E'\n' || CASE WHEN req->>'status' = 'pending' AND length(tok) = 64 THEN 'PASS' ELSE 'FAIL' END || ' 1 email invite created (pending, 64-char token)';

  -- 2. Signed-out visitor can read the link details, but not call internal functions
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  EXECUTE 'SET LOCAL ROLE anon';
  SELECT count(*) INTO n FROM get_access_link(tok);
  res := res || E'\n' || CASE WHEN n = 1 THEN 'PASS' ELSE 'FAIL' END || ' 2a anon can read link details with the token';
  SELECT count(*) INTO n FROM get_access_link('not-a-token');
  res := res || E'\n' || CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END || ' 2b anon gets nothing for a wrong token';
  BEGIN
    PERFORM request_patient_access('x@test.local', NULL);
    res := res || E'\nFAIL 2c anon could call request_patient_access';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 2c anon blocked from request_patient_access';
  END;
  BEGIN
    PERFORM my_doctor_id();
    res := res || E'\nFAIL 2d anon could call my_doctor_id';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 2d anon blocked from my_doctor_id';
  END;

  -- 3. pat1 creates a profile; the waiting request appears; direct table tricks are blocked
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_p1, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_p1::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  pid := create_my_profile('Pat', 'One', '082 123 4567', '1990-01-01');
  SELECT count(*), max(access_status), max(access_id::text) INTO n, s, link_token FROM list_my_access();
  aid := link_token::uuid;
  res := res || E'\n' || CASE WHEN n = 1 AND s = 'pending' THEN 'PASS' ELSE 'FAIL' END || ' 3a email request attached to the new profile (' || n || ' ' || coalesce(s, 'none') || ')';
  BEGIN
    INSERT INTO patient_accounts (auth_id, patient_id) VALUES (u_p1, gen_random_uuid());
    res := res || E'\nFAIL 3b patient could insert patient_accounts directly';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 3b direct patient_accounts insert blocked';
  END;
  UPDATE patients SET doctor_id = da WHERE id = pid;
  GET DIAGNOSTICS n = ROW_COUNT;
  res := res || E'\n' || CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END || ' 3c patient cannot set their own doctor_id directly';
  BEGIN
    PERFORM update_my_profile('{"doctor_id":"00000000-0000-0000-0000-000000000000"}'::jsonb);
    res := res || E'\nFAIL 3d update_my_profile accepted doctor_id';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 3d update_my_profile rejects doctor_id';
  END;
  PERFORM update_my_profile('{"allergies":"Penicillin","chronic":"Asthma"}'::jsonb);
  SELECT count(*) INTO n FROM patients WHERE id = pid;
  res := res || E'\n' || CASE WHEN n = 1 THEN 'PASS' ELSE 'FAIL' END || ' 3e patient reads own profile';

  -- 4. Before approval, doctor A sees nothing and cannot write
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_da, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_da::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM patients WHERE id = pid;
  res := res || E'\n' || CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END || ' 4a doctor cannot read the profile before approval';
  BEGIN
    INSERT INTO records (doctor_id, patient_id, visit_date, diagnosis) VALUES (da, pid, current_date, 'Test');
    res := res || E'\nFAIL 4b doctor wrote a record before approval';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 4b record write blocked before approval';
  END;

  -- 5. Patient approves
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_p1, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_p1::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  s := respond_access_request(aid, true);
  res := res || E'\n' || CASE WHEN s = 'approved' THEN 'PASS' ELSE 'FAIL' END || ' 5 patient approved';

  -- 6. After approval, doctor A can read and write; the patient sees the record
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_da, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_da::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM patients WHERE id = pid;
  res := res || E'\n' || CASE WHEN n = 1 THEN 'PASS' ELSE 'FAIL' END || ' 6a doctor reads the approved profile';
  SELECT count(*) INTO n FROM patients WHERE id = pid AND allergies = 'Penicillin';
  res := res || E'\n' || CASE WHEN n = 1 THEN 'PASS' ELSE 'FAIL' END || ' 6b doctor sees the patient-entered allergies';
  INSERT INTO records (doctor_id, patient_id, visit_date, diagnosis) VALUES (da, pid, current_date, 'Test visit');
  SELECT count(*) INTO n FROM records WHERE patient_id = pid;
  res := res || E'\n' || CASE WHEN n = 1 THEN 'PASS' ELSE 'FAIL' END || ' 6c doctor wrote and reads the record';
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_p1, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_p1::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM records WHERE patient_id = pid;
  res := res || E'\n' || CASE WHEN n = 1 THEN 'PASS' ELSE 'FAIL' END || ' 6d patient reads their own record';

  -- 7. A different doctor and the receptionist get nothing
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_db, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_db::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM patients WHERE id = pid;
  res := res || E'\n' || CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END || ' 7a other doctor cannot read the profile';
  SELECT count(*) INTO n FROM records WHERE patient_id = pid;
  res := res || E'\n' || CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END || ' 7b other doctor cannot read records';
  BEGIN
    INSERT INTO records (doctor_id, patient_id, visit_date, diagnosis) VALUES (db, pid, current_date, 'Intrusion');
    res := res || E'\nFAIL 7c other doctor wrote a record';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 7c other doctor cannot write a record';
  END;
  BEGIN
    PERFORM request_patient_access('z@test.local', NULL, da);
    res := res || E'\nFAIL 7d a doctor requested access on behalf of another doctor';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 7d a doctor cannot send requests for another doctor';
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_rc, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_rc::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM records WHERE patient_id = pid;
  res := res || E'\n' || CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END || ' 7e receptionist cannot read records';
  SELECT count(*) INTO n FROM patients WHERE id = pid;
  res := res || E'\n' || CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END || ' 7f receptionist cannot read a patient-owned profile';
  req2 := request_patient_access(NULL, '083 111 2222', da);
  res := res || E'\n' || CASE WHEN req2->>'status' = 'pending' THEN 'PASS' ELSE 'FAIL' END || ' 7g receptionist can invite by phone for their doctor';
  SELECT count(*) INTO n FROM list_access_requests();
  res := res || E'\n' || CASE WHEN n = 2 THEN 'PASS' ELSE 'FAIL' END || ' 7h receptionist sees the practice requests (' || n || ')';
  SELECT patient_name INTO s FROM list_access_requests() WHERE access_status = 'approved';
  res := res || E'\n' || CASE WHEN s = 'Pat One' THEN 'PASS' ELSE 'FAIL' END || ' 7i patient name is shown once approved';
  req := request_patient_access(NULL, '+27 83 111 2222', da);
  res := res || E'\n' || CASE WHEN req->>'id' = req2->>'id' THEN 'PASS' ELSE 'FAIL' END || ' 7j same phone reuses the open request';
  BEGIN
    PERFORM request_patient_access('self@test.local', NULL);
    res := res || E'\nFAIL 7k receptionist created a request for themselves';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 7k receptionist cannot request access for themselves (must pick a doctor)';
  END;
  BEGIN
    PERFORM request_patient_access('self@test.local', NULL, rc);
    res := res || E'\nFAIL 7l receptionist named themselves as the doctor';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 7l receptionist cannot name themselves as the doctor';
  END;

  -- 8. Phone link: a second patient opens it and attaches it to their profile (does not approve)
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_da, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_da::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO patients (doctor_id, first_name, last_name) VALUES (da, 'Walk', 'In') RETURNING id INTO walk;
  req := invite_patient_to_claim(walk, NULL, '0834445555');
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_p2, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_p2::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  pid2 := accept_patient_invite(req->>'token');
  res := res || E'\n' || CASE WHEN pid2 = walk THEN 'PASS' ELSE 'FAIL' END || ' 8a walk-in profile claimed through a phone-only invite';
  PERFORM accept_access_link(req2->>'token');
  SELECT count(*), max(access_status) INTO n, s FROM list_my_access();
  res := res || E'\n' || CASE WHEN n = 1 AND s = 'pending' THEN 'PASS' ELSE 'FAIL' END || ' 8b phone link attached as pending, not approved (' || n || ' ' || coalesce(s, 'none') || ')';

  -- 9. Revoke: access ends, the author keeps their own note but cannot add more
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_p1, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_p1::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM revoke_access(aid);
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_da, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_da::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM patients WHERE id = pid;
  res := res || E'\n' || CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END || ' 9a doctor loses the profile after revoke';
  SELECT count(*) INTO n FROM records WHERE patient_id = pid;
  res := res || E'\n' || CASE WHEN n = 1 THEN 'PASS' ELSE 'FAIL' END || ' 9b author still reads their own note';
  BEGIN
    INSERT INTO records (doctor_id, patient_id, visit_date, diagnosis) VALUES (da, pid, current_date, 'After revoke');
    res := res || E'\nFAIL 9c doctor wrote a record after revoke';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 9c record write blocked after revoke';
  END;
  SELECT count(*) INTO n FROM patients WHERE id = walk;
  res := res || E'\n' || CASE WHEN n = 1 THEN 'PASS' ELSE 'FAIL' END || ' 9d creating doctor keeps access to their own walk-in patient';

  RAISE EXCEPTION E'TEST RESULTS:%', res;
END
$test$;
