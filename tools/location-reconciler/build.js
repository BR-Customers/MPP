/* ============================================================================
   build.js — Location Reconciler generator
   ----------------------------------------------------------------------------
   Reads the legacy MES extract CSVs, the EMMD automation TSVs, and the
   authoritative Location seed (011), then emits a single self-contained
   location-reconciler.html with all data inlined (no external deps, opens
   offline in any browser).

   Run:  node tools/location-reconciler/build.js
   ============================================================================ */
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const HERE = __dirname;
const EX = path.join(ROOT, "reference", "legacy_mes_extract");
const AUT = path.join(EX, "emmd_automation");
const SEED = path.join(ROOT, "sql", "seeds", "011_seed_locations_mpp_plant.sql");

const read = p => fs.readFileSync(p, "utf8");

// ---- delimited parsing (handles quoted fields with commas) ----------------
function parseDelimited(text, delim) {
  const rows = [];
  const lines = text.replace(/^﻿/, "").split(/\r?\n/).filter(l => l.length);
  for (const line of lines) {
    const cells = []; let cur = "", q = false;
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (q) {
        if (c === '"' && line[i + 1] === '"') { cur += '"'; i++; }
        else if (c === '"') q = false;
        else cur += c;
      } else {
        if (c === '"') q = true;
        else if (c === delim) { cells.push(cur); cur = ""; }
        else cur += c;
      }
    }
    cells.push(cur); rows.push(cells);
  }
  const headers = rows.shift();
  return rows.map(r => Object.fromEntries(headers.map((h, i) => [h, r[i] === undefined ? "" : r[i]])));
}
const csv = p => parseDelimited(read(p), ",");
const tsv = p => parseDelimited(read(p), "\t");
const nz = v => (v === "NULL" || v === undefined ? "" : v);

// ---- LocationTypeDefinition catalog (id -> code/name/tier) -----------------
const DEFS = [
  [1, 1, "Organization"], [2, 2, "Facility"], [3, 3, "ProductionArea"], [4, 3, "SupportArea"],
  [5, 4, "ProductionLine"], [6, 4, "InspectionLine"], [7, 5, "Terminal"], [8, 5, "DieCastMachine"],
  [9, 5, "CNCMachine"], [10, 5, "TrimPress"], [11, 5, "AssemblyStation"], [12, 5, "SerializedAssemblyLine"],
  [13, 5, "InspectionStation"], [14, 5, "InventoryLocation"], [15, 5, "Scale"], [16, 5, "Printer"]
].map(([id, tier, code]) => ({ id, tier, code, name: code.replace(/([a-z])([A-Z])/g, "$1 $2") }));

// ---- legacy location tree (+ enrichment) ----------------------------------
const DNU = /DO NOT USE|DNU|TEMP|TBD|TODO|\bTEST\b/i;
const locRows = csv(path.join(EX, "locations.csv"));

// workcell material routing, grouped by WorkCell name
const wcm = csv(path.join(EX, "workcell_material.csv"));
const matByCell = {};
for (const r of wcm) {
  if (nz(r.IsDeleted) === "1") continue;
  (matByCell[r.WorkCell] = matByCell[r.WorkCell] || []).push({
    material: r.Material, cp: nz(r.IsConsumptionPoint) === "1", fg: nz(r.IsFinishedGood) === "1"
  });
}

const legacy = locRows.map(r => {
  const tierName = r.TierName;
  const key = tierName + ":" + r.Id;
  const parentKey = nz(r.ParentTier) && nz(r.ParentId) ? r.ParentTier + ":" + r.ParentId : null;
  const extra = nz(r.Extra);
  const machine = extra.startsWith("Machine=") ? extra.slice(8).trim() : "";
  return {
    key, tier: parseInt(r.Tier, 10), tierName, id: r.Id, name: r.Name, parentKey,
    machine, dnu: DNU.test(r.Name) || (machine && DNU.test(machine)),
    materials: tierName === "WorkCell" ? (matByCell[r.Name] || []) : []
  };
});

