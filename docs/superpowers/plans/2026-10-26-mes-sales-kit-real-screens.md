# MES Sales Kit -- Real Screens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every screen in the MES Track & Trace kit -- deck screenshots and interactive demo -- with the real MPP Perspective application, captured against a sanitized sample-plant database.

**Architecture:** A disposable database `MPP_MES_Demo` is built from the repo's migrations plus a demo seed set and a proc-driven scenario; a sanitized gate proves it carries no MPP text. The shared Dev gateway's `MPP` connection is pointed at it for one capture session, during which a puppeteer-core script drives the installed Chrome through the real screens and saves each step's DOM, stylesheets and a PNG; a sanitizer applies the customer-term substitutions and re-renders the PNGs from the sanitized DOM. The kit's demo then mounts those captured screens, binds their live regions to the existing simulation, and wires the tour's key actions.

**Tech Stack:** SQL Server 2022 + sqlcmd + the repo's migrations; PowerShell; Node 24 + `puppeteer-core` driving `C:\Program Files\Google\Chrome\Application\chrome.exe`; Python 3.14 (sanitizer, gates); the kit's existing vanilla-JS demo build and pptxgenjs deck.

**Spec:** `docs/superpowers/specs/2026-10-26-mes-sales-kit-real-screens-design.md` (and its parent `2026-10-22-mes-sales-kit-design.md`). Read both first.

## Global Constraints

- **Paths.** `MPP` = repo root. `KIT` = `C:\Users\JacquesPotgieter\Documents\Dev\Marketing\MES Track & Trace\`. `CAP` = `MPP\tools\sales-kit\captures\` (gitignored: raw captures carry app labels before substitution). Gateway connection file: `C:\Program Files\Inductive Automation\Ignition\data\config\resources\core\ignition\database-connection\MPP\config.json`.
- **Database name `MPP_MES_Demo`.** Never drop, reseed or edit `MPP_MES_Dev`; never open the `MPP_Prod` connection. Every SQL file under `sql/seeds_demo/` and every demo script carries no `USE` statement and is run with `-d MPP_MES_Demo`; grep for `USE ` before running anything (memory: scratch scripts hard-code Dev).
- **Gateway switch window.** Announce to Jacques before switching, record the original `connectionProps` value, switch back in the same session even after a failure, confirm Dev data after. The Perspective trial needs Jacques to reset it (gateway admin sign-in) right before the session.
- **Data goes through procs.** Config and history are created with the application's stored procedures (resolved by Code), as `sql/scratch/seed_demo.sql` and `seed_jp_validation.sql` do. Direct INSERTs only where the repo's own seeds use them (locations, attributes, code tables).
- **Sample plant = the kit's `config.js` plant** (spec section 4 and section 11 calls): presses P-01..P-03 with dies D-210 / D-220 (family) / D-240, trim, housing line L-1 (Machining IN, Machining OUT, Assembly OUT), cover line L-2 (Machining IN, Assembly OUT), items HSG-410 / HSG-410-M / HSG-440 / HSG-440-M / CVR-220 / BRK-230 / SEAL-01 / FG-4100 / FG-4400 / FG-2200, BOM FG-2200 = CVR-220 x1 + BRK-230 x1, SubAssembly routes end at `AssemblyOut`, operators and PINs as `config.js` (`04218` J. Kowalski etc.).
- **ASCII-only** seed strings; byte-scan generated SQL before applying.
- **Zero hits** from `python -I tools/sales-kit/check_terms.py` on: the demo DB text dump, every sanitized capture, and the whole `KIT` folder. Run it on its own, never piped.
- **No MPP application change** (views, scripts, SQL procs). The only repo script change is an optional `-SeedsPath` on `Reset-DevDatabase.ps1` with the old default.
- **Git.** MPP commits on `jacques/working`, explicit paths only, no Co-Authored-By trailer. KIT commits in its own repo.

## Review Focus

1. **The gateway left on the demo DB** -- a failed capture, a crash, or a forgotten step must still end with `MPP` back on `MPP_MES_Dev` (Task 6: switch script restores from its own backup; a check that fails if Dev data is not visible).
2. **A real label leaking through a capture** -- app text such as "MPP MES", "LTT", "Madison", "AIM", "Honda" inside attributes, tooltips, `title=`, hidden elements or CSS `content:` (Task 5: sanitizer tests cover attributes and hidden nodes; gate runs on the raw HTML text, not only visible text).
3. **A captured screen that depends on a live gateway** -- fonts, icons, `background-image` URLs or `<img src>` still pointing at `localhost:8088` (Task 5: bundle test fails on any `http`/`//localhost` reference).
4. **Simulation and real screen disagreeing at the same tour step** -- a different LOT number format, a column the sim leaves empty, a count that cannot happen in the real app (Task 8: number formats from captures; Tasks 9-11: side-by-side check per screen).
5. **Live re-render destroying the captured markup's state** -- an open tab, an expanded genealogy node or a half-typed PIN after a tick (Tasks 8-11 re-run the first kit's 10x survival check on every real screen).

