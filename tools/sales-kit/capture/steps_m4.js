// steps_m4.js -- capture steps for sales-kit module 4, Quality & containment (plan
// docs/superpowers/plans/2026-10-27-mes-sales-kit-module-4-quality.md, Task 4).
//
//   node capture.js --headed --steps-file steps_m4.js --steps all --out ..\captures\m4
//
// Needs MPP_MES_Demo built with -WithQualityScenario and the gateway's MPP connection on it.
// Names and LOT ids come from MPP_MES_Demo when this file loads (never by hard-coded Id), so a
// rebuild cannot point a step at the wrong LOT. Order matters: the release clears the tags, so
// every refusal is captured before it. Steps with signIn pause until the presenter has signed in
// and pressed Enter; nothing they type is saved (capture.js refuses a filled password field).
const { execFileSync } = require('child_process');

function q(sql) {
  // one value from MPP_MES_Demo (never another database)
  const out = execFileSync('sqlcmd', ['-S', 'localhost', '-E', '-C', '-d', 'MPP_MES_Demo', '-h', '-1', '-W', '-Q', 'SET NOCOUNT ON; ' + sql],
    { encoding: 'utf8' }).trim().split(/\r?\n/)[0].trim();
  if (!out || out === 'NULL') throw new Error('steps_m4: no value for: ' + sql);
  return out;
}
const lotId = name => q(`SELECT Id FROM Lots.Lot WHERE LotName = N'${name}'`);

const HELD = '520100004';                // the problem casting: hard Hold, waiting for Machining IN
const TAGGED_MIN = '520100005';          // tagged, waiting for Machining IN
const TAGGED_MOUT = '520100003';         // tagged, in the Machining OUT queue
const TAGGED_M = q(`SELECT TOP 1 l.LotName FROM Lots.Lot l JOIN Parts.Item i ON i.Id = l.ItemId
  WHERE i.PartNumber = N'HSG-410-M' AND l.CrtActive = 1 AND l.PieceCount > 0 ORDER BY l.Id DESC`);
const BORN = '520100009';                // opened after the window: born tagged
const PULLED_LABEL = q(`SELECT TOP 1 sl.LabelSerial FROM Lots.ShippingLabel sl
  JOIN Quality.ControlledRunMember m ON m.ContainerId = sl.ContainerId AND m.EndedAt IS NULL
  WHERE sl.VoidedAt IS NULL ORDER BY sl.Id`);
const RUN = 'CR000001';

const DC = ['Die Cast', 'Terminal'];
const TRIM = ['Trim Shop', 'Terminal'];
const L1MIN = ['Machining & Assembly', 'Housing line', 'Machining In'];
const L1MOUT = ['Machining & Assembly', 'Housing line', 'Machining Out'];
const L1AOUT = ['Machining & Assembly', 'Housing line', 'Assembly Out'];
const RUN_PAGE = '/shop-floor/controlled-runs/' + RUN;
const SIGN_OP = { signIn: '04218' };     // operator PIN sign-in, when a station asks for one

