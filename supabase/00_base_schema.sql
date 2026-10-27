-- ============================================================
-- MedConsult — base schema (tables, constraints, indexes, RLS switches, base functions, base policies)
-- Exported from the live project (eu-west-2) on 27 Oct 2026 so the database can be rebuilt anywhere,
-- e.g. a new project in Cape Town (af-south-1).
--
-- Run on an EMPTY Supabase project, in this order, each in the SQL editor:
--   1. supabase/00_base_schema.sql         (this file)
--   2. practice_access.sql
--   3. medical_aid_workflow.sql
--   4. medconsult_security_fixes.sql
--   5. patient_access.sql
--   6. print_requests.sql
--   7. supabase/99_final_grants.sql        (locks function access down to what the live project has)
-- Not safe to re-run on a project that already has these tables.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ── Tables ──────────────────────────────────────────────────
CREATE TABLE public.doctors (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), auth_id uuid, name text NOT NULL, first_name text NOT NULL, last_name text NOT NULL,
  email text NOT NULL, spec text DEFAULT 'General Practitioner'::text, hpcsa text, prac_num text, prac_name text, prac_addr text,
  phone text, vat text, bank text, signature text, plan text DEFAULT 'pro'::text, created_at timestamptz DEFAULT now(), practice_number text);

CREATE TABLE public.practices (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), name text NOT NULL, address text, phone text, email text, logo_url text,
  hpcsa_number text, vat_number text, bank_details text, plan text DEFAULT 'practice'::text, status text DEFAULT 'trial'::text,
  trial_ends_at timestamptz DEFAULT (now() + '30 days'::interval), billing_email text, created_at timestamptz DEFAULT now());

CREATE TABLE public.patients (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), doctor_id uuid, first_name text NOT NULL, last_name text NOT NULL, dob date,
  id_number text, gender text, blood_type text, phone text, whatsapp text, email text, address text, aid_provider text,
  aid_number text, aid_plan text, principal text, allergies text, chronic text, emergency text, color text DEFAULT '#2563eb'::text,
  status text DEFAULT 'active'::text, created_at timestamptz DEFAULT now(), aid_status text, aid_checked_at timestamptz,
  aid_checked_by text, aid_check_method text, aid_check_ref text, aid_dependant_code text, aid_card_path text);

CREATE TABLE public.appointments (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), doctor_id uuid, patient_id uuid, practice_id uuid, appt_date date NOT NULL,
  appt_time time NOT NULL, duration_min integer DEFAULT 20, type text DEFAULT 'In-Person'::text, status text DEFAULT 'Confirmed'::text,
  reason text, notes text, booked_by text DEFAULT 'patient'::text, created_at timestamptz DEFAULT now());

CREATE TABLE public.availability (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), doctor_id uuid, day_of_week integer NOT NULL, start_time time NOT NULL,
  end_time time NOT NULL, slot_minutes integer DEFAULT 20, is_active boolean DEFAULT true, created_at timestamptz DEFAULT now());

CREATE TABLE public.availability_overrides (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), doctor_id uuid, override_date date NOT NULL, is_available boolean DEFAULT false,
  reason text, created_at timestamptz DEFAULT now());

CREATE TABLE public.claims (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), doctor_id uuid, patient_id uuid, ref_number text NOT NULL, aid_provider text,
  aid_number text, service_date date, icd10 text, tariff_code text, service_desc text, amount numeric(10,2), notes text,
  status text DEFAULT 'Submitted'::text, submitted_date date DEFAULT CURRENT_DATE, created_at timestamptz DEFAULT now(),
  appointment_id uuid, switch_ref text, paid_cents integer, rejection_reason text);

CREATE TABLE public.claim_lines (
  id uuid NOT NULL DEFAULT gen_random_uuid(), claim_id uuid NOT NULL, tariff_code text NOT NULL, description text,
  quantity integer NOT NULL DEFAULT 1, unit_cents integer NOT NULL DEFAULT 0, nappi_code text, modifier text, created_at timestamptz DEFAULT now());

