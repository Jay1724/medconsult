-- run after find_doctor.sql on the full local stack
DO $test$
DECLARE res text := ''; u_d uuid := gen_random_uuid(); u_d2 uuid := gen_random_uuid(); u_o uuid := gen_random_uuid(); u_p uuid := gen_random_uuid(); u_q uuid := gen_random_uuid();
  d uuid; d2 uuid; o uuid; prac uuid; prac2 uuid; p uuid; q uuid; j jsonb; n int; day date; appt uuid; ok boolean;
BEGIN
  INSERT INTO auth.users (id,email,email_confirmed_at,aud,role) VALUES (u_d,'d@t.local',now(),'authenticated','authenticated'),(u_d2,'d2@t.local',now(),'authenticated','authenticated'),(u_o,'o@t.local',now(),'authenticated','authenticated'),(u_p,'p@t.local',now(),'authenticated','authenticated'),(u_q,'q@t.local',now(),'authenticated','authenticated');
  INSERT INTO doctors (auth_id,name,first_name,last_name,email,spec) VALUES (u_d,'D','Ann','Near','d@t.local','General Practitioner') RETURNING id INTO d;
  INSERT INTO doctors (auth_id,name,first_name,last_name,email,spec) VALUES (u_d2,'D2','Bob','Far','d2@t.local','Paediatrician') RETURNING id INTO d2;
  INSERT INTO doctors (auth_id,name,first_name,last_name,email,spec) VALUES (u_o,'O','Cy','Hidden','o@t.local','General Practitioner') RETURNING id INTO o;
  INSERT INTO practices (name,address,suburb,city,lat,lng) VALUES ('Near Clinic','1 Main','Roodepoort','Johannesburg',-26.12,27.90) RETURNING id INTO prac;
  INSERT INTO practice_members (practice_id,doctor_id,role) VALUES (prac,d,'owner');
  INSERT INTO practices (name,address,suburb,city,lat,lng) VALUES ('Far Clinic','9 Far','Sandton','Johannesburg',-26.10,28.05) RETURNING id INTO prac2;
  INSERT INTO practice_members (practice_id,doctor_id,role) VALUES (prac2,d2,'owner');
  INSERT INTO patients (doctor_id,first_name,last_name) VALUES (NULL,'Pat','One') RETURNING id INTO p;
  INSERT INTO patients (doctor_id,first_name,last_name) VALUES (NULL,'Quin','Two') RETURNING id INTO q;
  INSERT INTO patient_accounts (auth_id,patient_id) VALUES (u_p,p),(u_q,q);
  -- Hidden doctor has hours but never opts in. Others opt in through the function.
  INSERT INTO availability (doctor_id,day_of_week,start_time,end_time,slot_minutes) SELECT o, g, '08:00','12:00',30 FROM generate_series(0,6) g;

  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_d,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_d::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_my_listing(true);
  EXECUTE 'RESET ROLE'; SELECT listed INTO ok FROM doctors WHERE id=d; SELECT count(*) INTO n FROM availability WHERE doctor_id=d;
  res := res||E'\n'||CASE WHEN ok AND n=5 THEN 'PASS' ELSE 'FAIL' END||' 1 listing on seeds default hours when none exist';
  -- make hours available every day for deterministic tests, and list d2
  DELETE FROM availability WHERE doctor_id=d;
  INSERT INTO availability (doctor_id,day_of_week,start_time,end_time,slot_minutes) SELECT d, g, '00:00','23:30',30 FROM generate_series(0,6) g;
  INSERT INTO availability (doctor_id,day_of_week,start_time,end_time,slot_minutes) SELECT d2, g, '09:00','11:00',30 FROM generate_series(0,6) g; UPDATE doctors SET listed=true WHERE id=d2;

  -- patient searches near Roodepoort
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_p,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_p::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  j := search_doctors(NULL, -26.12, 27.91, NULL);
  res := res||E'\n'||CASE WHEN jsonb_array_length(j)=2 AND j->0->>'name'='Dr Ann Near' AND (j->0->>'distance_km')::float < (j->1->>'distance_km')::float THEN 'PASS' ELSE 'FAIL '||j::text END||' 2 search lists only opted-in doctors, nearest first';
  res := res||E'\n'||CASE WHEN jsonb_array_length(j->0->'next_slots')=3 THEN 'PASS' ELSE 'FAIL' END||' 3 each result carries its next three open slots';
  j := search_doctors('Paediatrician', NULL, NULL, NULL);
  res := res||E'\n'||CASE WHEN jsonb_array_length(j)=1 AND j->0->>'name'='Dr Bob Far' THEN 'PASS' ELSE 'FAIL' END||' 4 filter by doctor type';
  j := search_doctors(NULL, NULL, NULL, 'sandton');
  res := res||E'\n'||CASE WHEN jsonb_array_length(j)=1 THEN 'PASS' ELSE 'FAIL' END||' 5 filter by suburb or town text';
  res := res||E'\n'||CASE WHEN list_specialities() @> ARRAY['Paediatrician','General Practitioner'] AND NOT (list_specialities() @> ARRAY['x']) THEN 'PASS' ELSE 'FAIL' END||' 6 speciality list comes from listed doctors';
  -- booking
  j := search_doctors('General Practitioner', NULL, NULL, NULL);
  day := (j->0->'next_slots'->0->>'date')::date;
  BEGIN PERFORM book_appointment(d, day, (j->0->'next_slots'->0->>'time')::time, 'cough', false); res:=res||E'\nFAIL 7 booked a new doctor without sharing'; EXCEPTION WHEN OTHERS THEN res:=res||E'\nPASS 7 a new doctor needs the patient to share their profile'; END;
  appt := book_appointment(d, day, (j->0->'next_slots'->0->>'time')::time, 'cough', true);
  EXECUTE 'RESET ROLE'; SELECT count(*) INTO n FROM patient_access WHERE patient_id=p AND doctor_id=d AND status='approved';
  res := res||E'\n'||CASE WHEN appt IS NOT NULL AND n=1 THEN 'PASS' ELSE 'FAIL' END||' 8 booking with sharing creates the appointment and the approved link';
  -- other patient: slot gone, cannot double book
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_q,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_q::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN PERFORM book_appointment(d, day, (j->0->'next_slots'->0->>'time')::time, NULL, true); res:=res||E'\nFAIL 9 double booked'; EXCEPTION WHEN OTHERS THEN res:=res||E'\nPASS 9 a taken slot cannot be booked again'; END;
  SELECT count(*) INTO n FROM get_available_slots(d, day) WHERE slot_time=(j->0->'next_slots'->0->>'time')::time;
  res := res||E'\n'||CASE WHEN n=0 THEN 'PASS' ELSE 'FAIL' END||' 10 another patient no longer sees that slot as free';
  BEGIN PERFORM book_appointment(o, day, '08:00', NULL, true); res:=res||E'\nFAIL 11 booked unlisted doctor'; EXCEPTION WHEN OTHERS THEN res:=res||E'\nPASS 11 an unlisted doctor cannot be booked'; END;
  BEGIN PERFORM book_appointment(d, current_date - 1, '09:00', NULL, true); res:=res||E'\nFAIL 12 booked the past'; EXCEPTION WHEN OTHERS THEN res:=res||E'\nPASS 12 past dates cannot be booked'; END;
  BEGIN INSERT INTO appointments (doctor_id,patient_id,appt_date,appt_time) VALUES (o,q,day,'09:00'); res:=res||E'\nFAIL 13 direct insert'; EXCEPTION WHEN OTHERS THEN res:=res||E'\nPASS 13 patients can no longer insert appointments directly'; END;
  -- my doctors
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_p,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_p::text, true);
  j := list_my_doctors();
  res := res||E'\n'||CASE WHEN jsonb_array_length(j)=1 AND j->0->>'access_status'='approved' AND j->0->'next_appt' IS NOT NULL AND (j->0->>'can_book')::boolean THEN 'PASS' ELSE 'FAIL '||j::text END||' 14 my doctors lists the booked doctor with the next appointment';
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_q,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_q::text, true);
  res := res||E'\n'||CASE WHEN jsonb_array_length(list_my_doctors())=0 THEN 'PASS' ELSE 'FAIL' END||' 15 another patient sees none of it';
  -- staff cannot search / anon
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_d,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_d::text, true);
  BEGIN PERFORM search_doctors(NULL,NULL,NULL,NULL); res:=res||E'\nFAIL 16 doctor searched'; EXCEPTION WHEN OTHERS THEN res:=res||E'\nPASS 16 only patients can search'; END;
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims','',true); PERFORM set_config('request.jwt.claim.sub','',true); EXECUTE 'SET LOCAL ROLE anon';
  BEGIN PERFORM search_doctors(NULL,NULL,NULL,NULL); res:=res||E'\nFAIL 17 anon'; EXCEPTION WHEN insufficient_privilege THEN res:=res||E'\nPASS 17 anon cannot search'; END;
  -- owner sets location; non owner cannot
  EXECUTE 'RESET ROLE'; PERFORM set_config('request.jwt.claims', json_build_object('sub',u_d,'role','authenticated')::text, true); PERFORM set_config('request.jwt.claim.sub', u_d::text, true); EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_practice_location(prac,'Wilgeheuwel','Roodepoort',-26.1,27.9);
  BEGIN PERFORM set_practice_location(prac2,'x','y',NULL,NULL); res:=res||E'\nFAIL 18 set another practice'; EXCEPTION WHEN OTHERS THEN res:=res||E'\nPASS 18 only an owner can set their own practice location'; END;
  RAISE EXCEPTION 'TEST RESULTS:%', res;
END $test$;
