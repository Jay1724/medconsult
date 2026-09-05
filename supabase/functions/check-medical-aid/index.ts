// ─────────────────────────────────────────────────────────────────────────────
// MedConsult — check-medical-aid Edge Function
//
// POST { provider: string, member_number: string, id_number?: string }
// →    { status: 'valid' | 'invalid' | 'unverified', scheme: string | null,
//        message: string, checked_at: string }
//
// Today this is a format-validation stub: it mirrors the client-side registry
// in /medical-aid.js so the check cannot be bypassed by editing the page.
// When a switching-house agreement (Healthbridge / MediSwitch / MediKredit)
// is in place, set SWITCH_API_URL + SWITCH_API_KEY as function secrets and
// implement the call in liveCheck() below — the response contract and the
// portals' UI do not change.
//
// Deploy:  supabase functions deploy check-medical-aid --no-verify-jwt
// Secrets: supabase secrets set SWITCH_API_URL=... SWITCH_API_KEY=...
// ─────────────────────────────────────────────────────────────────────────────

type Format = { re: RegExp; hint: string };
type Scheme = { name: string; aliases: string[]; format?: Format };

const GENERIC: Format = { re: /^[A-Za-z0-9][A-Za-z0-9/\- ]{2,19}$/, hint: '4–20 characters: letters, digits, spaces, "-" or "/"' };
const digits = (min: number, max: number): Format => ({ re: new RegExp(`^\\d{${min},${max}}$`), hint: `${min}–${max} digits` });

// Keep in sync with /medical-aid.js
const SCHEMES: Scheme[] = [
  { name: 'Discovery Health Medical Scheme', aliases: ['discovery', 'discovery health'], format: digits(8, 11) },
  { name: 'Government Employees Medical Scheme (GEMS)', aliases: ['gems', 'government employees'], format: digits(7, 10) },
  { name: 'Bonitas Medical Fund', aliases: ['bonitas'], format: digits(7, 10) },
  { name: 'Momentum Medical Scheme', aliases: ['momentum', 'momentum health'] },
  { name: 'Bestmed Medical Scheme', aliases: ['bestmed'], format: digits(6, 10) },
  { name: 'Medihelp', aliases: ['medihelp'], format: digits(6, 10) },
  { name: 'Medshield Medical Scheme', aliases: ['medshield'], format: digits(6, 10) },
  { name: 'Fedhealth Medical Scheme', aliases: ['fedhealth'] },
  { name: 'Sizwe Hosmed Medical Scheme', aliases: ['sizwe', 'hosmed', 'sizwe hosmed'] },
  { name: 'Profmed', aliases: ['profmed'] },
  { name: 'KeyHealth Medical Scheme', aliases: ['keyhealth', 'key health'] },
  { name: 'Bankmed', aliases: ['bankmed'], format: digits(6, 10) },
  { name: 'Polmed (SAPS Medical Scheme)', aliases: ['polmed', 'saps'], format: digits(6, 10) },
  { name: 'LA Health Medical Scheme', aliases: ['la health'] },
  { name: 'Camaf (Chartered Accountants Medical Aid Fund)', aliases: ['camaf'] },
  { name: 'Suremed Health', aliases: ['suremed'] },
  { name: 'Genesis Medical Scheme', aliases: ['genesis'] },
];

const norm = (s: string) => (s || '').toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();

function findScheme(provider: string): Scheme | null {
  const q = norm(provider);
  if (!q) return null;
  for (const s of SCHEMES) {
    for (const c of [norm(s.name), ...s.aliases.map(norm)]) {
      if (c === q || c.includes(q) || q.includes(c)) return s;
    }
  }
  return null;
}

// Placeholder for the real eligibility check via a switching house.
// Return null while no switch is configured so callers get 'unverified'.
async function liveCheck(_scheme: Scheme | null, _memberNumber: string, _idNumber?: string): Promise<'valid' | 'invalid' | null> {
  const url = Deno.env.get('SWITCH_API_URL');
  const key = Deno.env.get('SWITCH_API_KEY');
  if (!url || !key) return null;
  // TODO(switch-integration): call the switching-house eligibility endpoint
  // here and map its response to 'valid' | 'invalid'.
  return null;
}

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

  let body: { provider?: string; member_number?: string; id_number?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }

  const provider = (body.provider || '').trim();
  const memberNumber = (body.member_number || '').trim();
  const checked_at = new Date().toISOString();
  if (!provider || !memberNumber) {
    return json({ status: 'invalid', scheme: null, message: 'provider and member_number are required.', checked_at }, 400);
  }

  const scheme = findScheme(provider);
  const fmt = scheme?.format ?? GENERIC;

  if (!fmt.re.test(memberNumber)) {
    return json({
      status: 'invalid',
      scheme: scheme?.name ?? null,
      message: `Member number does not match the expected format for ${scheme?.name ?? provider} (${fmt.hint}).`,
      checked_at,
    });
  }

  const live = await liveCheck(scheme, memberNumber, body.id_number);
  if (live) {
    return json({ status: live, scheme: scheme?.name ?? null, message: `Live eligibility check returned: ${live}.`, checked_at });
  }

  return json({
    status: 'unverified',
    scheme: scheme?.name ?? null,
    message: scheme
      ? `Format OK for ${scheme.name}. Live verification is not connected yet — confirm with the scheme and mark the membership verified manually.`
      : `Format OK, but "${provider}" is not in the scheme registry. Confirm the scheme name and verify manually.`,
    checked_at,
  });
});
