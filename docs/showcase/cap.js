// CDP screenshot driver for Perspective (websocket-loaded data).
// Usage: node cap.js <outfile> <waitMs> <url> [width] [height] [fullPage]
// Connects to a running Chrome at :9222, opens a tab, waits real time for the
// SPA + WebSocket data to render, captures a 2x-scale PNG, closes the tab.
const [,, outfile, waitMsStr, url, wStr, hStr, fullStr] = process.argv;
const waitMs = parseInt(waitMsStr || '9000', 10);
const width = parseInt(wStr || '1600', 10);
const height = parseInt(hStr || '1000', 10);
const fullPage = (fullStr === 'full');
const fs = require('fs');

function send(ws, id, method, params, sessionId) {
  const msg = { id, method, params: params || {} };
  if (sessionId) msg.sessionId = sessionId;
  ws.send(JSON.stringify(msg));
}

(async () => {
  const ver = await (await fetch('http://localhost:9222/json/version')).json();
  const ws = new WebSocket(ver.webSocketDebuggerUrl);
  let id = 0;
  const pending = new Map();
  let sessionId = null;
  const call = (method, params, sess) => new Promise((res) => { id++; pending.set(id, res); send(ws, id, method, params, sess); });

  let onAttached = null;
  await new Promise((r) => ws.addEventListener('open', r));
  ws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.method === 'Target.attachedToTarget' && onAttached) { onAttached(m.params.sessionId); onAttached = null; }
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); }
  });

  const log = (...a) => console.error('[cap]', ...a);
  setTimeout(() => { log('HARD TIMEOUT'); process.exit(2); }, waitMs + 30000);
  const { targetId } = await call('Target.createTarget', { url: 'about:blank' }); log('createTarget', targetId);
  const attachedP = new Promise((r) => { onAttached = r; });
  const attach = await call('Target.attachToTarget', { targetId, flatten: true });
  sessionId = (attach && attach.sessionId) || await attachedP; log('attached', sessionId);

  await call('Page.enable', {}, sessionId); log('page.enable');
  await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 2, mobile: false }, sessionId); log('metrics');
  await call('Page.navigate', { url }, sessionId); log('navigated, waiting', waitMs);
  await new Promise((r) => setTimeout(r, waitMs)); log('wait done');

  let clip = undefined;
  if (fullPage) {
    const { cssContentSize } = await call('Page.getLayoutMetrics', {}, sessionId);
    if (cssContentSize) clip = { x: 0, y: 0, width: cssContentSize.width, height: cssContentSize.height, scale: 1 };
  }
  const shot = await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: fullPage, clip }, sessionId);
  fs.writeFileSync(outfile, Buffer.from(shot.data, 'base64'));
  await call('Target.closeTarget', { targetId });
  console.log('wrote', outfile);
  ws.close();
  process.exit(0);
})().catch((e) => { console.error('ERR', e); process.exit(1); });
