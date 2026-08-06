// One-shot extractor: parse MPP_MES_FDS.md into docs/fat/fds_index.csv (the FAT section spine).
// Captures each requirement's id, title, section, scope tag, and FRS crosswalk, then maps it to a
// FAT area sheet. Re-run when the FDS gains/renumbers requirements:  node docs/fat/extract_fds_index.js
// The generated area placement + scope are a best-effort PRE-POPULATION — every row is VERIFY-flagged.

const fs = require('fs');
const path = require('path');

const FDS = path.join(__dirname, '..', '..', 'MPP_MES_FDS.md');
const OUT = path.join(__dirname, 'fds_index.csv');

const lines = fs.readFileSync(FDS, 'utf8').split(/\r?\n/);

// Scope tag from a header suffix like  — `MVP-EXPANDED`  (also bare "MIXED SCOPE" -> null).
function scopeOf(text) {
  const m = text.match(/`(MVP-EXPANDED|MVP-LITE|MVP|CONDITIONAL|FUTURE)`/);
  return m ? m[1] : null;
}
const IN_SCOPE = { 'MVP': 'Y', 'MVP-EXPANDED': 'Y', 'MVP-LITE': 'Conditional', 'CONDITIONAL': 'Conditional', 'FUTURE': 'Out-of-scope' };

// Area placement. Keyed by subsection ("5.3"), then section ("5"), then per-id override.
const SECTION_AREA = {
  '1': 'environment', '2': 'plant-hierarchy', '3': 'item-master', '4': 'users',
  '5': 'traceability', '6': 'die-cast', '7': 'assembly', '8': 'quality-holds',
  '9': 'shift-downtime', '10': 'plc-mapping', '11': 'audit', '12': 'traceability',
  '13': 'labels', '14': '', '15': 'environment', '16': 'traceability',
};
const SUBSECTION_AREA = {
  '2.5': 'terminal-login',
  '3.1': 'item-master', '3.2': 'routes-boms', '3.3': 'routes-boms', '3.4': 'op-quality', '3.5': 'plant-hierarchy', '3.6': 'container-configs',
  '5.3': 'movements', '5.6': 'quality-holds', '5.8': 'labels',
  '6.2': 'die-cast', '6.3': 'trim', '6.4': 'machining', '6.5': 'assembly', '6.6': 'assembly', '6.7': 'die-cast', '6.8': 'die-cast', '6.9': 'assembly', '6.10': 'machining',
  '7.2': 'assembly', '7.3': 'labels', '7.4': 'labels', '7.5': 'movements', '7.6': 'quality-holds', '7.7': 'movements',
  '8.5': 'code-tables',
  '9.3': 'code-tables', '9.4': 'shift-schedules',
  '12.3': 'shift-downtime',
  '13.1': 'labels',
};
const ID_AREA = {
  'FDS-05-004': 'die-cast', 'FDS-05-034': 'die-cast', 'FDS-05-035': 'die-cast',
  'FDS-05-039': 'die-cast', 'FDS-05-040': 'die-cast', 'FDS-05-041': 'die-cast', 'FDS-05-042': 'die-cast',
  'FDS-05-007': 'movements', 'FDS-05-008': 'movements', 'FDS-05-038': 'movements',
  'FDS-05-009': 'machining', 'FDS-05-010': 'machining', 'FDS-05-011': 'machining', 'FDS-05-022': 'machining', 'FDS-05-033': 'machining',
  'FDS-05-019': 'labels', 'FDS-05-020': 'labels', 'FDS-05-024': 'labels', 'FDS-05-003': 'traceability',
  // --- verification-pass re-filings (2026-08-03) ---
  'FDS-05-005': 'inspection', 'FDS-05-006': 'inspection',                       // received / pass-through creation = Check-In tab
  'FDS-08-008': 'op-quality', 'FDS-08-009': 'op-quality', 'FDS-08-010': 'op-quality', // quality-spec authoring = Config Tool
  'FDS-06-028': 'assembly', 'FDS-06-029': 'assembly',                           // tray/container auto-finish = assembly
  'FDS-09-009': 'shift-downtime', 'FDS-09-010': 'shift-downtime', 'FDS-09-013': 'shift-downtime',
  'FDS-09-014': 'shift-downtime', 'FDS-09-015': 'shift-downtime',               // runtime shift ops = plant floor
  'FDS-10-008': 'labels',                                                       // Zebra printing
  'FDS-13-004': 'environment', 'FDS-13-005': 'environment', 'FDS-13-006': 'environment', // out-of-scope interface boundaries
  'FDS-14-001': 'environment', 'FDS-14-005': 'routes-boms',                     // seed data (deploy) / BOM import
  'FDS-05-036': 'traceability',                                                 // lazy operator-driven LOT creation = lifecycle principle
};
// Requirement-level scope corrections where the FDS header omits a tag and section inheritance is wrong.
const SCOPE_OVERRIDE = { 'FDS-14-001': 'MVP' };