---

### Task 1: Demo database -- build path, plant, people, shifts, codes

**Files:**
- Modify: `MPP/sql/scripts/Reset-DevDatabase.ps1` (add `[string]$SeedsPath`, default `sql\seeds`; L74 uses it)
- Create: `MPP/sql/seeds_demo/001_demo_plant.sql`, `002_demo_people_shifts_codes.sql`, `MPP/tools/sales-kit/demo-db/Build-DemoDatabase.ps1`, `MPP/tools/sales-kit/demo-db/verify_demo_config.sql`

**Interfaces:**
- `Build-DemoDatabase.ps1` = `Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Demo -SeedsPath sql\seeds_demo -SkipDemoSeed`, then runs the three generic template seeds from `sql/seeds` (`022`, `024`, `026`, `027`) and `028_seed_aim_pool_dev.sql` (needed by `Container_Complete`), then `sql/seeds_demo/*.sql` in name order, then `verify_*.sql`. Refuses any `-DatabaseName` other than `MPP_MES_Demo`.
- `001_demo_plant.sql` mirrors `011_seed_locations_mpp_plant.sql`'s statement shapes (including the Printer type definition 16): enterprise `SAMPLE` "Sample Components Co.", site `SITE` "Sample Components Plant", Area `DC` "Die Cast" with machine cells `P-01`..`P-03` and terminal `DC-T1` (DefaultScreen `/shop-floor/die-cast`, IpAddress `127.0.0.1`), Area `TRIM` "Trim" with terminal `TRIM-T1` (`/shop-floor/trim`) and storage `TRIM-STORE`, lines `L-1` "Housing line" (terminals `L1-MIN`, `L1-MOUT`, `L1-AOUT` with `/shop-floor/machining-in`, `/shop-floor/machining-out`, `/shop-floor/assembly-nonserialized`, `CurrentClosureMethod` ByCount) and `L-2` "Cover line" (`L2-MIN`, `L2-AOUT`), storage `WHSE` "Warehouse", and `FALLBACK-TERMINAL` under `SITE`. Only `DC-T1` holds `127.0.0.1`; other stations are reached through the Terminal Selector.
- `002`: AppUsers via `Location.AppUser_*` procs with the six `config.js` operators (PIN as `NVARCHAR(5)` text) and two supervisors; a "First Shift" / "Second Shift" schedule (06:00-14:00, 14:00-22:00) in `Oee.ShiftSchedule` the way `scratch/seed_shifts.sql` expects; demo defect codes (`Porosity`, `Short shot`, `Cold flow`, `Flash`, `Damaged in handling`) and a small downtime-code set referencing the demo Areas.

