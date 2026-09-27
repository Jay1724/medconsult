// ─────────────────────────────────────────────────────────────────────────────
// MedConsult — check-medical-aid Edge Function
//
// POST { provider: string, member_number: string, id_number?: string,
//        dependant_code?: string }
// →    { status: 'valid' | 'invalid' | 'unverified', scheme: string | null,
//        message: string, checked_at: string,
//        id_check: { status: 'empty' | 'passport' | 'invalid' | 'valid', message: string } }
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

// SA ID number: YYMMDD SSSS C A Z — Luhn check digit. Keep in sync with /medical-aid.js
function validateSAId(raw?: string): { status: 'empty' | 'passport' | 'invalid' | 'valid'; message: string } {
  const id = (raw || '').replace(/\s+/g, '');
  if (!id) return { status: 'empty', message: 'No ID number supplied.' };
  if (/[A-Za-z]/.test(id)) return { status: 'passport', message: 'Passport or foreign ID — not checked.' };
  if (!/^\d{13}$/.test(id)) return { status: 'invalid', message: 'SA ID numbers have 13 digits.' };
  const yy = +id.slice(0, 2), mm = +id.slice(2, 4), dd = +id.slice(4, 6);
  const year = (yy <= new Date().getFullYear() % 100 ? 2000 : 1900) + yy;
  const d = new Date(Date.UTC(year, mm - 1, dd));
  if (mm < 1 || mm > 12 || d.getUTCMonth() !== mm - 1 || d.getUTCDate() !== dd) return { status: 'invalid', message: 'ID date of birth is not a valid date.' };
  if (!'012'.includes(id[10])) return { status: 'invalid', message: 'ID citizenship digit must be 0, 1 or 2.' };
  let sum = 0;
  for (let i = 0; i < 13; i++) {
    let n = +id[12 - i];
    if (i % 2 === 1) { n *= 2; if (n > 9) n -= 9; }
    sum += n;
  }
  if (sum % 10 !== 0) return { status: 'invalid', message: 'ID check digit does not match — probably a typo.' };
  return { status: 'valid', message: 'Valid SA ID number.' };
}

// Placeholder for the real eligibility check via a switching house.
// Return null while no switch is configured so callers get 'unverified'.
async function liveCheck(_scheme: Scheme | null, _memberNumber: string, _idNumber?: string, _dependantCode?: string): Promise<'valid' | 'invalid' | null> {
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

  let body: { provider?: string; member_number?: string; id_number?: string; dependant_code?: string };
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
  const id_check = validateSAId(body.id_number);
  const dep = (body.dependant_code || '').trim();
  const notes = [
    id_check.status === 'invalid' ? id_check.message : '',
    dep && !/^\d{2}$/.test(dep) ? 'Dependant code should be two digits.' : '',
  ].filter(Boolean).join(' ');
  const withNotes = (m: string) => (notes ? `${m} ${notes}` : m);

  if (!fmt.re.test(memberNumber)) {
    return json({
      status: 'invalid',
      scheme: scheme?.name ?? null,
      message: withNotes(`Member number does not match the expected format for ${scheme?.name ?? provider} (${fmt.hint}).`),
      checked_at,
      id_check,
    });
  }

  const live = await liveCheck(scheme, memberNumber, body.id_number, dep);
  if (live) {
    return json({ status: live, scheme: scheme?.name ?? null, message: withNotes(`Live eligibility check returned: ${live}.`), checked_at, id_check });
  }

  return json({
    status: 'unverified',
    scheme: scheme?.name ?? null,
    message: withNotes(scheme
      ? `Format OK for ${scheme.name}. Live verification is not connected yet — confirm with the scheme and mark the membership verified manually.`
      : `Format OK, but "${provider}" is not in the scheme registry. Confirm the scheme name and verify manually.`),
    checked_at,
    id_check,
  });
});
