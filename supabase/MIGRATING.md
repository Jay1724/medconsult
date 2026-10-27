# Moving MedConsult to Cape Town (af-south-1)

A Supabase project's region cannot be changed, so this means a new project, then switching the app over.
At the time of writing the live project holds only test data (2 logins, 2 doctors, 5 demo patients, no records),
so nothing needs copying. **Do this before real patient data goes in.**

## 1. Create the new project (dashboard)
supabase.com/dashboard → New project → organisation Yugen Studio → name `medconsult-za` → **Region: South Africa (Cape Town)**.
Pick a strong database password and store it in your password manager. Use a paid plan (Pro) so you get daily backups.

## 2. Rebuild the database (SQL editor, one file at a time, in this order)
1. `supabase/00_base_schema.sql`
2. `practice_access.sql`
3. `medical_aid_workflow.sql`
4. `medconsult_security_fixes.sql`
5. `patient_access.sql`
6. `print_requests.sql`
7. `supabase/99_verify.sql` — should list exactly 7 functions: get_access_link, get_available_slots, get_next_ref, get_patient_invite, get_practice_invite, seed_default_availability, set_updated_at.

Tested on a blank local Postgres: all six scripts run without errors and the policies match the live project one for one.

## 3. Auth settings (Authentication → URL configuration / Providers)
- Site URL `https://medconsult.africa`; add redirect URLs for every page that signs people in.
- Email: confirm "Confirm email" is ON (patient profiles require a verified email).
- Turn on leaked-password protection (Pro plan) and set a minimum password length of 8 or more.

## 4. Point the app at the new project
Send the new **Project URL** and **anon (publishable) key**; they are public values. The app files that hold them are replaced in one PR. Do not send the service role key or the database password.

## 5. Check, then retire the old project
Sign up as a doctor, add a patient, issue a sick note, reload, invite a patient, approve, request a print.
Then pause the London project for a week and delete it, so no patient data stays outside South Africa.
