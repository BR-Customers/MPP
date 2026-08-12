// Batch CDP screenshot driver for Perspective (websocket-loaded data).
// Usage: node capbatch.js captures.json [cookies.json]
// captures.json = [{ url, out, wait, w, h, full }]
// cookies.json  = [{ name, value }]  (injected for localhost auth; keep OUT of git)
// Opens ONE page via PUT /json/new, then navigates + captures each entry at 2x scale.
const fs = require('fs');
const captures = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const cookies = process.argv[3] ? JSON.parse(fs.readFileSync(process.argv[3], 'utf8')) : [];
const PORT = 9222;

(async () => {
  const created = await (await fetch(`http://localhost:${PORT}/json/new?about:blank`, { method: 'PUT' })).json();
  const pageId = created.id;
  const ws = new WebSocket(created.webSocketDebuggerUrl);
  let id = 0; const pending = new Map();
  const call = (method, params) => new Promise((res) => { id++; pending.set(id, res); ws.send(JSON.stringify({ id, method, params: params || {} })); });
  await new Promise((r) => ws.addEventListener('open', r));
  ws.addEventListener('message', (ev) => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); } });

  await call('Page.enable', {});
  await call('Network.enable', {});
  for (const ck of cookies) {
    await call('Network.setCookie', { name: ck.name, value: ck.value, domain: 'localhost', path: '/' });
  }
  await call('Emulation.setUserAgentOverride', { userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36' });
  for (const c of captures) {
    const w = c.w || 1600, h = c.h || 1000;
    await call('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 2, mobile: false });
    await call('Page.navigate', { url: c.url });
    await new Promise((r) => setTimeout(r, c.wait || 9000));
    let clip;
    if (c.full) { const { cssContentSize } = await call('Page.getLayoutMetrics', {}); if (cssContentSize) clip = { x: 0, y: 0, width: cssContentSize.width, height: cssContentSize.height, scale: 1 }; }
    const shot = await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: !!c.full, clip });
    fs.writeFileSync(c.out, Buffer.from(shot.data, 'base64'));
    console.log('wrote', c.out, `(${w}x${h}${c.full ? ' full' : ''})`);
  }
  await fetch(`http://localhost:${PORT}/json/close/${pageId}`).catch(() => {});
  ws.close();
  process.exit(0);
})().catch((e) => { console.error('ERR', e); process.exit(1); });