module.exports = [
  // ---- read-only first: the run as Quality finds it ----
  { name: 'm4-superlot-list', terminal: DC, route: '/shop-floor/controlled-runs', actions: [{ sleep: 2000 }] },
  { name: 'm4-superlot-members', terminal: DC, route: RUN_PAGE, actions: [{ sleep: 2500 }, { click: 'Members' }, { sleep: 1500 }] },
  { name: 'm4-superlot-history', terminal: DC, route: RUN_PAGE, actions: [{ sleep: 2500 }, { click: 'History' }, { sleep: 1500 }] },
  { name: 'm4-holds', terminal: DC, route: '/shop-floor/hold-management', actions: [{ sleep: 2500 }] },
  { name: 'm4-lot-held', terminal: DC, route: '/shop-floor/lot-detail/' + lotId(HELD), actions: [{ sleep: 2500 }] },
  { name: 'm4-lot-member', terminal: DC, route: '/shop-floor/lot-detail/' + lotId(BORN), actions: [{ sleep: 2500 }] },
  { name: 'm4-lot-member-superlots-tab', terminal: DC, route: '/shop-floor/lot-detail/' + lotId(BORN),
    actions: [{ sleep: 2500 }, { click: 'Super-lots' }, { sleep: 1500 }] },
  { name: 'm4-lot-member-history', terminal: DC, route: '/shop-floor/lot-detail/' + lotId(TAGGED_M),
    actions: [{ sleep: 2500 }, { click: 'History' }, { sleep: 1500 }] },
  { name: 'm4-genealogy', terminal: DC, route: '/shop-floor/genealogy',
    actions: [{ typeNear: 'LOTNAME', value: TAGGED_MOUT }, { click: 'Walk Tree' }, { sleep: 2500 }] },
  { name: 'm4-trace', terminal: DC, route: '/shop-floor/trace',
    actions: [{ sleep: 2000 }, SIGN_OP, { typeNear: 'IDENTIFIER', value: TAGGED_MOUT }, { click: 'Search' }, { sleep: 2000 }, { click: TAGGED_MOUT }, { sleep: 2500 }] },
  { name: 'm4-dashboard', terminal: DC, route: '/shop-floor/supervisor', actions: [{ sleep: 2500 }] },
  { name: 'm4-wizard-preview', terminal: DC, route: '/shop-floor/controlled-runs',
    actions: [{ sleep: 2000 }, { click: '+ New super-lot' }, { sleep: 1500 },
      { typeNear: 'Reason', value: 'Short shot found at final inspection' }, { typeNear: 'Suspect LOT', value: '520100006' },
      { click: 'Find' }, { sleep: 1500 }, { click: 'Preview' }, { sleep: 2500 }] },
  { name: 'm4-label', terminal: DC, route: RUN_PAGE, actions: [{ sleep: 2500 }, { click: 'Print 4 labels' }, { sleep: 2500 }] },

  // ---- the refusals (before anything clears a tag) ----
  { name: 'm4-refuse-machining-in', terminal: L1MIN, route: '/shop-floor/machining-in',
    actions: [{ sleep: 2000 }, SIGN_OP, { typeNear: 'Scan the LTT', value: TAGGED_MIN }, { key: 'Enter' }, { click: 'Start Machining' }, { sleep: 2500 }] },
  { name: 'm4-refuse-machining-in-hold', terminal: L1MIN, route: '/shop-floor/machining-in',
    actions: [{ sleep: 2000 }, SIGN_OP, { typeNear: 'Scan the LTT', value: HELD }, { key: 'Enter' }, { click: 'Start Machining' }, { sleep: 2500 }] },
  { name: 'm4-refuse-machining-out', terminal: L1MOUT, route: '/shop-floor/machining-out',
    actions: [{ sleep: 2000 }, SIGN_OP, { typeNear: 'PIECES', value: '16' }, { click: 'Submit', startsWith: true }, { sleep: 2500 }] },
  { name: 'm4-refuse-assembly', terminal: L1AOUT, route: '/shop-floor/assembly-nonserialized',
    actions: [{ sleep: 2000 }, SIGN_OP, { sleep: 1000 }],
    signIn: 'jacques', signInPrompt: 'Assembly OUT: scan or type ' + TAGGED_M + ' into the check-in / scan field so the CRT refusal shows (no password needed). Press Enter here once the refusal message is on screen.' },
  { name: 'm4-refuse-dock', terminal: DC, route: '/shop-floor/shipping',
    actions: [{ sleep: 2000 }, SIGN_OP, { typeNear: 'Scan shipping label', value: PULLED_LABEL }, { click: 'Ship Container' }, { sleep: 2500 }] },

  // ---- Quality signs in and works the run (Jacques types every credential) ----
  { name: 'm4-superlot-results', terminal: DC, route: RUN_PAGE, actions: [{ sleep: 2500 }, { click: 'Results' }, { sleep: 1500 }],
    signIn: 'jacques', signInPrompt: 'Super-lot page, Results tab: open a member row; when the "Quality sign-in" dialog asks, type your network user name and password and sign in. Leave the member open on Results, then press Enter here.' },
  { name: 'm4-superlot-results-saved', terminal: DC, route: RUN_PAGE, stay: true,
    signIn: 'jacques', signInPrompt: 'Still on Results: record outcomes for ' + TAGGED_MIN + ' (accept) and for one machined LOT (Use as is, 2 pieces), then use "mark the rest as all accepted" and save. Close any popup, then press Enter here.' },
  { name: 'm4-repack', terminal: DC, route: RUN_PAGE, stay: true,
    signIn: 'jacques', signInPrompt: 'Members tab: select the pulled-back container and open Repack; sign in if asked. Leave the Repack popup open (no password field showing), then press Enter here.' },
  { name: 'm4-deviation', terminal: DC, route: RUN_PAGE, stay: true,
    signIn: 'jacques', signInPrompt: 'Close Repack. Sign-off tab: Raise deviation; fill What deviates / Why it does not affect performance, sign with your network user name and password. When the signed deviation shows on Sign-off, press Enter here.' },
  { name: 'm4-signoff-release', terminal: DC, route: RUN_PAGE, stay: true,
    signIn: 'jacques', signInPrompt: 'Sign-off tab: tick the members ready to release and click Release so the release popup opens -- DO NOT type yet. Press Enter here; the popup is captured empty.' },
  { name: 'm4-signoff-done', terminal: DC, route: RUN_PAGE, stay: true,
    signIn: 'jacques', signInPrompt: 'Now tick the confirmation, type your network user name and password and Sign and release. When the Sign-off tab shows the release, press Enter here.' },
  { name: 'm4-history-after', terminal: DC, route: RUN_PAGE, actions: [{ sleep: 2500 }, { click: 'History' }, { sleep: 1500 }] },
  { name: 'm4-crt-clear', terminal: DC, route: '/shop-floor/lot-detail/' + lotId(BORN), actions: [{ sleep: 2500 }],
    signIn: 'jacques', signInPrompt: 'LOT Detail of ' + BORN + ' (still tagged if not released): clear CRT and sign in when asked. When "CRT cleared" shows, press Enter here.' },
  { name: 'm4-lot-released-history', terminal: DC, route: '/shop-floor/lot-detail/' + lotId(TAGGED_MIN),
    actions: [{ sleep: 2500 }, { click: 'History' }, { sleep: 1500 }] },

  // ---- the report and the Config Tool ----
  { name: 'm4-report', terminal: DC, route: '/shop-floor/reports',
    actions: [{ sleep: 2000 }, { click: 'Super-lot' }, { sleep: 1500 }],
    signIn: 'jacques', signInPrompt: 'Reports: pick ' + RUN + ' in "Scan or select super-lot" and let the report render. Then press Enter here (the Print PDF save comes after this capture).' },
  { name: 'm4-config-specs', project: 'MPP_Config', route: '/quality-specs', actions: [{ sleep: 2000 }],
    signIn: 'jacques', signInPrompt: 'Config Tool: sign in with your directory login if asked, open Quality Specs for one sample part (e.g. HSG-410). Press Enter here when the spec shows.' },
];
