-- Local test for popia_hardening.sql (after print_requests.sql). Ends with an error that carries the results; everything rolls back.
DO $test$
DECLARE
  res text := '';
  u_da uuid := gen_random_uuid(); u_db uuid := gen_random_uuid(); u_p1 uuid := gen_random_uuid(); u_p2 uuid := gen_random_uuid();
  da uuid; db uuid; p1 uuid; p2 uuid; rec uuid; n int; cfg text[];
BEGIN
  INSERT INTO auth.users (id,email,email_confirmed_at,aud,role) VALUES
    (u_da,'a@t.local',now(),'authenticated','authenticated'),(u_db,'b@t.local',now(),'authenticated','authenticated'),
    (u_p1,'p1@t.local',now(),'authenticated','authenticated'),(u_p2,'p2@t.local',now(),'authenticated','authenticated');
  INSERT INTO doctors (auth_id,name,first_name,last_name,email) VALUES (u_da,'Dr A','Ann','Doc','a@t.local') RETURNING id INTO da;
  INSERT INTO doctors (auth_id,name,first_name,last_name,email) VALUES (u_db,'Dr B','Bob','Doc','b@t.local') RETURNING id INTO db;
  INSERT INTO patients (doctor_id,first_name,last_name) VALUES (da,'Pat','One') RETURNING id INTO p1;
  INSERT INTO patients (doctor_id,first_name,last_name) VALUES (da,'Pat','Two') RETURNING id INTO p2;
  INSERT INTO patient_accounts (auth_id,patient_id) VALUES (u_p1,p1),(u_p2,p2);

  -- 1 doctor A writes a record: the database logs it with the doctor's identity
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_da,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_da::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  rec := (create_record(jsonb_build_object('patient_id',p1,'visit_date',current_date,'diagnosis','x')) ->> 'id')::uuid;
  EXECUTE 'RESET ROLE';
  UPDATE records SET notes='edited' WHERE id=rec;   -- claims still name doctor A, so the trigger logs them
  SELECT count(*) INTO n FROM access_log WHERE patient_id=p1 AND actor_doctor=da AND subject='record' AND action IN ('create','update');
  res := res || E'\n' || CASE WHEN n=2 THEN 'PASS' ELSE 'FAIL' END || ' 1 record create and update are logged with the doctor';

  -- 2 view logging: logged once, repeat within 10 minutes ignored
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_da,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_da::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM log_view(p1); PERFORM log_view(p1);
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO n FROM access_log WHERE patient_id=p1 AND action='view';
  res := res || E'\n' || CASE WHEN n=1 THEN 'PASS' ELSE 'FAIL' END || ' 2 a view is logged once within 10 minutes';

  -- 3 a doctor with no access cannot create view entries
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_db,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_db::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM log_view(p1);
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO n FROM access_log WHERE actor_doctor=db;
  res := res || E'\n' || CASE WHEN n=0 THEN 'PASS' ELSE 'FAIL' END || ' 3 a doctor without access cannot write log entries';

  -- 4 patient 1 sees their log, with the doctor name; patient 2 sees none of it
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_p1,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_p1::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM list_my_access_log() WHERE dr_name='Ann Doc';
  res := res || E'\n' || CASE WHEN n=3 THEN 'PASS' ELSE 'FAIL' END || ' 4 patient sees who created, changed and viewed their record';
  BEGIN PERFORM count(*) FROM access_log; res := res || E'\nFAIL 5 patient can read the log table directly'; EXCEPTION WHEN insufficient_privilege THEN res := res || E'\nPASS 5 log table cannot be read directly'; END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_p2,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_p2::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM list_my_access_log();
  res := res || E'\n' || CASE WHEN n=0 THEN 'PASS' ELSE 'FAIL' END || ' 6 another patient sees nothing of it';
  BEGIN DELETE FROM public.access_log; res := res || E'\nFAIL 7 patient deleted log rows'; EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 7 nobody can edit the log through the API'; END;
  EXECUTE 'RESET ROLE';

  -- 8 deleting is logged too (as the doctor); 9 anon cannot call log_view / list
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_da,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_da::text, true); DELETE FROM records WHERE id=rec;
  SELECT count(*) INTO n FROM access_log WHERE action='delete' AND subject_id=rec AND actor_doctor=da;
  res := res || E'\n' || CASE WHEN n=1 THEN 'PASS' ELSE 'FAIL' END || ' 8 deleting a record is logged';
  PERFORM set_config('request.jwt.claims','',true); PERFORM set_config('request.jwt.claim.sub','',true); EXECUTE 'SET LOCAL ROLE anon';
  BEGIN PERFORM log_view(p1); res := res || E'\nFAIL 9a anon can call log_view'; EXCEPTION WHEN insufficient_privilege THEN res := res || E'\nPASS 9a anon cannot call log_view'; END;
  BEGIN PERFORM * FROM list_my_access_log(); res := res || E'\nFAIL 9b anon can list the log'; EXCEPTION WHEN insufficient_privilege THEN res := res || E'\nPASS 9b anon cannot list the log'; END;

  -- 10 open practice insert is gone; 11 search paths pinned
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_p1,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_p1::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN INSERT INTO practices (name) VALUES ('junk'); res := res || E'\nFAIL 10 anyone can still create a practice'; EXCEPTION WHEN insufficient_privilege THEN res := res || E'\nPASS 10 direct practice creation is blocked'; END;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO n FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('get_next_ref','get_available_slots','seed_default_availability','set_updated_at') AND proconfig IS NOT NULL AND proconfig::text LIKE '%search_path%';
  res := res || E'\n' || CASE WHEN n=4 THEN 'PASS' ELSE 'FAIL' END || ' 11 search path pinned on all four functions';
  RAISE EXCEPTION 'TEST RESULTS:%', res;
END $test$;
