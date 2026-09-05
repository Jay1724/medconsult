// ─────────────────────────────────────────────────────────────────────────────
// MedConsult — create-checkout-session Edge Function
//
// POST { auth_id: string, email: string, name: string }
// →    { url: string }
//
// Creates a Stripe customer + a subscription-mode Checkout Session for the
// Practice Plan (R 5,000/month, 30-day free trial). Card details are entered
// on Stripe's own hosted page — they never touch our server, so this carries
// none of the PCI-DSS scope the old raw card-number form did.
//
// The signed-up auth user's id is stamped onto both the customer and the
// subscription as metadata so the webhook can find the right practice once
// one exists, and so retrieve-checkout-session can hand back the same id for
// a sanity check on return.
//
// Deploy:  supabase functions deploy create-checkout-session --no-verify-jwt
// Secrets: supabase secrets set STRIPE_SECRET_KEY=sk_... STRIPE_PRICE_ID=price_...
//          (STRIPE_PRICE_ID = a recurring ZAR 5,000/month Price created in the
//          Stripe Dashboard for the "Practice Plan" Product)
// ─────────────────────────────────────────────────────────────────────────────

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

async function stripe(path: string, params: Record<string, string>, secretKey: string) {
  const res = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${secretKey}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams(params),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data?.error?.message || `Stripe ${path} failed`);
  return data;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);

  const secretKey = Deno.env.get('STRIPE_SECRET_KEY');
  const priceId = Deno.env.get('STRIPE_PRICE_ID');
  if (!secretKey || !priceId) return json({ error: 'Stripe is not configured on the server yet.' }, 500);

  let body: { auth_id?: string; email?: string; name?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }
  const { auth_id, email, name } = body;
  if (!auth_id || !email) return json({ error: 'auth_id and email are required' }, 400);

  const origin = req.headers.get('origin') || 'https://medconsult.africa';

  try {
    const customer = await stripe('customers', { email, name: name || '', 'metadata[auth_id]': auth_id }, secretKey);

    const session = await stripe('checkout/sessions', {
      mode: 'subscription',
      customer: customer.id,
      'line_items[0][price]': priceId,
      'line_items[0][quantity]': '1',
      'subscription_data[trial_period_days]': '30',
      'subscription_data[metadata][auth_id]': auth_id,
      success_url: `${origin}/practice.html?checkout=success&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${origin}/practice.html?checkout=cancel`,
      client_reference_id: auth_id,
    }, secretKey);

    return json({ url: session.url });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : 'Failed to start checkout' }, 500);
  }
});