CREATE TABLE public.invoices (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), doctor_id uuid, patient_id uuid, inv_number text NOT NULL, inv_date date NOT NULL,
  due_date date, lines jsonb DEFAULT '[]'::jsonb, notes text, status text DEFAULT 'Pending'::text, created_at timestamptz DEFAULT now());

CREATE TABLE public.medical_aid_checks (
  id uuid NOT NULL DEFAULT gen_random_uuid(), patient_id uuid NOT NULL, status text NOT NULL, method text NOT NULL, reference text,
  message text, checked_by text, checked_by_auth uuid DEFAULT auth.uid(), created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE public.patient_access (
  id uuid NOT NULL DEFAULT gen_random_uuid(), patient_id uuid, doctor_id uuid NOT NULL, requested_by uuid NOT NULL, contact_email text,
  contact_phone text, token text NOT NULL DEFAULT replace(((gen_random_uuid())::text || (gen_random_uuid())::text), '-'::text, ''::text),
  status text NOT NULL DEFAULT 'pending'::text, created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + '14 days'::interval), decided_at timestamptz);

CREATE TABLE public.patient_accounts (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), auth_id uuid, patient_id uuid, created_at timestamptz DEFAULT now());

CREATE TABLE public.patient_invites (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), doctor_id uuid, patient_id uuid, email text,
  token text DEFAULT encode(gen_random_bytes(32), 'hex'::text), status text DEFAULT 'pending'::text,
  expires_at timestamptz DEFAULT (now() + '7 days'::interval), created_at timestamptz DEFAULT now(), contact_phone text);

CREATE TABLE public.patient_portal_users (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), auth_id uuid, patient_id uuid, created_at timestamptz DEFAULT now());

CREATE TABLE public.practice_invites (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), practice_id uuid, invited_by uuid, email text NOT NULL, role text NOT NULL,
  token text DEFAULT encode(gen_random_bytes(32), 'hex'::text), status text DEFAULT 'pending'::text,
  expires_at timestamptz DEFAULT (now() + '7 days'::interval), created_at timestamptz DEFAULT now());

CREATE TABLE public.practice_members (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), practice_id uuid, doctor_id uuid, role text NOT NULL DEFAULT 'doctor'::text,
  status text DEFAULT 'active'::text, invite_email text, invited_at timestamptz, joined_at timestamptz DEFAULT now(), created_at timestamptz DEFAULT now());

CREATE TABLE public.practice_scheme_contacts (
  practice_id uuid NOT NULL, scheme text NOT NULL, phone text, portal_url text, notes text, updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE public.prescriptions (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), doctor_id uuid, patient_id uuid, ref_number text NOT NULL, script_date date NOT NULL,
  diagnosis text, repeats text DEFAULT '0'::text, medications jsonb DEFAULT '[]'::jsonb, sig_image text, created_at timestamptz DEFAULT now());

CREATE TABLE public.print_requests (
  id uuid NOT NULL DEFAULT gen_random_uuid(), patient_id uuid NOT NULL, doctor_id uuid NOT NULL, kind text NOT NULL,
  doc_id uuid NOT NULL, status text NOT NULL DEFAULT 'requested'::text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE public.records (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), doctor_id uuid, patient_id uuid, visit_date date NOT NULL,
  visit_type text DEFAULT 'In-Person'::text, diagnosis text NOT NULL, icd10 text, vitals text, notes text, medication text,
  follow_up date, referral text, created_at timestamptz DEFAULT now());

CREATE TABLE public.sick_notes (
  id uuid NOT NULL DEFAULT uuid_generate_v4(), doctor_id uuid, patient_id uuid, ref_number text NOT NULL, issue_date date NOT NULL,
  rest_from date, rest_to date, diagnosis text NOT NULL, icd10 text, instructions text, sig_image text, created_at timestamptz DEFAULT now());

