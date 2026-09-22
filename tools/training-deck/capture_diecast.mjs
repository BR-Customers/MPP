// Drives the Dev die cast terminal and writes the screenshot sources for the
// training deck: one PNG + one JSON of measured target rectangles per shot.
// Dev only (Machine 11, die DMO125, training operator Sam Taylor / PIN 24680).
//
//   node tools/training-deck/capture_diecast.mjs [--only <group>]
//   groups: operator | reconcile | teamlead | dashboard
//
// Capture Chrome: headless on CDP port 9333 (see tools/training-deck/README.md).
// The team lead group needs a VISIBLE Chrome on 9334 and pauses for a person to
// type the supervisor sign-in -- this script never types credentials.
//
// Labels below were read off the live screen on 2026-09-18. When a label
// changes, the screen wins: a missing target fails loudly with its spec.
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { connect, setViewport } from '../perspective-capture/cdp.mjs';
import { URL, pickCell, sleep, text, waitFor } from '../perspective-capture/lib.mjs';
import { capture, press, fillBox, signInAs, measure, dumpControls, chooseFromDropdown } from './lib/measure.mjs';
import * as db from './lib/dc_db.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.resolve(HERE, '../../docs/training/diecast/shots');
const CELL = 'DC1-M11 - Machine 11';
const args = process.argv.slice(2);
const only = args.includes('--only') ? args[args.indexOf('--only') + 1] : null;
const want = (g) => !only || only === g;

const btn = (label, extra = {}) => ({ text: label, tag: 'button', ...extra });
// A cavity row on Lot Management: its name, walked up to the row's box.
const row = (desc) => ({ text: desc, tag: 'div', up: 8, maxChars: 200 });
const key = async (cdp, k, code, vk) => {
  await cdp.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: k, code, windowsVirtualKeyCode: vk });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code, windowsVirtualKeyCode: vk });
};

async function session({ port } = {}) {
  const cdp = await connect(URL, port ? { allowVisible: true } : undefined);
  await setViewport(cdp, 1600, 1000);
  await cdp.send('Page.navigate', { url: URL });
  await sleep(9000);
  return cdp;
}

async function toMachine(cdp) {
  await signInAs(cdp, db.PIN, 'ST');
  await pickCell(cdp, CELL);
  await press(cdp, { text: 'Lot Management', tag: 'div' }, 2500);
}

const waitForText = (cdp, needle) => waitFor(cdp, needle, 25000, needle);

async function refresh(cdp) { await press(cdp, btn('Refresh'), 3000); }

/** Always close the tab we opened -- a failed run used to leave its tab behind,
 *  and a dozen live Perspective sessions is what makes Runtime.evaluate time out. */
async function closeSession(cdp) {
  try { await cdp.send('Target.closeTarget', { targetId: cdp.targetId }); } catch { /* already gone */ }
  try { cdp.close(); } catch { /* already closed */ }
}

async function operator() {
  db.clearDie();
  const cdp = await session();
  try { await operatorSteps(cdp); } finally { await closeSession(cdp); }
}

