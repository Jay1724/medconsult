-- needs stubs for auth.jwt() and auth.mfa_factors (they exist on Supabase itself)
CREATE TABLE IF NOT EXISTS auth.mfa_factors (id uuid DEFAULT gen_random_uuid(), user_id uuid, status text, factor_type text DEFAULT 'totp');
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated; GRANT EXECUTE ON FUNCTION auth.jwt() TO anon, authenticated;
\i staff_mfa.sql
DO $test$
DECLARE res text := ''; u_d uuid := gen_random_uuid(); u_p uuid := gen_random_uuid(); u_n uuid := gen_random_uuid(); d uuid; p uuid; n int;
BEGIN
  INSERT INTO auth.users (id,email,email_confirmed_at,aud,role) VALUES (u_d,'d@t.local',now(),'authenticated','authenticated'),(u_p,'p@t.local',now(),'authenticated','authenticated'),(u_n,'n@t.local',now(),'authenticated','authenticated');
  INSERT INTO doctors (auth_id,name,first_name,last_name,email) VALUES (u_d,'D','D','Doc','d@t.local') RETURNING id INTO d;
  INSERT INTO doctors (auth_id,name,first_name,last_name,email) VALUES (u_n,'N','N','Doc','n@t.local');
  INSERT INTO patients (doctor_id,first_name,last_name) VALUES (d,'Pat','One') RETURNING id INTO p;
  INSERT INTO patient_accounts (auth_id,patient_id) VALUES (u_p,p);
  INSERT INTO auth.mfa_factors (user_id,status) VALUES (u_d,'verified');

  -- 1 enrolled doctor, password-only session (aal1): sees nothing
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_d,'role','authenticated','aal','aal1')::text, true); PERFORM set_config('request.jwt.claim.sub', u_d::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM patients;
  res := res || E'\n' || CASE WHEN n=0 THEN 'PASS' ELSE 'FAIL' END || ' 1 enrolled doctor with a password-only session sees no patients';
  BEGIN PERFORM create_record(jsonb_build_object('patient_id',p,'visit_date',current_date,'diagnosis','x')); res := res || E'\nFAIL 2 aal1 write allowed'; EXCEPTION WHEN OTHERS THEN res := res || E'\nPASS 2 and cannot write records either'; END;
  -- 3 same doctor after the code (aal2)
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_d,'role','authenticated','aal','aal2')::text, true);
  SELECT count(*) INTO n FROM patients;
  res := res || E'\n' || CASE WHEN n=1 THEN 'PASS' ELSE 'FAIL' END || ' 3 after the second step the doctor sees their patient';
  PERFORM create_record(jsonb_build_object('patient_id',p,'visit_date',current_date,'diagnosis','x'));
  res := res || E'\nPASS 4 and can write';
  -- 5 a doctor who has not enrolled is unaffected while the switch is off
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_n,'role','authenticated','aal','aal1')::text, true); PERFORM set_config('request.jwt.claim.sub', u_n::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  res := res || E'\n' || CASE WHEN mfa_ok() THEN 'PASS' ELSE 'FAIL' END || ' 5 not-enrolled staff are not locked out while the switch is off';
  -- 6 switch on: staff without a factor are locked out; patients are not
  EXECUTE 'RESET ROLE'; UPDATE app_settings SET value='true' WHERE key='mfa_required_for_staff'; EXECUTE 'SET LOCAL ROLE authenticated';
  res := res || E'\n' || CASE WHEN NOT mfa_ok() THEN 'PASS' ELSE 'FAIL' END || ' 6 with the switch on, staff without a second factor are locked out';
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_p,'role','authenticated','aal','aal1')::text, true); PERFORM set_config('request.jwt.claim.sub', u_p::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  res := res || E'\n' || CASE WHEN mfa_ok() THEN 'PASS' ELSE 'FAIL' END || ' 7 patients are never affected by the staff switch';
  SELECT count(*) INTO n FROM records WHERE patient_id=p;
  res := res || E'\n' || CASE WHEN n=1 THEN 'PASS' ELSE 'FAIL' END || ' 8 a patient still reads their own record';
  -- 9 anon blocked from function, settings table unreadable
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims','',true); PERFORM set_config('request.jwt.claim.sub','',true); EXECUTE 'SET LOCAL ROLE anon';
  BEGIN PERFORM mfa_ok(); res := res || E'\nFAIL 9 anon can call mfa_ok'; EXCEPTION WHEN insufficient_privilege THEN res := res || E'\nPASS 9 anon cannot call mfa_ok'; END;
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_p,'role','authenticated')::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN PERFORM count(*) FROM app_settings; res := res || E'\nFAIL 10 settings readable'; EXCEPTION WHEN insufficient_privilege THEN res := res || E'\nPASS 10 settings table cannot be read through the API'; END;
  RAISE EXCEPTION 'TEST RESULTS:%', res;
END $test$;