- [ ] **Step 1: Write `verify_demo_config.sql`** (raises an error and selects `FAIL: <reason>` when a check fails, `PASS` otherwise): 3 machine cells under `DC`; exactly one terminal with IpAddress `127.0.0.1` and it is `DC-T1`; `Location.Terminal_GetByIpAddress '127.0.0.1'` returns `DC-T1`; 6 operators whose `Pin` includes `04218` and `40218`; shift schedule rows exist; no Location `Name` containing `Madison`.
- [ ] **Step 2: Add `-SeedsPath`; write `Build-DemoDatabase.ps1` and the two seeds; run** `.\tools\sales-kit\demo-db\Build-DemoDatabase.ps1`. Expected: migrations and repeatables apply, verify prints only `PASS` lines.
- [ ] **Step 3: Confirm Dev untouched:** `sqlcmd -d MPP_MES_Dev -Q "SELECT TOP 1 Name FROM Location.Location ORDER BY Id"` still returns the real enterprise; `Reset-DevDatabase.ps1` with no `-SeedsPath` still reads `sql\seeds` (dry read of the resolved path).
- [ ] **Step 4: Commit** (MPP): the script change, `sql/seeds_demo/001*`, `002*`, `tools/sales-kit/demo-db/*`.

### Task 2: Demo database -- parts, routes, BOMs, dies

**Files:** Create `MPP/sql/seeds_demo/010_demo_items_routes_boms.sql`, `011_demo_dies.sql`; extend `verify_demo_config.sql`.

**Interfaces:**
- Items via `Parts.Item_Create` with the `config.js` types and names, parts-per-basket (`basketQty`) and DefaultSubLotQty (16 for `HSG-410-M` / `HSG-440-M`); eligibility via `Parts.ItemLocation_Add` (castings at `DC` and their line; components and purchased `SEAL-01` at `L-1` as consumption points); BOMs via `Parts.Bom_Create`/`_Publish` (`HSG-410-M` = HSG-410 x1, `HSG-440-M` = HSG-440 x1, `FG-4100` = HSG-410-M x1 + SEAL-01 x1, `FG-4400` = HSG-440-M x1 + SEAL-01 x1, `FG-2200` = CVR-220 x1 + BRK-230 x1); routes via `Parts.RouteTemplate_Create`/`_SaveAll`/`_Publish` exactly as `config.js` (`HSG-*` castings end at `MachiningOut`, `CVR`/`BRK` end at `AssemblyOut`, `*-M` = `AssemblyOut`, FGs = `AssemblyOut`); FG ContainerConfigs via `Parts.ContainerConfig_Create` (4 trays per container, tray qty per `config.js`).
- Dies via `Tools.Tool_Create` (ToolType Die) `D-210`, `D-220`, `D-240`; cavities via `Tools.ToolCavity_Create` with ItemId -- `D-220` carries `CVR-220 a`, `CVR-220 b`, `BRK-230 a`, `BRK-230 b`; mounts via `Tools.ToolAssignment_Assign` onto `P-01`, `P-02`, `P-03`.

- [ ] **Step 1: Extend verify:** every route publishes (`RouteTemplate_Publish` returned success); D-220 has 4 cavities over 2 items; each press has one mounted die; `Parts.Item_ListEligibleFinishedGoodsRanked` (or the BOM read proc) lists FG-2200 at `L-2`.
- [ ] **Step 2: Write both seeds, rebuild with `Build-DemoDatabase.ps1`.** Expected: verify all `PASS`.
- [ ] **Step 3: Commit** (MPP).

### Task 3: Demo database -- production history through the procs

**Files:** Create `MPP/sql/seeds_demo/050_demo_scenario.sql`, `MPP/tools/sales-kit/demo-db/verify_demo_scenario.sql`.

