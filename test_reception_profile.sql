-- ─────────────────────────────────────────────────────────────────────────────
-- MedConsult — Test receptionist profile (for trying out reception.html)
--
-- Before running:
--   1. Supabase Dashboard → Authentication → Users → Add user → Create new user
--      Email:    reception.test@medconsult.africa   (or change it below)
--      Password: choose one
--      Tick Auto Confirm User
--   2. Run practice_access.sql and medical_aid_workflow.sql (already done).
--   3. Run this script. Safe to run more than once.
--
-- Creates (or reuses):
--   • practice   MedConsult Test Practice
--   • doctor     Dr. Test Doctor (owner, no login)
--   • reception  profile + membership for the login above
--   • 4 patients covering each medical aid state, emails @medconsult.test
--   • 3 appointments today
--
-- To remove everything again, run test_reception_cleanup.sql.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  -- Change this if you used a different email in step 1
  rec_email   text := 'reception.test@medconsult.africa';

  rec_auth    uuid;
  rec_doc     uuid;
  test_doc    uuid;
  prac        uuid;
  p1 uuid; p2 uuid; p3 uuid; p4 uuid;
BEGIN
  SELECT id INTO rec_auth FROM auth.users WHERE lower(email) = lower(rec_email);
  IF rec_auth IS NULL THEN
    RAISE EXCEPTION 'No login found for %. Create it first under Authentication → Users → Add user.', rec_email;
  END IF;

  -- Practice
  SELECT id INTO prac FROM practices WHERE name = 'MedConsult Test Practice' LIMIT 1;
  IF prac IS NULL THEN
    INSERT INTO practices (name, address, phone, email, plan, status, trial_ends_at, billing_email)
    VALUES ('MedConsult Test Practice', '1 Test Street, Johannesburg, 2000', '011 000 0000',
            'practice@medconsult.test', 'practice', 'active', now() + interval '30 days', 'practice@medconsult.test')
    RETURNING id INTO prac;
  END IF;

  -- Test doctor (owner, no login)
  SELECT id INTO test_doc FROM doctors WHERE email = 'doctor@medconsult.test' LIMIT 1;
  IF test_doc IS NULL THEN
    INSERT INTO doctors (first_name, last_name, name, email, spec, hpcsa, prac_name)
    VALUES ('Test', 'Doctor', 'Dr. Test Doctor', 'doctor@medconsult.test', 'General Practitioner', 'MP0000000', 'MedConsult Test Practice')
    RETURNING id INTO test_doc;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM practice_members WHERE practice_id = prac AND doctor_id = test_doc) THEN
    INSERT INTO practice_members (practice_id, doctor_id, role, status, invite_email, joined_at)
    VALUES (prac, test_doc, 'owner', 'active', 'doctor@medconsult.test', now());
  END IF;

  -- Receptionist profile + membership for the login
  SELECT id INTO rec_doc FROM doctors WHERE auth_id = rec_auth ORDER BY created_at LIMIT 1;
  IF rec_doc IS NULL THEN
    INSERT INTO doctors (auth_id, first_name, last_name, name, email, spec)
    VALUES (rec_auth, 'Test', 'Receptionist', 'Test Receptionist', rec_email, 'Receptionist')
    RETURNING id INTO rec_doc;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM practice_members WHERE practice_id = prac AND doctor_id = rec_doc) THEN
    INSERT INTO practice_members (practice_id, doctor_id, role, status, invite_email, joined_at)
    VALUES (prac, rec_doc, 'receptionist', 'active', rec_email, now());
  ELSE
    UPDATE practice_members SET role = 'receptionist', status = 'active'
    WHERE practice_id = prac AND doctor_id = rec_doc;
  END IF;

  -- Patients (only created once)
  IF NOT EXISTS (SELECT 1 FROM patients WHERE doctor_id = test_doc AND email LIKE '%@medconsult.test') THEN
    -- Unverified medical aid, valid SA ID
    INSERT INTO patients (doctor_id, first_name, last_name, dob, id_number, gender, phone, email, address,
                          aid_provider, aid_number, aid_plan, aid_status, aid_dependant_code)
    VALUES (test_doc, 'Thabo', 'Mokoena', '1980-01-01', '8001015009087', 'Male', '082 000 0001', 'thabo@medconsult.test',
            '12 Oak Street, Johannesburg', 'Discovery Health Medical Scheme', '80045123', 'Classic Comprehensive', 'unverified', '00')
    RETURNING id INTO p1;

    -- Verified 45 days ago (shows Re-check due), dependant with a mistyped ID
    INSERT INTO patients (doctor_id, first_name, last_name, dob, id_number, gender, phone, email,
                          aid_provider, aid_number, aid_plan, principal, aid_dependant_code,
                          aid_status, aid_checked_at, aid_checked_by, aid_check_method, aid_check_ref)
    VALUES (test_doc, 'Sarah', 'Naidoo', '1992-02-20', '9202204720082', 'Female', '082 000 0002', 'sarah@medconsult.test',
            'Government Employees Medical Scheme (GEMS)', '1234567', 'Emerald', 'Raj Naidoo', '01',
            'verified', now() - interval '45 days', 'Test Receptionist', 'phone', 'GEMS-REF-001')
    RETURNING id INTO p2;

    -- Verified today
    INSERT INTO patients (doctor_id, first_name, last_name, dob, id_number, gender, phone, email,
                          aid_provider, aid_number, aid_plan, aid_dependant_code,
                          aid_status, aid_checked_at, aid_checked_by, aid_check_method, aid_check_ref)
    VALUES (test_doc, 'Lindiwe', 'Dube', '1992-02-20', '9202204720083', 'Female', '082 000 0003', 'lindiwe@medconsult.test',
            'Bonitas Medical Fund', '7654321', 'BonClassic', '00',
            'verified', now(), 'Test Receptionist', 'portal', 'BON-778812')
    RETURNING id INTO p3;

    -- Self-pay (no medical aid)
    INSERT INTO patients (doctor_id, first_name, last_name, phone, email)
    VALUES (test_doc, 'Pieter', 'Botha', '082 000 0004', 'pieter@medconsult.test')
    RETURNING id INTO p4;

    -- Check history for the verified patients
    INSERT INTO medical_aid_checks (patient_id, status, method, reference, checked_by, created_at)
    VALUES (p2, 'verified', 'phone',  'GEMS-REF-001', 'Test Receptionist', now() - interval '45 days'),
           (p3, 'verified', 'portal', 'BON-778812',   'Test Receptionist', now());

    -- Appointments today
    INSERT INTO appointments (doctor_id, patient_id, practice_id, appt_date, appt_time, duration_min, type, status, reason, booked_by)
    VALUES (test_doc, p1, prac, current_date, '09:00', 15, 'consultation', 'confirmed', 'Follow-up',         'reception'),
           (test_doc, p2, prac, current_date, '10:30', 15, 'consultation', 'confirmed', 'Asthma review',     'reception'),
           (test_doc, p4, prac, current_date, '14:00', 15, 'consultation', 'confirmed', 'General check-up',  'reception');
  END IF;

  RAISE NOTICE 'Test receptionist ready: sign in at reception.html as %', rec_email;
END $$;
