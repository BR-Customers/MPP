/* ============================================================================
   Location Reconciler — client app
   window.DATA is injected by build.js. Shapes:
     DATA.defs      [{id, code, name, tier}]
     DATA.legacy    [{key, tier, tierName, id, name, parentKey, machine, materials:[{material,cp,fg}], dnu}]
     DATA.newSeed   [{code, name, defId, parentCode, sortOrder, description, attributes:{}, deviceRefs:[], legacySourceIds:[]}]
     DATA.devices   [{code, type, line, server, basePath, members:[], migration, notes}]
     DATA.servers   [{name, pid}]
     DATA.meta      {generatedAt, sources:{...}}
   ============================================================================ */
(function () {
  "use strict";
  const D = window.DATA;
  const LS_KEY = "mpp_reconciler_newtree_v1";
  const LS_NOTES = "mpp_reconciler_legacynotes_v1";
  const LS_CHECKED = "mpp_reconciler_legacychecked_v1";
  const $ = (s, r) => (r || document).querySelector(s);
  const el = (t, c, txt) => { const e = document.createElement(t); if (c) e.className = c; if (txt != null) e.textContent = txt; return e; };
  const defById = Object.fromEntries(D.defs.map(d => [d.id, d]));
  const defByCode = Object.fromEntries(D.defs.map(d => [d.code, d]));

  // ---- working state -------------------------------------------------------
  let newTree = loadNewTree();          // flat array (mutable working copy)
  let selNew = null;                    // selected new-tree code
  let selLegacy = null;                 // selected legacy key
  const collapsedNew = new Set();
  const collapsedLegacy = new Set();
  let legacyNotes = loadLegacyNotes();  // { legacyKey: "note text" }
  const checkedLegacy = new Set(loadChecked()); // legacy keys the user has "checked off"

  function loadNewTree() {
    try { const s = localStorage.getItem(LS_KEY); if (s) return JSON.parse(s); } catch (e) {}
    return clone(D.newSeed);
  }
  function loadLegacyNotes() {
    try { const s = localStorage.getItem(LS_NOTES); if (s) return JSON.parse(s); } catch (e) {}
    return {};
  }
  function loadChecked() {
    try { const s = localStorage.getItem(LS_CHECKED); if (s) return JSON.parse(s); } catch (e) {}
    return [];
  }
  function clone(x) { return JSON.parse(JSON.stringify(x)); }
  function persist() { try { localStorage.setItem(LS_KEY, JSON.stringify(newTree)); } catch (e) {} }
  function persistNotes() { try { localStorage.setItem(LS_NOTES, JSON.stringify(legacyNotes)); } catch (e) {} }
  function persistChecked() { try { localStorage.setItem(LS_CHECKED, JSON.stringify(Array.from(checkedLegacy))); } catch (e) {} }

  // A textarea that saves without re-rendering (keeps focus while typing).
  function notesField(getVal, setVal) {
    const wrap = el("div", "field");
    const lbl = el("label", null, "Notes");
    const saved = el("span", "notes-saved", "");
    lbl.appendChild(saved); wrap.appendChild(lbl);
    const ta = el("textarea", "notes"); ta.value = getVal() || ""; ta.placeholder = "Jot notes here — saved automatically, included in the export.";
    let t;
    ta.addEventListener("input", () => { setVal(ta.value); saved.textContent = "saved ✓"; clearTimeout(t); t = setTimeout(() => saved.textContent = "", 1200); });
    wrap.appendChild(ta); return wrap;
  }

  // ---- indexes -------------------------------------------------------------
  const legacyByKey = Object.fromEntries(D.legacy.map(n => [n.key, n]));
  function legacyChildren(key) { return D.legacy.filter(n => n.parentKey === key); }
  function legacyRoots() { return D.legacy.filter(n => !n.parentKey || !legacyByKey[n.parentKey]); }
  function legacyAncestry(node) { const a = []; let c = node; while (c) { a.push(c); c = c.parentKey ? legacyByKey[c.parentKey] : null; } return a; }

  function newByCode(code) { return newTree.find(n => n.code === code); }
  function newChildren(code) { return newTree.filter(n => n.parentCode === code).sort((a, b) => a.sortOrder - b.sortOrder); }
  function newRoots() { return newTree.filter(n => !n.parentCode).sort((a, b) => a.sortOrder - b.sortOrder); }
  function descendants(code) { const out = []; (function rec(c) { newChildren(c).forEach(k => { out.push(k); rec(k.code); }); })(code); return out; }

  // ---- token matching (legacy node <-> device) -----------------------------
  const PROG = /\b\d[A-Z0-9]{2}\b/g;
  const KW = ["FUEL PUMP", "CAM HOLDER", "CAMHOLDER", "OIL PAN", "OILPAN", "ROCKER", "COMPRESSOR", "BRACKET", "ASSEMBLY", "MACHINING", "SORT", "TOTE", "SCALE", "FRONT", "REAR", "SIDE COVER"];
  function tokens(str) {
    const u = (str || "").toUpperCase();
    const t = new Set();
    (u.match(PROG) || []).forEach(x => t.add("P:" + x));
    KW.forEach(k => { if (u.includes(k)) t.add("K:" + k.replace(/\s/g, "")); });
    return t;
  }
  function legacyTokens(node) {
    const strs = legacyAncestry(node).map(n => n.name);
    const t = new Set(); strs.forEach(s => tokens(s).forEach(x => t.add(x))); return t;
  }
  const deviceTokens = D.devices.map(d => ({ d, t: tokens(d.line + " " + d.code) }));
  function matchDevices(node) {
    const lt = legacyTokens(node);
    const scored = deviceTokens.map(({ d, t }) => {
      let score = 0;
      t.forEach(x => { if (lt.has(x)) score += x.startsWith("P:") ? 10 : 3; });
      return { d, score };
    }).filter(x => x.score > 0).sort((a, b) => b.score - a.score);
    return scored;
  }

  // ---- rendering: trees ----------------------------------------------------
  function render() { renderLegacy(); renderNew(); renderDetail(); updateCounts(); updateCollapseLabels(); }

  function updateCounts() {
    $("#legacyCount").textContent = D.legacy.length + " nodes" + (checkedLegacy.size ? " · " + checkedLegacy.size + " checked" : "");
    $("#newCount").textContent = newTree.length + " nodes";
  }

  function nodeRow(opts) {
    const { hasKids, collapsed, onToggle, onSelect, selected, cls } = opts;
    const row = el("div", "node" + (selected ? " selected" : "") + (cls ? " " + cls : ""));
    const tw = el("span", "tw", hasKids ? (collapsed ? "▸" : "▾") : "·");
    tw.addEventListener("click", e => { e.stopPropagation(); onToggle && onToggle(); });
    row.appendChild(tw);
    row.addEventListener("click", onSelect);
    return { row, addName(text) { const n = el("span", "name", text); row.appendChild(n); return n; }, add(node) { row.appendChild(node); } };
  }

  function renderLegacy() {
    const filter = $("#legacySearch").value.trim().toUpperCase();
    const hideChecked = $("#legacyHideChecked").checked;
    const host = $("#legacyTree"); host.innerHTML = "";
    const matchSet = filter ? computeFilterLegacy(filter) : null;
    function walk(node, depth, ancestorChecked) {
      const own = checkedLegacy.has(node.key);
      const greyed = own || ancestorChecked;
      if (hideChecked && greyed) return;               // decluttered away
      if (matchSet && !matchSet.has(node.key)) return;
      const kids = legacyChildren(node.key);
      const collapsed = collapsedLegacy.has(node.key) && !filter;
      const { row, addName } = nodeRow({
        hasKids: kids.length > 0, collapsed,
        selected: selLegacy === node.key,
        cls: (node.dnu ? "dnu " : "") + (greyed ? "checked" : ""),
        onToggle: () => { toggle(collapsedLegacy, node.key); renderLegacy(); },
        onSelect: () => { selLegacy = node.key; render(); }
      });
      row.style.paddingLeft = (6 + depth * 15) + "px";
      const chk = document.createElement("input");
      chk.type = "checkbox"; chk.className = "chk"; chk.checked = own;
      chk.title = "Check off (grey out this node and its children)";
      chk.addEventListener("click", e => e.stopPropagation());
      chk.addEventListener("change", () => { toggle(checkedLegacy, node.key); persistChecked(); renderLegacy(); updateCounts(); });
      row.appendChild(chk);
      addName(node.name);
      row.appendChild(el("span", "kind", node.tierName));
      if (node.machine) row.appendChild(el("span", "badge host", "⌘ " + node.machine));
      if (node.materials && node.materials.length) row.appendChild(el("span", "badge mat", node.materials.length + " mat"));
      const dm = matchDevicesCache(node);
      if (dm.length) row.appendChild(el("span", "badge dev", dm.length + " dev"));
      host.appendChild(row);
      if (!collapsed) kids.forEach(k => walk(k, depth + 1, greyed));
    }
    legacyRoots().forEach(r => walk(r, 0, false));
    if (!host.children.length) host.appendChild(el("div", "empty", "No matches."));
  }
  const _mdCache = {};
  function matchDevicesCache(node) { if (!(node.key in _mdCache)) _mdCache[node.key] = matchDevices(node); return _mdCache[node.key]; }

  function computeFilterLegacy(f) {
    const keep = new Set();
    D.legacy.forEach(n => {
      if ((n.name || "").toUpperCase().includes(f) || (n.machine || "").toUpperCase().includes(f)) {
        legacyAncestry(n).forEach(a => keep.add(a.key));
        // also keep descendants of a direct hit
        descendantsLegacy(n.key).forEach(d => keep.add(d.key));
      }
    });
    return keep;
  }
  function descendantsLegacy(key) { const out = []; (function rec(k) { legacyChildren(k).forEach(c => { out.push(c); rec(c.key); }); })(key); return out; }

  function renderNew() {
    const filter = $("#newSearch").value.trim().toUpperCase();
    const host = $("#newTree"); host.innerHTML = "";
    const matchSet = filter ? computeFilterNew(filter) : null;
    function walk(node, depth) {
      if (matchSet && !matchSet.has(node.code)) return;
      const kids = newChildren(node.code);
      const collapsed = collapsedNew.has(node.code) && !filter;
      const def = defById[node.defId];
      const { row, addName } = nodeRow({
        hasKids: kids.length > 0, collapsed,
        selected: selNew === node.code,
        onToggle: () => { toggle(collapsedNew, node.code); renderNew(); },
        onSelect: () => { selNew = node.code; render(); }
      });
      row.style.paddingLeft = (6 + depth * 15) + "px";
      addName(node.name);
      row.appendChild(el("span", "kind", def ? def.name : ("def" + node.defId)));
      row.appendChild(el("span", "code", node.code));
      if (node.deviceRefs && node.deviceRefs.length) row.appendChild(el("span", "badge dev", node.deviceRefs.length + " dev"));
      if (node.legacySourceIds && node.legacySourceIds.length) row.appendChild(el("span", "badge host", "↩ legacy"));
      host.appendChild(row);
      if (!collapsed) kids.forEach(k => walk(k, depth + 1));
    }
    newRoots().forEach(r => walk(r, 0));
    if (!host.children.length) host.appendChild(el("div", "empty", "No nodes."));
  }
  function computeFilterNew(f) {
    const keep = new Set();
    newTree.forEach(n => {
      if ((n.name || "").toUpperCase().includes(f) || (n.code || "").toUpperCase().includes(f)) {
        let c = n; while (c) { keep.add(c.code); c = c.parentCode ? newByCode(c.parentCode) : null; }
        descendants(n.code).forEach(d => keep.add(d.code));
      }
    });
    return keep;
  }
  function toggle(set, k) { set.has(k) ? set.delete(k) : set.add(k); }

  function legacyParents() { return D.legacy.filter(n => legacyChildren(n.key).length).map(n => n.key); }
  function newParents() { return newTree.filter(n => newChildren(n.code).length).map(n => n.code); }
  function collapseAll(which) {
    const isLegacy = which === "legacy";
    const set = isLegacy ? collapsedLegacy : collapsedNew;
    const parents = isLegacy ? legacyParents() : newParents();
    const allCollapsed = parents.length && parents.every(k => set.has(k));
    if (allCollapsed) set.clear(); else parents.forEach(k => set.add(k));
    updateCollapseLabels();
    isLegacy ? renderLegacy() : renderNew();
  }
  function updateCollapseLabels() {
    const lp = legacyParents(), np = newParents();
    $("#legacyCollapse").textContent = (lp.length && lp.every(k => collapsedLegacy.has(k))) ? "Expand all" : "Collapse all";
    $("#newCollapse").textContent = (np.length && np.every(k => collapsedNew.has(k))) ? "Expand all" : "Collapse all";
  }

  // ---- detail panel --------------------------------------------------------
  function renderDetail() {
    const host = $("#detail"); host.innerHTML = "";
    // -- selected NEW node editor --
    if (selNew) {
      const node = newByCode(selNew);
      if (!node) { selNew = null; }
      else { renderNewEditor(host, node); }
    }
    // -- selected LEGACY node info --
    if (selLegacy) {
      const lnode = legacyByKey[selLegacy];
      if (lnode) renderLegacyInfo(host, lnode);
    }
    if (!selNew && !selLegacy) host.appendChild(el("div", "empty", "Select a node on either side to inspect it. Select a legacy node to see its device/host enrichment; select a new node to edit it."));
  }

  function renderNewEditor(host, node) {
    host.appendChild(el("h3", null, "Edit · new node"));
    const mk = (labelText, value, key, opts) => {
      const f = el("div", "field"); f.appendChild(el("label", null, labelText));
      let input;
      if (opts && opts.select) {
        input = el("select");
        opts.select.forEach(o => { const op = el("option", null, o.label); op.value = o.value; if (String(o.value) === String(value)) op.selected = true; input.appendChild(op); });
      } else { input = el("input"); input.value = value == null ? "" : value; }
      input.addEventListener("change", () => { opts && opts.onChange ? opts.onChange(input.value) : (node[key] = input.value); commit(); });
      f.appendChild(input); return f;
    };
    const r2 = el("div", "row2");
    r2.appendChild(mk("Name", node.name, "name"));
    r2.appendChild(mk("Code", node.code, "code", { onChange: v => renameCode(node, v) }));
    host.appendChild(r2);
    host.appendChild(mk("Kind (LocationTypeDefinition)", node.defId, "defId", {
      select: D.defs.map(d => ({ label: `${d.name}  (tier ${d.tier})`, value: d.id })),
      onChange: v => { node.defId = parseInt(v, 10); }
    }));
    // parent picker
    const parentOpts = [{ label: "— (root)", value: "" }].concat(
      newTree.filter(n => n.code !== node.code && !descendants(node.code).some(d => d.code === n.code))
        .map(n => ({ label: `${n.name}  [${n.code}]`, value: n.code })));
    host.appendChild(mk("Parent", node.parentCode || "", "parentCode", {
      select: parentOpts, onChange: v => { node.parentCode = v || null; }
    }));
    const r3 = el("div", "row2");
    r3.appendChild(mk("Sort order", node.sortOrder, "sortOrder", { onChange: v => { node.sortOrder = parseInt(v, 10) || 0; } }));
    host.appendChild(r3);
    host.appendChild(mk("Description", node.description, "description"));

    // attributes (free-form key/value; printer Endpoint/Model, terminal role, host)
    host.appendChild(el("h3", null, "Attributes"));
    node.attributes = node.attributes || {};
    const suggested = suggestedAttrs(node.defId);
    const attrKeys = Array.from(new Set(Object.keys(node.attributes).concat(suggested)));
    attrKeys.forEach(k => {
      const f = el("div", "field"); f.appendChild(el("label", null, k));
      const input = el("input"); input.value = node.attributes[k] == null ? "" : node.attributes[k];
      input.placeholder = suggested.includes(k) ? "(suggested)" : "";
      input.addEventListener("change", () => { if (input.value === "") delete node.attributes[k]; else node.attributes[k] = input.value; commit(); });
      f.appendChild(input); host.appendChild(f);
    });
    const addAttr = el("button", null, "+ attribute");
    addAttr.addEventListener("click", () => { const k = prompt("Attribute name:"); if (k) { node.attributes[k] = ""; commit(); } });
    host.appendChild(addAttr);

    // device refs
    host.appendChild(el("h3", null, "Attached devices / OPC"));
    if (!node.deviceRefs || !node.deviceRefs.length) host.appendChild(el("div", "muted", "None. Select a legacy node below or search the catalog, then “Attach”."));
    else {
      const wrap = el("div");
      node.deviceRefs.forEach(dc => {
        const chip = el("span", "chip", dc);
        const x = el("button", null, "×"); x.title = "detach";
        x.addEventListener("click", () => { node.deviceRefs = node.deviceRefs.filter(d => d !== dc); commit(); });
        chip.appendChild(x); wrap.appendChild(chip);
      });
      host.appendChild(wrap);
    }
    // legacy source
    if (node.legacySourceIds && node.legacySourceIds.length) {
      host.appendChild(el("h3", null, "Legacy source"));
      const wrap = el("div");
      node.legacySourceIds.forEach(k => wrap.appendChild(el("span", "chip", (legacyByKey[k] ? legacyByKey[k].name + " " : "") + "[" + k + "]")));
      host.appendChild(wrap);
    }
    // notes (per new node; exported)
    host.appendChild(el("h3", null, "Notes"));
    host.appendChild(notesField(() => node.notes, v => { if (v) node.notes = v; else delete node.notes; persist(); }));
  }

  function suggestedAttrs(defId) {
    const code = defById[defId] && defById[defId].code;
    if (code === "Printer") return ["Endpoint", "Model"];
    if (code === "Terminal") return ["Role", "Host"];
    if (code === "DieCastMachine") return ["Host"];
    return [];
  }

  function renderLegacyInfo(host, node) {
    host.appendChild(el("h3", null, "Legacy · " + node.tierName));
    const kv = el("div", "kv");
    const put = (k, v) => { kv.appendChild(el("div", "k", k)); kv.appendChild(el("div", "v", v == null || v === "" ? "—" : String(v))); };
    put("Name", node.name);
    put("Legacy id", node.tierName + " #" + node.id);
    put("Path", legacyAncestry(node).reverse().map(n => n.name).join("  ›  "));
    if (node.machine) put("Machine host", node.machine);
    host.appendChild(kv);

    if (node.materials && node.materials.length) {
      host.appendChild(el("h3", null, "WorkCell materials (routing)"));
      const wrap = el("div");
      node.materials.forEach(m => {
        const chip = el("span", "chip", (m.cp ? "▼ consume " : "▲ produce ") + m.material + (m.fg ? " (FG)" : ""));
        wrap.appendChild(chip);
      });
      host.appendChild(wrap);
    }

    const dm = matchDevicesCache(node);
    host.appendChild(el("h3", null, "Matched devices (heuristic)  ·  " + dm.length));
    if (!dm.length) host.appendChild(el("div", "muted", "No token match. Use the catalog search below."));
    dm.slice(0, 8).forEach(({ d, score }) => host.appendChild(deviceCard(d, score)));

    const b = el("button", null, "Search full device catalog …");
    b.addEventListener("click", openCatalog);
    host.appendChild(b);

    // notes (per legacy node; kept separately, included in export as legacyNotes)
    host.appendChild(el("h3", null, "Notes"));
    host.appendChild(notesField(() => legacyNotes[node.key], v => { if (v) legacyNotes[node.key] = v; else delete legacyNotes[node.key]; persistNotes(); }));
  }

  function deviceCard(d, score) {
    const c = el("div", "devcard");
    const h = el("div", "dc-h");
    h.appendChild(el("span", "t", d.code));
    if (score != null) h.appendChild(el("span", "score", "score " + score));
    c.appendChild(h);
    c.appendChild(el("div", "dc-type", d.type + "  ·  " + d.server + "  ·  " + d.line));
    if (d.members && d.members.length) c.appendChild(el("div", "members", d.members.join(", ")));
    if (d.migration) c.appendChild(el("div", "notes", d.migration));
    if (d.notes) c.appendChild(el("div", "notes", d.notes));
    const att = el("button", null, selNew ? ("Attach to " + selNew) : "Select a new node to attach");
    att.disabled = !selNew;
    att.addEventListener("click", () => {
      const n = newByCode(selNew); if (!n) return;
      n.deviceRefs = n.deviceRefs || []; if (!n.deviceRefs.includes(d.code)) n.deviceRefs.push(d.code);
      commit(); toast("Attached " + d.code + " → " + selNew);
    });
    c.appendChild(att);
    return c;
  }

  // ---- edit operations -----------------------------------------------------
  function commit() { persist(); render(); }
  function renameCode(node, newCodeRaw) {
    const nc = newCodeRaw.trim(); if (!nc || nc === node.code) return;
    if (newByCode(nc)) { alert("Code already exists: " + nc); render(); return; }
    const old = node.code;
    newTree.forEach(n => { if (n.parentCode === old) n.parentCode = nc; });
    node.code = nc; if (selNew === old) selNew = nc;
  }
  function addChild() {
    const parent = selNew ? newByCode(selNew) : null;
    const parentCode = parent ? parent.code : null;
    let i = 1, code; do { code = (parentCode || "NEW") + "-N" + i++; } while (newByCode(code));
    const sibs = newChildren(parentCode || null);
    const node = { code, name: "New node", defId: parent ? defaultChildDef(parent.defId) : 3, parentCode, sortOrder: (sibs.length ? Math.max(...sibs.map(s => s.sortOrder)) : 0) + 1, description: "", attributes: {}, deviceRefs: [], legacySourceIds: [] };
    newTree.push(node); selNew = code; if (parentCode) collapsedNew.delete(parentCode); commit();
  }
  function defaultChildDef(parentDef) {
    const t = defById[parentDef] ? defById[parentDef].tier : 2;
    if (t <= 2) return 3;   // -> ProductionArea
    if (t === 3) return 5;  // -> ProductionLine
    return 7;               // -> Terminal
  }
  function delNode() {
    if (!selNew) return; const node = newByCode(selNew); if (!node) return;
    const kids = descendants(node.code);
    if (!confirm(`Delete "${node.name}" [${node.code}]` + (kids.length ? ` and its ${kids.length} descendant(s)?` : "?"))) return;
    const kill = new Set([node.code, ...kids.map(k => k.code)]);
    newTree = newTree.filter(n => !kill.has(n.code)); selNew = node.parentCode || null; commit();
  }
  function moveSib(dir) {
    if (!selNew) return; const node = newByCode(selNew); if (!node) return;
    const sibs = newChildren(node.parentCode || null);
    const i = sibs.findIndex(s => s.code === node.code); const j = i + dir;
    if (j < 0 || j >= sibs.length) return;
    const a = sibs[i].sortOrder, b = sibs[j].sortOrder; sibs[i].sortOrder = b; sibs[j].sortOrder = a; commit();
  }
  function pullFromLegacy() {
    if (!selLegacy) { alert("Select a legacy node (left) first."); return; }
    const l = legacyByKey[selLegacy]; if (!l) return;
    const parent = selNew ? newByCode(selNew) : null;
    const parentCode = parent ? parent.code : null;
    let base = suggestCode(l), code = base, i = 2; while (newByCode(code)) code = base + "-" + i++;
    const sibs = newChildren(parentCode || null);
    const node = {
      code, name: l.name, defId: parent ? defaultChildDef(parent.defId) : mapLegacyDef(l),
      parentCode, sortOrder: (sibs.length ? Math.max(...sibs.map(s => s.sortOrder)) : 0) + 1,
      description: "From legacy " + l.tierName + " #" + l.id, attributes: l.machine ? { Host: l.machine } : {},
      deviceRefs: matchDevicesCache(l).slice(0, 1).map(x => x.d.code), legacySourceIds: [l.key]
    };
    newTree.push(node); selNew = code; if (parentCode) collapsedNew.delete(parentCode); commit();
    toast("Pulled “" + l.name + "” into new tree" + (parentCode ? " under " + parentCode : " (root)"));
  }
  function mapLegacyDef(l) { return ({ Site: 2, Area: 3, ProductionLine: 5, WorkCell: 5, Workstation: 7 })[l.tierName] || 7; }
  function suggestCode(l) {
    const prog = (l.name.toUpperCase().match(PROG) || [])[0] || "X";
    let role = "T"; const u = l.name.toUpperCase();
    if (/\bIN\b/.test(u) || u.includes("MACHINING IN")) role = "MIN";
    else if (/\bOUT\b/.test(u)) role = "MOUT";
    else if (u.includes("ASSEMBLY")) role = "AOUT";
    return "L-" + prog + "-" + role;
  }

  // ---- export / import -----------------------------------------------------
  function buildNested() {
    function shape(n) {
      const o = { code: n.code, name: n.name, kind: defById[n.defId] ? defById[n.defId].code : n.defId, defId: n.defId, sortOrder: n.sortOrder };
      if (n.description) o.description = n.description;
      if (n.attributes && Object.keys(n.attributes).length) o.attributes = n.attributes;
      if (n.deviceRefs && n.deviceRefs.length) o.deviceRefs = n.deviceRefs;
      if (n.legacySourceIds && n.legacySourceIds.length) o.legacySourceIds = n.legacySourceIds;
      if (n.notes) o.notes = n.notes;
      const kids = newChildren(n.code).map(shape);
      if (kids.length) o.children = kids;
      return o;
    }
    const out = { generatedBy: "location-reconciler", basisSeed: "011_seed_locations_mpp_plant.sql", tree: newRoots().map(shape) };
    // legacy-node notes, resolved with a name for readability
    const ln = {};
    Object.keys(legacyNotes).forEach(k => { if (legacyNotes[k]) ln[k] = { name: legacyByKey[k] ? legacyByKey[k].name : null, note: legacyNotes[k] }; });
    if (Object.keys(ln).length) out.legacyNotes = ln;
    if (checkedLegacy.size) out.legacyChecked = Array.from(checkedLegacy).map(k => ({ key: k, name: legacyByKey[k] ? legacyByKey[k].name : null }));
    return out;
  }
  function openExport() {
    $("#modalTitle").textContent = "Export new tree (JSON)";
    const body = $("#modalBody"); body.innerHTML = "";
    const ta = el("textarea", "json"); ta.value = JSON.stringify(buildNested(), null, 2); ta.readOnly = true;
    body.appendChild(ta);
    setFoot([
      { label: "Copy to clipboard", primary: true, fn: () => { ta.select(); navigator.clipboard && navigator.clipboard.writeText(ta.value); toast("Copied JSON"); } },
      { label: "Download .json", fn: () => download("location_reconciled.json", ta.value) },
      { label: "Close", fn: closeModal }
    ]);
    showModal();
  }
  function openImport() {
    $("#modalTitle").textContent = "Import / replace new tree (paste JSON)";
    const body = $("#modalBody"); body.innerHTML = "";
    const info = el("div", "muted"); info.textContent = "Paste a previously-exported nested tree OR a flat array. This replaces your current working tree.";
    const ta = el("textarea", "json"); ta.placeholder = "{ \"tree\": [ ... ] }";
    body.appendChild(info); body.appendChild(ta);
    setFoot([
      { label: "Replace tree", primary: true, fn: () => { try { importJson(JSON.parse(ta.value)); closeModal(); toast("Imported"); } catch (e) { alert("Invalid JSON: " + e.message); } } },
      { label: "Cancel", fn: closeModal }
    ]);
    showModal();
  }
  function importJson(obj) {
    const flat = [];
    if (Array.isArray(obj)) { // flat array already
      obj.forEach(n => flat.push(normalizeFlat(n)));
    } else if (obj.tree) {
      (function rec(arr, parentCode) { arr.forEach(n => { flat.push(normalizeFlat(n, parentCode)); if (n.children) rec(n.children, n.code); }); })(obj.tree, null);
    } else throw new Error("Expected {tree:[...]} or a flat array");
    if (obj.legacyNotes && !Array.isArray(obj)) {
      Object.keys(obj.legacyNotes).forEach(k => { const v = obj.legacyNotes[k]; legacyNotes[k] = typeof v === "string" ? v : (v && v.note) || ""; });
      persistNotes();
    }
    if (obj.legacyChecked && !Array.isArray(obj)) {
      obj.legacyChecked.forEach(x => checkedLegacy.add(typeof x === "string" ? x : x.key));
      persistChecked();
    }
    newTree = flat; selNew = null; commit();
  }
  function normalizeFlat(n, parentCode) {
    const o = {
      code: n.code, name: n.name,
      defId: n.defId != null ? n.defId : (defByCode[n.kind] ? defByCode[n.kind].id : 7),
      parentCode: n.parentCode !== undefined ? n.parentCode : (parentCode || null),
      sortOrder: n.sortOrder || 0, description: n.description || "",
      attributes: n.attributes || {}, deviceRefs: n.deviceRefs || [], legacySourceIds: n.legacySourceIds || []
    };
    if (n.notes) o.notes = n.notes;
    return o;
  }
  function openCatalog() {
    $("#modalTitle").textContent = "Device / OPC catalog  (" + D.devices.length + " devices)";
    const body = $("#modalBody"); body.innerHTML = "";
    const s = el("input"); s.placeholder = "Filter by code / line / type / member …";
    body.appendChild(s);
    const list = el("div"); body.appendChild(list);
    function draw() {
      const f = s.value.trim().toUpperCase(); list.innerHTML = "";
      D.devices.filter(d => !f || (d.code + " " + d.line + " " + d.type + " " + (d.members || []).join(" ")).toUpperCase().includes(f))
        .forEach(d => list.appendChild(deviceCard(d, null)));
      if (!list.children.length) list.appendChild(el("div", "muted", "No devices match."));
    }
    s.addEventListener("input", draw); draw();
    setFoot([{ label: "Close", fn: closeModal }]);
    showModal();
  }

  function resetTree() { if (confirm("Discard all edits and reset the new tree to the seed (011)?")) { newTree = clone(D.newSeed); selNew = null; commit(); } }

  // ---- modal / toast helpers ----------------------------------------------
  function showModal() { $("#modalBg").classList.add("show"); }
  function closeModal() { $("#modalBg").classList.remove("show"); }
  function setFoot(btns) {
    const f = $("#modalFoot"); f.innerHTML = "";
    btns.forEach(b => { const btn = el("button", b.primary ? "primary" : null, b.label); btn.addEventListener("click", b.fn); f.appendChild(btn); });
  }
  let toastT;
  function toast(msg) { const t = $("#toast"); t.textContent = msg; t.classList.add("show"); clearTimeout(toastT); toastT = setTimeout(() => t.classList.remove("show"), 1800); }
  function download(name, text) { const a = el("a"); a.href = URL.createObjectURL(new Blob([text], { type: "application/json" })); a.download = name; a.click(); }

  // ---- wire up -------------------------------------------------------------
  $("#legacySearch").addEventListener("input", renderLegacy);
  $("#newSearch").addEventListener("input", renderNew);
  $("#legacyCollapse").addEventListener("click", () => collapseAll("legacy"));
  $("#newCollapse").addEventListener("click", () => collapseAll("new"));
  $("#legacyHideChecked").addEventListener("change", renderLegacy);
  $("#btnAdd").addEventListener("click", addChild);
  $("#btnDel").addEventListener("click", delNode);
  $("#btnUp").addEventListener("click", () => moveSib(-1));
  $("#btnDown").addEventListener("click", () => moveSib(1));
  $("#btnPull").addEventListener("click", pullFromLegacy);
  $("#btnExport").addEventListener("click", openExport);
  $("#btnImport").addEventListener("click", openImport);
  $("#btnReset").addEventListener("click", resetTree);
  $("#btnCatalog").addEventListener("click", openCatalog);
  $("#modalClose").addEventListener("click", closeModal);
  $("#modalBg").addEventListener("click", e => { if (e.target === $("#modalBg")) closeModal(); });
  $("#genAt").textContent = D.meta.generatedAt;

  render();
})();
