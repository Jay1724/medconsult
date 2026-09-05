// ─────────────────────────────────────────────────────────────────────────────
// MedConsult — create-billing-portal-session Edge Function
//
// POST { stripe_customer_id: string }
// →    { url: string }
//
// Opens Stripe's hosted Billing Portal, where a practice owner can update
// their card, view invoices/receipts, or cancel — Stripe handles all of it,
// so "Update Payment Method" and "Cancel Subscription" no longer need to be
// custom-built (and no longer just show a "contact support" toast).
//
// Deploy:  supabase functions deploy create-billing-portal-session --no-verify-jwt
// Secrets: supabase secrets set STRIPE_SECRET_KEY=sk_...
// ─────────────────────────────────────────────────────────────────────────────

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);

  const secretKey = Deno.env.get('STRIPE_SECRET_KEY');
  if (!secretKey) return json({ error: 'Stripe is not configured on the server yet.' }, 500);

  let body: { stripe_customer_id?: string; return_url?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }
  if (!body.stripe_customer_id) return json({ error: 'stripe_customer_id is required' }, 400);

  const origin = req.headers.get('origin') || 'https://medconsult.africa';

  try {
    const res = await fetch('https://api.stripe.com/v1/billing_portal/sessions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${secretKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({
        customer: body.stripe_customer_id,
        return_url: body.return_url || `${origin}/practice.html`,
      }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data?.error?.message || 'Stripe billing_portal/sessions failed');
    return json({ url: data.url });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : 'Failed to open billing portal' }, 500);
  }
});
