-- Local test for print_requests.sql (run after patient_access.sql). Ends with an error carrying the results, so everything rolls back.
DO $test$
DECLARE
  res text := '';
  u_da uuid := gen_random_uuid(); u_db uuid := gen_random_uuid(); u_rc uuid := gen_random_uuid();
  u_p1 uuid := gen_random_uuid(); u_p2 uuid := gen_random_uuid();
  da uuid; db uuid; rc uuid; prac uuid; p1 uuid; p2 uuid; sn uuid; rx uuid; rec uuid;
  r1 jsonb; r2 jsonb; n int; ok boolean; q record;
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at, aud, role) VALUES
    (u_da,'a@t.local',now(),'authenticated','authenticated'),(u_db,'b@t.local',now(),'authenticated','authenticated'),
    (u_rc,'r@t.local',now(),'authenticated','authenticated'),(u_p1,'p1@t.local',now(),'authenticated','authenticated'),
    (u_p2,'p2@t.local',now(),'authenticated','authenticated');
  INSERT INTO doctors (auth_id,name,first_name,last_name,email) VALUES (u_da,'Dr A','A','Doc','a@t.local') RETURNING id INTO da;
  INSERT INTO doctors (auth_id,name,first_name,last_name,email) VALUES (u_db,'Dr B','B','Doc','b@t.local') RETURNING id INTO db;
  INSERT INTO doctors (auth_id,name,first_name,last_name,email) VALUES (u_rc,'Recep','Recep','One','r@t.local') RETURNING id INTO rc;
  INSERT INTO practices (name) VALUES ('P') RETURNING id INTO prac;
  INSERT INTO practice_members (practice_id,doctor_id,role,status) VALUES (prac,da,'owner','active'),(prac,rc,'receptionist','active');
  INSERT INTO patients (doctor_id,first_name,last_name) VALUES (da,'Pat','One') RETURNING id INTO p1;
  INSERT INTO patients (doctor_id,first_name,last_name) VALUES (da,'Pat','Two') RETURNING id INTO p2;
  INSERT INTO patient_accounts (auth_id,patient_id) VALUES (u_p1,p1),(u_p2,p2);
  INSERT INTO sick_notes (doctor_id,patient_id,ref_number,issue_date,diagnosis) VALUES (da,p1,'SN-1',current_date,'Secret flu') RETURNING id INTO sn;
  INSERT INTO prescriptions (doctor_id,patient_id,ref_number,script_date) VALUES (da,p1,'RX-1',current_date) RETURNING id INTO rx;
  INSERT INTO records (doctor_id,patient_id,visit_date,diagnosis) VALUES (da,p1,current_date,'Secret dx') RETURNING id INTO rec;

  -- 1-2 patient 1 requests a print; asking twice returns the same request
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_p1,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_p1::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  r1 := request_print('sick_note', sn); r2 := request_print('sick_note', sn);
  res := res || E'\n' || CASE WHEN r1->>'status'='requested' THEN 'PASS' ELSE 'FAIL' END || ' 1 patient can request a print of their own sick note';
  res := res || E'\n' || CASE WHEN r1->>'id'=r2->>'id' THEN 'PASS' ELSE 'FAIL' END || ' 2 a repeat request reuses the open one';
  PERFORM request_print('prescription', rx); PERFORM request_print('record', rec);
  SELECT count(*) INTO n FROM list_my_print_requests();
  res := res || E'\n' || CASE WHEN n=3 THEN 'PASS' ELSE 'FAIL' END || ' 3 patient sees their 3 requests';
  BEGIN PERFORM request_print('invoice', sn); res := res || E'\nFAIL 4 unknown kind accepted';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 4 unknown kind rejected'; END;
  SELECT count(*) INTO n FROM print_requests;
  res := res || E'\n' || CASE WHEN n=0 THEN 'PASS' ELSE 'FAIL' END || ' 5 table cannot be read directly (RLS, no policies)';

  -- 6 patient 2 cannot request patient 1's documents, and sees none of their requests
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_p2,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_p2::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN PERFORM request_print('sick_note', sn); res := res || E'\nFAIL 6a another patient requested my document';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 6a another patient cannot request my document'; END;
  SELECT count(*) INTO n FROM list_my_print_requests();
  res := res || E'\n' || CASE WHEN n=0 THEN 'PASS' ELSE 'FAIL' END || ' 6b other patient sees none of my requests';
  BEGIN PERFORM cancel_print_request(r1->>'id'); res := res || E'\nFAIL 6c another patient cancelled my request';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 6c another patient cannot cancel my request'; END;

  -- 7 anon cannot call anything
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims','',true); PERFORM set_config('request.jwt.claim.sub','',true); EXECUTE 'SET LOCAL ROLE anon';
  BEGIN PERFORM request_print('sick_note', sn); res := res || E'\nFAIL 7a anon can request';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 7a anon cannot request'; END;
  BEGIN PERFORM * FROM list_print_requests(); res := res || E'\nFAIL 7b anon can list';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 7b anon cannot list the staff queue'; END;

  -- 8 doctor B (unrelated) sees nothing and cannot act
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_db,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_db::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM list_print_requests();
  res := res || E'\n' || CASE WHEN n=0 THEN 'PASS' ELSE 'FAIL' END || ' 8a unrelated doctor sees no requests';
  BEGIN PERFORM mark_print_request((r1->>'id')::uuid,'ready'); res := res || E'\nFAIL 8b unrelated doctor marked ready';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 8b unrelated doctor cannot mark requests'; END;

  -- 9 receptionist sees type, date, reference, and patient name; flow requested -> ready -> collected
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_rc,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_rc::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT * INTO q FROM list_print_requests() WHERE kind='sick_note';
  res := res || E'\n' || CASE WHEN q.doc_ref='SN-1' AND q.patient_name='Pat One' AND q.doc_date=current_date THEN 'PASS' ELSE 'FAIL' END || ' 9a receptionist sees reference, date and patient name';
  BEGIN PERFORM mark_print_request(q.id,'collected'); res := res || E'\nFAIL 9b collected before ready';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 9b cannot collect before it is ready'; END;
  PERFORM mark_print_request(q.id,'ready');
  PERFORM mark_print_request(q.id,'collected');
  BEGIN PERFORM mark_print_request(q.id,'ready'); res := res || E'\nFAIL 9c reopened a closed request';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 9c closed requests stay closed'; END;

  -- 10 doctor A sees all three (one closed, kept 7 days), then patient cancels a still-open one
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_da,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_da::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM list_print_requests();
  res := res || E'\n' || CASE WHEN n=3 THEN 'PASS' ELSE 'FAIL' END || ' 10 doctor sees all requests for their patients';
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_p1,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_p1::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT id INTO q FROM list_my_print_requests() WHERE kind='prescription';
  PERFORM cancel_print_request(q.id);
  SELECT count(*) INTO n FROM list_my_print_requests() WHERE status='cancelled';
  res := res || E'\n' || CASE WHEN n=1 THEN 'PASS' ELSE 'FAIL' END || ' 11 patient can cancel a request that is still waiting';
  SELECT id INTO q FROM list_my_print_requests() WHERE kind='sick_note';
  BEGIN PERFORM cancel_print_request(q.id); res := res || E'\nFAIL 12 cancelled a collected request';
  EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 12 cannot cancel after collection'; END;
  -- 13 after the patient is done, a new request for the same document is allowed again
  r1 := request_print('sick_note', sn);
  res := res || E'\n' || CASE WHEN r1->>'status'='requested' THEN 'PASS' ELSE 'FAIL' END || ' 13 a new request is allowed once the old one is closed';

  EXECUTE 'RESET ROLE';
  RAISE EXCEPTION 'TEST RESULTS:%', res;
END $test$;
