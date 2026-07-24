# MPP MES — Project Status

> ## 🚧 OPEN TODO (deferred 2026-07-16) — Converge operation-template execution to ONE SQL methodology
>
> **Problem:** the same concept — *"for this LOT at this step, which OperationTemplate applies, then record its event"* — is implemented **five different ways** across the shop floor (view expression bindings, view Python, a Core-Python recorder, and inside a SQL proc), and two steps skip it entirely. This drift is the root of the string of *"template missing"* bugs (Trim OUT / Machining OUT / Machining IN, all fixed piecemeal 2026-07-16) and is hard to trust/maintain.
>
> **Target:** one SQL resolver `Parts.ufn_OperationTemplateForLotRole(@LotId, @RoleCode)` used by **every** execution proc (each proc knows its own role and resolves internally); Perspective/Python becomes **thin inert glue** (passes `lotId`, renders result — zero domain decisions); keep pre-flight **SQL-read gates** for UX. Matches the existing "no business logic in Python" rule — this is *enforcing* it, not a new direction.
>
> **Design decisions to make first (3 sharp edges):** (1) `ProductionEvent_Record` is generic (serves die-cast shots + Trim-IN) → give it a `@RoleCode` param, or split into per-role procs; (2) `DieCastShot` is a *named template code*, not an OperationType role → keep a legit by-code lookup, or model it as a role; (3) the two Assembly gaps — should `AssemblyIn` record an Advance checkpoint (like MachiningIn)? should `AssemblyOut` validate a ConsumeMint template (like MachiningOut)? (≥1 looks like a latent bug).
>
> **Blast radius:** 3 execution procs rewritten (`TrimOut_Record`, `MachiningOut_Mint`, `ProductionEvent_Record`) + `MachiningIn_RecordPick` aligns + 1 new function + 3 NQs + ~7 views/thin-Python stripped + **~15 SQL test fixtures** (biggest chunk — must build routes, not pass template ids). **Config side untouched.** Behavior risk low (relocating proven logic); mechanical risk moderate (tests).
>
> **How to run it:** SERIALIZE — do it on a quiet `jacques/working` as a clean sweep; it's a *poor* parallel candidate (it rewrites the exact operation procs/views the active session churns → heavy merge conflicts; gateway + `MPP_MES_Dev` are shared singletons). Full inventory + blast-radius detail: **`notes/2026-07-16_operation-template-methodology-inventory.md`**.

**Last updated:** 2026-07-24 — **Meeting-driven workstreams (2026-07-22 notes) built + the plant location model reconciled to the authoritative Site DB; `jacques/working` == `main` == `a7829b6a`. Full `MPP_MES_Test` suite 2151/0.** Six of seven meeting items shipped (**die cast HELD** pending Jacques's feedback on its spec's assumptions):
> **(1) Location reconcile** — `MPP_MES_Site` is now the authoritative location map. Regenerated the seed (`gen_locations_mpp.js` now reads `sql/seeds/_site_*.tsv` dumps) with authoritative **Names** (never renamed — codes fixed to match: RPYCAM re-key, AFIN→AOUT, 5PA MIN→MOUT/AIN, 6F9TC/COS MOUT→AOUT…), **printers only on MOUT/AOUT/COMBINED/ASER** terminals, DefaultScreen/closure(→enum, vision-through-scale→ByVision)/scanner/confirm seeded, `TRIM{1,2}-STORE` + `INSP` inspection area (66B-TC re-parented) added. Applied to **Dev in place** via `sql/scripts/reconcile_location_dev.sql` (two-phase rename preserves `Location.Id` → the 50 live LOTs + PLC reg stayed attached; old printers retired to `__OLD__`/deprecated for the downtime FK). Memory: [[project-mpp-location-authority]].
> **(2) Operator-change audit** — migration `0044` (LogEventType 75 `OperatorChanged`) + `Audit.OperatorChange_Log` + NQ + `AppUser.logOperatorChange`, wired into `InitialsEntry.loginAs` (capture old op → audit handoff, fire-and-forget). Tests 18/18.
> **(3) Assembly-OUT projected consumption (display-only, NOT a gate)** — `Workorder.Assembly_GetComponentProjection` (mirrors CompleteTray math + exact-cell pool) + NQ + `Assembly.getComponentProjection` + `view.custom.componentProjection` binding + **rendered**: `ComponentProjectionRow` instance view + flex-repeater under the components sidebar with red LOW pills. Tests 10/10.
> **(4) Combined Machining IN/OUT tabs** — new `MachiningStation` view (embeds `MachiningIn`+`MachiningOutSplit`), route `/shop-floor/machining` = the `-MIO-` terminals' DefaultScreen.
> **(5) Trim storage → Machining IN** — Trim OUT (`TrimOut_Record` v2) deposits every trimmed LOT into the local `TRIM{N}-STORE` (destination picker gone, "Shot count"→"Lot count"); `Lot_GetTrimStorageQueueForLine` shows each line the eligible Trim-Storage LOTs (two-line part on both); `MachiningIn_RecordPick` v2 **claims** (in-txn move Storage→line, race-safe no-op-COMMIT). TrimBody + MachiningIn views rewired. **Also fixed the pre-existing `0027` MachiningIn route-test failures.** Full suite 2144/0.
> **(6) Third-party inspection station** — customer-confirmed: check-out **IS assembly-out** (bought-in part = component consumed by a newly-minted pass-through FG, FG-style container config 1 lot→1 tray→1 container). Only new backend = `Lots.Lot_GetInspectionQueueByLocation` (Received-origin LOTs at station + latest result; 7/7). New `ThirdPartyInspection` tabs view: **Check In**=ReceivingDock / **Inspect**=queue / **Check Out**=AssemblyNonSerialized; route + `INSP-SORT-T1`/`66B-Ins` DefaultScreen. **⚠ Scaffold remaining:** the Inspect tab shows the queue but the dynamic **quality-capture attribute form** (render a QualitySpec's attrs → build `ResultsJson` → `QualitySample_Record`) is NOT built — first consumer of the Phase-9 capture API, a meaty form of its own.
> Design docs: `docs/superpowers/specs/2026-07-23-*` (7). Consolidated smoke test: `docs/superpowers/specs/2026-07-24-consolidated-smoke-test.md`. All Ignition views were file-authored (Designer closed) + scanned; concurrent-session file `Core/…/Location/Location/code.py` left untouched/uncommitted.

**Prior header (2026-07-20):** **Shop-floor UX polish + terminal-context refactor; all pushed to `origin/jacques/working` (through `60852585`).** Session shipped, each committed: Cell Mount Card embedded on Plant Hierarchy (Tool Config section, right of the details card, gated on `IsMountTarget`); Item Master cavity `#` ordinal removed + die-cast cavity dropdown shows number **+ description**; ContainerConfig **view-deserialize fix** (a `customMethods` param was an object — must be a plain string, or the whole view fails to load); Trim IN/OUT inventory rescoped to **LOTs residing in the terminal's zone** (role-filter band-aid removed — the earlier IN/OUT split is undone); MovementScan **"already at this location"** pre-check (disables Move when the LOT's current location == destination); plant-floor **disabled-button styling** (`:disabled` grey/not-allowed on `psc-pf-*` buttons, Core stylesheet); `Trim/InventoryRow` switched to a **flex `pf-inventory-row`** card so the Select-on-left button lays out without disturbing the shared `pf-queue-row` grid; Trim OUT **shot-count prefill** from the selected LOT's pieces. **Terminal refactor:** one `BlueRidge.Location.Terminal.applyToSession` resolver — onStartup/NavigationTree/TerminalSelector all delegate; fixes stale printer/PLC/closure/vision after a navigate and clears the cell. **Root-caused a recurring plant-floor trap:** a stale/**fallback** terminal (unregistered laptop IP) has `zoneLocationId` = the whole Madison Facility → plant-wide queue reads + false "Not eligible at destination"; the station subtitle "Madison Facility" is the tell. **DB incident:** a concurrent agent reset `MPP_MES_Dev` mid-session (Run-Tests pointed at Dev); `sql/scratch/seed_jp_validation.sql` refreshed to Jacques's rebuilt config (3 dies mounted DC1-M01..03 + routes-through-Trim/BOMs/eligibility/container-configs) as the LOT-free restore fixture; DB-safety guardrails already landed earlier today (Run-Tests → `MPP_MES_Test` default; Reset refuses `*_Dev` without `-Force`). New memories: [[mpp-terminal-session-context-and-fallback]], [[mpp-core-stylesheet-canonical]], [[ignition-view-deserialize-schema-valid-json]]. Full per-item detail: `notes/2026-07-20_working-notes.md`.**

**Prior header (2026-07-16):** — **Shop-floor bug-fix pass: route-aware operation-template lookups (Trim OUT / Machining OUT / Machining IN "template missing" fixed), die-cast→Warehouse auto-deposit, assembly insufficient-stock toast now names the short component(s), NavigationTree reusable component, Trim IN validates/deposits at the AREA. Branch reconciled with 13 concurrent-stream commits + promoted — `main` == `jacques/working` == `db4800d5`. Surfaced a bigger architectural TODO: converge operation-template execution to ONE SQL methodology (see the 🚧 TODO at the very top). Full detail in the 2026-07-16 section below + `notes/2026-07-15_working-notes.md`.**

**Prior header (2026-07-14):** **PLC integration built end-to-end (Plans 1–3) on `jacques/working`; `hunter/explore` merged in (Phase 9 quality capture).** SQL: migration `0038` (`PlcDeviceType` / `TerminalPlcDevice` / `Item.PlcId`, audit entity Id 58) + `0039` (handshake audit LogEventTypes 67/68). Ignition: 4 UDT defs + `MPP_Sim` Programmable-Device-Simulator + 22 instances (generated from one member catalog); Sim Panel `/dev/sim/plc`; Core NQs; gateway watchers (Scale / SerializedMip / NonSerializedMip / TrayInspection) + rising-edge `PlcWatcher.dispatch`; `/plc-devices` mapping editor; `onStartup` → `session.custom.plcDevices`; Item Master `PlcId` field. Full SQL reset green (39 migrations + 349 repeatables; `0039` test 2/2); `scan.ps1` clean; pushed to `origin/jacques/working` (`d5d8a332`). **Owed (only):** one folder-watch gateway Tag Change script in Designer + the simulator smoke pass — see `notes/2026-07-14_plc-commissioning-runbook.md`. Migration-collision note: the Hunter merge renumbered the PLC migration `0037→0038` (Phase 9 keeps `0037`) and bumped the `TerminalPlcDevice` audit entity Id `57→58`. Detail in the 2026-07-14 section below.

