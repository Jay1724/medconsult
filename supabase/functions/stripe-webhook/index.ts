// ─────────────────────────────────────────────────────────────────────────────
// MedConsult — stripe-webhook Edge Function
//
// Keeps a practice's subscription state in sync with Stripe after the initial
// checkout: renewals, cancellations, and failed payments all land here as
// customer.subscription.* events and get written onto the matching
// practices row (matched by stripe_customer_id).
//
// Initial provisioning does NOT happen here — practice.html creates the
// practice row synchronously right after the Stripe redirect (see
// retrieve-checkout-session), and that almost always runs before Stripe's
// first subscription.created webhook arrives. So if no matching practices
// row exists yet, this handler just no-ops rather than racing the client;
// it only ever updates a row that already exists.
//
// Verifies the Stripe-Signature header manually (HMAC-SHA256 via Web Crypto)
// so this has no dependency on the Stripe SDK.
//
// Deploy:  supabase functions deploy stripe-webhook --no-verify-jwt
// Secrets: supabase secrets set STRIPE_SECRET_KEY=sk_... STRIPE_WEBHOOK_SECRET=whsec_...
//          SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
// Stripe Dashboard: add an endpoint at <project>.functions.supabase.co/stripe-webhook
//          listening for customer.subscription.created/updated/deleted.
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const TOLERANCE_SECONDS = 300;

async function verifyStripeSignature(rawBody: string, header: string | null, secret: string): Promise<boolean> {
  if (!header) return false;
  const parts = Object.fromEntries(header.split(',').map((p) => p.split('=') as [string, string]));
  const timestamp = parts.t;
  const signature = parts.v1;
  if (!timestamp || !signature) return false;
  if (Math.abs(Date.now() / 1000 - Number(timestamp)) > TOLERANCE_SECONDS) return false;

  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${timestamp}.${rawBody}`));
  const expected = Array.from(new Uint8Array(mac)).map((b) => b.toString(16).padStart(2, '0')).join('');
  return expected === signature;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('POST only', { status: 405 });

  const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET');
  if (!webhookSecret) return new Response('Webhook not configured', { status: 500 });

  const rawBody = await req.text();
  const valid = await verifyStripeSignature(rawBody, req.headers.get('stripe-signature'), webhookSecret);
  if (!valid) return new Response('Invalid signature', { status: 400 });

  const event = JSON.parse(rawBody);
  const sub = event.data?.object;

  if (event.type?.startsWith('customer.subscription.') && sub?.customer) {
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    await supabase
      .from('practices')
      .update({
        stripe_subscription_id: sub.id,
        subscription_status: sub.status,
        trial_ends_at: sub.trial_end ? new Date(sub.trial_end * 1000).toISOString() : null,
        current_period_end: sub.current_period_end ? new Date(sub.current_period_end * 1000).toISOString() : null,
        cancel_at_period_end: !!sub.cancel_at_period_end,
      })
      .eq('stripe_customer_id', sub.customer);
    // No matching row yet (webhook arrived before the client finished provisioning) — nothing to do.
  }

  return new Response(JSON.stringify({ received: true }), { headers: { 'Content-Type': 'application/json' } });
});
