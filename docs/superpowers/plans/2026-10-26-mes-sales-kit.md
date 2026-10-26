# MES Track & Trace Sales Kit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a menu-driven presenter deck and a single-file interactive demo that sell the MES's track & trace capabilities through a fictional casting + assembly sample plant, with the core and modules 1-3 complete.

**Architecture:** The demo is authored as small plain-JS source files (config, a pure domain model, a simulation tick, one UI file per module) that a build script concatenates into one HTML template and inlines with the logo; the domain model is unit-tested in Node. The deck is a pptxgenjs generator that captures its screenshots from the demo's `?scene=` hooks and is checked by a python-pptx test script. A term checker kept inside the MPP repo greps every shareable file for MPP terms.

**Tech Stack:** Vanilla JS (ES2020, no framework) + Node 24 `node:test`; Python 3.14 (`python-pptx`, `pillow`, `numpy`); pptxgenjs + the pptx skill's `apply_theme.js` / `validate.py`; headless Microsoft Edge (captures); PowerPoint COM (render).

**Spec:** `docs/superpowers/specs/2026-10-22-mes-sales-kit-design.md` (read it first; sections are cited below as "spec §N"). The `ignition-sales-kit` skill's `SKILL.md` and `references/{deck-outline,demo-architecture,anonymization}.md` are normative where the spec does not override them; `references/example-demo-src.html` and `references/example-build_sales_deck.js` are the worked patterns to copy structure and helpers from.

## Global Constraints

- **Paths.** `KIT` = `C:\Users\JacquesPotgieter\Documents\Dev\Marketing\MES Track & Trace\` (shareable). `SKILL` = `C:\Users\JACQUE~1\AppData\Local\Temp\claude\C--Users-JacquesPotgieter--claude-spares-spare-zhB1ew\d8ea4fa4-3cec-4cb4-86a6-885928e5f6fb\scratchpad\rfid_kit\RFID Track & Trace - Marketing Kit\skill\ignition-sales-kit\`. `PPTX` = `C:\Users\JacquesPotgieter\AppData\Local\Claude-Data\claude_pzs8sxrjxfjjc\local-agent-mode-sessions\skills-plugin\191ea612-08b2-49ff-a794-931fd00cb623\c510e7c7-1612-4930-9e03-88095f47f951\skills\pptx\scripts\`. `MPP` = the repo root.
- **Deliverable names, exactly:** `MES Track & Trace - Overview.pptx`, `MES Track & Trace - Interactive Demo.html`, `README.md`.
- **Never in a shareable file** (deck XML, demo, README, build sources): the terms in `MPP/tools/sales-kit/banned_terms.txt`, any PLC / controls / scale / printer / vision brand, any date, timeline or price. Ignition may be named. Blue Ridge Automation may be named.
- **Never say "continuous".** Say **lot-based** (casting, trim) and **line-flow** (machining, assembly).
- **"Proven in production at a manufacturer"** appears exactly once, in the core (deck slide 4 and the demo welcome screen). No per-feature live claims. The scale station, controlled runs / super-lots and OEE do not appear in modules 1-3; OEE appears only on the add-ons slide.
- **Call-to-action label, verbatim:** `Schedule a live demo with one of our engineers`. Link: `CONFIG.cta.href` = `"#schedule-placeholder"` with `CONFIG.cta.placeholder = true`, which the UI shows as a visible "link to be supplied" marker.
- **Demo:** one HTML file, no external requests, works from `file://`, a web server and an iframe; any `localStorage` use wrapped in try/catch; dark only (`<meta name="color-scheme" content="dark">`); usable at 1024x768; "best on a larger screen" note below 800 px; "SAMPLE PROJECT" chip in the header with tooltip "Simulated plant and data".
- **Demo tokens** (copy into `:root`): `--n10:#0B1220 --n20:#111A2E --n30:#172238 --n40:#1F2C44 --n50:#2C3A55 --n60:#425270 --n70:#697A98 --n80:#9AA8BF --n90:#C9D2E0 --n100:#F0F3F8 --a40:#126680 --a50:#1888A8 --a60:#22A8CC --a70:#4BC2E0 --warn:#F4B343`; fonts `'Noto Sans', 'Segoe UI', sans-serif` and `'Roboto Mono', Consolas, monospace` (system fallbacks only; no web fonts).
- **Seed/string values are ASCII-only** in CONFIG and the deck generator (use `-` not em-dash, `x` not multiplication sign) except deliberate UI glyphs written as `\u` escapes in JS.
- **Git.** `KIT` is its own local git repo (no remote); `node_modules/`, `render/`, `*.tmp` ignored. Files in `MPP` are committed on `jacques/working` with explicit paths only (never `git add -A`/`-u`), no `Co-Authored-By` trailer.
- **Study material is never copied.** `MPP/notes/2026-10-22_mpp-mes-walkthrough.html` and `MPP/mockup/*.html` may be read for behaviour, layout and wording; nothing from them is pasted into `KIT`.

## Review Focus