**Interfaces:**
- Modelled on `sql/scratch/seed_demo.sql` (no wipe needed: fresh DB). One shift of history using only: `Lots.DieCastLot_Open`, `Workorder.DieCastShiftOutput_Record`, `Lots.DieCastLot_Release`, `Lots.Lot_MoveToValidated` (to `TRIM`), `Workorder.TrimOut_Record`, `Workorder.MachiningIn_RecordPick`, `Workorder.MachiningOut_Mint`, `Lots.Lot_Create` (Received, `SEAL-01` with vendor lot `SUP-1099`), `Workorder.Assembly_CompleteTray`, `Lots.Container_Open` / `ContainerTray_Close` / `Container_Complete`, `Workorder.RejectEvent_Record` (die cast scrap incl. one not logged, so P-02 shows a variance). Leaves: open baskets on most cavities with one cavity idle (pending shots), 3-6 baskets at trim, LOTs waiting at each line's Machining IN, a casting part-way through Machining OUT, machined housings at Assembly OUT, at least two packed containers with full genealogy back to the press, and seal kits low enough that the housing line is one tray from its lock.
- Every proc call checks the returned `Status` and `THROW`s with the step name on failure, so a broken step stops the script.

- [ ] **Step 1: Write `verify_demo_scenario.sql`:** a container whose trays trace (via the genealogy read proc the Genealogy Viewer uses) back to a casting with Press / Tool / Cavity; `Lot_GetWipQueueByLocation` returns >= 2 LOTs at `L-1` Machining IN; a casting with `PieceCount` < its start count still at Machining OUT; `Quality.Reject_*` / reconcile read for P-02 shows a non-zero unaccounted; no minted SubAssembly appears in the Machining OUT queue.
- [ ] **Step 2: Write the scenario, rebuild, run verify.** Expected: all `PASS`.
- [ ] **Step 3: Commit** (MPP).

### Task 4: Sanitized gate on the database

**Files:** Create `MPP/tools/sales-kit/demo-db/dump_text.py`, `MPP/tools/sales-kit/demo-db/test_dump_text.py`, `MPP/sql/seeds_demo/090_sanitize_migration_data.sql`.

**Interfaces:**
- `python -I dump_text.py --db MPP_MES_Demo --out <file>`: via `sqlcmd`, lists every `nvarchar/nchar/varchar/char/ntext` column of every user table and writes `schema.table.column<TAB>value` lines for non-null values; then `check_terms.py` runs on the output folder.
- `090` rewrites the migration-seeded customer data the gate finds (0054 shipping-label ZPL address -> "Sample Components Plant, 100 Industrial Way"; 0067 ChargeToParty "Non-Specific MPP" -> "Non-Specific"; anything else the gate finds), using direct UPDATEs (these rows have no editing proc; this DB is disposable).

- [ ] **Step 1: Failing gate first:** `test_dump_text.py` runs `dump_text.py` on `MPP_MES_Demo` before `090` exists and asserts the dump contains the migration-0054 label address and the gate exits 1 (proves the dump reaches every text column, including ones no screen shows). Run -> the gate FAILS as expected.
- [ ] **Step 2: Write `090`, rebuild, run the gate.** Expected: `0 hit(s)`.
- [ ] **Step 3: Commit** (MPP).

### Task 5: Capture and sanitize tooling

**Files:** Create `MPP/tools/sales-kit/capture/package.json`, `capture.js`, `steps.js`, `MPP/tools/sales-kit/capture/sanitize.py`, `test_sanitize.py`, `substitutions.json`; `.gitignore` entries for `tools/sales-kit/captures/` and `tools/sales-kit/capture/node_modules/`.

