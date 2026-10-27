/* MedConsult — invite a patient and request access to their profile.
 *
 * Used by the doctor and reception screens. A doctor, or a receptionist for a doctor, enters an
 * email address or a phone number. The patient gets a link, signs in, and approves or declines.
 * Nothing is visible to the doctor until the patient approves.
 *
 *   PatientAccess.init({ sb, getDoctors, onOpenDoc })   // onOpenDoc(kind, id) is optional: lets a doctor open a document to print it
 *   PatientAccess.init({ sb, getDoctors })   // getDoctors is optional: () => [{ id, name }]
 *   PatientAccess.open()                     // invite form
 *   PatientAccess.openRequests()             // list of requests and their status
 *
 * Needs patient_access.sql to be installed. Styles are scoped with the pa- prefix.
 */
(function () {
  'use strict';
  var sb = null, getDoctors = null, onOpenDoc = null, root = null, tab = 'invite', last = null;
  var FALLBACK_ORIGIN = 'https://medconsult.africa';

  var CSS = [
    '.pa-ov{position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:2000;display:flex;align-items:center;justify-content:center;padding:16px}',
    '.pa-card{background:var(--white,#fff);color:var(--ink,#111113);width:100%;max-width:460px;max-height:92vh;overflow:auto;border-radius:14px;box-shadow:0 24px 60px rgba(0,0,0,.3);font-family:inherit}',
    '.pa-hd{display:flex;align-items:center;justify-content:space-between;padding:18px 20px 0}',
    '.pa-hd h3{margin:0;font-size:17px;font-weight:700}',
    '.pa-x{background:none;border:0;font-size:22px;line-height:1;cursor:pointer;color:var(--ink2,#5a5a65);padding:4px 8px}',
    '.pa-tabs{display:flex;gap:6px;padding:12px 20px 0}',
    '.pa-tab{border:1px solid var(--border,#d0d0da);background:transparent;color:var(--ink2,#5a5a65);border-radius:999px;padding:6px 14px;font-size:12px;font-weight:600;cursor:pointer}',
    '.pa-tab.on{background:var(--azure,#2b7fff);border-color:var(--azure,#2b7fff);color:#fff}',
    '.pa-bd{padding:16px 20px 20px}',
    '.pa-note{font-size:12.5px;line-height:1.55;color:var(--ink2,#5a5a65);margin:0 0 14px}',
    '.pa-lbl{display:block;font-size:12px;font-weight:600;margin:12px 0 5px}',
    '.pa-in{width:100%;box-sizing:border-box;padding:10px 12px;border:1px solid var(--border,#d0d0da);border-radius:8px;font:inherit;font-size:14px;background:var(--white,#fff);color:inherit}',
    '.pa-in:focus{outline:2px solid var(--azure,#2b7fff);outline-offset:0;border-color:transparent}',
    '.pa-or{text-align:center;font-size:11px;color:var(--ink3,#a8a8b8);margin:10px 0 0;letter-spacing:.06em}',
    '.pa-row{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}',
    '.pa-btn{border:1px solid var(--border,#d0d0da);background:var(--white,#fff);color:var(--ink,#111113);border-radius:8px;padding:9px 14px;font:inherit;font-size:13px;font-weight:600;cursor:pointer;text-decoration:none;display:inline-flex;align-items:center}',
    '.pa-btn.p{background:var(--azure,#2b7fff);border-color:var(--azure,#2b7fff);color:#fff}',
    '.pa-btn:disabled{opacity:.55;cursor:not-allowed}',
    '.pa-btn.sm{padding:5px 10px;font-size:12px}',
    '.pa-link{display:flex;gap:6px;margin-top:10px}',
    '.pa-link input{flex:1;min-width:0;font-size:12px;color:var(--ink2,#5a5a65)}',
    '.pa-ok{background:#ecfdf3;border:1px solid #abefc6;color:#067647;border-radius:8px;padding:10px 12px;font-size:13px;font-weight:600}',
    '.pa-err{color:#b42318;font-size:12.5px;margin-top:10px;min-height:16px}',
    '.pa-item{border:1px solid var(--border,#d0d0da);border-radius:10px;padding:11px 12px;margin-bottom:8px}',
    '.pa-item .t{display:flex;justify-content:space-between;gap:8px;align-items:flex-start;font-size:13.5px;font-weight:600}',
    '.pa-item .s{font-size:12px;color:var(--ink2,#5a5a65);margin-top:3px}',
    '.pa-pill{font-size:11px;font-weight:700;border-radius:999px;padding:2px 9px;white-space:nowrap}',
    '.pa-pill.pending,.pa-pill.requested{background:#fff4e5;color:#b54708}.pa-pill.approved,.pa-pill.ready{background:#ecfdf3;color:#067647}',
    '.pa-pill.declined,.pa-pill.revoked,.pa-pill.expired,.pa-pill.collected,.pa-pill.cancelled{background:#f2f4f7;color:#475467}',
    '.pa-empty{text-align:center;color:var(--ink2,#5a5a65);font-size:13px;padding:24px 0}'
  ].join('');

  function esc(s) {
    return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  function origin() {
    var o = location.origin;
    return (!o || o === 'null' || /^file:/.test(o) || /localhost|127\.0\.0\.1/.test(o)) ? FALLBACK_ORIGIN : o;
  }
  function linkFor(token) { return origin() + '/patient.html?access=' + encodeURIComponent(token); }
  function message(link) {
    return 'You have been invited to share your health profile with a doctor on MedConsult. ' +
           'Open this link to see who is asking, then approve or decline: ' + link;
  }
  function doctors() {
    try { var d = getDoctors ? getDoctors() : []; return Array.isArray(d) ? d : []; } catch (e) { return []; }
  }
  function say(msg, bad) {
    var el = root && root.querySelector('.pa-err');
    if (el) { el.style.color = bad ? '#b42318' : '#067647'; el.textContent = msg || ''; }
  }

  function ensureRoot() {
    if (root) return;
    var st = document.createElement('style'); st.textContent = CSS; document.head.appendChild(st);
    root = document.createElement('div');
    root.className = 'pa-ov'; root.style.display = 'none';
    root.setAttribute('role', 'dialog'); root.setAttribute('aria-modal', 'true');
    root.addEventListener('click', function (e) { if (e.target === root) close(); });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && root.style.display !== 'none') close(); });
    document.body.appendChild(root);
  }
  function close() { if (root) root.style.display = 'none'; }

  function shell(body) {
    root.innerHTML =
      '<div class="pa-card">' +
        '<div class="pa-hd"><h3>Patient access</h3><button class="pa-x" aria-label="Close" data-a="close">&times;</button></div>' +
        '<div class="pa-tabs">' +
          '<button class="pa-tab' + (tab === 'invite' ? ' on' : '') + '" data-a="tab-invite">Invite</button>' +
          '<button class="pa-tab' + (tab === 'requests' ? ' on' : '') + '" data-a="tab-requests">Requests</button>' +
          '<button class="pa-tab' + (tab === 'prints' ? ' on' : '') + '" data-a="tab-prints">Print requests</button>' +
        '</div>' +
        '<div class="pa-bd">' + body + '</div>' +
      '</div>';
    root.onclick = function (e) {
      if (e.target === root) { close(); return; }
      var a = e.target.getAttribute && e.target.getAttribute('data-a');
      if (!a) return;
      if (a === 'close') close();
      else if (a === 'tab-invite') { tab = 'invite'; last = null; renderInvite(); }
      else if (a === 'tab-requests') { tab = 'requests'; renderRequests(); }
      else if (a === 'tab-prints') { tab = 'prints'; renderPrints(); }
      else if (a === 'print-open') { if (onOpenDoc) { close(); onOpenDoc(e.target.getAttribute('data-kind'), e.target.getAttribute('data-doc')); } }
      else if (a === 'print-mark') markPrint(e.target.getAttribute('data-id'), e.target.getAttribute('data-s'));
      else if (a === 'create') create();
      else if (a === 'copy') copy(e.target.getAttribute('data-v'));
      else if (a === 'share') share();
      else if (a === 'another') { last = null; renderInvite(); }
      else if (a === 'cancel') cancel(e.target.getAttribute('data-id'));
    };
  }

  function renderInvite() {
    tab = 'invite'; ensureRoot(); root.style.display = 'flex';
    if (last) { renderDone(); return; }
    var docs = doctors();
    var sel = '';
    if (docs.length) {
      sel = '<label class="pa-lbl" for="pa-doc">Doctor the request is for</label><select class="pa-in" id="pa-doc">' +
        docs.map(function (d) { return '<option value="' + esc(d.id) + '">' + esc(d.name) + '</option>'; }).join('') + '</select>';
    }
    shell(
      '<p class="pa-note">The patient gets a link, signs in, and chooses to approve or decline. ' +
      'You can only see their profile and records after they approve, and they can withdraw access at any time.</p>' +
      sel +
      '<label class="pa-lbl" for="pa-email">Email address</label>' +
      '<input class="pa-in" id="pa-email" type="email" inputmode="email" autocomplete="off" placeholder="patient@example.com">' +
      '<div class="pa-or">OR</div>' +
      '<label class="pa-lbl" for="pa-phone">Cellphone number</label>' +
      '<input class="pa-in" id="pa-phone" type="tel" inputmode="tel" autocomplete="off" placeholder="082 123 4567">' +
      '<div class="pa-err" role="alert"></div>' +
      '<div class="pa-row"><button class="pa-btn p" data-a="create" id="pa-go">Create invite link</button></div>'
    );
  }

  function renderDone() {
    var link = linkFor(last.token), msg = message(link);
    var phone = (last.phone || '').replace(/[^0-9]/g, '');
    var canShare = typeof navigator !== 'undefined' && !!navigator.share;
    var btns = '';
    if (canShare) btns += '<button class="pa-btn p" data-a="share">Share…</button>';
    btns += '<a class="pa-btn' + (canShare ? '' : ' p') + '" target="_blank" rel="noopener" href="https://wa.me/' + esc(phone) + '?text=' + encodeURIComponent(msg) + '">WhatsApp</a>';
    if (last.phone) btns += '<a class="pa-btn" href="sms:' + esc(last.phone) + '?&body=' + encodeURIComponent(msg) + '">SMS</a>';
    if (last.email) btns += '<a class="pa-btn" href="mailto:' + esc(last.email) + '?subject=' + encodeURIComponent('Your MedConsult access request') + '&body=' + encodeURIComponent(msg) + '">Email</a>';
    shell(
      '<div class="pa-ok">' + (last.status === 'approved' ? 'This patient has already approved access.' : 'Invite link ready. It stays valid for 14 days.') + '</div>' +
      '<p class="pa-note" style="margin-top:12px">Send it yourself. MedConsult does not message the patient for you.</p>' +
      '<div class="pa-link"><input class="pa-in" readonly value="' + esc(link) + '" onclick="this.select()"><button class="pa-btn" data-a="copy" data-v="' + esc(link) + '">Copy</button></div>' +
      '<div class="pa-row">' + btns + '</div>' +
      '<div class="pa-err" role="alert"></div>' +
      '<div class="pa-row"><button class="pa-btn sm" data-a="another">Invite someone else</button><button class="pa-btn sm" data-a="tab-requests">View requests</button></div>'
    );
  }

  function create() {
    var email = root.querySelector('#pa-email').value.trim();
    var phone = root.querySelector('#pa-phone').value.trim();
    var docSel = root.querySelector('#pa-doc');
    if (!email && !phone) { say('Enter an email address or a cellphone number.', true); return; }
    var btn = root.querySelector('#pa-go'); btn.disabled = true; btn.textContent = 'Creating…'; say('');
    sb.rpc('request_patient_access', { p_email: email || null, p_phone: phone || null, p_doctor: docSel ? docSel.value : null })
      .then(function (r) {
        if (r.error || !r.data) {
          btn.disabled = false; btn.textContent = 'Create invite link';
          say((r.error && r.error.message) || 'Could not create the invite.', true); return;
        }
        last = { token: r.data.token, status: r.data.status, email: email, phone: phone };
        renderDone();
      });
  }

  function copy(text) {
    var done = function () { say('Link copied.', false); };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
    else { fallbackCopy(text); done(); }
  }
  function fallbackCopy(text) {
    var i = root.querySelector('.pa-link input'); if (i) { i.select(); try { document.execCommand('copy'); } catch (e) {} }
  }
  function share() {
    var link = linkFor(last.token);
    navigator.share({ title: 'MedConsult access request', text: message(link), url: link }).catch(function () {});
  }

  function renderRequests() {
    tab = 'requests'; ensureRoot(); root.style.display = 'flex';
    shell('<div class="pa-empty">Loading…</div>');
    sb.rpc('list_access_requests').then(function (r) {
      var body = root.querySelector('.pa-bd');
      if (r.error) { body.innerHTML = '<div class="pa-err">' + esc(r.error.message) + '</div>'; return; }
      var rows = r.data || [];
      if (!rows.length) { body.innerHTML = '<div class="pa-empty">No requests yet.</div>'; return; }
      var multi = {}; rows.forEach(function (x) { multi[x.dr_id] = 1; });
      var showDr = Object.keys(multi).length > 1;
      body.innerHTML = rows.map(function (x) {
        var who = x.patient_name || x.contact_email || x.contact_phone || 'Patient';
        var sub = [];
        if (x.patient_name && x.contact_email) sub.push(x.contact_email);
        if (showDr) sub.push('For ' + x.dr_name);
        sub.push(new Date(x.requested_at).toLocaleDateString());
        var actions = '';
        if (x.access_status === 'pending') {
          actions = '<div class="pa-row" style="margin-top:8px">' +
            (x.link_token ? '<button class="pa-btn sm" data-a="copy" data-v="' + esc(linkFor(x.link_token)) + '">Copy link</button>' : '') +
            '<button class="pa-btn sm" data-a="cancel" data-id="' + esc(x.access_id) + '">Cancel</button></div>';
        }
        return '<div class="pa-item"><div class="t"><span>' + esc(who) + '</span><span class="pa-pill ' + esc(x.access_status) + '">' + esc(x.access_status) + '</span></div>' +
               '<div class="s">' + esc(sub.join(' · ')) + '</div>' + actions + '</div>';
      }).join('') + '<div class="pa-err" role="alert"></div>';
    });
  }

  // Printed copies patients asked for. Staff see type, date and reference only; the doctor opens the document to print it.
  var KIND = { sick_note: 'Sick note', prescription: 'Prescription', record: 'Consultation record' };
  function renderPrints() {
    tab = 'prints'; ensureRoot(); root.style.display = 'flex';
    shell('<div class="pa-empty">Loading…</div>');
    sb.rpc('list_print_requests').then(function (r) {
      var body = root.querySelector('.pa-bd');
      if (r.error) { body.innerHTML = '<div class="pa-err">' + esc(r.error.message) + '</div>'; return; }
      var rows = r.data || [];
      if (!rows.length) { body.innerHTML = '<div class="pa-empty">No print requests.</div>'; return; }
      var multi = {}; rows.forEach(function (x) { multi[x.dr_id] = 1; });
      var showDr = Object.keys(multi).length > 1;
      body.innerHTML = rows.map(function (x) {
        var sub = [KIND[x.kind] || x.kind, x.doc_ref, x.doc_date ? new Date(x.doc_date + 'T00:00:00').toLocaleDateString() : '', showDr ? 'Dr. ' + x.dr_name : ''].filter(Boolean);
        var id = esc(x.id), act = '';
        if (x.status === 'requested') {
          act = (onOpenDoc ? '<button class="pa-btn sm" data-a="print-open" data-kind="' + esc(x.kind) + '" data-doc="' + esc(x.doc_id) + '">Open to print</button>' : '') +
                '<button class="pa-btn sm" data-a="print-mark" data-s="ready" data-id="' + id + '">Mark ready</button>';
        } else if (x.status === 'ready') {
          act = '<button class="pa-btn sm" data-a="print-mark" data-s="collected" data-id="' + id + '">Collected</button>';
        }
        if (x.status === 'requested' || x.status === 'ready') act += '<button class="pa-btn sm" data-a="print-mark" data-s="cancelled" data-id="' + id + '">Cancel</button>';
        return '<div class="pa-item"><div class="t"><span>' + esc(x.patient_name) + '</span><span class="pa-pill ' + esc(x.status) + '">' + esc(x.status) + '</span></div>' +
               '<div class="s">' + esc(sub.join(' · ')) + '</div>' + (act ? '<div class="pa-row" style="margin-top:8px">' + act + '</div>' : '') + '</div>';
      }).join('') + '<div class="pa-err" role="alert"></div>';
    });
  }
  function markPrint(id, status) {
    sb.rpc('mark_print_request', { p_id: id, p_status: status }).then(function (r) {
      if (r.error) { say(r.error.message, true); return; }
      renderPrints();
    });
  }

  function cancel(id) {
    sb.rpc('cancel_access_request', { p_id: id }).then(function (r) {
      if (r.error) { say(r.error.message, true); return; }
      renderRequests();
    });
  }

  window.PatientAccess = {
    init: function (opts) { sb = opts.sb; getDoctors = opts.getDoctors || null; onOpenDoc = opts.onOpenDoc || null; },
    open: function () { if (!sb) return; last = null; renderInvite(); },
    openRequests: function () { if (!sb) return; renderRequests(); },
    openPrints: function () { if (!sb) return; renderPrints(); }
  };
})();