async function operatorSteps(cdp) {
  await toMachine(cdp);
  await refresh(cdp);

  // --- Screen tour (slide 4) ---
  await capture(cdp, OUT, 'lot_overview', {
    header: { union: ['hTerminal', 'hReset'] },
    hTerminal: { text: 'Terminal', tag: 'div', up: 1, maxChars: 30 },
    hReset: btn('Reset Terminal'),
    cell: { selector: 'div.ia_dropdown', nth: 0 },
    tabs: { union: ['tabLot', 'tabRec'] },
    tabLot: { text: 'Lot Management', tag: 'div' },
    tabRec: { text: 'Reconcile Shift', tag: 'div' },
    die: { union: ['dieLabel', 'dieMount'] },
    dieLabel: { text: 'DIE', tag: 'div' },
    dieMount: btn('Die Mount'),
    rows: { union: ['firstGroup', 'lastRow'] },
    firstGroup: { text: '2 cavities', tag: 'div', nth: 0, up: 2, maxChars: 60 },
    lastRow: row('In 4 Da'),
    footer: { union: ['openAll', 'clear'] },
    openAll: btn('OPEN ALL EMPTY CAVITIES'),
    clear: btn('Clear'),
  });

  // --- Pick your machine (slide 6) ---
  // The open dropdown list is rendered outside the field and is not worth
  // measuring; the slide points at the field and at the die name the screen
  // shows once a machine is picked.
  await capture(cdp, OUT, 'cell_pick', {
    cell: { selector: 'div.ia_dropdown', nth: 0 },
    die: { text: 'Tool DMO125', tag: 'div', exact: false, up: 1, maxChars: 120 },
  });

  // --- Open a basket (slide 7): ticket scanned into one row, button ready ---
  await fillBox(cdp, { placeholder: 'Scan LTT', nth: 0 }, '70000101');
  await sleep(800);
  await capture(cdp, OUT, 'open_scan', {
    row: row('In 2-Da'),
    scan: { placeholder: 'Scan LTT', nth: 0 },
    openBtn: btn('OPEN 1 BASKET(S)'),
  });
  await press(cdp, btn('OPEN 1 BASKET(S)'), 3500);
  await capture(cdp, OUT, 'open_done', {
    basket: { text: '70000101', tag: 'div', exact: false, up: 1, maxChars: 80 },
    note: { text: 'Basket opened (70000101).', tag: 'div' },
  });

  // --- Changeover: several at once (slide 8) ---
  await fillBox(cdp, { placeholder: 'Scan LTT', nth: 0 }, '70000102');
  await fillBox(cdp, { placeholder: 'Scan LTT', nth: 1 }, '70000103');
  await fillBox(cdp, { placeholder: 'Scan LTT', nth: 2 }, '70000104');
  await sleep(800);
  await capture(cdp, OUT, 'open_many', {
    scan1: { placeholder: 'Scan LTT', nth: 0 },
    scans: { union: ['scan1', 'scan3'] },
    scan3: { placeholder: 'Scan LTT', nth: 2 },
    openBtn: btn('OPEN 3 BASKET(S)'),
  });
  await press(cdp, btn('OPEN 3 BASKET(S)'), 3500);
  await refresh(cdp);

  // --- Release (slides 9 and 9b): dialog top with a counter reading, then its buttons ---
  await press(cdp, btn('Release', { nth: 0 }), 3000);
  await fillBox(cdp, { placeholder: 'e.g. 1600' }, '420');
  await sleep(1500);
  await capture(cdp, OUT, 'release_top', {
    rowRelease: btn('Release', { nth: 0 }),
    counter: { placeholder: 'e.g. 1600' },
    pieces: { placeholder: 'e.g. 288' },
    boxes: { union: ['bNow', 'bCloses'] },
    bNow: { text: 'ON THE BASKET NOW', tag: 'div', up: 1, maxChars: 40 },
    bCloses: { text: 'BASKET CLOSES AT', tag: 'div', up: 1, maxChars: 40 },
    scrap: btn('Add scrap reason'),
  });
  await measure(cdp, { b: btn('Release basket', { scroll: true }) });
  await sleep(900);
  await capture(cdp, OUT, 'release_bottom', {
    releaseBtn: btn('Release basket'),
    cancel: btn('Cancel'),
    fixCounter: btn('Counter reset / wrong total?'),
  });
  await press(cdp, btn('Release basket'), 3500);
  await refresh(cdp);

  // --- Void an empty basket (slide 10) ---
  await press(cdp, btn('Void', { nth: 0 }), 2500);
  await capture(cdp, OUT, 'void_dialog', {
    rowVoid: btn('Void', { nth: 0 }),
    message: { text: 'This cannot be undone', tag: 'div', exact: false },
    // The dialog's own Void, found inside the dialog: "lowest Void on screen"
    // picked a row's Void button below the dialog.
    voidBtn: { within: 'Void empty basket', withinUp: 4, text: 'Void', tag: 'button' },
  });
  await press(cdp, btn('Cancel'), 1500);

  // --- PIN pad (slides 5 and 18): opened from the operator chip, as at hand-over ---
  await press(cdp, { text: 'Operator: Sam Taylor', tag: 'div' }, 2000);
  await capture(cdp, OUT, 'pin_pad', {
    chip: { text: 'Operator: Sam Taylor', tag: 'div' },
    display: { union: ['pinHeading', 'badge'] },   // the dashes sit between these two
    pinHeading: { text: 'Enter your PIN', tag: 'div' },
    badge: { placeholder: 'Scan badge or type PIN' },
    keypad: { union: ['k1', 'kBack'] },
    k1: btn('1'),
    kBack: btn('Back'),
  });
  for (const d of '13579') await press(cdp, btn(d), 250);
  await sleep(2500);
  await capture(cdp, OUT, 'pin_unknown', {
    retype: { text: 'Re-type PIN', tag: 'div' },
    register: { text: 'Register New User', tag: 'div' },
  });
  await press(cdp, { text: 'Re-type PIN', tag: 'div' }, 1500);
  await signInAs(cdp, db.PIN, 'ST');
}

