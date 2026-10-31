-- run on a database that already has base schema, patient_access, practice_access, popia_hardening, staff_mfa, clinical_reads
DO $test$
DECLARE res text := ''; u_d uuid := gen_random_uuid(); u_o uuid := gen_random_uuid(); u_r uuid := gen_random_uuid(); u_p uuid := gen_random_uuid();
  d uuid; o uuid; r uuid; p uuid; p2 uuid; prac uuid; n int; j jsonb; rid uuid; sid uuid; xid uuid; ref1 text; ref2 text;
BEGIN
  INSERT INTO auth.users (id,email,email_confirmed_at,aud,role) VALUES (u_d,'d@t.local',now(),'authenticated','authenticated'),(u_o,'o@t.local',now(),'authenticated','authenticated'),(u_r,'r@t.local',now(),'authenticated','authenticated'),(u_p,'p@t.local',now(),'authenticated','authenticated');
  INSERT INTO doctors (auth_id,name,first_name,last_name,email) VALUES (u_d,'D','D','Doc','d@t.local') RETURNING id INTO d;
  INSERT INTO doctors (auth_id,name,first_name,last_name,email) VALUES (u_o,'O','O','Other','o@t.local') RETURNING id INTO o;
  INSERT INTO doctors (auth_id,name,first_name,last_name,email) VALUES (u_r,'R','R','Recep','r@t.local') RETURNING id INTO r;
  INSERT INTO practices (name) VALUES ('P') RETURNING id INTO prac;
  INSERT INTO practice_members (practice_id,doctor_id,role) VALUES (prac,d,'owner'),(prac,r,'receptionist');
  INSERT INTO patients (doctor_id,first_name,last_name) VALUES (d,'Pat','One') RETURNING id INTO p;
  INSERT INTO patients (doctor_id,first_name,last_name) VALUES (o,'Pat','Two') RETURNING id INTO p2;
  INSERT INTO patient_accounts (auth_id,patient_id) VALUES (u_p,p);

  -- doctor, second step done
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_d,'role','authenticated','aal','aal2')::text, true); PERFORM set_config('request.jwt.claim.sub', u_d::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  j := create_record(jsonb_build_object('patient_id',p,'visit_date',current_date,'diagnosis','Flu','notes','rest'));
  rid := (j->>'id')::uuid;
  j := create_sick_note(jsonb_build_object('patient_id',p,'issue_date',current_date,'diagnosis','Flu')); sid := (j->>'id')::uuid; ref1 := j->>'ref_number';
  j := create_sick_note(jsonb_build_object('patient_id',p,'issue_date',current_date,'diagnosis','Flu')); ref2 := j->>'ref_number';
  res := res || E'\n' || CASE WHEN ref1='SN-2401' AND ref2='SN-2402' THEN 'PASS' ELSE 'FAIL '||ref1||ref2 END || ' 1 reference numbers are made by the database, in order';
  j := create_prescription(jsonb_build_object('patient_id',p,'script_date',current_date,'medications','[{"name":"X"}]'::jsonb)); xid := (j->>'id')::uuid;
  res := res || E'\n' || CASE WHEN j->>'ref_number'='RX-3301' THEN 'PASS' ELSE 'FAIL' END || ' 2 prescription reference starts at RX-3301';
  j := get_patient_file(p);
  res := res || E'\n' || CASE WHEN jsonb_array_length(j->'records')=1 AND jsonb_array_length(j->'sick_notes')=2 AND jsonb_array_length(j->'prescriptions')=1 THEN 'PASS' ELSE 'FAIL' END || ' 3 doctor reads the full file through the function';
  PERFORM get_document('sick_note', sid); PERFORM get_document('sick_note', sid);
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO n FROM access_log WHERE patient_id=p AND action='view' AND subject='patient';
  res := res || E'\n' || CASE WHEN n=1 THEN 'PASS' ELSE 'FAIL '||n END || ' 4 opening the file is logged once';
  SELECT count(*) INTO n FROM access_log WHERE patient_id=p AND action='view' AND subject='sick_note' AND subject_id=sid;
  res := res || E'\n' || CASE WHEN n=1 THEN 'PASS' ELSE 'FAIL '||n END || ' 5 opening one document is logged once even if opened twice';
  -- direct table reads / writes are closed
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM records; res := res || E'\n' || CASE WHEN n=0 THEN 'PASS' ELSE 'FAIL' END || ' 6 doctor cannot read records straight from the table';
  SELECT count(*) INTO n FROM sick_notes; SELECT n + count(*) INTO n FROM prescriptions;
  res := res || E'\n' || CASE WHEN n=0 THEN 'PASS' ELSE 'FAIL' END || ' 7 nor sick notes or prescriptions';
  BEGIN INSERT INTO records (doctor_id,patient_id,visit_date,diagnosis) VALUES (d,p,current_date,'x'); res := res || E'\nFAIL 8 direct insert allowed'; EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 8 doctor cannot insert straight into the table'; END;
  BEGIN PERFORM create_record(jsonb_build_object('patient_id',p2,'visit_date',current_date,'diagnosis','x')); res := res || E'\nFAIL 9 wrote to a stranger'; EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 9 cannot write for a patient who has not approved'; END;
  BEGIN PERFORM get_patient_file(p2); res := res || E'\nFAIL 10 read a stranger'; EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 10 cannot read a patient who has not approved'; END;
  j := list_my_documents('sick_note');
  res := res || E'\n' || CASE WHEN jsonb_array_length(j)=2 AND NOT (j->0 ? 'diagnosis') THEN 'PASS' ELSE 'FAIL' END || ' 11 issue list has no diagnosis';
  j := list_my_documents('prescription');
  res := res || E'\n' || CASE WHEN jsonb_array_length(j)=1 AND NOT (j->0 ? 'medications') THEN 'PASS' ELSE 'FAIL' END || ' 12 prescription list has no medicines';
  -- password-only session
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_d,'role','authenticated','aal','aal1')::text, true);
  EXECUTE 'RESET ROLE'; INSERT INTO auth.mfa_factors (user_id,status) VALUES (u_d,'verified'); EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN PERFORM get_patient_file(p); res := res || E'\nFAIL 13 aal1 read'; EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 13 enrolled doctor without the code is refused'; END;
  -- front desk
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_r,'role','authenticated','aal','aal1')::text, true); PERFORM set_config('request.jwt.claim.sub', u_r::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN PERFORM get_patient_file(p); res := res || E'\nFAIL 14 receptionist read'; EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 14 receptionist cannot open clinical records'; END;
  j := list_my_documents('sick_note');
  res := res || E'\n' || CASE WHEN jsonb_array_length(j)=0 THEN 'PASS' ELSE 'FAIL' END || ' 15 receptionist gets an empty issue list';
  -- patient
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_p,'role','authenticated','aal','aal1')::text, true); PERFORM set_config('request.jwt.claim.sub', u_p::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM records WHERE patient_id=p; res := res || E'\n' || CASE WHEN n=1 THEN 'PASS' ELSE 'FAIL' END || ' 16 patient still reads their own record directly';
  BEGIN PERFORM get_patient_file(p); res := res || E'\nFAIL 17 patient called doctor function'; EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 17 patient cannot use the doctor functions'; END;
  -- anon
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims','',true); PERFORM set_config('request.jwt.claim.sub','',true); EXECUTE 'SET LOCAL ROLE anon';
  BEGIN PERFORM get_patient_file(p); res := res || E'\nFAIL 18 anon'; EXCEPTION WHEN insufficient_privilege THEN res := res || E'\nPASS 18 anon cannot call'; END;
  RAISE EXCEPTION 'TEST RESULTS:%', res;
END $test$;