function areaFor(id, section, subsection) {
  if (ID_AREA[id]) return ID_AREA[id];
  if (SUBSECTION_AREA[subsection]) return SUBSECTION_AREA[subsection];
  return SECTION_AREA[section] != null ? SECTION_AREA[section] : '';
}

function csv(v) {
  v = (v == null ? '' : String(v));
  return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
}

const out = [];
let curSection = '', curSectionScope = null, curSectionTitle = '';
let curSub = '', curSubScope = null, curSubTitle = '';
let pending = null; // requirement being accumulated (to scan body for FRS ref)

function flush() {
  if (!pending) return;
  const scope = SCOPE_OVERRIDE[pending.id] || pending.scope || curSubScope || curSectionScope || 'MVP';
  out.push([
    pending.id, pending.title, `${curSub} ${curSubTitle}`.trim(),
    areaFor(pending.id, curSection, curSub), scope, IN_SCOPE[scope] || 'Y',
    pending.frs || '', 'VERIFY',
  ]);
  pending = null;
}

for (const line of lines) {
  let m;
  if ((m = line.match(/^##\s+(\d+)\.\s+(.*)$/))) {
    flush();
    curSection = m[1]; curSectionTitle = m[2].replace(/\s*—.*$/, '').trim(); curSectionScope = scopeOf(line);
    curSub = ''; curSubScope = null; curSubTitle = '';
  } else if ((m = line.match(/^###\s+(\d+\.\d+)\s+(.*)$/))) {
    flush();
    curSub = m[1]; curSubTitle = m[2].replace(/\s*—.*$/, '').trim(); curSubScope = scopeOf(line);
  } else if ((m = line.match(/^####\s+(FDS-\d\d-\d\d\d)\s*[—-]\s*(.*)$/))) {
    flush();
    let rest = m[2];
    const sc = scopeOf(rest);
    const title = rest.replace(/\s*[—-]\s*`(MVP-EXPANDED|MVP-LITE|MVP|CONDITIONAL|FUTURE)`.*$/, '').replace(/`/g, '').trim();
    pending = { id: m[1], title, scope: sc, frs: '' };
  } else if (pending && !pending.frs) {
    const f = line.match(/\(FRS\s+([0-9., –-]+?)\)/);
    if (f) pending.frs = f[1].replace(/\s+/g, ' ').trim();
  }
}
flush();

// De-dupe (a requirement id can be re-cited; keep first full definition).
const seen = new Set();
const rows = out.filter((r) => (seen.has(r[0]) ? false : seen.add(r[0])));

const header = ['FDS', 'Title', 'Section', 'Area', 'Scope', 'InScope', 'FRS', 'Verify'];
fs.writeFileSync(OUT, [header, ...rows].map((r) => r.map(csv).join(',')).join('\n') + '\n', 'utf8');

const byArea = {};
for (const r of rows) byArea[r[3] || '(none)'] = (byArea[r[3] || '(none)'] || 0) + 1;
console.log(`Wrote ${path.relative(process.cwd(), OUT)} — ${rows.length} requirements`);
console.log('Per area:', JSON.stringify(byArea, null, 0));
const scopes = {};
for (const r of rows) scopes[r[5]] = (scopes[r[5]] || 0) + 1;
console.log('InScope:', JSON.stringify(scopes));
