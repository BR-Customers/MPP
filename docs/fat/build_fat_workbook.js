// Builds docs/fat/MPP_MES_FAT.xlsx from the canonical CSVs, styled with ExcelJS.
//   - fds_index.csv         : the FDS requirement spine (section titles + scope + area placement + FRS crosswalk)
//   - areas/<slug>.csv      : per-area test rows (one witnessable step per row)
// The workbook is a REGENERATED derivative — never hand-edit the .xlsx. Edit the CSVs
// and re-run:  node docs/fat/build_fat_workbook.js
//
// The FAT measures the built system against the FDS (Blue Ridge's authored design spec).
// FRS clauses are carried as a SECONDARY crosswalk on each requirement's section banner.
//
// Output sheets:
//   Cover        : project / parties / environment-under-test / sign-off block + live roll-up
//   Coverage     : FDS requirement -> covering TestID(s); colour-coded flags; FRS crosswalk
//   <one per area>: test rows grouped into FDS-requirement section banners (+ Blue Ridge / Non-FDS)

const fs = require('fs');
const path = require('path');
const ExcelJS = require('exceljs');

const FAT_DIR = __dirname;
const AREAS_DIR = path.join(FAT_DIR, 'areas');
const INDEX_CSV = path.join(FAT_DIR, 'fds_index.csv');
const OUTPUT = path.join(FAT_DIR, 'MPP_MES_FAT.xlsx');

const SHEETS = [
  ['environment', 'Environment & Platform'],
  ['plant-hierarchy', 'Plant Hierarchy'],
  ['item-master', 'Item Master'],
  ['routes-boms', 'Routes & BOMs'],
  ['op-quality', 'Op Templates & Quality Specs'],
  ['container-configs', 'Container Configs'],
  ['code-tables', 'Code Tables'],
  ['shift-schedules', 'Shift Schedules'],
  ['plc-mapping', 'PLC Device Mapping'],
  ['users', 'Users & Attribution'],
  ['terminal-login', 'Terminal & Login'],
  ['die-cast', 'Die Cast'],
  ['trim', 'Trim'],
  ['machining', 'Machining'],
  ['assembly', 'Assembly'],
  ['inspection', 'Pass-Through Parts'],
  ['quality-holds', 'Quality Capture & Holds'],
  ['movements', 'Movements & Inventory'],
  ['traceability', 'LOT Traceability & Genealogy'],
  ['shift-downtime', 'Shift & Downtime'],
  ['labels', 'Labels & Printing'],
  ['audit', 'Audit Browser'],
];
const SHEET_NAME = new Map(SHEETS);
const COLS = ['TestID', 'Workflow', 'Precondition', 'Step', 'Expected Result', 'Result', 'Witness', 'Date', 'Notes'];
const WIDTHS = [14, 22, 30, 44, 44, 9, 10, 12, 34];
const NCOL = COLS.length;

