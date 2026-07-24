// ============================================================
// Generator: gen_locations_mpp.js  (v2 - Site-reconciled, 2026-07-23)
// Emits:     011_seed_locations_mpp_plant.sql  (idempotent)
// Source:    _site_locations.tsv + _site_attributes.tsv  (dumped from MPP_MES_Site,
//            the authoritative onsite mapping). Spec:
//            docs/superpowers/specs/2026-07-23-location-model-reconciliation-design.md
//
// Rules baked in (all approved 2026-07-23):
//   - Names are authoritative (Site) - carried verbatim, ASCII-cleaned (double spaces).
//   - Role is derived from the NAME and realized as DefaultScreen. Codes are CORRECTED
//     to match the name-role (CODEMAP); names are never bent to codes.
//   - Printer child ONLY under MOUT / AOUT / COMBINED / ASER terminals (die-cast, trim,
//     MIN, AIN, fallback get none).
//   - Closure method normalized to enum (ByCount/ByWeight/ByVision); the 3 vision-through-
//     scale terminals override to ByVision.
//   - Adds: Trim Storage per shop; Inspection area (66B-TC re-parented in, sort-cage
//     inspection line, one 3-closure validation terminal).
// ============================================================
const fs = require('fs');
const path = require('path');
const DIR = __dirname;
const sq = s => String(s).replace(/'/g, "''");
const pad3 = n => String(n).padStart(3, '0');

const DEFID = { Organization:1, Facility:2, ProductionArea:3, SupportArea:4, ProductionLine:5,
  InspectionLine:6, Terminal:7, DieCastMachine:8, CNCMachine:9, TrimPress:10, AssemblyStation:11,
  SerializedAssemblyLine:12, InspectionStation:13, InventoryLocation:14, Scale:15, Printer:16 };

function tsv(f) {
  return fs.readFileSync(path.join(DIR, f), 'utf8').split(/\r?\n/).filter(x => x.trim())
    .map(l => l.split('\t'));
}
const locRows = tsv('_site_locations.tsv');   // [Id, Code, Name, Def, ParentCode, Sort, Deprecated]
const attrRows = tsv('_site_attributes.tsv');  // [LocCode, Name, Val]

// ---- code corrections: old Site code -> corrected code (unchanged codes pass through) ----
const CODEMAP = {
  'MA1-FP6NA-AFIN':'MA1-FP6NA-AOUT', 'MA1-FPRPY-AFIN':'MA1-FPRPY-AOUT',
  'MA2-6F9TC-MOUT':'MA2-6F9TC-AOUT', 'MA2-COS-MOUT':'MA2-COS-AOUT',
  'MA2-5PA-MIN1':'MA2-5PA-MIN', 'MA2-5PA-MIN2':'MA2-5PA-MOUT', 'MA2-5PA-MIN3':'MA2-5PA-AIN',
  '5PA - AO':'MA2-5PA-AOUT', 'MA2-RPY6B2-AFIN':'MA2-RPY6B2-AOUT',
  // RPYCAM1 re-key (off authoritative names)
  'MA2-RPYCAM1-MIN-A':'MA2-RPYCAM1-MIN-CH', 'MA2-RPYCAM1-MIN-B':'MA2-RPYCAM1-MIN-RS',
  'MA2-RPYCAM1-AIN':'MA2-RPYCAM1-MOUT-CH', 'MA2-RPYCAM1-MOUT-B':'MA2-RPYCAM1-MOUT-RS',
  'MA2-RPYCAM1-MOUT-A':'MA2-RPYCAM1-MIO-RS5',
  'MA2-RPYCAM1-AOUT1':'MA2-RPYCAM1-AIN', 'MA2-RPYCAM1-AOUT2':'MA2-RPYCAM1-AOUT1', 'MA2-RPYCAM1-AOUT3':'MA2-RPYCAM1-AOUT2',
  // RPYCAM2 re-key
  'MA2-RPYCAM2-MOUT-A':'MA2-RPYCAM2-MIN-CH', 'MA2-RPYCAM2-MIN-B':'MA2-RPYCAM2-MIN-RS',
  'MA2-RPYCAM2-MOUT-B':'MA2-RPYCAM2-MOUT-CH', 'RS-MO':'MA2-RPYCAM2-MOUT-RS',
  'MA2-RPYCAM2-MIN-A':'MA2-RPYCAM2-MIO-RS5',
};
const newCode = c => CODEMAP[c] || c;

// ---- parent re-parenting (66B Thermal Case moves under the new inspection area).
//      Applied as a post-insert UPDATE, because INSP is created after the Site loop. ----
const PARENTOVR = {};

// ---- name overrides (the single authorized name change) ----
const NAMEOVR = { 'MA2-RPY6B2-AFIN':'Assembly Out' };

// ---- rows to drop entirely ----
const seenCode = new Set();
function skip(r) {
  const [id, code, name, def, parent, sort, dep] = r;
  if (dep === '1') return true;                 // deprecated
  if (!code || !code.trim()) return true;       // stray "[add 10 printers]" placeholder
  if (def === 'Printer') return true;           // re-emit printers per rule, not Site's
  if (seenCode.has(code)) return true;          // duplicate (e.g. 66B-Ins appears twice)
  seenCode.add(code);
  return false;
}

const clean = s => s.replace(/\s+/g, ' ').trim();   // collapse double spaces

// ---- role from authoritative name; DefaultScreen from role ----
const SCREEN = { MIN:'/shop-floor/machining-in', MOUT:'/shop-floor/machining-out',
  AIN:'/shop-floor/assembly-in', AOUT:'/shop-floor/assembly-nonserialized',
  ASER:'/shop-floor/assembly-serialized', COMBINED:'/shop-floor/machining',
  INSPECT:'/shop-floor/third-party-inspection' };
function roleOf(name, code) {
  const n = clean(name).toLowerCase();
  if (/in\s*-\s*out/.test(n)) return 'COMBINED';
  if (/serial/.test(n)) return 'ASER';
  if (/machining\s+out/.test(n)) return 'MOUT';
  if (/machining\s+in/.test(n)) return 'MIN';
  if (/assembly\s+out/.test(n)) return 'AOUT';
  if (/assembly\s+in/.test(n)) return 'AIN';
  if (/^dc/i.test(code)) return 'DIECAST';
  if (/^trim/i.test(code)) return 'TRIM';
  if (/^insp/i.test(code) || /insp/i.test(n)) return 'INSPECT';
  if (code === 'FALLBACK-TERMINAL') return 'FALLBACK';
  return 'OTHER';
}
const printsFor = role => ['MOUT','AOUT','COMBINED','ASER'].includes(role);

// ---- closure normalization (+ vision-through-scale override by NEW code) ----
const CLOSURE_NORM = { 'weight':'ByWeight', 'vision':'ByVision', 'bycount':'ByCount' };
const VISION_SCALE = new Set(['MA1-FP6NA-AOUT','MA1-FPRPY-AOUT','MA2-5PA-AOUT']); // desc "vision through scale"
function normClosure(newC, raw) {
  if (VISION_SCALE.has(newC)) return 'ByVision';
  return CLOSURE_NORM[String(raw).toLowerCase()] || raw;
}

// ---- attribute lookup by old Site code ----
const attrByCode = {};
for (const [loc, name, val] of attrRows) {
  if (!loc || !loc.trim()) continue;
  (attrByCode[loc] = attrByCode[loc] || {})[name] = val;
}

// ---------------- emit ----------------
const out = [];
function loc(defId, parentCode, name, code, desc, sort) {
  const parent = parentCode === null ? 'NULL'
    : `(SELECT Id FROM Location.Location WHERE Code = N'${sq(parentCode)}')`;
  out.push(
`IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'${sq(code)}')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT ${defId}, ${parent}, N'${sq(name)}', N'${sq(code)}', N'${sq(desc)}', ${sort};`);
}
function attr(code, attrName, val) {
  out.push(
`IF NOT EXISTS (SELECT 1 FROM Location.LocationAttribute la JOIN Location.Location l ON l.Id = la.LocationId
        JOIN Location.LocationAttributeDefinition ad ON ad.Id = la.LocationAttributeDefinitionId
        WHERE l.Code = N'${sq(code)}' AND ad.AttributeName = N'${sq(attrName)}')
    INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
    SELECT (SELECT Id FROM Location.Location WHERE Code = N'${sq(code)}'),
           (SELECT TOP 1 Id FROM Location.LocationAttributeDefinition WHERE AttributeName = N'${sq(attrName)}' AND LocationTypeDefinitionId = 7 ORDER BY Id),
           N'${sq(val)}', SYSUTCDATETIME();`);
}

out.push(`-- ============================================================
-- Seed:        011_seed_locations_mpp_plant.sql   (GENERATED - edit gen_locations_mpp.js)
-- Description: Full MPP plant Location tree reconciled to MPP_MES_Site (authoritative).
--              Names authoritative; codes corrected to name-role; printers only on
--              OUT terminals; DefaultScreen/closure/scanner/confirm attributes seeded.
--              ASCII-only Names/Descriptions. Idempotent by Code.
-- ============================================================
SET NOCOUNT ON;

-- === LocationTypeDefinition: Printer (Cell-kind, DefId 16) =====
IF NOT EXISTS (SELECT 1 FROM Location.LocationTypeDefinition WHERE Code = N'Printer')
BEGIN
    SET IDENTITY_INSERT Location.LocationTypeDefinition ON;
    INSERT INTO Location.LocationTypeDefinition (Id, LocationTypeId, Code, Name) VALUES (16, 5, N'Printer', N'Printer');
    SET IDENTITY_INSERT Location.LocationTypeDefinition OFF;
END
IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint')
    INSERT INTO Location.LocationAttributeDefinition (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES (16, N'Endpoint', N'NVARCHAR', 1, NULL, NULL, 1, N'Zebra print target - IP:port or print-queue name');
IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Model')
    INSERT INTO Location.LocationAttributeDefinition (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES (16, N'Model', N'NVARCHAR', 0, NULL, NULL, 2, N'Printer model (informs label-template selection)');
`);

// ---- structure (from Site, transformed) ----
out.push('\n-- === Plant hierarchy (reconciled from Site) ===');
const terminals = [];  // {code, role, parentDef}
let printerSeq = 0;
const defByCode = {};
for (const r of locRows) defByCode[r[1]] = r[3];

for (const r of locRows) {
  if (skip(r)) continue;
  const [id, code0, name0, def, parent0, sort] = r;
  const code = newCode(code0);
  const name = clean(NAMEOVR[code0] || name0);
  const parent = parent0 ? (PARENTOVR[code0] || newCode(parent0)) : null;
  const desc = code;   // description not authoritative; keep terse (code) to avoid stale notes
  loc(DEFID[def], parent, name, code, desc, Number(sort) || 1);

  if (def === 'Terminal' || def === 'InspectionStation') {
    const role = (def === 'InspectionStation') ? 'INSPECT' : roleOf(name, code);
    const parentDef = defByCode[parent0] || '';
    terminals.push({ code, code0, role, parentDef });
    if (printsFor(role)) {
      printerSeq++;
      loc(DEFID.Printer, code, `P - ${pad3(printerSeq)}`, `${code}-P1`, `Label printer for ${code}`, 99);
    }
  }
}

// ---- exceptions: Trim Storage per shop + Inspection area ----
out.push('\n-- === Exception 1: Trim Storage (one per trim shop) ===');
loc(DEFID.InventoryLocation, 'TRIM1', 'Trim Storage', 'TRIM1-STORE', 'TRIM1-STORE', 99);
loc(DEFID.InventoryLocation, 'TRIM2', 'Trim Storage', 'TRIM2-STORE', 'TRIM2-STORE', 99);

out.push('\n-- === Exception 2: Inspection area (66B-TC re-parented here; sort-cage line; 3-closure terminal) ===');
loc(DEFID.ProductionArea, 'MPP-MAD', 'Inspection', 'INSP', 'INSP', 98);
loc(DEFID.InspectionLine, 'INSP', 'Sort Cage Inspection', 'INSP-SORT', 'INSP-SORT', 1);
loc(DEFID.Terminal, 'INSP-SORT', 'Inspection', 'INSP-SORT-T1', 'INSP-SORT-T1', 1);
terminals.push({ code: 'INSP-SORT-T1', code0: 'INSP-SORT-T1', role: 'INSPECT', parentDef: 'InspectionLine' });
// re-parent 66B Thermal Case under the inspection area (INSP now exists)
out.push(`UPDATE Location.Location SET ParentLocationId = (SELECT Id FROM Location.Location WHERE Code = N'INSP')
    WHERE Code = N'66B-TC' AND ParentLocationId <> (SELECT Id FROM Location.Location WHERE Code = N'INSP');`);
// NOTE: INSP-SORT-T1 supports all 3 closure methods (count/weight/vision) - capability of the
// inspection screen, not a single CurrentClosureMethod value. Inspection screen TBD (flag).

// ---- attributes ----
out.push('\n-- === DefaultScreen (derived from name-role) ===');
for (const t of terminals) {
  let screen = SCREEN[t.role];
  if (t.role === 'DIECAST') screen = t.parentDef === 'DieCastMachine' ? '/shop-floor/die-cast/dedicated' : '/shop-floor/die-cast';
  if (t.role === 'TRIM')    screen = t.parentDef === 'TrimPress'      ? '/shop-floor/trim/dedicated'      : '/shop-floor/trim';
  if (screen) attr(t.code, 'DefaultScreen', screen);
}

out.push('\n-- === Closure method (normalized enum; vision-through-scale -> ByVision) ===');
out.push('\n-- === HasBarcodeScanner / RequiresCompletionConfirm (Site-authoritative) ===');
for (const t of terminals) {
  const a = attrByCode[t.code0] || {};
  if (a.CurrentClosureMethod != null) attr(t.code, 'CurrentClosureMethod', normClosure(t.code, a.CurrentClosureMethod));
  if (a.HasBarcodeScanner != null)    attr(t.code, 'HasBarcodeScanner', a.HasBarcodeScanner);
  if (a.RequiresCompletionConfirm != null) attr(t.code, 'RequiresCompletionConfirm', a.RequiresCompletionConfirm);
}

const sqlPath = path.join(DIR, '011_seed_locations_mpp_plant.sql');
fs.writeFileSync(sqlPath, out.join('\n') + '\n', 'utf8');
const inserts = out.join('\n').split('IF NOT EXISTS').length - 1;
console.error(`Wrote ${sqlPath}: ${inserts} idempotent inserts, ${terminals.length} terminals, ${printerSeq} printers.`);

// ============================================================
// Companion: _reconcile_dev.sql - IN-PLACE transform of an EXISTING (old-model) DB
// (MPP_MES_Dev) to the reconciled model, preserving every Location.Id (so LOTs, PLC
// registrations, and FK refs stay attached). NOT wrapped in a transaction - the caller
// wraps BEGIN TRAN / ROLLBACK for a dry-run, or BEGIN TRAN / COMMIT to apply.
// Steps: (1) two-phase code rename (temp namespace avoids unique-Code collisions on the
// RPYCAM shuffle), (2) authoritative Name updates, (3) idempotent node adds + 66B reparent,
// (4) printer prune to the OUT-only keep set, (5) attribute reset+set (DefaultScreen/
// closure/scanner/confirm).
// ============================================================
const rc = [];
rc.push(`-- GENERATED by gen_locations_mpp.js - in-place Dev reconciliation. Wrap in your own BEGIN TRAN.
SET NOCOUNT ON; SET XACT_ABORT ON;`);

// (1) two-phase rename
rc.push('\n-- (1) two-phase code rename (old -> __T__old -> new)');
for (const [oldC, newC] of Object.entries(CODEMAP))
  rc.push(`UPDATE Location.Location SET Code = N'__T__${sq(oldC)}' WHERE Code = N'${sq(oldC)}';`);
for (const [oldC, newC] of Object.entries(CODEMAP))
  rc.push(`UPDATE Location.Location SET Code = N'${sq(newC)}' WHERE Code = N'__T__${sq(oldC)}';`);
// printer children of renamed terminals follow their parent's code (P1 child code re-derives on add below);
// old printer rows are pruned in step (4), fresh ones added in step (3).

// (2) authoritative names (every reconciled location)
rc.push('\n-- (2) authoritative Name updates');
for (const r of locRows) {
  if (r[6] === '1' || !r[1] || r[3] === 'Printer' || !r[1].trim()) continue;
  const code = newCode(r[1]); const name = clean(NAMEOVR[r[1]] || r[2]);
  rc.push(`UPDATE Location.Location SET Name = N'${sq(name)}' WHERE Code = N'${sq(code)}' AND Name <> N'${sq(name)}';`);
}

// (3a) Retire ALL existing printers into a dead __OLD__ namespace + deprecate them, BEFORE the
//      node-add. This frees every printer code so the fresh printers below re-parent to the
//      corrected terminals (the RPYCAM shuffle mis-parents a stale printer otherwise), while
//      keeping the rows so FK refs (Dev smoke data logs downtime against 2 printers) stay valid.
const keptPrinters = terminals.filter(t => printsFor(t.role)).map(t => `${t.code}-P1`);
rc.push('\n-- (3a) retire existing printers (rename to __OLD__ + deprecate) so fresh ones re-parent cleanly');
rc.push(`UPDATE Location.Location SET Code = N'__OLD__' + Code, DeprecatedAt = ISNULL(DeprecatedAt, SYSUTCDATETIME())
    WHERE LocationTypeDefinitionId = 16 AND Code NOT LIKE N'__OLD__%';`);

// (3b) idempotent node adds (new nodes: INSP, trim storage, 66B*, 6ma-CH-L2, AO-OP, new terminals)
//      + fresh printers for kept terminals + 66B reparent. Reuse the seed's INSERT/UPDATE block.
rc.push('\n-- (3b) add missing nodes + fresh printers + reparent (idempotent; existing codes skip)');
rc.push(out.filter(s => s.startsWith('IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code') || s.startsWith('UPDATE Location.Location SET ParentLocationId')).join('\n'));

// (5) attribute reset + set (authoritative). Clear the four managed attrs on every reconciled
//     terminal, then re-insert the target values (DefaultScreen from role; closure/scanner/confirm from Site).
rc.push('\n-- (5) reset + set managed attributes on reconciled terminals');
const managed = ['DefaultScreen','CurrentClosureMethod','HasBarcodeScanner','RequiresCompletionConfirm'];
const termCodes = terminals.map(t => `N'${sq(t.code)}'`).join(', ');
rc.push(`DELETE la FROM Location.LocationAttribute la
    JOIN Location.Location l ON l.Id = la.LocationId
    JOIN Location.LocationAttributeDefinition ad ON ad.Id = la.LocationAttributeDefinitionId
    WHERE l.Code IN (${termCodes}) AND ad.AttributeName IN (${managed.map(m => `N'${m}'`).join(', ')});`);
// re-emit the attr inserts (from the seed's attr block)
rc.push(out.filter(s => s.includes("INTO Location.LocationAttribute")).join('\n'));

// Written to sql/scripts/ (NOT sql/seeds/) so the DB reset does not auto-run this one-time
// in-place ops script against a fresh DB (it transforms an EXISTING old-model DB only).
const rcPath = path.join(DIR, '..', 'scripts', 'reconcile_location_dev.sql');
fs.writeFileSync(rcPath, rc.join('\n') + '\n', 'utf8');
console.error(`Wrote ${rcPath}: ${Object.keys(CODEMAP).length} renames, ${keptPrinters.length} kept printers.`);