-- ── Keys ────────────────────────────────────────────────────
ALTER TABLE public.appointments ADD CONSTRAINT appointments_pkey PRIMARY KEY (id);
ALTER TABLE public.availability ADD CONSTRAINT availability_pkey PRIMARY KEY (id);
ALTER TABLE public.availability_overrides ADD CONSTRAINT availability_overrides_pkey PRIMARY KEY (id);
ALTER TABLE public.claim_lines ADD CONSTRAINT claim_lines_pkey PRIMARY KEY (id);
ALTER TABLE public.claims ADD CONSTRAINT claims_pkey PRIMARY KEY (id);
ALTER TABLE public.doctors ADD CONSTRAINT doctors_pkey PRIMARY KEY (id);
ALTER TABLE public.invoices ADD CONSTRAINT invoices_pkey PRIMARY KEY (id);
ALTER TABLE public.medical_aid_checks ADD CONSTRAINT medical_aid_checks_pkey PRIMARY KEY (id);
ALTER TABLE public.patient_access ADD CONSTRAINT patient_access_pkey PRIMARY KEY (id);
ALTER TABLE public.patient_accounts ADD CONSTRAINT patient_accounts_pkey PRIMARY KEY (id);
ALTER TABLE public.patient_invites ADD CONSTRAINT patient_invites_pkey PRIMARY KEY (id);
ALTER TABLE public.patient_portal_users ADD CONSTRAINT patient_portal_users_pkey PRIMARY KEY (id);
ALTER TABLE public.patients ADD CONSTRAINT patients_pkey PRIMARY KEY (id);
ALTER TABLE public.practice_invites ADD CONSTRAINT practice_invites_pkey PRIMARY KEY (id);
ALTER TABLE public.practice_members ADD CONSTRAINT practice_members_pkey PRIMARY KEY (id);
ALTER TABLE public.practice_scheme_contacts ADD CONSTRAINT practice_scheme_contacts_pkey PRIMARY KEY (practice_id, scheme);
ALTER TABLE public.practices ADD CONSTRAINT practices_pkey PRIMARY KEY (id);
ALTER TABLE public.prescriptions ADD CONSTRAINT prescriptions_pkey PRIMARY KEY (id);
ALTER TABLE public.print_requests ADD CONSTRAINT print_requests_pkey PRIMARY KEY (id);
ALTER TABLE public.records ADD CONSTRAINT records_pkey PRIMARY KEY (id);
ALTER TABLE public.sick_notes ADD CONSTRAINT sick_notes_pkey PRIMARY KEY (id);

ALTER TABLE public.doctors ADD CONSTRAINT doctors_auth_id_key UNIQUE (auth_id);
ALTER TABLE public.doctors ADD CONSTRAINT doctors_email_key UNIQUE (email);
ALTER TABLE public.patient_access ADD CONSTRAINT patient_access_token_key UNIQUE (token);
ALTER TABLE public.patient_accounts ADD CONSTRAINT patient_accounts_auth_id_key UNIQUE (auth_id);
ALTER TABLE public.patient_invites ADD CONSTRAINT patient_invites_token_key UNIQUE (token);
ALTER TABLE public.patient_portal_users ADD CONSTRAINT patient_portal_users_auth_id_key UNIQUE (auth_id);
ALTER TABLE public.practice_invites ADD CONSTRAINT practice_invites_token_key UNIQUE (token);
ALTER TABLE public.practice_members ADD CONSTRAINT practice_members_practice_id_doctor_id_key UNIQUE (practice_id, doctor_id);

