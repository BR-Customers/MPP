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
import { URL, pickCell, sleep, text } from '../perspective-capture/lib.mjs';
import { capture, press, fillBox, signInAs, measure, dumpControls } from './lib/measure.mjs';
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
    voidBtn: btn('Void', { nth: -1 }),   // the dialog's own Void is the lowest one on screen
  });
  await press(cdp, btn('Cancel'), 1500);

  // --- PIN pad (slides 5 and 18): opened from the operator chip, as at hand-over ---
  await press(cdp, { text: 'Operator: Sam Taylor', tag: 'div' }, 2000);
  await capture(cdp, OUT, 'pin_pad', {
    chip: { text: 'Operator: Sam Taylor', tag: 'div' },
    display: { text: 'Enter your PIN', tag: 'div', up: 2, maxChars: 60 },
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
    await press(cdp, { selector: 'div.ia_dropdown', nth: 0 }, 1200);
    await dump(cdp, 'rec_shift_open');
    await key(cdp, 'Escape', 'Escape', 27);
    await sleep(600);
    await capture(cdp, OUT, 'rec_compute', {
      shift: { text: 'REPORTING SHIFT', tag: 'div', up: 1, maxChars: 120 },
      counter: { text: 'PRESS COUNTER', tag: 'div', exact: false, up: 1, maxChars: 120 },
      compute: btn('Compute'),
      fixCounter: btn('Fix counter'),
    });
    await dump(cdp, 'rec_before_compute');
  } finally { await closeSession(cdp); }
}

if (want('operator')) await operator();
if (want('reconcile')) await reconcile();
process.exit(0);
