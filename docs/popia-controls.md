# POPIA controls for MedConsult

Decision (27 Oct 2026): data stays in the Supabase London region (eu-west-2). Supabase has no Cape Town option, so we compensate with strict contracts, consent, access control and logging. This is a working checklist, not legal advice; have an attorney review it before launch.

## Why London is defensible
POPIA s72 allows a transfer abroad when the recipient is bound by an agreement giving substantially similar protection (s72(1)(a)), or the person consents (s72(1)(b)). We rely on both: Supabase's data processing agreement (with standard contractual clauses) and an explicit consent line at sign-up. Open question for the attorney: whether health data going to a country without a formal adequacy finding needs prior authorisation from the Information Regulator under s57.

## Built into the product
| Control | Where |
|---|---|
| Patients own their profile; a doctor sees nothing until the patient approves; revocable any time | patient_access.sql |
| Row level security on every table, no table readable without a rule | base schema + scripts |
| Receptionists never get clinical records | patient_access.sql |
| Health documents never leave by email; paper copy on request, collected at the practice | print_requests.sql |
| Every create, change and delete of clinical data is logged by the database; doctors' file views are logged | popia_hardening.sql |
| Patients can see who accessed their record | popia_hardening.sql, Profile tab |
| Open "anyone can create a practice" rule removed | popia_hardening.sql |
| Links to unregistered patients expire (14 days) and only verified emails match | patient_access.sql |
| Doctors read and write clinical data only through server functions: second factor, clinician-only, patient permission checked, view logged by the database. Direct table access for doctors removed. Issue lists show reference/patient/date only | clinical_reads.sql |

## Still to build (in this order)
1. ~~Consent and privacy notice at patient sign-up~~ (consent.sql, PR #15).
2. Front-desk view so receptionists cannot read allergies or chronic conditions through the API.
3. Patient rights: download my data, ask for correction, ask for deletion (with the HPCSA retention carve-out, which keeps clinical notes for the legal retention period).
4. ~~Two-factor sign-in for doctors~~ (staff_mfa.sql, PR #16).
5. ~~Clinical reads behind logged functions~~ (clinical_reads.sql).
6. Retention schedule and automated clean-up of expired invites and old logs.

## Non-code tasks (you)
- Register an Information Officer with the Information Regulator (the responsible party must have one).
- Sign data processing agreements with Supabase, Vercel and PayFast; keep copies. Add them to a sub-processor list on the privacy page.
- Pay for the Supabase Pro plan: daily backups, and turn on point-in-time recovery. Backups are part of the security safeguard.
- Write a one-page breach response plan: who decides, how the Regulator and affected patients are told, within what time.
- Update privacy.html: the access flow, the access log, print-on-request, London hosting and why, retention.
- Each practice using MedConsult is the responsible party for its patients; MedConsult is the operator. Prepare a short operator agreement for practices to accept at sign-up.