-- ── Foreign keys ────────────────────────────────────────────
ALTER TABLE public.appointments ADD CONSTRAINT appointments_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE CASCADE;
ALTER TABLE public.appointments ADD CONSTRAINT appointments_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE;
ALTER TABLE public.appointments ADD CONSTRAINT appointments_practice_id_fkey FOREIGN KEY (practice_id) REFERENCES practices(id) ON DELETE SET NULL;
ALTER TABLE public.availability ADD CONSTRAINT availability_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE CASCADE;
ALTER TABLE public.availability_overrides ADD CONSTRAINT availability_overrides_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE CASCADE;
ALTER TABLE public.claim_lines ADD CONSTRAINT claim_lines_claim_id_fkey FOREIGN KEY (claim_id) REFERENCES claims(id) ON DELETE CASCADE;
ALTER TABLE public.claims ADD CONSTRAINT claims_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE CASCADE;
ALTER TABLE public.claims ADD CONSTRAINT claims_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE;
ALTER TABLE public.invoices ADD CONSTRAINT invoices_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE CASCADE;
ALTER TABLE public.invoices ADD CONSTRAINT invoices_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE;
ALTER TABLE public.medical_aid_checks ADD CONSTRAINT medical_aid_checks_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE;
ALTER TABLE public.patient_access ADD CONSTRAINT patient_access_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE CASCADE;
ALTER TABLE public.patient_access ADD CONSTRAINT patient_access_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE;
ALTER TABLE public.patient_access ADD CONSTRAINT patient_access_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES doctors(id);
ALTER TABLE public.patient_accounts ADD CONSTRAINT patient_accounts_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE;
ALTER TABLE public.patient_invites ADD CONSTRAINT patient_invites_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE CASCADE;
ALTER TABLE public.patient_invites ADD CONSTRAINT patient_invites_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE;
ALTER TABLE public.patient_portal_users ADD CONSTRAINT patient_portal_users_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE;
ALTER TABLE public.patients ADD CONSTRAINT patients_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE CASCADE;
ALTER TABLE public.practice_invites ADD CONSTRAINT practice_invites_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES doctors(id);
ALTER TABLE public.practice_invites ADD CONSTRAINT practice_invites_practice_id_fkey FOREIGN KEY (practice_id) REFERENCES practices(id) ON DELETE CASCADE;
ALTER TABLE public.practice_members ADD CONSTRAINT practice_members_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE CASCADE;
ALTER TABLE public.practice_members ADD CONSTRAINT practice_members_practice_id_fkey FOREIGN KEY (practice_id) REFERENCES practices(id) ON DELETE CASCADE;
ALTER TABLE public.practice_scheme_contacts ADD CONSTRAINT practice_scheme_contacts_practice_id_fkey FOREIGN KEY (practice_id) REFERENCES practices(id) ON DELETE CASCADE;
ALTER TABLE public.prescriptions ADD CONSTRAINT prescriptions_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE CASCADE;
ALTER TABLE public.prescriptions ADD CONSTRAINT prescriptions_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE;
ALTER TABLE public.print_requests ADD CONSTRAINT print_requests_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id);
ALTER TABLE public.print_requests ADD CONSTRAINT print_requests_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE;
ALTER TABLE public.records ADD CONSTRAINT records_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE CASCADE;
ALTER TABLE public.records ADD CONSTRAINT records_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE;
ALTER TABLE public.sick_notes ADD CONSTRAINT sick_notes_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE CASCADE;
ALTER TABLE public.sick_notes ADD CONSTRAINT sick_notes_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE;

