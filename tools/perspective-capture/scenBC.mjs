// SCENARIO B -- four-cavity die, two cavities roll mid-shift, successors opened
//               on those cavities, then one end-of-shift entry.
// SCENARIO C -- same die shape, solid run, nothing released all shift.
import { connect, setViewport } from './cdp.mjs';
import { URL, signIn, pickCell, tab, fill, shot, sleep, evalJs, clickButton, text } from './lib.mjs';
import { openBasket, releaseBasket, dieState, resetDie } from './db.mjs';

const OUT = process.env.SHOTDIR;
const cdp = await connect(URL);
await setViewport(cdp, 1600, 1000);

/** Click the Release button on the row for a named cavity. */
async function releaseRow(cavityName) {
  await tab(cdp, 'Lot Release', 'Currently Open');
  await sleep(1200);
  const res = await evalJs(cdp, [
    '(() => {',
    '  const want = ' + JSON.stringify(cavityName) + ';',
    '  const btns = [...document.querySelectorAll("button")].filter(b => (b.textContent||"").trim() === "Release");',
    '  for (const b of btns) {',
    '    let row = b.parentElement;',
    '    for (let i=0;i<5 && row;i++) { if ((row.textContent||"").includes(want)) { b.click(); return "clicked"; } row = row.parentElement; }',
    '  }',
    '  return "NOTFOUND";',
    '})()',
  ].join(' '));
  if (res === 'NOTFOUND') throw new Error('no Release row for ' + cavityName);
  await sleep(2500);
  if (!(await text(cdp)).includes('PRESS COUNTER READING NOW')) throw new Error('dialog did not open for ' + cavityName);
}

async function confirmRelease() {
  await clickButton(cdp, 'Release basket', { settle: 3500 });
  for (let i = 0; i < 12; i++) {
    if (!(await text(cdp)).includes('PRESS COUNTER READING NOW')) return;
    await sleep(700);
  }
  throw new Error('release dialog never closed');
}

// =====================================================================
// SCENARIO B
// =====================================================================
const B = { die: 'RB-B', machine: 'DC1-M05', item: 'RB-B-2200', cell: 'DC1-M05 - Machine 05' };
console.log(resetDie(B.die));
for (let n = 1; n <= 4; n++) {
  openBasket({ die: B.die, cavity: n, ltt: String(91000100 + n), item: B.item, machine: B.machine });
}

await cdp.send('Page.navigate', { url: URL });
await sleep(9000);
await signIn(cdp);
await pickCell(cdp, B.cell);

await tab(cdp, 'Lot Release', 'Currently Open');
await shot(cdp, OUT + '/B', 'B1_four_open');

// -- cavity 1 rolls at 1450 (the reading the operator wrote down at the swap) --
await releaseRow('Intake 1 Aa');
await fill(cdp, 'e.g. 1600', '1450');
await sleep(1500);
await shot(cdp, OUT + '/B', 'B2_cav1_rolls_at_1450');
await confirmRelease();

// -- cavity 3 rolls at the same reading --
await releaseRow('Exhaust 1 Ba');
await fill(cdp, 'e.g. 1600', '1450');
await sleep(1200);
await shot(cdp, OUT + '/B', 'B3_cav3_rolls_at_1450');
await confirmRelease();
console.log('B: two cavities rolled at 1450\n' + dieState(B.die));

// -- successors on exactly the two cavities that closed --
openBasket({ die: B.die, cavity: 1, ltt: '91000111', item: B.item, machine: B.machine });
openBasket({ die: B.die, cavity: 3, ltt: '91000113', item: B.item, machine: B.machine });
await clickButton(cdp, 'Refresh', { settle: 3000 });
await tab(cdp, 'Lot Release', 'Currently Open');
await shot(cdp, OUT + '/B', 'B4_successors_open');

// -- end of shift at 2000: the divergence --
await tab(cdp, 'Record Shift Output', 'PRESS COUNTER READING NOW');
await sleep(1200);
await fill(cdp, '0', '2000');
await sleep(600);
await clickButton(cdp, 'Compute / Preview', { settle: 3500 });
await shot(cdp, OUT + '/B', 'B5_endofshift_2000_divergence');
await clickButton(cdp, 'SUBMIT SHIFT OUTPUT', { settle: 4000 });
await sleep(1500);
await shot(cdp, OUT + '/B', 'B6_submitted');
console.log('B final:\n' + dieState(B.die));

// =====================================================================
// SCENARIO C -- nothing released all shift
// =====================================================================
const C = { die: 'RB-C', machine: 'DC1-M06', item: 'RB-C-2000', cell: 'DC1-M06 - Machine 06' };
console.log(resetDie(C.die));
for (let n = 1; n <= 4; n++) {
  openBasket({ die: C.die, cavity: n, ltt: String(91000200 + n), item: C.item, machine: C.machine });
}
await pickCell(cdp, C.cell);
await tab(cdp, 'Lot Release', 'Currently Open');
await shot(cdp, OUT + '/C', 'C1_four_open_untouched');

await tab(cdp, 'Record Shift Output', 'PRESS COUNTER READING NOW');
await sleep(1200);
await fill(cdp, '0', '1800');
await sleep(600);
await clickButton(cdp, 'Compute / Preview', { settle: 3500 });
await shot(cdp, OUT + '/C', 'C2_uniform_1800');
await clickButton(cdp, 'SUBMIT SHIFT OUTPUT', { settle: 4000 });
await sleep(1500);
await shot(cdp, OUT + '/C', 'C3_submitted');
console.log('C final:\n' + dieState(C.die));

cdp.close();
