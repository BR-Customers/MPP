// Finds on-screen controls and records their rectangles next to the screenshot,
// so slide markers are placed from measurement, never guessed pixels.
import fs from 'node:fs';
import path from 'node:path';
import { evalJs } from '../../perspective-capture/cdp.mjs';

const FINDER = `(spec) => {
  const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 2 && r.height > 2; };
  let els = [...document.querySelectorAll(spec.selector || spec.tag || '*')].filter(vis);
  if (spec.placeholder) els = els.filter((e) => e.placeholder === spec.placeholder);
  if (spec.text) {
    const want = spec.text.toLowerCase();
    els = els.filter((e) => { const t = (e.innerText || e.value || '').trim().toLowerCase();
      return spec.exact === false ? t.includes(want) : t === want; });
    // innermost only: drop any element that contains another match
    els = els.filter((e) => !els.some((o) => o !== e && e.contains(o)));
  }
  els.sort((a, b) => { const ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
    return (ra.y - rb.y) || (ra.x - rb.x); });
  let el = (spec.nth || 0) < 0 ? els[els.length + spec.nth] : els[spec.nth || 0];   // nth -1 = last
  if (!el) return null;
  for (let i = 0; i < (spec.up || 0) && el.parentElement; i++) {
    const p = el.parentElement;
    if (spec.maxChars && (p.innerText || '').length > spec.maxChars) break;
    el = p;
  }
  if (spec.scroll) el.scrollIntoView({ block: 'nearest' });
  if (spec.__press) { el.scrollIntoView({ block: 'nearest' }); if (el.focus) el.focus(); el.click(); }
  const r = el.getBoundingClientRect();
  return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
}`;

/** Click a control found the same way measure() finds it. el.click() raises a
 *  real bubbling event React acts on; a coordinate click can be swallowed by the
 *  transparent layer Perspective stacks over popups (harness README rule 2). */
export async function press(cdp, spec, settleMs = 1500) {
  const r = await evalJs(cdp, `(${FINDER})(${JSON.stringify({ ...spec, __press: true })})`);
  if (!r) throw new Error(`press: not found: ${JSON.stringify(spec)}`);
  await new Promise((res) => setTimeout(res, settleMs));
  return r;
}

export async function measure(cdp, specs) {
  const out = {};
  for (const [name, spec] of Object.entries(specs)) {
    if (spec.union) continue;
    const r = await evalJs(cdp, `(${FINDER})(${JSON.stringify(spec)})`);
    if (!r) throw new Error(`measure: "${name}" not found: ${JSON.stringify(spec)}`);
    const pad = spec.pad || 0;
    out[name] = { x: r.x - pad, y: r.y - pad, w: r.w + 2 * pad, h: r.h + 2 * pad };
  }
  for (const [name, spec] of Object.entries(specs)) {
    if (!spec.union) continue;
    const rs = spec.union.map((n) => { if (!out[n]) throw new Error(`union ${name}: ${n} missing`); return out[n]; });
    const x = Math.min(...rs.map((r) => r.x)), y = Math.min(...rs.map((r) => r.y));
    out[name] = { x, y, w: Math.max(...rs.map((r) => r.x + r.w)) - x, h: Math.max(...rs.map((r) => r.y + r.h)) - y };
  }
  return out;
}

export async function capture(cdp, dir, id, specs = {}) {
  fs.mkdirSync(dir, { recursive: true });
  const targets = await measure(cdp, specs);
  const r = await cdp.send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(dir, `${id}.png`), Buffer.from(r.data, 'base64'));
  const size = await evalJs(cdp, '({w: innerWidth, h: innerHeight})');
  const shot = { image: `${id}.png`, width: size.w, height: size.h, targets };
  fs.writeFileSync(path.join(dir, `${id}.json`), JSON.stringify(shot, null, 2));
  console.log(`captured ${id} (${Object.keys(targets).length} targets)`);
  return shot;
}

export async function dumpControls(cdp) {
  return evalJs(cdp, `[...document.querySelectorAll('button,input,[role=button],a')]
    .map(e => ({ e, r: e.getBoundingClientRect() })).filter(o => o.r.width > 2)
    .map(o => ({ tag: o.e.tagName, text: (o.e.innerText||o.e.value||'').trim().slice(0,40),
      placeholder: o.e.placeholder || '', x: Math.round(o.r.x), y: Math.round(o.r.y),
      w: Math.round(o.r.width), h: Math.round(o.r.height) }))`);
}

/** Sign in as a specific operator, whoever the session remembers. Opens the
 *  PIN pad from the sub-header's clickable "Operator: <name>" chip (the top bar's
 *  "Operator: <initials>" is only a label) when it is not already up, then
 *  presses the visible keypad buttons (harness rule 3: several numpads are
 *  mounted, only the visible one has a size). */
export async function signInAs(cdp, pin, initials) {
  const { text, sleep } = await import('../../perspective-capture/lib.mjs');
  const { click } = await import('../../perspective-capture/cdp.mjs');
  const t0 = Date.now();
  while (Date.now() - t0 < 10000) {
    const t = await text(cdp);
    if (t.includes('Enter your PIN')) break;
    if (t.includes('Operator: ' + initials)) return 'already';
    const chip = await evalJs(cdp, `(() => {
      const el = [...document.querySelectorAll('div,span')].find(e => {
        const r = e.getBoundingClientRect();
        return r.width > 20 && /^Operator:/.test((e.innerText||'').trim())
          && getComputedStyle(e).cursor === 'pointer' && e.tagName === 'DIV'; });
      if (!el) return null; const r = el.getBoundingClientRect(); return { x: r.x + r.width/2, y: r.y + r.height/2 }; })()`);
    if (chip) { await click(cdp, chip.x, chip.y); await sleep(2000); } else await sleep(500);
  }
  if (!(await text(cdp)).includes('Enter your PIN')) throw new Error('PIN pad never appeared');
  for (const d of pin) {
    const r = await evalJs(cdp, `(() => { const b = [...document.querySelectorAll('button')].find(el =>
      (el.textContent||'').trim() === ${JSON.stringify(d)} && el.getBoundingClientRect().width > 20);
      if (!b) return 'NOTFOUND'; b.click(); return 'ok'; })()`);
    if (r === 'NOTFOUND') throw new Error('keypad digit not found: ' + d);
    await sleep(280);
  }
  await sleep(3500);
  if (!(await text(cdp)).includes('Operator: ' + initials)) throw new Error('signed in, but not as ' + initials);
  return 'signed-in';
}

/** Focus a text box, empty it, and type into it with real key events (what a
 *  keyboard-wedge scanner does). Perspective commits on real keystrokes only. */
export async function fillBox(cdp, spec, value) {
  const { typeText } = await import('../../perspective-capture/cdp.mjs');
  await press(cdp, spec, 300);
  const mod = { modifiers: 2 };   // Ctrl
  await cdp.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, ...mod });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, ...mod });
  await cdp.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 });
  await typeText(cdp, String(value));
  await new Promise((r) => setTimeout(r, 700));
}
