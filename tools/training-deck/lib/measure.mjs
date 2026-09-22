// Finds on-screen controls and records their rectangles next to the screenshot,
// so slide markers are placed from measurement, never guessed pixels.
import fs from 'node:fs';
import path from 'node:path';
import { evalJs } from '../../perspective-capture/cdp.mjs';

const FINDER = `(spec) => {
  const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 2 && r.height > 2; };
  // spec.within: search only inside the box that holds this label. Several
  // controls on a screen are identical apart from the label above them (the
  // die-wide shot boxes, the per-cavity numbers), and the other tab's controls
  // stay mounted in the DOM, so an index across the page is meaningless.
  let root = document;
  if (spec.within) {
    const label = [...document.querySelectorAll('div,span')]
        .find((e) => (e.innerText || '').trim() === spec.within && vis(e))
      || [...document.querySelectorAll('input')].find((e) => e.value === spec.within && vis(e));
    if (!label) return null;
    root = label;
    if (spec.withinRow) {
      // Walk up to the ROW: full-width but short. Counting parents instead
      // silently escapes the row and hits the die-wide boxes above it.
      for (let i = 0; i < 12 && root.parentElement; i++) {
        const r = root.getBoundingClientRect();
        if (r.width > 900 && r.height < 140) break;
        root = root.parentElement;
      }
      const r = root.getBoundingClientRect();
      if (!(r.width > 900 && r.height < 140)) return null;
    } else {
      for (let i = 0; i < (spec.withinUp || 3) && root.parentElement; i++) root = root.parentElement;
    }
  }
  let els = [...root.querySelectorAll(spec.selector || spec.tag || '*')].filter(vis);
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
    if (t.includes('Operator: ' + initials) || t.includes('Operator: Sam Taylor')) return 'already';
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
  const after = await text(cdp);
  // The top bar shows initials, the sub-header the name; a session whose
  // terminal has not resolved yet shows only the name.
  if (!after.includes('Operator: ' + initials) && !after.includes('Operator: Sam Taylor')) throw new Error('signed in, but not as ' + initials);
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
  // Tab commits it. Perspective writes the binding on blur, and a click on some
  // other element does not always blur a numeric field -- without this the
  // screen keeps the old value and nothing downstream recalculates.
  await cdp.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
  await new Promise((r) => setTimeout(r, 900));
}

/** Open a Perspective dropdown and choose an option by its text.
 *  Two gotchas: the field opens on a real mouse click (el.click() on the root
 *  does nothing), and the options render in a portal outside the field, with
 *  class iaDropdownCommon_option. `where` is {near: '<label text>'} -- indexes
 *  are useless here because the OTHER tab's row dropdowns stay mounted in the
 *  DOM, so "the second dropdown" was a per-cavity part picker. */
export async function chooseFromDropdown(cdp, where, optionText) {
  const { click } = await import('../../perspective-capture/cdp.mjs');
  const LOCATE = `(() => {
    // {text}: the dropdown's own text (its placeholder or current value).
    if (${JSON.stringify(!!where.text)}) {
      const own = [...document.querySelectorAll('div.ia_dropdown')]
        .find(e => (e.innerText || '').trim().startsWith(${JSON.stringify(where.text || '')})
          && e.getBoundingClientRect().width > 80);
      if (!own) return null;
      const r = own.getBoundingClientRect();
      return { x: r.x, y: r.y, w: r.width, h: r.height, text: own.innerText.trim() };
    }
    const label = [...document.querySelectorAll('div,span')]
      .find(e => (e.innerText || '').trim() === ${JSON.stringify(where.near)}
        && e.getBoundingClientRect().width > 2);
    if (!label) return null;
    let box = label;
    for (let i = 0; i < 6 && box.parentElement; i++) {
      box = box.parentElement;
      const dd = box.querySelector('div.ia_dropdown');
      if (dd) { const r = dd.getBoundingClientRect();
        if (r.width > 80) return { x: r.x, y: r.y, w: r.width, h: r.height, text: dd.innerText.trim() }; }
    }
    return null; })()`;
  const dd = await evalJs(cdp, LOCATE);
  if (!dd) throw new Error(`no dropdown for ${JSON.stringify(where)}`);
  await click(cdp, dd.x + dd.w / 2, dd.y + dd.h / 2);
  await new Promise((r) => setTimeout(r, 1200));
  // The option list ignores a synthetic el.click(); it wants real mouse events,
  // so measure the option and click its centre through the Input domain.
  const hit = await evalJs(cdp, `(() => {
    const want = ${JSON.stringify(optionText)};
    const o = [...document.querySelectorAll('.iaDropdownCommon_option')]
      .find(e => (e.innerText || '').trim().startsWith(want));
    if (!o) return { options: [...document.querySelectorAll('.iaDropdownCommon_option')].map(e => (e.innerText||'').trim()) };
    const r = o.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);
  if (!hit || hit.options) throw new Error(`option "${optionText}" not in the ${JSON.stringify(where)} dropdown: ${JSON.stringify(hit && hit.options)}`);
  await click(cdp, hit.x, hit.y);
  await new Promise((r) => setTimeout(r, 2000));
  // Read the value back by finding the dropdown the same way again -- after a
  // pick the layout can reflow and move it, so its old position means nothing.
  const again = await evalJs(cdp, LOCATE);
  const chosen = again ? again.text : '(dropdown gone)';
  if (!String(chosen).startsWith(optionText)) throw new Error(`the ${JSON.stringify(where)} dropdown still reads "${chosen}"`);
}
