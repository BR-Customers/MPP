// Plain marketing screenshots of the MES -- no markup. Dev only.
//
//   node tools/marketing-shots/capture_marketing.mjs [--only config|floor]
//
// Plant floor: headless capture Chrome on CDP port 9333.
// Config Tool: needs an AD login, which this script never types. Open a
// VISIBLE Chrome on port 9334, sign in to MPP_Config there yourself, then run
// with --only config; the script reuses that signed-in window's session.
//
// Output: docs/marketing/shots/<nn>_<name>.png at 1920x1080 plus shots.json
// (section, title, file) for build_marketing_deck.js.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setViewport, sleep, evalJs, click } from '../perspective-capture/cdp.mjs';
import { signInAs, press, chooseFromDropdown, fillBox } from '../training-deck/lib/measure.mjs';
import * as db from '../training-deck/lib/dc_db.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.resolve(HERE, '../../docs/marketing/shots');
const MANIFEST = path.join(OUT, 'shots.json');
const GW = 'http://localhost:8088/data/perspective/client';
const args = process.argv.slice(2);
const only = args.includes('--only') ? args[args.indexOf('--only') + 1] : null;

fs.mkdirSync(OUT, { recursive: true });
const manifest = fs.existsSync(MANIFEST) ? JSON.parse(fs.readFileSync(MANIFEST, 'utf8')) : [];
function record(entry) {
  const i = manifest.findIndex((m) => m.file === entry.file);
  if (i >= 0) manifest[i] = entry; else manifest.push(entry);
  manifest.sort((a, b) => a.file.localeCompare(b.file));
  fs.writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2));
}

async function shot(cdp, file, section, title) {
  await sleep(1500);
  const r = await cdp.send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(OUT, file), Buffer.from(r.data, 'base64'));
  record({ file, section, title });
  console.log(`shot ${file}  [${section}] ${title}`);
}

async function go(cdp, url, settle = 6000) {
  await cdp.send('Page.navigate', { url });
  await sleep(settle);
}

/** Open a target on a given CDP port. The Config Tool window is visible and
 *  already signed in, so we attach to ITS page instead of opening a new one --
 *  a new tab would share the session cookie, but attaching keeps it simple. */
async function attach(port, { reuseExisting }) {
  process.env.CDP_PORT = String(port);
  const { connect } = await import(`../perspective-capture/cdp.mjs?port=${port}`);
  return connect(`${GW}/MPP`, { allowVisible: true, reuseExisting });
}

// ---------------------------------------------------------------- floor ----
async function floor() {
  const { connect } = await import('../perspective-capture/cdp.mjs');
  const cdp = await connect(`${GW}/MPP/shop-floor/die-cast`);
  try {
    await setViewport(cdp, 1920, 1080);
    await go(cdp, `${GW}/MPP/shop-floor/die-cast`, 9000);
    await signInAs(cdp, db.PIN, 'ST');
    const { pickCell } = await import('../perspective-capture/lib.mjs');
    await pickCell(cdp, 'DC1-M11 - Machine 11');
    // Reconcile first and SUBMIT it (Dev only), so the baskets carry real
    // piece counts and the production dashboard has a shift to show.
    await press(cdp, { text: 'Reconcile Shift', tag: 'div' }, 3000);
    await chooseFromDropdown(cdp, { near: 'REPORTING SHIFT' }, 'First Shift');
    await fillBox(cdp, { placeholder: '0' }, '900');
    await press(cdp, { text: 'Compute', tag: 'button' }, 4500);
    await fillBox(cdp, { within: 'Warm-up shots', withinUp: 2, tag: 'input' }, '6');
    await shot(cdp, '22_diecast_reconcile.png', 'Plant floor: Die cast', 'End-of-shift reconciliation');
    await press(cdp, { text: 'SUBMIT SHIFT ENTRY', tag: 'button' }, 3000);
    const confirm = await evalJs(cdp, `[...document.querySelectorAll('button')]
      .filter(b => b.getBoundingClientRect().width > 20 && /confirm|submit|record|yes/i.test(b.innerText)
        && b.innerText.trim() !== 'SUBMIT SHIFT ENTRY').map(b => b.innerText.trim())`);
    console.log('confirm buttons:', JSON.stringify(confirm));
    if (confirm.length) await press(cdp, { text: confirm[confirm.length - 1], tag: 'button' }, 4000);

    await press(cdp, { text: 'Lot Management', tag: 'div' }, 2500);
    await press(cdp, { text: 'Refresh', tag: 'button' }, 3000);
    await shot(cdp, '20_diecast_baskets.png', 'Plant floor: Die cast', 'Die cast baskets, cavity by cavity');

    await press(cdp, { text: 'Release', tag: 'button', nth: 0 }, 3000);
    await fillBox(cdp, { placeholder: 'e.g. 1600' }, '1180');
    await shot(cdp, '21_diecast_release.png', 'Plant floor: Die cast', 'Releasing a full basket');
    await press(cdp, { text: 'Cancel', tag: 'button' }, 2000);

    await press(cdp, { text: 'Downtime', tag: 'button' }, 3500);
    await shot(cdp, '30_downtime.png', 'Plant floor: Downtime', 'Downtime manager');

    await go(cdp, `${GW}/MPP/shop-floor/lot-search`);
    // The query box opens holding the literal text "null" (an unseeded
    // binding) -- replace it with a real search before the picture.
    await fillBox(cdp, { within: 'QUERY', withinUp: 2, tag: 'input' }, '6MA');
    await press(cdp, { text: 'Search', tag: 'button' }, 3000);
    await shot(cdp, '40_lot_search.png', 'Plant floor: Traceability', 'LOT search');
    const lotId = db.sql(`SELECT TOP 1 l.Id FROM Lots.Lot l JOIN Tools.Tool t ON t.Id=l.ToolId AND t.Code=N'${db.DIE}' ORDER BY l.Id`);
    if (lotId) {
      await go(cdp, `${GW}/MPP/shop-floor/lot-detail/${lotId.trim()}`);
      await press(cdp, { text: 'History', tag: 'div' }, 2500);
      await shot(cdp, '41_lot_detail.png', 'Plant floor: Traceability', 'LOT detail and history');
    }
    // Reports left out: on Dev the Reporting module is unlicensed and every
    // report carries a large trial watermark.
    await go(cdp, `${GW}/MPP/shop-floor/die-cast/supervisor`);
    await shot(cdp, '51_diecast_production.png', 'Plant floor: Reporting', 'Die cast production, this shift against the last');
  } finally {
    try { await cdp.send('Target.closeTarget', { targetId: cdp.targetId }); } catch { /* gone */ }
  }
}