1. **Clicking while the simulation runs at 10x** -- an open LOT detail, popup, tour highlight or half-typed PIN must survive re-renders (Task 6 adds `test_rerender_preserves_open_panel` as a browser check; every view task re-runs it).
2. **Leaving the demo running for an hour** -- queues must neither drain to empty nor grow without bound, and no line may stall forever on the low-inventory lock (Task 5: `sim stays bounded over 20000 ticks`).
3. **RESET, or a tour "Show me" whose example LOT has since closed** -- every `go()` must pick a fresh LOT that satisfies the step, never a stored id (Task 5: `findExample` tests; Tasks 7-9 use it in every tour step).
4. **Tracing a LOT that is mid-process** -- an open basket, a partly consumed casting LOT, a tray not yet packed -- must show true partial quantities and no phantom children (Task 3: `traceBack/traceForward on partial parent`).
5. **Opening the file the way a prospect will** -- double-clicked from email (`file://`), inside an iframe, at tablet width -- with zero console errors and zero network requests (Task 10).

---

### Task 1: Kit scaffold, tooling and the term checker

**Files:**
- Create: `KIT/.gitignore`, `KIT/demo-build/assets/logo.png`, `KIT/demo-build/inline_assets.py`, `KIT/deck-build/logo.png`, `KIT/deck-build/package.json`, `KIT/tools/capture_scenes.ps1`, `KIT/tools/render_pptx.ps1`, `KIT/tools/contact_sheet.py`
- Create: `MPP/tools/sales-kit/banned_terms.txt`, `MPP/tools/sales-kit/check_terms.py`, `MPP/tools/sales-kit/test_check_terms.py`
- Create: `MPP/notes/2026-10-26_mes-sales-kit-SOURCE.md`

**Interfaces:**
- Produces: `python -I MPP/tools/sales-kit/check_terms.py <folder>` -- scans every text file, and the XML inside every `.pptx`/`.zip` (`ppt/**/*.xml`), case-insensitive against `banned_terms.txt` (one regex per line, `#` comments) plus a built-in date regex `\b20\d\d-\d\d-\d\d\b` and month-name-year regex. Prints `path:line: term` per hit; exit 0 when clean, 1 otherwise. Skips `node_modules/`, `render/`, `.git/`.

- [ ] **Step 1: Create the folders, git init, copy the logo and the four helper scripts.** Logo = `rfid_img0.png` already extracted beside `SKILL/..` (`...\RFID Track & Trace - Marketing Kit\rfid_img0.png`). Scripts come from `SKILL/scripts/` (`inline_assets.py`, `capture_scenes.ps1`, `render_pptx.ps1`, `contact_sheet.py`). Do not copy anything else from the skill: its references name the RFID kit's customer.
- [ ] **Step 2: Install dependencies.** `python -m pip install numpy pillow python-pptx`; in `KIT/deck-build`: `npm init -y && npm install pptxgenjs`. Expected: `python -c "import numpy, PIL, pptx"` and `node -e "require('pptxgenjs')"` both exit 0.
- [ ] **Step 3: Write `banned_terms.txt`** -- the spec §6 list as regexes: `\bMPP\b`, `madison`, `precision products`, `indiana`, `honda`, `\bAIM\b`, `flexware`, `manufacturing director`, `sparkmes`, `excsrv`, `\b5G0\b`, `\b6MA\b`, `12270`, `\b5J6\b`, `\b5K8\b`, `\b64A\b`, `\b6C2\b`, `\bDM\d{4}\b`, `\bLTT\b`, `T-Out-A`, `M-Out-A`, `M-In-A`, `allen.?bradley`, `rockwell`, `logix`, `siemens`, `omron`, `mitsubishi`, `cognex`, `zebra`, `omniserver`, `topserver`, `baxter`, `\$\s?\d`, `\bcontinuous\b`. Add any real line, area or terminal name found while studying in Step 6.
- [ ] **Step 4: Write the failing tests** in `test_check_terms.py` (pytest-free, plain `assert`, run with `python -I`): `test_clean_folder_passes` (a temp folder with `hello.html` = `"<p>Sample plant</p>"` -> exit 0); `test_flags_term_in_html` (`"Ships to Honda"` -> exit 1, output contains `honda`); `test_flags_term_inside_pptx_xml` (a zip named `x.pptx` holding `ppt/slides/slide1.xml` with `MPP` -> exit 1); `test_flags_iso_date` (`"2026-10-26"` -> exit 1); `test_skips_node_modules` (term only under `node_modules/` -> exit 0).
- [ ] **Step 5: Run the tests -- expect FAIL** (`check_terms.py` missing). Implement `check_terms.py`. Run again: `python -I MPP/tools/sales-kit/test_check_terms.py` -> prints `5 passed`.
- [ ] **Step 6: Study and write the internal SOURCE note.** Read the walkthrough sections for sign-in, die cast, Machining IN/OUT, assembly, protected actions, genealogy; read `mockup/diecast_reconcile_mock.html` and `mockup/diecast_shift_reconciliation_mock.html`; read CLAUDE.md "Terminal-mint model" and "Die cast -- cavity-attributed scrap". Write `notes/2026-10-26_mes-sales-kit-SOURCE.md`: where the kit lives, which project it came from, the real -> fictional mapping of concepts (not names) used in Task 2's CONFIG, the maturity snapshot from spec §5, and how to run `check_terms.py`.
- [ ] **Step 7: Commit both repos.** KIT: `git add .gitignore demo-build deck-build/package.json deck-build/package-lock.json deck-build/logo.png tools && git commit -m "scaffold: kit folders, helper scripts, logo"`. MPP: `git add tools/sales-kit/banned_terms.txt tools/sales-kit/check_terms.py tools/sales-kit/test_check_terms.py notes/2026-10-26_mes-sales-kit-SOURCE.md docs/superpowers/specs/2026-10-22-mes-sales-kit-design.md docs/superpowers/plans/2026-10-26-mes-sales-kit.md && git commit -m "sales-kit: design, plan, term checker, source note"`.