-- ── Checks ──────────────────────────────────────────────────
ALTER TABLE public.claim_lines ADD CONSTRAINT claim_lines_quantity_check CHECK ((quantity > 0));
ALTER TABLE public.claim_lines ADD CONSTRAINT claim_lines_unit_cents_check CHECK ((unit_cents >= 0));
ALTER TABLE public.claims ADD CONSTRAINT claims_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'ready'::text, 'submitted'::text, 'paid'::text, 'queried'::text, 'rejected'::text])));
ALTER TABLE public.medical_aid_checks ADD CONSTRAINT medical_aid_checks_method_check CHECK ((method = ANY (ARRAY['manual'::text, 'api'::text, 'phone'::text, 'portal'::text, 'card'::text])));
ALTER TABLE public.medical_aid_checks ADD CONSTRAINT medical_aid_checks_status_check CHECK ((status = ANY (ARRAY['verified'::text, 'invalid'::text, 'unverified'::text])));
ALTER TABLE public.patient_access ADD CONSTRAINT patient_access_check CHECK (((patient_id IS NOT NULL) OR (contact_email IS NOT NULL) OR (contact_phone IS NOT NULL)));
ALTER TABLE public.patient_access ADD CONSTRAINT patient_access_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'declined'::text, 'revoked'::text, 'cancelled'::text])));
ALTER TABLE public.patient_invites ADD CONSTRAINT patient_invites_contact_check CHECK (((email IS NOT NULL) OR (contact_phone IS NOT NULL)));
ALTER TABLE public.patients ADD CONSTRAINT patients_aid_check_method_check CHECK ((aid_check_method = ANY (ARRAY['manual'::text, 'api'::text, 'phone'::text, 'portal'::text, 'card'::text])));
ALTER TABLE public.patients ADD CONSTRAINT patients_aid_dependant_code_check CHECK ((aid_dependant_code ~ '^\d{2}$'::text));
ALTER TABLE public.patients ADD CONSTRAINT patients_aid_status_check CHECK ((aid_status = ANY (ARRAY['unverified'::text, 'verified'::text, 'invalid'::text])));
ALTER TABLE public.practices ADD CONSTRAINT practices_plan_check CHECK (((plan IS NULL) OR (plan = ANY (ARRAY['solo'::text, 'practice'::text, 'starter'::text, 'pro'::text])))) NOT VALID;
ALTER TABLE public.print_requests ADD CONSTRAINT print_requests_kind_check CHECK ((kind = ANY (ARRAY['sick_note'::text, 'prescription'::text, 'record'::text])));
ALTER TABLE public.print_requests ADD CONSTRAINT print_requests_status_check CHECK ((status = ANY (ARRAY['requested'::text, 'ready'::text, 'collected'::text, 'cancelled'::text])));

-- ── Indexes ─────────────────────────────────────────────────
CREATE INDEX idx_appointments_doctor_date ON public.appointments USING btree (doctor_id, appt_date);
CREATE INDEX idx_appointments_patient ON public.appointments USING btree (patient_id);
CREATE INDEX idx_availability_doctor_day ON public.availability USING btree (doctor_id, day_of_week);
CREATE INDEX claim_lines_claim_idx ON public.claim_lines USING btree (claim_id);
CREATE INDEX claims_appt_idx ON public.claims USING btree (appointment_id);
CREATE INDEX claims_patient_idx ON public.claims USING btree (patient_id);
CREATE INDEX claims_status_idx ON public.claims USING btree (status);
CREATE INDEX medical_aid_checks_patient_idx ON public.medical_aid_checks USING btree (patient_id, created_at DESC);
CREATE INDEX patient_access_doctor_idx ON public.patient_access USING btree (doctor_id, status);
CREATE INDEX patient_access_email_idx ON public.patient_access USING btree (contact_email) WHERE (patient_id IS NULL);
CREATE UNIQUE INDEX patient_access_one_open ON public.patient_access USING btree (patient_id, doctor_id) WHERE ((patient_id IS NOT NULL) AND (status = ANY (ARRAY['pending'::text, 'approved'::text])));
CREATE INDEX patient_access_patient_idx ON public.patient_access USING btree (patient_id, status);
CREATE INDEX idx_patient_accounts_auth ON public.patient_accounts USING btree (auth_id);
CREATE INDEX idx_patient_accounts_patient ON public.patient_accounts USING btree (patient_id);
CREATE INDEX idx_practice_members_doctor ON public.practice_members USING btree (doctor_id);
CREATE INDEX idx_practice_members_practice ON public.practice_members USING btree (practice_id);
CREATE INDEX print_requests_doctor_idx ON public.print_requests USING btree (doctor_id, status);
CREATE UNIQUE INDEX print_requests_open_uq ON public.print_requests USING btree (patient_id, kind, doc_id) WHERE (status = ANY (ARRAY['requested'::text, 'ready'::text]));

