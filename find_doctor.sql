-- MedConsult — find a doctor, book safely, see my doctors
-- Run after patient_access.sql, popia_hardening.sql. Safe to re-run.
--
-- * Doctors opt in to being listed (default off). Only name, speciality, HPCSA number, practice name/address
--   and open slots are shown to patients.
-- * A practice has a town/suburb and (optionally) map coordinates, so "near me" can sort by distance.
--   The patient's own location is sent to the search and NOT stored.
-- * Booking goes through book_appointment(): free slot, listed doctor, patient shares their profile with a
--   new doctor in the same step. Direct inserts into appointments by patients are closed.

ALTER TABLE public.practices ADD COLUMN IF NOT EXISTS suburb text;
ALTER TABLE public.practices ADD COLUMN IF NOT EXISTS city text;
ALTER TABLE public.practices ADD COLUMN IF NOT EXISTS lat double precision;
ALTER TABLE public.practices ADD COLUMN IF NOT EXISTS lng double precision;
ALTER TABLE public.doctors   ADD COLUMN IF NOT EXISTS listed boolean NOT NULL DEFAULT false;

-- No two live bookings for the same doctor and time.
CREATE UNIQUE INDEX IF NOT EXISTS appointments_one_live_slot
  ON public.appointments (doctor_id, appt_date, appt_time) WHERE lower(status) NOT IN ('cancelled', 'no show', 'no_show');

-- ── Free slots (security definer, so other patients' bookings are taken into account) ──
CREATE OR REPLACE FUNCTION public.free_slots(p_doctor uuid, p_date date) RETURNS TABLE(slot_time time)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  blocked boolean; s time; e time; m int; cur time;
  now_sa timestamp := (now() AT TIME ZONE 'Africa/Johannesburg');
BEGIN
  IF p_date < now_sa::date THEN RETURN; END IF;
  SELECT NOT o.is_available INTO blocked FROM availability_overrides o WHERE o.doctor_id = p_doctor AND o.override_date = p_date;
  IF coalesce(blocked, false) THEN RETURN; END IF;
  SELECT a.start_time, a.end_time, a.slot_minutes INTO s, e, m FROM availability a
   WHERE a.doctor_id = p_doctor AND a.day_of_week = extract(dow FROM p_date)::int AND a.is_active LIMIT 1;
  IF s IS NULL OR coalesce(m, 0) <= 0 THEN RETURN; END IF;
  cur := s;
  WHILE cur < e LOOP
    IF (p_date + cur) > (now_sa + interval '1 hour')
       AND NOT EXISTS (SELECT 1 FROM appointments x WHERE x.doctor_id = p_doctor AND x.appt_date = p_date AND x.appt_time = cur
                       AND lower(x.status) NOT IN ('cancelled', 'no show', 'no_show')) THEN
      slot_time := cur; RETURN NEXT;
    END IF;
    cur := cur + make_interval(mins => m);
  END LOOP;
END $$;

-- Does the signed-in patient already have an approved link to this doctor?
CREATE OR REPLACE FUNCTION public.has_granted_access_to_doctor(p_doctor uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM patient_access a WHERE a.patient_id = public.my_patient_id() AND a.doctor_id = p_doctor AND a.status = 'approved')
$$;

-- The existing slot function now answers from the same source.
CREATE OR REPLACE FUNCTION public.get_available_slots(p_doctor_id uuid, p_date date) RETURNS TABLE(slot_time time)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT f.slot_time FROM public.free_slots(p_doctor_id, p_date) f
  WHERE auth.uid() IS NOT NULL
    AND (EXISTS (SELECT 1 FROM doctors d WHERE d.id = p_doctor_id AND d.listed) OR public.has_granted_access_to_doctor(p_doctor_id))
$$;

-- ── Doctors: opt in / out ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_my_listing(p_listed boolean) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d uuid := public.my_doctor_id();
BEGIN
  IF auth.uid() IS NULL OR d IS NULL THEN RAISE EXCEPTION 'Your staff profile is not set up yet'; END IF;
  IF NOT public.is_clinician() THEN RAISE EXCEPTION 'Only doctors can be listed'; END IF;
  IF p_listed AND NOT EXISTS (SELECT 1 FROM availability WHERE doctor_id = d AND is_active) THEN
    PERFORM public.seed_default_availability(d);      -- Mon-Fri 08:00-17:00 in 20 minute slots; edit under Availability
  END IF;
  UPDATE doctors SET listed = p_listed WHERE id = d;
  RETURN p_listed;
END $$;

CREATE OR REPLACE FUNCTION public.set_practice_location(p_practice uuid, p_suburb text, p_city text, p_lat double precision, p_lng double precision)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
       SELECT 1 FROM practice_members pm WHERE pm.practice_id = p_practice AND pm.doctor_id = public.my_doctor_id()
         AND pm.role IN ('owner', 'admin') AND coalesce(pm.status, 'active') NOT IN ('suspended', 'removed', 'pending')) THEN
    RAISE EXCEPTION 'Only the practice owner can change the location';
  END IF;
  IF (p_lat IS NULL) <> (p_lng IS NULL) OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'Check the map location';
  END IF;
  UPDATE practices SET suburb = nullif(btrim(p_suburb), ''), city = nullif(btrim(p_city), ''), lat = p_lat, lng = p_lng WHERE id = p_practice;
  RETURN true;