**Interfaces:**
- `node capture.js --steps <names|all> --out CAP` (gateway `http://localhost:8088`, project `MPP`, viewport 1904x882): launches the installed Chrome via `puppeteer-core`; for each step from `steps.js` -- `{name, terminal?: code, route, actions: [{click|type|wait|evaluate}], ready: <selector or text>, viewport?}` -- selects the terminal through `/shop-floor/terminal-selector` when it differs from the session's, navigates, performs the actions with real input events, waits for `ready` and 1.5 s of no DOM mutation, then writes `CAP/raw/<name>.json` = `{w, h, route, html}` (the app root's outerHTML with input `value`s copied into attributes) and `CAP/raw/<name>.png`. Once per run it writes `CAP/raw/bundle.css`: every stylesheet the page loaded (fetched by URL), with `@font-face` and `url(...)` targets fetched and inlined as data URIs.
- `python -I sanitize.py --raw CAP/raw --out-screens KIT/deck-build/screens --out-captures KIT/demo-build/captures`: applies `substitutions.json` (ordered list of `[regex, replacement]`, case-sensitive and -insensitive entries) to every text node, attribute value and CSS `content:` string; writes `<name>.json` (sanitized) and `bundle.css` to `--out-captures`; renders each sanitized screen to `<name>.png` in `--out-screens` by loading `{bundle.css + html}` in headless Chrome at its viewport; exits non-zero if `check_terms.py` finds anything in its output or if any output contains `http://`, `https://` or `//localhost`.
- `substitutions.json` (MPP repo only) starts with: `MPP MES` -> `MES Track & Trace`; `Madison Precision Products` -> `Sample Components Co.`; `Madison Facility` -> `Sample Components Plant`; `\bLTT\b` -> `LOT ticket`; `\bAIM\b` -> `Shipping System`; `Honda` -> `customer`; `T-Out-A` / `M-Out-A` / `M-In-A` -> `TrimOut` / `MachiningOut` / `MachiningIn`. Every new gate hit is added here.

- [ ] **Step 1: Failing tests** `test_sanitize.py` (fixture HTML in the test): replaces in a text node, in `title=` and `placeholder=` attributes, inside a `display:none` element and in CSS `content:"MPP MES"`; leaves `class` names and `data-component` attributes untouched; fails the run when the output still holds `http://localhost:8088/...`; a bundle with an inlined font has no `http`.
- [ ] **Step 2: Implement `sanitize.py`; run tests** -> pass.
- [ ] **Step 3: Implement `capture.js` with one step (`terminal-selector`) and run it against the CURRENT Dev gateway into a scratch folder** to prove the mechanics (navigation, wait, DOM, bundle, PNG). Expected: PNG shows the selector; `bundle.css` has inlined fonts; then delete that scratch output (it is Dev data).
- [ ] **Step 4: Write `steps.js` for every step in the table below.** Each step's `ready` is the element the deck screenshot is about.
- [ ] **Step 5: Commit** (MPP): tooling, tests, substitutions, gitignore.

| Step name | Terminal | Route / action | Used by |
|---|---|---|---|
| `core-supervisor` | DC-T1 | `/shop-floor/supervisor` | demo landing |
| `core-pin-pad` | DC-T1 | `/shop-floor/die-cast`, operator bar sign-in, type `042` | deck 5, demo |
| `core-elevation` | DC-T1 | die cast, signed in `04218`, Release on a short basket -> elevation modal | deck 5/14, demo |
| `m1-lot-search` | DC-T1 | `/shop-floor/lot-search`, search the packed tray | deck, demo |
| `m1-lot-detail` + one per tab | DC-T1 | `/shop-floor/lot-detail/<tray>` and each tab | deck, demo |
| `m1-genealogy` | DC-T1 | `/shop-floor/genealogy`, walk tree for the tray | deck, demo |
| `m1-trace` | DC-T1 | `/shop-floor/trace` for the casting (forward) | deck, demo |
| `m1-report` | DC-T1 | `/shop-floor/reports`, LOT Detail report for the tray | deck, demo |
| `m2-diecast` | DC-T1 | `/shop-floor/die-cast`, press P-02 | deck, demo |
| `m2-trim` | TRIM-T1 | `/shop-floor/trim` | deck, demo |
| `m2-reconcile` | DC-T1 | `/shop-floor/die-cast/reconcile`, P-02 with the variance | deck, demo |
| `m3-machining-in` | L1-MIN | `/shop-floor/machining-in` (+ line inventory) | deck, demo |
| `m3-machining-out` + `-minted` | L1-MOUT | `/shop-floor/machining-out`, pick fullest casting, mint 16 | deck, demo |
| `m3-assembly` + `-locked` + `-checkin` | L1-AOUT | `/shop-floor/assembly-nonserialized`, before / at the lock / add-lot box | deck, demo |