### Task 2: CONFIG and the die-cast half of the domain model

**Files:**
- Create: `KIT/demo-build/src/config.js`, `KIT/demo-build/src/model.js`
- Test: `KIT/demo-build/test/model.diecast.test.js`

**Interfaces:**
- Module format (every `src/*.js`): `(function (root) { ...; root.X = X; if (typeof module === 'object') module.exports = X; })(typeof window !== 'undefined' ? window : globalThis);` -- `config.js` exports `CONFIG`, `model.js` exports `Model`.
- `CONFIG` shape (pinned values; names otherwise builder's call within spec §6):
  - `plant: { name: 'Sample Components Plant', shifts: ['A','B'] }`
  - `presses: [{id:'P-01', die:'D-210'}, {id:'P-02', die:'D-220'}, {id:'P-03', die:'D-240'}]`
  - `dies: { 'D-210': {cavities:[{item:'HSG-410', code:'a'},{item:'HSG-410', code:'b'}]}, 'D-220': {cavities:[{item:'CVR-220',code:'a'},{item:'CVR-220',code:'b'},{item:'BRK-230',code:'a'},{item:'BRK-230',code:'b'}]}, 'D-240': {cavities:[{item:'HSG-440',code:'a'},{item:'HSG-440',code:'b'}]} }` -- D-220 is the family die: cavity identity is `(item, code)`, never `code` alone.
  - `items: { 'HSG-410': {type:'Casting', name:'Housing casting', basketQty:48, route:['DieCast','TrimIn','TrimOut','MachiningIn','MachiningOut']}, 'HSG-410-M': {type:'SubAssembly', name:'Machined housing', route:['AssemblyOut']}, 'HSG-440': {type:'Casting', name:'Pump housing casting', basketQty:40, route:['DieCast','TrimIn','TrimOut','MachiningIn','MachiningOut']}, 'HSG-440-M': {type:'SubAssembly', ...}, 'CVR-220': {type:'Casting', name:'Cover casting', basketQty:96, route:['DieCast','TrimIn','TrimOut','MachiningIn','AssemblyOut']}, 'BRK-230': {type:'Casting', name:'Bracket casting', basketQty:120, route:[same as CVR-220]}, 'SEAL-01': {type:'Component', name:'Seal kit (purchased)', boxQty:200}, 'FG-4100': {type:'FinishedGood', name:'Housing assembly', trayQty:12, bom:{'HSG-410-M':1,'SEAL-01':1}}, 'FG-4400': {type:'FinishedGood', name:'Pump housing assembly', trayQty:10, bom:{'HSG-440-M':1,'SEAL-01':1}}, 'FG-2200': {type:'FinishedGood', name:'Cover assembly', trayQty:24, bom:{'CVR-220':1,'BRK-230':2}} }`
  - `lines: { 'L-1': {name:'Housing line', machiningOut:true, makes:['FG-4100','FG-4400']}, 'L-2': {name:'Cover line', machiningOut:false, makes:['FG-2200']} }` -- L-2 has no Machining OUT, so its castings are consumed directly at Assembly OUT (spec §4.2, CLAUDE.md Model Y).
  - `operators: [{initials:'JK', name:'J. Kowalski', pin:'04218'}, ... 6 total, at least one PIN with a leading zero]`, `supervisors: [{initials:'RS', name:'R. Santos'}]`
  - `cta: { label:'Schedule a live demo with one of our engineers', href:'#schedule-placeholder', placeholder:true }`
  - `lotPrefix:'LT', containerPrefix:'CN', seed: 20261`
- `Model` (all functions pure over a `state` object they mutate; all ids strings):
  - `createState(config, seed) -> State` with `lots:{}`, `edges:[]` (`{parent, child, qty, kind:'Consumption'}`), `events:[]` (`{t, lotId, kind, qty, who}`), `cavityState:{[pressId]:{[item+'/'+code]:{basketLotId|null, watermark, pending}}}`, `counters:{[pressId]:number}`, `clock` (minutes since shift start), `shift:'A'`, `rnd()` seeded PRNG.
  - `openBasket(state, pressId, item, code, who) -> Lot` -- `Lot = {id, item, type, qty, origin:'Manufactured'|'Received', status:'Open'|'Good'|'Closed'|'Hold', location, routeStep, createdAt, press, die, cavity, shift}`; refuses (throws `Error('basket already open')`) if that cavity already has one.
  - `recordShot(state, pressId) -> void` -- increments the press counter; each cavity with an open basket gets `qty += 1`; a cavity with none adds to `pending` (never advances a watermark).
  - `releaseBasket(state, lotId, who) -> Lot` -- status `Good`, location `'TRIM'`, `routeStep` -> `TrimIn`; frees the cavity.

- [ ] **Step 1: Write the failing tests** (`node --test KIT/demo-build/test`): `config is ascii-only` (JSON.stringify(CONFIG) has no char > 0x7E); `family die cavity identity` (open baskets on D-220 `CVR-220/a` and `BRK-230/a` both succeed); `second basket on same cavity throws`; `shots fill open baskets only` (open HSG-410/a only, 5 shots -> that LOT qty 5, cavity b `pending` 5, counter 5); `release moves basket to trim` (status `Good`, location `TRIM`, cavity free).
- [ ] **Step 2: Run** `node --test KIT/demo-build/test` -> FAIL (`Cannot find module`).
- [ ] **Step 3: Implement `config.js` and the four `Model` functions above.**
- [ ] **Step 4: Run** -> all pass.
- [ ] **Step 5: Commit** (KIT): `git add demo-build/src demo-build/test && git commit -m "model: config and die cast baskets"`.

### Task 3: Line-flow model -- trim, FIFO, minting, trays, containers, trace

**Files:**
- Modify: `KIT/demo-build/src/model.js`
- Test: `KIT/demo-build/test/model.flow.test.js`

**Interfaces:**
- Consumes: Task 2 `State`, `Lot`.
- Produces (on `Model`):
  - `trimComplete(state, lotId, scrapQty, who) -> Lot` -- subtractive scrap (`qty -= scrapQty`), routeStep -> `MachiningIn`, location = `lineFor(item)` (internal helper: the line whose `makes` includes an FG whose BOM, directly or via `item + '-M'`, uses this item).
  - `lineQueue(state, lineId, role) -> Lot[]` -- open-or-good LOTs at the line whose current `routeStep === role`, oldest `createdAt` first. For a LOT whose route's last step is `MachiningOut`/`AssemblyOut`, it stays in that queue until `qty === 0` (then `status:'Closed'`).
  - `machiningInPick(state, lineId, lotId, who) -> Lot` -- refuses unless `lotId` is `lineQueue(...,'MachiningIn')[0]` (`Error('not next in FIFO')`); advances `routeStep`.
  - `machiningOutMint(state, lineId, parentLotId, qty, who) -> Lot` -- creates the sub-assembly LOT (item = `parent.item + '-M'`), reduces parent, adds edge `{parent, child, qty, kind:'Consumption'}`, closes parent at 0. Refuses on a line with `machiningOut:false`.
  - `availableFor(state, lineId, item) -> number` -- sum of qty of usable LOTs of `item` at the line (for FG components: SubAssembly at `AssemblyOut`, castings at `AssemblyOut` on lines without Machining OUT, purchased `Received` LOTs).
  - `assemblyCompleteTray(state, lineId, fgItem, who) -> {ok:true, lot} | {ok:false, reason:'locked', short:{[item]:needed}}` -- consumes `bom[item] * trayQty` per component FIFO across LOTs (one edge per LOT drawn from); a tray LOT is `Manufactured` and is never itself a component source.
  - `isLocked(state, lineId, fgItem) -> boolean` -- true when any component's `availableFor` < its per-tray need.
  - `checkInBox(state, lineId, item, qty, supplierLot, who) -> Lot` -- `origin:'Received'`, `status:'Good'`, at the line.
  - `packContainer(state, lineId, fgItem, trayLotIds, who) -> Container` -- `{id, item, trays:[...], qty, createdAt}` stored in `state.containers`; trays get `status:'Closed'`, `containerId`.
  - `traceBack(state, lotId) -> Node` where `Node = {lot, qty, parents: Node[]}` (qty = edge qty into the child).
  - `traceForward(state, lotId) -> {lots: Lot[], containers: Container[]}`.

- [ ] **Step 1: Write the failing tests:** `trim scrap is subtractive`; `machining in refuses out-of-order pick`; `mint reduces parent, creates child, records edge` (parent 48, mint 12 -> parent 36 open, child 12, one edge qty 12); `mint closes parent at zero`; `mint refused on line without machining out` (L-2); `minted sub-assembly is not in the Machining OUT queue` (regression for the known MPP wart in CLAUDE.md: after minting, `lineQueue(L-1,'MachiningOut')` contains no `-M` item); `tray consumes FIFO across lots` (two HSG-410-M LOTs of 8 and 8, trayQty 12 -> oldest drained to 0, second to 4, two edges); `tray locks when short` (`{ok:false, reason:'locked', short:{'SEAL-01':...}}` and no state change); `check-in clears the lock`; `tray lots are never component sources` (FG-2200 tray created, then `availableFor(L-2,'FG-2200')` is 0); `traceBack/traceForward on partial parent` (cast 48, mint 12 twice -> traceForward(casting) lists both children and only them; traceBack(child) shows parent with qty 12; after packing one child's tray, forward trace includes that container).
- [ ] **Step 2: Run** -> FAIL. **Step 3: Implement.** **Step 4: Run** -> pass.
- [ ] **Step 5: Commit:** `git add demo-build/src/model.js demo-build/test/model.flow.test.js && git commit -m "model: line flow, minting, trays, lock, trace"`.

### Task 4: Shift reconciliation model

**Files:**
- Modify: `KIT/demo-build/src/model.js`
- Test: `KIT/demo-build/test/model.reconcile.test.js`

**Interfaces:**
- Produces:
  - `recordScrap(state, pressId, item, code, qty, reason, who)` -- die cast scrap is **additive** (never decrements a basket); stamped with `press, die, item, code, shift`; works with no basket open.
  - `reconcile(state, pressId) -> Row[]` (`counterDelta` = the press counter change since shift start; each cavity tracks its own watermark at its first basket open this shift), one row per cavity `(item, code)`, grouped by item then code: `{item, code, netShots, good, scrap, unaccounted, pending, disposition|null}` where for a cavity that had a basket this shift `netShots = counterDelta - pending`, `good` = pieces put in its baskets this shift, `unaccounted = netShots - good - scrap`; a cavity with no basket all shift has `pending = counterDelta` and is outside the identity (`unaccounted = null`).
  - `dispose(state, pressId, item, code, reason, who)` -- `reason` in `CONFIG.varianceReasons = ['Warm-up shots','Counter error','Short shot not logged','Unknown']`; required when `unaccounted !== 0`.
  - `reconcileComplete(state, pressId) -> {ok:true} | {ok:false, missing:[{item,code}]}`.

- [ ] **Step 1: Write the failing tests:** `identity holds per cavity` (for every row with a basket, `netShots === good + scrap + unaccounted`); `scrap is additive` (recordScrap 3 with a basket open -> basket qty unchanged); `scrap without a basket is recorded`; `cavity with no basket is pending, not variance`; `family die rows grouped by item then code` (D-220 rows order `BRK-230/a, BRK-230/b, CVR-220/a, CVR-220/b`); `non-zero variance requires disposition` (complete -> `missing` lists it; after `dispose(...'Unknown')` -> ok); `Unknown is always accepted`.
- [ ] **Step 2: Run** -> FAIL. **Step 3: Implement.** **Step 4: Run** -> pass.
- [ ] **Step 5: Commit:** `git add demo-build/src/model.js demo-build/test/model.reconcile.test.js && git commit -m "model: shift reconciliation"`.

### Task 5: Simulation tick and tour example finder

**Files:**
- Create: `KIT/demo-build/src/sim.js`
- Test: `KIT/demo-build/test/sim.test.js`

**Interfaces:**
- Produces `Sim`:
  - `seedPlant(state) -> void` -- populates a realistic mid-shift plant: every press running with baskets open on most cavities (at least one cavity pending somewhere), 6-12 LOTs across trim and each line queue, sub-assemblies at L-1 Assembly OUT, a few packed containers, SEAL-01 boxes checked in, at least one non-zero variance on P-02.
  - `tick(state) -> string[]` -- advances one simulated minute and returns the ids of LOTs it changed. Rules: each press fires on a fixed cycle (P-01 every tick, P-02 every 2, P-03 every tick) with a 2% chance of a short (scrap 1); full baskets release (an "operator" opens the next one after 0-3 ticks, so pending happens naturally); trim completes the oldest trimmed basket every ~4 ticks; machining picks/mints FIFO; assembly completes a tray when not locked; when SEAL-01 runs low a box is checked in after a short delay (so the lock is seen, then clears); trays pack into containers of 4; closed LOTs older than 240 ticks are archived out of the live views but kept for trace.
  - `findExample(state, kind) -> lotId|null` for `kind` in `'openBasket' | 'pendingCavity' | 'trimQueue' | 'machiningInNext' | 'mintable' | 'subAssembly' | 'finishedTray' | 'packedTray' | 'lockedLine'` -- always computed from current state.
  - `reset(state)` -- `createState` + `seedPlant` with `CONFIG.seed`.

- [ ] **Step 1: Write the failing tests:** `same seed same plant` (two resets -> deep-equal lots); `pieces are conserved` (after 2000 ticks: total cast good == sum over lots of qty + consumed edge qty + trim scrap, per casting item); `genealogy is acyclic`; `sim stays bounded over 20000 ticks` (live open LOT count between 15 and 250 at every 1000th tick; every line packed at least one container in each 2000-tick window; no line locked for more than 60 consecutive ticks); `findExample returns a valid lot for every kind after seed and after 5000 ticks` (each returned LOT satisfies its kind's predicate).
- [ ] **Step 2: Run** -> FAIL. **Step 3: Implement.** **Step 4: Run** -> pass (keep the 20000-tick test under 10 s).
- [ ] **Step 5: Commit:** `git add demo-build/src/sim.js demo-build/test/sim.test.js && git commit -m "sim: tick, seed, findExample"`.

### Task 6: Demo shell -- build script, chrome, welcome menu, sign-in, protected action, tour engine, scenes

**Files:**
- Create: `KIT/demo-build/src/template.html` (all CSS + `<body>` shell; `<!--@SCRIPTS@-->` marker), `KIT/demo-build/src/ui/shell.js`, `KIT/demo-build/src/ui/core.js`, `KIT/demo-build/src/ui/tour.js`, `KIT/demo-build/build_demo.py`, `KIT/.claude/launch.json`

**Interfaces:**
- `build_demo.py`: `python -I build_demo.py` (cwd `demo-build`) concatenates, in order, `config.js, model.js, sim.js, ui/shell.js, ui/core.js, ui/m1.js, ui/m2.js, ui/m3.js, ui/tour.js` (skipping missing ones) into the template, writes `demo-src.html`, then runs `inline_assets.py demo-src.html "../MES Track & Trace - Interactive Demo.html"`.
- `ui/shell.js` produces `UI`: `UI.state` (the model State), `UI.view`, `UI.register(name, {title, module, render(root), nav:boolean})`, `UI.navigate(name, params)`, `UI.refresh()` (throttled 500 ms at 3x/10x, immediate at 1x), `UI.openLot(lotId)` (one shared LOT detail -- implemented in Task 7, stubbed here), `UI.toast(msg, level)`, `UI.setSpeed(n)`, `UI.toggleSim()`, `UI.reset()`, `UI.hl(elementId)`; sim controls PAUSE / 1x / 3x / 10x / RESET and a LIVE dot in the header; header also holds the plant name, the SAMPLE PROJECT chip, the signed-in operator, and the CTA button.
- `ui/core.js` registers `welcome`, `signin`, and `UI.requireSupervisor(actionText) -> Promise<boolean>` (modal: "This action needs a supervisor", supervisor picks name + types a password-styled field that accepts any non-empty value -- it is a demo; text notes "In your plant this is checked against your directory").
  - Welcome: one sentence (`A sample plant running MES Track & Trace on Ignition -- the plant, parts and data are simulated.`), the single "proven in production at a manufacturer" line, one tile per **built** module (`TOURS` keys) that starts that module's tour, "Explore on your own", the CTA. Reopenable via "About this demo".
  - Sign-in: numeric PIN pad, 5 digits, leading zero kept (PIN is a string), unknown PIN -> "Re-type PIN" primary and "Register" secondary; success shows initials in the header.
- `ui/tour.js`: `TOURS = { core:[...], m1:[...], m2:[...], m3:[...] }`, each step `{title, text, go()}`; drawer bottom-left, collapsible, Back / Show me / Next, "Step n of N", module name, "Back to the menu" on the last step, last step text ends with the CTA. `tourStart(module)`, `tourGo()`.
- Scenes: `?scene=<name>&nochrome=1` pauses the sim, skips welcome, calls `SCENES[name]()`; `?skip=1` skips welcome. `SCENES` is a plain object each module file adds to. Shell scenes: `welcome`, `signin-pad`, `protected-action`.
- `.claude/launch.json` in KIT: `{"version":"0.0.1","configurations":[{"name":"kit-demo","runtimeExecutable":"python","runtimeArgs":["-m","http.server","8765"],"port":8765}]}` (cwd KIT).

- [ ] **Step 1: Implement shell, core, tour engine (with the core tour: 4 steps -- welcome, sign in, a protected action, the menu) and `build_demo.py`.** Navigate must add/remove its own `v-<view>` body class (never overwrite `className`) so `nochrome` survives.
- [ ] **Step 2: Build:** `python -I build_demo.py` -> `KIT/MES Track & Trace - Interactive Demo.html` exists, < 1.5 MB.
- [ ] **Step 3: Browser check** via `preview_start` name `kit-demo`, open `/MES%20Track%20%26%20Trace%20-%20Interactive%20Demo.html`: welcome renders; sign-in with `04218` succeeds and shows `JK`; `00000` shows Re-type PIN; protected-action modal resolves true/false; speed controls change tick rate; `test_rerender_preserves_open_panel` -- open the protected-action modal, set 10x, wait 5 s, modal and typed text still there; `read_console_messages onlyErrors` -> none.
- [ ] **Step 4: Term check:** `python -I MPP/tools/sales-kit/check_terms.py KIT` -> exit 0.
- [ ] **Step 5: Commit (KIT):** `git add demo-build/src demo-build/build_demo.py .claude/launch.json && git commit -m "demo: shell, welcome menu, sign-in, protected action, tour engine"`. (The built HTML is committed at Task 10.)

### Task 7: Module 1 -- Traceability & genealogy

**Files:**
- Create: `KIT/demo-build/src/ui/m1.js`; Modify: `KIT/demo-build/src/ui/tour.js` (TOURS.m1)

**Interfaces:**
- Consumes: `Model.traceBack/traceForward`, `Sim.findExample`, `UI.register/openLot/hl`.
- Produces views `lot-search` (search by LOT id, item, or container; recent LOTs table), `lot-detail` (header: LOT id, item + name, qty, status pill, location, created by/at; tabs History | Genealogy | Where used), `genealogy` (indented tree back to press, die, cavity, shift; any node clickable -> `UI.openLot`), `trace-report` (a printable "Trace report" rendered as a white A4-style page inside the dark app, with a Print button calling `window.print()` and a print stylesheet). Implements `UI.openLot`.
- Tour m1 (6-8 steps): find a finished tray -> its LOT detail -> genealogy back to the press and cavity -> the casting LOT -> where used, forward to containers -> the trace report -> any LOT anywhere opens this same detail -> CTA. Every `go()` uses `Sim.findExample`.
- Scenes: `m1-search`, `m1-lot-detail`, `m1-genealogy`, `m1-where-used`, `m1-trace-report`.

- [ ] **Step 1: Implement views, tour, scenes.** Re-render without closing an expanded tree node or the active tab (key expanded state by LOT id).
- [ ] **Step 2: Build and browser-check:** every m1 tour step's Show me at 1x and 10x lands on a valid LOT; the genealogy of a mid-process casting shows partial child quantities matching the model; `test_rerender_preserves_open_panel` with the genealogy tree expanded; console errors none; term check exit 0.
- [ ] **Step 3: Commit:** `git add demo-build/src/ui/m1.js demo-build/src/ui/tour.js && git commit -m "demo: module 1 traceability"`.

### Task 8: Module 2 -- Casting & lot-based production

**Files:**
- Create: `KIT/demo-build/src/ui/m2.js`; Modify: `tour.js` (TOURS.m2)

**Interfaces:**
- Consumes: `Model.openBasket/releaseBasket/recordScrap/reconcile/dispose/reconcileComplete/trimComplete`, `UI.requireSupervisor`.
- Produces views `diecast` (press picker; per cavity card grouped by part then letter: basket LOT, live count / basket qty bar, Open / Release / Scrap buttons; a cavity with no basket shows "No basket -- shots pending"), `trim` (queue of baskets oldest first; Check out with scrap qty), `reconcile` (per press: rows grouped part -> letter with Net shots, Good, Scrap, Unaccounted, Disposition dropdown; rows with non-zero unaccounted highlighted `--warn`; Complete button shows the missing list or succeeds; pending cavities in a separate "Pending -- no basket" block outside the totals). Releasing a basket below its count asks `UI.requireSupervisor('Release a basket under count')`.
- Tour m2 (6-8 steps): a press with baskets filling live -> open a basket on a pending cavity -> release at count -> the basket in trim, checked out -> shift reconciliation, the identity in words ("every shot is a good part, a scrap, or explained") -> dispose a variance with "Unknown" -> the basket's LOT detail (crosses into module 1) -> CTA.
- Scenes: `m2-diecast`, `m2-release`, `m2-trim`, `m2-reconcile`, `m2-reconcile-variance`.

- [ ] **Step 1: Implement.** **Step 2: Build and browser-check** (tour Show me at 1x/10x; release-under-count path both approve and cancel; reconcile Complete blocked then succeeds; counts keep rising under an open popup; console clean; term check). **Step 3: Commit** `git add demo-build/src/ui/m2.js demo-build/src/ui/tour.js && git commit -m "demo: module 2 casting"`.

### Task 9: Module 3 -- Line-flow machining & assembly

**Files:**
- Create: `KIT/demo-build/src/ui/m3.js`; Modify: `tour.js` (TOURS.m3)

**Interfaces:**
- Consumes: `Model.lineQueue/machiningInPick/machiningOutMint/assemblyCompleteTray/isLocked/checkInBox/packContainer/availableFor`.
- Produces views `line-inventory` (per line: what is at the line by item, with counts), `machining-in` (scan field accepting a LOT id + "next in line" card; a wrong LOT gets "not next in line -- take LOT xxx first"), `machining-out` (FIFO queue oldest first, pick a casting LOT, enter qty, Mint -> card "Parent LT... reduced 48 -> 36, new LT... created 12"), `assembly` (per line: product picker, tray progress, Complete tray; when `isLocked` the station shows a locked banner naming the short component and a "Check in a box" action, after which it unlocks).
- Tour m3 (6-8 steps): line inventory -> Machining IN scan the next LOT (and the refusal for a wrong one) -> Machining OUT, a machined part is born from its casting -> assembly completes a tray -> the station locks before it runs out -> check in a box, unlocked -> the tray's genealogy back to the press (crosses into module 1) -> CTA.
- Scenes: `m3-line-inventory`, `m3-machining-in`, `m3-machining-out-minted`, `m3-assembly`, `m3-assembly-locked`.

- [ ] **Step 1: Implement.** **Step 2: Build and browser-check** (as Task 8, plus: wrong-LOT refusal; lock -> check-in -> unlock; L-2 tour path never offers Machining OUT). **Step 3: Commit** `git add demo-build/src/ui/m3.js demo-build/src/ui/tour.js && git commit -m "demo: module 3 line flow"`.

### Task 10: Demo verification pass

**Files:** none created; fixes go to the files of Tasks 6-9.

- [ ] **Step 1: Viewports** -- `resize_window` 1600x900, 1024x768, 700x900: every view and the welcome screen; nav never wraps into content; tour drawer never covers primary buttons; the small-screen note at 700. Reset to `desktop` after.
- [ ] **Step 2: Hosting** -- `read_network_requests` after a full tour shows only the page itself; open the built file inside a test page at `KIT/tools/iframe-check.html` (`<iframe src="../MES%20Track%20%26%20Trace%20-%20Interactive%20Demo.html" width=1400 height=850>`, served by `kit-demo`) -> works; then in headless Edge from `file://` via `capture_scenes.ps1 -Scenes welcome` -> image shows the welcome screen.
- [ ] **Step 3: All four tours end to end at 10x**, every Show me; RESET mid-tour then Show me again works; console errors none.
- [ ] **Step 4: Term check** exit 0; grep the built HTML for `http` -> only `http://www.w3.org/2000/svg`.
- [ ] **Step 5: Commit (KIT):** `git add "MES Track & Trace - Interactive Demo.html" demo-build tools/iframe-check.html && git commit -m "demo: verified build"`.

### Task 11: Capture deck screens

**Files:** Create `KIT/deck-build/screens/*.png`

- [ ] **Step 1: Capture:** `powershell -File KIT/tools/capture_scenes.ps1 -Demo "KIT/MES Track & Trace - Interactive Demo.html" -Out KIT/deck-build/screens -Scenes "welcome,signin-pad,protected-action,m1-search,m1-lot-detail,m1-genealogy,m1-where-used,m1-trace-report,m2-diecast,m2-release,m2-trim,m2-reconcile,m2-reconcile-variance,m3-line-inventory,m3-machining-in,m3-machining-out-minted,m3-assembly,m3-assembly-locked" -WideScenes "signin-pad,protected-action"` -> every line `ok`.
- [ ] **Step 2: Look at every PNG** (Read tool). Re-capture any that is blank, mid-animation, or shows the tour drawer / SAMPLE chip. Fix the scene, not the image.
- [ ] **Step 3: Commit:** `git add deck-build/screens && git commit -m "deck: screen captures"`.

### Task 12: Deck generator and its checks

**Files:**
- Create: `KIT/deck-build/build_deck.js` (start from `SKILL/references/example-build_sales_deck.js`: keep its THEME/masters/helpers `content, wideShot, card, badge, callout, bullets`, replace content), `KIT/deck-build/check_deck.py`

**Interfaces:**
- Run: `APPLY_THEME="PPTX/apply_theme.js" NODE_PATH="$PWD/node_modules" node build_deck.js` (cwd deck-build) -> writes `KIT/MES Track & Trace - Overview.pptx`.
- Sections and slides (titles are the build's exact strings for the checks; captions/notes builder's):
  - **Core:** 1 `MES Track & Trace` (title; drawn flow graphic basket -> line -> finished good -> container; "Presented by Blue Ridge Automation"); 2 `The question after every customer complaint`; 3 `Where this fits`; 4 `What we deliver` (one system, both modes -- lot-based and line-flow -- one genealogy; the single "proven in production at a manufacturer" line); 5 `The operator's day` (signin-pad + protected-action captures); 6 `Where do you want to start?` (menu: 7 tiles; tiles 1-3 hyperlink to the first slide of their section; tiles 4-7 labelled `Available on request`, no link).
  - **Module 1** (`Traceability & genealogy`), **Module 2** (`Casting & lot-based production`), **Module 3** (`Line-flow machining & assembly`): a module title slide, 3-4 tour slides from that module's captures, and a closing slide whose `Back to the menu` text hyperlinks to slide 6.
  - **Close:** `What changes on your floor`; `Is this a fit for your plant?` (notes map answers to modules); `How we work together` (site walk, functional design spec, build and preview, commission on site, train and hand over -- no durations); `Additional add-ons` (OEE & downtime analytics, ERP / scheduling integration, controlled runs with e-signed release, scale / weigh stations -- "quoted separately"); `Let's walk your floor.`; `Take the next steps` (last; 1 explore the interactive demo, 2 `Schedule a live demo with one of our engineers`).
  - Every slide calls `addNotes` with `TALK TRACK:`; slide 1's notes carry the do-not-say list (sample plant is fictional; if asked where it runs, "in production at a manufacturer" and nothing more; no customer names, timelines, prices, PLC brands) and the **starting point picker** (prospect says X -> open module N).
- `check_deck.py <pptx>` asserts: slide 6 title `Where do you want to start?`; exactly 3 internal hyperlinks on slide 6, each targeting the first slide of sections Module 1/2/3; every module's last slide has a hyperlink to slide 6; every slide has notes starting `TALK TRACK:` or `CLOSE:`; last slide title `Take the next steps`; the phrase `proven in production` occurs exactly once across all slide text (notes excluded); no slide text contains `continuous`. Exit 0 when all pass, printing each check.

- [ ] **Step 1: Write `check_deck.py`; run it against a missing file -> FAIL.**
- [ ] **Step 2: Implement `build_deck.js`.** pptxgenjs gotchas from deck-outline.md: `&` in `pres.company` / master titles as `&amp;`; explicit image `w`/`h` from real aspect ratio; `isTextBox: true` on free text; `align: "left"` on titles. Internal links: `hyperlink: { slide: N }`.
- [ ] **Step 3: Build, then** `python -I check_deck.py "../MES Track & Trace - Overview.pptx"` -> all checks pass; `python "PPTX/office/validate.py" "../MES Track & Trace - Overview.pptx"` (not with `-I`) -> valid.
- [ ] **Step 4: Commit:** `git add deck-build/build_deck.js deck-build/check_deck.py "MES Track & Trace - Overview.pptx" && git commit -m "deck: menu-driven overview"`.

### Task 13: Render and inspect the deck

- [ ] **Step 1:** `powershell -File KIT/tools/render_pptx.ps1 "KIT/MES Track & Trace - Overview.pptx" KIT/render/` then `python -I KIT/tools/contact_sheet.py KIT/render KIT/render/sheet --cols 2 --per-sheet 6`.
- [ ] **Step 2: Look at every contact sheet**: text overflow, titles wrapping, pills over screenshots, stretched images, colliding captions. Fix in `build_deck.js`, rebuild, re-run `check_deck.py`, re-render until clean.
- [ ] **Step 3: Hyperlinks in slide show** -- PowerPoint COM: open the deck, run the show from slide 6, follow each tile's link (`SlideShowWindow.View.GotoSlide` is not enough -- use the shape's `ActionSettings(1).Hyperlink.SubAddress` and confirm it names the right slide) and each "Back to the menu".
- [ ] **Step 4: Commit** `"deck: render fixes"`.

### Task 14: Package and hand over

**Files:** Create `KIT/README.md`; Modify `MPP/notes/2026-10-26_mes-sales-kit-SOURCE.md`; memory note.

- [ ] **Step 1: README** -- what each file is; presenting (open the demo first; the menu; the starting point picker table copied from slide 1 notes; PAUSE / 1x / 3x / 10x / RESET); the rules (fictional plant; "in production at a manufacturer" and nothing more; no customer, PLC brand, timeline or price; modules 4-7 "available on request"); hosting (single file, no install, iframe-safe); re-skinning (CONFIG block in `demo-build/src/config.js`, then `python -I build_demo.py`); rebuilding the deck; the CTA link is a placeholder to replace in `config.js` and `build_deck.js`.
- [ ] **Step 2: Final term check** `python -I MPP/tools/sales-kit/check_terms.py KIT` -> exit 0 (this unzips the deck XML).
- [ ] **Step 3: Update the SOURCE note** with the build commit hashes and the check results; memory file `project_mpp_sales_kit.md` pointing at `KIT` and the SOURCE note (+ MEMORY.md line).
- [ ] **Step 4: Commit both repos** (KIT: `README.md`; MPP: the SOURCE note, explicit path) and send `MES Track & Trace - Overview.pptx` and `MES Track & Trace - Interactive Demo.html` with `SendUserFile`.
