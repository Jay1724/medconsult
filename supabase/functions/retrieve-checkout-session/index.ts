// ─────────────────────────────────────────────────────────────────────────────
// MedConsult — retrieve-checkout-session Edge Function
//
// POST { session_id: string }
// →    { auth_id, stripe_customer_id, stripe_subscription_id,
//         subscription_status, trial_ends_at, current_period_end }
//
// Called by practice.html right after Stripe redirects back with
// ?checkout=success&session_id=... — it needs the subscription's real trial
// end and status before it can finish creating the practice row. This
// synchronous lookup provisions the account without waiting on the
// stripe-webhook function, which instead keeps the subscription in sync
// afterwards (renewals, cancellations, failed payments).
//
// Deploy:  supabase functions deploy retrieve-checkout-session --no-verify-jwt
// Secrets: supabase secrets set STRIPE_SECRET_KEY=sk_...
// ─────────────────────────────────────────────────────────────────────────────

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

async function stripeGet(path: string, secretKey: string) {
  const res = await fetch(`https://api.stripe.com/v1/${path}`, {
    headers: { Authorization: `Bearer ${secretKey}` },
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data?.error?.message || `Stripe ${path} failed`);
  return data;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);

  const secretKey = Deno.env.get('STRIPE_SECRET_KEY');
  if (!secretKey) return json({ error: 'Stripe is not configured on the server yet.' }, 500);

  let body: { session_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }
  if (!body.session_id) return json({ error: 'session_id is required' }, 400);

  try {
    const session = await stripeGet(
      `checkout/sessions/${encodeURIComponent(body.session_id)}?expand[]=subscription`,
      secretKey,
    );
    if (session.payment_status !== 'paid' && session.status !== 'complete') {
      return json({ error: 'Checkout was not completed.' }, 400);
    }
    const sub = session.subscription;
    return json({
      auth_id: session.client_reference_id,
      stripe_customer_id: session.customer,
      stripe_subscription_id: sub?.id ?? null,
      subscription_status: sub?.status ?? null,
      trial_ends_at: sub?.trial_end ? new Date(sub.trial_end * 1000).toISOString() : null,
      current_period_end: sub?.current_period_end ? new Date(sub.current_period_end * 1000).toISOString() : null,
    });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : 'Failed to retrieve checkout session' }, 500);
  }
});
