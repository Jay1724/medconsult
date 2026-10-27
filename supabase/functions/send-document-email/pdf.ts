// PDF builders for documents emailed to patients. Pure functions (pdf-lib only) so they can be tested in Node.
import { PDFDocument, StandardFonts, rgb } from 'npm:pdf-lib@1.17.1';

type Doc = { name?: string; hpcsa?: string; prac_name?: string; prac_num?: string; prac_addr?: string; phone?: string };

const INK = rgb(0.07, 0.09, 0.15), MUTED = rgb(0.4, 0.44, 0.5), LINE = rgb(0.88, 0.89, 0.92);

export function fmt(d?: string | null) {
  if (!d) return '';
  const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  const x = new Date(d + (d.includes('T') ? '' : 'T00:00:00'));
  return `${x.getDate()} ${m[x.getMonth()]} ${x.getFullYear()}`;
}

async function base(title: string, subtitle: string, doc: Doc) {
  const pdf = await PDFDocument.create();
  const page = pdf.addPage([595, 842]);
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const w = (s: string) => s.replace(/[\u2013\u2014]/g, '-').replace(/[\u2018\u2019]/g, "'").replace(/[\u201C\u201D]/g, '"').replace(/[^\x20-\x7E -ÿ]/g, '?');   // Helvetica is WinAnsi only
  let y = 790;
  page.drawText(w(doc.prac_name || 'MedConsult'), { x: 48, y, size: 11, font: bold, color: INK });
  y -= 14;
  const meta = [doc.prac_addr, doc.phone, doc.prac_num ? 'Practice no. ' + doc.prac_num : ''].filter(Boolean).join('  |  ');
  if (meta) page.drawText(w(meta), { x: 48, y, size: 8.5, font, color: MUTED });
  y -= 44;
  page.drawText(w(title), { x: 48, y, size: 24, font: bold, color: INK });
  y -= 18;
  page.drawText(w(subtitle), { x: 48, y, size: 10, font, color: MUTED });
  y -= 30;
  const row = (k: string, v: string) => {
    page.drawLine({ start: { x: 48, y: y + 14 }, end: { x: 547, y: y + 14 }, thickness: 0.5, color: LINE });
    page.drawText(w(k.toUpperCase()), { x: 48, y, size: 8, font: bold, color: MUTED });
    const lines = wrap(w(v), font, 11, 330);
    lines.forEach((l, i) => page.drawText(l, { x: 200, y: y - i * 14, size: 11, font, color: INK }));
    y -= Math.max(1, lines.length) * 14 + 14;
  };
  return { pdf, page, font, bold, w, row, getY: () => y, setY: (v: number) => { y = v; } };
}

function wrap(text: string, font: any, size: number, max: number) {
  const out: string[] = []; let line = '';
  for (const word of text.split(/\s+/)) {
    const t = line ? line + ' ' + word : word;
    if (font.widthOfTextAtSize(t, size) > max && line) { out.push(line); line = word; } else line = t;
  }
  if (line) out.push(line);
  return out;
}

async function footer(b: Awaited<ReturnType<typeof base>>, doc: Doc, sigImg?: string | null) {
  let y = b.getY() - 30;
  if (sigImg && sigImg.startsWith('data:image/png;base64,')) {
    try {
      const bytes = Uint8Array.from(atob(sigImg.split(',')[1]), (c) => c.charCodeAt(0));
      const img = await b.pdf.embedPng(bytes);
      const s = img.scale(Math.min(1, 160 / img.width, 60 / img.height));
      b.page.drawImage(img, { x: 48, y: y - s.height, width: s.width, height: s.height });
      y -= s.height + 6;
    } catch { /* unreadable signature image: print name only */ }
  }
  b.page.drawLine({ start: { x: 48, y }, end: { x: 220, y }, thickness: 0.5, color: INK });
  y -= 14;
  b.page.drawText(b.w(doc.name || 'Attending practitioner'), { x: 48, y, size: 11, font: b.bold, color: INK });
  if (doc.hpcsa) { y -= 13; b.page.drawText(b.w('HPCSA ' + doc.hpcsa), { x: 48, y, size: 9, font: b.font, color: MUTED }); }
  b.page.drawText('Issued electronically via MedConsult. Confidential: intended only for the person named above.',
    { x: 48, y: 40, size: 8, font: b.font, color: MUTED });
}

// Diagnosis is deliberately left off: employers do not need it, and email is not a private channel.
export async function sickNotePdf(n: any, patientName: string, patientId: string | null, doc: Doc) {
  const b = await base('Medical Certificate', 'Sick note  |  Ref ' + n.ref_number, doc);
  b.row('Patient', patientName);
  if (patientId) b.row('ID number', patientId);
  b.row('Date issued', fmt(n.issue_date));
  b.row('Unfit for work from', fmt(n.rest_from || n.issue_date));
  b.row('Unfit for work until', fmt(n.rest_to || n.issue_date));
  if (n.instructions) b.row('Notes', n.instructions);
  await footer(b, doc, n.sig_image);
  return await b.pdf.save();
}

export async function prescriptionPdf(r: any, patientName: string, doc: Doc) {
  const b = await base('Prescription', 'Electronic script  |  Ref ' + r.ref_number, doc);
  b.row('Patient', patientName);
  b.row('Date', fmt(r.script_date));
  b.row('Repeats', r.repeats && r.repeats !== '0' ? r.repeats : 'None');
  const meds = Array.isArray(r.medications) ? r.medications : [];
  meds.filter((m: any) => m?.name).forEach((m: any, i: number) =>
    b.row('Medication ' + (i + 1), [m.name + (m.str ? ' ' + m.str : ''), m.dose, m.qty ? 'Qty: ' + m.qty : '', m.inst].filter(Boolean).join(' | ')));
  await footer(b, doc, r.sig_image);
  return await b.pdf.save();
}
