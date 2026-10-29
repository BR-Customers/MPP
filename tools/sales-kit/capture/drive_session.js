// drive_session.js -- keep ONE headed Chrome open across commands, for capture sessions that need
// sign-ins and live step adjustment (sales-kit module 4 walk, 2026-10-29). Credentials come only
// from CAP_USER / CAP_PASS in the environment ({"cred":true}); nothing is written to disk.
// Output: CAP_RAW (default ../captures/m4/raw). Notes: notes/2026-10-27_super-lot-gateway-walk-bugs.md
//   node drive.js launch
//   node drive.js term "Die Cast/Terminal"
//   node drive.js go /shop-floor/controlled-runs [project]
//   node drive.js do '<json array of capture.js actions>'   (+ {"cred":true} types CAP_USER / CAP_PASS)
//   node drive.js text            visible text
//   node drive.js shot <png>
//   node drive.js snap <name>     -> CAP/m4/raw/<name>.json + .png (+ bundle.css once)
const CAPDIR = __dirname;
const fs = require('fs'), path = require('path'), os = require('os');
const puppeteer = require(CAPDIR + '/node_modules/puppeteer-core');
const cap = require(CAPDIR + '/capture.js');
const RAW = process.env.CAP_RAW || path.join(__dirname, '..', 'captures', 'm4', 'raw');
const PORT = 9333;
const vpf = path.join(os.tmpdir(), 'mpp-capture-vp.txt');   // viewport kept across connects
const sleep = ms => new Promise(r => setTimeout(r, ms));
const [cmd, ...rest] = process.argv.slice(2);

async function page() {
  const b = await puppeteer.connect({ browserURL: 'http://127.0.0.1:' + PORT, defaultViewport: null });
  const pages = await b.pages();
  const p = pages.find(x => x.url().startsWith('http')) || pages[pages.length - 1];
  const vp = (fs.existsSync(vpf) ? fs.readFileSync(vpf, 'utf8') : '1904,882').trim().split(',').map(Number);
  const cur = p.viewport();
  if (!cur || cur.width !== vp[0] || cur.height !== vp[1]) await p.setViewport({ width: vp[0], height: vp[1] });
  return [b, p];
}

async function typeCred(p) {
  // username into the visible text input just before the visible password input, password into it
  const u = process.env.CAP_USER, pw = process.env.CAP_PASS;
  if (!u || !pw) throw new Error('CAP_USER / CAP_PASS not set');
  const pts = await p.evaluate(() => {
    const vis = e => e.getBoundingClientRect().height > 0;
    const ins = [...document.querySelectorAll('input')].filter(vis);
    const pi = ins.findIndex(i => i.type === 'password');
    if (pi < 0) return null;
    const ui = ins.slice(0, pi).reverse().find(i => i.type !== 'password' && i.type !== 'checkbox');
    const c = e => { const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; };
    return { u: ui ? c(ui) : null, p: c(ins[pi]) };
  });
  if (!pts) throw new Error('no password field visible');
  if (pts.u) { await p.mouse.click(pts.u[0], pts.u[1], { clickCount: 3 }); await p.keyboard.type(u, { delay: 30 }); }
  await p.mouse.click(pts.p[0], pts.p[1], { clickCount: 3 });
  await p.keyboard.type(pw, { delay: 30 });
  await sleep(300);
}