### Task 6: The capture session (gateway switch)

**Files:** Create `MPP/tools/sales-kit/demo-db/Switch-GatewayDb.ps1`.

**Interfaces:**
- `Switch-GatewayDb.ps1 -To Demo|Dev`: `Demo` copies `config.json` to `config.json.pre-demo` (refuses if that backup exists and differs from the current file -- a previous session did not finish) and sets `connectionProps` to `databaseName=MPP_MES_Demo`; `Dev` restores the backup byte-for-byte and deletes it. After either, it asks the gateway to reload configuration (the 8.3 config scan endpoint, with the token `scan.ps1` uses) and runs `node capture.js --probe`, which opens the Terminal Selector and returns the tree's root node text; it polls until that reads `Sample Components Co.` for `Demo` or the real enterprise name for `Dev`. If writing under `Program Files` is denied, it stops and prints the two exact values for Jacques to set in the gateway web UI (Config > Databases > MPP > Extra connection properties).

- [ ] **Step 1: Tell Jacques the switch is about to happen; ask him to reset the Perspective trial.** Wait for his go.
- [ ] **Step 2: `Switch-GatewayDb.ps1 -To Demo`.** Expected: probe shows `Sample Components Co.`.
- [ ] **Step 3: `node capture.js --steps all --out CAP`.** Look at every PNG in `CAP/raw`. Re-run individual steps until each shows the intended state.
- [ ] **Step 4: `Switch-GatewayDb.ps1 -To Dev`** -- also if Step 3 failed. Expected: probe shows the real enterprise; tell Jacques the gateway is back on Dev.
- [ ] **Step 5: `python -I sanitize.py ...`; then `check_terms.py` on `KIT`.** Expected: sanitize exit 0; `0 hit(s)`. Add any hit to `substitutions.json` and re-run sanitize (no re-capture needed).
- [ ] **Step 6: Commit** (MPP: switch script; KIT: `deck-build/screens/*.png`, `demo-build/captures/*`).

### Task 7: Deck on real screens

**Files:** Modify `KIT/deck-build/build_deck.js`.

- [ ] **Step 1: Map each tour slide to its capture** (table in Task 5); replace file names; re-read each slide's title, caption and notes against the real screen and rewrite whatever describes something the real screen does not show (e.g. the trace report is the LOT Detail report on the Reports page; LOT numbers in notes use the captured ones).
- [ ] **Step 2: Rebuild; `check_deck.py` 10/10; `validate.py` passes; render via PowerPoint (only when PowerPoint is not already running); review every contact sheet; PowerPoint COM link check (tiles -> module starts, back links -> slide 6).**
- [ ] **Step 3: `check_terms.py` on KIT (standalone) -> 0; commit** (KIT).

### Task 8: Demo -- real-screen host, number formats, core screens

**Files:** Create `KIT/demo-build/src/ui/rs.js`; modify `build_demo.py` (inlines `captures/bundle.css` and each `captures/<name>.json` as `<script type="application/json" id="cap-<name>">`), `template.html` (keeps the demo chrome; app area hosts captured screens), `config.js` (number formats), `model.js` + tests (LOT/container numbering), `ui/core.js`, `ui/tour.js`.