// --- palette -----------------------------------------------------------------
const C = {
  header: '1F3A5F', headerText: 'FFFFFFFF',
  fdsBanner: '2E75B6', brBanner: '548235', warnBanner: 'C55A11',
  bannerText: 'FFFFFFFF',
  zebra: 'F5F8FC', placeholderFill: 'F2F2F2', placeholderText: 'FF808080',
  inputFill: 'FFF6D9', border: 'D9D9D9',
  covGreen: 'E2EFDA', covRed: 'FADBD8', covGrey: 'ECECEC', covAmber: 'FCE4B8',
  titleText: '1F3A5F',
};
const fill = (argb) => ({ type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF' + argb } });
const thin = { style: 'thin', color: { argb: 'FF' + C.border } };
const allBorders = { top: thin, left: thin, bottom: thin, right: thin };

// --- CSV parsing -------------------------------------------------------------
function parseCsv(text) {
  const rows = [];
  for (const line of text.split(/\r?\n/)) {
    if (line === '') continue;
    const f = []; let cur = '', q = false;
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (q) { if (c === '"') { if (line[i + 1] === '"') { cur += '"'; i++; } else q = false; } else cur += c; }
      else { if (c === '"') q = true; else if (c === ',') { f.push(cur); cur = ''; } else cur += c; }
    }
    f.push(cur); rows.push(f);
  }
  return rows;
}
function readCsvObjects(file) {
  const rows = parseCsv(fs.readFileSync(file, 'utf8'));
  if (!rows.length) return [];
  const h = rows[0].map((x) => x.trim());
  return rows.slice(1).map((r) => { const o = {}; h.forEach((k, i) => (o[k] = (r[i] || '').trim())); return o; });
}

// --- load data ---------------------------------------------------------------
const indexRows = readCsvObjects(INDEX_CSV);
const reqById = new Map();
const reqsByArea = new Map();
for (const c of indexRows) {
  if (!c.FDS) continue;
  reqById.set(c.FDS, c);
  const slug = c.Area || '';
  if (!reqsByArea.has(slug)) reqsByArea.set(slug, []);
  reqsByArea.get(slug).push(c);
}
const testsByArea = new Map();
const allTests = [];
if (fs.existsSync(AREAS_DIR)) {
  for (const [slug] of SHEETS) {
    const f = path.join(AREAS_DIR, slug + '.csv');
    if (!fs.existsSync(f)) continue;
    const rows = readCsvObjects(f).filter((r) => r.TestID);
    testsByArea.set(slug, rows);
    for (const r of rows) allTests.push({ ...r, __area: slug });
  }
}

// --- styling helpers ---------------------------------------------------------
function styleHeaderRow(ws, row) {
  row.height = 20;
  for (let i = 1; i <= NCOL; i++) {
    const cell = row.getCell(i);
    cell.fill = fill(C.header);
    cell.font = { bold: true, color: { argb: C.headerText }, size: 11 };
    cell.alignment = { vertical: 'middle', horizontal: i >= 6 && i <= 8 ? 'center' : 'left' };
    cell.border = allBorders;
  }
}
function bannerRow(ws, text, kind) {
  const row = ws.addRow([text]);
  ws.mergeCells(row.number, 1, row.number, NCOL);
  const cell = row.getCell(1);
  const bg = kind === 'br' ? C.brBanner : kind === 'warn' ? C.warnBanner : C.fdsBanner;
  cell.fill = fill(bg);
  cell.font = { bold: true, color: { argb: C.bannerText }, size: 11 };
  cell.alignment = { vertical: 'middle', horizontal: 'left', indent: 1 };
  row.height = 18;
  return row;
}
function placeholderRow(ws, text) {
  const row = ws.addRow([text]);
  ws.mergeCells(row.number, 1, row.number, NCOL);
  const cell = row.getCell(1);
  cell.fill = fill(C.placeholderFill);
  cell.font = { italic: true, color: { argb: C.placeholderText }, size: 10 };
  cell.alignment = { vertical: 'middle', horizontal: 'left', indent: 2 };
  row.height = 15;
}
// Approximate wrapped-row height so text shows fully on open (Excel auto-fit is unreliable from file).
function estimateHeight(vals) {
  let maxLines = 1;
  for (let i = 0; i < NCOL; i++) {
    const cpc = WIDTHS[i] - 2;               // chars per line ≈ column width
    if (cpc < 8) continue;                    // skip narrow input cols
    const s = (vals[i] || '').toString();
    // account for explicit line breaks + wrapping of each segment
    let lines = 0;
    for (const seg of s.split('\n')) lines += Math.max(1, Math.ceil(seg.length / cpc));
    if (lines > maxLines) maxLines = lines;
  }
  return Math.min(200, Math.max(16, maxLines * 12.6 + 4));
}
function dataRow(ws, t, zebra) {
  const vals = [t.TestID, t.Workflow, t.Precondition, t.Step, t['Expected Result'], t.Result, t.Witness, t.Date, t.Notes];
  const row = ws.addRow(vals);
  row.height = estimateHeight(vals);
  for (let i = 1; i <= NCOL; i++) {
    const cell = row.getCell(i);
    cell.border = allBorders;
    cell.alignment = { vertical: 'top', wrapText: true, horizontal: i >= 6 && i <= 8 ? 'center' : 'left' };
    cell.font = { size: 10 };
    if (i === 1) cell.font = { size: 10, bold: true, color: { argb: 'FF' + C.fdsBanner } };
    if (i >= 6 && i <= 8) cell.fill = fill(C.inputFill);           // Result / Witness / Date = fill-in
    else if (zebra) cell.fill = fill(C.zebra);
  }
  row.getCell(6).dataValidation = { type: 'list', allowBlank: true, formulae: ['"Pass,Fail,N/A"'] };
  return row;
}

// --- area sheets -------------------------------------------------------------
const areaRowCount = new Map();
// A test row's FDS field may name SEVERAL requirements, separated by ';' --
// one witnessable step can satisfy more than one FDS clause. Everything that
// files or counts a test goes through this, so a multi-FDS row appears under
// each banner it covers and is credited to each requirement on Coverage.
function fdsList(t) {
  if (!t || !t.FDS || t.FDS === 'NONE') return [];
  return String(t.FDS).split(';').map((x) => x.trim()).filter(Boolean);
}

function buildAreaSheet(wb, slug, name) {
  const tests = testsByArea.get(slug) || [];
  if (!tests.length && !reqsByArea.has(slug)) return;
  const ws = wb.addWorksheet(name.slice(0, 31), { views: [{ state: 'frozen', ySplit: 1 }] });
  ws.columns = WIDTHS.map((w) => ({ width: w }));
  styleHeaderRow(ws, ws.addRow(COLS));

  const byReq = new Map(); const none = []; const unfiled = [];
  const areaSet = new Set((reqsByArea.get(slug) || []).map((c) => c.FDS));
  for (const t of tests) {
    const ids = fdsList(t);
    if (!ids.length) { none.push(t); continue; }
    const mine = ids.filter((id) => areaSet.has(id));
    if (!mine.length) { unfiled.push(t); continue; }
    for (const id of mine) {
      if (!byReq.has(id)) byReq.set(id, []);
      byReq.get(id).push(t);
    }
  }
  let zebra = false;
  for (const c of reqsByArea.get(slug) || []) {
    const scope = c.InScope && c.InScope !== 'Y' ? `   [${c.Scope}]` : '';
    const frs = c.FRS ? `      (FRS ${c.FRS})` : '';
    bannerRow(ws, `${c.FDS}  —  ${c.Title}${frs}${scope}`, 'fds');
    zebra = false;
    const rows = byReq.get(c.FDS) || [];
    if (!rows.length) placeholderRow(ws, c.InScope === 'Out-of-scope' ? '   (out of scope — no test required)' : '   ⚠ no test steps authored yet');
    else for (const t of rows) { dataRow(ws, t, zebra); zebra = !zebra; }
  }
  if (none.length) { bannerRow(ws, 'Blue Ridge / Non-FDS', 'br'); zebra = false; for (const t of none) { dataRow(ws, t, zebra); zebra = !zebra; } }
  if (unfiled.length) { bannerRow(ws, '⚠ Unfiled — FDS requirement not indexed to this area', 'warn'); zebra = false; for (const t of unfiled) { dataRow(ws, t, zebra); zebra = !zebra; } }
  areaRowCount.set(name, tests.length);
}

// --- coverage sheet ----------------------------------------------------------
function buildCoverage(wb) {
  const ws = wb.addWorksheet('Coverage', { views: [{ state: 'frozen', ySplit: 1 }] });
  const heads = ['FDS', 'Title', 'Section', 'Area', 'Scope', 'FRS crosswalk', 'Covering TestIDs', 'Coverage'];
  const widths = [12, 46, 26, 24, 14, 16, 30, 15];
  ws.columns = widths.map((w) => ({ width: w }));
  const hr = ws.addRow(heads); hr.height = 20;
  for (let i = 1; i <= heads.length; i++) { const cell = hr.getCell(i); cell.fill = fill(C.header); cell.font = { bold: true, color: { argb: C.headerText } }; cell.alignment = { vertical: 'middle' }; cell.border = allBorders; }

  const byFds = new Map();
  for (const t of allTests) { for (const id of fdsList(t)) { if (!byFds.has(id)) byFds.set(id, []); byFds.get(id).push(t.TestID); } }
  let gaps = 0;
  for (const c of indexRows) {
    if (!c.FDS) continue;
    const ids = byFds.get(c.FDS) || [];
    let flag, bg;
    if (c.InScope === 'Out-of-scope') { flag = 'Out-of-scope'; bg = C.covGrey; }
    else if (ids.length) { flag = `Covered (${ids.length})`; bg = C.covGreen; }
    else if (c.InScope === 'Conditional') { flag = 'Conditional — no test'; bg = C.covAmber; }
    else { flag = '⚠ NO TEST'; bg = C.covRed; gaps++; }
    const idStr = ids.join(', ');
    const row = ws.addRow([c.FDS, c.Title, c.Section, SHEET_NAME.get(c.Area) || c.Area || '—', c.Scope, c.FRS, idStr, flag]);
    row.height = Math.min(160, Math.max(16, Math.max(Math.ceil((c.Title || '').length / 44), Math.ceil(idStr.length / 28)) * 12.6 + 4));
    for (let i = 1; i <= heads.length; i++) {
      const cell = row.getCell(i);
      cell.border = allBorders; cell.font = { size: 10 };
      cell.alignment = { vertical: 'top', wrapText: i === 2 || i === 7 };
      if (i === 1) cell.font = { size: 10, bold: true, color: { argb: 'FF' + C.fdsBanner } };
    }
    const fc = row.getCell(8); fc.fill = fill(bg); fc.font = { size: 10, bold: true };
  }
  return gaps;
}

// --- cover sheet -------------------------------------------------------------
function buildCover(wb, gaps) {
  const ws = wb.addWorksheet('Cover');
  ws.columns = [{ width: 30 }, { width: 16 }, { width: 16 }, { width: 14 }, { width: 10 }, { width: 10 }];
  const inY = indexRows.filter((c) => c.FDS && c.InScope === 'Y').length;
  const inC = indexRows.filter((c) => c.FDS && c.InScope === 'Conditional').length;
  const inO = indexRows.filter((c) => c.FDS && c.InScope === 'Out-of-scope').length;

  const title = ws.addRow(['MPP MES — Factory Acceptance Test (FAT)']);
  ws.mergeCells(title.number, 1, title.number, 6);
  title.getCell(1).font = { bold: true, size: 18, color: { argb: 'FF' + C.titleText } };
  title.height = 26;
  const sub = ws.addRow(['Madison Precision Products, Inc.  ·  Blue Ridge Automation']);
  ws.mergeCells(sub.number, 1, sub.number, 6);
  sub.getCell(1).font = { size: 11, italic: true, color: { argb: 'FF595959' } };
  ws.addRow([]);

  const kv = (label, value) => {
    const r = ws.addRow([label, value]);
    r.getCell(1).font = { bold: true, size: 10 };
    ws.mergeCells(r.number, 2, r.number, 6);
    r.getCell(2).font = { size: 10 };
    r.getCell(2).alignment = { wrapText: true, vertical: 'top' };
    return r;
  };
  const sectionLabel = (text) => {
    const r = ws.addRow([text]);
    ws.mergeCells(r.number, 1, r.number, 6);
    r.getCell(1).fill = fill(C.header); r.getCell(1).font = { bold: true, color: { argb: C.headerText } };
    r.height = 18; return r;
  };

  kv('Measured against', 'MPP MES Functional Design Specification (FDS) — FRS crosswalk shown per requirement');
  kv('Scope', 'Full MVP / MVP-EXPANDED — Config Tool (Arc 1) + Plant Floor (Arc 2)');
  kv('FDS requirements', `${inY} in-scope  ·  ${inC} conditional  ·  ${inO} out-of-scope  (see Coverage sheet)`);
  kv('Total test steps', String(allTests.length));
  kv('In-scope requirements with no test', String(gaps));
  ws.addRow([]);

  sectionLabel('ENVIRONMENT UNDER TEST   (fill in at witnessing)');
  for (const l of ['Ignition Gateway version', 'SQL Server / database', 'Git commit / build tag', 'Test date(s)']) {
    const r = ws.addRow([l, '']);
    r.getCell(1).font = { size: 10 };
    ws.mergeCells(r.number, 2, r.number, 6);
    r.getCell(2).fill = fill(C.inputFill); r.getCell(2).border = allBorders;
  }
  ws.addRow([]);

  sectionLabel('SIGN-OFF');
  const soHead = ws.addRow(['Role', 'Name', '', 'Signature', 'Date', '']);
  ws.mergeCells(soHead.number, 2, soHead.number, 3); ws.mergeCells(soHead.number, 5, soHead.number, 6);
  for (const i of [1, 2, 4, 5]) { soHead.getCell(i).font = { bold: true, size: 10 }; soHead.getCell(i).fill = fill(C.zebra); soHead.getCell(i).border = allBorders; }
  soHead.getCell(3).border = allBorders; soHead.getCell(6).border = allBorders;
  for (const role of ['MPP — Acceptance', 'MPP — Quality', 'Blue Ridge — Lead']) {
    const r = ws.addRow([role, '', '', '', '', '']);
    ws.mergeCells(r.number, 2, r.number, 3); ws.mergeCells(r.number, 5, r.number, 6);
    r.height = 24;
    for (let i = 1; i <= 6; i++) r.getCell(i).border = allBorders;
    r.getCell(1).font = { size: 10, bold: true };
  }
  ws.addRow([]);

  sectionLabel('ROLL-UP  (live — updates as Result cells are filled)');
  const ruHead = ws.addRow(['Area', 'Total', 'Pass', 'Fail', 'N/A', 'Open']);
  for (let i = 1; i <= 6; i++) { ruHead.getCell(i).font = { bold: true, size: 10 }; ruHead.getCell(i).fill = fill(C.zebra); ruHead.getCell(i).border = allBorders; }
  for (const [, name] of SHEETS) {
    if (!areaRowCount.has(name)) continue;
    const r = ws.addRow([name, areaRowCount.get(name), null, null, null, null]);
    const sref = `'${name.slice(0, 31)}'!F:F`;
    r.getCell(3).value = { formula: `COUNTIF(${sref},"Pass")` };
    r.getCell(4).value = { formula: `COUNTIF(${sref},"Fail")` };
    r.getCell(5).value = { formula: `COUNTIF(${sref},"N/A")` };
    r.getCell(6).value = { formula: `B${r.number}-C${r.number}-D${r.number}-E${r.number}` };
    for (let i = 1; i <= 6; i++) { r.getCell(i).border = allBorders; r.getCell(i).font = { size: 10 }; r.getCell(i).alignment = { horizontal: i === 1 ? 'left' : 'center' }; }
    r.getCell(1).font = { size: 10, bold: true };
  }
}

// --- assemble ----------------------------------------------------------------
async function main() {
  const wb = new ExcelJS.Workbook();
  wb.creator = 'MPP FAT builder'; wb.created = new Date(0);
  // Build order: Coverage first, then area sheets (populate areaRowCount), then Cover (needs the counts).
  const coverageGaps = buildCoverage(wb);
  for (const [slug, name] of SHEETS) buildAreaSheet(wb, slug, name);
  buildCover(wb, coverageGaps);
  // Reorder tabs: Cover, Coverage, then the areas in SHEETS order.
  const present = new Set(wb.worksheets.map((w) => w.name));
  const desired = ['Cover', 'Coverage', ...SHEETS.map(([, n]) => n.slice(0, 31)).filter((n) => present.has(n))];
  desired.forEach((nm, i) => { const w = wb.getWorksheet(nm); if (w) w.orderNo = i + 1; });

  await wb.xlsx.writeFile(OUTPUT);
  console.log(`Wrote ${path.relative(process.cwd(), OUTPUT)}`);
  console.log(`  ${allTests.length} test steps · ${indexRows.filter((c) => c.FDS && c.InScope === 'Y').length} in-scope FDS reqs · ${coverageGaps} in-scope req(s) with no test`);
}
main().catch((e) => { console.error(e); process.exit(1); });
