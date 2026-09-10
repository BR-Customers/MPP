// Minimal Chrome DevTools Protocol driver -- no npm deps (Node 24 has a global
// WebSocket). Exists because the in-app browser pane cannot commit a
// Perspective input binding and hands screenshots back inline rather than as
// files; both are blockers for a screenshot review book. Real Chrome driven
// over CDP dispatches real key events (Perspective commits them) and
// Page.captureScreenshot returns bytes we can write to disk.
import fs from 'node:fs';
import path from 'node:path';

const HOST = '127.0.0.1';
const PORT = 9222;

async function httpJson(p) {
  const res = await fetch(`http://${HOST}:${PORT}${p}`);
  return res.json();
}

export async function connect(url) {
  // Reuse an existing about:blank-ish target if one is free, else make one.
  const t = await httpJson(`/json/new?${encodeURIComponent(url)}`).catch(async () => {
    const list = await httpJson('/json/list');
    return list.find((x) => x.type === 'page');
  });
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });

  let id = 0;
  const pending = new Map();
  const listeners = [];
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    } else if (msg.method) {
      listeners.forEach((fn) => fn(msg));
    }
  };

  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const myId = ++id;
      pending.set(myId, { resolve, reject });
      ws.send(JSON.stringify({ id: myId, method, params }));
      setTimeout(() => {
        if (pending.has(myId)) { pending.delete(myId); reject(new Error(`timeout: ${method}`)); }
      }, 30000);
    });

  await send('Page.enable');
  await send('Runtime.enable');
  return { send, on: (fn) => listeners.push(fn), close: () => ws.close(), targetId: t.id };
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Evaluate in the page and return the JS value. */
export async function evalJs(cdp, expression) {
  const r = await cdp.send('Runtime.evaluate', {
    expression, returnByValue: true, awaitPromise: true,
  });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.text + ' :: ' + expression);
  return r.result.value;
}

/** Centre of the first element whose visible text matches, or null. */
export async function findByText(cdp, text, { tag = '*', nth = 0, exact = false } = {}) {
  const js = `
  (() => {
    const want = ${JSON.stringify(text)};
    const all = [...document.querySelectorAll(${JSON.stringify(tag)})];
    const hits = all.filter(e => {
      const t = (e.textContent || '').trim();
      const ok = ${exact} ? t === want : t.includes(want);
      if (!ok) return false;
      // innermost match only -- otherwise every ancestor container matches too
      return ![...e.children].some(c => ((c.textContent||'').trim().includes(want)));
    });
    const el = hits[${nth}];
    if (!el) return null;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return null;
    return { x: r.x + r.width/2, y: r.y + r.height/2, w: r.width, h: r.height, text: (el.textContent||'').trim().slice(0,80) };
  })()`;
  return evalJs(cdp, js);
}

export async function click(cdp, x, y) {
  // `buttons` is NOT optional: without the bitmask on mousePressed, Chrome
  // synthesises an event that many React handlers ignore, so the click looks
  // delivered and does nothing. Move first so hover/focus handlers run.
  const base = { x: Math.round(x), y: Math.round(y), button: 'left', clickCount: 1 };
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: base.x, y: base.y, buttons: 0 });
  await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', ...base, buttons: 1 });
  await sleep(40);
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...base, buttons: 0 });
}

export async function clickText(cdp, text, opts = {}) {
  const hit = await findByText(cdp, text, opts);
  if (!hit) throw new Error(`clickText: not found: ${text}`);
  await click(cdp, hit.x, hit.y);
  await sleep(opts.settle ?? 700);
  return hit;
}

/** Real key events, one char at a time -- Perspective's inputs commit on these. */
export async function typeText(cdp, str) {
  for (const ch of str) {
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', text: ch, unmodifiedText: ch, key: ch });
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: ch });
    await sleep(30);
  }
}

export async function pressKey(cdp, key, windowsVirtualKeyCode) {
  await cdp.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key, windowsVirtualKeyCode });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key, windowsVirtualKeyCode });
}

/** Click an input by its placeholder, clear it, and type a value. */
export async function fillByPlaceholder(cdp, placeholder, value) {
  const hit = await evalJs(cdp, `
  (() => {
    const el = document.querySelector('input[placeholder=${JSON.stringify(placeholder).replace(/"/g, "'")}]');
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width/2, y: r.y + r.height/2 };
  })()`);
  if (!hit) throw new Error(`fillByPlaceholder: no input with placeholder ${placeholder}`);
  await click(cdp, hit.x, hit.y);
  await sleep(150);
  // select-all then overwrite
  await cdp.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'a', windowsVirtualKeyCode: 65, modifiers: 2 });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'a', windowsVirtualKeyCode: 65, modifiers: 2 });
  await sleep(80);
  await typeText(cdp, String(value));
  await sleep(250);
  return true;
}

export async function shot(cdp, outDir, name, clip = null) {
  fs.mkdirSync(outDir, { recursive: true });
  const params = { format: 'png', captureBeyondViewport: false };
  if (clip) params.clip = { ...clip, scale: 1 };
  const { data } = await cdp.send('Page.captureScreenshot', params);
  const file = path.join(outDir, `${name}.png`);
  fs.writeFileSync(file, Buffer.from(data, 'base64'));
  return file;
}

export async function setViewport(cdp, width, height) {
  await cdp.send('Emulation.setDeviceMetricsOverride', {
    width, height, deviceScaleFactor: 1, mobile: false,
  });
}