**Interfaces:**
- `RS.screen(el, name)` -> mounts a deep clone of capture `name` into `el` and returns `{root, q(sel), all(sel)}`; captured elements are addressed by their `data-component-path` / Perspective `data-component` attributes recorded in a per-screen selector map at the top of each module file (never by position).
- `RS.text(root, sel, value)`, `RS.rows(root, listSel, rowSel, items, fill(rowEl, item))` (clones the first captured row as the template, removes the rest), `RS.show(root, sel, bool)`, `RS.on(root, sel, handler)` (delegated click), `RS.input(root, sel)` (real `<input>` kept editable, value read on action).
- Number formats: casting/basket LOTs, minted sub-LOTs, tray LOTs and containers follow the formats seen in the captures (e.g. 9-digit ticket numbers for baskets, `<parent>-NN` for minted sub-LOTs, the app's tray and container formats); model tests updated to assert the formats.
- Core: landing view = real Supervisor Dashboard capture with live tiles; PIN pad = captured sign-in popup over any screen with the keypad wired (existing `UI.signIn` logic, new markup); protected action = captured elevation modal wired to the existing `UI.requireSupervisor` logic.

- [ ] **Step 1: Failing model tests** for the number formats; implement; `node --test "test/*.test.js"` green.
- [ ] **Step 2: Implement `rs.js`, the build changes and the core screens.** Build. Browser check (served by `kit-demo`): the captured CSS applies with no request to `localhost:8088` (network list = page only); PIN pad accepts `04218`, `00000` -> Re-type/Register; elevation approve/cancel; 10x survival of a half-typed PIN and an open modal; console errors none.
- [ ] **Step 3: Side-by-side:** capture PNG vs demo screen at the same step look the same (fonts, colours, layout). Commit (KIT).

### Task 9: Demo -- module 1 on real screens

Views `lot-search`, `lot-detail` (all captured tabs; tab switching wired), `genealogy` (tree expand/collapse wired; nodes from `Model.traceBack`), `trace` (forward), `report` (Reports page with the LOT Detail report region showing the rendered report image from the capture, refreshed per LOT where the captured report shows LOT-specific values). Tour m1 and scenes rebound to the new views.

- [ ] **Step 1: Implement; build; browser check:** every m1 step at 1x and 10x lands on a valid LOT with a visible highlight; partial quantities match the model; collapsed node and active tab survive 10x; console clean; side-by-side vs captures. Commit (KIT).

### Task 10: Demo -- module 2 on real screens

Views `diecast` (press selection, cavity tiles live, open basket, release incl. the elevation path for a short basket, scrap), `trim` (queue live, check-out), `reconcile` (live rows, disposition dropdown, complete). Tour m2 and scenes rebound.

- [ ] **Step 1: Implement; build; browser check** as Task 9 plus the first kit's m2 checks (release cancel/approve, reconcile blocked then ok, dropdown survives a tick, modals safe when the sim moves first). Commit (KIT).

### Task 11: Demo -- module 3 on real screens

Views `machining-in` (line inventory dock live, scan field wired, wrong-LOT refusal), `machining-out` (FIFO queue live, pick, mint with the parent-reduced / child-created result), `assembly` (live component table, low-inventory lock with the captured add-lot box wired to check-in, complete tray). Tour m3 and scenes rebound.

- [ ] **Step 1: Implement; build; browser check** as Task 9 plus the first kit's m3 checks. Commit (KIT).

### Task 12: Verify, package, review

- [ ] **Step 1: Full first-kit verification list** (spec 2026-10-22 section 8 and the first plan's Task 10): viewports 1600x900 / 1024x768 / 700x900, iframe, `file://` via headless Chrome, all four tours at 10x with RESET mid-tour, network = page only, zero console errors, `node --test` green.
- [ ] **Step 2: Recapture the deck's demo-only scenes if any remain; rebuild the deck; Task 7 Step 2 checks again.**
- [ ] **Step 3: `check_terms.py` on KIT -> 0 (standalone); update README (real screens, how to re-capture: `Build-DemoDatabase.ps1`, switch, `capture.js`, `sanitize.py`, switch back) and the SOURCE note; commit both repos.**
- [ ] **Step 4: Whole-work review on the most capable model; fix pass; hand over both files.**
