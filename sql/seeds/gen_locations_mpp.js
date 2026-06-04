// ============================================================
// Generator: gen_locations_mpp.js
// Emits:     011_seed_locations_mpp_plant.sql  (idempotent)
// Source:    MPP_LOCATION_SEED_TREE.md (validated 2026-06-04)
// Why a generator: ~190 Location rows + a Printer under every
//   terminal; regenerate as the remaining open items firm up
//   (⚠5 tablets, ⚠6 multi-printer, ⚠7 storage granularity).
//
// LocationTypeDefinition Ids (from migration 0002):
//   3 ProductionArea · 4 SupportArea · 5 ProductionLine(WorkCenter)
//   7 Terminal · 8 DieCastMachine · 16 Printer (NEW — created here)
// ============================================================
const fs = require('fs');
const path = require('path');

const DEF = { AREA: 3, SUPPORT: 4, WC: 5, TERM: 7, DCM: 8, PRINTER: 16 };
const out = [];
const sq = s => String(s).replace(/'/g, "''");           // escape single quotes
const pad2 = n => String(n).padStart(2, '0');

function loc(defId, parentCode, name, code, desc, sort) {
  const parent = parentCode === null
    ? 'NULL'
    : `(SELECT Id FROM Location.Location WHERE Code = N'${sq(parentCode)}')`;
  out.push(
`IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'${sq(code)}')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT ${defId}, ${parent}, N'${sq(name)}', N'${sq(code)}', N'${sq(desc)}', ${sort};`);
}
// every terminal gets exactly one Printer child (uniform model, FDS-10-008)
function terminalWithPrinter(parentWcCode, name, code, desc, sort) {
  loc(DEF.TERM, parentWcCode, name, code, desc, sort);
  loc(DEF.PRINTER, code, `${name} — Printer`, `${code}-P1`, `Label printer for ${code}`, 1);
}

// role-code → display name
const ROLE = {
  'MIN':'Machining IN','MOUT':'Machining OUT','AIN':'Assembly IN','AOUT':'Assembly OUT',
  'AFIN':'Assembly Finished','ASER':'Assembly (Serialized)',
  'MIN-A':'Machining IN — Side A','MIN-B':'Machining IN — Side B',
  'MOUT-A':'Machining OUT — Side A','MOUT-B':'Machining OUT — Side B',
  'MIN1':'Machining IN 1','MIN2':'Machining IN 2','MIN3':'Machining IN 3',
  'AOUT1':'Assembly OUT 1','AOUT2':'Assembly OUT 2','AOUT3':'Assembly OUT 3',
};

// ---- header ----
out.push(`-- ============================================================
-- Seed:        011_seed_locations_mpp_plant.sql   (GENERATED — edit gen_locations_mpp.js)
-- Description: Full MPP plant Location tree (reconciled from the two
--              plant-layout-mapper exports). Supersedes the 10-row sample
--              010_seed_locations.sql for real-plant work. Idempotent by Code.
-- ============================================================
SET NOCOUNT ON;

-- === NEW LocationTypeDefinition: Printer (Cell-kind, DefId 16) =====
IF NOT EXISTS (SELECT 1 FROM Location.LocationTypeDefinition WHERE Code = N'Printer')
BEGIN
    SET IDENTITY_INSERT Location.LocationTypeDefinition ON;
    INSERT INTO Location.LocationTypeDefinition (Id, LocationTypeId, Code, Name) VALUES (16, 5, N'Printer', N'Printer');
    SET IDENTITY_INSERT Location.LocationTypeDefinition OFF;
END
IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint')
    INSERT INTO Location.LocationAttributeDefinition (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES (16, N'Endpoint', N'NVARCHAR', 1, NULL, NULL, 1, N'Zebra print target — IP:port or print-queue name');
IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Model')
    INSERT INTO Location.LocationAttributeDefinition (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES (16, N'Model', N'NVARCHAR', 0, NULL, NULL, 2, N'Printer model (informs label-template selection)');
`);

// ---- Enterprise + Site (reuse if 010 already ran) ----
out.push('\n-- === Enterprise + Site =======================================');
loc(1, null, 'Madison Precision Products', 'MPP-ENT', 'Enterprise root', 1);
loc(2, 'MPP-ENT', 'Madison Facility', 'MPP-MAD', 'Main manufacturing facility, Madison IN', 1);

// ---- Die Cast areas: machines + pair terminals ----
const dieCast = [['DC1','Die Cast 1',11],['DC2','Die Cast 2',3],['DC3','Die Cast 3',5],['DC4','Die Cast 4',3]];
let areaSort = 1;
for (const [code, name, n] of dieCast) {
  out.push(`\n-- === ${name} (${n} machines, pair terminals) ===`);
  loc(DEF.AREA, 'MPP-MAD', name, code, `Die casting area — ${n} machines`, areaSort++);
  for (let i = 1; i <= n; i++) loc(DEF.DCM, code, `${name} Machine ${pad2(i)}`, `${code}-M${pad2(i)}`, `Die cast machine`, i);
  let t = 1;
  for (let m = 1; m <= n; m += 2, t++) {
    const m2 = m + 1 <= n ? m + 1 : null;
    const served = m2 ? `M${pad2(m)}, M${pad2(m2)}` : `M${pad2(m)}`;
    terminalWithPrinter(code, `${name} Terminal ${pad2(t)}`, `${code}-T${pad2(t)}`,
      `Shared terminal — serves ${served}`, t);
  }
}

// ---- Trim Shops (one area-level terminal each) ----
for (const [code, name] of [['TRIM1','Trim Shop 1'],['TRIM2','Trim Shop 2']]) {
  out.push(`\n-- === ${name} ===`);
  loc(DEF.AREA, 'MPP-MAD', name, code, 'Trim shop — area-level processing, no sublot split', areaSort++);
  terminalWithPrinter(code, `${name} Terminal`, `${code}-T1`, 'Area-level trim terminal', 1);
}

// ---- Machining & Assembly rooms ----
const MA1 = [
  ['MA1-COMPBR','Comp bracket',['MIN','AOUT']],
  ['MA1-6MD','6MD',['MIN','AOUT']],
  ['MA1-FPRPY','Fuel Pump (RPY 66v)',['MIN','MOUT','AFIN']],
  ['MA1-FP6NA','Fuel Pump (6na 6vj)',['MIN','MOUT','AFIN']],
  ['MA1-5GOR','5GO Rear',['MIN','MOUT','ASER']],
  ['MA1-5GOF','5GO Front',['MIN','MOUT','ASER']],
];
const CAM8 = ['MIN-A','MIN-B','MOUT-A','MOUT-B','AIN','AOUT1','AOUT2','AOUT3'];
const MA2 = [
  ['MA2-RPY6B2','RPY 6b2 line2',['MIN','MOUT','AIN','AFIN']],
  ['MA2-RPYCAM2','RPY Line 2 Cam holders',CAM8],
  ['MA2-RPYCAM1','RPY Line 1 CH',CAM8],
  ['MA2-5PA','5PA Fuel Pump',['MIN1','MIN2','MIN3']],
  ['MA2-6MAOP','6ma oil pan',['MIN','AOUT']],
  ['MA2-V6OP','v6 oil pan',['MIN','AOUT']],
  ['MA2-COS','COS (offsite-origin)',['MOUT']],
  ['MA2-6F9TC','6F9-TC (offsite-origin)',['MOUT']],
  ['MA2-59B','59b Cam holder',['MIN','AOUT1','AOUT2']],
  ['MA2-6FBCHOP','6FB CH/OP',['MIN','AOUT']],
  ['MA2-64AOP','64A Oil Pan',['MIN','AOUT']],
  ['MA2-6MACH','6MA CH',['MIN','AOUT1','AOUT2','AOUT3']],
];
for (const [areaCode, areaName, wcs] of [['MA1','Machining & Assembly 1',MA1],['MA2','Machining & Assembly 2',MA2]]) {
  out.push(`\n-- === ${areaName} ===`);
  loc(DEF.AREA, 'MPP-MAD', areaName, areaCode, 'Machining & Assembly room', areaSort++);
  let wcSort = 1;
  for (const [wcCode, wcName, roles] of wcs) {
    loc(DEF.WC, areaCode, wcName, wcCode, `Line — ${wcName}`, wcSort++);
    let tSort = 1;
    for (const r of roles) {
      terminalWithPrinter(wcCode, `${wcName} — ${ROLE[r]}`, `${wcCode}-${r}`, ROLE[r], tSort++);
    }
  }
}

// ---- Storage areas (SupportArea) ----
out.push('\n-- === Storage ===');
for (const [code, name, desc] of [
  ['WHSE','Warehouse','WIP / cast storage — all die cast goes here prior to Trim'],
  ['SHIPIN','Shipping IN','Receiving dock — pass-through parts'],
  ['SHIPOUT','Shipping OUT','Finished-goods staging']]) {
  loc(DEF.SUPPORT, 'MPP-MAD', name, code, desc, areaSort++);
}

const sqlPath = path.join(__dirname, '011_seed_locations_mpp_plant.sql');
fs.writeFileSync(sqlPath, out.join('\n') + '\n', 'utf8');
console.error(`Wrote ${sqlPath} — ${out.join('\n').split('IF NOT EXISTS').length - 1} idempotent inserts.`);
