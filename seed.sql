-- ─────────────────────────────────────────────────────────────────────────────
-- MedConsult — Test Data Seed
-- Run each block in order in the Supabase SQL editor (Dashboard → SQL Editor).
-- Replace the placeholder values before running.
-- ─────────────────────────────────────────────────────────────────────────────


-- ── STEP 1: Discover your IDs ─────────────────────────────────────────────────
-- Run this block first to find your patient_id and available doctors.

SELECT
  p.id        AS patient_id,
  p.fn        AS first_name,
  p.ln        AS last_name,
  u.email     AS login_email
FROM patients p
JOIN patient_accounts pa ON pa.patient_id = p.id
JOIN auth.users u         ON u.id = pa.auth_id
ORDER BY p.created_at DESC
LIMIT 10;

-- List existing doctors:
SELECT id, fn, ln, spec FROM doctors ORDER BY ln;


-- ── STEP 2: Insert a test doctor (skip if one already exists) ─────────────────
-- This creates Dr. Thabo Mokoena, GP, and returns the doctor's UUID.

INSERT INTO doctors (fn, ln, spec)
VALUES ('Thabo', 'Mokoena', 'General Practitioner')
RETURNING id;  -- copy this UUID — you'll need it below


-- ── STEP 3: Populate patient demographics ────────────────────────────────────
-- Replace <YOUR_PATIENT_ID> with the id from Step 1.

UPDATE patients SET
  fn      = 'Naledi',
  ln      = 'Dlamini',
  em      = 'naledi.dlamini@gmail.com',
  dob     = '1990-07-22',
  idnum   = '9007220084083',
  gen     = 'Female',
  bl      = 'O+',
  allerg  = 'Penicillin, NSAIDs',
  chronic = 'Asthma (mild intermittent), Iron-deficiency anaemia',
  aid     = 'Momentum Health',
  aidnum  = 'MH-2024-339876',
  aidplan = 'Ingwe Option',
  ph      = '+27 82 456 7890',
  wa      = '+27 82 456 7890',
  addr    = '22 Buitenkant Street, Gardens, Cape Town, 8001',
  emer    = 'Sipho Dlamini (Brother) — +27 73 876 5432'
WHERE id = '<YOUR_PATIENT_ID>';


-- ── STEP 4: Link doctor to patient ───────────────────────────────────────────
-- Replace both placeholders. This also enables appointment booking.
-- (The patient can also do this themselves via the new "Link Doctor" UI.)

UPDATE patients
SET doctor_id = '<DOCTOR_ID>'
WHERE id = '<YOUR_PATIENT_ID>';


-- ── STEP 5: Seed appointments ────────────────────────────────────────────────
-- Mix of upcoming (Confirmed + Pending) and past (Completed) appointments.

INSERT INTO appointments (patient_id, doctor_id, appt_date, appt_time, type, status, reason, booked_by)
VALUES
  ('<YOUR_PATIENT_ID>', '<DOCTOR_ID>', CURRENT_DATE + 7,  '09:00:00', 'In-Person', 'Confirmed', 'Asthma follow-up and inhaler script renewal',    'doctor'),
  ('<YOUR_PATIENT_ID>', '<DOCTOR_ID>', CURRENT_DATE + 21, '10:30:00', 'In-Person', 'Pending',   'Annual wellness check',                          'patient'),
  ('<YOUR_PATIENT_ID>', '<DOCTOR_ID>', CURRENT_DATE - 14, '08:30:00', 'In-Person', 'Completed', 'Chest tightness and shortness of breath',         'patient'),
  ('<YOUR_PATIENT_ID>', '<DOCTOR_ID>', CURRENT_DATE - 45, '14:00:00', 'In-Person', 'Completed', 'Fatigue and dizziness — iron level review',       'doctor'),
  ('<YOUR_PATIENT_ID>', '<DOCTOR_ID>', CURRENT_DATE - 90, '11:00:00', 'In-Person', 'Completed', 'General consultation',                            'patient');


-- ── STEP 6: Seed medical records ─────────────────────────────────────────────

INSERT INTO records (patient_id, date, diag, icd, vit, notes, meds, fu)
VALUES
  (
    '<YOUR_PATIENT_ID>',
    CURRENT_DATE - 14,
    'Acute asthma exacerbation',
    'J45.0',
    'BP 118/76  HR 92  SpO2 97%  RR 18  Temp 36.6°C',
    'Patient presented with wheeze and chest tightness following cold air exposure. Air entry bilaterally reduced with expiratory wheeze. Responded well to nebulised salbutamol in-rooms.',
    'Salbutamol 100mcg inhaler — 2 puffs QID PRN; Budesonide 200mcg inhaler — 2 puffs BD x 7 days',
    CURRENT_DATE + 7
  ),
  (
    '<YOUR_PATIENT_ID>',
    CURRENT_DATE - 45,
    'Iron-deficiency anaemia',
    'D50.9',
    'BP 110/70  HR 88  Temp 36.4°C  Weight 58 kg',
    'FBC: Hb 9.2 g/dL, MCV 72 fL, Ferritin 4 ng/mL. Patient reports 6 weeks of fatigue and exertional dyspnoea. No active bleeding identified. Dietary review done — poor iron intake noted.',
    'Ferrous sulphate 200 mg BD with meals x 3 months; Vitamin C 500 mg daily (aids absorption)',
    CURRENT_DATE - 14
  ),
  (
    '<YOUR_PATIENT_ID>',
    CURRENT_DATE - 90,
    'Routine wellness assessment',
    'Z00.0',
    'BP 112/72  HR 74  Weight 57.5 kg  BMI 21.3  SpO2 99%',
    'Annual check — patient in good general health. Chest clear. Abdomen soft and non-tender. Cervical smear normal. Fasting cholesterol within normal limits. Mild persistent asthma remains well-controlled on current regimen.',
    'Continue existing asthma management. Repeat FBC in 6 months.',
    CURRENT_DATE - 45
  );


-- ── STEP 7: Seed sick note ───────────────────────────────────────────────────

INSERT INTO sick_notes (patient_id, doctor_name, patient_name, diag, icd, date, "from", "to", inst)
VALUES (
  '<YOUR_PATIENT_ID>',
  'Dr. Thabo Mokoena',
  'Naledi Dlamini',
  'Acute asthma exacerbation',
  'J45.0',
  CURRENT_DATE - 14,
  CURRENT_DATE - 14,
  CURRENT_DATE - 12,
  'Patient is unfit for work from 14 to 12 days ago. Rest, avoid cold air exposure, and follow the prescribed inhaler regimen. May return to work when symptom-free.'
);


-- ── STEP 8: Seed prescription ────────────────────────────────────────────────

INSERT INTO prescriptions (patient_id, doctor_name, patient_name, diag, date, medications)
VALUES (
  '<YOUR_PATIENT_ID>',
  'Dr. Thabo Mokoena',
  'Naledi Dlamini',
  'Iron-deficiency anaemia',
  CURRENT_DATE - 45,
  '[
    {"name":"Ferrous Sulphate","str":"200 mg","dose":"1 tablet twice daily with meals","qty":"180 tablets (3-month supply)"},
    {"name":"Vitamin C","str":"500 mg","dose":"1 tablet daily","qty":"90 tablets (3-month supply)"}
  ]'
);


-- ── Done ─────────────────────────────────────────────────────────────────────
-- Reload the patient portal — all tabs should now show real-looking data.
-- The patient can also link/change a doctor via Profile → My Doctor → Link Doctor.
