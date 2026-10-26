// capture.js -- drive the real MPP Perspective application through the sales-kit steps and save
// each step's DOM, a PNG, and (once per run) the full stylesheet bundle.
//
//   node capture.js --steps all|name1,name2 --out <dir>      capture steps from steps.js
//   node capture.js --probe                                  print the Terminal Selector's root node text
//
// Drives the installed Chrome through puppeteer-core (no browser download). Real input events, so
// Perspective input bindings commit as they do for an operator. Output per step:
//   <out>/raw/<name>.json  {w, h, route, html}   html = the page with scripts/links/styles removed,
//                                                input values copied into attributes, icons and
//                                                images inlined (no reference back to the gateway)
//   <out>/raw/<name>.png                          what the screen looked like (unsanitized: internal)
//   <out>/raw/bundle.css                          every stylesheet the page used, url()s inlined
const puppeteer = require('puppeteer-core');
const fs = require('fs');
const path = require('path');

const GATEWAY = 'http://localhost:8088';
const PROJECT = 'MPP';
const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const VIEWPORT = { width: 1904, height: 882 };

const args = process.argv.slice(2);
const arg = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const url = route => GATEWAY + '/data/perspective/client/' + PROJECT + route;

async function ready(page, what, timeout = 30000) {
  // `what` is a CSS selector, or text:<visible text> to wait for.
  if (what.startsWith('text:')) {
    const t = what.slice(5);
    await page.waitForFunction(x => document.body && document.body.innerText.includes(x), { timeout }, t);
  } else {
    await page.waitForSelector(what, { visible: true, timeout });
  }
}

async function settle(page, quietMs = 1500, maxMs = 15000) {
  // Wait until the DOM has not changed for quietMs (Perspective renders in waves).
  await page.evaluate((quiet, max) => new Promise(res => {
    let last = Date.now();
    const obs = new MutationObserver(() => { last = Date.now(); });
    obs.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true });
    const start = Date.now();
    const t = setInterval(() => {
      if (Date.now() - last >= quiet || Date.now() - start >= max) { clearInterval(t); obs.disconnect(); res(); }
    }, 100);
  }), quietMs, maxMs);
}

async function clickText(page, text, opts = {}) {
  // Click the innermost visible element whose own text (trimmed) equals `text` (or starts with it).
  const ok = await page.evaluate((t, starts) => {
    const els = [...document.querySelectorAll('body *')].filter(e => {
      const r = e.getBoundingClientRect();
      if (!r.width || !r.height) return false;
      const own = (e.innerText || '').trim();
      return starts ? own.startsWith(t) : own === t;
    });
    const el = els.reverse().find(e => ![...e.children].some(c => els.includes(c))) || els[0];
    if (!el) return false;
    el.scrollIntoView({ block: 'center' });
    const r = el.getBoundingClientRect();
    window.__clickAt = [r.left + r.width / 2, r.top + r.height / 2];
    return true;
  }, text, !!opts.startsWith);
  if (!ok) throw new Error('clickText: no visible element with text "' + text + '"');
  const [x, y] = await page.evaluate(() => window.__clickAt);
  await page.mouse.click(x, y);
}

async function act(page, a) {
  if (a.click) await clickText(page, a.click, a);
  else if (a.clickSel) { await page.waitForSelector(a.clickSel, { visible: true }); await page.click(a.clickSel); }
  else if (a.type !== undefined) {
    if (a.into) { await page.waitForSelector(a.into, { visible: true }); await page.click(a.into, { clickCount: 3 }); }
    await page.keyboard.type(String(a.type), { delay: 40 });
  }
  else if (a.key) await page.keyboard.press(a.key);
  else if (a.wait) await ready(page, a.wait, a.timeout);
  else if (a.sleep) await sleep(a.sleep);
  else if (a.evaluate) await page.evaluate(a.evaluate);
  if (!a.noSettle) await settle(page, 800, 8000);
}

