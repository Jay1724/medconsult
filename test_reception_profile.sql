-- ─────────────────────────────────────────────────────────────────────────────
-- MedConsult — Test receptionist profile (for trying out reception.html)
--
-- Before running:
--   1. Supabase Dashboard → Authentication → Users → Add user → Create new user
--      Email: reception.test@medconsult.africa   Password: choose one
--      Tick Auto Confirm User
--      (Using a different email? Change it in steps 4, 5 and 9 below.)
--   2. practice_access.sql and medical_aid_workflow.sql must have been run.
--   3. Run this whole file. Plain statements only; safe to run more than once.
--
-- Creates (or reuses): MedConsult Test Practice, Dr. Test Doctor (owner, no
-- login, works every day 08:00 to 17:00), a receptionist profile for the login, 4 test patients
-- (emails end in @medconsult.test) and 3 appointments today.
-- The last statement shows what was set up. Remove it all with
-- test_reception_cleanup.sql.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Practice
INSERT INTO practices (name, address, phone, email, plan, status, trial_ends_at, billing_email)
SELECT 'MedConsult Test Practice', '1 Test Street, Johannesburg, 2000', '011 000 0000',
       'practice@medconsult.test', 'practice', 'active', now() + interval '30 days', 'practice@medconsult.test'
WHERE NOT EXISTS (SELECT 1 FROM practices WHERE name = 'MedConsult Test Practice');

-- 2. Test doctor (no login)
INSERT INTO doctors (first_name, last_name, name, email, spec, hpcsa, prac_name)
SELECT 'Test', 'Doctor', 'Dr. Test Doctor', 'doctor@medconsult.test', 'General Practitioner', 'MP0000000', 'MedConsult Test Practice'
WHERE NOT EXISTS (SELECT 1 FROM doctors WHERE email = 'doctor@medconsult.test');

-- 3. Test doctor owns the practice
INSERT INTO practice_members (practice_id, doctor_id, role, status, invite_email, joined_at)
SELECT pr.id, d.id, 'owner', 'active', 'doctor@medconsult.test', now()
FROM practices pr, doctors d
WHERE pr.name = 'MedConsult Test Practice' AND d.email = 'doctor@medconsult.test'
  AND NOT EXISTS (SELECT 1 FROM practice_members m WHERE m.practice_id = pr.id AND m.doctor_id = d.id);

-- 3b. Working hours for the test doctor: every day 08:00 to 17:00, 15 minute slots
--     (day_of_week 0 = Sunday … 6 = Saturday)
INSERT INTO availability (doctor_id, day_of_week, start_time, end_time, slot_minutes, is_active)
SELECT d.id, dow, '08:00', '17:00', 15, true
FROM doctors d, generate_series(0, 6) AS dow
WHERE d.email = 'doctor@medconsult.test'
  AND NOT EXISTS (SELECT 1 FROM availability a WHERE a.doctor_id = d.id AND a.day_of_week = dow);

-- 4. Receptionist profile for the login
INSERT INTO doctors (auth_id, first_name, last_name, name, email, spec)
SELECT u.id, 'Test', 'Receptionist', 'Test Receptionist', u.email, 'Receptionist'
FROM auth.users u
WHERE lower(u.email) = lower('reception.test@medconsult.africa')
  AND NOT EXISTS (SELECT 1 FROM doctors d WHERE d.auth_id = u.id);

-- 5. Receptionist joins the practice
INSERT INTO practice_members (practice_id, doctor_id, role, status, invite_email, joined_at)
SELECT pr.id, d.id, 'receptionist', 'active', u.email, now()
FROM practices pr, auth.users u JOIN doctors d ON d.auth_id = u.id
WHERE pr.name = 'MedConsult Test Practice'
  AND lower(u.email) = lower('reception.test@medconsult.africa')
  AND NOT EXISTS (SELECT 1 FROM practice_members m WHERE m.practice_id = pr.id AND m.doctor_id = d.id);

-- 6. Patients, one per medical aid state
-- Unverified, valid SA ID
INSERT INTO patients (doctor_id, first_name, last_name, dob, id_number, gender, phone, email, address,
                      aid_provider, aid_number, aid_plan, aid_status, aid_dependant_code)
SELECT d.id, 'Thabo', 'Mokoena', '1980-01-01', '8001015009087', 'Male', '082 000 0001', 'thabo@medconsult.test',
       '12 Oak Street, Johannesburg', 'Discovery Health Medical Scheme', '80045123', 'Classic Comprehensive', 'unverified', '00'