-- ── Row level security on everywhere ────────────────────────
DO $$ DECLARE t text; BEGIN
  FOR t IN SELECT c.relname FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r' LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- ── Base functions (the rest are defined by the scripts that follow) ──
CREATE OR REPLACE FUNCTION public.set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

CREATE OR REPLACE FUNCTION public.get_available_slots(p_doctor_id uuid, p_date date)
 RETURNS TABLE(slot_time time without time zone) LANGUAGE plpgsql AS $$
declare
  v_day_of_week int; v_is_override boolean; v_start_time time; v_end_time time; v_slot_min int; v_current time;
begin
  v_day_of_week := extract(dow from p_date);
  select is_available into v_is_override from availability_overrides where doctor_id = p_doctor_id and override_date = p_date;
  if found and not v_is_override then return; end if;
  select start_time, end_time, slot_minutes into v_start_time, v_end_time, v_slot_min
  from availability where doctor_id = p_doctor_id and day_of_week = v_day_of_week and is_active = true limit 1;
  if not found then return; end if;
  v_current := v_start_time;
  while v_current < v_end_time loop
    if not exists (select 1 from appointments where doctor_id = p_doctor_id and appt_date = p_date and appt_time = v_current and status not in ('Cancelled', 'No Show')) then
      slot_time := v_current; return next;
    end if;
    v_current := v_current + (v_slot_min || ' minutes')::interval;
  end loop;
end;
$$;

CREATE OR REPLACE FUNCTION public.get_next_ref(p_doctor_id uuid, p_table text, p_prefix text) RETURNS text LANGUAGE plpgsql AS $$
declare v_count integer; v_num text;
begin
  execute format('select count(*) from %I where doctor_id = $1', p_table) into v_count using p_doctor_id;
  v_num := p_prefix || '-' || lpad((v_count + 1001)::text, 4, '0');
  return v_num;
end;
$$;

CREATE OR REPLACE FUNCTION public.seed_default_availability(p_doctor_id uuid) RETURNS void LANGUAGE plpgsql AS $$
begin
  insert into availability (doctor_id, day_of_week, start_time, end_time, slot_minutes) values
    (p_doctor_id, 1, '08:00', '17:00', 20), (p_doctor_id, 2, '08:00', '17:00', 20), (p_doctor_id, 3, '08:00', '17:00', 20),
    (p_doctor_id, 4, '08:00', '17:00', 20), (p_doctor_id, 5, '08:00', '17:00', 20)
  on conflict do nothing;
end;
$$;

CREATE TRIGGER claims_updated_at BEFORE UPDATE ON public.claims FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── Original policies (the scripts that follow replace or add the rest) ──
CREATE POLICY "Doctor sees own appointments" ON public.appointments FOR ALL
  USING (doctor_id = (SELECT doctors.id FROM doctors WHERE doctors.auth_id = auth.uid()));
CREATE POLICY "Patient can book appointments" ON public.appointments FOR INSERT
  WITH CHECK (patient_id = (SELECT pa.patient_id FROM patient_accounts pa WHERE pa.auth_id = auth.uid()));
CREATE POLICY "Patient can cancel own appointments" ON public.appointments FOR UPDATE
  USING (patient_id = (SELECT pa.patient_id FROM patient_accounts pa WHERE pa.auth_id = auth.uid()));
CREATE POLICY "Patient sees own appointments" ON public.appointments FOR SELECT
  USING (patient_id = (SELECT pa.patient_id FROM patient_accounts pa WHERE pa.auth_id = auth.uid()));
CREATE POLICY "Anyone can read availability" ON public.availability FOR SELECT USING (true);
CREATE POLICY "Doctor manages own availability" ON public.availability FOR ALL
  USING (doctor_id = (SELECT doctors.id FROM doctors WHERE doctors.auth_id = auth.uid()));