async function selectTerminal(page, code) {
  // The Terminal Selector accepts a scanned terminal code; typing it + Enter is what a scan does.
  await page.goto(url('/shop-floor/terminal-selector'), { waitUntil: 'networkidle2', timeout: 60000 });
  await ready(page, 'text:Select your terminal');
  await settle(page);
  const input = await page.$('input');
  if (!input) throw new Error('selectTerminal: no scan field on the Terminal Selector');
  await input.click({ clickCount: 3 });
  await page.keyboard.type(code, { delay: 40 });
  await page.keyboard.press('Enter');
  await page.waitForFunction(() => !location.pathname.endsWith('/terminal-selector'), { timeout: 30000 });
  await settle(page);
}

async function snapshotHtml(page) {
  return page.evaluate(async (gateway) => {
    const toDataUri = async (u) => {
      const r = await fetch(u); const b = await r.blob();
      return await new Promise(res => { const fr = new FileReader(); fr.onload = () => res(fr.result); fr.readAsDataURL(b); });
    };
    const doc = document.documentElement.cloneNode(true);
    // live values -> attributes so the static copy shows what was typed
    const live = [...document.querySelectorAll('input, textarea, select')];
    const copies = [...doc.querySelectorAll('input, textarea, select')];
    live.forEach((el, i) => {
      const c = copies[i]; if (!c) return;
      if (el.tagName === 'TEXTAREA') c.textContent = el.value;
      else if (el.tagName === 'SELECT') [...c.options].forEach((o, j) => { if (j === el.selectedIndex) o.setAttribute('selected', ''); });
      else { c.setAttribute('value', el.value); if (el.checked) c.setAttribute('checked', ''); }
    });
    doc.querySelectorAll('script, link, style, noscript, iframe').forEach(e => e.remove());
    // <use> pointing at an external sprite -> inline the referenced symbol's content
    for (const use of [...doc.querySelectorAll('use')]) {
      const href = use.getAttribute('href') || use.getAttribute('xlink:href') || '';
      if (!href || href.startsWith('#')) continue;
      const [file, id] = href.split('#');
      try {
        const txt = await (await fetch(new URL(file, location.href))).text();
        const svgDoc = new DOMParser().parseFromString(txt, 'image/svg+xml');
        const sym = id ? svgDoc.getElementById(id) : svgDoc.documentElement;
        const svg = use.closest('svg');
        if (sym && svg) {
          if (sym.getAttribute('viewBox') && !svg.getAttribute('viewBox')) svg.setAttribute('viewBox', sym.getAttribute('viewBox'));
          use.replaceWith(...[...sym.childNodes].map(n => document.importNode(n, true)));
        }
      } catch (e) { use.remove(); }
    }
    for (const img of [...doc.querySelectorAll('img[src], image[href]')]) {
      const attr = img.hasAttribute('src') ? 'src' : 'href';
      const v = img.getAttribute(attr);
      if (v && !v.startsWith('data:')) { try { img.setAttribute(attr, await toDataUri(new URL(v, location.href))); } catch (e) { img.removeAttribute(attr); } }
    }
    for (const el of [...doc.querySelectorAll('[style*="url("]')]) {
      let s = el.getAttribute('style');
      for (const m of [...s.matchAll(/url\((['"]?)([^'")]+)\1\)/g)]) {
        if (m[2].startsWith('data:')) continue;
        try { s = s.replace(m[0], 'url("' + await toDataUri(new URL(m[2], location.href)) + '")'); } catch (e) {}
      }
      el.setAttribute('style', s);
    }
    return '<!DOCTYPE html>' + doc.outerHTML;
  }, GATEWAY);
}

async function bundleCss(page) {
  return page.evaluate(async () => {
    const toDataUri = async (u) => {
      const r = await fetch(u); const b = await r.blob();
      return await new Promise(res => { const fr = new FileReader(); fr.onload = () => res(fr.result); fr.readAsDataURL(b); });
    };
    // Only the font faces this page actually loaded are kept: the gateway offers a dozen
    // (every Roboto variant) and inlining them all makes the bundle megabytes.
    const loaded = new Set([...document.fonts].filter(f => f.status === 'loaded')
      .map(f => (f.family.replace(/["']/g, '') + '|' + String(f.weight) + '|' + f.style).toLowerCase()));
    const keepFace = (block) => {
      const fam = (block.match(/font-family\s*:\s*["']?([^;"']+)/i) || [])[1] || '';
      const wt = (block.match(/font-weight\s*:\s*([^;]+)/i) || [])[1] || '400';
      const st = (block.match(/font-style\s*:\s*([^;]+)/i) || [])[1] || 'normal';
      const w = String(wt).trim() === 'normal' ? '400' : String(wt).trim() === 'bold' ? '700' : String(wt).trim();
      return loaded.has((fam.trim() + '|' + w + '|' + st.trim()).toLowerCase());
    };
    let out = '';
    for (const sheet of [...document.styleSheets]) {
      let text = '';
      if (sheet.href) text = await (await fetch(sheet.href)).text();
      else if (sheet.ownerNode) text = sheet.ownerNode.textContent;
      text = text.replace(/@font-face\s*\{[^}]*\}/gi, b => keepFace(b) ? b : '');
      const base = sheet.href || location.href;
      // Large images in the client CSS are loading animations and splash backgrounds (never on an
      // app screen); they would add megabytes, so they become a transparent pixel. Fonts are kept.
      const PIXEL = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
      for (const m of [...text.matchAll(/url\((['"]?)([^'")]+)\1\)/g)]) {
        if (m[2].startsWith('#')) continue;
        let uri = m[2];
        try { if (!uri.startsWith('data:')) uri = await toDataUri(new URL(m[2], base)); } catch (e) { continue; }
        if (uri.startsWith('data:image') && uri.length > 60000) uri = PIXEL;
        text = text.split(m[0]).join('url("' + uri + '")');
      }
      out += '\n/* ---- ' + (sheet.href ? new URL(sheet.href).pathname : 'inline') + ' ---- */\n' + text;
    }
    return out;
  });
}

(async () => {
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new', defaultViewport: VIEWPORT });
  const page = await browser.newPage();
  try {
    if (args.includes('--probe')) {
      await page.goto(url('/shop-floor/terminal-selector'), { waitUntil: 'networkidle2', timeout: 60000 });
      await ready(page, 'text:Select your terminal');
      await settle(page);
      const root = await page.evaluate(() => {
        const t = document.body.innerText.split('\n').map(s => s.trim()).filter(Boolean);
        const i = t.findIndex(s => s.startsWith('Terminal Onboarding'));
        return t[i + 1] || '';
      });
      console.log(root);
      return;
    }
    const steps = require('./steps.js');
    const want = arg('--steps', 'all');
    const list = want === 'all' ? steps : steps.filter(s => want.split(',').includes(s.name));
    if (!list.length) throw new Error('no steps match ' + want);
    const raw = path.join(arg('--out', 'captures'), 'raw');
    fs.mkdirSync(raw, { recursive: true });
    let terminal = null, bundled = false;
    for (const s of list) {
      process.stdout.write(s.name + ' ... ');
      await page.setViewport(s.viewport || VIEWPORT);
      if (s.terminal && s.terminal !== terminal) { await selectTerminal(page, s.terminal); terminal = s.terminal; }
      if (s.route) {
        await page.goto(url(s.route), { waitUntil: 'networkidle2', timeout: 60000 });
        await settle(page);
      }
      for (const a of s.actions || []) await act(page, a);
      if (s.ready) await ready(page, s.ready);
      await settle(page);
      if (s.after) await sleep(s.after);
      const vp = page.viewport();
      fs.writeFileSync(path.join(raw, s.name + '.json'), JSON.stringify({ w: vp.width, h: vp.height, route: s.route || '', html: await snapshotHtml(page) }));
      await page.screenshot({ path: path.join(raw, s.name + '.png') });
      if (!bundled) { fs.writeFileSync(path.join(raw, 'bundle.css'), await bundleCss(page)); bundled = true; }
      console.log('ok');
    }
  } finally {
    await browser.close();
  }
})().catch(e => { console.error('\nFAILED: ' + e.message); process.exit(1); });