END $$;

-- ── Patients: search ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_specialities() RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(array_agg(DISTINCT d.spec ORDER BY d.spec), '{}') FROM doctors d
  WHERE auth.uid() IS NOT NULL AND d.listed AND d.spec IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION public.search_doctors(p_spec text DEFAULT NULL, p_lat double precision DEFAULT NULL, p_lng double precision DEFAULT NULL,
                                                 p_place text DEFAULT NULL, p_limit int DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE out jsonb; place text := nullif(lower(btrim(coalesce(p_place, ''))), '');
BEGIN
  IF auth.uid() IS NULL OR public.my_patient_id() IS NULL THEN RAISE EXCEPTION 'Please sign in first'; END IF;
  SELECT coalesce(jsonb_agg(r ORDER BY (r->>'distance_km') IS NULL, (r->>'distance_km')::float, r->>'name'), '[]'::jsonb) INTO out
  FROM (
    SELECT jsonb_build_object(
      'id', d.id, 'name', 'Dr ' || d.first_name || ' ' || d.last_name, 'spec', d.spec, 'hpcsa', d.hpcsa,
      'practice', coalesce(pr.name, d.prac_name), 'address', coalesce(pr.address, d.prac_addr), 'suburb', pr.suburb, 'city', pr.city,
      'distance_km', CASE WHEN p_lat IS NOT NULL AND pr.lat IS NOT NULL THEN
          round((6371 * 2 * asin(sqrt(least(1, power(sin(radians(pr.lat - p_lat) / 2), 2)
            + cos(radians(p_lat)) * cos(radians(pr.lat)) * power(sin(radians(pr.lng - p_lng) / 2), 2)))))::numeric, 1) END,
      'known', public.has_granted_access_to_doctor(d.id),
      'next_slots', (SELECT coalesce(jsonb_agg(jsonb_build_object('date', x.day, 'time', to_char(x.t, 'HH24:MI')) ORDER BY x.day, x.t), '[]'::jsonb)
                     FROM (SELECT g.day, f.slot_time AS t,
                                  row_number() OVER (ORDER BY g.day, f.slot_time) AS rn
                           FROM generate_series((now() AT TIME ZONE 'Africa/Johannesburg')::date,
                                                (now() AT TIME ZONE 'Africa/Johannesburg')::date + 13, interval '1 day') AS g(day)
                           CROSS JOIN LATERAL public.free_slots(d.id, g.day::date) f) x WHERE x.rn <= 3)
    ) AS r
    FROM doctors d
    LEFT JOIN LATERAL (SELECT p.* FROM practice_members pm JOIN practices p ON p.id = pm.practice_id
                       WHERE pm.doctor_id = d.id AND coalesce(pm.status, 'active') NOT IN ('suspended', 'removed', 'pending')
                       ORDER BY pm.created_at NULLS LAST LIMIT 1) pr ON true
    WHERE d.listed AND d.auth_id IS NOT NULL
      AND (nullif(btrim(coalesce(p_spec, '')), '') IS NULL OR d.spec = p_spec)
      AND (place IS NULL OR lower(coalesce(pr.suburb, '') || ' ' || coalesce(pr.city, '') || ' ' || coalesce(pr.address, d.prac_addr, '')) LIKE '%' || place || '%')
      AND EXISTS (SELECT 1 FROM availability a WHERE a.doctor_id = d.id AND a.is_active)
    LIMIT greatest(1, least(coalesce(p_limit, 20), 50))
  ) q;
  RETURN out;
END $$;

-- ── Patients: book ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.book_appointment(p_doctor uuid, p_date date, p_time time, p_reason text DEFAULT NULL, p_share boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid := public.my_patient_id(); known boolean; appt uuid; ex uuid;
BEGIN
  IF auth.uid() IS NULL OR pid IS NULL THEN RAISE EXCEPTION 'Please sign in first'; END IF;
  known := public.has_granted_access_to_doctor(p_doctor);
  IF NOT known AND NOT EXISTS (SELECT 1 FROM doctors d WHERE d.id = p_doctor AND d.listed) THEN
    RAISE EXCEPTION 'This doctor is not taking online bookings';
  END IF;
  IF NOT known AND NOT p_share THEN
    RAISE EXCEPTION 'To book with a new doctor you need to share your profile with them';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('book:' || p_doctor::text || p_date::text));
  IF NOT EXISTS (SELECT 1 FROM public.free_slots(p_doctor, p_date) f WHERE f.slot_time = p_time) THEN
    RAISE EXCEPTION 'That time has just been taken. Please pick another';
  END IF;
  IF EXISTS (SELECT 1 FROM appointments a WHERE a.patient_id = pid AND a.appt_date = p_date AND a.appt_time = p_time
             AND lower(a.status) NOT IN ('cancelled', 'no show', 'no_show')) THEN
    RAISE EXCEPTION 'You already have an appointment at that time';
  END IF;
  IF NOT known THEN
    SELECT id INTO ex FROM patient_access WHERE patient_id = pid AND doctor_id = p_doctor AND status IN ('pending', 'declined', 'revoked') ORDER BY created_at DESC LIMIT 1;
    IF ex IS NOT NULL THEN UPDATE patient_access SET status = 'approved', decided_at = now() WHERE id = ex;
    ELSE INSERT INTO patient_access (patient_id, doctor_id, requested_by, status, decided_at)  /* patient-initiated: requested_by is the doctor it is for */ VALUES (pid, p_doctor, p_doctor, 'approved', now()); END IF;
  END IF;
  INSERT INTO appointments (doctor_id, patient_id, appt_date, appt_time, type, status, reason, booked_by)
  VALUES (p_doctor, pid, p_date, p_time, 'In-Person', 'Pending', nullif(left(btrim(coalesce(p_reason, '')), 300), ''), 'patient')
  RETURNING id INTO appt;
  RETURN appt;
END $$;

-- ── Patients: my doctors ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_my_doctors() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid := public.my_patient_id(); out jsonb;
BEGIN
  IF auth.uid() IS NULL OR pid IS NULL THEN RETURN '[]'::jsonb; END IF;
  SELECT coalesce(jsonb_agg(r ORDER BY r->>'name'), '[]'::jsonb) INTO out FROM (
    SELECT jsonb_build_object(
      'id', d.id, 'name', 'Dr ' || d.first_name || ' ' || d.last_name, 'spec', d.spec, 'hpcsa', d.hpcsa,
      'practice', coalesce(pr.name, d.prac_name), 'address', coalesce(pr.address, d.prac_addr),
      'access_id', ac.id, 'access_status', ac.status,
      'can_book', (ac.status = 'approved' OR d.listed),
      'next_appt', (SELECT to_jsonb(x) FROM (SELECT a.appt_date AS date, to_char(a.appt_time, 'HH24:MI') AS time FROM appointments a
                    WHERE a.patient_id = pid AND a.doctor_id = d.id AND a.appt_date >= (now() AT TIME ZONE 'Africa/Johannesburg')::date
                      AND lower(a.status) IN ('pending', 'confirmed') ORDER BY a.appt_date, a.appt_time LIMIT 1) x),
      'last_visit', (SELECT max(a.appt_date) FROM appointments a WHERE a.patient_id = pid AND a.doctor_id = d.id
                     AND a.appt_date < (now() AT TIME ZONE 'Africa/Johannesburg')::date AND lower(a.status) NOT IN ('cancelled', 'no show', 'no_show'))
    ) AS r
    FROM doctors d
    LEFT JOIN LATERAL (SELECT a.id, a.status FROM patient_access a WHERE a.patient_id = pid AND a.doctor_id = d.id
                       AND a.status IN ('approved', 'pending') ORDER BY (a.status = 'approved') DESC, a.created_at DESC LIMIT 1) ac ON true
    LEFT JOIN LATERAL (SELECT p.* FROM practice_members pm JOIN practices p ON p.id = pm.practice_id
                       WHERE pm.doctor_id = d.id ORDER BY pm.created_at NULLS LAST LIMIT 1) pr ON true
    WHERE ac.id IS NOT NULL OR EXISTS (SELECT 1 FROM appointments a WHERE a.patient_id = pid AND a.doctor_id = d.id)
  ) q;
  RETURN out;
END $$;

-- ── Close the direct booking route; tidy rights ────────────────────────────────
DROP POLICY IF EXISTS "Patient can book appointments" ON public.appointments;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['free_slots(uuid,date)', 'get_available_slots(uuid,date)', 'has_granted_access_to_doctor(uuid)', 'set_my_listing(boolean)',
    'set_practice_location(uuid,text,text,double precision,double precision)', 'list_specialities()',
    'search_doctors(text,double precision,double precision,text,int)', 'book_appointment(uuid,date,time,text,boolean)', 'list_my_doctors()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY['get_available_slots(uuid,date)', 'set_my_listing(boolean)', 'set_practice_location(uuid,text,text,double precision,double precision)',
    'list_specialities()', 'search_doctors(text,double precision,double precision,text,int)', 'book_appointment(uuid,date,time,text,boolean)', 'list_my_doctors()'] LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;