(async () => {
  if (cmd === 'launch') {
    const { spawn } = require('child_process');
    const ud = path.join(os.tmpdir(), 'mpp-capture-chrome-profile');
    const c = spawn('C:/Program Files/Google/Chrome/Application/chrome.exe',
      ['--remote-debugging-port=' + PORT, '--user-data-dir=' + ud, '--window-size=1904,1022', '--no-first-run', '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows', 'about:blank'],
      { detached: true, stdio: 'ignore' });
    c.unref(); await sleep(3000);
    const [b, p] = await page(); await p.setViewport({ width: 1904, height: 882 }); b.disconnect();
    console.log('launched'); return;
  }
  const [b, p] = await page();
  try {
    if (cmd === 'quit') { await b.close(); console.log('closed'); return; }
    if (cmd === 'pdf') {
      // click Print PDF and save the first PDF-looking response body to rest[0]
      let saved = false;
      p.on('response', async r => {
        try {
          const ct = (r.headers()['content-type'] || '') + ' ' + (r.headers()['content-disposition'] || '');
          if (!saved && /pdf/i.test(ct + r.url())) { const buf = await r.buffer(); if (buf.slice(0, 4).toString() === '%PDF') { fs.writeFileSync(rest[0], buf); saved = true; console.log('pdf ' + buf.length + ' ' + r.url().slice(0, 120)); } }
        } catch (e) {}
      });
      await p.evaluate(() => {
        window.__pdfB64 = null;
        const orig = URL.createObjectURL.bind(URL);
        URL.createObjectURL = (b) => {
          try { if (b && b.size > 1000) { const fr = new FileReader(); fr.onload = () => { window.__pdfB64 = fr.result; }; fr.readAsDataURL(b); } } catch (e) {}
          return orig(b);
        };
      });
      await sleep(1000);
      await cap.clickText(p, 'Print PDF');
      for (let i = 0; i < 40 && !saved; i++) {
        await sleep(500);
        const d = await p.evaluate(() => window.__pdfB64);
        if (d) { const buf = Buffer.from(d.split(',')[1], 'base64'); if (buf.slice(0, 4).toString() === '%PDF') { fs.writeFileSync(rest[0], buf); saved = true; console.log('pdf (blob) ' + buf.length); } }
      }
      console.log(saved ? 'saved' : 'no pdf seen');
      return;
    }
    if (cmd === 'term') { await cap.selectTerminal(p, rest[0].split('/')); }
    else if (cmd === 'go') {
      const u = 'http://localhost:8088/data/perspective/client/' + (rest[1] || 'MPP') + rest[0];
      await p.goto(u, { waitUntil: 'domcontentloaded', timeout: 60000 }); await cap.settle(p);
    }
    else if (cmd === 'do') {
      for (const a of JSON.parse(rest[0])) {
        if (a.dlDir) { const s = await p.browser().target().createCDPSession(); await s.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: a.dlDir, eventsEnabled: true }); }
        else if (a.wheel) { await p.mouse.move(a.wheel[0], a.wheel[1]); await p.mouse.wheel({ deltaY: a.wheel[2] }); await cap.settle(p, 800, 8000); }
        else if (a.xy) { await p.mouse.click(a.xy[0], a.xy[1]); await cap.settle(p, 800, 8000); }
        else if (a.ph) {
          // click the visible input / textarea whose placeholder starts with a.ph, then type a.value
          const pt = await p.evaluate(t => {
            const e = [...document.querySelectorAll('input, textarea')].find(x => x.getBoundingClientRect().height > 0 && (x.placeholder || '').startsWith(t));
            if (!e) return null; const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2];
          }, a.ph);
          if (!pt) throw new Error('no field with placeholder ' + a.ph);
          await p.mouse.click(pt[0], pt[1], { clickCount: 3 });
          if (a.value !== undefined) await p.keyboard.type(String(a.value), { delay: 30 });
          await cap.settle(p, 800, 8000);
        }
        else if (a.cred) { await typeCred(p); await cap.settle(p, 800, 8000); }
        else if (a.viewport) { fs.writeFileSync(vpf, a.viewport.join(',')); await p.setViewport({ width: a.viewport[0], height: a.viewport[1] }); await cap.settle(p, 800, 8000); }
        else await cap.act(p, a);
      }
    }
    else if (cmd === 'text') { console.log(await p.evaluate(() => document.body.innerText)); }
    else if (cmd === 'shot') { await p.screenshot({ path: rest[0] }); }
    else if (cmd === 'snap') {
      fs.mkdirSync(RAW, { recursive: true });
      await cap.settle(p);
      const vp = p.viewport() || await p.evaluate(() => ({ width: innerWidth, height: innerHeight }));
      const route = new URL(p.url()).pathname.replace(/^\/data\/perspective\/client\/[^/]+/, '');
      fs.writeFileSync(path.join(RAW, rest[0] + '.json'), JSON.stringify({ w: vp.width, h: vp.height, route, html: await cap.snapshotHtml(p) }));
      await p.screenshot({ path: path.join(RAW, rest[0] + '.png') });
      if (!fs.existsSync(path.join(RAW, 'bundle.css'))) fs.writeFileSync(path.join(RAW, 'bundle.css'), await cap.bundleCss(p));
      console.log('saved ' + rest[0]);
    }
    else throw new Error('unknown command ' + cmd);
    if (cmd !== 'text' && cmd !== 'snap') console.log('ok  ' + p.url());
  } catch (e) { console.error('FAILED: ' + e.message); process.exitCode = 1; }
  finally { b.disconnect(); }
})();
