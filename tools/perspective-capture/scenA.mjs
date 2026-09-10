// SCENARIO A -- single-cavity die, ten 70-piece baskets in one shift, partial
// at end of shift. Baskets 2-4 and 6-10 are fast-forwarded through the same
// two procs the UI calls; every step the book SHOWS is driven through the UI.
import { connect, setViewport } from './cdp.mjs';
import { URL, signIn, pickCell, tab, fill, shot, sleep, evalJs, clickText, clickButton, text } from './lib.mjs';
import { openBasket, releaseBasket, dieState, resetDie } from './db.mjs';

const OUT = process.env.SHOTDIR + '/A';
const DIE = 'RB-A', MACHINE = 'DC1-M04', ITEM = 'RB-A-70', CELL = 'DC1-M04 - Machine 04';

// Start from a known state so the run is repeatable.
console.log(resetDie(DIE));
console.log(openBasket({ die: DIE, cavity: 1, ltt: '91000001', item: ITEM, machine: MACHINE }));

const cdp = await connect(URL);
await setViewport(cdp, 1600, 1000);
await cdp.send('Page.navigate', { url: URL });
await sleep(9000);
await signIn(cdp);
await pickCell(cdp, CELL);
console.log('cell:', CELL);

async function openReleaseDialog() {
  await tab(cdp, 'Lot Release');
  await sleep(1200);
  const hit = await evalJs(cdp, `
  (() => {
    const b = [...document.querySelectorAll('button')].find(el =>
      (el.textContent||'').trim() === 'Release' && el.getBoundingClientRect().width > 20);
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return { x: r.x + r.width/2, y: r.y + r.height/2 };
  })()`);
  if (!hit) throw new Error('no Release button');
  const { click } = await import('./cdp.mjs');
  await click(cdp, hit.x, hit.y);
  await sleep(2500);
  if (!(await text(cdp)).includes('Release basket')) throw new Error('release dialog did not open');
}

/** Confirm the release and WAIT for the dialog to actually go away. Releasing
 *  the basket out from under an open dialog leaves it bound to a LOT that is
 *  no longer Open, and every field in it goes Component-Error. */
async function confirmRelease() {
  await clickButton(cdp, 'Release basket', { settle: 3500 });
  for (let i = 0; i < 12; i++) {
    if (!(await text(cdp)).includes('PRESS COUNTER READING NOW')) return;
    await sleep(700);
  }
  throw new Error('release dialog never closed');
}

// ---- A1: the first release of the shift, counter at 70 ----
await openReleaseDialog();
await shot(cdp, OUT, 'A1a_dialog_empty');
await fill(cdp, 'e.g. 1600', '70');
await sleep(1500);
await shot(cdp, OUT, 'A1b_reading_70');
await confirmRelease();
console.log('A1 released at 70');
await shot(cdp, OUT, 'A1c_after_release');

// ---- fast-forward baskets 2-4 (readings 140/210/280) ----
for (const [n, r] of [[2, 140], [3, 210], [4, 280]]) {
  console.log('ff open', openBasket({ die: DIE, cavity: 1, ltt: String(91000000 + n), item: ITEM, machine: MACHINE }));
  console.log('ff rel ', releaseBasket({ die: DIE, cavity: 1, reading: r, machine: MACHINE }));
}

// ---- A2: open basket 5 through the UI ----
await tab(cdp, 'Open Basket');
await sleep(1500);
await shot(cdp, OUT, 'A2a_open_tab');
// The bulk-open grid's LTT cells carry no placeholder to key off, so basket 5
// is opened through the same proc the grid calls and the tab is captured as a
// view. Nothing about the chain depends on which path opened the basket.
console.log(openBasket({ die: DIE, cavity: 1, ltt: '91000005', item: ITEM, machine: MACHINE }));
await clickButton(cdp, 'Refresh', { settle: 3000 });
await tab(cdp, 'Open Basket');
await sleep(1500);
await shot(cdp, OUT, 'A2c_opened');
console.log('A2 basket 5 opened');

// ---- A3: release basket 5 at 350 -- the chain screenshot ----
await openReleaseDialog();
await fill(cdp, 'e.g. 1600', '350');
await sleep(1500);
await shot(cdp, OUT, 'A3_reading_350_chain');
await confirmRelease();
console.log('A3 released at 350');

// ---- fast-forward baskets 6-10 (420..700) ----
for (const [n, r] of [[6, 420], [7, 490], [8, 560], [9, 630], [10, 700]]) {
  openBasket({ die: DIE, cavity: 1, ltt: String(91000000 + n), item: ITEM, machine: MACHINE });
  releaseBasket({ die: DIE, cavity: 1, reading: r, machine: MACHINE });
}
openBasket({ die: DIE, cavity: 1, ltt: '91000011', item: ITEM, machine: MACHINE });
console.log('state after 10 baskets:\n' + dieState(DIE));

// ---- A4: end of shift, counter 735 -> the partial basket ----
await tab(cdp, 'Record Shift Output', 'PRESS COUNTER READING NOW');
await sleep(1500);
await shot(cdp, OUT, 'A4a_shift_output_empty');
await fill(cdp, '0', '735');
await sleep(600);
await clickButton(cdp, 'Compute / Preview', { settle: 3500 });
await shot(cdp, OUT, 'A4b_partial_35');
console.log('A4 computed at 735');

await clickButton(cdp, 'SUBMIT SHIFT OUTPUT', { settle: 4000 });
await shot(cdp, OUT, 'A4c_submitted');
console.log('final state:\n' + dieState(DIE));
cdp.close();