/** Save the controls of a state I have not scripted yet, so the next run can
 *  name its targets. Written to TEMP, never into the committed shots folder. */
async function dump(cdp, name) {
  const fs = await import('node:fs');
  const os = await import('node:os');
  const dir = path.join(os.tmpdir(), 'training-deck-dumps');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${name}.json`), JSON.stringify(await dumpControls(cdp), null, 1));
  fs.writeFileSync(path.join(dir, `${name}.txt`), await text(cdp));
  const r = await cdp.send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(dir, `${name}.png`), Buffer.from(r.data, 'base64'));
  console.log(`dumped ${name} -> ${dir}`);
}

async function reconcile() {
  db.clearDie();
  // Four baskets running, so the per-cavity table has something in it.
  ['In 2-Da', 'In 2-Db', 'In 3 Da', 'In 3 Db'].forEach((desc, i) =>
    console.log(db.openBasket({ desc, ltt: `7000020${i + 1}` })));
  const cdp = await session();
  try {
    await signInAs(cdp, db.PIN, 'ST');
    await pickCell(cdp, CELL);
    await press(cdp, { text: 'Reconcile Shift', tag: 'div' }, 3000);

    await capture(cdp, OUT, 'rec_overview', {
      entry: { text: 'THIS ENTRY', tag: 'div', up: 1, maxChars: 400 },
      diewide: { text: 'DIE-WIDE', tag: 'div', up: 1, maxChars: 500 },
      percavity: { text: 'PER CAVITY', tag: 'div', up: 1, maxChars: 120 },
      totals: { text: 'UNACCOUNTED', tag: 'div', up: 3, maxChars: 300 },
      submit: btn('SUBMIT SHIFT ENTRY'),
    });

    // Shift, counter reading, Compute (slide 12).
    await chooseFromDropdown(cdp, { near: 'REPORTING SHIFT' }, 'First Shift');
    await fillBox(cdp, { placeholder: '0' }, '600');
    await capture(cdp, OUT, 'rec_compute', {
      shift: { text: 'REPORTING SHIFT', tag: 'div', up: 1, maxChars: 120 },
      counter: { text: 'PRESS COUNTER READING NOW', tag: 'div', up: 1, maxChars: 120 },
      compute: btn('Compute'),
      fixCounter: btn('Fix counter'),
    });
    await press(cdp, btn('Compute'), 4500);

    // Warm-up and quality test shots (slide 13).
    await fillBox(cdp, { within: 'Warm-up shots', withinUp: 2, tag: 'input' }, '5');
    await fillBox(cdp, { within: 'Quality test shots', withinUp: 2, tag: 'input' }, '2');
    await sleep(1200);
    await capture(cdp, OUT, 'rec_diewide', {
      warmup: { within: 'Warm-up shots', withinUp: 2, tag: 'input' },
      qtest: { within: 'Quality test shots', withinUp: 2, tag: 'input' },
      addDw: btn('Add die-wide scrap'),
      block: { text: 'DIE-WIDE', tag: 'div', up: 1, maxChars: 500 },
    });

    // The per-cavity table (slide 14).
    // In a cavity row GOOD is an input and CAVITY SCRAP is a BUTTON showing the
    // number; pressing it opens the scrap editor under the row. Targets are
    // anchored on the cavity's own name and walked up to the ROW -- scoping by
    // the "PER CAVITY" heading reaches a box that also holds the die-wide
    // inputs, and typing then lands in the wrong field.
    const inRow = (desc, extra) => ({ within: desc, withinRow: true, ...extra });
    const ROW = 'In 2-Da';

    await capture(cdp, OUT, 'rec_table', {
      shots: { text: 'SHOTS', tag: 'div' },
      good: { text: 'GOOD', tag: 'div', nth: 0 },
      cavityScrap: { text: 'CAVITY SCRAP', tag: 'div' },
      variance: { text: 'VARIANCE', tag: 'div' },
      goodBox: inRow(ROW, { tag: 'input', nth: 0 }),
      scrapBtn: inRow(ROW, { tag: 'button', nth: 0 }),
      totals: { text: 'UNACCOUNTED', tag: 'div', up: 3, maxChars: 300 },
      submit: btn('SUBMIT SHIFT ENTRY'),
    });

    // Scrap on one cavity (slide 14).
    await press(cdp, inRow(ROW, { tag: 'button', nth: 0 }), 2500);
    await chooseFromDropdown(cdp, { text: 'Scrap reason' }, '001');
    await fillBox(cdp, { placeholder: 'qty' }, '10');
    await sleep(1500);
    await capture(cdp, OUT, 'rec_scrap', {
      scrapBtn: inRow(ROW, { tag: 'button', nth: 0 }),
      reason: { selector: 'div.ia_dropdown', nth: -1 },
      qty: { placeholder: 'qty' },
      addReason: btn('Add scrap reason'),
    });

    // Good typed by hand, LAST: it follows the counter until a person edits it,
    // and editing scrap afterwards recalculates it again. Fewer good than the
    // counter expects makes the variance amber (slide 15).
    await fillBox(cdp, inRow(ROW, { tag: 'input', nth: 0 }), '550');
    // The amber state arrives with the recompute, not with the keystroke.
    await waitForText(cdp, 'Needs a reason');
    await capture(cdp, OUT, 'rec_variance', {
      goodBox: inRow(ROW, { tag: 'input', nth: 0 }),
      varianceChip: inRow(ROW, { text: '33', tag: 'button' }),
      needsReason: { text: 'Needs a reason: In 2-Da', tag: 'div' },
      totals: { text: 'UNACCOUNTED', tag: 'div', up: 3, maxChars: 300 },
      submit: btn('SUBMIT SHIFT ENTRY'),
    });

    // The reason picker behind the amber number.
    await press(cdp, inRow(ROW, { text: '33', tag: 'button' }), 2500);
    await capture(cdp, OUT, 'rec_variance_reason', {
      varianceChip: inRow(ROW, { text: '33', tag: 'button' }),
      reasonRow: { text: 'VARIANCE 33', tag: 'div', up: 1, maxChars: 200 },
      reasonDd: { selector: 'div.ia_dropdown', nth: -1 },
      submit: btn('SUBMIT SHIFT ENTRY'),
    });

    // Fix counter (slide 16).
    await press(cdp, btn('Fix counter'), 2500);
    await capture(cdp, OUT, 'fix_counter', {
      reads: { placeholder: 'e.g. 12' },
      why: { text: 'WHY IT MOVED', tag: 'div', up: 1, maxChars: 120 },
      note: { placeholder: 'What happened, in your words' },
      record: btn('Record this reading'),
      cancel: btn('Cancel'),
    });
    await press(cdp, btn('Cancel'), 2000);

    // Downtime (slide 17).
    await press(cdp, btn('Downtime'), 3500);
    await capture(cdp, OUT, 'downtime', {
      dtButton: btn('Downtime'),
      scope: { text: 'Current shift', tag: 'div', up: 1, maxChars: 60 },
      list: { text: 'No downtime events for this scope / shift.', tag: 'div' },
      start: btn('Start Downtime'),
      past: btn('Add Past Event'),
    });
  } finally { await closeSession(cdp); }
}

async function teamleadPopups() {
  const cdp = await session();
  try {
    await signInAs(cdp, db.PIN, 'ST');
    await pickCell(cdp, CELL);
    await press(cdp, { text: 'Lot Management', tag: 'div' }, 2500);
    await press(cdp, btn('Supervisor Access'), 3000);
    await dump(cdp, 'tl_supervisor_access');
    await capture(cdp, OUT, 'sup_access', { supBtn: btn('Supervisor Access') });
    await key(cdp, 'Escape', 'Escape', 27); await sleep(1200);
    await session_reset(cdp);
    await press(cdp, btn('Die Mount'), 3000);
    await dump(cdp, 'tl_die_mount');
    await capture(cdp, OUT, 'die_mount_closed', { dieMount: btn('Die Mount') });
    await session_reset(cdp);
    await press(cdp, btn('Reset Terminal'), 3000);
    await dump(cdp, 'tl_reset_terminal');
    await capture(cdp, OUT, 'reset_terminal', { resetBtn: btn('Reset Terminal') });
  } finally { await closeSession(cdp); }
}

/** Close whatever popup is up by reloading the page -- popups here have
 *  different close buttons, and a reload is the one move that always works. */
async function session_reset(cdp) {
  await cdp.send('Page.reload');
  await sleep(9000);
  await signInAs(cdp, db.PIN, 'ST');
}

async function dashboard() {
  // Give today's shift some registered production first (Dev only): one
  // Reconcile Shift entry on Machine 11 for the current shift.
  const s1 = await session();
  try {
    await signInAs(s1, db.PIN, 'ST');
    await pickCell(s1, CELL);
    await press(s1, { text: 'Reconcile Shift', tag: 'div' }, 3000);
    await chooseFromDropdown(s1, { near: 'REPORTING SHIFT' }, 'First Shift');
    await fillBox(s1, { placeholder: '0' }, '700');
    await press(s1, btn('Compute'), 4500);
    await press(s1, btn('SUBMIT SHIFT ENTRY'), 3000);
    await press(s1, btn('CONFIRM & SUBMIT'), 4000);
  } catch (e) { console.log('  (dashboard seed skipped) ' + e.message); }
  finally { await closeSession(s1); }
  const { connect: c } = await import('../perspective-capture/cdp.mjs');
  const cdp = await c('http://localhost:8088/data/perspective/client/MPP/shop-floor/die-cast/supervisor');
  try {
    await setViewport(cdp, 1600, 1000);
    await sleep(9000);
    await capture(cdp, OUT, 'dash_overview', {
      area: { text: 'AREA', tag: 'div', up: 1, maxChars: 60 },
      tiles: { union: ['tCur', 'tChange'] },
      tCur: { text: 'CURRENT SHIFT', tag: 'div', exact: false, up: 1, maxChars: 120 },
      tChange: { text: 'CHANGE', tag: 'div', up: 1, maxChars: 80 },
      current: { text: 'Current shift', tag: 'div', exact: false, up: 2, maxChars: 3000 },
      previous: { text: 'Previous shift', tag: 'div', exact: false, up: 2, maxChars: 3000 },
    });
  } finally { await closeSession(cdp); }
}

/** Team lead screens that need a supervisor AD sign-in. Runs in a VISIBLE
 *  Chrome on CDP port 9334; when the Authorize box is up, a PERSON types the
 *  account and password. This script never types credentials -- it waits for
 *  the box to go away, then captures what opened behind it. */
async function teamleadVisible() {
  process.env.CDP_PORT = '9334';
  const { connect: c } = await import('../perspective-capture/cdp.mjs?visible');
  const cdp = await c(URL, { allowVisible: true, reuseExisting: true });
  await setViewport(cdp, 1600, 1000);
  await cdp.send('Page.navigate', { url: URL });
  await sleep(9000);
  await signInAs(cdp, db.PIN, 'ST');
  // This window's session may not resolve to the DC1-T1 terminal, and then the
  // machine list shows every cell with different labels -- match by code.
  try { await pickCell(cdp, CELL); }
  catch { await chooseFromDropdown(cdp, { text: 'Scan or pick a cell' }, 'DC1-M11'); }
  await press(cdp, { text: 'Lot Management', tag: 'div' }, 2500);

  await press(cdp, btn('Supervisor Access'), 3000);
  await capture(cdp, OUT, 'sup_access', {
    supBtn: btn('Supervisor Access'),
    user: { placeholder: 'domain\\username' },
    pass: { placeholder: 'Password' },
    auth: btn('Authenticate'),
  });
  await press(cdp, btn('Cancel'), 2000);

  await press(cdp, btn('Die Mount'), 3000);
  console.log('>>> In the visible Chrome window: type the supervisor account and password, then press Authenticate.');
  console.log('>>> Waiting up to 5 minutes...');
  const t0 = Date.now();
  while (Date.now() - t0 < 300000) {
    const up = await evalJs(cdp, `[...document.querySelectorAll('input')].some(i => i.placeholder === 'Password' && i.getBoundingClientRect().width > 2)`);
    if (!up) break;
    await sleep(1000);
  }
  await sleep(3500);
  await dump(cdp, 'tl_die_mount_open');
  await capture(cdp, OUT, 'die_mount', {});
  console.log('captured die mount -- you can close the window now');
}

if (want('operator')) await operator();
if (only === 'tlvisible') await teamleadVisible();
if (only === 'tlpopups') await teamleadPopups();
if (only === 'dashboard') await dashboard();
if (want('reconcile')) await reconcile();
process.exit(0);