CREATE POLICY "Anyone can read availability overrides" ON public.availability_overrides FOR SELECT USING (true);
CREATE POLICY "Doctor manages own overrides" ON public.availability_overrides FOR ALL
  USING (doctor_id = (SELECT doctors.id FROM doctors WHERE doctors.auth_id = auth.uid()));
CREATE POLICY "Doctor sees own claims" ON public.claims FOR ALL
  USING (doctor_id = (SELECT doctors.id FROM doctors WHERE doctors.auth_id = auth.uid()));
CREATE POLICY "Doctor can insert own profile" ON public.doctors FOR INSERT WITH CHECK (auth.uid() = auth_id);
CREATE POLICY "Doctor can update own profile" ON public.doctors FOR UPDATE USING (auth.uid() = auth_id);
CREATE POLICY "Doctor can view own profile" ON public.doctors FOR SELECT USING (auth.uid() = auth_id);
CREATE POLICY "Doctor sees own invoices" ON public.invoices FOR ALL
  USING (doctor_id = (SELECT doctors.id FROM doctors WHERE doctors.auth_id = auth.uid()));
CREATE POLICY "Patient reads own invoices" ON public.invoices FOR SELECT
  USING (patient_id = (SELECT pa.patient_id FROM patient_accounts pa WHERE pa.auth_id = auth.uid()));
CREATE POLICY "Doctor sees patient accounts for own patients" ON public.patient_accounts FOR SELECT
  USING (patient_id IN (SELECT patients.id FROM patients WHERE patients.doctor_id = (SELECT doctors.id FROM doctors WHERE doctors.auth_id = auth.uid())));
CREATE POLICY "Patient sees own account" ON public.patient_accounts FOR SELECT USING (auth_id = auth.uid());
CREATE POLICY "Patient sees own portal record" ON public.patient_portal_users FOR SELECT USING (auth.uid() = auth_id);
CREATE POLICY "Doctor sees own patients" ON public.patients FOR ALL
  USING (doctor_id = (SELECT doctors.id FROM doctors WHERE doctors.auth_id = auth.uid()));
CREATE POLICY "Patient reads own record" ON public.patients FOR SELECT
  USING (id = (SELECT patient_portal_users.patient_id FROM patient_portal_users WHERE patient_portal_users.auth_id = auth.uid()));
CREATE POLICY "Anyone can create a practice" ON public.practices FOR INSERT WITH CHECK (true);
CREATE POLICY "Doctor sees own prescriptions" ON public.prescriptions FOR ALL
  USING (doctor_id = (SELECT doctors.id FROM doctors WHERE doctors.auth_id = auth.uid()));
CREATE POLICY "Patient reads own prescriptions" ON public.prescriptions FOR SELECT
  USING (patient_id = (SELECT pa.patient_id FROM patient_accounts pa WHERE pa.auth_id = auth.uid()));
CREATE POLICY "Doctor sees own records" ON public.records FOR ALL
  USING (doctor_id = (SELECT doctors.id FROM doctors WHERE doctors.auth_id = auth.uid()));
CREATE POLICY "Patient reads own medical records" ON public.records FOR SELECT
  USING (patient_id = (SELECT pa.patient_id FROM patient_accounts pa WHERE pa.auth_id = auth.uid()));
CREATE POLICY "Doctor sees own sick notes" ON public.sick_notes FOR ALL
  USING (doctor_id = (SELECT doctors.id FROM doctors WHERE doctors.auth_id = auth.uid()));
CREATE POLICY "Patient reads own sick notes" ON public.sick_notes FOR SELECT
  USING (patient_id = (SELECT pa.patient_id FROM patient_accounts pa WHERE pa.auth_id = auth.uid()));

-- ── Storage bucket for medical aid card photos (private) ────
INSERT INTO storage.buckets (id, name, public) VALUES ('medical-aid-cards', 'medical-aid-cards', false) ON CONFLICT (id) DO NOTHING;
