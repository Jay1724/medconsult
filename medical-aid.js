/* ─────────────────────────────────────────────────────────────────────────────
   MedConsult — Medical Aid scheme registry + member number validation
   Shared by reception.html and doctor.html (and mirrored server-side in
   supabase/functions/check-medical-aid).

   Member number patterns are heuristics to catch capture typos — schemes do
   not publish authoritative formats. A "format OK" result does NOT mean the
   membership is active; only a live check via a switching house (Healthbridge,
   MediSwitch, MediKredit) or the scheme itself can confirm that.
   ───────────────────────────────────────────────────────────────────────────── */
window.MedicalAid = (function () {
  'use strict';

  // Permissive fallback for schemes without a known digit-only convention.
  var GENERIC = { re: /^[A-Za-z0-9][A-Za-z0-9\/\- ]{2,19}$/, hint: '4–20 characters: letters, digits, spaces, "-" or "/"' };
  var DIGITS = function (min, max) {
    return { re: new RegExp('^\\d{' + min + ',' + max + '}$'), hint: min + '–' + max + ' digits' };
  };

  // Major CMS-registered schemes (open + large restricted).
  var SCHEMES = [
    { name: 'Discovery Health Medical Scheme', aliases: ['discovery', 'discovery health'], format: DIGITS(8, 11) },
    { name: 'Government Employees Medical Scheme (GEMS)', aliases: ['gems', 'government employees'], format: DIGITS(7, 10) },
    { name: 'Bonitas Medical Fund', aliases: ['bonitas'], format: DIGITS(7, 10) },
    { name: 'Momentum Medical Scheme', aliases: ['momentum', 'momentum health'] },
    { name: 'Bestmed Medical Scheme', aliases: ['bestmed'], format: DIGITS(6, 10) },
    { name: 'Medihelp', aliases: ['medihelp'], format: DIGITS(6, 10) },
    { name: 'Medshield Medical Scheme', aliases: ['medshield'], format: DIGITS(6, 10) },
    { name: 'Fedhealth Medical Scheme', aliases: ['fedhealth'] },
    { name: 'Sizwe Hosmed Medical Scheme', aliases: ['sizwe', 'hosmed', 'sizwe hosmed'] },
    { name: 'Profmed', aliases: ['profmed'] },
    { name: 'KeyHealth Medical Scheme', aliases: ['keyhealth', 'key health'] },
    { name: 'Bankmed', aliases: ['bankmed'], format: DIGITS(6, 10) },
    { name: 'Polmed (SAPS Medical Scheme)', aliases: ['polmed', 'saps'], format: DIGITS(6, 10) },
    { name: 'LA Health Medical Scheme', aliases: ['la health'] },
    { name: 'Camaf (Chartered Accountants Medical Aid Fund)', aliases: ['camaf'] },
    { name: 'Suremed Health', aliases: ['suremed'] },
    { name: 'Genesis Medical Scheme', aliases: ['genesis'] }
  ];

  function norm(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim(); }

  // Match a free-text provider name to a scheme in the registry (exact name,
  // alias, or either containing the other). Returns the scheme or null.
  function findScheme(provider) {
    var q = norm(provider);
    if (!q) return null;
    for (var i = 0; i < SCHEMES.length; i++) {
      var s = SCHEMES[i];
      var candidates = [norm(s.name)].concat(s.aliases.map(norm));
      for (var j = 0; j < candidates.length; j++) {
        if (candidates[j] === q || candidates[j].indexOf(q) !== -1 || q.indexOf(candidates[j]) !== -1) return s;
      }
    }
    return null;
  }

  function schemeNames() { return SCHEMES.map(function (s) { return s.name; }); }

  /* Validate captured details. Returns:
     { status: 'no_aid' | 'unknown_scheme' | 'format_ok' | 'format_invalid',
       scheme: matched registry name or null,
       hint:   expected format description,
       message: human-readable summary }                                      */
  function validate(provider, memberNumber) {
    provider = String(provider || '').trim();
    memberNumber = String(memberNumber || '').trim();
    if (!provider && !memberNumber) return { status: 'no_aid', scheme: null, hint: '', message: 'No medical aid captured (self-pay).' };

    var scheme = findScheme(provider);
    var fmt = (scheme && scheme.format) || GENERIC;
    var name = scheme ? scheme.name : provider;

    if (!memberNumber) {
      return { status: 'format_invalid', scheme: scheme && scheme.name, hint: fmt.hint, message: 'Member number is required when a provider is given.' };
    }
    if (!fmt.re.test(memberNumber)) {
      return { status: 'format_invalid', scheme: scheme && scheme.name, hint: fmt.hint, message: 'Member number does not look valid for ' + name + ' (expected ' + fmt.hint + ').' };
    }
    if (!scheme) {
      var guess = suggestScheme(provider);
      return { status: 'unknown_scheme', scheme: null, hint: fmt.hint, suggestion: guess,
        message: guess
          ? '"' + provider + '" is not in the scheme registry. Did you mean ' + guess + '?'
          : '"' + provider + '" is not in the scheme registry — number format looks plausible, please double-check the scheme name.' };
    }
    return { status: 'format_ok', scheme: scheme.name, hint: fmt.hint, message: 'Member number format looks valid for ' + scheme.name + '.' };
  }

  // Closest registry scheme to a mistyped name (edit distance), or null.
  function editDistance(a, b) {
    var prev = [], cur, i, j;
    for (j = 0; j <= b.length; j++) prev[j] = j;
    for (i = 1; i <= a.length; i++) {
      cur = [i];
      for (j = 1; j <= b.length; j++) {
        cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
      }
      prev = cur;
    }
    return prev[b.length];
  }
  function suggestScheme(provider) {
    var q = norm(provider);
    if (q.length < 3) return null;
    var best = null, bestD = Infinity;
    SCHEMES.forEach(function (s) {
      [norm(s.name)].concat(s.aliases.map(norm)).forEach(function (c) {
        var d = editDistance(q, c.slice(0, Math.max(q.length, 3)));
        if (d < bestD) { bestD = d; best = s.name; }
      });
    });
    return bestD <= Math.max(1, Math.floor(q.length / 3)) ? best : null;
  }

  /* ── SA ID numbers ───────────────────────────────────────────────────────
     Format: YYMMDD SSSS C A Z
       YYMMDD  date of birth
       SSSS    0000–4999 female, 5000–9999 male
       C       0 SA citizen, 1 permanent resident, 2 refugee
       A       formerly race, now 8 or 9 (not checked)
       Z       Luhn check digit over the first 12 digits
     Returns { status: 'empty' | 'passport' | 'invalid' | 'valid',
               message, dob ('YYYY-MM-DD'), gender ('Male'|'Female'),
               citizenship, warnings: [] }                                     */
  var CITIZENSHIP = { '0': 'SA citizen', '1': 'Permanent resident', '2': 'Refugee' };

  function luhnOk(digits) {
    var sum = 0;
    for (var i = 0; i < digits.length; i++) {
      var d = +digits[digits.length - 1 - i];
      if (i % 2 === 1) { d *= 2; if (d > 9) d -= 9; }
      sum += d;
    }
    return sum % 10 === 0;
  }

  function validateSAId(raw, opts) {
    opts = opts || {};
    var id = String(raw || '').replace(/\s+/g, '');
    if (!id) return { status: 'empty', message: '', warnings: [] };
    if (/[A-Za-z]/.test(id)) {
      return { status: 'passport', message: 'Passport or foreign ID — cannot be checked automatically.', warnings: [] };
    }
    if (!/^\d{13}$/.test(id)) {
      return { status: 'invalid', message: 'SA ID numbers have 13 digits (this has ' + id.replace(/\D/g, '').length + ').', warnings: [] };
    }
    var yy = +id.slice(0, 2), mm = +id.slice(2, 4), dd = +id.slice(4, 6);
    var nowYY = new Date().getFullYear() % 100;
    var year = (yy <= nowYY ? 2000 : 1900) + yy;
    var date = new Date(Date.UTC(year, mm - 1, dd));
    if (mm < 1 || mm > 12 || date.getUTCMonth() !== mm - 1 || date.getUTCDate() !== dd) {
      return { status: 'invalid', message: 'The first six digits are not a valid date of birth (YYMMDD).', warnings: [] };
    }
    var cit = CITIZENSHIP[id[10]];
    if (!cit) return { status: 'invalid', message: 'Digit 11 must be 0 (citizen), 1 (permanent resident) or 2 (refugee).', warnings: [] };
    if (!luhnOk(id)) return { status: 'invalid', message: 'Check digit does not match — one of the digits is probably mistyped.', warnings: [] };

    var pad = function (n) { return (n < 10 ? '0' : '') + n; };
    var dob = year + '-' + pad(mm) + '-' + pad(dd);
    var gender = +id.slice(6, 10) < 5000 ? 'Female' : 'Male';
    var warnings = [];
    if (opts.dob && opts.dob !== dob) warnings.push('Date of birth captured (' + opts.dob + ') does not match the ID (' + dob + ').');
    if (opts.gender && /^(male|female)$/i.test(opts.gender) && opts.gender.toLowerCase() !== gender.toLowerCase()) {
      warnings.push('Gender captured (' + opts.gender + ') does not match the ID (' + gender + ').');
    }
    return { status: 'valid', message: 'Valid SA ID · born ' + dob + ' · ' + gender + ' · ' + cit + '.', dob: dob, gender: gender, citizenship: cit, warnings: warnings };
  }

  /* Dependant code: two digits. Most schemes use 00 for the main (principal)
     member and 01+ for dependants — conventions vary, so these are warnings. */
  function validateDependantCode(code, principal) {
    code = String(code || '').trim();
    var isPrincipal = !principal || /^self$/i.test(String(principal).trim());
    if (!code) return { status: 'empty', message: 'Dependant code not captured — the scheme will ask for it.' };
    if (!/^\d{2}$/.test(code)) return { status: 'invalid', message: 'Dependant code is two digits, e.g. 00 or 01.' };
    if (code === '00' && !isPrincipal) return { status: 'warn', message: 'Code 00 is usually the main member, but a different principal member is captured.' };
    if (code !== '00' && isPrincipal) return { status: 'warn', message: 'Code ' + code + ' usually means a dependant — capture the principal member\'s name.' };
    return { status: 'ok', message: code === '00' ? 'Main member (00).' : 'Dependant ' + code + '.' };
  }

  /* ── Verification workflow ───────────────────────────────────────────── */
  var RECHECK_DAYS = 30;
  var METHODS = {
    phone: 'Phoned the scheme',
    portal: 'Scheme provider portal',
    card: 'Membership card seen',
    api: 'Automatic check',
    manual: 'Manual'
  };

  // A 'verified' status older than RECHECK_DAYS becomes 'recheck'.
  function effectiveStatus(status, checkedAt) {
    if (status === 'verified' && checkedAt && Date.now() - new Date(checkedAt).getTime() > RECHECK_DAYS * 86400000) return 'recheck';
    return status;
  }

  // True when a patient on medical aid should be checked before billing.
  function needsCheck(provider, status, checkedAt) {
    return !!provider && effectiveStatus(status || 'unverified', checkedAt) !== 'verified';
  }

  function contactSearchUrl(scheme) {
    return 'https://www.google.com/search?q=' + encodeURIComponent(scheme + ' medical scheme healthcare provider contact number');
  }

  // Pill label + CSS class for a stored verification status.
  function statusPill(status, checkedAt) {
    switch (effectiveStatus(status, checkedAt)) {
      case 'recheck': return { label: 'Re-check due', cls: 'pill-yellow' };
      case 'verified': return { label: 'Verified', cls: 'pill-green' };
      case 'invalid': return { label: 'Invalid', cls: 'pill-red' };
      case 'unverified': return { label: 'Unverified', cls: 'pill-yellow' };
      default: return { label: 'Self-pay', cls: 'pill-grey' };
    }
  }

  return {
    schemes: SCHEMES, schemeNames: schemeNames, findScheme: findScheme, suggestScheme: suggestScheme,
    validate: validate, validateSAId: validateSAId, validateDependantCode: validateDependantCode,
    statusPill: statusPill, effectiveStatus: effectiveStatus, needsCheck: needsCheck,
    contactSearchUrl: contactSearchUrl, METHODS: METHODS, RECHECK_DAYS: RECHECK_DAYS
  };
})();
