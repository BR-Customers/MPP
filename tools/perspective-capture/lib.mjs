// Shared steps for driving the die cast terminal.
import { sleep, evalJs, findByText, click, clickText, typeText, shot } from './cdp.mjs';

export const URL = 'http://localhost:8088/data/perspective/client/MPP/shop-floor/die-cast';

export async function text(cdp) {
  return evalJs(cdp, 'document.body.innerText');
}

export async function waitFor(cdp, needle, ms = 20000, label = null) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const t = await text(cdp);
    if (t.includes(needle)) return true;
    await sleep(400);
  }
  throw new Error(`waitFor timed out: ${label || needle}`);
}

/** Sign in at the PIN gate. The gate is the app's own startup popup; if it is
 *  not up yet we wait for it rather than poking the operator bar, because the
 *  bar's popup is the same view and racing them opens two. */
export async function signIn(cdp, pin = '00002') {
  const t0 = Date.now();
  while (Date.now() - t0 < 8000) {
    const t = await text(cdp);
    if (t.includes('Enter your PIN')) break;
    if (t.includes('Operator: DEV') || t.includes('Operator: Dev User')) return 'already';
    await sleep(500);
  }
  // The gate auto-opens in some sessions and not others; the operator chip in
  // the sub-header opens the same popup, so fall back to it rather than
  // waiting on a race we do not control.
  if (!(await text(cdp)).includes('Enter your PIN')) {
    const chip = await evalJs(cdp, `
    (() => {
      const el = [...document.querySelectorAll('div,span')].find(e =>
        (e.textContent||'').trim() === 'Operator:' && e.getBoundingClientRect().width > 40);
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { x: r.x + r.width/2, y: r.y + r.height/2 };
    })()`);
    if (chip) { await click(cdp, chip.x, chip.y); await sleep(2000); }
  }
  if (!(await text(cdp)).includes('Enter your PIN')) throw new Error('PIN gate never appeared');

  // Prefer the popup's own scan/type input over the numpad: it is one stable
  // selector instead of ten, and a real keystroke through it is the same path
  // a badge scanner uses.
  for (const d of pin) {
    const parts = [
      '(() => {',
      '  const want = ' + JSON.stringify(d) + ';',
      '  const b = [...document.querySelectorAll("button")].find(el => {',
      '    if ((el.textContent||"").trim() !== want) return false;',
      '    const r = el.getBoundingClientRect();',
      '    return r.width > 20 && r.height > 20;',
      '  });',
      '  if (!b) return "NOTFOUND";',
      '  b.click();',
      '  return "ok";',
      '})()',
    ];
    const r = await evalJs(cdp, parts.join(' '));
    if (r === 'NOTFOUND') throw new Error('keypad digit not found: ' + d);
    await sleep(280);
  }
  await sleep(3500);
  if ((await text(cdp)).includes('Enter your PIN')) throw new Error('still at the PIN gate after entering ' + pin);
  return 'signed-in';
}

export async function pressEnter(cdp) {
  await cdp.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 });
  await cdp.send('Input.dispatchKeyEvent', { type: 'char', text: '\r', key: 'Enter', windowsVirtualKeyCode: 13 });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 });
  await sleep(600);
}

/** The numpad keys are the ONLY single-digit-only elements inside the popup. */
async function digitKey(cdp, d) {
  // The digit text sits in a small inner span; the clickable key is an
  // ancestor. Find the innermost match, then walk UP to the first box big
  // enough to be a key -- filtering on size at the text node itself finds
  // nothing, which is what the naive version got wrong.
  // Keypad keys are real <button>s. Several IDENTICAL numpads are mounted at
  // once (the login popup, the register popup, ...) and all but the visible
  // one measure 0x0 -- so a non-zero rect is what actually disambiguates them,
  // not the text or the DOM depth.
  const hit = await evalJs(cdp, `
  (() => {
    const want = ${JSON.stringify(d)};
    const b = [...document.querySelectorAll('button')].find(el => {
      if ((el.textContent||'').trim() !== want) return false;
      const r = el.getBoundingClientRect();
      return r.width > 20 && r.height > 20;
    });
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return { x: r.x + r.width/2, y: r.y + r.height/2, w: Math.round(r.width) };
  })()`);
  if (!hit) throw new Error('keypad digit not found: ' + d);
  return hit;
}

