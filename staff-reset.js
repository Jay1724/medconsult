/*
 * MedConsult forgot-password for the doctor, reception and practice portals.
 *
 *   StaffReset.init({ sb, passwordInput: '#l-pass', emailInput: '#l-email' })
 *
 * Adds a "Forgot your password?" link under the password box. The link opens a small dialog that asks for the email and
 * sends Supabase's reset email (always the same answer, so nobody can find out who has an account). The email link brings
 * the person back to the same portal page, where a "Choose a new password" dialog appears before anything else.
 * Needs the portal addresses in Supabase: Authentication > URL Configuration > Redirect URLs.
 */
(function () {
  'use strict';
  var sb = null, root = null, KEY = 'mc_recovering';

  var CSS = [
    '.sr-ov{position:fixed;inset:0;background:rgba(0,0,0,.65);z-index:20000;display:flex;align-items:center;justify-content:center;padding:16px}',
    '.sr-card{background:#fff;color:#111113;width:100%;max-width:400px;border-radius:14px;box-shadow:0 24px 60px rgba(0,0,0,.35);padding:22px;font-family:inherit;position:relative}',
    '.sr-card h3{margin:0 0 6px;font-size:18px;font-weight:700}',
    '.sr-card p{margin:0 0 14px;font-size:13px;line-height:1.55;color:#5a5a65}',
    '.sr-card input{width:100%;box-sizing:border-box;padding:12px 13px;border:1px solid #d0d0da;border-radius:10px;font-size:15px;margin:0 0 10px;background:#fff;color:#111113;font-family:inherit}',
    '.sr-btn{width:100%;border:0;border-radius:10px;padding:12px;font-size:14px;font-weight:600;cursor:pointer;background:#2b7fff;color:#fff;margin-top:2px}',
    '.sr-btn.ghost{background:transparent;color:#5a5a65;border:1px solid #d0d0da;margin-top:8px}',
    '.sr-btn[disabled]{opacity:.6;cursor:default}',
    '.sr-x{position:absolute;top:10px;right:12px;width:30px;height:30px;border:0;border-radius:50%;background:#f2f2f6;color:#5a5a65;font-size:20px;line-height:1;cursor:pointer}',
    '.sr-err{color:#b42318;font-size:12.5px;min-height:16px;margin:0 0 8px}',
    '.sr-ok{color:#067647;font-size:13px;line-height:1.55;margin:0 0 6px}',
    '.sr-link{display:block;text-align:center;margin-top:12px;font-size:13px;font-weight:600;color:#2b7fff;cursor:pointer;text-decoration:none}'
  ].join('');

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function ensureRoot() {
    if (root) return;
    var st = document.createElement('style'); st.textContent = CSS; document.head.appendChild(st);
    root = document.createElement('div'); root.className = 'sr-ov'; root.style.display = 'none'; document.body.appendChild(root);
  }
  function show(html) { ensureRoot(); root.innerHTML = '<div class="sr-card">' + html + '</div>'; root.style.display = 'flex'; }
  function hide() { if (root) root.style.display = 'none'; }
  function $(s) { return root.querySelector(s); }

  function askEmail(prefill, notice) {
    show('<button class="sr-x" id="sr-x" aria-label="Close">&times;</button><h3>Reset your password</h3>' +
      '<p>Enter the email you signed up with. If it matches an account, we will email you a link to choose a new password.</p>' +
      (notice ? '<div class="sr-err">' + esc(notice) + '</div>' : '') +
      '<input type="email" id="sr-email" placeholder="you@practice.co.za" autocomplete="email" value="' + esc(prefill || '') + '">' +
      '<div class="sr-err" id="sr-err"></div><button class="sr-btn" id="sr-go">Send reset link</button>');
    $('#sr-x').onclick = hide;
    var go = $('#sr-go'), input = $('#sr-email'), err = $('#sr-err');
    input.focus();
    input.onkeydown = function (e) { if (e.key === 'Enter') go.click(); };
    go.onclick = function () {
      var email = input.value.trim();
      if (!email) { err.textContent = 'Please enter your email.'; return; }
      go.disabled = true; go.textContent = 'Sending…'; err.textContent = '';
      sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname }).then(function (r) {
        if (r.error && /rate|seconds|too many/i.test(r.error.message || '')) { go.disabled = false; go.textContent = 'Send reset link'; err.textContent = 'Please wait a minute before asking again.'; return; }
        show('<button class="sr-x" id="sr-x" aria-label="Close">&times;</button><h3>Check your email</h3><div class="sr-ok">If that email has an account, a reset link is on its way. Check your inbox and spam folder.</div><button class="sr-btn ghost" id="sr-done">Back to sign in</button>');
        $('#sr-x').onclick = hide; $('#sr-done').onclick = hide;
      });
    };
  }

  function chooseNew() {
    show('<h3>Choose a new password</h3><p>Use at least 8 characters.</p>' +
      '<input type="password" id="sr-p1" placeholder="New password" autocomplete="new-password">' +
      '<input type="password" id="sr-p2" placeholder="Repeat new password" autocomplete="new-password">' +
      '<div class="sr-err" id="sr-err"></div><button class="sr-btn" id="sr-go">Save password and continue</button>');
    var go = $('#sr-go'), p1 = $('#sr-p1'), p2 = $('#sr-p2'), err = $('#sr-err');
    p1.focus();
    p2.onkeydown = function (e) { if (e.key === 'Enter') go.click(); };
    go.onclick = function () {
      if (p1.value.length < 8) { err.textContent = 'Password must be at least 8 characters.'; return; }
      if (p1.value !== p2.value) { err.textContent = 'The two passwords do not match.'; return; }
      go.disabled = true; go.textContent = 'Saving…'; err.textContent = '';
      sb.auth.updateUser({ password: p1.value }).then(function (r) {
        if (r.error) { go.disabled = false; go.textContent = 'Save password and continue'; err.textContent = r.error.message; return; }
        try { sessionStorage.removeItem(KEY); } catch (e) {}
        location.replace(location.pathname);   // start clean: the portal now signs in (and asks for the authenticator code if set up)
      });
    };
  }

  function addLink(opts) {
    var pw = document.querySelector(opts.passwordInput || '#l-pass');
    if (!pw || pw.parentNode.querySelector('.sr-link')) return;
    var a = document.createElement('a'); a.className = 'sr-link'; a.href = '#'; a.textContent = 'Forgot your password?';
    a.onclick = function (e) { e.preventDefault(); var em = document.querySelector(opts.emailInput || '#l-email'); askEmail(em ? em.value.trim() : ''); };
    pw.insertAdjacentElement('afterend', a);
  }

  function init(opts) {
    sb = opts.sb; opts = opts || {};
    addLink(opts);
    var hash = location.hash || '';
    if (/error_code=|error=access_denied/.test(hash)) {
      history.replaceState(null, '', location.pathname);
      askEmail('', 'That reset link has expired or was already used. Ask for a new one.');
      return;
    }
    if (/type=recovery/.test(hash)) { try { sessionStorage.setItem(KEY, '1'); } catch (e) {} history.replaceState(null, '', location.pathname); }
    var recovering = false; try { recovering = !!sessionStorage.getItem(KEY); } catch (e) {}
    if (recovering) {
      sb.auth.getSession().then(function (r) {
        if (r.data && r.data.session) chooseNew();
        else { try { sessionStorage.removeItem(KEY); } catch (e) {} }
      });
    }
  }

  window.StaffReset = { init: init, open: function (email) { ensureRoot(); askEmail(email || ''); } };
})();
