/*
 * MedConsult two-factor sign-in for doctors and staff (authenticator app / TOTP, built on Supabase Auth MFA).
 *
 *   StaffMFA.init({ sb })           once, after the Supabase client exists
 *   await StaffMFA.require()        call right after a password sign-in or a restored session, BEFORE showing the app.
 *                                   Resolves true when it is fine to continue, false when the person signed out.
 *   StaffMFA.openSettings()         set up or turn off two-factor (wire to a button)
 *
 * The database enforces the same rule (staff_mfa.sql): once someone has a second factor, password-only sessions
 * cannot read patient data. This file only collects the code and handles set-up.
 */
(function () {
  'use strict';
  var sb = null, root = null;

  var CSS = [
    '.mf-ov{position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:3000;display:flex;align-items:center;justify-content:center;padding:16px}',
    '.mf-card{background:var(--white,#fff);color:var(--ink,#111113);width:100%;max-width:400px;max-height:92vh;overflow:auto;border-radius:14px;box-shadow:0 24px 60px rgba(0,0,0,.3);padding:22px 22px 20px;font-family:inherit}',
    '.mf-card h3{margin:0 0 6px;font-size:18px;font-weight:700}',
    '.mf-card p{margin:0 0 14px;font-size:13px;line-height:1.55;color:var(--ink2,#5a5a65)}',
    '.mf-code{width:100%;box-sizing:border-box;font-size:26px;letter-spacing:.35em;text-align:center;padding:12px;border:1px solid var(--border,#d0d0da);border-radius:10px;background:transparent;color:inherit;margin-bottom:12px;font-family:monospace}',
    '.mf-btn{width:100%;border:0;border-radius:10px;padding:12px;font-size:14px;font-weight:600;cursor:pointer;background:var(--azure,#2b7fff);color:#fff;margin-bottom:8px}',
    '.mf-btn.ghost{background:transparent;color:var(--ink2,#5a5a65);border:1px solid var(--border,#d0d0da)}',
    '.mf-btn[disabled]{opacity:.6;cursor:default}',
    '.mf-err{color:#b42318;font-size:12.5px;min-height:18px;margin:0 0 8px}',
    '.mf-qr{display:block;margin:6px auto 10px;width:180px;height:180px;background:#fff;border-radius:8px;padding:6px}',
    '.mf-secret{font-family:monospace;font-size:12px;word-break:break-all;background:rgba(127,127,127,.12);padding:8px 10px;border-radius:8px;margin-bottom:12px}',
    '.mf-bar{position:fixed;left:50%;bottom:16px;transform:translateX(-50%);z-index:2500;background:#1d2939;color:#fff;border-radius:12px;padding:10px 14px;font-size:13px;display:flex;gap:12px;align-items:center;box-shadow:0 8px 24px rgba(0,0,0,.3);max-width:calc(100vw - 32px)}',
    '.mf-bar button{background:#fff;color:#1d2939;border:0;border-radius:8px;padding:6px 10px;font-weight:600;cursor:pointer;font-size:12px}',
    '.mf-bar .x{background:transparent;color:#cbd5e1;font-size:16px;padding:0 4px}'
  ].join('');

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function ensureRoot() {
    if (root) return;
    var st = document.createElement('style'); st.textContent = CSS; document.head.appendChild(st);
    root = document.createElement('div'); root.className = 'mf-ov'; root.style.display = 'none'; document.body.appendChild(root);
  }
  function show(html) { ensureRoot(); root.innerHTML = '<div class="mf-card">' + html + '</div>'; root.style.display = 'flex'; }
  function hide() { if (root) root.style.display = 'none'; }
  function $(sel) { return root.querySelector(sel); }
  function err(msg) { var e = $('.mf-err'); if (e) e.textContent = msg || ''; }
  function busy(btn, on, label) { btn.disabled = on; if (label) btn.textContent = label; }
  function cleanCode(v) { return String(v || '').replace(/\D/g, '').slice(0, 6); }

  function state() {
    return Promise.all([sb.auth.mfa.getAuthenticatorAssuranceLevel(), sb.auth.mfa.listFactors()]).then(function (r) {
      var aal = r[0].data || {}, f = r[1].data || {};
      return { current: aal.currentLevel, next: aal.nextLevel, verified: (f.totp || [])[0] || null, all: f.all || [] };
    });
  }

  // Ask for the 6-digit code. Resolves true once verified, false if the person chose to sign out.
  function askCode(factorId) {
    return new Promise(function (resolve) {
      show('<h3>Two-factor sign-in</h3><p>Open your authenticator app and enter the 6-digit code for MedConsult.</p>' +
           '<input class="mf-code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="······" aria-label="6-digit code">' +
           '<div class="mf-err" role="alert"></div>' +
           '<button class="mf-btn" id="mf-go">Verify</button><button class="mf-btn ghost" id="mf-out">Sign out</button>');
      var input = $('.mf-code'), go = $('#mf-go');
      input.focus();
      input.addEventListener('input', function () { input.value = cleanCode(input.value); if (input.value.length === 6) go.click(); });
      $('#mf-out').onclick = function () { sb.auth.signOut().then(function () { hide(); resolve(false); }); };
      go.onclick = function () {
        if (input.value.length !== 6) { err('Enter the 6-digit code.'); return; }
        busy(go, true, 'Checking…'); err('');
        sb.auth.mfa.challengeAndVerify({ factorId: factorId, code: input.value }).then(function (r) {
          if (r.error) { busy(go, false, 'Verify'); input.value = ''; input.focus(); err('That code did not work. Check the code and your phone clock, then try again.'); return; }
          hide(); resolve(true);
        });
      };
    });
  }

  function nudge() {
    try { if (sessionStorage.getItem('mf_nudge')) return; sessionStorage.setItem('mf_nudge', '1'); } catch (e) {}
    var bar = document.createElement('div'); bar.className = 'mf-bar';
    bar.innerHTML = '<span>Protect patient records: turn on two-factor sign-in.</span><button data-a="set">Set up</button><button class="x" data-a="x" aria-label="Dismiss">&times;</button>';
    bar.onclick = function (e) { var a = e.target.getAttribute && e.target.getAttribute('data-a'); if (a === 'set') { bar.remove(); openSettings(); } else if (a === 'x') bar.remove(); };
    document.body.appendChild(bar);
  }

  function require() {
    if (!sb) return Promise.resolve(true);
    return state().then(function (s) {
      if (s.verified && s.current !== 'aal2') return askCode(s.verified.id);
      if (!s.verified) nudge();
      return true;
    }).catch(function () { return true; });   // never lock people out because this check itself failed; the database still enforces the rule
  }

  function openSettings() {
    if (!sb) return;
    state().then(function (s) {
      if (s.verified) {
        show('<h3>Two-factor sign-in</h3><p>It is <strong>on</strong>. You will be asked for a code from your authenticator app each time you sign in.</p>' +
             '<div class="mf-err" role="alert"></div><button class="mf-btn ghost" id="mf-off">Turn off</button><button class="mf-btn" id="mf-close">Done</button>');
        $('#mf-close').onclick = hide;
        $('#mf-off').onclick = function () {
          if (s.current !== 'aal2') { err('Sign in again with your code before turning it off.'); return; }
          if (!window.confirm('Turn off two-factor sign-in? Your account will be protected by your password only.')) return;
          sb.auth.mfa.unenroll({ factorId: s.verified.id }).then(function (r) { if (r.error) err(r.error.message); else { hide(); } });
        };
        return;
      }
      show('<h3>Set up two-factor sign-in</h3><p>You will need an authenticator app such as Google Authenticator, Microsoft Authenticator or Authy.</p>' +
           '<button class="mf-btn" id="mf-start">Start</button><button class="mf-btn ghost" id="mf-close">Not now</button>');
      $('#mf-close').onclick = hide;
      $('#mf-start').onclick = function () { enroll(s.all); };
    });
  }

  function enroll(all) {
    // clear any half-finished set-up from before
    var clear = Promise.all((all || []).filter(function (f) { return f.status === 'unverified'; }).map(function (f) { return sb.auth.mfa.unenroll({ factorId: f.id }); }));
    clear.then(function () { return sb.auth.mfa.enroll({ factorType: 'totp', friendlyName: 'MedConsult ' + new Date().toISOString().slice(0, 10) }); }).then(function (r) {
      if (r.error) { show('<h3>Could not start</h3><p>' + esc(r.error.message) + '</p><button class="mf-btn" id="mf-close">Close</button>'); $('#mf-close').onclick = hide; return; }
      var f = r.data;
      show('<h3>Scan this code</h3><p>Scan it with your authenticator app, then enter the 6-digit code it shows.</p>' +
           '<img class="mf-qr" alt="QR code for your authenticator app" src="' + esc(f.totp.qr_code) + '">' +
           '<p style="margin-bottom:6px">Can\'t scan? Enter this key by hand:</p><div class="mf-secret">' + esc(f.totp.secret) + '</div>' +
           '<input class="mf-code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="······" aria-label="6-digit code">' +
           '<div class="mf-err" role="alert"></div><button class="mf-btn" id="mf-go">Turn on</button><button class="mf-btn ghost" id="mf-close">Cancel</button>');
      var input = $('.mf-code'), go = $('#mf-go');
      input.addEventListener('input', function () { input.value = cleanCode(input.value); });
      $('#mf-close').onclick = function () { sb.auth.mfa.unenroll({ factorId: f.id }).then(hide, hide); };
      go.onclick = function () {
        if (input.value.length !== 6) { err('Enter the 6-digit code.'); return; }
        busy(go, true, 'Checking…'); err('');
        sb.auth.mfa.challengeAndVerify({ factorId: f.id, code: input.value }).then(function (v) {
          if (v.error) { busy(go, false, 'Turn on'); input.value = ''; err('That code did not work. Try the next code.'); return; }
          show('<h3>Two-factor is on</h3><p>From now on you will enter a code each time you sign in. Keep your phone safe; if you lose it, ask your practice owner to help you recover access.</p><button class="mf-btn" id="mf-close">Done</button>');
          $('#mf-close').onclick = hide;
        });
      };
    });
  }

  window.StaffMFA = { init: function (o) { sb = o.sb; }, require: require, openSettings: openSettings };
})();