FROM doctors d WHERE d.email = 'doctor@medconsult.test'
  AND NOT EXISTS (SELECT 1 FROM patients WHERE email = 'thabo@medconsult.test');

-- Verified 45 days ago (Re-check due), dependant, ID with a typo
INSERT INTO patients (doctor_id, first_name, last_name, dob, id_number, gender, phone, email,
                      aid_provider, aid_number, aid_plan, principal, aid_dependant_code,
                      aid_status, aid_checked_at, aid_checked_by, aid_check_method, aid_check_ref)
SELECT d.id, 'Sarah', 'Naidoo', '1992-02-20', '9202204720082', 'Female', '082 000 0002', 'sarah@medconsult.test',
       'Government Employees Medical Scheme (GEMS)', '1234567', 'Emerald', 'Raj Naidoo', '01',
       'verified', now() - interval '45 days', 'Test Receptionist', 'phone', 'GEMS-REF-001'
FROM doctors d WHERE d.email = 'doctor@medconsult.test'
  AND NOT EXISTS (SELECT 1 FROM patients WHERE email = 'sarah@medconsult.test');

-- Verified today
INSERT INTO patients (doctor_id, first_name, last_name, dob, id_number, gender, phone, email,
                      aid_provider, aid_number, aid_plan, aid_dependant_code,
                      aid_status, aid_checked_at, aid_checked_by, aid_check_method, aid_check_ref)
SELECT d.id, 'Lindiwe', 'Dube', '1992-02-20', '9202204720083', 'Female', '082 000 0003', 'lindiwe@medconsult.test',
       'Bonitas Medical Fund', '7654321', 'BonClassic', '00',
       'verified', now(), 'Test Receptionist', 'portal', 'BON-778812'
FROM doctors d WHERE d.email = 'doctor@medconsult.test'
  AND NOT EXISTS (SELECT 1 FROM patients WHERE email = 'lindiwe@medconsult.test');

-- Self-pay
INSERT INTO patients (doctor_id, first_name, last_name, phone, email)
SELECT d.id, 'Pieter', 'Botha', '082 000 0004', 'pieter@medconsult.test'
FROM doctors d WHERE d.email = 'doctor@medconsult.test'
  AND NOT EXISTS (SELECT 1 FROM patients WHERE email = 'pieter@medconsult.test');

-- 7. Check history for the two verified patients
INSERT INTO medical_aid_checks (patient_id, status, method, reference, checked_by, created_at)
SELECT p.id, 'verified', p.aid_check_method, p.aid_check_ref, 'Test Receptionist', p.aid_checked_at
FROM patients p
WHERE p.email IN ('sarah@medconsult.test', 'lindiwe@medconsult.test')
  AND NOT EXISTS (SELECT 1 FROM medical_aid_checks c WHERE c.patient_id = p.id);

-- 8. Appointments today (run again on another day to get appointments for that day)
INSERT INTO appointments (doctor_id, patient_id, practice_id, appt_date, appt_time, duration_min, type, status, reason, booked_by)
SELECT p.doctor_id, p.id, pr.id, current_date, v.t::time, 15, 'consultation', 'confirmed', v.reason, 'reception'
FROM (VALUES ('thabo@medconsult.test', '09:00', 'Follow-up'),
             ('sarah@medconsult.test', '10:30', 'Asthma review'),
             ('pieter@medconsult.test', '14:00', 'General check-up')) AS v(email, t, reason)
JOIN patients p ON p.email = v.email
JOIN practices pr ON pr.name = 'MedConsult Test Practice'
WHERE NOT EXISTS (SELECT 1 FROM appointments a WHERE a.patient_id = p.id AND a.appt_date = current_date);

-- 9. What was set up (login_found = false means step 1 was missed)
SELECT
  EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = lower('reception.test@medconsult.africa')) AS login_found,
  (SELECT count(*) FROM practice_members m JOIN practices pr ON pr.id = m.practice_id
     WHERE pr.name = 'MedConsult Test Practice' AND m.role = 'receptionist') AS receptionists,
  (SELECT count(*) FROM patients WHERE email LIKE '%@medconsult.test') AS test_patients,
  (SELECT count(*) FROM appointments a JOIN practices pr ON pr.id = a.practice_id
     WHERE pr.name = 'MedConsult Test Practice' AND a.appt_date = current_date) AS appointments_today;