// ---- new tree (parse seed 011) --------------------------------------------
const seedText = read(SEED);
const INS = /SELECT\s+(\d+),\s*(?:NULL|\(SELECT Id FROM Location\.Location WHERE Code = N'([^']+)'\))\s*,\s*N'((?:[^']|'')*)'\s*,\s*N'((?:[^']|'')*)'\s*,\s*N'((?:[^']|'')*)'\s*,\s*(\d+)\s*;/g;
const newSeed = []; let m;
while ((m = INS.exec(seedText)) !== null) {
  const defId = parseInt(m[1], 10);
  if (defId === 16 && /LocationAttributeDefinition/.test(seedText.slice(m.index - 120, m.index))) continue; // safety; attr inserts don't match anyway
  newSeed.push({
    defId, parentCode: m[2] || null,
    name: m[3].replace(/''/g, "'"), code: m[4].replace(/''/g, "'"),
    description: m[5].replace(/''/g, "'"), sortOrder: parseInt(m[6], 10),
    attributes: {}, deviceRefs: [], legacySourceIds: []
  });
}

// ---- device catalog (EMMD) ------------------------------------------------
const rollup = tsv(path.join(AUT, "device_rollup.tsv"));
const manifest = csv(path.join(AUT, "integration_manifest.csv"));
const servers = tsv(path.join(AUT, "opc_servers.tsv")).map(s => ({ name: s.ServerName, pid: s.ServerPid }));
const manByBase = {};
for (const r of manifest) manByBase[r.LegacyBasePath] = r;
const devices = rollup.map(r => {
  const man = manByBase[r.BasePath] || {};
  return {
    code: man.DeviceCode || r.BasePath,
    type: man.DeviceType || "",
    line: man.Line || "",
    server: r.ServerName,
    basePath: r.BasePath,
    members: (r.Members || "").split(",").map(s => s.trim()).filter(Boolean),
    migration: man.MigrationStrategy || "",
    notes: man.Notes || ""
  };
});

// ---- assemble + emit ------------------------------------------------------
const DATA = {
  defs: DEFS, legacy, newSeed, devices, servers,
  meta: {
    generatedAt: new Date().toISOString().slice(0, 19).replace("T", " ") + " UTC",
    sources: {
      legacyLocations: "reference/legacy_mes_extract/locations.csv",
      workcellMaterial: "reference/legacy_mes_extract/workcell_material.csv",
      deviceRollup: "reference/legacy_mes_extract/emmd_automation/device_rollup.tsv",
      integrationManifest: "reference/legacy_mes_extract/emmd_automation/integration_manifest.csv",
      seed: "sql/seeds/011_seed_locations_mpp_plant.sql"
    }
  }
};

const css = read(path.join(HERE, "src", "styles.css"));
const app = read(path.join(HERE, "src", "app.js"));
const json = JSON.stringify(DATA).replace(/</g, "\\u003c");

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MPP Location Reconciler</title>
<style>${css}</style>
</head>
<body>
<header>
  <h1>MPP Location Reconciler</h1>
  <span class="sub">legacy&nbsp;⟷&nbsp;new seed &nbsp;·&nbsp; generated <span id="genAt"></span></span>
  <span class="spacer"></span>
  <button id="btnCatalog">Device catalog</button>
  <button id="btnImport">Import</button>
  <button id="btnReset" class="danger">Reset to seed</button>
  <button id="btnExport" class="primary">Export JSON</button>
</header>
<div class="main">
  <div class="col legacy">
    <div class="col-head"><h2>Legacy (MES)</h2><span class="count" id="legacyCount"></span><span class="spacer" style="flex:1"></span><label class="hidechk"><input type="checkbox" id="legacyHideChecked"> hide checked</label><button id="legacyCollapse" class="mini">Collapse all</button><input class="search" id="legacySearch" placeholder="search legacy…"></div>
    <div class="tree" id="legacyTree"></div>
    <div class="legend">Read-only. Struck-through = DO NOT USE / TEMP / TBD. Badges: ⌘ host · N mat (workcell materials) · N dev (matched OPC devices).</div>
  </div>
  <div class="col">
    <div class="col-head"><h2>New seed (011 — editable)</h2><span class="count" id="newCount"></span><span class="spacer" style="flex:1"></span><button id="newCollapse" class="mini">Collapse all</button><input class="search" id="newSearch" placeholder="search new…"></div>
    <div class="tools">
      <button id="btnAdd">+ Child</button>
      <button id="btnDel" class="danger">Delete</button>
      <button id="btnUp">↑</button>
      <button id="btnDown">↓</button>
      <button id="btnPull" class="primary">← Pull from legacy</button>
    </div>
    <div class="tree" id="newTree"></div>
    <div class="legend">Edits auto-save to your browser (localStorage). “Pull from legacy”: select a legacy node (left) + a new parent, then click. Re-parent via the Parent picker in the detail panel.</div>
  </div>
  <div class="col">
    <div class="col-head"><h2>Detail &amp; enrichment</h2></div>
    <div class="detail" id="detail"></div>
  </div>
</div>
<div class="modal-bg" id="modalBg">
  <div class="modal">
    <div class="modal-head"><h3 id="modalTitle"></h3><span class="spacer" style="flex:1"></span><button id="modalClose">×</button></div>
    <div class="modal-body" id="modalBody"></div>
    <div class="modal-foot" id="modalFoot"></div>
  </div>
</div>
<div class="toast" id="toast"></div>
<script>window.DATA = ${json};</script>
<script>${app}</script>
</body>
</html>`;

const out = path.join(HERE, "location-reconciler.html");
fs.writeFileSync(out, html, "utf8");
console.log("Wrote " + out);
console.log("  legacy nodes : " + legacy.length + "  (workstations w/ host: " + legacy.filter(n => n.machine).length + ")");
console.log("  new seed     : " + newSeed.length + " nodes");
console.log("  devices      : " + devices.length);
console.log("  defs         : " + DEFS.length);
