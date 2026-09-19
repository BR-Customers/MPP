// Finds on-screen controls and records their rectangles next to the screenshot,
// so slide markers are placed from measurement, never guessed pixels.
import fs from 'node:fs';
import path from 'node:path';
import { evalJs } from '../../perspective-capture/cdp.mjs';

const FINDER = `(spec) => {
  const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 2 && r.height > 2; };
  let els = [...document.querySelectorAll(spec.tag || '*')].filter(vis);
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
  let el = els[spec.nth || 0];
  if (!el) return null;
  for (let i = 0; i < (spec.up || 0) && el.parentElement; i++) {
    const p = el.parentElement;
    if (spec.maxChars && (p.innerText || '').length > spec.maxChars) break;
    el = p;
  }
  const r = el.getBoundingClientRect();
  return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
}`;

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