**Prior header note (2026-07-08):** **Streams converged on `hunter/explore`: main's terminal-mint model redesign (Jacques, ~24 commits — route-driven queues, `MachiningOut_Mint` consume-mint, OperatorBar, Category cascades, `seed_demo` auto-run in Reset-DevDatabase) MERGED with the 2026-07-07 smoke-findings fix pass + follow-ups (Hunter — see that stream's header note below). Merge resolutions: shared-terminal cell picker kept as a picker-only ContextBar hidden on dedicated flavors (reconciles main's ContextBar removal with the picker requirement); die-cast tally readers unified on main's `_tallyRows`; `seed_demo.sql` taken from main (mint model). Full suite + gateway scan re-run post-merge.**

> **See the `## 🔖 2026-07-14 — PLC Integration` section directly below for the full PLC writeup.**

**Prior header note (hunter/explore, 2026-07-07):** **Smoke-findings fix pass on `hunter/explore`: all 14 items from `notes/2026-07-07_smoke_findings.md` addressed (full suite 1945/1945, only the pre-existing `010_Parts_codes_crud` thrower). Per-item ✅/⚠️ annotations live in the findings file. Re-smoke owed — see the section directly below.** Prior header note (2026-07-06 second session): **Jacques 2026-07-06 meeting task list worked on `hunter/explore`: 21 of 24 items fixed, tested, committed (full suite 1934/1934, only the pre-existing `010_Parts_codes_crud` thrower). 3 items open pending live repro / Jacques's call.** Prior header note (earlier 2026-07-06):

---

## 🔖 2026-07-20 — Cell Mount Card embedded on Plant Hierarchy (Tool Configuration section)

Completed the final outstanding item of the approved `docs/superpowers/specs/2026-06-16-cell-mount-card-design.md` — the PlantHierarchy embed. The data layer, NQs, `BlueRidge.Parts.Tool` methods, and the `CellMountCard` component were all already built + tested; only the view wiring remained.

- **What:** on the Config Tool Plant Hierarchy (`/plant`, MPP_Config), selecting a mount-compatible cell (a Die Cast Machine) now shows a **Tool Configuration** card (`CellMountCard`) **to the right of** the Location Details card — mount an unmounted compatible tool (dropdown + notes + Mount) or Release the currently-mounted one.
- **How:** `LocationDetailsPanel` + an `ia.display.view` embed of `BlueRidge/Components/Location/CellMountCard` wrapped in a new `DetailTopRow` (flex row, wrap); details `grow:1 basis:0`, embed `basis:460px shrink:0`. New `view.custom.cellContext` bound to `runScript(getCellMountContextOrEmpty, {selected.id})`; embed visibility gated on `{cellContext.IsMountTarget} && {mode} != "view"` (Jacques's "mount-compatible cells only" rule); `params.cellLocationId` ← `{selected.id}`. **No backend changes** — single-file view edit + `scan.ps1`.
- **Verified live** in the Perspective client: card renders for a `DieCastMachine` cell, positioned right of the details card (bounding-box check: x=824 vs 589, same row), "No tool mounted" empty state with TOOL dropdown + Mount button. JSON valid; `scan.ps1` clean ("Project Up to Date … by external").
- **⚠️ Working-tree note (pickled-data hazard):** `PlantHierarchy/view.json` re-pickled its `sortedTree`/`tree`/`editDraft` runtime data mid-session (a concurrent Designer/gateway save). I restored HEAD and re-applied only the logical edits, so the working-tree diff is a **clean 82-line insert**. Commit it before opening this view in Designer again, or Designer will re-pickle and bloat the next diff. Not yet committed (explicit-staging convention).

---

## 🔖 2026-07-16 — Shop-floor bug-fix pass + die-cast→Warehouse deposit + branch reconcile (`main` = `db4800d5`)

Worked a live shop-floor smoke list end-to-end on `jacques/working`; reconciled with a concurrent stream and promoted to `main` (`db4800d5`). Per-item root causes in `notes/2026-07-15_working-notes.md`.

- **Operation-template "template missing" (Trim OUT / Machining OUT / Machining IN) — route-aware fix.** All three resolved the template by the *role code* (`getActiveTemplateIdByCode("TrimOut"/"MachiningOut")` in views; `WHERE Code = N'MachiningIn'` in SQL) — but template codes are `T-Out-A`/`M-Out-A`/`M-In-A`, so the lookups always returned None. Fixed: new Core helper `OperationTemplate.getActiveTemplateIdForLot(lotId, role)` (TrimBody + MachiningOutSplit); `MachiningIn_RecordPick` resolves route-aware in-proc. Die Cast already used the route-aware path. **Convention now in CLAUDE.md.** This exposed 5 divergent methodologies → **prominent OPEN TODO at the top of this doc** + inventory in `notes/2026-07-16_operation-template-methodology-inventory.md`.
- **Die-cast → Warehouse auto-deposit.** Die-cast LOTs were minted at the machine and never moved to storage (the shift-tally proc already *assumed* they had). `Lot_Create` gains opt-in `@DepositToStorage BIT`: after birth at the machine, INLINE system-move to the Warehouse (`WHSE` by code), two movement rows (born-at-machine → moved-to-storage), soft-skip if no WHSE configured. Wired through the NQ + `Lot.create` + DieCastBody opt-in. Rollback-transaction tested.
- **Assembly insufficient-stock toast now names the short component(s).** `Assembly_CompleteTray` swapped `IF EXISTS` for a `STRING_AGG` short-list (`PartNumber (need X, have Y)`).
- **NavigationTree reusable component.** Extracted the DevLauncher plant-tree into `Components/PlantFloor/NavigationTree`; the Terminal Selector (unrecognized-IP gate) now embeds the tree instead of a flat table.
- **Trim IN validates/deposits at the AREA, not a press.** Removed the press picker (dedicated-flavor pattern per FDS-02-010); Movement-Scan destination + WIP queue + subtitle bind to `session.custom.terminal.zoneLocationId`/`zoneName`; fixed a mount-order race (embed read `session.custom.cell` before `startup()` set it).
- **Merge/reconcile.** `jacques/working` was 13 behind `origin/main`; merged main **cleanly** (auto-merged the concurrent MachiningOut-queue feature + warehouse wiring + the other stream's components-at-cell / InventoryManager / ReceivingDock / LotLabel / Zebra work), verified coherent, promoted to `main` by fast-forward.

**Dev DB (`MPP_MES_Dev`) applied this session — all data-safe, NO reset (live test data preserved):** versioned `0037`/`0038`/`0039` (were unapplied — quality-capture + PLC foundation incl. `Item.PlcId`) + all 349 repeatables re-run, then the route-aware `MachiningIn_RecordPick`, `Lot_Create` warehouse deposit, and `Assembly_CompleteTray` message.

---

## 🔖 2026-07-14 — PLC Integration built end-to-end (Plans 1–3) + `hunter/explore` merged

Executed the three PLC-integration plans on `jacques/working` (spec
`docs/superpowers/specs/2026-07-10-plc-udt-terminal-mapping-design.md`; plans
`…-plc-integration-plan1/2/3-*`). Ignition file-authoring; validated against the
`MPP_Sim` simulator, not live PLCs. **Everything committed + pushed to
`origin/jacques/working` (`d5d8a332`).**

### Merge reconciliation (`hunter/explore` → `jacques/working`, `3b58ad40`)
Clean auto-merge that brought in Hunter's **Phase 9 quality capture / CRT / global
trace** (migration `0037`). Two collisions resolved:
- **Migration number:** our PLC migration `0037` → **`0038`** (file + `MigrationId`
  + test dir `0037_PlcIntegration` → `0038_PlcIntegration`). Phase 9 keeps `0037`.
- **Audit Id:** both inserted `Audit.LogEntityType` Id 57 (Hunter=`QualitySample`,
  ours=`TerminalPlcDevice`). PLC bumped to **Id 58** + Id-or-Code guard added.
- Verified: full suite on a throwaway `MPP_MES_Test` = **2087/2087**, both
  migrations apply in sequence.

### Plan 1 — SQL foundation (pre-existing + reconciled)
Migration `0038` (`Location.PlcDeviceType` fixed-seed of 4 types, `Location.
TerminalPlcDevice` thin pointer terminal→UDT-instance, `Parts.Item.PlcId`) + 8
procs (`TerminalPlcDevice_Save/_GetByTerminal/_Deprecate/_GetByInstancePath`,
`Item_SetPlcId/_GetPlcId`, `SerializedPart_Mint @SerialNumber/_GetBySerial`) +
migration `0039` (audit LogEventType 67 `PlcHandshake`, 68 `PlcLineStop`).
`GetByInstancePath` (reverse lookup) + `0039` were added in Plan 3.

### Plan 2 — UDTs / simulator / Sim Panel / NQs
**`ignition/tags/`** (import-managed, NOT scan-synced): `generate_tags.py` (one
member catalog + the device manifest → all 3 artifacts, so real UDTs and the sim
can't drift) → **4 UDT defs**, **22 instances** (`PlcDevices.json`, all → `MPP_Sim`),
**`MPP_Sim_program.csv`** (325 writeable rows). Addressing scheme locked: member
appended directly to `{BasePath}`; separator lives in `{BasePath}` (dev `<device>/`),
so one def serves sim + every real device by swapping only params. **6 Core NQs**
(all `type:"Query"`). **Sim Panel** `/dev/sim/plc` (`BlueRidge.Sim` + `ScenarioRow`)
— device dropdown, per-type control panel (incl. 18-checkbox disposition grid),
scenario tracker. Jacques imported the tags/UDTs/CSV into the gateway.

### Plan 3 — watchers + dispatch + config editor + wiring
- **Entity layer:** `Common.Util.systemAppUserId()`, `Location.TerminalPlcDevice`
  wrapper, `Parts.Item.getPlcId/setPlcId`, `Lots.SerializedPart.getBySerial` +
  `@serialNumber` mint.
- **`Workorder.PlcWatcher`:** instance-member tag I/O, rising-edge guard,
  `WriteDisplayEnabled` gating (spec §5.1), `logInterface` (FDS-01-014), and
  `dispatch(tagPath, prev, cur)` → resolve terminal → route to the per-type watcher.
- **4 watchers** (`ScaleWatcher`, `SerializedMipWatcher`, `NonSerializedMipWatcher`,
  `TrayInspectionWatcher`), pure choreography over the procs (no business logic in
  Python). SerializedMip (mint against the FIFO front LOT) and TrayInspection
  (vision `VisionPartNumber` vs `Item.PlcId`; mismatch → line-stop) are the concrete
  ones; Scale weight-persistence/coupling + NonSerialized FG/count resolution are
  **flagged commissioning hooks, not faked**.
- **Config-Tool `/plc-devices`** editor (MPP_Config) + `PlcDeviceType_List`.
- **Wiring (Designer closed, edits done in files, `06117aaa`):** `onStartup` →
  `session.custom.plcDevices`; session prop declared; **Item Master → Identity**
  gains the `PlcId` field (loads via `getPlcId`, saves via `setPlcId` — separate
  procs, so no `Item_Get/_Update` change / no INSERT-EXEC test impact).

**Verification:** full SQL reset green (39 migrations + 349 repeatables deploy
clean; `0039` test 2/2); `scan.ps1` clean.

### ⚠️ Owed — the ONLY remaining steps (see `notes/2026-07-14_plc-commissioning-runbook.md`)
1. **A4 — one gateway Tag Change script** (Designer): watch the `[MPP]PlcDevices`
   folder, body `BlueRidge.Workorder.PlcWatcher.dispatch(str(event.tagPath),
   event.previousValue, event.currentValue)`. Safe as a folder-watch because
   `dispatch` + each `handleEdge` ignore non-trigger members. (Explicit path list:
   `ignition/tags/plc_trigger_tag_paths.txt`.) NOT hand-authored — the 8.3
   tag-change resource schema + the real tag paths are import-specific.
2. **Seed ≥1 mapping** via `/plc-devices` (so `dispatch` resolves).
3. **Simulator acceptance pass** — run the `/dev/sim/plc` scenarios against the live
   watchers on `MPP_Sim` (the no-hardware acceptance gate).
4. **Hardware commissioning** (gated on plant network + driver decisions): per-device
   OPC connections, flip instance params sim→real, tick `integration_manifest.csv`.

**Flagged open decisions** (spec §5.2/§11, watcher hooks): NonSerialized FG/PieceCount
source; scale raw-weight persistence + 5G0 scale↔MIP completion coupling; the
`len(PartSN)≥6`/interlock serial rule (proc-level); tray-close bookkeeping;
line-stop-vs-formal-Hold policy; Mitsubishi series / Pro-face / OmniServer-scale
driver specifics.

---

## 🔖 2026-07-07 — Smoke-findings fix pass (all 14 items) on `hunter/explore`

Worked `notes/2026-07-07_smoke_findings.md` end to end (per-item ✅/⚠️ annotations in that file). Full suite **1945/1945**; all Ignition edits file-authored + `scan.ps1`'d.

**SQL (TDD, new/updated tests):**
- `TrimOut_Record` **v1.2** — the cap is now the **COMBINED** shot+scrap sum vs `Lot.PieceCount`, and **scrap decrements the LOT** on the move (arrives at machining with its real remaining qty). Tests `0024/040+050` updated (happy path 18+2=20; boundary sum==pieces passes; combined-over rejects).
- `Item_ListEligibleForLocation` **v2.1** — optional `@OperationTypeCode` route-role filter (same predicate as the no-template gate) + new NQ `parts/Item_ListEligibleForLocationByRole`; the **Die Cast Item dropdown is now eligibility ∩ has-DieCast-route** (and re-pulls on the header Refresh). Property-based tests in `0023/050`. Existing callers unchanged (param defaults NULL).

**Terminal Selector:** search-bar table error fixed — `filterForSelector` received `{view.custom.terminals}` as Perspective ImmutableMaps in the runScript expression (`.get()` AttributeErrors; `extractQualifiedValues` doesn't unwrap those) → JSON round-trip to plain dicts. Scan field + search bar centered (icon offset balanced with a trailing spacer; both input boxes 360px).

**Die Cast:** prefill repointed to the real **parts-per-basket** column — `Item.MaxLotSize` (repurposed as PartsPerBasket per Data Model v1.9; `DefaultSubLotQty` kept only as a dev-data fallback). Reject verified **already cavity-scoped** mechanically (rail cavity → `Lot_GetLatestForToolCavity` → newest open LOT on that cavity, tested 0022/070); RejectPanel label reworded cavity-first ("Rejecting Cavity N - charges newest open LOT ..."); **real bug fixed**: `submitCreate` classified a *typed* cavity by `int()` parse, so a typed cavity NUMBER was treated as a ToolCavityId — now classified by membership in the dropdown option ids; typed values become the manual CavityNote (D2). Scrollbar overflow pass (ContextBar, CumulativeCard, ActiveCavityCard, ToolCavityRow); both cavity dropdowns pinned `width:100%` (resize-glitch theory: transient scrollbar shrank the field; the options popup tracks field width). **Cell picker moved into the Active Cell ContextBar**, gated by a new `cellPickerEnabled` body param — DieCastShared passes true (its separate PickerBar deleted), DieCastDedicated stays pickerless.

**Trim:** new reusable `Components/PlantFloor/Trim/InventoryRow` card (Machining QueueRow styling: position / LOT / part · pcs · arrived / Good-Hold pill). IN panel's table → card repeater; OUT panel restructured to **two columns** — tappable pick list left (Select button + selected highlight, `trimLotSelected` page message), form right (scan, selected-LOT-by-name label, machining-line dropdown, shot/scrap counts, combined-cap help, Trim OUT). `activeLotName` plumbed through scan-resolve / select / submit-clear.

**LOT Detail:** history-row time fixed by moving date math to Python — new `Lot.mapHistoryInstances` precomputes `EventAtDisplay` (MM/dd HH:mm) + `EventAgo` ("3h ago"); HistoryRow's MetaLabel just concatenates (the Date serialized to a string on the repeater param hop, so `dateFormat`/`dateDiff` passed the raw value through). If the Paused tab shows the same symptom, PauseRow gets the identical treatment.

**⚠️ Open for Jacques:** (1) if cavity rejects must record with **no open LOT** on the cavity (pure machine scrap), `RejectEvent.LotId` needs a schema change — current design charges the newest open LOT for traceability; (2) weight-prefill semantics (UnitWeight × count) still assumed; (3) dev items need `PartsPerBasket` (`MaxLotSize`) populated via the Item screen for the prefill to show real values.

**⚠️ Owed — re-smoke.** Dev DB was reset by test runs — reseed (`sql/scratch/smoke_seed_phase4.sql` etc.) + **restart the gateway** before smoking. File-edited existing views this pass: TerminalSelector, DieCastBody, DieCastShared, RejectPanel, TrimBody, LotDetail, HistoryRow (+ new `Trim/InventoryRow`); Core script modules Terminal / Item / Lot also changed. Keep Designer closed on the edited views until the scan is picked up (scan already run 2026-07-07).

---

**Prior header note (main, 2026-07-07):** **Terminal-mint model redesign EXECUTED end-to-end on `jacques/working` — the rename-BOM thread is unwound; the ROUTE is now the single source of truth for terminal FIFO + part identity.** SQL fully built + validated (full suite **1887/1887**, only the pre-existing `010_Parts_codes_crud` thrower); migrations `0035` (`Parts.OperationRoleKind` Advance/OriginMint/ConsumeMint) + `0036` (drop cell-coupling); Machining OUT is a consume-**mint** (`MachiningOut_Mint`, Consumption genealogy) not a split; route-legality validation at publish; ranked eligible-FG read; `Lot_Split` demoted to exception-only; `seed_demo` + demo routes (`029`) re-authored to the mint model. Ignition NQs/scripts/**views** file-authored + scanned. Docs: Data Model updated (`OperationRoleKind` + v2.0 changelog). Spec: `docs/superpowers/specs/2026-07-07-terminal-mint-model-and-rename-bom-removal-design.md`; plans `...-plan1/2/3-*`. **Owed:** Designer smoke of the mint / route-driven-queue / ranked-FG views; FDS-06-007/05-033/06-008 prose rewrite; JP backup (`sql/scratch/seed_jp_validation.sql`) still old-model; vestigial dest-dropdown on MachiningOutSplit. See the 2026-07-07 section directly below. Prior header note (2026-07-06 second session): **Jacques 2026-07-06 meeting task list worked on `hunter/explore`: 21 of 24 items fixed, tested, committed (full suite 1934/1934). 3 items open. Designer smoke owed.** Prior header note (earlier 2026-07-06): **Spec 2 (machining/assembly plant-floor flow reconciliation) EXECUTED end-to-end on `jacques/working`. All SQL built + verified (full suite 1910/1910 green); Ignition backend + views file-authored + scanned. A4 (serialized FG-LOT) deferred by decision; M3 view-repoint deferred. Awaiting Jacques's Designer smoke of the views. See the Spec 2 section below.** Prior header note (2026-07-02):

---

## 🔖 2026-07-07 (second session) — Worked the 2026-07-06 working-notes list end-to-end

Merged `origin/main` (Hunter's `97310ac` Route-Category cascade + `7c7dffe` notes) into
`jacques/working` — clean auto-merge, no conflicts. Then worked every item in
`notes/2026-07-06_working-notes.md` (per-item resolution log at the top of that file).

- **Operation Template management (Config):** filter dropdown repointed **type → CATEGORY**
  with a one-click "All Categories" reset; **creation popup** now a **Category → Operation
  cascade** (auto-selects when a category has one type, e.g. Die Cast); selection list ordered
  **Die Cast → Trim → Machining & Assembly** (by `OperationCategory.Id`). New entity helper
  `OperationTemplate.getOperationTypesByCategory`; `search()` filters+orders by category.
- **Route steps:** dead `OperationAreaName` read removed from `RouteTemplate._mapSteps`
  (repointed onto the v4.1 proc's Category/Type). The Category→Operation route-step cascade
  itself came in with `main`'s `97310ac`.
- **`Parts.Item_Deprecate` → v3.0 CASCADE-deprecate** (the big one): deprecating a part now
  **cascade-deprecates its owned config** (RouteTemplate / Bom-as-parent / ItemLocation /
  ContainerConfig) and **blocks ONLY on a live (non-terminal, i.e. not Closed/Scrap) LOT**;
  a part used as a BomLine child in another part's BOM is neither blocked nor cascaded. Per-
  dependent audit rows + cascade counts in the Item audit NewValue. New suite
  `sql/tests/0008_Parts_Item/020_Item_Deprecate_cascade.sql` (**15/15 green**). Item Master
  deprecate now routes through a `ConfirmDestructive` cascade-warning popup (was immediate).
- **Terminal-FIFO / `CoupledDownstreamCellLocationId` note:** closed as **OBE** — already
  answered by the 2026-07-07 terminal-mint redesign (route-driven queue; coupling column
  dropped in `0036`).

**Verification:** full suite on a throwaway `MPP_MES_Test` = **1886/1887**; the single
failure (`0024/060 [WipQueue] fresh LOT in MachiningIn`) is **pre-existing + environmental**
— it resolves demo-seed rows (`6MA-M` / `MA1-FPRPY-MOUT` / `DEV`) that `Run-Tests -SkipDemoSeed`
omits, unrelated to this session. Ignition changes file-authored + `scan.ps1`'d.

**Owed:** Designer smoke of the Op-Template Category filter + cascade creation popup + the
Item Master deprecate confirm (existing-view edits, authored with Designer closed).

---

## 🔖 2026-07-07 — Terminal-mint model: rename-BOM thread unwound, route = single source of truth

**What & why.** The Machining & Assembly flow had accreted a "rename-BOM" mechanism (FDS-05-033) that minted a machined LOT at Machining IN by "consuming" a 1-line BOM. Commits `348762e`/`1e46c60` half-unwound it, leaving `HasRenameBom` as a fragile queue discriminator. This redesign removes it entirely and re-bases terminal FIFO + part identity on the **route**. Brainstormed → spec → 3 plans → executed on `jacques/working`.

**The model (spec `docs/superpowers/specs/2026-07-07-terminal-mint-model-and-rename-bom-removal-design.md`):**
- **Route is the single source of truth.** A terminal of `OperationType` role R shows LOTs whose lowest-`SequenceNumber` *pending* route step has role R. "Pending" depends on **`OperationRoleKind`** (new): `Advance` (satisfied by a `ProductionEvent`), `OriginMint` (DieCast — always satisfied), `ConsumeMint` (Machining/Assembly OUT — terminal step, stays queued until the LOT closes).
- **Model Y (mint-step placement):** the consume-mint is the **final route step of the *consumed* part**. A casting's route carries `…→MachiningIn→MachiningOut` (MachiningOut mints the SubAssembly, consuming the casting). The SubAssembly's route picks up *after* birth (`AssemblyIn→AssemblyOut`). Finished goods are the **output** of Assembly OUT and are **unrouted**.
- **Decision C:** a SubAssembly identity exists only when the line has a Machining OUT terminal (expressed purely as route authoring).
- **Consume-mint** = mint a new part-number LOT by consuming input(s) per the *produced* part's BOM (`Consumption` genealogy), derived via BOM + line-eligibility, operator-overridable. Flexible operator qty (prefill `DefaultSubLotQty`). `Lot_Split`/`Split` demoted to exception-only.

**Landed (all committed, ~24 commits):**
- **SQL** — `0035_operation_role_kind` (table + `OperationType.OperationRoleKindId`); `0036_drop_coupled_downstream_cell` (dropped `CoupledDownstreamCellLocationId` + `Workorder.MachiningOut_AutoComplete`); `Lots.Lot_GetWipQueueByLocation` v3.0 (route-driven, `@OperationTypeCode`, dropped `HasRenameBom`/`HasLineEvent`); `Workorder.MachiningOut_Mint` (replaces `RecordSplit`); route-legality validation in `Parts.RouteTemplate_Publish`; `Parts.Item_ListEligibleFinishedGoodsRanked`; `Lot_Split` header scoped exception-only; `seed_demo.sql` machining threads rebuilt on the mint (authentic cast→machined `Consumption`); **`029_seed_item_routes.sql` demo routes re-authored** to the mint model. Full suite **1887/1887** (only pre-existing `010_Parts_codes` thrower).
- **Ignition** (Core NQs + scripts + shop-floor views, file-authored + scanned) — `MachiningOut_Mint` NQ + `Machining.mint()`; `Item_ListEligibleFinishedGoodsRanked` NQ; `Lot_GetWipQueueByLocation` NQ/script `@operationTypeCode` (last arg — existing bindings unaffected); MachiningIn/MachiningOutSplit/AssemblyNonSerialized views repointed (queue roles, mint action, ranked-FG default); retired coupling PLC/NQs.
- **Docs** — Data Model: `OperationRoleKind` table + v2.0 changelog row (flags stale coupling/split prose).
- **Data preservation** — Jacques's live 4-part 5G0 config was captured to `sql/scratch/seed_jp_validation.sql` before any schema change (his Dev DB was never destructively reset; verified intact, 0 LOTs lost).

**Verified live.** A `6MA-C` casting walks the route-driven queue: fresh → `TrimIn` queue; after Trim + Machining-In events → `MachiningOut` queue (ready to mint). `MachiningOut_Mint` mints the SubAssembly with `Consumption` genealogy (12 assertions green).

**Next-session pickup / owed:**
1. **Designer smoke** of MachiningOutSplit (mint), the route-driven queues, and the Assembly ranked-FG default against a demo-seeded gateway (`Reset-DevDatabase` default seeds `seed_demo`, but note it `USE MPP_MES_Dev` — see gotcha).
2. **FDS prose** — FDS-06-007 / 05-033 / 06-008 still narrate rename-at-IN / split / coupling; Data Model `CoupledDownstreamCellLocationId` / `DefaultSubLotQty` / `RequiresSubLotSplit` prose flagged in the changelog.
3. **JP backup** (`sql/scratch/seed_jp_validation.sql`) still holds Jacques's *old-model* `5G0-c` route (ends at MachiningIn); re-author to Option A (`…→MachiningOut`; `5G0-SA`→AssemblyOut; `5G0-FG` unrouted) when he wants his Dev fixture to match.
4. Cosmetic: delete the vestigial destination dropdown on MachiningOutSplit (Designer); per-screen queue-role tuning for AssemblyIn/Serialized/Trim (left showing-all on purpose).
5. Pre-existing (unrelated) `Parts.DataCollectionField_Create` Msg 3915 thrower (`010_Parts_codes_crud`) — the suite's non-zero exit; worth a separate fix.

**Testing gotchas learned this session:** (a) `seed_demo.sql` pins `USE MPP_MES_Dev` — running it via `-d <other>` still hits Dev; validate the demo against a demo-seeded DB by copying with the `USE` swapped. (b) A throwaway `MPP_MES_Test` (`Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Test -SkipDemoSeed`) is the clean way to validate migrations/procs without touching Jacques's hand-built Dev. (c) `sqlcmd.exe` can't open Git-Bash `/tmp` paths — write temp SQL under the repo. (d) Jacques's Dev has only his 4 hand-built parts, NOT the `020` demo dataset — so `029`/`seed_demo` (demo items) can't run there; his Dev is migrations + manual config.

---

## 🔖 2026-07-06 (second session) — Jacques meeting fixes: 21 of 24 items landed on `hunter/explore`

Worked `notes/2026-07-06_jacques-meeting-tasks.md` end to end (per-item annotations live in that file). Full suite **1934/1934** after all proc changes. All Ignition edits file-authored + `scan.ps1`'d.

**Data integrity (SQL, all with new/updated tests):**
- `TrimOut_Record` v1.1 — required `@SourceLocationId` (the terminal's Trim zone) **blocks double checkout** (LOT must sit at/under the zone; after checkout it sits at the destination, so a re-scan rejects); `ShotCount`/`ScrapCount` capped at `Lot.PieceCount`. NQ + entity + TrimBody pass `session.custom.terminal.zoneLocationId`.
- `Lot_GetShiftCavityTally` v1.1 — **scrap-inclusive** (RejectEvent_Record decrements PieceCount, so rejected qty is added back per lot) + new `RejectSum` column. New tests 0022/050.
- `Lot_GetAttributeHistory` v1.2 — Movement details carry location codes + recording terminal; new **Production** and **Reject** timeline streams. New `Lots.Lot_GetScrapSummary` (+ Core NQ) feeds the LOT Detail **Total Scrap** KPI. New tests 0022/060.
- `Location_ListMachiningDestinations` v1.1 (**line-resident**) — Trim OUT destinations are the machining **production lines** (WorkCenter tier with a Machining-In cell child); checkout parks the LOT at the line. Also fixes a latent mismatch (deposit-at-MIN-cell vs Machining-In queue read at the LINE via zoneLocationId). Test 0024/060 rewritten; `smoke_seed_phase4` repointed to MA1-COMPBR.
- `Location_ListForEligibilityPicker` v1.1 — eligibility authoring at **Area + WorkCenter tiers only**; terminals/printers structurally excluded. Test 0009/050 extended.

**Die Cast entry rework (DieCastBody + RejectPanel):** the SQL-computed `ShiftShots` is now actually displayed (it was never bound — the "null"/missing shots complaint) plus a per-cavity scrap line; **no-template gate** on Create via route-role resolution (`getActiveTemplateIdForRoute(itemId, 'DieCast')`) with a red warning under the Item dropdown (parts whose routes lack a DieCast-role step are blocked — intended, but route data must carry roles); header **Refresh** button + `refreshToken` arg on the mounted-tool/shift-tally bindings (also bumped on create/reject — replaces the old direct write into a bound prop); right rail consolidated to **one card** (cavity, KPIs, reject entry, peer tally); RejectPanel shows **"Rejecting against <LOT>"** (attribution rides the active LOT's stamped cavity — flagged to Jacques that the right-rail cavity selection does NOT retarget it); item pick prefills Piece Count = `Item.MaxParts` and Weight = `UnitWeight x MaxParts` (**weight semantics assumed — confirm**).

**Trim:** IN panel shows a **Currently-in-Trim** table; OUT panel has the same inventory as a **selectable pick list** (tap sets the active LOT; scan retained); OUT submit **stays on-screen** (form clears; no LOT Detail nav); MovementScan capacity label rendered a raw backslash-u221e escape under the Eligible label — now ASCII `(no cap)` (likely the reported "null").

**Config Tool:** Routes draft-step editor **migrated off Area to OperationType roles** — its Area dropdown fed a deprecated shim returning ALL templates (Jacques's un-scoped dropdown); now Operation Type → templates-of-that-role cascade, and the **Data Collection column resolves at pick time** via new `OperationTemplate.getFieldSummary` (was blank on drafts until save+publish). No save-contract change. Terminal selector: 100-row default + live search. Create LOT popup: button spacing (no-wrap, 640px, 44px buttons). **FDS commentary stripped from all operator-visible view text** across MPP + MPP_Config (script comments kept; residual sweep zero).

**Still open (3):** (1) **cavity-this-shift over-listing** — query verified correct (every Active cavity of the mounted die, by design); either the die's cavity config has extras or Jacques expects only-ran-this-shift — needs his call; (2) **cavity dropdown resize glitch** — not reproducible statically, smoke-list item; (3) **Trim IN "null" under Eligible** — all operands isNull-guarded; the capacity-label fix is the likely culprit, confirm on smoke.

**⚠️ Owed — Designer smoke.** Dev DB was reset by test runs — reseed smoke data (`sql/scratch/smoke_seed_phase4.sql` etc.) and **restart the gateway** (stale-connection memory) before smoking: DieCastBody (KPIs incl. scrap, refresh button, gate warning, prefill, one-card rail, reject target label), TrimBody (inventory tables, line destinations, double-checkout toast, stay-on-screen), TerminalSelector (100 rows + search), ConfirmCreateLot spacing, LotDetail (Total Scrap KPI, Production/Reject rows, pause date format), MPP_Config Routes tab (role cascade + pick-time Data Collection). DieCastBody / TrimBody / Routes / DraftStepRow / RejectPanel / MovementScan / LotDetail / HistoryRow / PauseRow / TerminalSelector / ConfirmCreateLot were **file-edited existing views** — keep Designer closed on them until the scan is picked up, and expect Files-vs-Gateway prompts if a stale Designer cache exists.

---

## 🔖 2026-07-06 — Spec 2 (machining & assembly flow) executed

Executed `docs/superpowers/plans/2026-07-02-machining-assembly-plant-floor-flow.md` (in-session TDD + two parallel subagents on a second DB `MPP_MES_Ttest` for the independent read procs / MachiningOutSplit view). Branch `jacques/working`.

**SQL — done + verified (full suite 1910/1910, 0 fail; only pre-existing `010_Parts_codes_crud` throws):**
- **M1** `MachiningOut_RecordSplit` → **extract-one / partial-remainder**: `SUM(children) <= parent`, parent decremented + stays OPEN, Closes only at 0. Tests 070/075/080 rewritten (`b8a95f1`).
- **A1** migration **`0034`** `Lots.ContainerTray.FinishedGoodLotId` (BIGINT NULL FK → Lot + filtered-unique, 1:1 tray↔LOT) (`74b4687`). *(Spec 1 had taken 0032/0033, so this is 0034 not the plan's 0032.)*
- **A2** `Workorder.Assembly_CompleteTray` — mints FG LOT (tray = LOT), consumes `BOM × PieceCount` FIFO into it, attaches/auto-opens the Container, returns `ContainerFull`. **Delegates container completion (AIM + ShippingLabel) to the existing `Container_Complete`** (decision 2026-07-06 — the built `Container_Complete` hard-requires an AIM pool id for the NOT-NULL ShippingLabel, so "stub AIM + insert label" wasn't clean). Inlines all sub-mutations per the INSERT-EXEC rule. Test `092` (`a698dc9`).
- **A3** retired BOM consumption from `ContainerTray_Close` (now a thin tray-insert helper); 070 deleted, 075 → no-consume guard, 077 backward-trace rewired through the FG LOT (`115860d`).
- **I1** `Lots.Lot_GetLineInventoryByPart` (on-hand grouped part→lot FIFO, ET) (`dfe2143`, Ttest subagent).
- **K1** `Workorder.FinishedGoods_GetProducedSummary` (derived LotCount/PartCount over tray-linked FG LOTs) (`6da83b5`, Ttest subagent).

**Ignition — file-authored + scanned (⚠️ NOT Designer-smoked):**
- **A5/M3/I2 backend** — Core NQs `workorder/Assembly_CompleteTray`, `parts/OperationTemplate_GetForRouteRole`, `lots/Lot_GetLineInventoryByPart` + entity methods `Assembly.completeTray`/`getEligibleFinishedGoodsForDropdown`/`handleTrayComplete`, `OperationTemplate.getActiveTemplateIdForRoute`, `Lot.getLineInventoryByPart` (`beca0fb`, `b71225d`).
- **A6** `AssemblyNonSerialized` — Complete-Tray button now calls `completeTray` (mints FG LOT); existing Complete-Container button handles the delegated completion; persistent finished-good dropdown (shown when no container open → `completeTray` auto-opens one); container custom prop now carries `ItemId`; **Inventory** button opens the new popup (`e07a477`, `b71225d`).
- **I2** new `Components/PlantFloor/InventoryManager` popup (on-hand table + scan-to-check-in via `moveToValidated`) (`b71225d`).
- **M2** `MachiningOutSplit` reworked to a single extract-one form (parent stays open) (`0ecf900`).
- **D1** docs — FDS 1.6, Data Model 1.9u, OIR 2.20 (OI-32 closed), docx regenerated (`7c28449`).

**Deferred (documented):**
- **A4 serialized FG-LOT** — chicken-and-egg (`SerializedPart.ProducingLotId` NOT NULL at etch time vs FG LOT minted at completion); needs customer input on etch-vs-completion ordering. Note: `notes/2026-07-06_A4-serialized-fg-lot-deferred.md`.
- **M3 view repoint** — resolver + NQ are live, but the MachiningOutSplit view still uses `getActiveTemplateIdByCode` (repointing to route-role resolution would break parts whose route lacks a `MachiningOut` step until route data carries OperationTypes).

**⚠️ Owed — Designer smoke (the CLI-impossible step; run `.\scan.ps1` first, no gateway restart):** exercise AssemblyNonSerialized (complete a tray → FG LOT mints + consumes BOM; full container → Complete → ShippingLabel; FG dropdown auto-opens a container; Inventory button opens the popup), the InventoryManager popup (on-hand list + scan check-in), and MachiningOutSplit (extract a sub-LOT < parent → parent stays open; extract to zero → closes). Seed dev data via the smoke scripts; the operator session needs `session.custom.cell.locationId` + `appUserId`. A5 caveat: `getEligibleFinishedGoodsForDropdown` reuses `Item_ListEligibleForLocation` (all eligible items at the cell, not strictly ItemType=FinishedGood) — tighten to FG-only if MPP wants. AssemblyNonSerialized's `trayPosition` draft field is now vestigial (completeTray auto-assigns position).

---

**Prior header note (2026-07-02):** — **PROJECT_STATUS had drifted badly out of sync. Corrected: all Arc 2 plant-floor phases (5 Machining, 6 Assembly, 7 Hold/Sort, 8 Downtime, 9 Shipping) are in fact BUILT (SQL + Ignition views), migrations `0027`–`0029` with test suites, landed via the `hunter/explore` merge (PR #2). The one unbuilt external is AIM integration. Two design specs committed today for the operation-type restructure + machining/assembly reconciliation to the customer discovery. See the 2026-07-02 section directly below.** Prior header note (2026-06-15): (**Phase 4 fully specced — two design specs committed (SQL foundation + gateway/front-end); Phase 3 die-cast SQL reviewed, stale-base/Id-collision caught, cleaned up by the original agent + committed; Phase 3 front-end spec committed. See the 2026-06-15 section directly below.** Earlier context follows.) Prior note 2026-06-08: (**Eligibility-style config editors — backend COMPLETE + verified (SQL suite 1196/1196), Perspective UI drafted pending Designer smoke.** 3 bundled SaveAll procs (`Tools.ToolAttribute_SaveAll` hard-delete + per-DataType validation; `Tools.ToolCavity_SaveAll` insert/update-only + number-immutable + Scrapped-lock; `Parts.OperationTemplateField_SaveAll` reconcile + reactivate) + 3 NQs + entity `saveAttributesAll`/`saveCavitiesAll`/`saveFieldsAll`/typed options; Perspective UI file-authored for Attributes (type-aware) / Cavities / Assignments (inline mount, non-draft) / Operation-Template Fields + Tools & OperationTemplates parent dirty-gating; MountToCell/AddAttribute/AddCavity popups retired. Subagent-driven w/ per-task spec+quality review, commits `81f7a82`..`33b94e5` on `jacques/working`. **⚠️ Visual Designer smoke (Phase H3) NOT yet done — that is the next step; no Perspective session has exercised these views.** See Recently closed + Next Session Pickup. Also 2026-06-08: **Plant Floor (Arc 2) phased plan validated + corrected to v1.3 (MVP gaps ratified in-scope as Phase 9; migrations re-baselined to 0020-0027); task list (CSV + xlsx) generated — see Recently closed.) Earlier 2026-06-05 (**Tools Config Tool — Mount-to-Cell tool-type filter + three bug-fixes (Retire→status, NULL rank pills, "null" description) applied to `MPP_MES_Dev` but ⚠️ UNCOMMITTED in working tree; eligibility-style config-editor redesign brainstormed + spec'd + committed `7f41a2d`, implementation NOT started; Data Model → v1.9o. See today's Next Session Pickup + Recently closed.**) **Also 2026-06-05 (parallel session):** re-enabled the 13 legacy-seed-coupled SQL tests via dynamic location lookups (suite **1165/1165**); ran an Ignition entity-script code-review pass and applied buckets 1–3; fully configured demo item **5G0** across every Item Master tab; fixed the Routes-tab StateBadge undeclared-custom-prop error and codified a new "pre-declare bound custom props" convention. Earlier — 2026-05-29 (**Quality Spec Config Tool — built (Phases A–H) AND smoke-tested + polished; functional end-to-end.** Backend: migration 0017, 3 net-new procs, readable-audit on all quality procs, **SQL tests 1161/1161**; 14 NQs; entity script; `/quality-specs` master-detail screen + `QualitySpecAttributeRow` + `NewSpecModal` + route/nav + Item Master cross-nav. Smoke fixes landed today: spec library + Version History converted table→flex-repeater (legible, no squish/mojibake); `numeric-entry-field` component fix; `Lower≤Target≤Upper` save validation (proc-enforced); left-list refresh after publish/etc.; hide UOM/Target/Lower/Upper on non-Numeric attrs (meta.visible); `+ New Version` clones the *selected* version; date-resolved per-version state **Active/Scheduled/Superseded** (SQL `ListBySpec.State` + `GetActiveForSpec` tiebreaker) surfaced in dropdown + history pills. Also earlier today: audit-readability refactor COMPLETE (Slices 1–8 + 2.5). Two visual smokes still pending: the ConfigChangeDetail color-diff (Slice 2.5) and the new Quality state badges.)

---

## 🔖 2026-07-02 — Status doc reconciled to reality + customer-discovery design (operation-type restructure + machining/assembly reconciliation)

**Two things happened: (1) discovered PROJECT_STATUS was badly stale, (2) brainstormed + specced the customer's machining/assembly discovery into two committed specs.**

### The stale-status correction (ground truth is the code, not this doc)
Grounding for the design work (5 read-only subagent passes over SQL + Ignition + FDS + Data Model) revealed that **all Arc 2 plant-floor phases are already built**, not just through Phase 8 as this doc implied:
- **Migrations `0027` (Machining), `0028` (Assembly + Container/Tray/Serial/ShippingLabel/AIM pool), `0029` (Hold/Sort/Shipping/AIM)** — each with a full `sql/tests/00{27,28,29}_*` suite.
- **Procs:** `MachiningIn_PickAndConsume`, `MachiningOut_RecordSplit`, `MachiningOut_AutoComplete`, `Assembly_ScanIn`, `ConsumptionEvent_RecordWithBomCheck`, `ContainerTray_Close`, `Container_Open/_Complete/_Ship`, `ContainerSerial_Add`, `Location_ListMachiningDestinations`, `Item_ListEligibleForLocation`, plus Hold/Sort/Shipping procs.
- **Ignition views:** `MachiningIn`, `MachiningOutSplit`, `AssemblyIn`, `AssemblyNonSerialized`, `AssemblySerialized`, `HoldManagement`, `ShippingDock`, `SortCageWorkflow`, `ReceivingDock` (+ Dedicated/Shared/Body triads for DieCast/Trim).
- Landed via the **`hunter/explore` merge (PR #2)**. **AIM integration is the one unbuilt external.** Designer-smoke status of the newest views was **not** independently verified this session.
- ⚠️ **Older sections of this doc below are pre-`hunter/explore` and describe phases as unbuilt/pending that are now built. Trust the code + test suites over the older narrative until a full rewrite is done.**

### Customer discovery + two design specs (committed on `jacques/working`)
Customer walkthrough (2026-07-01/02) of the machining/assembly lines drove a design session (brainstorming → grounding → specs). Key model decisions: **route vs BOM separation**; operation templates become **area-agnostic, classified by a new `OperationType` role** (terminals resolve the right template by role, not by Area); **machining-out = extract-one sublot** (parent stays open — executes pending UJ-03); **assembly-out mints a finished-good LOT (tray = LOT)** consuming `BOM × PieceCount` FIFO while **retaining the Container** as wrapper (future RFID + pending AIM); **tray ↔ LOT is 1:1**, container holds 1→n trays; reusable **line inventory check-in popup**.

- **Spec 1** `docs/superpowers/specs/2026-07-02-operation-type-model-restructure-design.md` (commit `2fa35e8`) — drop `OperationTemplate.AreaLocationId`, add `OperationTypeId` FK → new `Parts.OperationType` (8 roles) + `Parts.OperationCategory` (3 groups). Full change inventory (migration + backfill, 6 procs, 4 NQs, entity script, 2 Config-Tool views, tests, FDS/Data-Model edits). Config-vs-dev tagged. **Decisions D1–D3 resolved by Jacques: OperationCategory = table; both tables fixed-seed; the 3 part-specific template→role mappings confirmed.** **Implementation plan next (writing-plans).**
- **Spec 2** `docs/superpowers/specs/2026-07-02-machining-assembly-plant-floor-flow-design.md` (commit `bfea396`) — **reconciliation deltas** onto the built Phase 5/6 (keep/change/add): machining-out extract-one, `Assembly_CompleteTray` orchestrator (mint FG LOT + consume BOM FIFO + manage container), `ContainerTray.FinishedGoodLotId`, persistent finished-good dropdown, inventory popup, finished-goods KPI. 5 open decisions (D1–D5) in §11. **⏳ Jacques still reviewing Spec 2.**

**Next session pickup:** Spec 1 implementation plan (in progress); Spec 2 pending Jacques's review of the §11 decisions; a full PROJECT_STATUS rewrite to reflect the post-`hunter/explore` built state is owed.

---

## 🔖 2026-06-17 — Arc 2 Phase 8 (Downtime + Shift Boundary) built end-to-end (SQL + 4 views), pending Designer smoke

**Built on `hunter/explore`** (fast-forwarded from current `main`/`f14b305`). Spec + plan committed today (`docs/superpowers/specs/2026-06-16-arc2-phase8-downtime-shift-design.md`, `docs/superpowers/plans/2026-06-16-arc2-phase8-downtime-shift.md`).

- **SQL — migration `0026`:** `Oee.DowntimeEvent` table + `DowntimeReasonCode.StandardDurationMinutes` delta + `Break` reason type/codes seed + audit seeds. Procs: `DowntimeEvent_Start`/`_End`, `DowntimeReasonCode_Assign` (B7 late-binding), `EndOfShiftEntry_Submit` (FDS-09-013), `DowntimeEvent_GetOpenByLocation`, `Lot_GetInProcessByLocation`, `ShiftHandover_Acknowledge`, `DowntimeEvent_GetOpenSummary`. **SQL suite 1629/1629.**
- **Ignition:** `BlueRidge.Oee.DowntimeEvent`/`Shift`/`DowntimePlc` scripts + oee NQs (all Core); **4 plant-floor views in MPP** — Downtime Entry (smoked working end-to-end), End-of-Shift Time Entry, Shift-End Summary, Supervisor Dashboard — + routes (`/shop-floor/{downtime,end-of-shift,shift-summary,supervisor}`); `DowntimePlcWatcher` gateway timer (sim-ready, no-op until `_WATCH` configured at commissioning); **toast listener** wired into the MPP session (`Core/Components/NotifyHost` + `Toast` view copied to Core + hidden overlay dock).
- **Decisions/divergences:** breaks as fixed reason codes w/ uniform durations (**OI-37** raised); manual downtime defaults to `Operator` source; ET reads `CAST … AS DATETIME2(3)`.
- **Debugging lessons (memories added):** Perspective `bidirectional` must be **inside** binding `config`; a raw `datetimeoffset` return breaks the Ignition JDBC read (cast to `DATETIME2(3)`); plant-floor `pf-*` design system ≠ Config-Tool `screen-active`/`btn`.

**Pending:** Designer smoke of End-of-Shift / Shift-End Summary / Supervisor Dashboard (Downtime Entry already verified working); dashboard Paused-LOTs + Shift-Availability tiles are stubs (need aggregate reads / OEE calc — AIM + Print-Failure tiles are legitimately Phase 7); End-of-Shift ±15-min window-gating not wired (always visible); confirm MPP break durations (OI-37). Not yet pushed to remote; OIR `.docx` regen pending.

---

## 🔖 2026-06-16 — Phase 4 (Movement + Trim + Receiving) BUILT end-to-end (SQL green; Ignition file-authored, Designer-smoke owed)

Plan: `docs/superpowers/plans/2026-06-16-arc2-phase4-movement-trim.md` (writing-plans from the two 2026-06-15 specs). Executed hybrid: SQL inline TDD; the 3 views via parallel subagents; convergence (routes/scan/commit) in-session. All on `jacques/working`.

**SQL — complete + green (full suite passes; both Phase 4 suites green):**
- Migration `0024` (audit LogEventType 34 `TrimCheckpointRecorded` reserved / 35 `TrimOutRecorded`) + seed `024` (Trim IN/OUT OperationTemplates, no fields, bound to Area `TRIM1`).
- **6 net-new procs:** `Parts.ItemLocation_CheckEligibility`, `Parts.Item_GetMaxParts`, `Lots.Lot_GetCellLineQuantity`, `Lots.Lot_GetWipQueueByLocation` (Phase 5 FIFO consumer), `Lots.Lot_MoveToValidated` (eligibility FDS-02-012 + MaxParts OI-12 + B2, inline move), `Workorder.TrimOut_Record` (closing checkpoint + whole-LOT move, no split). `Lot_MoveTo`/`Lot_Create` reused untouched. Suite `0024` = 39 assertions.
- Migration `0025` (label dispatch): `LotLabel.DispatchedAt` + LogEventType 36 `LabelDispatched`; `@PrinterName` added to `LotLabel_Print`/`_Reprint`; new `LotLabel_RecordDispatch`; new `Location.Terminal_GetPrinter` read. Suite `0025`.
- **Migration numbers consumed: `0024` + `0025`.** Phase 5 (Machining) renumbers to **`0026`+**.

**Ignition — file-authored + scanned (NOT Designer-smoked):**
- **13 Core NQs** (the 6 movement/trim + `LotLabel_Print`/`_Reprint`/`_RecordDispatch` + `Terminal_GetPrinter` + `Audit_LogInterfaceCall` + `LabelTypeCode_List`/`PrintReasonCode_List`).
- **Entity scripts:** new `Parts.ItemLocation`, `Workorder.TrimOut`, `Lots.LotLabel` (synchronous raw-TCP 9100 ZPL dispatcher + InterfaceLog-every-attempt + fail-fast + default Primary/Initial id resolution); extended `Parts.Item` (getMaxParts/getForDropdown/getByPartNumber), `Lots.Lot` (moveToValidated/getCellLineQuantity/getWipQueueByLocation/getByName), `Location.Terminal` (getPrinter).
- **`onStartup`** resolves the terminal's child Printer into a declared `session.custom.printer`.
- **3 views:** `Components/PlantFloor/MovementScan`, `Views/ShopFloor/TrimStation` (tabbed IN/OUT), `Views/ShopFloor/ReceivingDock` (parallel-subagent authored). Routes `/shop-floor/trim` + `/shop-floor/receiving` added.

**⚠️ Owed / carry-over:**
1. **Designer smoke** (the one CLI-impossible step) — exercise all 3 views in a Perspective session. Run `.\scan.ps1` first — **no gateway restart** (new Core NQs register for inherited visibility on scan; the old "restart required" note was false, corrected 2026-07-02).
2. **HomeRouter tiles** for Trim/Receiving — deferred (editing the existing HomeRouter `view.json` is the file-edit boundary → do in Designer). Routes are directly navigable now.
3. **Hardware-gated:** real Zebra LTT print is a deployment gate (raw TCP to networked printers only). Dispatch verifiable via a local socket listener / Labelary.
4. **TrimStation IN-tab checkpoint** (`ProductionEvent.record` for `TrimIn`) is TODO'd (no counter inputs wired yet); "Record scrap"/"Correct piece count" buttons present but disabled. The IN-tab MOVE works.
5. **TrimStation OUT destination dropdown** uses the generic all-cells list (`getCellsForDropdown`) — includes terminal/printer-kind cells; a Machining-line-scoped read would be tighter.
6. **Smoke seed** `sql/scratch/smoke_seed_phase4.sql` not yet written (owed with the Designer smoke).

**🚩 Pre-existing branch blocker (NOT Phase 4 — for the Phase 3-deltas owner):** `Parts.DataCollectionField_Create` (still v2.0) doesn't supply `DataTypeId`, but deltas migration `0023` made `DataCollectionField.DataTypeId` NOT NULL → every DataCollectionField create throws (surfaces as Msg 3915 under INSERT-EXEC in `0007_Parts_codes/010`). Needs a `@DataTypeId` path on Create (+ likely Update) + a required-vs-default decision. I fixed the companion stale-temp-table (Msg 213) in that test, but did not touch the Create proc. Until resolved, the full suite shows one throwing file (all 1602 assertions still pass).

---

## 🔖 2026-06-15 — Phase 3 SQL cleaned up; Phase 4 fully specced (next: writing-plans on Spec 1)

**Phase 3 (die cast) — SQL cleaned up, front-end spec in.** Reviewed the Phase 3 die-cast SQL (built by a parallel agent in a worktree): caught that it was authored on a **stale base** (branched before Phase 2's `0021`), giving a hard **audit-Id collision** (`0022` reused LogEventType 29/30 + LogEntityType 42/43 already taken by `0021`). The original agent rebased + re-reconciled; the cleaned build is committed (`f619326`) — post-cleanup `0022` uses LogEventType **32/33**, LogEntityType **45/46**. The Phase 3 front-end design spec is committed (`2276bbf`). Secondary review findings still worth folding into the Phase 3 front-end build: the dropped `@EventAt` param vs the NQ that passes it; the TOCTOU race on the reject quantity check; `ProductionEvent_ListByLot` / `DataCollectionField.DataType` gaps. Phase 3 front-end is the *other* agent's to wrap.

**Phase 4 (Movement + Trim + Receiving) — two design specs written + committed on `jacques/working`:**
- **Spec 1 — SQL foundation** (`docs/superpowers/specs/2026-06-15-arc2-phase4-movement-trim-sql-design.md`, `29310e1`): migration `0023` (audit seeds, LogEventType 34/35) + seed `023` (Trim OperationTemplates, no fields) + **6 net-new procs** (`ItemLocation_CheckEligibility`, `Item_GetMaxParts`, `Lot_GetCellLineQuantity`, `Lot_GetWipQueueByLocation`, `Lot_MoveToValidated`, `TrimOut_Record`) + the `0023` test suite. Receiving reuses `Lot_Create` (vendor lot + serial range already shipped). **Decision:** server-authoritative `Lot_MoveToValidated` (eligibility + MaxParts enforced in the proc) + advisory reads. Confirms: drop `ReceivingScan`, no MaxParts at TrimOut, no data-collection fields on Trim templates.
- **Spec 2 — gateway + front-end** (`docs/superpowers/specs/2026-06-15-arc2-phase4-gateway-frontend-design.md`, `4770efc` + `2434491`): **synchronous** LTT ZPL dispatch (raw TCP 9100 → networked Zebra; GX420d Ethernet variant validated), resolved from `session.custom.printer` (an `onStartup` extension), every attempt logged to `Audit.InterfaceLog` via the existing `Audit_LogInterfaceCall`; **print failure never rolls back the LOT** (retry via the existing `LotLabel_Reprint`). Small label SQL delta in migration `0024` (`@PrinterName` on Print/Reprint + `LotLabel.DispatchedAt` + `LotLabel_RecordDispatch`). Reusable **Movement Scan** component, one **tabbed Trim Station** view (IN/OUT), **Receiving Dock**; Core NQs + entity scripts + routes. **New convention:** FDS-02-009 "scan or dropdown" inputs = one `ia.input.dropdown` with `allowCustomOptions:true` (memory `feedback_ignition_scan_or_dropdown_allowcustomoptions`).

**Next session:** `writing-plans` on **Spec 1** (buildable first; Spec 2 depends on its procs), then build. Both specs are awaiting Jacques's read.

### ⚠️ Phase 3 spec-agent addendum (2026-06-15, parallel session) — read before building Phase 3/4

A second agent produced the **Phase 3 SQL-deltas spec** + baked the Phase 3 FE decisions (D1–D5) in, codified the ET convention, and landed the Phase 2 LOT-view smoke fixes. Fold these into writing-plans/build:

- **✅ Migration collision RESOLVED 2026-06-16.** Numbers claimed across all three specs: **Phase 3 SQL-deltas = `0023`** (`docs/.../2026-06-15-arc2-phase3-sql-deltas-design.md`), **Phase 4 movement/trim = `0024`** (renumbered from `0023`; seed `024`, tests `0024_PlantFloor_Movement_Trim`), **Phase 4 label dispatch = `0025`** (renumbered from `0024`). Both Phase 4 specs were edited in place — the Phase 4 agent reads the corrected numbers. Audit-Id high-water unaffected: Phase 3 deltas `0023` adds NO LogEventType/LogEntityType; Phase 4 `0024` adds LogEventType 34/35; Phase 4 `0025` adds LogEventType 36. Phase 5 (Machining) renumbers off its old `0024` earmark to `0026+`.
- **Phase 3 SQL-deltas spec RESOLVES the "gaps" listed above as open:** adds `Parts.DataCollectionField.DataType` (new `Parts.DataCollectionFieldDataType` FK code table + backfill + `DataCollectionField_List` returns it), the `Workorder.ProductionEvent_ListByLot` read proc, optional `Lot_Create @LotName` (D4 forward-compat — mint stays default), and the `@CavityNote` no-active-cavity path (D2 — stored in the legacy `Lot.CavityNumber`). The secondary-review `@EventAt`-param + reject-TOCTOU findings are NOT in this spec — still fold them into the build.
- **Phase 3 FE spec decisions baked in (D1–D5)** + reconciled with the SQL-deltas spec (commits `aadbc0b`, `5ae57d9`): mockup two-column layout (NO tabs), cavity dropdown w/ `allowCustomOptions:true` free-entry, rapid cavity-peer logging, scanned-LTT mint-default + one-line flip, DataType-driven field typing. Field codes corrected to **`GoodCount`/`BadCount`** (there is no `ShotCount`/`Good`/`Bad` DataCollectionField — `ShotCount`/`ScrapCount` are typed `ProductionEvent` columns); reject proc uses **`@Quantity`** + `@ChargeToArea NVARCHAR(100)`.
- **⏳ Pending MPP (expected this morning, 2026-06-16):** is the pre-printed LTT # the canonical LOT id? **Yes** → flip `Lot.create` to pass `lotName=scannedLtt` (one line; the `Lot_Create @LotName` seam is already specced). **No** → server mint stays. Either way no rebuild.
- **ET timestamp convention codified** (CLAUDE.md § SQL design, commit `58655dc`): all displayed timestamps are ET (store UTC, convert at the read boundary via `AT TIME ZONE`). **OI-36** (OIR v2.19) tracks the refactor sweep — apply the ET conversion to every NEW Phase 3/4 read proc (`ProductionEvent_ListByLot.EventAt`, Movement/WIP reads, etc.).
- **Phase 2 LOT-view smoke fixes landed + pushed** (commits in the `f619326`..`2276bbf` batch): flex-repeater row sub-views relocated to `Components/PlantFloor/...` (Ignition can't register a view nested under another view), `ia.container.tab` for LOT Detail tabs, path-param route `/shop-floor/lot-detail/:lotId`, LOT Search default-Top-200 + Reset + Vendor column + `StatusPill` cell-view, history-timeline enrichment (pause/genealogy/label/reason streams, ET). Seed dev data via `sql/scratch/smoke_seed_phase2.sql`. The throwaway `PausedDemo` page was deleted (the `PausedLotIndicator` component stays for real embedding).

---

## ✅ Closed 2026-06-11 — Eligibility-style config editors signed off (was: Designer-smoke pickup, 2026-06-08)

**Jacques closed this out 2026-06-11** — the eligibility-style editors are accepted and the Phase H3 Designer-smoke obligation is retired. Original pickup detail retained below for reference.

**The eligibility-style config editors are built: backend COMPLETE + verified, Perspective UI drafted.** Plan at `docs/superpowers/plans/2026-06-08-eligibility-style-config-editors.md` executed via subagent-driven-development on `jacques/working` (commits `81f7a82`..`33b94e5`). SQL suite **1196/1196**; every Ignition resource scanned clean. **Nothing has been visually smoked yet — that is the entire remaining task.**

**Next step: Designer smoke (plan Phase H3).** Open a Perspective session and exercise each surface:
- **Tools → Attributes** (`/tools`): edit a value → `●` dirty + Save/Discard appear; Save persists + clears dirty + toasts; Discard reverts; `+ Add` picks a Definition and the value input matches its DataType (String text / Integer+Decimal numeric / Boolean checkbox / Date picker); `×` hard-deletes on Save; switching tools/tabs while dirty raises ConfirmUnsaved. Confirm `+ New definition` still opens `AddAttributeDefinition`.
- **Tools → Cavities**: add cavity (Active), set status via dropdown, Save; saved-Scrapped row is locked/dimmed; number read-only on existing rows; empty save does NOT delete cavities.
- **Tools → Assignments**: inline cell dropdown (compatible cells only); Mount mounts immediately + toasts + history/banner update; Release works; NO dirty-gating from this tab; MountToCell popup is gone. **Eyeball the active-mount banner** (the `coalesce`→`if(isNull,…,toStr)` defensive fix landed, but confirm AssignedAt renders cleanly — date formatting on the banner wasn't specced).
- **Operation Templates → Fields**: add field via dropdown, toggle Required, remove, Save; switching template/version while Fields dirty raises ConfirmUnsaved.
- **`/audit`**: confirm `Audit.ConfigLog` rows for each save carry the `<SUBJECT> · <Attributes|Cavities|Fields> · <action>` narrative + resolved-FK Old/New JSON.

**Known caveats for the smoke (all file-authored without a Perspective session, so expect to iterate in Designer):**
- The Tools + OperationTemplates **parent views were file-edited** (the view-edit-boundary risk was explicitly accepted). Watch for Designer "Files vs Gateway" reconciliation prompts; the diffs were clean structural deltas (~100–220 lines, no pickle).
- Entry-field inputs (numeric/date) commit on `dom.onBlur`; dropdowns/checkboxes on `onActionPerformed` — verify commits fire.
- Tab gating uses the ItemMaster tab-objects `disabled`-when-dirty model (`toolTabObjects`), not a click-intercept.
- Two unverified-design assumptions worth confirming: the `toolTypeId` lazy lookup on the Attributes `+ New definition` click, and the `_applyFieldChange` `"CODE - Name"` label split populating new-row Code/Name.

**After smoke passes:** merge `jacques/working` → `main` when ready. If smoke surfaces fixes, they're Designer edits to the drafted views.

**Migration-number heads-up:** `0018` is now taken by the Arc-1 tooltype-compat migration above. The Data Model header / Arc-2 plan had *planned* a Phase-5 `0018` for the OperationTemplate sub-LOT-split ALTER — that future Arc-2 migration must renumber to `0019+` when it actually builds (Arc 2 is OI-35-gated, unbuilt).

**Carry-forward (still owed from 2026-05-29, non-blocking):** the two Quality visual smokes below (state badges + ConfigChangeDetail color-diff).

**Carry-forward from the 2026-06-05 hardening session (non-blocking):**
- **Visual eyeball owed:** demo item **5G0** is now fully configured — open `/items` → 5G0 and confirm every tab renders (Identity, Container Config, Routes w/ OT data-collection fields, BOMs, Quality Specs w/ attributes, Eligibility). Also confirm the Routes-tab StateBadge no longer errors with no version selected (the custom-prop fix).
- **Offered, not done — sibling custom-prop audit:** apply the Routes `getXOrEmpty` + pre-declared-custom-props pass to the other versioned editors (**BOMs**, **QualitySpecs**) — they bind header/version props the same way and likely carry the same latent "binding returns None into a nested read" error. See `feedback_ignition_predeclare_bound_custom_props`.
- **Code-review items deferred by design** (pushed back with reasoning, left as-is): #3 DowntimeReasonType "(Unassigned)" vs "All Types" dropdown (both `value:None` — needs a proc + Designer view change to fix properly); #9 `Location.eligibleTypes` Python tier filter (5 static rows, backstopped by the SaveAll proc); #11 RouteTemplate `"Route v1"` default name. Revisit only if desired.

---

## 🔖 Next Session Pickup — Quality Spec Config Tool is functional; small polish + two visual smokes

**State of play.** The Quality Spec Config Tool is **built and smoke-tested end-to-end** (Phases A–H + a day of polish fixes — see Last-updated + Recently-closed). All committed locally; push at session start if not already pushed. Nothing blocking.

**Two visual smokes still owed** (need a Perspective session — quick eyeball):
1. **Quality state badges** — `/quality-specs`: with two published versions (one effective-now, one future-effective), confirm the dropdown + Version History show **Active / Scheduled / Superseded** with the right colors.
2. **ConfigChangeDetail color-diff** (Slice 2.5) — `/audit` → click a row → confirm the Changes block renders with color (green/red/yellow).

**Small known follow-ups (non-blocking, all in `BlueRidge/Views/Quality/QualitySpecs` + components):**
- `badge-warn` class doesn't exist in the stylesheet; `SpecListRow` and the main `StateBadge` still use it for the Draft pill (renders unstyled). Standardize on `badge-draft`. (VersionHistoryRow already fixed.)
- `QualitySpec_Get` doesn't SELECT `DeprecatedAt`, so the header can't show a deprecated badge (library already hides deprecated specs). One-line SQL add + widen any `INSERT-EXEC` scratch table that calls it.
- Both `/quality-specs` and `QualitySpecAttributeRow` view.json are Designer-expanded; expect format churn on Designer saves (not a bug).

**After that — next major work** (pick per priority): the OI-35 architecture gate still blocks Arc 2 Phase 1 SQL; other Config Tool surfaces (Tools master) remain; or whatever the customer prioritizes.

---

### (superseded) Build the Quality Spec Config Tool (audit refactor is DONE)

**State of play.** The project-wide audit-readability refactor is **complete across all 8 slices + 2.5**. Every audit-writing proc now emits the `SUBJECT · CATEGORY · ACTION` narrative `Description` + resolved-FK `OldValue`/`NewValue` JSON. **SQL tests 1136/1136.** Slices landed:

| # | Slice | Procs | Status |
|---|---|---|---|
| 1 | Convention + UI + popup fix | — | ✅ 2026-05-28 |
| 2 | Eligibility (reference impl) | `ItemLocation_SaveAllForItem` | ✅ 2026-05-29 |
| 2.5 | ConfigChangeDetail diff highlighting | `Common.Util.prettyJsonDiff` + popup | ✅ 2026-05-29 |
| 3 | BOMs | `Bom_*` (6) | ✅ 2026-05-29 |
| 4 | Routes | `RouteTemplate_*` (6) | ✅ 2026-05-29 |
| 5 | Item core (Identity + ContainerConfig) | `Item_*`, `ContainerConfig_*` (5) | ✅ 2026-05-29 |
| 6 | Plant Hierarchy | `Location_*`, `LocationAttribute_Set` (6) | ✅ 2026-05-29 |
| 7 | LocationTypeEditor | `LocationTypeDefinition_*` (2) | ✅ 2026-05-29 |
| 8 | Downtime + Defect codes | `DowntimeReasonCode_*`, `DefectCode_*` (6) | ✅ 2026-05-29 |

**⚠️ One visual smoke still pending (Slice 2.5).** The ConfigChangeDetail popup's new **Changes** block uses `ia.display.markdown` (`props.markdown.escapeHtml=false`) bound to `Common.Util.prettyJsonDiff`, which emits HTML `<div>` lines colored green/red/yellow. Open `/audit` → click any row → confirm the diff renders **with color**. If 8.3's markdown sanitizes inline `style` attributes, the +/−/~ symbols still convey the diff (graceful degradation) and it's a one-line revert to the dual-block-only render. Helper + popup are scanned/live; the dual Old/New JSON blocks were kept below the diff for the full unabridged snapshot.

**Convention reference for new procs.** Use `Audit.ufn_MidDot()` for the separator and `Audit.ufn_TruncateActivity()` for the 500-char cap. Resolve every FK to a `{Id, Code, Name}`-style sub-object via `JSON_QUERY((... FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))` — a **bare** aliased `FOR JSON` subquery double-encodes as an escaped string. Strip trailing separators with `LEFT(x, DATALENGTH(x)/2 - 2)`, never `LEN()`-based. Render `BIT` diffs as `true`/`false` words. Keep test fixtures' free-text names off tokens other tests grep for (e.g. avoid `'SaveAll'` in a Description — it cross-contaminates `02_audit_readers/050_ConfigLog_List.sql`'s `@DescriptionLike` filter).

**On resume — build the Quality Spec Config Tool.** Spec `docs/superpowers/specs/2026-05-28-quality-spec-config-tool-design.md`, plan `docs/superpowers/plans/2026-05-28-quality-spec-config-tool.md` (9 phases / ~18 tasks, SQL-first). The Quality SQL layer is already built (migration `0008` + ~20 procs); this is mostly Ignition front-end + a contained SQL delta (migration `0017` adds `QualitySpecAttribute.UomId` FK). Audit rows are designed to the readability convention from day one. Front-end mirrors the BOMs versioned-editor impl in a standalone `/quality-specs` master-detail shell.

> **Build heads-up for the quality-spec plan:** the plan (written before Slice 1 landed) inlines `NCHAR(183)` in its audit-prose blocks — use the deployed `Audit.ufn_MidDot` + `Audit.ufn_TruncateActivity` helpers instead for consistency with the refactored procs.

**Other open Ignition items not blocking the above:**
- Phase 7 QualitySpecs cross-nav — **now folded into the Quality Spec Config Tool plan** (Phase H: "Go to spec →" navigates to the new standalone `/quality-specs` screen). No longer a standalone task; the cross-nav needs the standalone screen as its target.
- DieCastMachine Cell read-only mounted-Tool status panel — deferred until Tools master Config Tool surface exists.
- Orphan Draft BOM rows in dev DB from pre-fix `+ New Version` clicks may still need a manual cleanup pass.
- OI-35 Architecture Decision Gate still gating Arc 2 Phase 1 SQL build (independent of any Ignition work).

---

---

## 🆕 Item Master design convention update (2026-05-20)

The Item Master design has been **reworked from bundled-editDraft + bidi-Object-param to per-section ownership** before any Phase 3+ implementation lands. Each of 6 sections (Identity + 5 tabs) now owns its own selected/editDraft locally, has its own Save/Discard, and broadcasts dirty state via `sectionDirtyChanged` page-scoped messages. Parent aggregates flags + gates tab/item switches via the existing ConfirmUnsaved popup.

**Why:** R1 (bidi Object-param round-trip) was never proven and Phase 2's wiring drifted from the original design. Per-section ownership uses primitives the project has shipped reliably (page-scoped messages) and aligns with how the customer's roles actually work (different engineers own different concerns).

**Canonical reference:** `project_mpp_item_master_pattern` memory (2026-05-20 rev).

**Docs realigned:**
- `docs/superpowers/specs/2026-05-20-item-master-phase4-design.md` + plan — **rewritten** for per-section.
- `docs/superpowers/specs/2026-05-20-item-master-boms-design.md` + plan — **medium retrofit** flagged via §0 convention-reconciliation preamble (most of spec stands).
- `docs/superpowers/specs/2026-05-20-item-master-routes-design.md` + plan — **light retrofit** (Routes already designed for per-section; convention ratifies it).

**Phase 1 + 2 code:** parent's old bundled `editDraft` and `selected` blocks are inert (never properly populated for ContainerConfig); they get demolished as part of Phase 4 Task 5.

---

## ✅ Recently closed

### Arc 2 Phase 3 — SQL deltas (migration 0023) built + tested (2026-06-16)

Built the three die-cast front-end SQL dependencies + a concurrency fix, in-session TDD against a fresh `Reset-DevDatabase` baseline (DB had been at `0021` — Phase 3 `0022` was committed but never applied; reset brought it to `0022` then `0023` applied). **Full SQL suite 1535/1535 green** (30 net-new `0023_PlantFloor_DieCast_Deltas/` assertions). On `jacques/working`, commits `7f3da5a` (Phase 4 renumber) → `6f5b7b1`.

- **Migration `0023`** — new `Parts.DataCollectionFieldDataType` FK code table (5 rows String/Integer/Decimal/Boolean/Date) + `Parts.DataCollectionField.DataTypeId` NOT NULL FK (nullable→backfill-by-Code→NOT NULL, DT-2). No audit-lookup rows. Idempotent (verified re-apply = no-op).
- **`DataCollectionField_List` v3.0** — joins the new code table, returns `DataTypeId/Code/Name` (the FE typed-widget driver, D5).
- **`Workorder.ProductionEvent_ListByLot`** (new, PE-1a) — header-only chronological checkpoint list, resolved-name joins, empty-safe; `EventAt` raw UTC (FE formats; OI-36 if ET wanted). Feeds the FE cumulative-cavity card + last-shot hint.
- **`Lot_Create` `@LotName` (D4) + `@CavityNote` (D2)** — additive, backward-compatible (every existing caller/test passes NULL and behaves byte-for-byte as today; the `0021`/`0022` LOT tests pass unmodified). `@LotName` supplied = use verbatim, no `IdentifierSequence` burn; duplicate/blank rejected. `@CavityNote` = manual cavity stored in the legacy `Lot.CavityNumber` when `@ToolCavityId IS NULL` on a die-cast cell; validated cavity path unchanged.
- **`RejectEvent_Record` TOCTOU fix (v1.1)** — the `@Quantity > @PieceCount` gate read `PieceCount` unlocked pre-transaction; added an in-transaction `IF @NewPieceCount < 0 RAISERROR` re-check under the existing UPDLOCK (routes to CATCH = clean Status 0) so concurrent over-rejects can't drive `PieceCount` negative. (Beyond the deltas-spec scope but a correctness bug; the project-status addendum flagged it.)
- **Reconciliation folded in (verified vs as-built):** the FE-spec NQ for `ProductionEvent_Record` named `@EventAt` (proc has none — stamps `SYSUTCDATETIME()`) and `@DataCollectionValuesJson` (real param is **`@FieldValuesJson`**) — Part B authors the NQ/entity-script against the real signature (recorded in the plan's reconciliation section).
- **Part B front-end — BUILT (file-authored + scanned), commits `c29d5db`+`5a8a566`.** 5 Core NQs (`workorder/ProductionEvent_Record`+`_ListByLot`, `workorder/RejectEvent_Record`, `parts/ToolCavity_ListActiveByTool`, `parts/ToolAssignment_ListActiveByCell`; `lots/Lot_Create` gained `:lotName`/`:cavityNote`); entity scripts (`BlueRidge.Workorder.ProductionEvent`+`RejectEvent` new modules; `Parts.Tool` +cavity-dropdown/cell→tool helpers; `Parts.OperationTemplate.getDieCastShotFields` DataType-merge; `Lots.Lot.create` lotName/cavityNote forward + `getOriginTypeIdByCode`; `Quality.DefectCode.getForDropdown`); the no-tabs two-column **DieCastEntry** page + **CheckpointPanel**/**RejectPanel**/**FieldInputRow**/**PeerTallyRow** sub-views; 3 `/shop-floor/die-cast*` routes + HomeRouter tile; smoke seed `sql/scratch/smoke_seed_phase3_diecast.sql`.
  - **Topology reconciliation (FE spec assumed namespaces that don't exist):** tool NQs live under `parts/` (no `tools/` group) and tool helpers extend `BlueRidge.Parts.Tool` (no `BlueRidge.Tools.*`); event procs got a new `workorder/` NQ group + `BlueRidge.Workorder.*`. NQ params reconciled to the **as-built** `ProductionEvent_Record` (no `@EventAt`; `@FieldValuesJson` not `@DataCollectionValuesJson`).
  - **⚠️ REMAINING (manual): Designer visual smoke** — the views were file-authored without a Perspective session, so expect iteration. The `scan.ps1` already ran — **the new Core NQs are registered, no gateway restart needed.** Walkthrough in the plan §B5 / FE spec §10: minimal-tap create, cavity-peer (flat genealogy), free-entry cavity (D2), data-driven checkpoint widgets (D5) + unchanged inventory, reject + close-at-zero. Seed via the smoke script; the operator session needs `session.custom.cell.locationId` + `appUserId` set.
  - **Known FE follow-up:** the Item field is a numeric-entry (flagged TODO) — needs an `Item_ListEligibleForLocation` read to become an eligibility-constrained dropdown (deferred: would be untested new SQL; the proc validates eligibility server-side regardless). Tool-reassign Edit + Hold buttons are surfaced per the mockup but not fully wired (reuse existing `Parts.Tool` assign/release + hold procs at smoke).
  - **Open dispositions (non-blocking):** D4 canonical-LOT-id MPP confirmation (server-mint default until then; one-line flip to `lotName=scannedLtt`); `ProductionEvent_ListByLot.EventAt` UTC-vs-ET (OI-36); Tool-reassign-from-plant-floor auth policy.

### Arc 2 Phase 2 — LOT Lifecycle SQL foundation built end-to-end (2026-06-11)

Migration `0021` + **13 net-new procs** + test suite `0021_PlantFloor_Lot_Lifecycle/` (9 files), **SQL suite 1449/1449**. Brainstormed → spec'd (`docs/superpowers/specs/2026-06-11-arc2-phase2-lot-lifecycle-design.md`) → planned (`docs/superpowers/plans/2026-06-11-arc2-phase2-lot-lifecycle.md`) → built. Tasks 0–5 ran subagent-driven (fresh implementer + spec-review + code-review + fix per task); Tasks 6–7 + integration sign-off ran in normal in-session flow (faster/cheaper for well-specified pattern SQL where context is already held — see the 2026-06-11 process note). All on `jacques/working`, commits `56aefa1`..`6bae073`.

- **Schema (migration 0021):** 5 new tables — `LotGenealogy` (born-partitioned on `EventAt`, 20-yr Honda class, PartitionRetention 240mo), `LotAttributeChange`, `LotLabel`, `PauseEvent` (filtered-unique open-pause invariant + CK_ResumePaired), `LabelTemplate` (1:1 active ASCII ZPL body per LabelTypeCode). Seeds: 3 new LogEventType + 3 LogEntityType + one ZPL template per label type. B4 closure + B5 materialized cols already existed in 0020 — Phase 2 *maintains* them.
- **Mutations:** `Lot_Update` (partial-update NULL semantics, lenient optimistic lock, per-field LotAttributeChange audit, resolved WeightUom FK), `Lot_UpdateAttribute`.
- **Genealogy:** `Lot_Split` (parent-derived `-NN` sublot suffix, UPDLOCK/HOLDLOCK serialization, closure depth+1, Option-A multi-row return, inline child-create to dodge INSERT-EXEC/result-set pollution), `Lot_Merge` (die-rank-compat rules keyed off `Tool.DieRankId` + supervisor override, fresh-MESL blended output, closure ancestor-dedup, BIGINT sum guard), `LotGenealogy_RecordConsumption` (consumption edge + closure; `@ProducedLotId` required since `ChildLotId` is NOT NULL).
- **Reads:** `Lot_GetGenealogyTree` (closure-backed ancestors/descendants/both), `Lot_GetParents`/`Lot_GetChildren` (one-hop edges + EventUser), `Lot_GetAttributeHistory` (UNION of attribute/status/movement streams).
- **Labels:** `LotLabel_Print` + `LotLabel_Reprint` — SQL-side ZPL render from `LabelTemplate` (5-token REPLACE), sublot `ParentLotId` rule, reprint resolves prior label type (else Primary) + forces non-Initial reason. `LotLabel` entity audits route to `Audit.OperationLog`.
- **Pause (OI-21):** `LotPause_Place`/`_Resume`/`_GetByLocation`/`_GetCountsByLocation` — B3 open-event pre-check + filtered-unique backstop, multi-Cell concurrent pause, resumer-may-differ.
- **Key engineering note:** every mutation proc that orchestrates sub-mutations INLINES them (child create, parent reduce, source close) rather than `EXEC`-ing the status-row procs — an `EXEC`'d status-row SELECT pollutes the caller's result set and nesting INSERT-EXEC is illegal. Validations run *before* `BEGIN TRANSACTION` (ROLLBACK inside an INSERT-EXEC'd proc throws Msg 3915).
- **Deferred (by design):** the 4 Perspective views (LOT Detail, LOT Search, Genealogy Viewer, Paused-LOT Indicator) are a follow-on Ignition push (SQL-first decision); `@PrinterName` on labels lands with the B17 gateway dispatcher; precise B5 OEE-grade recompute lands with the Phase 3 event writers. Migration `0021` is now taken — Phase 3 die-cast is `0022`.

### Terminal-mode view-policy model — smoke-discovered redesign landed end-to-end (2026-06-10/11)

Designer-smoking Phase 1 exposed that FDS-02-010's parent-tier TerminalMode derivation misclassified every machining/assembly-line + trim terminal (cell-less parents -> Shared with an EMPTY context picker; attribution broken). MPP ruling: lines are tracked at line resolution; stations are operation points. Redesign (spec `docs/superpowers/specs/2026-06-10-terminal-mode-view-policy-design.md`, plan + 8-task subagent-driven execution): **there is no TerminalMode anywhere** — behavior is a property of the operator view assigned via `DefaultScreen` (shared-flavor views open with a select-location step; dedicated-flavor views bind context to the terminal's parent Location at ANY tier).

- **SQL:** `Terminal_GetByIpAddress`/`Terminal_List` v1.1 (mode column dropped; `HasPrinter` registry flag added — every terminal must carry >= 1 child Printer; seed has 62/63, FALLBACK-TERMINAL flagged); NEW `Location.Terminal_ListContextCells` (recursive equipment-cell picker excluding Terminal/Printer kinds, MAXRECURSION 8); test file `015_Terminal_ContextCells_List.sql`. Suite **1308/1308**.
- **Ignition:** Core NQ + `Terminal.listContextCells`/`getContextCellsForDropdown`; MPP session shape drops `terminalMode`, adds `presence.policy` (default `strict`; dedicated views set `confirm`); HomeRouter initials-gate removed (view flavor owns it); CellContextSelector re-pointed to the terminal-scoped picker (also fixes its old all-Cells list offering terminals/printers); PresenceIdleWatcher gates on `policy != "confirm"` (strict-flavor idle handling TODO'd for first work views); InitialsField auto-fill re-anchored to `policy == "confirm"`; TerminalSelector session-write purged.
- **FDS v1.4** (+docx): §2.5, 02-008/009/010/011, 04-003 amended; 04-006 explicitly unchanged (both flavors keep the 30-min re-confirm); §1 diagram + FDS-05-008 move step re-anchored; stale header version fixed (was reading 1.3).
- **⚠️ Owed:** a 60-second session smoke (after a `scan.ps1` — no gateway restart needed): select DC1-T1 -> CellContextSelector lists exactly the 11 DC1 presses; line terminal -> empty picker. (Earlier note here claimed a gateway restart was required for MPP to resolve the inherited `location/Terminal_ListContextCells` NQ; that was a mis-attribution — scan re-reads NQs fine. The real prior fix was *moving* NQs into Core for sibling visibility. Corrected 2026-06-12.)

### Arc 2 Phase 1 Ignition layer — NQs + gateway scripts + 7 Perspective views built (2026-06-09)

The follow-on Ignition push to the Phase 1 SQL foundation (tasks T030–T041, ~54h) is **built + file-authored + statically reviewed**, committed on `jacques/working` (`07f2e10`..`848426b`). Executed subagent-driven (fresh implementer + spec/quality review per task + a final holistic cross-cutting review). **NOT yet Designer-smoked — that is the remaining manual step.**

- **New project topology (Jacques's decision):** introduced **`Core`** (inheritable parent; holds the moved `BlueRidge.*` scripting library) and **`MPP`** (`parent=Core`; the plant-floor operator project) — pulled from the gateway projects folder into the repo (`ee70f4a`). The legacy `MPP_Config` (config tool) stays as-is. Entity scripts + NQs → Core; views + session-startup + timers → MPP.
- **DB-access layer (T030, Core):** 17 thin Named Queries wrapping the Phase-1 procs (all `type:"Query"` — even mutations, status-row pattern) + 6 entity-script modules (`Location.Terminal`, `Location.AppUser`, `Oee.Shift`, `Lots.Lot`, `Lots.IdentifierSequence`, `Audit.Partition`). Later migrated `location/Location_ListByTier` into Core too (for the Cell selector).
- **Session bootstrap + gateway timers (T031/T033/T034, MPP):** rewrote `onStartup` to resolve the terminal from client IP (`Terminal_GetByIpAddress`) into `session.custom.terminal.*`; declared the plant-floor `session.custom` shape (`terminal`/`user`/`appUserId`/`cell`); `ShiftBoundaryTicker` (60s) → `Shift.tickShiftBoundary`; `PartitionMaintenance` (24h) → `Audit.Partition.maintain`.
- **7 Perspective views (T035–T041, MPP):** Per-Mutation Initials Field, Elevation Modal, Initials Entry (+ A-Z keypad), 30-Min Idle Re-Confirm Modal, PresenceIdleWatcher (`now(30000)` idle binding), Terminal Selector (`ia.display.table` full-schema + `onSelectionChange`), Cell Context Selector, Home Router (gates terminal→Dedicated-presence→defaultScreen, repointed `/`). Routes added: `/shop-floor/initials`, `/shop-floor/terminal-selector`, `/` → HomeRouter.

**Known follow-ups / flagged decisions (none blocking the build):**
1. **Gateway sync + Designer smoke** is the only remaining step a CLI can't do — the new files are in the repo but NOT yet in the live gateway's `Core`/`MPP` copies. Sync repo→gateway (carefully, to avoid clobbering in-Designer work) then smoke each surface in a Perspective session.
2. **AD elevation is default-deny:** `AppUser.elevate`'s `_validateAdCredentials` denies all until the gateway AD Identity Provider is wired (FDS-04-007). No invented permissive rule — wire the IdP at deployment and decide the validation mechanism.
3. `ia.input.password-field` (Elevation Modal) is unconfirmed in Designer — verify it renders.
4. Timers attribute shift/partition audit to the dev-fallback AppUser `2`; seed a dedicated **system** AppUser before cutover.
5. `now(30000)` idle re-fire + the PresenceIdleWatcher embedding into work screens are runtime-verify / later-phase items.
6. Cell Context Selector is Phase-1-scoped (pick+persist+broadcast); zone cascade + `v_EffectiveItemLocation` enrichment are later-phase.

### Arc 2 Phase 1 SQL — Phase 0 gate signed off + design/plan committed + dispatch begun (2026-06-09)

**OI-35 architecture gate CLEARED.** Phase 0 Track B was decided 2026-06-08 (`Meeting_Notes/2026-06-08_Phase0_Decision_Log.md`); the staged T009 sign-off Blocks 1–5 were applied to the canonical docs this session:
- **Data Model** → new § "Scaling Decisions (OI-35)" (rev **1.9s**).
- **FDS** → FDS-11-009 differentiated retention table (20-yr Honda / 7-yr general) (rev **1.3a**).
- **OIR** → OI-35 **RESOLVED**; UJ-03 changed (no auto even-split, Phase 0 T008); UJ-05 build-default locked; counts/version (**v2.18**).
- **Plant Floor plan** → B10 serial-migration convention refined.
- **Validation doc** → Section 5 resolution banner (C-4/C-5 CREATE-ownership pinned).
- **CLAUDE.md** → Active Blockers cleared. Decision-log T009 marked Done.

**Phase 1 scoped + designed + planned (SQL-first push).** Brainstormed the build approach: SQL foundation first (migration `0020` + ~16 procs + `0020_PlantFloor_Foundation/` test suite green, target 80–105), Ignition layer (3 Gateway scripts + 7 Perspective views) deferred to a follow-on push; subagent-driven execution. **Key design decision — partitioning:** monthly `RANGE RIGHT` + **`TRUNCATE`-based sliding-window** (not `SWITCH`) so the singleton `BIGINT IDENTITY Id` PK convention is preserved (clustered index = partition-aligned hot path; `Id` stays NONCLUSTERED PK); single `PRIMARY` filegroup; sliding-window logic in a testable proc so the future Gateway timer is a thin caller. Grounding catch: `Audit_LogOperation` (B7 target) has near-zero Arc-1 blast radius (Arc 1 audits to `ConfigLog`); no partitioning exists in the repo yet (genuinely new ground).

- **Design spec:** `docs/superpowers/specs/2026-06-09-arc2-phase1-sql-foundation-design.md` (commit `2785590`).
- **Implementation plan:** `docs/superpowers/plans/2026-06-09-arc2-phase1-sql-foundation.md` (commit `e1ef121`) — Tasks A–G (A partitioning in-session; B Lot core; C Terminal; D AppUser/elevation; E WorkOrder+eligibility view; F audit split+Shift; G integration/sign-off).
- **Status:** dispatch (subagent-driven) has **begun** on the SQL build (separate session). All on `jacques/working`.

### Eligibility-style config editors — backend built + verified, UI drafted (2026-06-08)

Executed the plan `docs/superpowers/plans/2026-06-08-eligibility-style-config-editors.md` (turned from spec `7f41a2d` via `writing-plans`) using **subagent-driven-development** — fresh implementer per task + two-stage (spec then code-quality) review per task + a final holistic cross-cutting review. All on `jacques/working`, commits `81f7a82`..`33b94e5`.

- **SQL (Phases A–B), fully tested — suite 1196/1196:** three bundled SaveAll procs following the audit-readable convention (`SUBJECT · CATEGORY · ACTION`, resolved-FK JSON, status row, no OUTPUT params):
  - `Tools.ToolAttribute_SaveAll` — insert/update/**hard-DELETE on absent** (`ToolAttribute` has no `DeprecatedAt`) + per-`DataType` value validation (String/Integer/Decimal/Boolean/Date). Reuses LogEntityType `ToolAttribute`.
  - `Tools.ToolCavity_SaveAll` — **insert + update only** (no deprecate-on-absent; cavities persist, end-of-life via Scrapped); CavityNumber immutable on existing rows; rejects transition out of Scrapped. LogEntityType `ToolCavity`.
  - `Parts.OperationTemplateField_SaveAll` — insert / update `IsRequired` / deprecate-on-absent / reactivate. LogEntityType `OpTemplateField`.
  - 3 thin NQs under `named-query/parts/` (`type:"Query"`, sqlType 3/7/3). No schema change (D4 = no SortOrder). No new LogEntityType seed (all three codes pre-existed).
- **Review catches (per-task):** ToolAttribute Boolean-NULL slipped the `NOT IN` validation → NOT-NULL constraint crash (fixed `i.Value IS NULL OR …` + test); OperationTemplateField reactivation could clear `DeprecatedAt` on >1 deprecated row for the same pairing → unique-index violation (fixed `MAX(Id)` guard + reject-active-re-add + regression test). Test fixtures named off "SaveAll" to avoid the `02_audit_readers/050_ConfigLog_List.sql` `%SaveAll%` count cross-contamination.
- **Entity scripts (Phase C):** `BlueRidge.Parts.Tool.saveAttributesAll`/`saveCavitiesAll`/`getAttributeDefinitionOptions`(carries DataType); `BlueRidge.Parts.OperationTemplate.saveFieldsAll` + `getFieldsForTemplate` now surfaces `DataCollectionFieldId`. Per-row legacy mutations kept as the non-UI surface. Resolved both plan-flagged prereqs (`Tool_Get` returns `ToolTypeId`; `OperationTemplateField_ListByTemplate` already returns `DataCollectionFieldId`).
- **Perspective UI (Phases D–H), file-authored + scanned — NOT visually smoked yet:** Attributes section + type-aware AttributeRow (four `position.display`-gated value inputs); Cavities section + CavityRow (status dropdown, Scrapped-lock, immutable number, remove only on unsaved rows); Assignments rewritten as a **non-draft** inline mount/release surface (+ binding-safe `getActiveAssignmentForToolOrEmpty`); Operation-Template Fields draft panel + FieldRow. Tools parent gains `sectionDirty` map + ConfirmUnsaved tab/tool-switch gating + `toolTabObjects` (ItemMaster tab-objects pattern); OperationTemplates parent folds `fieldsDirty` into its existing version-switch gate. All mirror the `ItemMaster/Eligibility` reference (atomic single-write `view.custom.state`, page-scoped row→section messages, pre-declared shaped bound props).
- **Cleanup (Phase I):** `MountToCell` / `AddAttribute` / `AddCavity` popups deleted (no dangling refs; `AddAttributeDefinition` kept + still referenced); defensive banner expr + dead-state removal.
- **⚠️ Remaining: Phase H3 visual Designer smoke** (see Next Session Pickup) — the only step a subagent/CLI cannot do. Parent views were file-edited (accepted view-edit-boundary risk); expect possible Designer iteration.

### Plant Floor (Arc 2) phased plan validated + corrected; task list generated (2026-06-08)

Diligence pass over the Arc 2 plan against the current FDS (v1.3), Data Model (v1.9o), and the **actual shipped migrations on disk** (three parallel inventory agents + ground-truth disk verification). Found 2 blocking defects, 3 MVP coverage gaps, and consistency drift; all corrections applied to `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` (→ **v1.2**).

- **Blocking fixes:** (1) Arc 1 actually shipped migrations through `0018`, so all Arc 2 migrations renumbered **`0014`–`0021` → `0019`–`0026`** and test suites → **`0020`–`0027`** (Arc 1 test suites end at `0019`). (2) **Phase 1 now CREATEs `Lots.Lot` (+ `LotStatusHistory` + `LotMovement`) and Phase 2 CREATEs `LotGenealogy` + `LotAttributeChange` + `LotLabel`** — these core tables were never built by Arc 1 (only the Lots *code* tables exist); the plan had wrongly ALTERed `Lot`.
- **Consistency:** `HoldEvent`/`DowntimeEvent`/`ShippingLabel` CREATE-ownership pinned (Phases 7/8/6); Phase 4 dep corrected to {1,3}; Phase 6↔7 schema cross-dep noted; gateway-script count five→six; stale v1.0a placeholder note removed; versions restamped (FDS v1.3 / DM v1.9o).
- **Three MVP gaps flagged for a scope decision** (not yet sized in-scope): G-1 inspection recording (FDS-08-011..013); G-2 Controlled Run Tag (FDS-10-012 — also missing from the **schema**, needs a DM bump); G-3 reporting + Global Trace Tool (FDS-12 — plan defers to an unscoped workstream).
- **New artifacts:** `MPP_MES_PLANT_FLOOR_PLAN_VALIDATION.md` (findings report), `MPP_MES_TASK_LIST_PLANT_FLOOR.csv` + `.xlsx` (**184 tasks, ~739 h / ~92 dev-days**; xlsx adds Workstream + SuggestedRole grouping + a swimlane ReadMe). Phase 9 holds the gap-fill tasks (T182/T183 CRT + T184 reporting marked **Blocked** pending decisions).
- **OI-35 still gates the actual SQL build** — the task list assumes the Phase 0 default decisions (closure table, monthly partitioning, materialized columns, OperationLog split); these must be ratified in Phase 0 before Phase 1 (`0020`) is written.
- **MVP scope ratified (2026-06-08):** quality-capture (G-1 inspection, FDS-08-011..013), the Controlled Run Tag workflow (G-2 — `Lot.CrtActive` added to the Phase 1 `Lot` CREATE, **Data Model v1.9q**), and the Global Trace Tool + LOT Genealogy Report (G-3a) are all **in-scope** as a new **Phase 9** (plan → **v1.3**). The legacy PD operational reports stay **deferred** to near/post-deployment (UJ-19). **Arc 2 migrations re-baselined +1 to `0020`–`0027`** (Phase 9 `0028`) because `0019_location_coupled_downstream_cell` landed on disk 2026-06-08 — the per-phase numbers are now next-free-at-build-time.

### Tools Config Tool — eligibility-style editor redesign spec'd (2026-06-05)

Brainstormed (with the visual-companion mockup tool) → design spec committed `7f41a2d`: `docs/superpowers/specs/2026-06-05-eligibility-style-config-editors-design.md`. **No implementation yet** — next step is `writing-plans`. Ports the Item Master eligibility editing model onto Tools Attributes/Cavities/Assignments + Operation-Template fields. Decisions: (1) full eligibility model (inline draft + Save/Discard + atomic SaveAll); (2) cavity status as inline dropdown, `ToolCavity_SaveAll` insert+update only (no delete-on-absent — end-of-life via Scrapped); (3) assignments adopt the look + inline mount (kills MountToCell popup) but stay immediate/audited with no draft; (4) no field ordering (no SortOrder); (5) type-aware attribute value inputs (text/numeric/checkbox/date by DataType, proc-validated). New procs planned: `ToolAttribute_SaveAll` (delete-on-absent — no DeprecatedAt column), `ToolCavity_SaveAll`, `OperationTemplateField_SaveAll`. Parent Tools + OperationTemplates views gain dirty-gating like Item Master.

### Tools Config Tool — Mount-to-Cell tool-type filter (2026-06-05) ⚠️ UNCOMMITTED

Mount-to-Cell dropdown now filters Cell-tier Locations to the kinds a tool type can mount on (Die → Die Cast Machine), instead of listing all 146 cells (presses + printers + terminals). Migration `0018_tooltype_compatible_celldef.sql` adds `Tools.ToolType.CompatibleLocationTypeDefinitionId` (FK → `Location.LocationTypeDefinition`, NULL = no restriction) and seeds Die→DieCastMachine by Code. New `Tools.Tool_ListCompatibleCells @ToolId` proc (rule in SQL per `feedback_no_business_logic_in_python`) + NQ; `getCellsForDropdown(toolId)` + the MountToCell binding pass the tool id; `ToolType_List`/`_Get` surface the column. Verified on dev: Die tool → 22 DieCastMachine cells only. **Data Model → v1.9o.** Applied non-destructively to `MPP_MES_Dev`; scanned. **Not committed — see Next Session Pickup.**

### Tools Config Tool — Retire/status + display bug-fixes (2026-06-05) ⚠️ UNCOMMITTED

Three issues from Jacques's review (root-caused via DB evidence, no guessing): (1) **Retire left status "Active"** — `Tool_Deprecate` set `DeprecatedAt` only, never `StatusCode`, and the chip reads `StatusCode`. Per decision, the proc now sets **StatusCode=Retired + DeprecatedAt** together (ISNULL-guarded, audit old→new status); verified via rollback-test; the already-retired `CAV-TEST-DIE` data-corrected to Retired. (2) **Rank pills/chips rendered literal "NULL"** — no tool has a DieRank; pills bound text directly to a null rank. Now hidden via `position.display = !isNull(...)` on `ToolRow.BadgeRank` + header `SummaryBadgeRank`. (3) **Description showed "null"** — `getOne` now coerces null→"" for display; `add`/`update` coerce ""→NULL so the DB keeps NULL. Also: the reported "assignment history vanished" was a **non-bug** — `CAV-TEST-DIE` was never mounted (audit + raw table confirm zero assignment rows; the two real assignments belong to ASN-DIE-A/B). Applied to `MPP_MES_Dev`; scanned. **Not committed — see Next Session Pickup.**

### Quality Spec Config Tool — built end-to-end + smoke-polished (2026-05-29)

Brainstormed/designed/planned previously; **built and smoke-tested in one session**. Executed the plan `docs/superpowers/plans/2026-05-28-quality-spec-config-tool.md` Phases A–H, then iterated on live-session smoke feedback. Parallel-subagent-draft → serialize throughout.

- **SQL (Phase A):** migration `0017` (`QualitySpecAttribute.UomId` FK + `QualitySpec.DeprecatedAt`/`DeprecatedByUserId` → `Location.AppUser`); 3 net-new procs `QualitySpecVersion_SaveDraft` / `QualitySpec_Deprecate` / `QualitySpecVersion_DiscardDraft`; readable-audit convention on every quality mutation proc; date-resolved Publish (no auto-deprecate). **SQL tests 1161/1161.**
- **Ignition (B–H):** 14 named queries; extended `BlueRidge.Quality.QualitySpec` entity script; `/quality-specs` master-detail screen; `QualitySpecAttributeRow`, `SpecListRow`, `VersionHistoryRow` flex-repeaters; `NewSpecModal`; route + sidebar nav (pre-existing); Item Master "Go to spec →" cross-nav.
- **Smoke fixes:** spec library + Version History converted table→flex-repeater (table column-width squish + em-dash mojibake + blank CreatedBy fixed); `ia.input.numeric-entry-field` (was nonexistent `numeric-entry`); `Lower≤Target≤Upper` validation enforced in `QualitySpecVersion_SaveDraft`; left-rail list refresh after publish/new-version/discard/deprecate; hide UOM/Target/Lower/Upper on non-Numeric attrs via `meta.visible`; `+ New Version` clones the *selected* version.
- **Date-resolved versioning surfaced:** per-version **Active / Scheduled / Superseded** state computed in SQL (`QualitySpecVersion_ListBySpec.State` via `@ActiveId` = max `EffectiveFrom ≤ now` among published-non-deprecated) + `GetActiveForSpec` `VersionNumber DESC` tiebreaker; shown in the version dropdown + Version History pills.
- **Key plan corrections caught at build:** plan's `Audit.AppUser` → real table is `Location.AppUser`; plan's A3 code had the `JSON_QUERY` double-encode bug; `QualitySpec_Update` SETs ItemId/OpTemplateId unconditionally (NULL-defaulting params would wipe links → NQ + entity pass them through); new tests written in the `test.Assert_*` framework (plan used raw RAISERROR).
- **Memory added:** `feedback_ignition_numeric_entry_field_type`. Context-pack `06_component_quirks` corrected (had the wrong numeric component id).

### Audit-readability refactor Slices 2.5 + 3–8 landed — refactor COMPLETE (2026-05-29)

Closed out the entire project-wide audit-readability refactor in one session. Slices 3–8 (the six backport slices, ~31 procs) were **drafted in parallel by six subagents** — one per slice, each given the Slice-2 reference impl + the three inherited fixes (`JSON_QUERY` wrap, `DATALENGTH` strip, boolean-words) — then serialized through a single deploy + full-test pass, triaged, and committed slice-by-slice. **SQL tests 1136/1136** (was 1060 after Slice 2; +76 convention-shape assertions).

- **Slice 2.5** — `Common.Util.prettyJsonDiff` (unified colorized diff: green add / red remove / yellow change; resolved-FK sub-objects collapse to `Code — Name`; degrades to +/−/~ symbols if HTML isn't rendered). ConfigChangeDetail popup gains an `ia.display.markdown` Changes block (`props.markdown.escapeHtml=false`, schema confirmed from a user-supplied markdown example) above the kept Old/New JSON blocks. **Visual smoke pending** (see Next Session Pickup). Commit `feat(audit): Slice 2.5 …`.
- **Slice 3 BOMs** — 6 `Bom_*` procs; lines resolve `ChildItem` + `Uom`, header resolves `ParentItem`.
- **Slice 4 Routes** — 6 `RouteTemplate_*` procs; steps resolve `OperationTemplate`, header resolves `Item`. Publish says "supersedes v<N-1>" (Routes don't auto-deprecate). 
- **Slice 5 Item core** — `Item_*` + `ContainerConfig_*` (5); Update procs capture pre-state for field-diffs.
- **Slice 6 Plant Hierarchy** — `Location_*` + `LocationAttribute_Set` (6); resolves Parent + LocationTypeDefinition.
- **Slice 7 LocationTypeEditor** — `LocationTypeDefinition_SaveAll`/`Deprecate` (2); attribute +/-/~ reconciliation + cascade count.
- **Slice 8 Downtime + Defect codes** — 6 atomic Create/Update/Deprecate procs; resolve Area + DowntimeReasonType.

**Triage fixes during serialization (3 failure clusters → all resolved):**
1. **Routes `Header` double-encoding** — subagents wrapped the inner `Item`/`OperationTemplate` in `JSON_QUERY` but left the outer `Header` subquery bare, so it double-encoded to an escaped string. Wrapped `Header` in `JSON_QUERY()` across all 5 route procs (7 spots).
2. **`ConfigLog_List` cross-contamination** — `030_RouteTemplate_SaveAll.sql` fixtures named `'SaveAll test item N'` surfaced in the new `Item_Create` narratives and matched the `@DescriptionLike='SaveAll'` filter (8 rows vs 1). Renamed to `'Route bundle item N'`.
3. **BOM Deprecate audit test** — v1 was auto-deprecated by the v2 publish (no standalone audit row) and the explicit v1 deprecate is an idempotent no-op; retargeted the assertion to deprecate the active v2.

### Quality Spec Config Tool — design + implementation plan committed (2026-05-28)

Brainstormed → designed → planned. No code yet; queued behind the audit refactor.

- **Spec:** `docs/superpowers/specs/2026-05-28-quality-spec-config-tool-design.md` (`4d4b07b`).
- **Plan:** `docs/superpowers/plans/2026-05-28-quality-spec-config-tool.md` (`35859a1`). 9 phases / ~18 tasks, SQL-first, complete code for net-new SQL + entity script, mirror-with-deltas for the large views.
- **Key finding:** the Quality SQL layer was **already built** (migration `0008` + ~20 procs + `sql/tests/0011_Quality_Spec/`). This build is mostly Ignition front-end plus a contained SQL delta.
- **Design decisions captured this session:**
  - Standalone `/quality-specs` master-detail screen (NOT an Item Master tab — the mockup designs it standalone; Item Master tab stays link-only) + Phase 7 "Go to spec →" cross-nav folded in.
  - Lifecycle: Draft/Published/Deprecated (BOMs vocabulary on the built procs), but **date-resolved active versions — Publish does NOT auto-deprecate the prior Published version** (`_GetActiveForSpec @AsOfDate` resolves the active one; future-effective Published = "Scheduled" badge). This reconciles the mockup's Active/Pending model with the built Draft/Published procs.
  - `QualitySpecAttribute.UomId` FK dropdown (not free text) → SQL delta: migration `0017` adds the FK.
  - Add `QualitySpec_Deprecate` header soft-delete proc (+ `QualitySpec.DeprecatedAt`); add bundled `QualitySpecVersion_SaveDraft` (per the editDraft/explicit-Save convention; the per-action `_Add/_Update/_MoveUp/...` procs stay but aren't called per-click).
  - **Audit-readability convention applied to every quality-spec mutation proc from day one** (per the audit refactor spec §3/§4 + a richer quality catalog in the design §7) — so quality specs never need a backport slice.
- **Front-end reference:** mirrors the BOMs versioned-editor impl (`BlueRidge.Parts.Bom` + `Components/Parts/ItemMaster/Boms` + `BomLineRow`) — atomic state writes, binding-based dirty, input-only embeds via page-scoped messages — but in a standalone `LocationTypeEditor`-style shell.

### Audit-readability refactor Slice 2 landed (2026-05-29)

`Parts.ItemLocation_SaveAllForItem` is now the **reference implementation** of the `SUBJECT · CATEGORY · ACTION` convention; Slices 3-8 mirror this proc.

- **Subject resolution**: `PartNumber — Description` resolved once at proc start via `Audit.ufn_MidDot()` separator.
- **Change-set classification**: a `@Changes` table variable buckets the reconciliation into `+` (add, incl. reactivation-as-add), `~` (update with field-level diff), `-` (remove), each joined to `Location.Location` + `Location.LocationTypeDefinition` for resolved names — all computed from **pre-mutation** state before `BEGIN TRANSACTION`.
- **Activity narrative**: `STRING_AGG ... WITHIN GROUP` composes per-op specifics with a 3-per-op cap + `+N more` overflow counters; capped at 500 via `Audit.ufn_TruncateActivity()`. Live example produced in tests: `TEST-ELIG-ITEM-001 — Eligibility map test item · Eligibility · +DIECAST (Production Area); 1 rows`.
- **Resolved-FK JSON**: `OldValue`/`NewValue` expand `LocationId` to `Location: {Id, Code, Name}` sub-objects (one JOIN per row at write time, zero at read time).
- **Two defects caught in the plan's SQL** (both fixed in the reference impl, both flagged for Slices 3-8 in Next Session Pickup):
  1. Resolved sub-object emitted via a bare aliased `FOR JSON` subquery — SQL Server double-encodes that as an escaped *string*, not a nested object. Fixed by wrapping in `JSON_QUERY((...))`.
  2. Trailing-`"; "` strip used `LEFT(x, LEN(x) - 2)`; `LEN()` ignores trailing spaces so it ate one real char off the last specific (`5→nul`, `Area`). Fixed to `LEFT(x, DATALENGTH(x)/2 - 2)`.
- **Boolean rendering**: field-diffs on `BIT` columns render as words (`IsConsumptionPoint true→false`), not `1→0` — readability convention for all slices.
- **Tests**: 6 new convention-shape assertions (Tests 9-13: SUBJECT·Eligibility· prefix, `+<Code>` presence, resolved `Location` Id/Code/Name in NewValue, length ≤ 500, plus Test 13's `~`-update path asserting `true→false` words + the last specific surviving intact). The Eligibility test item was renamed off "SaveAll" to stop its audit narrative cross-matching `ConfigLog_List`'s `@DescriptionLike='SaveAll'` filter. **1060/1060 SQL tests.** Proc at v1.3.
- **Designer smoke (Task 2.8) DONE 2026-05-29** — `/items → Eligibility → Save → /audit` verified narrative + resolved-name popup; ConfigChangeDetail EntityLine `\u` binding error fixed (literal middle-dot).

Proc bumped to v1.1. Files: `sql/migrations/repeatable/R__Parts_ItemLocation_SaveAllForItem.sql`, `sql/tests/0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql`.

### Audit-readability refactor Slice 1 landed (2026-05-28)

First slice of the project-wide audit-log readability refactor spec'd at `docs/superpowers/specs/2026-05-28-audit-readability-refactor-design.md`. Five tasks landed across 6 commits:

- **Helpers**: `Audit.ufn_MidDot()` returns `NCHAR(183)` middle-dot separator; `Audit.ufn_TruncateActivity(@text)` applies the 500-char cap with `NCHAR(8230)` ellipsis suffix on overflow + NULL passthrough. 6 truncate tests pass. **1054/1054 SQL tests total.**
- **Convention codified**: `sql_best_practices_mes.md` gained a full "Audit Log Description Convention" section covering the `SUBJECT · CATEGORY · ACTION` shape, verb/symbol vocabulary, field-diff notation, truncation rules, and FK-resolution rule. CLAUDE.md gained a brief pointer subsection. New procs inherit the convention; existing procs migrate as touched in Slices 2-8.
- **AuditLog UI**: dropped meaningless numeric `EntityId` column; added `ChangesSummary` column between Event and Severity (powered by yesterday's `BlueRidge.Common.Util.summarizeJsonDiff` helper); renamed `Description` column header to `Activity`. Scoped monospace+ellipsis CSS for the Changes column under `.psc-audit-log-table`. Absorbed yesterday's `HANDOFF_AUDIT_LOG_2026-05-28.md` (handoff deleted).
- **Popup fixed**: `BlueRidge/Components/Popups/ConfigChangeDetail` opens correctly on row click. Three bugs found via a one-shot diagnostic log of `event.keys()` + `str(event)`:
  1. Event name was `onRowClick` which `ia.display.table` doesn't dispatch in 8.3 — silent no-op, nothing in logs. Standard event is `onSelectionChange`. Switched.
  2. Event payload is a PyDictionary not an object. `hasattr(event, "selection")` returned False because `selection` would be a KEY not attr. Plus event uses `selectedRow` (int index) not `selection` (array). Plus `if not sel:` would silently return on `selectedRow=0`. Switched to dict `.get()` + explicit `if sel is None` check.
  3. EntityLine binding used `coalesce(BIGINT entityId, '(new)')` which fails Quality due to type mismatch. Rendered as 'null' + red error indicator. Switched to `if(isNull(...), '(new)', toStr(...))` to force string type.

Commit chain on main: `159bc73` (ufn_MidDot) → `66a7ab5` (ufn_TruncateActivity + tests) → `2d0b16b` (convention codified) → `129aaa9` (AuditLog UI + handoff absorption) → `91fa14d` (popup fixes + Slice 2.5 plan add).

Slice 2.5 added to the implementation plan: diff highlighting on the popup via `ia.display.markdown` + new `Common.Util.prettyJsonDiff` helper. Deferred until after Slice 2 lands resolved-name JSON, because highlighting bare-ID diffs `LocationId 4 → 5` is useless whereas `Location DC-401 → DC-402` is actionable.

**Lessons captured (no new memories this slice, but noted for future):**
- `ia.display.table` standard event for row clicks in 8.3 is `onSelectionChange`, NOT `onRowClick`. Silent no-op if event name is wrong — no error logged anywhere. Diagnostic was to add `log("event attrs=" + str(dir(event)))` at script entry; if log doesn't appear, event isn't dispatched.
- `event` payload for `onSelectionChange` is a PyDictionary with keys `selectedRow` (int), `selectedColumn` (str), `data` (the visible-column subset of the row, NOT the full row data). For full row use `self.props.data[idx]`.
- `event.get("selectedRow")` returns 0 for the first row — using truthy `if not sel: return` silently breaks on that row. Use explicit `if sel is None: return`.

### Item Master Phase 8 Eligibility editor — end-to-end smoke green (2026-05-28)

Closed out Phase 8 — the last big tab in the Item Master refactor. Full vertical stack landed in 16 commits (`31f66cb`..`0a83224`), all 14 spec §9 smoke steps pass:

- **SQL** — `Parts.ItemLocation_SaveAllForItem` (bundled reconcile: add / update / deprecate / reactivate-deprecated all atomically), `Location.Location_ListForEligibilityPicker` (tier-grouped picker read with `NCHAR(8212)` em-dash to avoid `sqlcmd` codepage trap), `Parts.ItemLocation_ListByItem` bumped to v3.0 (added `TierOrdinal`, re-sorted `(tierOrdinal, code)`). 11 SaveAll tests + 3 picker tests pass. Existing 64 ItemLocation CRUD tests still pass after widening `#IlByItem1`/`#IlByItem2` scratch tables for the new column. **1048/1048 SQL tests passing.**
- **Ignition** — 3 NQ wrappers (SaveAll + picker + **previously-missing** `ItemLocation_ListByItem` read NQ — `6527d24` was the root cause of all the post-save dirty-stuck symptoms, see below), `BlueRidge.Parts.Eligibility` entity script, new `EligibilityRow` sub-view (page-scoped message propagation per `feedback_ignition_embed_params_input_only`), and full rewrite of `Eligibility/view.json` per per-section ownership pattern matching BOMs.
- **Pattern adherence** — `isDirty` binding uses the canonical BOMs-equivalent `runScript("BlueRidge.Common.Util.convertWrapperObjectToJson", 0, {view.custom.state.editDraft.rows}) != ...{state.selected.rows}` expression. No divergence from the per-section ownership convention.

**Process lesson (captured as memory `feedback_check_nq_files_first`)**: I spent four rounds patching the `isDirty` binding (property+transform variants, type comparison tweaks, deep-path watching theories) chasing a "save success toast but dirty stays true" symptom. The actual root cause was a missing NQ file (`parts/ItemLocation_ListByItem`) which the plan had assumed already existed. `load()` was failing silently with `java.lang.Exception: Named query not found` every call, so `state.selected` never reset post-save. **Lesson:** when a new editor following an established pattern misbehaves in surprising ways, FIRST check the gateway log for `Named query not found` traces — don't immediately blame the binding or comparison logic. 30-second diagnostic vs hours of binding archaeology.

**Plan deviations (all documented in commits):**
- Tier filter in tests uses `lt.Code = N'Area'` / `N'Cell'`, not `ltd.Name = N'Area'` — dev seeds carry definition names like `'Production Area'` / `'CNC Machine'`.
- Test Item insert uses `CreatedByUserId` (Parts.Item has no `IsActive` column).
- Picker proc uses `NCHAR(8212)` (em-dash codepoint) instead of literal em-dash in source — sqlcmd was loading the UTF-8 source file with the Win-1252 codepage and storing the wrong 3-byte sequence in the proc body. Same fix applied to the test's LIKE pattern via `@Sep NVARCHAR(5) = NCHAR(8212)`.
- Row qty fields (`Min`/`Max`/`Default`) use `meta.visible` not `position.display` so the 240px slot stays reserved when `IsConsumptionPoint` is off (uniform row geometry per user feedback).
- Save (`props.enabled`) + Discard (`meta.visible`) wrap `view.custom.isDirty` in `if(isNull(...), false, ...)` defensive guard so a transient Quality-Bad doesn't cascade to Component Error.

Audit-log "Changes" column work from 2026-05-27 evening is still uncommitted in working tree alongside the Phase 8 commits — see "Next Session Pickup" above. The two workstreams touched disjoint files; no interference.

### Item Master Phase 3 dirty-drift blocker resolved + Phase 6 BOMs smoke green (2026-05-27 → 2026-05-28)

Closed out the per-section dirty-drift blocker that had been gating Phase 3 closeout for a week. Two compounding bugs in `BlueRidge.Common.Util.convertWrapperObjectToJson` + `load()` racing:

1. **Shallow unwrap.** `convertWrapperObjectToJson` was `return dict(obj)` — handed back a Python dict containing raw `BasicQualifiedValue` leaves. The dirty-binding expression then either compared two dicts whose Java-wrapper identities drifted between reads (false-positive dirty), or — once `system.util.jsonEncode(dict(obj))` was tried — choked because jsonEncode can't serialize raw QV objects (binding evaluated to null, "Error_Configuration"). Fix: `return system.util.jsonEncode(extractQualifiedValues(obj))`. The existing `extractQualifiedValues` already handles `JavaMap` + `QualifiedValue` recursively — which is exactly the shape that arrives at runScript (`HashMap` of `BasicQualifiedValue`). Confirmed via diagnostic logging that captured both sides' types + reprs.

2. **Load-race architecture.** Even with deep unwrap, the dirty-binding still fired spuriously on cross-item nav because `load()` was writing `self.view.custom.selected = X; self.view.custom.editDraft = X` as two SEQUENTIAL property assignments. Between the writes the binding evaluated with `selected = new item, editDraft = old item` → dirty=true → `sectionDirtyChanged{isDirty:true}` propagated → parent latched `sectionDirty.<section> = true`. The subsequent dirty=false transition either coalesced or arrived after the parent already gated navigation. **Fix:** wrap both in a single `view.custom.state` parent property and write atomically: `self.view.custom.state = {"selected": dict(loaded), "editDraft": dict(loaded)}`. Applied to Identity, ContainerConfig, BOMs (per-section ownership), and Routes (the only one that uses explicit `broadcastDirty()` instead of binding-driven dirty).

**Phase 3 smoke (steps 1–16, including the previously-blocked cross-item nav steps 10–16) all PASS.**

**Phase 6 BOMs end-to-end smoke (B1–B13) also all PASS** in the same multi-day session. Numerous fixes layered on top of the per-section state refactor:

- **Six BOM mutation NQs** (`Bom_Create`, `Bom_CreateNewVersion`, `Bom_Publish`, `Bom_SaveDraft`, `Bom_Deprecate`, `Bom_DiscardDraft`) were mistyped as `UpdateQuery`. JDBC's executeUpdate path throws on the status-row SELECT every project mutation proc returns — "A result set was generated for update." The procs succeeded server-side, but client got an exception, no toast fired, no UI updated. Flipped all six to `type: "Query"`. New memory: `feedback_ignition_nq_type_for_status_row_procs`.
- **`forEach` in Ignition expressions doesn't exist.** Four BOMs/BomLineRow bindings (`VersionDropdown.options`, `LinesRepeater.instances`, `ItemPicker.options`, `UomEdit.options`) had been authored as `forEach({list}, {label: ..., value: ...})` expressions and silently failed with "Nested paths not allowed" / "TagPathFormatException". Converted all four to property binding + script transform, mirroring Routes' working pattern. New memory: `feedback_ignition_no_foreach_in_expressions`.
- **`BomLineRow` was nested under `Boms/`.** Same "Ignition can't load views nested under other views" trap that hit `DraftStepRow` yesterday. Moved to `ItemMaster/BomLineRow/` as a sibling of the other section embeds.
- **Embed sub-view params are input-only.** `BomLineRow.QtyEdit` + `UomEdit` were bidi-bound to `view.params.line.X` — writes silently dropped, never reaching the parent. Save Draft stayed disabled after qty edits; UOM "reverted to EA" on every pick. Added page-scoped `bomLineQtyChanged` + `bomLineUomChanged` messages with `_applyQtyChange` + `_applyUomChange` customMethods on the parent. New memory: `feedback_ignition_embed_params_input_only`.
- **`handleNewVersion` didn't load state inline.** Was relying on `activeVersionId.onChange` → `loadActiveVersion()` chain to populate the new draft's content. The chain didn't reliably fire. Now `handleNewVersion` explicitly fetches the bundle and writes `view.custom.state = {selected, editDraft}` synchronously, same pattern Routes' `BtnNewVersion` uses.
- **Single-Published invariant + pre-publish confirmation UX.** Catching that v1 + v2 could both have `DeprecatedAt IS NULL` for the same `ParentItemId`: `Bom_Publish` now auto-deprecates any prior Published version in the same transaction, with an `OUTPUT inserted.VersionNumber INTO @DeprecatedVersions` so the success message reads "Published v2. Deprecated v1." Publish button now routes through a new `requestPublish` customMethod that inspects `view.custom.versions` for a prior Published row — if found, opens the existing `ConfirmDestructive` popup ("Publish v2? This will deprecate v1 currently active in production."); first publish goes direct. Commit `f6df905`.
- **Layout polish.** ColMove/ColRm header placeholders converted from empty `ia.display.label` to empty `ia.container.flex` so they reserve slot width when invisible (labels collapse on `meta.visible: false`). Draft/Published alternate columns switched from `meta.visible` to `position.display` (alternates that share a column should collapse, not both reserve space). All BomLineRow controls get uniform `height: 30px` so bottom edges align. ColArrows widened 52px → 72px so arrows fit side-by-side.
- **Component filter.** `Parts.ItemLocation_ListAvailableForBom` excludes `ItemType.Name = N'Finished Good'` per business rule (BOM components are never Finished Goods).

Commit chain on main (this session): `bd00c5e` (per-section atomic state writes + extractQualifiedValues chain) → `5b13cc1` (yesterday's DraftStepRow polish) → `44ec8b7` (script-console demo) → `1049ea3` (BOMs end-to-end smoke fixes bundle) → `c27c36d` (Routes elementStyle parity) → `f6df905` (BOMs Publish invariant + UX).

**Memory updates (durable lessons captured):**
- `project_mpp_item_master_pattern` — added "Atomic state writes" addendum documenting the `view.custom.state = {selected, editDraft}` single-write rule + the `convertWrapperObjectToJson` co-fix.
- `feedback_ignition_nq_type_for_status_row_procs` — NEW. Mutation procs returning status-row SELECT must have NQ `type: "Query"`, not `UpdateQuery`.
- `feedback_ignition_no_foreach_in_expressions` — NEW. Ignition expression language has no iteration primitive; use property + script transform.
- `feedback_ignition_embed_params_input_only` — NEW. Sub-view params are input-only; bidi writes to nested paths under `view.params.X` get silently dropped; use page-scoped messages.
- `feedback_no_business_logic_in_python` — NEW. Jacques rule: business rules (compatibility matrices, validation thresholds, etc.) live in SQL, never in Python entity scripts.
- `CLAUDE.md` § Compound editors with per-section ownership — strengthened with the atomic-state-write paragraph + embed-to-parent propagation paragraph.

### Item Master Phase 8 Eligibility — spec + implementation plan committed (2026-05-27)

Brainstormed + designed + planned. Code not yet landed.

- Spec: `docs/superpowers/specs/2026-05-27-item-master-eligibility-design.md` (commits `03c50e0` + `8fc736d` self-review).
- Plan: `docs/superpowers/plans/2026-05-27-item-master-eligibility.md` (commit `84a2a0b`). 10 tasks, SQL-first, every task has exact file paths + complete code blocks + expected sqlcmd output.
- Pattern: per-section ownership with atomic state writes (same pattern locked in Phase 3 fix).
- Editor model: tiered list (one row per `Parts.ItemLocation` row), single typeahead Location dropdown grouped by tier, bundled SaveAll proc with reactivate-deprecated semantics, no client-side business-rule enforcement.
- Schema already supports the design — `Parts.ItemLocation` already has the consumption-metadata columns from migration 0010. No new migration needed.

### Item Master Phase 6 — BOMs versioning workflow landed via rebase + ff-merge (2026-05-26)

Second versioned per-section embed to ship (after Phase 5 Routes). The BOMs tab on `/items` now supports the full Draft → Published → Deprecated lifecycle: create new version (clone last Published into Draft), add/edit/remove component-item lines (Item dropdown + UoM auto-populate + Qty + IsScrapTracked), Save Draft (bundled JSON-line reconciliation via `Bom_SaveDraft` — physical DELETE/UPDATE/INSERT since `BomLine` has no `DeprecatedAt`), Publish (atomic save-then-publish with optional `EffectiveFrom` + min-1-line guard moved BEFORE `BEGIN TRANSACTION` to avoid Msg 3915 in INSERT-EXEC tests), Discard Draft (hard delete + cascade), Deprecate Published (idempotent). Filtered UNIQUE index `UX_Bom_ActiveDraft` enforces one Draft per ParentItemId. New migration: `0016_parts_bom_unique_draft.sql`.

Built in worktree `.claude/worktrees/Agent-B-item-master-boms`, then **rebased onto main** after main absorbed Phase 5 Routes + Phase 3 Item CRUD which collided on three surfaces:

- **Migration slot collision** — `0015_parts_bom_unique_draft.sql` renamed to `0016_*` (0015 taken by main's `audit_add_event_type_deleted`).
- **`Uom_List` NQ add/add** — kept main's `EXEC Parts.Uom_List @IncludeDeprecated = :includeDeprecated` signature; deleted BOMs' duplicate; updated `BlueRidge.Parts.Bom.listUoms()` to pass `{"includeDeprecated": False}`.
- **Generic 2-button confirm popup duplication** — swapped BOMs' new `ConfirmAction` for main's `ConfirmDestructive`; updated 2 callers in `Boms/view.json` (`openDeprecateConfirm`, `openDiscardDraftConfirm`); deleted `ConfirmAction` view dir. Orphan `f30be77 feat(popups): reusable ConfirmAction popup` commit still in history → `682905b` deletes its files (net effect correct; squash if cleaner log desired).

**Pattern backports from main's Routes versioning work (post-fork commits):**

- **`85986c3` isDirty deep-compare** — backported as `43c20bd`. BOMs' `view.custom.isDirty` was comparing `editDraft.lines != selected.lines` (list reference equality); now routes both sides through `Common.Util.convertWrapperObjectToJson` for primitive-level equality. **This is the candidate fix-pattern for the open dirty-drift blocker on Identity/ContainerConfig.**
- **`e7f2f3e` / `404b51b` ImmutableMap unwrap in versions.onChange** — NOT APPLICABLE; BOMs has no versions.onChange handler (uses runScript-bound dropdown + Python entity returning plain `list[dict]`); uses `flex-repeater` not `ia.display.table`.
- **`e29c670` selectedItem default shape restore** — NOT APPLICABLE; BOMs `view.custom.selected` + `editDraft` already declare full nested empty shape.
- **`a391f07` Routes onChange bracket-access on ImmutableMap (not broken json.loads roundtrip)** — landed AFTER the rebase agent did its main pass; BOMs absorbed via a second silent rebase before ff-merge. BOMs has no analogous onChange callsite.

**Pre-existing test bug recovered:** `010_Bom_crud.sql` had a `#BomListScratch` temp-table that wasn't widened when `R__Parts_Bom_ListByParentItem.sql` went to v3 (added `LineCount` + `Status` columns). INSERT-EXEC was throwing Msg 213 silently aborting the whole file via `sqlcmd -b`, skipping ~13 trailing assertions including `[BomCreateHappy]`. Fixed in `705986e` as part of the rebase pass.

**Final 11-commit set on main:** `971c2f4` SQL backend → `c61db35` 10 NQs → `ae481b5` entity script → `f30be77` ConfirmAction (orphaned later) → `d357a95` BomLineRow → `38639a1` BOMs embed wire → `217c540` migration renumber → `c2962c1` Uom_List signature → `682905b` ConfirmAction→ConfirmDestructive swap → `43c20bd` isDirty deep-compare → `705986e` `#BomListScratch` widen. Merged ff-only.

**SQL tests:** 1034/1034 passing (was 972 on BOMs branch pre-rebase; +62 from main's Phase 5 Routes additions + recovered `010_Bom_crud.sql` assertions).

**Pickup tomorrow:**

1. **Smoke-test BOMs end-to-end in Designer** — open `/items`, pick 5G0, click BOMs tab. Verify: versions list with line-count + status badges; `+ New Version` → clones last Published into Draft + EffectiveFrom prefill + success toast; edit qty → `●` dirty + tab disable; `+ Add Component` Item dropdown auto-populates UoM; reorder arrows; row `×` remove; `Save Draft` → reload persists; `Publish` (zero-line + missing EffectiveFrom blocked; valid → status flip); `Deprecate` → `ConfirmDestructive` → status flip; `Discard Draft` → `ConfirmDestructive` → version vanishes; tab-switch with dirty Draft triggers ConfirmDestructive gate (parent's Phase 4 infrastructure carries this); `Audit.ConfigLog` rows for every mutation.
2. **Reset dev DB** — `.\Reset-DevDatabase.ps1` to land migration 0016 cleanly (if `0015_parts_bom_unique_draft` row exists in `SchemaVersion` from pre-rebase, the reset rebuilds from scratch).
3. **`.\scan.ps1`** before Designer testing to pick up new NQs + 2 new views + restructured `Boms/view.json`.
4. **Try `43c20bd` deep-compare pattern on Identity + ContainerConfig isDirty** — first diagnostic step for the open editDraft-drift blocker (both currently do reference-equality on dict-typed editDraft vs selected, the exact bug the BOMs backport addressed).
5. **Working tree on main has uncommitted edits** to `ItemMaster/{resource.json, view.json}` from prior Identity bug investigation — survived the merge intact; decide whether to commit / discard / continue iterating before re-opening Designer.
6. Optional cleanup: interactive-rebase squash `f30be77` (orphan ConfirmAction add) into `682905b` (its delete) for tidier log.
7. Optional: remove worktree `git worktree remove .claude/worktrees/Agent-B-item-master-boms` (Agent-A + Agent-C worktrees still in use for parallel work).

### Item Master Phase 4 — ContainerConfig save + parent gate infrastructure (2026-05-26)

First section to ship under the per-section ownership convention. ContainerConfig embed now owns its own `view.custom.selected` + `view.custom.editDraft` locally, receives a plain BIGINT `params.value: itemId` (input-only, no bidi Object-param), fetches its own data via `BlueRidge.Parts.ContainerConfig.getByItem` on `params.value` onChange, has its own Save / Discard buttons in a HeaderRow, broadcasts `sectionDirtyChanged` page-scoped on every dirty transition, and listens for `sectionSaveRequested` / `sectionDiscardRequested` from the parent. New `TargetWeight` field with `position.display` gated on `ClosureMethod == 'ByWeight'`. `handleSave` coerces string text-field input → numeric (text-field bidi writes strings into editDraft, so the plan's `trays <= 0` would silently misvalidate in Jython 2).

Parent ItemMaster view demolished the old bundled `editDraft` / `selected` / `mode` props (never properly populated anyway) and added the per-section gate infrastructure:

- `view.custom.selectedItemId` (BIGINT, set on item-row click); all 5 tab embeds receive `params.value: selectedItemId` input-only.
- `view.custom.activeTabIndex` (int, bidi-bound to TabContainer.currentTabIndex). View-level onChange interceptor stages `pendingSwitch` and opens ConfirmUnsaved when leaving a dirty section, then auto-reverts.
- `view.custom.sectionDirty` flag map populated by listening to `sectionDirtyChanged` from sections.
- `view.custom.pendingSwitch` staging area for the intercepted nav event.
- `root.scripts.customMethods`: `openConfirmUnsaved(sectionKey)`, `completeSwitch()`, `cancelSwitch()`.
- `root.scripts.messageHandlers`: rewritten `itemRowClicked` (gated by any-section-dirty), new `sectionDirtyChanged`, new `confirmUnsavedResult` (save → page-msg `sectionSaveRequested`; discard → page-msg `sectionDiscardRequested`; cancel → drop pendingSwitch).
- TabContainer `props.tabs` bound via `runScript(BlueRidge.Parts.Item.itemMasterTabLabels, 0, {view.custom.sectionDirty})` — returns a plain Python list[str] with `●` prefix on dirty sections. Initial `[if(...), ...]` expression-array-literal binding caused a red error at the top of the tab strip; runScript binding is cleaner.

Identity panel (DetailsHeader) restored as **read-only display** binding to a new `view.custom.selectedItem` prop populated via `runScript(BlueRidge.Parts.Item.getOneOrEmpty, 0, {view.custom.selectedItemId})`. `getOneOrEmpty` returns the full Item key-shape with null values when itemId is null/missing, so cold-open bindings render clean rather than Quality-Bad. All Identity inputs are `enabled: false`; Save / Deprecate buttons toast Phase-3 placeholders. Phase 3 will carve Identity into its own embed and wire bidi editing.

Plan deviations (all called out in commit messages):

- **sqlType corrections**: plan said `INT → 4`, `DECIMAL → 8`; correct values from the empirical Designer-canonical enum (per `ignition-context-pack/04_named_queries.md`) are `INT → 2` (Int4) and DECIMAL has no native code so `→ 5` (Float8 — JDBC coerces).
- **`self.X()` not `self.rootContainer.X()`** inside `root.scripts.messageHandlers` and `root.scripts.customMethods`: per the verified `ignition-view-customMethods-scope` memory, `self` IS the root component at that scope. The plan-text had the wrong addressing.
- **`{X} != null` not `isnull(X, 0) != 0`** for nullable-BIGINT visibility gates: `isnull(value, default)` is SQL; Ignition expressions use `isNull(value)` or direct null comparison. The wrong syntax silently fail-evaluated to Quality-Bad and propagated to the view-level ERROR banner.

Commit range: `4e2f47d` (NQ Create) → `8c72bea` (NQ Update) → `bcb4575` (entity script) → `981b816` (ContainerConfig embed) → `7731120` (parent gate) → `61a9eaa` (DetailsHeader excise + tab init fix) → `08256e0` (expr/runScript fixes) → `be207a5` (Identity read-only restore).

**Status**: full smoke (spec §7 steps 1–11) passed 2026-05-26.

**Late-stage smoke fix (`2817cdd`)**: spec §7 step 4 originally wanted a ConfirmUnsaved popup on tab clicks with revert-to-current-tab semantics. `ia.container.tab` in Ignition 8.3 doesn't expose `instantiation` / `keepAlive` / pre-change events, so the popup-intercept-with-state-preservation pattern is infeasible against that component. Pivoted to the **tab-objects pattern** — `props.tabs` accepts a list of dicts per tab with `text` / `runWhileHidden` / `disabled` fields. New `BlueRidge.Parts.Item.itemMasterTabObjects(sectionDirty, activeTab)` returns objects with `runWhileHidden: true` (keeps inactive embeds mounted, preserves their local editDraft across tab visibility changes) and `disabled: true` on every non-active tab when any section is dirty (locks navigation visually instead of via script intercept). The active tab still shows the `●` dirty-dot prefix as the cue. Item-row click popup intercept stays as-is (separate code path). Spec §7 step 4 should be retro-edited to describe this UX. Reference: [Ignition tab container docs](https://www.docs.inductiveautomation.com/docs/8.3/appendix/components/perspective-components/perspective-container-palette/perspective-tab-container#adding-components-to-tabs).

### Defect Codes — Task 8 complete (2026-05-20)

The flex-repeater never re-rendered because the screen chained two bindings: a query+transform on `view.custom.allRows` (Python list[dict] with `java.sql.Timestamp` values from unread CreatedAt/DeprecatedAt) feeding a second expression binding `runScript("...filterAndMapRows", 0, {view.custom.allRows}, {view.custom.filter.searchText})`. Substituting a freshly transformed list-of-dicts back into another binding's args chokes Perspective's marshaling. Script Console didn't reproduce because it sends literal Python objects.

**Fix (`15eeee2`):** consolidated to the DowntimeCodes peer pattern — new `BlueRidge.Quality.DefectCode.search(filter)` does DB + client-side text filter + row mapping in one shot; `view.custom.rows` binds via single expr `runScript("...search", 0, {view.custom.filter})`; the flex-repeater downgrades to a plain property binding on `view.custom.rows`.

**Bundled follow-ups:**
- `15eeee2` — "Area (optional)" → "Area" label + handleSave null-area warning toast guard
- `75b4420` — Editor `editDraft.meta` initialized to the proper empty shape upfront (was `null`, causing red borders and "null" text on first render); explicit `props.text:""` on Excused checkbox (suppresses component default placeholder); list-view IncludeDeprecated wrapped in `IncludeDeprecatedField` matching DowntimeCodes filter sidebar
- `16291b6` — DefectCodeRow gains `params.deprecated` + root opacity binding (55% fade) + EditButton conditional hide for deprecated rows
- `4922ec4` — Both DefectCodeRow and DowntimeCodeRow switched EditButton hide from `position.display` to `meta.visible` so the 80px slot stays reserved and Area/Excused columns hold their x-position across deprecated rows ([[ignition-meta-visible-in-tables]])

Smoke-confirmed by Jacques: add, deprecate, filter all working.

### Defect Codes — open follow-ups (not blocking)

- **`getAllAreas` vs `listByTier`** — Task 5 added `listByTier` as a generic primitive but neither Task 6 (popup) nor Task 7 (list view) ended up using it. Ships with zero consumers. Cleanup option: migrate both area-dropdown sites to `listByTier('Area')` + transform when next touched.
- **Parity opportunity in DowntimeCodeEditor** — same `editDraft: {meta: null}` initial state and unset `props.text` on Excused checkbox. Symptoms haven't been reported there (its `params.editId` onChange populates meta earlier in lifecycle) but the same two-line fix would close the latent risk.

---

This file holds the **volatile** state of the project — current doc versions, active blockers, recent change narrative, and the next-session briefing. Durable identity, document map, architecture, and conventions live in `CLAUDE.md`.

---

## Current Document Versions

| Doc | Version | Rev Date | Status / Notes |
|---|---|---|---|
| Data Model | **v1.9q** | 2026-06-08 | Current. v1.9q (2026-06-08): `Lots.Lot.CrtActive BIT` added (FDS-10-012 Controlled Run Tag hook). v1.9p (2026-06-08): Location `CoupledDownstreamCellLocationId` typed-FK promotion (migration `0019_location_coupled_downstream_cell`) + `Quality.QualityResult.NumericValue` + OI-35 scaling fold-in. v1.9o: `Tools.ToolType.CompatibleLocationTypeDefinitionId` (migration `0018`) for the Mount-to-Cell tool-type filter (Die→DieCastMachine). v1.9n (2026-06-04): sub-LOT split relocated Trim OUT → Machining OUT. v1.9m: `Parts.OperationTemplate.RequiresSubLotSplit`. |
| FDS | **v1.4** | 2026-06-10 | Current. v1.4 (2026-06-10): terminal-mode view-policy model — FDS-02-010 rewritten (behavior by assigned view; parent-tier derivation retired), 02-008/009/011 + 04-003 amended, 04-006 unchanged; header-version stale note resolved. v1.3 (2026-06-03): sub-LOT split relocated Trim OUT → Machining OUT. v1.2 (2026-05-18): `ParentLocationId` immutability (FDS-02-002a). v1.1 (2026-05-12): Customer Acceptance signature page. v1.0 (2026-05-04): first customer-review release. |
| Open Issues Register | **v2.17** | 2026-05-01 | Current. **9 items closed** from Jacques's 2026-05-01 markup: OI-07, -24, -25, -27, -28, -29, -30, -31, UJ-03 → all ✅ Resolved. 6 items remain Open. |
| Outstanding Items extract | **v2.0** | 2026-05-01 | Current. Reduced to 6 Open items per OIR v2.17. |
| User Journeys | **v0.9** | 2026-04-29 | Current. FDS v0.11m reconciliation pass. |
| Phased Plan — Plant Floor (Arc 2) | **v1.3** | 2026-06-08 | Current. v1.3 (2026-06-08): MVP gaps (inspection / CRT / Global Trace) ratified in-scope as Phase 9; `Lot.CrtActive` added (DM v1.9q); Arc 2 migrations re-baselined +1 to `0020`-`0027` (Phase 9 `0028`). v1.2 (2026-06-08): validation-correction pass — migrations renumbered `0019`–`0026` / test suites `0020`–`0027`; Phase 1 CREATEs `Lot` + history (was wrongly ALTERed); Phase 2 CREATEs genealogy/attr/label; CREATE-ownership + dep-table + version fixes. v1.1 (2026-06-03): sub-LOT split → Machining OUT. Companion: validation report + task list (CSV/xlsx). |
| Phased Plan — Config Tool (Arc 1) | v1.7 | earlier | All 8 phases built and tested. |
| Seeding Registry | v1.0 | earlier | Current. |
| ERD | (current through v1.9i) | — | **Pending refresh** — see ERD Refresh Queue below. |

---

## 🚨 Active Blockers

### OI-35 — Architecture Decision Gate (HIGH)

**Long-horizon scaling, retention, archiving strategy must resolve before Arc 2 Phase 1 SQL build (`0014_arc2_phase1_shop_floor_foundation.sql`) commences.** Last-responsible-moment posture confirmed by Jacques 2026-04-29.

Eight architectural decisions:

1. Per-table retention class (push back on 20-yr for `Audit.OperationLog` / `InterfaceLog` / `FailureLog`).
2. Monthly partitioning + sliding-window automation across ~14 high-volume event tables **plus the two runtime-EAV children** `Workorder.ProductionEventValue` + `Quality.QualityResult` (partition-aligned with their parents; folded in 2026-06-08 EAV-at-scale review). **Must be in CREATE migration.**
3. Columnstore on aged partitions (>90 days).
4. Materialized closure table for `Lots.LotGenealogy` — Honda audit O(1) vs recursive CTE at year 15. **Must be in CREATE migration.**
5. Materialize `TotalInProcess` / `InventoryAvailable` columns onto `Lots.Lot` (supersedes OI-23 view choice at scale). **Must be in CREATE migration.**
6. `Lots.IdentifierSequence_Next` locking model — row-locked vs SQL Server `SEQUENCE`.
7. Split `Audit.OperationLog` into 7-yr general + 20-yr `Lots.LotEventLog`. **Must be in CREATE migration.**
8. Filtered indexes on hot subsets.

Items 2/4/5/7 must be in the CREATE migration — retrofitting partition schemes, closure tables, or materialization columns to populated 100M+ row tables is operationally expensive.

**Resolution path:** internal Blue Ridge architecture review + MPP IT retention-policy negotiation (single meeting). Output: data model § "Scaling Decisions" + FDS-11 retention paragraph + Phase 1 migration content.

**Background:** `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`.

### Phase 0 Customer Validation Workshop with MPP — Track A (8 items)

Track A is the customer-validation gate. Track B is the architecture workshop above (OI-35). OI-31 closed 2026-05-01 (cutover seed at +10K above Flexware counter — captured in FDS-16-003) — only the rollout-shape sub-question remains as a Ben item, no longer Phase-0-gating.

1. **FDS-06-030** — WorkOrder BIT-flag enumeration.
2. **Historical data migration** — entity list + pre-flight validation + discrepancy review.
3. **ShotCount semantics** — cumulative counter (current default) vs derived from aggregated LOT quantity.
4. **Workstation `DefaultScreen` + `ConfirmationMethod` seeding** — per-Cell Perspective-view list + per-Cell `ConfirmationMethod` value (Vision / Barcode / Both).
5. **Honda AIM Hold/Update contract detail** — `PlaceOnHold` / `ReleaseFromHold` / `UpdateAim` signatures + error recovery (UJ-04 GetNextNumber pool flow already locked).
6. **Label template scope** — Flexware has 3 templates (CONTAINER / LOT / CONTAINER_HOLD); confirm matches + any new (Sort Cage / Hold / Void). Couples to S-09 in Seeding Registry.
7. **OI-32 Material Allocation operator screen** — premise challenged 2026-04-24; revised "close as not-reproduced" framing awaits Ben's explicit confirmation.
8. **OI-33 AIM pool empty-pool hard-fail customer validation** — confirm hard-fail is the desired posture (production stops on affected lines until pool refills; no soft-fallback).

---

## Outstanding for Next Session

### Open Part B UJs

- **UJ-05** Sort Cage serial migration — default direction committed (update-in-place + `Lots.ContainerSerialHistory`); awaits MPP Quality + Honda compliance affirmation.
- **UJ-19** Productivity DB replacement — Ben + MPP Production Control name the four PD reports; **MVP scope confirmed** per OI-30 closure (the four reports are deliverables; reports beyond the four = post-deployment change order).

### Open Part A items (4)

- **OI-32** Material Allocation operator screen — Ben's confirmation of "close as not-reproduced" framing.
- **OI-33** AIM pool empty-pool hard-fail — MPP Operations / IT customer validation.
- **OI-34** Production schedule leverage — MPP Production Control discovery walk-through.
- **OI-35** Long-horizon scaling, retention, archiving — Blue Ridge architecture review + MPP IT retention negotiation. **HARD GATE** before Arc 2 Phase 1 SQL build.

### SQL queue — Blue Ridge owns (gated on Phase 0)

1. ✅ **OI-07 + OI-12 correction migrations** — landed 2026-04-28 as `0013_oi07_oi12_corrections.sql`. 858/858 tests passing.
2. ✅ **LocationTypeDefinition CRUD support** — landed 2026-05-13 as `0014_locationattributedefinition_unique_active_name.sql` (filtered UNIQUE index) plus `R__Location_LocationTypeDefinition_SaveAll.sql` (bundled meta + child reconciliation in one transaction) and `R__Location_LocationTypeDefinition_Deprecate.sql` (cascade + FK guard against active Locations). 907/907 tests passing.
3. **Arc 2 Phase 1 SQL implementation** — needs renumber to **`0015_arc2_phase1_shop_floor_foundation.sql`** (0014 was taken by item 2). **GATED on Phase 0 — both tracks (Customer Validation + Architecture Decision)** before commencement. Phase 1 plan body bakes OI-35 architectural decisions into the migration on day one (partition functions, closure table if elected, materialization columns if elected, OperationLog split if elected, filtered indexes per B8). Includes the Phase 4 Data Model column add `Parts.OperationTemplate.RequiresSubLotSplit` if not landed earlier as its own migration.
4. **Phases 2–8 SQL** — sequential per the rebuilt plan (migrations `0016`–`0022`, shifted by one from the original reservation). Phase 4 migration `0018` includes the `RequiresSubLotSplit` ALTER if not already shipped.

### ERD refresh queue

ERD pending refresh for v1.9j–m additions:

- `ContainerConfig.ClosureMethod` values (`ByCount` / `ByWeight` / `ByVision`)
- `Lots.ShippingLabel.BannerAcknowledgedAt`
- `CoupledDownstreamCellLocationId` LocationAttribute under `CNCMachine`
- `Parts.OperationTemplate.RequiresSubLotSplit`

Per-schema tabs are the source of truth and remain canonical until next regen.

### Internal Docs Portal — ✅ landed 2026-05-12

Initial v1 build at `docs_portal/`. See "Recent Change Narrative" entry below for details.

### LocationTypeEditor modal — ✅ closed 2026-05-15

Full vertical stack landed 2026-05-13, convention-rectification pass 2026-05-14, all 8 smoke flows pass 2026-05-15 (commits `f469061` + `7ab9cd3`). Audit verified via `Audit.ConfigLog` rows. Marker removed from this section; historical detail in the "Recent Change Narrative" entries below.

### Non-blocking polish

- Memory file revision-history-format trim: applied to FDS only; not yet to Data Model + OIR.
- FDS-06-028 wording sharpen — WO Auto-Finish (§6.10) prose still mentions "camera-count mode" pre-tray-reframe. Low priority.
- ~~**Latent NQ v1 schema bug:** at least `location/Get/resource.json` is `version: 1`~~ — resolved 2026-05-14 (bumped to v2 with corrected sqlType enum). See `feedback_ignition_nq_resource_schema.md` memory for the empirically-verified Designer sqlType table.
- **Audit Log UI revisit** (Jacques, 2026-05-27) — current FailureLog + AuditLog browser pages work for Phase 3 verification but the UI itself wants another design pass at some point. Not blocking anything; revisit when there's a natural opening between feature work.

### Deferred follow-ups tied to future Config Tool surfaces

- **DieCastMachine Cell — read-only mounted-Tool status panel** (Plant Hierarchy editor). When the Tools master Config Tool surface is built, add a read-only section under (or alongside) Attributes on DieCastMachine Cell details showing the currently mounted Tool, mount timestamp, and mounting supervisor, sourced from `Tools.ToolAssignment_ListActiveByCell(@CellLocationId)`. Mutation (mount/release) stays on the plant-floor scan-in screen per FDS-05-034 + the `tool-assignment-modal` mockup design — the Plant Hierarchy panel is visibility-only so engineering can see what's mounted without going to the floor or asking. Deferred until the Tool master Config Tool screen exists (it would have no cross-link target today). Discussion: 2026-05-18 session.

- **Downtime / OEE dashboard (not started, 2026-07-21)** — supervisor dashboard: open downtime by cell/line, downtime Pareto by reason code + reason type over a shift/day/date-range, and Availability % once a shift-availability rollup exists (downtime minutes vs shift minutes per `Oee.Shift` — no proc computes A/P/Q today). The downtime subsystem already captures all inputs; only the rollup/dashboard surface is missing. See `notes/2026-07-21_downtime-dashboard-need.md`. Raised while shipping the Shift Schedules config screen (`/shifts`), which is now built (NQ + view + route over the pre-existing `Oee.ShiftSchedule_*` procs; the sidebar nav item was a dead link before).

### 🟠 Open at session end (2026-05-19)

### Item Master Phase 1 view shell landed (2026-05-19)

The Item Master Configuration Tool page (`/items`) is built as a Phase 1 visual shell — 7 new view files plus a page-config registration. Layout fully mirrors the mockup at `mockup/index.html` §"SCREEN: Item Master" (lines 308–860) and `+Add Item` modal (lines 2629–2715). All `view.custom.editDraft.*` form bindings active; dirty indicator works; tab switching works; toast placeholders for Save/Deprecate/Create/New Version all fire correctly.

**What's wired:** Page route, sidebar nav (already in place), ItemMaster shell, ItemRow flex-repeater + page-scoped click messaging, DetailsHeader form (9 inputs bidi-bound to editDraft.meta), TabStrip with 5-tab switching, 5 embedded tab views (ContainerConfig editable; Routes/BOMs/QualitySpecs/Eligibility read-only with placeholder New Version buttons), AddItem modal opened from +Add Item button.

**What's NOT wired (deliberately Phase 2+ per `docs/superpowers/specs/2026-05-19-item-master-view-shell-design.md`):**
- Item list / item details DB read paths (Phase 2)
- Item Save / Deprecate / Add Item Create flows (Phase 3)
- Container Config save (Phase 4)
- Routes versioning workflow — own design + plan (Phase 5)
- BOMs versioning workflow — own design + plan (Phase 6)
- Quality Specs cross-navigation (Phase 7)
- Eligibility editor (Phase 8)

**Pickup notes for next session:** Designer-side smoke test of the page (5G0 dummy data renders, item rows click, fields edit + dirty indicator flips through embedded boundary, all 5 tabs visible). The bidi-on-Object-param mechanism for Embedded View `props.params.value` is the architectural risk — if it doesn't round-trip when smoke tested, fall back per R1 in the design doc.

### 🟠 Audit-pages customMethods addressing bug (2026-05-19 — fixed same day, note retained)

The `view.custom.editDraft` / `view.custom.selected` dirty-check binding in the audit views surfaced a `customMethods` scope issue: `root.scripts.customMethods` attaches methods to the ROOT COMPONENT, not to the view. Addressing inside a view-level onChange script must use `self.rootContainer.X()` (not `self.X()` or `self.view.X()`). Fixed in the same session; see `feedback_ignition_view_customMethods_scope.md` memory for the full pattern. Relevant for any future view that calls `customMethods` from within embedded-view or event-handler context.

---

## OIR Status (v2.17, 2026-05-01)

54 items total: **47 resolved, 0 in review, 6 open, 1 superseded.**

- **Open Part A:** OI-32 (Material Allocation framing — Ben), OI-33 (AIM pool hard-fail — MPP Ops / IT), OI-34 (production schedule leverage — Production Control), OI-35 (scaling / retention — Blue Ridge architecture + MPP IT) **HARD GATE**
- **Open Part B:** UJ-05 (Sort Cage serial migration — MPP Quality + Honda), UJ-19 (PD replacement — Ben + Production Control name the four reports)

---

## Decision Owners

Items genuinely gating downstream work, by owner:

1. **OI-35 Architecture Decision Workshop** — Blue Ridge architecture lead + MPP IT (retention-policy negotiation). Gates Arc 2 Phase 1 SQL build.
2. **Phase 0 Customer Validation Workshop with MPP** — 9 gating items above. Gates Arc 2 Phase 1 SQL build.
3. **Ben** — OI-32 close-as-not-reproduced confirmation; OI-31 rollout-shape decision is no longer gating (OI-31 closed 2026-05-01 with the +10K seed-offset rule; rollout shape is operationally informational only). Memo at `Meeting_Notes/2026-04-24_OI-31_Single-Line_Deployment_Impact.md`.
4. **Tom (security SME)** — final elevated-action list validation (FDS-04-007).

---

## Build Status

- **Configuration Tool (Arc 1):** Phases 1–8 + G.1–G.5 + 0013 corrections + 0014 LocationTypeDefinition CRUD support complete. Audit page procs (FailureLog_List, ConfigLog_List, FailureLog_DistinctProcedures) landed 2026-05-19. Phase 5 Routes versioning + Phase 6 BOMs versioning landed 2026-05-26. **1034/1034 tests passing** across 24+ test suites.
- **SQL artifacts:** `/sql/` folder, **16 versioned migrations** (latest: `0015_audit_add_event_type_deleted` + `0016_parts_bom_unique_draft`) **+ 230+ repeatable procs.** PowerShell reset script `Reset-DevDatabase.ps1` auto-discovers and runs all scripts via `sqlcmd.exe`. Tested on SQL Server 2025.
- **Plant Floor (Arc 2):** Mockup landed at `mockup/plantFloor.html` (12 terminal/lot routes + Home Page). SQL not yet started — gated on Phase 0.
- **Ignition project (live build, Arc 1):** Phase 1 Location pipeline + toasts + scan helper landed 2026-05-12. LocationTypeEditor full stack 2026-05-13. **Convention rectification 2026-05-14** — `Common.Db`/`Common.Util`/`Common.Ui` layer built, `Common.Action` deleted, 5 entity scripts retrofitted through Common helpers, LocationTypeEditor view restructured to `editDraft`/`selected` pattern + dirty indicator + Cancel, all NQs normalized (camelCase identifiers, Designer-canonical sqlType enum, v2 schema). Designer smoke-test pending. Audit pages (FailureLog + AuditLog) landed 2026-05-19 with the customMethods addressing bug fixed same day. **Downtime Codes Ops view wired 2026-05-19** — first Config Tool admin surface to combine live-data List + popup editor + page-scoped refresh pulse (separate pattern from the audit-browser read-only pattern).
- **Seed data loading:** CSVs ready in `reference/seed_data/` (876 rows total). `machines.csv` not yet loaded; MPP parts list not yet provided; `defect_codes.csv` not yet loaded; `downtime_reason_codes.csv` has bulk-load proc but not yet invoked.

---

## Source-of-Truth Doc Locations

| Doc | Markdown source | Word output |
|---|---|---|
| Data Model | `MPP_MES_DATA_MODEL.md` | `MPP_MES_DATA_MODEL.docx` |
| FDS | `MPP_MES_FDS.md` | `MPP_MES_FDS.docx` |
| FDS Changelog | `MPP_MES_FDS_CHANGELOG.md` | `MPP_MES_FDS_CHANGELOG.docx` |
| OIR | `MPP_MES_Open_Issues_Register.md` | `MPP_MES_Open_Issues_Register.docx` |
| User Journeys | `MPP_MES_USER_JOURNEYS.md` | `MPP_MES_USER_JOURNEYS.docx` |
| Phased Plan Plant Floor | `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` | `MPP_MES_PHASED_PLAN_PLANT_FLOOR.docx` |
| Seeding Registry | `MPP_MES_SEEDING_REGISTRY.md` | `MPP_MES_SEEDING_REGISTRY.docx` |
| ERD | `MPP_MES_ERD.html` | — |

Arc 2 revisions spec: `docs/superpowers/specs/2026-04-23-arc2-model-revisions.md` (still untracked in working tree).

Indexing review (carries OI-35 Decision Gate callout): `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`.

Phase G capability snapshot: `Meeting_Notes/2026-04-22_Phase_G_Capabilities_Summary.md`.

---

## Recent Change Narrative

A timeline of session-by-session changes. Most recent first.

### 2026-06-05 — SQL/Ignition hardening session (parallel to the Tools work)

A separate workstream from the Tools Config Tool session above. Five things landed, all committed on `jacques/working`, SQL suite green **1165/1165** throughout.

- **Re-enabled the 13 legacy-seed-coupled SQL tests** (`2f27b04`). They had been deactivated when the legacy `010` location sample was dropped for the real MPP plant seed (`011`). Refactored with the **hybrid** strategy: mutation/CRUD tests resolve area/cell anchors dynamically per `GO`-batch (`SELECT TOP 1 ... WHERE LocationTypeDefinitionId = N` / `OFFSET` for distinct ones) instead of hardcoded Ids/Codes; pure seed-read tests derive expected counts via direct `COUNT`. `MPP-MAD` reused for the Tools non-Cell rejection case. `_disabled/` folders removed. Memory `project_mpp_location_seed_and_disabled_tests` updated to RESOLVED.
- **Ignition entity-script code review** across all 29 `BlueRidge.*` modules, fixes applied in three buckets (`2c909ac`): correctness (RouteTemplate `json.dumps`→`convertWrapperObjectToJson`, Eligibility itemId unwrap, QualitySpec `listVersions` filter, Tree default icon, Notify TTL, Db `is not None` guard, dead import, DieRank dict-index + null guards); a wrapper-safe JSON-encode sweep (6 sites → `convertWrapperObjectToJson`); convention enforcement (RouteTemplate `appUserId`-from-session, Tool DataType allowlist → proc, QualitySpec draft-check dedup + label consolidation). Deferred by design: #3 DowntimeReasonType dropdown, #9 `eligibleTypes`, #11 `"Route v1"` default.
- **Demo item 5G0 fully configured** (`829698e`) — extended `020_seed_items.sql` so item 1 (5G0) populates every Item Master tab: 14 `OperationTemplateField` rows, 7 `QualitySpecAttribute` rows (Dimensional Numeric + Visual Text/Boolean), 4 `ItemLocation` eligibility rows (DieCastMachine cells, one consumption point). Idempotent, ASCII-only, locations by Code.
- **Committed the `0018` tooltype-compat SQL** (`9d10ae3`) and fixed an unrelated INSERT-EXEC drift it caused in `0013_Tools_Types/010_Types_read` (temp tables widened for the new `CompatibleLocationTypeDefinitionId` column).
- **Routes-tab StateBadge custom-prop fix** (`7e79563`) — `view.custom.selectedHeader` (and `versions`, etc.) were referenced by bindings but existed only in `propConfig` with no default, and the `getHeader` binding returned `None` for an unselected version, so nested reads errored. Declared all bound props in the `custom` block with shaped defaults and added `RouteTemplate.getHeaderOrEmpty` → `_EMPTY_HEADER` so the binding source is never `None`. Codified the rule in CLAUDE.md, `ignition-context-pack/02_perspective_views.md`, and memory `feedback_ignition_predeclare_bound_custom_props`.

### 2026-05-20 — Item Master Phase 2: read paths + R1 smoke test bed

Phase 2 of the 8-phase Item Master Configuration Tool. Three new Named Queries (`parts/Item_List`, `parts/Item_Get`, `parts/ContainerConfig_GetByItem`) wrap existing stored procs. Two new entity scripts (`BlueRidge.Parts.Item`, `BlueRidge.Parts.ContainerConfig`) route through `Common.Db`. The parent `ItemMaster/view.json` now binds `view.custom.items` to a `runScript(BlueRidge.Parts.Item.getAllForList, ...)` expression and its `itemRowClicked` handler calls the live entity scripts to populate `view.custom.editDraft.meta` + `view.custom.editDraft.containerConfig` from the DB. The other four tab slices (routes/boms/qualitySpecs/eligibility) are left empty until their own phases land.

**No SQL changes.** Tests stay at 937/937 (existing `Parts.Item_List`, `Parts.Item_Get`, `Parts.ContainerConfig_GetByItem` reused as-is).

**Spec:** `docs/superpowers/specs/2026-05-20-item-master-phase2-design.md`
**Plan:** `docs/superpowers/plans/2026-05-20-item-master-phase2.md`

**Files touched (8 created + 2 modified):**
- 3 new NQ folders under `ignition/projects/MPP_Config/ignition/named-query/parts/`
- 2 new entity script modules under `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/`
- 1 view edit + resource.json metadata bump on `BlueRidge/Views/Parts/ItemMaster/`

**R1 smoke verification — PENDING.** Designer smoke checklist in spec §9. R1 holding is the precondition for Phase 3-8 building on the bidi-embed pattern. If smoke fails, the page-scoped message fallback documented in spec §2 governs the rebuild.

**Worktree:** built in `.claude/worktrees/Agent-B-item-master-phase2` on branch `worktree-Agent-B-item-master-phase2`. Ready to merge to main once R1 smoke verifies green.

**Next pickup:** Jacques walks the R1 smoke checklist in Designer. On pass → Phase 3 (Item Save / Deprecate / Add Item Create) brainstorming, including cleanup of the `PartsPerBasket` Identity field that doesn't map to a real `Parts.Item` column. On fail → fallback design cycle (page-scoped messages instead of bidi-embed).

### 2026-05-19 — Item Master Phase 1 view shell

Phase 1 of an 8-phase Item Master Configuration Tool build (per `docs/superpowers/specs/2026-05-19-item-master-view-shell-design.md` + `docs/superpowers/plans/2026-05-19-item-master-view-shell.md`).

**Files landed (8 new view files + 1 config edit):**
- `page-config/config.json` — added `/items` route entry
- `views/BlueRidge/Views/Parts/ItemMaster/{resource.json, view.json}` — page shell
- `views/BlueRidge/Components/Parts/ItemMaster/ItemRow/{resource.json, view.json}` — flex-repeater row sub-view
- `views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/{resource.json, view.json}` — tab 1 (editable form)
- `views/BlueRidge/Components/Parts/ItemMaster/Routes/{resource.json, view.json}` — tab 2 (published-only table)
- `views/BlueRidge/Components/Parts/ItemMaster/Boms/{resource.json, view.json}` — tab 3 (published-only table)
- `views/BlueRidge/Components/Parts/ItemMaster/QualitySpecs/{resource.json, view.json}` — tab 4 (read-only linked list)
- `views/BlueRidge/Components/Parts/ItemMaster/Eligibility/{resource.json, view.json}` — tab 5 (Area dropdown + machine table)
- `views/BlueRidge/Components/Popups/AddItem/{resource.json, view.json}` — +Add Item modal shell

**Architecture:**
- Parent ItemMaster holds all state on `view.custom` (items, selected, editDraft, itemTypes, uoms, activeTab, mode, search, typeFilter)
- 5 always-mounted Embedded Views in TabPanels, gated by `position.display = "{view.custom.activeTab} = '<key>'"`
- Each embedded tab's `props.params.value` bidirectionally bound to `view.custom.editDraft.<slice>` — child form-field writes propagate back up through the embed boundary (R1 in the design doc — first use of this pattern in the project, needs Designer smoke validation)
- ItemRow flex-repeater fires page-scoped `itemRowClicked` message handled by `root.scripts.messageHandlers[0]` on the parent
- Save / Deprecate / Create Item / New Version buttons all fire `BlueRidge.Common.Notify.toast(...)` placeholders for Phases 3/5/6

**Roadmap forward:** Phase 2 wires read paths; Phase 3 wires Item mutations + Add Item Create; Phase 4 Container Config save; Phases 5/6 are substantial Routes/BOMs versioned-entity workflows that warrant their own design docs. Phases 7/8 are Quality Specs cross-link and Eligibility editor.

### 2026-05-19 — Downtime Codes Ops view wired end-to-end (first Config Tool admin surface)

Plan + spec committed first (`docs/superpowers/specs/2026-05-19-downtime-codes-wiring-design.md` + `docs/superpowers/plans/2026-05-19-downtime-codes-wiring.md`), then executed via subagent-driven development across 9 tasks. Scaffolded `Views/Oee/DowntimeCodes` was sample-data only; this session turned it into a fully interactive admin surface.

**Backend layer** — 6 new NQs under `named-query/oee/` (`DowntimeReasonCode_List` / `_Get` / `_Create` / `_Update` / `_Deprecate` plus `DowntimeReasonType_List` with 30-min cache). Two new entity-script modules: `BlueRidge.Oee.DowntimeReasonType` (`getAll`, `getForDropdown(includeUnassigned, includeAll)`) and `BlueRidge.Oee.DowntimeReasonCode` (full CRUD: `search/getOne/add/update/deprecate/emptyMeta`, with client-side `searchText` filter since the proc has no `@SearchText`). Added `BlueRidge.Location.Location.getAllAreas(includeAll)` as a peer read helper that filters the existing `location/GetTree` flat result for `HierarchyLevel == 2`.

**Spec-review catch** — Initial plan asserted Areas were `HierarchyLevel == 3` (ISA-95 ordinal counting). The project's seed (migration 0002 line 110) places Areas at `HierarchyLevel == 2` (zero-indexed: Enterprise=0, Site=1, **Area=2**, WorkCenter=3, Cell=4). Spec reviewer caught the defect before code shipped to a view; plan + spec corrected, code patched. Seeded Areas are DC/MS/QC/TS (4, not 3 -- QC included but downtime typically only uses the first 3).

**New popup view** — `BlueRidge/Components/Popups/DowntimeCodeEditor`: single popup for both Add and Edit via `view.params.mode = "create"|"update"` discriminator, with `editDraft/selected` state, dirty indicator, and `ConfirmUnsaved` wiring on both header X and footer Cancel. Code field is readonly in update mode (immutable post-create per the proc). Deprecate button visible only in update mode. Refresh pulse on Save/Deprecate via page-scoped `downtimeCodesRefresh` message.

**Wired existing views** — `BlueRidge/Components/DowntimeCodeRow` got an `id` input param and Edit button onClick → openPopup. `BlueRidge/Views/Oee/DowntimeCodes` got: filter keys renamed (`area` → `areaLocationId`, `reasonType` → `downtimeReasonTypeId`) to match proc params, hardcoded sample arrays replaced with `runScript` bindings, `+ Add Code` button wired to openPopup, repeater binding restructured with script transform mapping proc PascalCase → row-component lowercase keys, and `downtimeCodesRefresh` message handler at root that shallow-copies `view.custom.filter` to force re-eval of the rows binding.

**Bugs caught during smoke testing** —
- `scope: "C"` on `component.onActionPerformed` doesn't fire reliably; project standard is `scope: "G"` (matches PlantHierarchy + AuditLog precedent). Fixed both AddCodeButton and DowntimeCodeRow EditButton.
- `IncludeDeprecated` checkbox originally wrapped in a flex+label workaround; Jacques reverted to single-component `ia.input.checkbox.props.text` — works fine in normal-width containers. New memory entry `feedback_ignition_checkbox_text_prop_ok.md` corrects my earlier overcaution.
- Edit button on deprecated rows hidden via `meta.visible` (not `position.display`) to preserve column alignment across the tabular layout. New memory entry `feedback_ignition_meta_visible_in_tables.md` notes table rows are the legitimate exception to the "use position.display" convention.

**Visual polish** — Deprecated rows in the list rendered at 55% opacity (root `style.opacity` binding), Edit button hidden via `meta.visible: false`. Greyed visual + no Edit affordance for deprecated rows; toggle "Include deprecated" to surface them.

**Bulk-load explicitly deferred** — `Oee.DowntimeReasonCode_BulkLoadFromSeed` proc exists and is tested. One-shot cutover operation; will run from Designer Script Console with the 353-row seed JSON when MPP confirms the DC/MS/TS → AreaLocationId mapping. No UI button needed.

**SQL untouched** — no migrations or repeatable procs added. Test suite remains at 937/937.

**Generalizes** — this is the reference pattern for any future Config Tool admin surface where a single entity has full CRUD (no compound children — that pattern stays the `SaveAll` bundled-proc reference impl): List-Detail view with live runScript-bound rows, popup editor with mode discriminator + ConfirmUnsaved, page-scoped refresh pulse. Distinct from the audit-browser pattern (read-only with TOP cap + COUNT(*) OVER total).

**Parallel work landed same day** — audit-pages addressing bug (customMethods scope) fixed; `BlueRidge.Location.Location.listByTier(tierCode)` + `location/Location_ListByTier` NQ added as prep for the upcoming Defect Codes Config Tool screen.

### 2026-05-19 — Audit pages landed (FailureLog + AuditLog Config Tool browsers)

Design and plan committed first (`docs/superpowers/specs/2026-05-19-audit-pages-design.md` + `docs/superpowers/plans/2026-05-19-audit-pages.md`), then executed via 13 commits using the subagent-driven development pattern. Full SQL reset + test run closes the session at **937/937 tests passing**.

**SQL** — `Audit.FailureLog_List` and `Audit.ConfigLog_List` both received `TOP 1000` caps and `COUNT(*) OVER() AS TotalCount` window-aggregate columns, which drive the "Showing N of M — narrow your filter" banner on both pages. FailureLog_List gained `@FailureReasonLike` substring filter and `@LogEntityTypeId` filter; ConfigLog_List gained `@DescriptionLike` and `@SeverityId`. New `Audit.FailureLog_DistinctProcedures` proc powers the Procedure dropdown on the FailureLog page — returns every distinct `ProcedureName` that has ever logged a failure. Test extensions landed alongside each proc. Note on canonical column names: `Audit.ConfigLog` uses `LoggedAt`/`UserId` (not `ChangedAt`/`AppUserId`); the proc passes those through unchanged and downstream Ignition consumers use `loggedAt` / `userDisplayName` accordingly. 220 repeatable procs total.

**Ignition NQs** — 9 new named queries under `named-query/audit/`: `FailureLog_List`, `FailureLog_GetByEntity`, `FailureLog_GetTopReasons`, `FailureLog_GetTopProcs`, `FailureLog_DistinctProcedures`, `ConfigLog_List`, `ConfigLog_GetByEntity`, `LogEntityType_List`, `LogSeverity_List`.

**Entity scripts** — 4 new modules: `BlueRidge.Audit.LogEntityType` (`getAll`), `BlueRidge.Audit.LogSeverity` (`getAll`), `BlueRidge.Audit.FailureLog` (3-NQ-bundled `search()` returning `{rows, totalCount, topReasons, topProcs}`), `BlueRidge.Audit.ConfigLog` (1-NQ `search()` returning `{rows, totalCount}`). Both `search()` functions deep-unwrap their filter dict via `Common.Util._u()` at entry to defend against tile-click / bidirectional-binding QualifiedValue wrappers. `Common.Util.prettyJson` helper added — formats AttemptedParameters / Old / New JSON for the detail popups (try/except wrapper; falls back to raw text on parse failure).

**New views** — three new components written as files (new-view path; no Designer cache conflict): `BlueRidge/Components/Popups/FailureDetail` (single AttemptedParameters JSON block), `BlueRidge/Components/Popups/ConfigChangeDetail` (side-by-side Old + New diff blocks), `BlueRidge/Components/Audit/TopRow` (reusable tile-row sub-view shared between Top Reasons + Top Procs panels; fires page-scoped `applyFilterFromTile` message on tile click). FailureLog and AuditLog views fully wired: default date range = last 7 days, no auto-apply on load, explicit Apply + Reset buttons, TOP 1000 cap with banner. Tile-row click sets the appropriate filter field and triggers apply. FailureLog filter set: Date / EntityType / Procedure / AppUser / Search text. AuditLog filter set: Date / EntityType / Severity / Search text.

**Deviation noted** — AuditLog lost its AppUser dropdown during the wire pass; the original mockup's `UserDropdown` slot was repurposed to `SeverityDropdown`. The design called for AppUser filter on both pages. Tracked as a follow-up polish item; not blocking any other work.

**Proc return shapes documented** — TopReasons / TopProcs procs return `FailureCount` (not `Count`). The view's flex-repeater transform accounts for this.

**Session also included** (earlier commits, not audit-pages scope): FDS v1.2 (`ParentLocationId` immutability rule, `5bd3d80`) and plant hierarchy view work (`d0d5355`).

### 2026-05-15 — LocationTypeEditor smoke test + close-confirmation dialog

Two commits landed:
- `f469061` fix(loc-type-editor): dirty indicator + attribute-table alignment
- `7ab9cd3` feat(loc-type-editor): close-confirmation dialog for unsaved work

**Smoke test — all 8 flows pass.** Tier select, definition pick, edit + dirty indicator, Cancel revert, Save commit (audit verified — `Audit.ConfigLog` rows 251/252 with full pre/post payloads), Add Definition, Add/Remove Attribute, Deprecate (FK guard rejects active-Location references with graceful toast).

**Fixes landed:**

- Attribute row text-field events moved from `events.component.onActionPerformed` (no-op — text-fields don't have Component Events at all) to `events.dom.onBlur` for AttributeName / DefaultValue / Uom / Description. Dirty indicator now fires when user tabs out of any attribute field.
- AttrTableHeader column basis / grow aligned with AttributeDefinitionRow. ColArrows + ColRemove converted from `ia.display.label` to `ia.container.flex` (empty labels were collapsing despite `basis`).
- Pulled `min-width: 180px` from `.psc-search-input` — class was overloaded as a generic input look across 24 sites, and the 180px floor was overriding flex sizing in every attribute-row cell.

**New view:**

- `BlueRidge/Components/Popups/ConfirmUnsaved` — parameterised 3-button popup (Save & Close / Discard & Close / Cancel). LocationTypeEditor's CloseIcon + footer CloseButton now dirty-check before closing; if dirty, open this popup; user's choice routes back via page-scoped `confirmUnsavedResult` message handler. Reusable across future editors — see `project_mpp_confirm_unsaved_pattern.md` memory.

**Workflow learning — file-edit boundary established.** view.json edits to existing views are unreliable due to (a) Designer's GSON serialization of `=` / `'` / `<` / `>` as 6-char unicode escapes (`=` etc.) that fight tool JSON-parsing, and (b) Designer's in-memory cache conflicts. The Designer "Files vs Gateway" conflict dialog also has confusing semantics — picking "Gateway" pushed Designer's cached state to disk and overwrote our file edits.

Established split going forward (also added to CLAUDE.md):

| File type | Edit path |
|---|---|
| view.json (existing views) | Designer — Claude writes Designer-step instructions |
| view.json (new views) | File + scan — no Designer cache to conflict with |
| stylesheet.css | File |
| Python script modules | File |
| NQ `query.sql` / `resource.json` | File |
| SQL migrations / procs | File |

**Cosmetic items still open** (next session):

- TypeBadge `nameForTier` runScript returns NULL — needs gateway-log traceback to diagnose
- Description input renders literal "null" when DB value is NULL — coalesce missing on read path
- `â€` garble on em-dash placeholders — UTF-8 / Latin-1 mismatch somewhere in render pipeline

**Memory added/updated:**

- NEW `feedback_ignition_designer_unicode_escapes.md` — Designer 8.3 GSON escape style for `=` / `'` / `<` / `>` and how to match it when file-editing view.json scripts.
- NEW `project_mpp_confirm_unsaved_pattern.md` — reusable ConfirmUnsaved popup pattern for editors with `editDraft` / `selected` state.
- UPDATED `feedback_ignition_view_edit_boundary.md` — conflict-resolution dialog learning ("Gateway" overwrites disk with Designer's cache, not the inverse).

**Context pack additions:**

- `02_perspective_views.md` — note on Designer's GSON unicode-escape serialization
- `07_conventions_and_antipatterns.md` — close-confirmation popup pattern + text-field-events caveat (no Component Events; use `dom.onBlur`)

### 2026-05-14 — Convention rectification per Hunter's pack updates

Hunter merged in pack updates (`hunter/explore` → `main` fast-forward, commits `784a981` / `591da53` / `cf0fb42` / `fc534bf`) that source the `ignition-context-pack/` from `MPP_MES_CONFIG_TOOL_FRONTEND_CONVENTIONS.md` v1.2 and document the `SaveAll` bundled pattern. Our 2026-05-12/13 Ignition work was built against the older pack and deviated in several places. Today's session rectified the deviations as a coordinated four-phase pass.

Decision sheet: `Meeting_Notes/2026-05-14_Convention_Rectification_Review.md` (line-by-line response document with Jacques's per-item decisions).

**Phase 1 — Foundation built (Common helpers):**

- **`BlueRidge.Common.Db`** — `execList` / `execOne` / `execMutation`. Only layer that calls `system.db.runNamedQuery`. Handles BIT Status convention.
- **`BlueRidge.Common.Util`** — `log` (inspect-frame auto-fill of calling module + function), `_currentAppUserId` (reads `session.custom.appUserId` with dev fallback to AppUser.Id 2), `extractQualifiedValues`, `convertWrapperObjectToJson`.
- **`BlueRidge.Common.Ui.notifyResult(result, successTitle, successMsg, errorTitle)`** — routes mutation result to toast.
- **`BlueRidge.Common.Notify.toast`** — `DEFAULT_TTL_SEC` 8 → 5 per C1 decision.
- **`BlueRidge.Common.Action`** deleted (was the parallel-universe `execMutation` that mixed DB + toast).
- **`BlueRidge.Common.Session.getCurrentUserId`** now a thin shim over `Common.Util._currentAppUserId`.

**Phase 2 — Entity scripts retrofitted + NQ casings normalized:**

- 5 entity scripts (`Location.Location`, `Location.Tree`, `Location.LocationType`, `Location.LocationTypeDefinition`, `Location.LocationAttributeDefinition`) rewritten to route every DB call through `Common.Db.*`. All `system.db.*` direct calls eliminated outside `Common.Db`. Per-module logger declarations removed; replaced with direct `Common.Util.log(...)` calls. 5 copies of local `_rowsToDicts` helper deleted.
- Module surface standardized per pack convention: `listByType` → `getAll`, `listByDefinition` → `getAll`, `listAll` → `getAll`, `get` → `getOne`. Custom domain handlers (`handleMoveUp`/`handleMoveDown`/`handleSaveAll`/`handleDeprecate`/factories) kept per Jacques's A4 decision ("standard is starting point, not complete list").
- 9 NQ files normalized: parameter identifiers → camelCase (`LocationID`/`UserID`/`Id`/`AppUserId` → `locationId`/`userId`/`id`/`appUserId`); query.sql `:placeholder` references updated to match.
- `Get/resource.json` bumped v1 → v2 schema (was the latent Designer-NPE bug flagged 2026-05-13).
- `print ds` stripped from `Location.code.py:124` (B1); `Tree.code.py` header rewritten to standard module shape (B2).

**Phase 3 — LocationTypeEditor view restructured to editDraft/selected pattern:**

- `view.custom.meta` + `view.custom.attributesDraft` → `view.custom.selected` (baseline) + `view.custom.editDraft` (in-flight), each carrying `{meta, attributes}`.
- All form bindings repointed to `editDraft.meta.*`; attributes repeater binding to `editDraft.attributes`.
- 4 message handlers (`definitionClick`, `attrDraftUpdate`, `attrDraftRemove`, `attrDraftMove`) rewritten to mutate `editDraft.attributes` and maintain the `selected` baseline on selection changes.
- 5 inline scripts rewritten (Save, Deprecate, +Add Definition, +Add Attribute, TierDropdown onChange) for the new state shape.
- **New:** dirty indicator label bound to `if({view.custom.editDraft} != {view.custom.selected}, "● Unsaved changes", "")` per pack universal rule.
- **New:** Cancel button in DetailsHeader — reverts `editDraft = dict(selected)` in update mode; resets to view mode in create mode; hidden when no pending changes.
- Save handler does proper deep-copy commit on success (`selected = {meta: dict(...), attributes: [dict(a) for a in ...]}`) so the dirty indicator clears.

**Phase 4 — Pack contributions + memory updates (two-way street):**

- **`ignition-context-pack/03_script_python.md`**: `execMutation` updated for BIT Status convention; full SP shape (`DECLARE @Status BIT = 0`) baked in verbatim. `notifyResult` signature updated. **New `Common.Notify` section** documenting popup-per-toast surface (top-right FIFO max 5, errors persist, non-errors auto-dismiss 5s — supersedes the single-banner pattern; toast is now THE standard, no variant). `runNamedQuery` vs `execQuery` clarified.
- **`ignition-context-pack/04_named_queries.md`**: Status-row pattern rewritten with verbatim SP shape. **sqlType section rewritten** with the empirically-verified Designer-canonical enum table (Int1/Int2/Int4/Int8/Float4/Float8/Boolean/String/DateTime/ByteArray = 0/1/2/3/4/5/6/7/8/20) — explicit warning that `java.sql.Types` codes are irrelevant. NQ v2 schema section added.
- **`ignition-context-pack/07_conventions_and_antipatterns.md`**: mutation feedback section updated for toast; **new "Mode discriminator on shared add/edit popups" section** (C4); all `Status='OK'`/`'ERROR'` references updated to BIT 1/0.
- **`ignition-context-pack/02_perspective_views.md`**: **new "Tree mutations — return `{items, selectedPath, selected}`" section** (C2) documenting our re-anchor pattern and the `Tree.props.selection` writeback misfire workaround.
- **`ignition-context-pack/00_README.md`**: file-13 / file-14 descriptions updated.

**sqlType correction (A9 → empirical resolution):**

Initial reading of A9 had me writing `sqlType: 2` for BIGINT (based on observing existing Designer-saved NQs with that code). Jacques provided an empirical reference (Designer-saved NQ with one parameter of every type) that revealed **Designer uses its own internal type enum, NOT `java.sql.Types`**:

| sqlType | Designer name | DB type |
|---|---|---|
| 0 / 1 / 2 / 3 | Int1 / Int2 / Int4 / Int8 | TINYINT / SMALLINT / INTEGER / **BIGINT** |
| 4 / 5 | Float4 / Float8 | REAL / FLOAT |
| 6 | Boolean | BIT |
| 7 | String | **NVARCHAR / VARCHAR** |
| 8 | DateTime | DATETIME |
| 20 | ByteArray | VARBINARY |

Existing Designer-saved NQs in the project had BIGINT params with `sqlType: 2` (Int4) — that was a UI selection mistake by whoever created them; SQL Server's INT → BIGINT silent coercion meant the procs worked anyway. All NQ resource.json files corrected: BIGINT params `2` → `3`, NVARCHAR params `-9` → `7`. Memory entry `feedback_ignition_nq_resource_schema.md` updated with the full Designer enum.

**Memory entries added/updated:**

- UPDATED `feedback_ignition_nq_resource_schema.md` — full Designer sqlType enum table; corrects earlier "sqlType 2 for BIGINT" claim.

**Files touched (42 total):**

- 3 new Common modules (Db, Ui, Util) — 6 files
- 1 deleted module (Action) — 2 files
- 9 NQ folders modified (resource.json + query.sql each)
- 5 entity scripts rewritten
- 1 view (LocationTypeEditor) restructured
- 5 pack files updated
- 1 PROJECT_STATUS.md updated
- 1 memory file updated
- 1 review markdown added to Meeting_Notes/

**Next pickup:** smoke-test the LocationTypeEditor modal in Designer end-to-end (tier select, definition pick, edit fields with dirty indicator, Cancel revert, Save commit, Add Definition flow, Add Attribute flow, Deprecate FK guard).

### 2026-05-13 — LocationTypeEditor modal: full vertical stack scaffolded (WIP)

Big day. Built the complete top-to-bottom stack for the Plant Hierarchy view's cog-button "Location Type Editor" modal: SQL migration + procs + tests, named queries, entity scripts, embedded views, popup view, and the cog-button onClick wiring. **907/907 SQL tests pass.** End-of-day smoke-test in Designer still surfaces issues; modal is NOT FULLY WORKING yet but the full surface area is in place to iterate from.

**SQL (all green, all tests passing):**

- **Migration 0014** — `0014_locationattributedefinition_unique_active_name.sql`. Filtered UNIQUE index on `Location.LocationAttributeDefinition(LocationTypeDefinitionId, AttributeName) WHERE DeprecatedAt IS NULL`. Defends the bundled save proc against active-name collisions; allows reuse of deprecated names. **Note:** this slot was originally reserved for Arc 2 Phase 1's `0014_arc2_phase1_shop_floor_foundation.sql`. That work shifts to `0015` when it lands (SQL queue updated accordingly).
- **`R__Location_LocationTypeDefinition_SaveAll.sql`** — bundled save proc. Meta as params (`@Id`, `@LocationTypeId`, `@Code`, `@Name`, `@Icon`, `@Description`, `@AppUserId`) + `@AttributesJson NVARCHAR(MAX)`. Server-side reconciliation: OPENJSON parse → validate within-batch uniqueness + immutable Code/LocationTypeId on update → DEPRECATE missing children → UPDATE Id-matched (SortOrder = array index) → INSERT NULL-Id rows → one Audit row with full pre/post snapshot → status-row SELECT. See `project_mpp_bundled_save_pattern.md` memory.
- **`R__Location_LocationTypeDefinition_Deprecate.sql`** — soft-delete with cascade to active children. FK guard rejects when active `Location.Location` rows reference. Idempotent re-deprecate returns `Status=1, Message='Already deprecated.'`.
- **Tests:** `030_LocationTypeDefinition_SaveAll.sql` (12 scenarios), `040_LocationTypeDefinition_Deprecate.sql` (6 scenarios). All assertions pass.

**Ignition (scaffolded, end-of-day modal still buggy in Designer):**

- **5 named queries:** `location/LocationType_List`, `LocationTypeDefinition_List`, `LocationAttributeDefinition_ListByDefinition`, `LocationTypeDefinition_SaveAll`, `LocationTypeDefinition_Deprecate`. Resource.json forced to v2 schema after Designer 8.3.5 NPE'd on v1 inheritance from the `Get` NQ template.
- **3 entity script modules:** `BlueRidge.Location.LocationType` (`listAll`, `nameForTier`), `BlueRidge.Location.LocationTypeDefinition` (`listByType`, `handleSaveAll`, `handleDeprecate`, `emptyMeta`, `emptyAttributeRow`, `metaFromDefinition`), `BlueRidge.Location.LocationAttributeDefinition` (`listByDefinition`). All read functions wrap their `system.db.execQuery` calls in try/except with error-toast on failure.
- **`Common.Action.runMutation` upgraded** — now returns the status-row dict (or None) instead of bool. Backwards-compatible (truthy/falsy preserved); `handleSaveAll` reads `result["NewId"]` from the return.
- **3 new views:** `BlueRidge/Components/AttributeDefinitionRow` (editable row sibling of read-only AttributeRow), `BlueRidge/Components/DefinitionItem` (chip/button for tier-scoped definition selection, root = flex with label inside), `BlueRidge/Components/Popups/LocationTypeEditor` (the modal — tier dropdown + definitions repeater + Definition Details panel + Attribute Definitions table + footer Close).
- **PlantHierarchy/view.json** cog icon (`LocationTypeEditorButton`) wired to `dom.onClick` opening the modal via `system.perspective.openPopup(id='mpp-loc-type-editor', view='BlueRidge/Components/Popups/LocationTypeEditor', modal=True, ...)`.

**Bugs hit + fixed during the day** (each = a memory entry now):

1. **Toast popup auto-dismiss never fired** — `view.custom.dismissAt` had no binding, so the polled `now(500) > dismissAt` expression stayed false forever. Fix: add an expression binding on `dismissAt` that computes `dateArithmetic(now(0), {view.params.ttl}, 'second')`. Updated `project_mpp_toast_system.md`.
2. **Tree-selection re-anchor pattern** — when items change programmatically the selection path goes stale. Fixed by having `handleMoveUp`/`handleMoveDown` return `{tree, selectedPath, selected}` so the view writes all three atomically. Same pattern can be reused for any future tree-mutating action.
3. **NQ resource.json schema v1 vs v2** — Designer 8.3.5 NPEs on v1 shape. Bumped all 5 new NQs to v2 with the Designer-saved field order. Pre-existing `location/Get` is still v1 — flagged for cleanup. New memory: `feedback_ignition_nq_resource_schema.md`.
4. **`def list()` shadowed Python builtin** in `BlueRidge.Location.LocationType` — broke `_rowsToDicts`'s `list(...)` call. Renamed to `listAll()`. Genuine junior miss; flagged it as such in the conversation. Update Plant Hierarchy view + binding to call `listAll`.
5. **Message scope: view vs page** — `scope='view'` doesn't propagate from an embedded view to its parent. Chip click from inside `DefinitionItem` with `scope='view'` never reached the popup's `definitionClick` handler. Fix: change to `scope='page'` and flip handler config to `pageScope: true`. Same fix applied to `attrDraftUpdate`/`attrDraftRemove`/`attrDraftMove` from `AttributeDefinitionRow`. New memory: `feedback_ignition_message_scope.md`.
6. **`lookup()` expression function** requires a Dataset, doesn't work against `list[dict]` from `runScript`. TypeBadge expression failed because tiers is a list[dict]. Fix: added `nameForTier(tiers, tierId)` helper in `LocationType` module, called via `runScript`. New memory: `feedback_ignition_lookup_dataset_only.md`.
7. **`DefinitionChip` view was rooted at `ia.input.button`** — non-idiomatic, didn't render text. Rebuilt as `ia.container.flex` root with `ia.display.label` child. Folder renamed `DefinitionChip` → `DefinitionItem`; "chip" terminology replaced with "definition" everywhere (function `chipsFromDefinitions` → `definitionItemsFor`, prop `view.custom.chips` → projection removed entirely, meta names `Chips*` → `Definitions*`, message `defChipClick` → `definitionClick`).
8. **Read-side silent failures upgraded to toasts** — all three list functions (`listAll`, `listByType`, `listByDefinition`) now catch exceptions and fire an error toast before returning `[]`. The `definitionClick` message handler also fires warning toasts on null payload + stale-id-not-in-list paths.

**Memory entries added/updated:**

- NEW: `feedback_ignition_nq_resource_schema.md` — v2 schema required, clone shape from Designer-saved file
- NEW: `feedback_ignition_message_scope.md` — view vs page, use page for embedded→parent
- NEW: `feedback_ignition_lookup_dataset_only.md` — Dataset-aware expr fns don't work on list[dict]
- NEW: `project_mpp_bundled_save_pattern.md` — the SaveAll-with-JSON-deltas pattern as project standard
- UPDATED: `project_mpp_toast_system.md` — dismissAt wiring formula
- UPDATED: `feedback_readonly_type_tables.md` — LocationTypeDefinition now CRUDable (LocationType stays read-only)

**Next session pickup:**

1. Open Designer fresh, pull project, double-click each new NQ to confirm none Designer-NPE
2. Open LocationTypeEditor modal via the cog button on Plant Hierarchy
3. Verify tier dropdown populates, definitions repeater renders DefinitionItems, click flow propagates selection to Definition Details + Attribute Definitions panels, Save round-trips through the bundled proc, Deprecate FK-guards on tiers with active Locations
4. Whatever isn't working at that point — fix and iterate

### 2026-05-12 — Internal Docs Portal landed

Built and shipped the v1 internal docs portal — a self-contained static HTML site at `docs_portal/` that consolidates **FDS + Data Model + OIR + ERD** into one browsable, searchable surface for the Blue Ridge team. Internal-only; does NOT replace the `.docx` deliverables to MPP.

**What's in v1:**

- Four pages: `fds.html`, `data-model.html`, `oir.html`, `erd.html` (the ERD is iframed — no rewrite), plus an `index.html` meta-refresh to FDS.
- Shared shell: sticky header nav, sticky TOC sidebar with `IntersectionObserver`-driven active-section highlight, dark theme matching the ERD palette (`#0f1117` bg / `#6c8aff` accent).
- Cross-doc full-text search via **MiniSearch** — section-level granularity (every h2 + h3), ~277 entries, ~470 KB serialized index, lazy-loaded into a modal triggered by `🔍` button or `/` key.
- Six custom markdown-it plugins:
  1. `heading_permalinks` — adds clickable `#` chips on h2/h3/h4, canonicalizes FDS-XX-NNN and OI-XX/UJ-XX heading ids
  2. `anchor_fds_req` — wraps bold-inline `**FDS-XX-NNN**` references in section anchors
  3. `scope_pill` — backticked scope tags (`MVP`, `CONDITIONAL`, etc.) render as colored badges
  4. `cross_doc_link` — bare `FDS-XX-NNN`, `OI-XX`, `UJ-XX`, `Schema.Table`, `(FRS X.Y.Z)` refs in body text auto-link across docs (only for known schema tables, validated against a pre-parsed allowlist)
  5. `oi_badge` — inline 🔓 OI-XX chip on FDS h4 requirements that an open OI references (8 live badges from the 6 open OIs)
  6. `schema_table_anchor` — Data Model only, gives table h3s schema-prefixed slugs (`parts-operationtemplate`) so cross_doc_link's expected anchors actually resolve

**How to rebuild:** `npm run build:portal` (alias for `node tools/build_docs_portal.js`). Idempotent — wipes and rebuilds `docs_portal/`. Test suite: `npm run test:portal` (38 tests across the generator + plugins + smoke tests).

**Spec + plan:** `docs/superpowers/specs/2026-05-12-docs-portal-design.md` (approved 2026-05-12) and `docs/superpowers/plans/2026-05-12-docs-portal.md` (17 tasks, executed via subagent-driven development).

**Three plan deviations corrected during build:**

1. `buildToc` regex strip left scope-pill text in TOC labels — added a span-strip pre-pass. Same issue with permalink `#` chips — added an anchor-strip pre-pass.
2. The FDS source uses `#### FDS-XX-NNN — Title` h4 headings, not `**FDS-XX-NNN**` bold inline (plan got this inverted). Both `heading_permalinks` and `oi_badge` were extended to recognize the h4 form. 8 live OI badges now appear on FDS.
3. The OIR's `### OI-XX — long description` headings were producing slugified ids that didn't match the bare `oir.html#oi-35` hrefs the cross-doc plugins generate. Added OIR-pattern canonicalization to `heading_permalinks` (mirrors the FDS pattern handling).

Each plan correction landed as a small `fix(portal):` commit so the chain is auditable.

### 2026-05-07 — MPP custom Perspective icon library landed

Built and deployed the `mpp` custom Perspective icon library against the lock spec in `mockup/icons.csv`. 34 unique icon sprites (35 logical icons; `cancel` covers both `close` and `reject` from `icons.csv`) at the locked Material Symbols Outlined / wght 300 / grade -25 / fill 0 / opsz 48 axes. Sprite at `ignition/icons/mpp/mpp.svg` (30 KB), companion `config.json` + `resource.json`, and a README at `ignition/icons/README.md` capturing the deploy + recolor recipe.

Three discoveries forced strategy changes from the original design spec, all captured in the README:

- **Ignition 8.3 moved custom icon libraries** from `data/modules/com.inductiveautomation.perspective/icons/<lib>.svg` (8.1) to `data/config/resources/core/com.inductiveautomation.perspective/icons/<lib>/` (8.3), with mandatory `config.json` + `resource.json` siblings. Folder name must equal library name. Gateway service restart needed — Scan File System is unreliable for modified-sprite reloads.
- **Material Symbols' native viewBox `0 -960 960 960` does not render** in 8.3 Perspective. Path data is remapped to viewBox `0 0 24 24` via `transform="translate(0 24) scale(0.025)"` on each path.
- **`fill="currentColor"` on the path doesn't propagate Perspective's color hook.** Perspective wraps each rendered icon in an outer SVG with `style="fill: currentcolor"`; SVG attribute fill on a child path overrides that cascade. Removing the fill attribute entirely lets the Icon component's top-level `color` prop or a Style Class `Text → Color` drive recolor.

Source for the SVGs: `github.com/google/material-design-icons` (the GitHub repo is the only place Google publishes Material Symbols at every variable-font axis combination including `gradN25`; `fonts.gstatic.com` exposes only `wght` and `fill`).

Spec + plan: `docs/superpowers/specs/2026-05-05-ignition-icon-library-design.md` and `docs/superpowers/plans/2026-05-05-ignition-icon-library.md`. Final-state commit: `8303f72`. Durable mechanics also captured in `CLAUDE.md` § Ignition custom Perspective icon library.

### 2026-05-04 — FDS v1.0 customer-review release

Cut FDS v0.11p → **v1.0**, the first customer-review release. Pre-release working-session history (v0.1 through v0.11p) archived in `MPP_MES_FDS_CHANGELOG.docx`; future revisions tracked in the FDS body itself.

- **Feedback-Welcomed callout** added prominently near the front matter, framing v1.0 as the critical-feedback window. Specific areas highlighted: plant-floor workflows (§5–§9), event-data capture, Honda traceability, integration touch points, scope boundary, the 6 remaining open items.
- **In-document Revision History** reset to start at v1.0 with one consolidated entry summarising the 16 sections covered + the 6 remaining open items. Pointer block to the standalone changelog removed.
- **`MPP_MES_FDS_CHANGELOG.md/.docx`** marked archival as of v1.0; standalone artifact retained as the historical record of design evolution but no longer appended to.

### 2026-05-01 — Outstanding Items extract + 9-item closure pass + companion FDS amendments

Built a focused 15-item working extract of the OIR (`MPP_MES_Outstanding_Items.md` / `.docx`) for customer review. Jacques marked it up by adding "Final decision" annotations to 9 items; clarified two follow-ups (per-Operation split flag confirmed as the implemented mechanism; UJ-19 four PD reports remain MVP scope while reports beyond the four = post-deployment change order); approved a four-doc landing pass.

- **OIR v2.17** (companion to this session) — closed OI-07, -24, -25, -27, -28, -29, -30, -31, UJ-03 → all ✅ Resolved with explicit Decision (2026-05-01) blocks. Counts shift: Part A Resolved 22 → 30, In Review 1 → 0, Open 11 → 4 (only OI-32, -33, -34, -35 remain). Part B Resolved 16 → 17, In Review 1 → 0, Open 2 → 2 (UJ-05, UJ-19). Grand total: 54 items, 47 resolved, 0 in review, 6 open, 1 superseded.
- **FDS v0.11p** — **FDS-16-003** amended: cutover-day seeding rule changed from "at or above the Flexware value" to a concrete `<Flexware-current> + 10,000` offset (or MPP-agreed delta). Sample post-offset cutover seeds: `Lot=1,720,932`, `SerializedItem=12,492`. The "Open items (OI-31)" paragraph absorbed into design fact (format carry-forward, no reset policy, ~30+ year rollover horizon). **FDS-12-015 NEW** — `§12.6 Notifications Posture — MVP` establishes banners-only via terminal-context broadcast (FDS-07-006a/b, elevation banners, hold tiles, AIM-pool alarm tiles); text and email notifications are out-of-MVP, future change order. **Embedded Open Items Register reduced** from 14 unresolved items to 6 (OI-33, OI-35, UJ-19 HIGH; OI-34, OI-32, UJ-05 MEDIUM); previously-omitted OI-35 row added.
- **`MPP_MES_Outstanding_Items.md/.docx` v2.0** — refreshed to the 6 remaining Open items only (OI-32, OI-33, OI-34, OI-35, UJ-05, UJ-19). Customer-facing working draft for Phase 0 / architecture-review walk-throughs.
- **No data model / SQL / UJ doc changes this session** — register entries + FDS prose only.
- **Phase 0 Track A items reduced** from 9 to 8 (OI-31 closed; sub-question Ben rollout-shape no longer Phase-0-gating). Active blockers stay: OI-35 architecture gate (HARD) + Phase 0 Customer Validation Workshop.

### 2026-04-30 — Arc 2 Plant Floor mockup + FDS amendments

Substantial day building the operator-facing UI mockup and correcting two FDS sections.

- **`mockup/plantFloor.html` + `mockup/plantFloor.css` + extracted `mockup/styles.css`** — 12 terminal/lot routes covering every operator surface in the Phased Plan v1.0: `home`, `terminal/initials`, `terminal/cell-context`, `terminal/diecast`, `terminal/trim-in`, `terminal/trim-out`, `terminal/machining-in`, `terminal/assembly`, `terminal/assembly-ns`, `terminal/sort-cage` (Serialized + Non-Serialized variants), `terminal/receiving`, `terminal/shipping`, `terminal/end-of-shift`, `lot/detail`. Home Page has plant-hierarchy tree dock + tabbed details panel (Location Details + LOT Search + Genealogy Lookup + Hold Management + Supervisor Dashboard with AIM Pool Wallboard tile). Cross-cutting modals: Elevation, BOM Rename, Idle Re-Confirm, Material Substitute Override, Change Cell Context. Print Failure Banner. Header has elevation toggle (mockup demo affordance), app-title-as-home-link, breadcrumb (terminal routes only), Config Tool nav-out (elevated only). Polymorphism via Flex Repeater + Embedded View. Per-action AD elevation pattern with secondary-color treatment for elevated buttons. 1080p scroll-free with inner-repeater scroll modifiers for high-N entity lists. Touch-friendly (44 px minimum touch targets, 56 px header).
- **FDS v0.11m → v0.11n** (commit `361f6a4`): **FDS-09-013** End-of-Shift Time Entry — selection mechanism corrected to button-toggle on both terminal modes. 3 toggleable buttons (Lunch · 30 min, Break 1 · 15 min, Break 2 · 15 min) tap-to-select / tap-to-deselect. No numeric duration entry. Differences between Dedicated and Shared scoped to identity capture only (Shared adds inline initials field + 3-button single-select Time Category — Regular / Overtime / Double-Time). Zero-button submission valid (operator skipped breaks → no DowntimeEvent rows).
- **FDS v0.11n → v0.11o** (commit `d7f889f`): **FDS-06-014** ByVision row corrected — camera scans the FULL TRAY as a single image, ONE validation event per tray (not per piece). Four-tray container = four passing tray-scan events. Per-tray `ConsumptionEvent` semantics clarified. New OPC tag names: `TrayPresent`, `TrayValidationResult`, `TrayFullFlag`. Same mechanic applies in Sort Cage non-serialized re-pack (uses the same camera).
- **Phased Plan v1.0 implication flagged** — Phase 1's "Terminal Selector" placeholder is structurally a Home Page (plant browser) for elevated desktop users, not a generic Terminal Selector. Mockup proves the model; Phased Plan + FDS will be updated at next pass to match. Companion FDS-02 paragraph also pending.

### 2026-04-29 — Multi-doc reconciliation + scaling-gate tracking + Phased Plan rebuild + DM column add

Five commits over the day landed substantial work.

- **OIR sync + DM column adds** (commit `c7ca780`) — DM v1.9j → v1.9k. `Lots.ShippingLabel.BannerAcknowledgedAt DATETIME2(3) NULL` added (FDS-07-006b broadcast-script Acknowledge action). `CoupledDownstreamCellLocationId` LocationAttributeDefinition seeded under `CNCMachine` (FDS-06-008 auto-move target). OIR v2.14 → v2.15 — OI-33 (AIM pool empty-pool hard-fail customer validation, HIGH) + OI-34 (production schedules leverage, MEDIUM) folded from embedded FDS register into canonical OIR. OIR v2.15 → v2.16 — **OI-35 NEW (HIGH) "MUST DECIDE BEFORE ARC 2 PHASE 1 SQL BUILD"** — long-horizon scaling, retention, archiving strategy.
- **DM v1.9l + UJ v0.9 reconciliation** (commit `3851802`) — comprehensive sweep aligning DM and UJ to FDS v0.11m. DM v1.9k → v1.9l: ContainerConfig `ByVision` reframed as tray-level trigger; "Casting → Trim" subsection retitled "Trim → Machining" with full BOM example rewrite (5G0-TRIM Component + 5G0-MACHINED Sub-Assembly); `Parts.v_EffectiveItemLocation` view documented (Direct ∪ BomDerived per FDS-02-012); deferred event tables (WorkOrderOperation, ConsumptionEvent, RejectEvent, DowntimeEvent) renamed `OperatorId` → `AppUserId`; UJ-14 + UJ-16 PENDING callouts converted to resolved-prose; 5 Arc 2 admonitions stripped; WorkOrderType SQL correction marked landed; Tools cross-references rewritten. UJ v0.8 → v0.9: 4 high-impact scene rewrites — Trim Shop ("Trim is yield loss, not a rename" + "Trim OUT split + route to Machining FIFO"); Machining scene (FIFO pick + BOM rename at IN, PLC-driven auto-move at OUT); 11:30am Assembly tray-level closure with three peer methods + configured-value references; End of Shift FDS-09-013 single-submission rewrite. Assumption status flips: UJ-12, UJ-14, UJ-16, UJ-18 → ✅ Resolved.
- **Phased Plan Plant Floor v0.3 → v1.0 full rebuild + DM v1.9m** (commit `cf11542`) — complete document rebuild. 1825 lines (down from v0.3's 2077). Phase shape preserved (9 phases, 0–8). Cross-Cutting Concerns B1–B17 lifted verbatim with B12 reframed for **Flex Repeater + Embedded View** as the polymorphic primitive. NEW Seeding Registry — Phase Coupling section maps S-01..S-11 to phases. Phase 0 expanded with parallel **Architecture Decision Workshop** track (OI-35). Phase 1 bakes OI-35 architectural decisions into the migration on day one. Phase 3 Die Cast walkthrough corrected for **Shared terminal model**. Phase 4 Trim OUT branches on `Parts.OperationTemplate.RequiresSubLotSplit`. Phase 5 Machining whole rewrite (FIFO pick + BOM rename at IN; PLC-driven auto-complete + auto-move via CoupledDownstreamCellLocationId at OUT; no operator OUT view). Phase 6 Assembly tray-level closure with three peer methods. Phase 7 AIM pool topup loop + tier alarms. Phase 8 FDS-09-013 end-of-shift entry. Migration numbering rebased — Phase 1 lands at `0014`. **DM v1.9l → v1.9m** companion: `Parts.OperationTemplate.RequiresSubLotSplit BIT NOT NULL DEFAULT 0` added.

### 2026-04-28 — FDS continuity + clarity pass + indexing review

FDS lifted from v0.11j → v0.11m across multiple amend-in-place sessions. Major edits:

- §1.4 layer diagram → table; §1.7 FDS-01-007 historian-DB-separation guidance added.
- §2.5 Cell Context Selection (scan **or** dropdown — was scan-only); FDS-02-010 mode-derivation table refreshed (Cell→Dedicated, WC→Shared, Area→Shared); FDS-02-012 expanded with BOM-derived eligibility.
- §3.6 + §6.6 closure granularity corrected to **tray-level** (FDS-03-017 / FDS-06-013 / FDS-06-014 rewritten — `ClosureMethod` extended with `ByVision`).
- §5.10 + FDS-05-033 part-identity rename moved one step downstream from Casting→Trim to **Trim→Machining**; §5.4/§6.3/§6.4 Trim→Machining workflow reframe (sub-LOT split at Trim OUT not Machining IN; Machining OUT auto-completes via PLC and auto-moves to coupled Assembly Cell via new `CoupledDownstreamCellLocationId` LocationAttribute).
- §9.4 end-of-shift time entry (lunch + breaks only, ~15-min header window).
- FDS-07-006b reframed from per-session bound-query to **Gateway-broadcast-with-session-filter** (one DB query per 5s regardless of terminal count).
- Document-wide strip of project-execution decoration (Arc 2 / Phase N / version trailers / "Implementation deferred" admonitions / requirement-deletion tombstones).

**Standalone FDS Change Log doc** — `MPP_MES_FDS_CHANGELOG.md` + `.docx` created. Pre-release pattern: change log lives in companion doc while FDS is in active development; reintegrates into FDS at customer-review release.

**Data model v1.9j** — `Parts.ContainerConfig.ClosureMethod` extended with `ByVision`; UpperCamelCase casing applied; OI-02 caveat retired.

**Indexing & query-perf review** — full report at `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`. Phase 1–8 already-built schemas have good index coverage; the gap is the **deferred Arc 2 tables** (Lots event tables, Workorder.ConsumptionEvent / RejectEvent, Oee.DowntimeEvent, Quality.HoldEvent) — 14 tables × multiple indexes each need to be pinned in the data model spec before Arc 2 Phase 1 CREATE migrations are written. Three architectural concerns also flagged: 20-year audit retention strategy, `v_LotDerivedQuantities` materialization criteria, recursive-CTE depth limit on `LotGenealogy`. All pre-Arc-2-Phase-1 decisions.

### 2026-04-27 — Integration queue + UJ enrichment + closure batch

- **Integration queue from OIR v2.10 — 7 of 8 landed:** (1) OI-12 MaxParts ✅ `47a4e25`, (2) OI-18 ItemLocation cascade ✅ `0f7f40f`, (3) OI-08 Terminal mode ✅ `7a9d87e`, (4) OI-23 Lot derivations view ✅ `e393b7d`, (5) OI-16 PLC confirm + RequiresCompletionConfirm ✅ `55427f5`, (6) OI-21 Pausable LOT — design locked + landed ✅ `15edd5e`, (7) UJ-04 AIM pool — design locked + landed ✅ `82df891`. (8) OI-13 BOM export moved to seeding registry as S-06.
- **UJ enrichment + closure batch** — 13 UJ entries enriched to OI-style depth in v2.13 (commit `483948e`); Jacques reviewed the docx and closed 10 in v2.14 (commit `a2b58f5`): UJ-07/-08/-11/-13/-14/-16 (Option A defaults), UJ-09 (Option C — strict + supervisor override), UJ-10 (Option D — shift-end summary), UJ-17 (Option A — ConfirmationMethod LocationAttribute), UJ-18 (Gateway-script-async architectural — FDS-01-014 + print-dispatch async pattern + ShippingLabel +5 print-state cols).

### 2026-04-23 / -24 — Arc 2 Model Revisions + corrections

- **Arc 2 Model Revisions (2026-04-23 session)** — 6 commits on 2026-04-23 lifted doc set to Data Model v1.9 / FDS v0.11 / UJ v0.8 / OIR v2.7 / Arc 2 Plan v0.2. Tool/Cavity promoted to `Lots.Lot`; ProductionEvent reshaped to checkpoint form; new `Lots.IdentifierSequence` table; `MaxLotSize` repurposed as `PartsPerBasket`; OI-09 closed (cavity-parallel LOTs as peers); OI-26 deleted; OI-31 opened.
- **2026-04-24 corrections + integrations:**
  - ERD full rebuild — every tab fully current to v1.9; Master tab rebuilt from v1.5 baseline; Audit `bigbigint` typos + OEE column mismatches fixed; Tools cross-schema FKs drawn (commits `2a91da0`, `70d0f37`).
  - Phase 0 + Phase 1 of Arc 2 Plan rewritten in-place (clock# + PIN removed from body, not just overlay) — commit `9121502`.
  - **OI-07 correction** — `WorkOrderType` corrected to single `Production` row; Demand + Maintenance moved to FUTURE hooks; Recipe deleted (commit `ce3e080`).
  - **Storyboards + IPAddresses review** (commit `7550bb8`) — 2012 Flexware docs reviewed against v1.9 design. 83% coverage. Report at `reference/NewInput/REVIEW_2026-04-24.md`. OI-32 Material Allocation + OI-32b Material Classes opened.
  - **OI-31 single-line deployment memo for Ben** — `Meeting_Notes/2026-04-24_OI-31_Single-Line_Deployment_Impact.md`.
  - **Jacques's OIR review batch applied** (commit `6865d8d`, OIR v2.10) — 17 Part A OIs moved Resolved + 2 UJ closures (UJ-02, UJ-04).

### Earlier landmarks

- **Phase G SQL** — All five sub-phases (G.1–G.5) landed by 2026-04-23 (terminal commit `534f55c`). 853/853 tests passing across 20+ test suites at that point.
- **2026-04-20 OI review refactor** — All phases (A/B/C/D/E/F/G) landed.
- **Phase B Tool Management design spec** — Approved 2026-04-21 (commit `47ce9c7`). Full schema spec at `docs/superpowers/specs/2026-04-21-tool-management-design.md` v0.2.
- **Legacy PDF references** — `reference/Manufacturing Director Technical Manual.pdf` (2009 Flexware doc) converted to searchable Markdown at `reference/Manufacturing_Director_Technical_Manual.md` on 2026-04-21. Converter `reference/scripts/convert_mdtm_to_md.js` reusable for future Flexware docs.
- **Seed data extraction** — 876 rows extracted from FRS Appendices B/C/D/E into CSVs in `reference/seed_data/`, plus auto-generated `reference/seed_data.xlsx`. Per-appendix Node.js parsers in `reference/seed_data/parsers/`. Source PDF: `reference/MPP_FRS_Draft.pdf`.
