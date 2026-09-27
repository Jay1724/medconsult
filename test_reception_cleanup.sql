-- ─────────────────────────────────────────────────────────────────────────────
-- MedConsult — Remove the test receptionist data created by test_reception_profile.sql
-- Afterwards delete the login under Authentication → Users.
-- ─────────────────────────────────────────────────────────────────────────────
DELETE FROM appointments     WHERE practice_id IN (SELECT id FROM practices WHERE name = 'MedConsult Test Practice');
DELETE FROM patients         WHERE email LIKE '%@medconsult.test';
DELETE FROM practice_members WHERE practice_id IN (SELECT id FROM practices WHERE name = 'MedConsult Test Practice');
DELETE FROM doctors          WHERE email IN ('doctor@medconsult.test', 'reception.test@medconsult.africa');
DELETE FROM practices        WHERE name = 'MedConsult Test Practice';
