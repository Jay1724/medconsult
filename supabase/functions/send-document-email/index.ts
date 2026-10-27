// Emails a newly issued sick note / prescription (as a PDF) or a "new record" notice to the patient.
// Called by the doctor's browser with their own login. Reads go through the caller's JWT, so row-level
// security decides whether they may send this document; the function never uses the service role.
//
// Secrets: RESEND_API_KEY (required), FROM_EMAIL (optional, e.g. "MedConsult <noreply@medconsult.africa>").
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sickNotePdf, prescriptionPdf } from './pdf.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
const b64 = (u: Uint8Array) => { let s = ''; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000)); return btoa(s); };

const TABLES: Record<string, string> = { sick_note: 'sick_notes', prescription: 'prescriptions', record: 'records' };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const auth = req.headers.get('Authorization') ?? '';
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
  const { data: u } = await sb.auth.getUser();
  if (!u?.user) return json({ error: 'Please sign in' }, 401);

  let body: any; try { body = await req.json(); } catch { return json({ error: 'Bad request' }, 400); }
  const table = TABLES[body?.kind];
  if (!table || typeof body?.id !== 'string') return json({ error: 'Bad request' }, 400);

  // RLS: only a document the signed-in doctor may read comes back.
  const { data: row, error } = await sb.from(table).select('*').eq('id', body.id).maybeSingle();
  if (error || !row) return json({ error: 'Document not found' }, 404);

  const { data: pat } = await sb.from('patients').select('first_name,last_name,email,id_number').eq('id', row.patient_id).maybeSingle();
  if (!pat?.email) return json({ sent: false, reason: 'no_email' });
  const { data: doc } = await sb.from('doctors').select('id,first_name,last_name,hpcsa,prac_name,prac_num,prac_addr,phone').eq('id', row.doctor_id).maybeSingle();
  if (!doc) return json({ error: 'Doctor profile not found' }, 404);

  const drName = 'Dr. ' + doc.first_name + ' ' + doc.last_name;
  const pdfDoc = { name: drName, hpcsa: doc.hpcsa, prac_name: doc.prac_name, prac_num: doc.prac_num, prac_addr: doc.prac_addr, phone: doc.phone };
  const patName = pat.first_name + ' ' + pat.last_name;
  const portal = 'https://medconsult.africa/patient.html';

  let subject: string, what: string, attachments: { filename: string; content: string }[] = [];
  if (body.kind === 'sick_note') {
    subject = 'Your sick note from ' + drName; what = 'a sick note';
    attachments = [{ filename: row.ref_number + '.pdf', content: b64(await sickNotePdf(row, patName, pat.id_number, pdfDoc)) }];
  } else if (body.kind === 'prescription') {
    subject = 'Your prescription from ' + drName; what = 'a prescription';
    attachments = [{ filename: row.ref_number + '.pdf', content: b64(await prescriptionPdf(row, patName, pdfDoc)) }];
  } else {
    subject = 'New update in your MedConsult record'; what = 'a new consultation record';
  }

  const html = `<div style="font-family:Arial,sans-serif;max-width:520px;color:#111">
    <p>Hi ${esc(pat.first_name)},</p>
    <p>${esc(drName)} has added ${what} for you on MedConsult.${attachments.length ? ' It is attached to this email.' : ''}</p>
    <p><a href="${portal}" style="background:#2563eb;color:#fff;padding:10px 16px;border-radius:8px;text-decoration:none">Open your patient portal</a></p>
    <p style="font-size:12px;color:#666">This message is confidential and meant only for you. If you were not expecting it, please ignore it and let your practice know.</p></div>`;

  const key = Deno.env.get('RESEND_API_KEY');
  if (!key) return json({ error: 'Email is not configured yet' }, 503);
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: Deno.env.get('FROM_EMAIL') ?? 'MedConsult <noreply@medconsult.africa>', to: [pat.email], subject, html, attachments }),
  });
  if (!r.ok) return json({ error: 'The email service refused the message' }, 502);
  return json({ sent: true });
});