// --------------------------------------------------------------- config ----
async function config() {
  const cdp = await attach(9334, { reuseExisting: true });
  await setViewport(cdp, 1920, 1080);
  const page = async (route) => go(cdp, `${GW}/MPP_Config${route}`, 7000);
  const tryPress = async (spec, ms = 2500) => {
    try { await press(cdp, spec, ms); return true; } catch (e) { console.log('  (skip) ' + e.message); return false; }
  };

  await page('/plant');
  await tryPress({ text: 'Die Cast 1', tag: 'div' }, 3000);
  await shot(cdp, '02_plant_hierarchy.png', 'Configuration: Plant model', 'Plant hierarchy');

  await page('/items');
  await tryPress({ text: '12232-6MA -0000', tag: 'div' }, 3500);
  await tryPress({ text: 'Routes', tag: 'div' }, 3000);
  await shot(cdp, '03_item_routes.png', 'Configuration: Parts', 'Item Master - routing');
  await tryPress({ text: '11200-5J6 -A110', tag: 'div' }, 3500);
  await tryPress({ text: 'Boms', tag: 'div' }, 3000);
  await shot(cdp, '04_item_bom.png', 'Configuration: Parts', 'Item Master - bill of materials');

  await page('/parts/operation-templates');
  await tryPress({ text: 'Die Cast Shot', tag: 'div' }, 3000);
  await shot(cdp, '05_operation_templates.png', 'Configuration: Parts', 'Operation templates');

  await page('/parts/tools');
  await tryPress({ text: 'DMO125', tag: 'div' }, 3500);
  await tryPress({ text: 'Cavities', tag: 'div' }, 3000);
  await shot(cdp, '06_tools.png', 'Configuration: Dies', 'Dies and cavities');

  await page('/defect-codes');
  await shot(cdp, '07_defect_codes.png', 'Configuration: Quality and downtime', 'Defect codes');
  await page('/downtime-codes');
  await shot(cdp, '08_downtime_codes.png', 'Configuration: Quality and downtime', 'Downtime codes');
  await page('/shifts');
  await shot(cdp, '09_shifts.png', 'Configuration: Shifts', 'Shift schedules');
  await page('/plc-devices');
  try {
    const { chooseFromDropdown } = await import('../training-deck/lib/measure.mjs');
    await chooseFromDropdown(cdp, { text: 'Select a terminal' }, 'MA2-6MACH');
  } catch (e) { console.log('  (skip) ' + e.message); }
  await shot(cdp, '10_plc_devices.png', 'Configuration: Machine integration', 'PLC devices');
}

if (!only || only === 'floor') await floor();
if (!only || only === 'config') await config();
process.exit(0);