/** Pick the ACTIVE CELL by its dropdown label, e.g. "DC1-M10 - Machine 10". */
export async function pickCell(cdp, label) {
  // Target the dropdown structurally, not by its placeholder: the session
  // remembers the last cell, so after the first run the placeholder text is
  // gone and a text match finds nothing. The ACTIVE CELL dropdown is the
  // topmost one on the page (the shift/defect ones live inside tab panels).
  const dd = await evalJs(cdp, `
  (() => {
    // Dropdown ROOTS carry class "ia_dropdown iaDropdownCommon ...". The inner
    // search input only exists while the menu is open, which is why keying off
    // it found nothing on a closed dropdown.
    const els = [...document.querySelectorAll('div.ia_dropdown')]
      .map(e => ({ e, r: e.getBoundingClientRect() }))
      .filter(o => o.r.width > 120 && o.r.height > 20)
      .sort((a, b) => a.r.y - b.r.y);
    if (!els.length) return null;
    const r = els[0].r;   // ACTIVE CELL sits above every tab-panel dropdown
    return { x: r.x + r.width/2, y: r.y + r.height/2 };
  })()`);
  if (!dd) throw new Error('cell dropdown not found');
  await click(cdp, dd.x, dd.y);
  await sleep(900);
  await clickText(cdp, label, { settle: 2500 });
  await sleep(1500);
}

export async function tab(cdp, name, expect = null) {
  for (let attempt = 0; attempt < 3; attempt++) {
    await clickText(cdp, name, { tag: 'div,span', settle: 2200 });
    if (!expect) return;
    if ((await text(cdp)).includes(expect)) return;
  }
  throw new Error(`tab ${name}: never showed ${expect}`);
}

/** Fill a Perspective text input located by placeholder. Real key events. */
export async function fill(cdp, placeholder, value) {
  const hit = await evalJs(cdp, `
  (() => {
    const el = [...document.querySelectorAll('input')].find(i => i.placeholder === ${JSON.stringify(placeholder)});
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width/2, y: r.y + r.height/2 };
  })()`);
  if (!hit) throw new Error('no input with placeholder: ' + placeholder);
  await click(cdp, hit.x, hit.y);
  await sleep(200);
  await cdp.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'a', windowsVirtualKeyCode: 65, modifiers: 2 });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'a', windowsVirtualKeyCode: 65, modifiers: 2 });
  await sleep(100);
  await typeText(cdp, String(value));
  await sleep(400);
  return evalJs(cdp, `
    (() => { const el = [...document.querySelectorAll('input')].find(i => i.placeholder === ${JSON.stringify(placeholder)});
             return el ? el.value : null; })()`);
}

/** Click a real <button> by its label. Use this for ACTIONS: several dialogs
 *  give their heading the same words as their confirm button ("Release
 *  basket"), and a plain text click lands on the heading and silently does
 *  nothing. */
export async function clickButton(cdp, label, opts) {
  const settle = (opts && opts.settle) || 2500;
  const exact = !opts || opts.exact !== false;
  // Dispatch on the ELEMENT rather than at coordinates. A coordinate click can
  // be swallowed by an overlay that sits above the button (Perspective popups
  // stack a transparent modal layer), and it fails silently -- the button
  // paints as if nothing happened. el.click() raises a real, bubbling click
  // that React's handler sees.
  const parts = [
    '(() => {',
    '  const want = ' + JSON.stringify(label) + ';',
    '  const exact = ' + (exact ? 'true' : 'false') + ';',
    '  const b = [...document.querySelectorAll("button")].filter(el => {',
    '    const t = (el.textContent||"").trim();',
    '    if (exact ? t !== want : !t.includes(want)) return false;',
    '    const r = el.getBoundingClientRect();',
    '    return r.width > 10 && r.height > 10 && !el.disabled;',
    '  });',
    '  if (!b.length) return "NOTFOUND";',
    '  b[b.length - 1].click();',
    '  return "clicked:" + b.length;',
    '})()',
  ];
  const res = await evalJs(cdp, parts.join(' '));
  if (res === 'NOTFOUND') throw new Error('clickButton: no enabled button labelled ' + label);
  await sleep(settle);
  return res;
}

export { shot, sleep, evalJs, clickText, findByText, click };
