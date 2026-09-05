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
      return { status: 'unknown_scheme', scheme: null, hint: fmt.hint, message: '"' + provider + '" is not in the scheme registry — number format looks plausible, please double-check the scheme name.' };
    }
    return { status: 'format_ok', scheme: scheme.name, hint: fmt.hint, message: 'Member number format looks valid for ' + scheme.name + '.' };
  }

  // Pill label + CSS class for a stored verification status.
  function statusPill(status) {
    switch (status) {
      case 'verified': return { label: 'Verified', cls: 'pill-green' };
      case 'invalid': return { label: 'Invalid', cls: 'pill-red' };
      case 'unverified': return { label: 'Unverified', cls: 'pill-yellow' };
      default: return { label: 'Self-pay', cls: 'pill-grey' };
    }
  }

  return { schemes: SCHEMES, schemeNames: schemeNames, findScheme: findScheme, validate: validate, statusPill: statusPill };
})();
