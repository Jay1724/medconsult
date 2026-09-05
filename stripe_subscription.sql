-- ─────────────────────────────────────────────────────────────────────────────
-- MedConsult — Stripe subscription columns
-- Run once in the Supabase SQL editor (Dashboard → SQL Editor).
--
-- Adds Stripe billing state to the practices table, replacing the decorative
-- "PayFast" placeholder with real subscription tracking. subscription_status
-- mirrors Stripe's own status values directly (trialing, active, past_due,
-- canceled, incomplete, incomplete_expired, unpaid) so the webhook can write
-- it straight through without translation.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE practices
  ADD COLUMN IF NOT EXISTS stripe_customer_id text UNIQUE,
  ADD COLUMN IF NOT EXISTS stripe_subscription_id text UNIQUE,
  ADD COLUMN IF NOT EXISTS subscription_status text,
  ADD COLUMN IF NOT EXISTS current_period_end timestamptz,
  ADD COLUMN IF NOT EXISTS cancel_at_period_end boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS practices_stripe_customer_id_idx ON practices (stripe_customer_id);
CREATE INDEX IF NOT EXISTS practices_stripe_subscription_id_idx ON practices (stripe_subscription_id);
