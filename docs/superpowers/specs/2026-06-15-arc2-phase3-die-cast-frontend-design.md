# Arc 2 Phase 3 — Die Cast Operator Station: FRONT-END (Ignition Perspective) — Design

**Date:** 2026-06-15
**Status:** Draft for review

## Revision history

| Date | Change |
|---|---|
| 2026-06-15 (initial) | First draft. Recommended an `ia.container.tab` shell (Entry / Checkpoint / Reject) with five open front-end decisions FE-D1..FE-D5. |
| 2026-06-15 (decision bake-in) | **Five decisions settled and baked in, replacing the open FE-D1..FE-D5.** **D1** — the screen now matches the customer-approved mockup (`mockup/plantFloor.html` Die Cast section): a single, **no-tabs**, two-column screen (left NEW-LOT form, right two stacked cards: cumulative cavity KPIs + Reject Entry). The prior tab-shell recommendation (§3.4) is **withdrawn**. **D2** — Cavity is an operator-selected dropdown with **free-entry fallback** when no active cavities resolve. **D3** — rapid cavity-peer logging via a post-submit "Create LOT from another cavity" action that keeps Cell/Tool/Item sticky. **D4** — scanned LTT captured, server-side mint is the default (`@LotName = NULL`), forward-compatible to "scanned LTT IS the LOT name" as a one-line flip. **D5** — dynamic checkpoint field typing is data-driven off the new `DataCollectionField.DataType` column (from the sql-deltas spec). The §9 "GAP — no DataType column" is now resolved by that cross-spec column; `ProductionEvent_ListByLot` is now a confirmed cross-spec read. SQL changes are NOT authored here — they live in the parallel sql-deltas spec and are referenced as cross-spec dependencies. |

**Scope:** The **Perspective / Named-Query / entity-script / gateway layer** for the Die Cast workflow — the deferred follow-on the Phase 3 SQL spec explicitly hands off ("a separate front-end spec", SQL spec §9). It wraps the SQL foundation already designed/built in migration `0022` and three net-new procs. This spec adds: the Die Cast LOT Entry view, the Checkpoint and Reject embedded components, the cavity-peer creation flow, the Core Named Queries that front the five procs, the Core entity-script modules that call them, the page-config routes, and the integration seam for the (out-of-scope) `DieCastCycleReader` gateway script. **No SQL is authored or modified here** — the procs are the contracts; this layer is a thin, business-logic-free caller (FDS-13-002, "no business logic in Python").

## 1. Source of truth

- **Phase 3 SQL spec** — `docs/superpowers/specs/2026-06-12-arc2-phase3-die-cast-sql-design.md`. The proc contracts wrapped here, plus decisions D1 (cumulative `ShotCount`), D2 (checkpoints don't move inventory), D3 (`RejectEvent` decrements LOT + close-at-zero). This front-end spec MUST NOT reinterpret those decisions; it surfaces their effects to the operator.
- **Phase 3 SQL-DELTAS spec (parallel, in-progress)** — the small SQL follow-on that adds the three things this front-end depends on: (a) `Parts.DataCollectionField.DataType` (the typed-widget driver for D5), (b) the `Workorder.ProductionEvent_ListByLot` read proc (the right-rail cumulative-cavity card + last-shot hint), and (c) an **optional `@LotName` parameter on `Lots.Lot_Create`** (the D4 forward-compat seam) plus the **no-active-cavity handling** `Lot_Create` needs when the operator free-enters a cavity (D2). **This front-end spec authors no SQL** — it names these as cross-spec dependencies and is written so they drop in cleanly. Where this spec says "the sql-deltas spec," it means that document.
- **The customer-approved mockup** — `mockup/plantFloor.html` (`<section data-route="terminal/diecast">`, lines ~906–1029) + `mockup/plantFloor.css`. **As of the 2026-06-15 decision bake-in, this mockup is the binding visual target for the Die Cast LOT Entry screen (D1).** The screen is a single, no-tabs, two-column layout (left NEW-LOT form, right two stacked cards). This spec maps each mockup region to a Perspective component below.
- **Phased plan** — `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` § "Phase 3 — Die Cast Operator Station"; task list `MPP_MES_TASK_LIST_PLANT_FLOOR.csv` T082–T085 (the deferred UI/gateway subset the SQL spec named).
- **FDS** — §5.2 **FDS-05-004** (Manufactured LOT creation at Die Cast), **FDS-05-034 / FDS-05-035** (Tool+Cavity required on die-cast `Lot_Create`; Tools system-of-record on `Lot`), **FDS-05-036** (lazy, operator-driven LOT creation), **FDS-03-013 / FDS-03-017a** (operation-template-driven dynamic screen rendering; checkpoint shape), **FDS-05-038** (Pausable LOT indicator — already shipped in Phase 2, reused), **§5.4 FDS-05-004 note** (cavity-parallel peers = N independent LOTs, flat genealogy), **FDS-02-013** (tablet design constraint — touch targets ≥ 44 px, portrait), **FDS-10-012** (Controlled Run Tag — relevant only as an out-of-scope seam).
- **Data Model** — `Workorder.ProductionEvent` / `ProductionEventValue` / `RejectEvent`; `Lots.Lot` `ToolId`/`ToolCavityId`; `Parts.OperationTemplate` / `OperationTemplateField` / `DataCollectionField` (the new `DataCollectionField.DataType` column the sql-deltas spec adds is the D5 widget driver).
- **Ignition context pack** — `07_conventions_and_antipatterns.md` (view authoring, three-layer rule, save semantics), `02_perspective_views.md`, `06_component_quirks.md`, `03_script_python.md`, `04_named_queries.md`.
- **Shipped Phase 1/2 plant-floor surface** — reference implementations this spec mirrors: `CellContextSelector`, `InitialsField`, `ElevationModal`, `PausedLotIndicator`, `LotDetail`, and the `BlueRidge.Lots.Lot` entity module (`ignition/projects/Core/.../BlueRidge/Lots/Lot/code.py`).

## 2. Reconciliation to shipped resources

What already exists and is **reused, not rebuilt**:

- **Procs (SQL spec, migration 0022):** `Workorder.ProductionEvent_Record`, `Workorder.RejectEvent_Record`, `Tools.ToolCavity_ListActiveByTool`, plus the pre-shipped `Tools.ToolAssignment_ListActiveByCell` and the Phase 1/2 `Lots.Lot_Create`, `Lots.Lot_AssertNotBlocked`. Seeded `DieCastShot` `OperationTemplate` + its `OperationTemplateField` rows (`DieInfo`, `CavityInfo`, `Weight`, `GoodCount`, `BadCount`).
- **Entity scripts (Core):** `BlueRidge.Lots.Lot.create(...)` already wraps `Lot_Create` with `toolId` / `toolCavityId` params — the Die Cast LOT Entry view calls it unchanged. `BlueRidge.Quality.DefectCode` already lists defect codes for the reject dropdown.
- **Named Queries (Core):** `lots/Lot_Create` (carries `toolId`/`toolCavityId`/`weight`/`pieceCount`; the sql-deltas spec adds an **optional `@LotName`** param — the NQ `query.sql` gains one `:lotName` line per D4, see §5), `quality/DefectCode_List`, `parts/OperationTemplateField_ListByTemplate`, `parts/DataCollectionField_List` (rows now carry `DataType` — D5), `parts/OperationTemplate_List`, `lots/Lot_AssertNotBlocked`. **No `tools/` or `workorder/` NQ group exists yet** — this spec creates them (§5).
- **Perspective components (MPP):** `Components/PlantFloor/CellContextSelector` (Cell resolution by terminal context, dropdown, and scan), `Components/PlantFloor/InitialsField` + `ElevationModal` (operator attribution + AD elevation), `Components/PlantFloor/PausedLotIndicator` (FDS-05-038 — embedded unchanged on the Die Cast screen). `session.custom.cell`, `session.custom.terminal.terminalLocationId`, and `session.custom.appUserId` are the established context model.
- **Routes:** `BlueRidge/Views/ShopFloor/HomeRouter` is the terminal entry point; `page-config/config.json` already routes `/shop-floor/*`. This spec adds three entries under that prefix.

Net-new in this spec: 1 page view (`DieCastEntry`) + its embedded Checkpoint / Reject / cavity-card sub-views + row sub-views, 5 NQs (3 read incl. the confirmed `ProductionEvent_ListByLot`, 2 mutation), 4 entity-script modules, 3 page-config routes, 1 deferred-gateway seam note.

## 3. The views and components

All views live in the **MPP** project (`ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/...`). Flex-repeater ROW sub-views live under `Components/PlantFloor/<Page>/<Row>` — **never nested inside a page-view's own folder** (Ignition will not register a view nested under another view; per `parallel-view-authoring` memory). Every view's root keeps `meta.name: "root"`. Every binding-read `view.custom.*` prop is pre-declared with a fully-shaped default (`07` → "Pre-declare every custom property a binding reads").

### 3.1 Die Cast LOT Entry — `Views/ShopFloor/DieCastEntry` — `MVP` (FDS-05-004, FDS-05-034, FDS-05-036) — **mockup-driven layout (D1)**

The primary (and only) screen. Route `/shop-floor/die-cast`. **There are NO tabs.** The layout matches the customer-approved mockup (`mockup/plantFloor.html` `terminal/diecast`, lines ~906–1029) 1:1: a header band, a context bar, then a **two-column body** — a large primary "NEW LOT" form on the **LEFT**, and **two stacked cards on the RIGHT** (cumulative cavity KPIs + Reject Entry). Tablet-first, ≥ 44 px touch targets throughout (FDS-02-013). On a narrow/portrait viewport the two columns stack (left form first), matching the mockup's `@media (max-width: 900px)` reflow — the right cards drop below the form, not into a tab.

The root is an `ia.container.flex` (`direction: column`). The two-column body is a `ia.container.flex` (`direction: row`, `wrap: wrap`) with the left form `grow: 1` and the right rail a fixed ~320 px column (mirrors the mockup `grid-template-columns: 1fr 320px`), wrapping to full-width below the form when the viewport narrows.

**A. Header band** (mockup `.pf-terminal-header`):
   - Title **"Die Cast LOT Entry"**; subtitle **"PRESS N (DC-0NN) · SHARED TERMINAL · DIE CAST AREA"** — both bound: the press code from `session.custom.cell`, the tool code from `view.custom.activeTool` (see B). ASCII middle-dot literal `·` is fine in a label `props.text` (it is NOT an `expr` string literal — `feedback_ignition_expr_no_unicode_escape` applies only to `type:"expr"`).
   - Top-right: the **Paused-LOTs indicator** — embed the shipped `Components/PlantFloor/PausedLotIndicator` unchanged, bound to the active Cell (`session.custom.cell.locationId`, FDS-05-038) — and a **Close** control that navigates back to `HomeRouter` (`system.perspective.navigate`, scope `G` per `feedback_ignition_popup_open_scope`).

**B. Context bar** (mockup `.pf-terminal-cell-context`):
   - **"ACTIVE CELL <press>"** (label + `session.custom.cell` value) and a **"Change (scan or pick)"** button that opens the shipped `Components/PlantFloor/CellContextSelector` (as a popup or inline reveal, matching its Phase 1 usage; `replyMessage: "cellContextChanged"`, page scope). The view subscribes to `cellContextChanged` (page scope) and reloads its context (active tool, cavity list, eligibility) on change.
   - Right-aligned: **"Tool DC-0NN mounted · N cavities active"** — bound to `view.custom.activeTool.ToolCode` + the length of the cavity-options list. On Cell change, `view.custom.activeTool` loads from `BlueRidge.Tools.ToolAssignment.getActiveByCellOrEmpty(cellLocationId)` (§6, shaped-empty binding). When no tool is mounted, this reads "No die mounted" and the cavity dropdown enters free-entry mode (D2, below).

**C. LEFT — "NEW LOT" card** (mockup left `.pf-panel`; primary, large). Bidi-bound to `view.custom.editDraft` (the established `editDraft` pattern; pre-seed the full shape per `feedback_ignition_bidi_nested_path_init`). Fields top-to-bottom, matching the mockup order:
   - **LTT Barcode (scan)** — first field, `mpp/qr_code_scanner` adornment (verified present, used by `CellContextSelector`). Help text "Pre-printed labels per FRS 2.2.1." The scanned value is captured into `editDraft.scannedLtt`. **D4 governs what happens to it** (server-mint default; see §3.1.1).
   - **Operator Initials** — embed the shipped `Components/PlantFloor/InitialsField` inline (shared terminal — no auto-populate; the operator types/scans initials per row, FDS-04 attribution). Its resolved `appUserId` crosses back via the established page-scoped message and lands in `view.custom.appUserId`.
   - **Item** — `ia.input.dropdown`, options constrained to Items eligible at this Cell per FDS-02-012 (existing eligibility read, `BlueRidge.Parts.Eligibility` / `Location_ListForEligibilityPicker` family). The mockup shows Item as a disabled "resolved from Tool" field; **if** `ToolCavity_ListActiveByTool` carries the producing `ItemId` per cavity (the sql-deltas spec confirms), the Item auto-populates from the selected cavity and the dropdown becomes confirm/override; **otherwise** it is the eligibility-constrained picker. (This is the former FE-D2-Item; the dropdown is the safe default and degrades to read-only display when cavity-derived.)
   - **Tool (auto-populated)** — read-only display of `view.custom.activeTool.ToolCode` + an **Edit** button gated by `ElevationModal` (mockup `data-elevated-action="EditTool"`). On elevation success, open the inline Tool re-assign flow wiring the **existing** `BlueRidge.Parts.Tool.releaseAssignment` / `assignToCell` (= `Tools.ToolAssignment_Release` + `_Assign`, FDS-05-004 step 4). **No new release/assign proc is authored.** Empty-state when no tool: "No die mounted on this cell — use Edit to assign" (cavity goes free-entry, D2).
   - **Cavity** — `ia.input.dropdown` with **free-entry fallback** — see **§3.1.2 (D2)**.
   - **Piece Count** — numeric input. Required. Mockup help "Max N (configured on this item)." Use `ia.input.numeric-entry-field` (`props.value`) — NOT `ia.input.numeric-entry` (`feedback_ignition_numeric_entry_field_type`); the project's text-field-for-numbers alt is acceptable but numeric-entry-field is preferred for a touch keypad. The UI MAY preflight `pieceCount <= Item.MaxLotSize` (`PartsPerBasket`) for UX; the proc stays authoritative (FDS-05-004 step 6).
   - **Weight** — numeric input, **optional** (scale integration is Phase 6; operator-entered here). Optional Weight UOM dropdown.
   - **Footer actions** (mockup `.pf-actions`): **Submit · Create LOT** (primary, large) · **Cancel** (clears the draft) · spacer · **Place Hold on this LOT** (elevated; wires the existing hold-place flow — out of scope to author, surfaced here per the mockup). See §3.1.3 for the Submit flow and the post-submit cavity-peer action (D3).

**D. RIGHT rail — two stacked cards** (mockup right `aside`):
   - **"CAVITY X (CUMULATIVE)"** — Shot Count / Scrap Count / Last Event, fed by `BlueRidge.Workorder.ProductionEvent.listByLot(activeLotId)` (wrapping the confirmed cross-spec `Workorder.ProductionEvent_ListByLot`). Reads cumulative `ShotCount` / `ScrapCount` for the most-recent event on the active LOT + its `EventAt`. Empty/no-LOT state shows dashes. This is the §3.2 Checkpoint card's read companion; the **opening-checkpoint entry** lives in the Checkpoint sub-view (§3.2), reachable inline / via deep-link.
   - **"REJECT ENTRY"** — the §3.3 Reject panel, embedded as a card (Defect Code dropdown, Quantity, **Add RejectEvent** button). Input param `activeLotId`.

#### 3.1.1 Scanned-LTT capture & server-side mint default (D4)

The view always captures the scanned LTT barcode into `view.custom.editDraft.scannedLtt`. **Until MPP confirms (expected the day after this revision) whether the pre-printed LTT # IS the canonical LOT id, the default behavior is to MINT server-side:** `Lot.create(...)` passes **`lotName = None`** (→ `@LotName = NULL` on the sql-deltas `Lot_Create`), the proc mints `MintedLotName`, and the view:
   - stores the scanned value alongside for reconciliation/audit, and
   - shows a **mismatch warning** (non-blocking toast / inline note) when the scanned LTT ≠ the minted name, so a divergence is visible during the pilot.

**Flipping to "the scanned LTT IS the LOT name" is a one-line change, not a redesign:** set `lotName = editDraft.scannedLtt` in the single `Lot.create` call site (the entity method already forwards `lotName` → `:lotName` → `@LotName`; see §5/§6). The sql-deltas spec's `@LotName` defaults to NULL precisely so this front-end need not change shape. Both states are documented; no other code path depends on which is active.

#### 3.1.2 Cavity dropdown with free-entry fallback (D2)

- **Normal path:** `ia.input.dropdown`, options from `BlueRidge.Tools.ToolCavity.getActiveForDropdown(toolId)` (wraps `Tools.ToolCavity_ListActiveByTool`, Active cavities only). The selected `value` is the `ToolCavity.Id`. Required.
- **Free-entry fallback:** when that list is **empty** (no tool checked into the press, or the tool has no Active cavities configured), the dropdown SHALL allow the operator to **type a cavity value** rather than being stuck with no options. In Perspective, `ia.input.dropdown` accepts user-entered values via its custom-value capability — set the dropdown to allow custom/free-text entry (the prop is the dropdown's "allow custom values" toggle, named `props.allowCustomOptions` in the 8.3 schema; **verified in Designer 2026-06-15 (top-level prop, sibling to `search`)**, since the pack does not yet document it). When free-entry is active, the captured value is a free-text cavity label (NOT a `ToolCavity.Id`).
- **Cross-spec dependency (FLAGGED, not solved here):** `Lots.Lot_Create` validates that the supplied `ToolCavityId` belongs to the active Tool (FDS-05-034). A free-entered cavity is therefore **not a valid `ToolCavityId`** and would be rejected by the as-built proc. The **sql-deltas spec owns the no-cavity / free-entry reconciliation** (e.g., accept a NULL `ToolCavityId` + a free-text cavity label, or relax the cavity-belongs-to-tool check when no active mount exists — mirroring `project_mpp_plant_floor_smoke_seed`, where `Lot_Create` already skips Tool/Cavity validation when no active mount is present). **This front-end spec does NOT author that SQL** — it surfaces the free-entry control and passes either a `ToolCavityId` (normal) or a free-text cavity value (fallback), and the sql-deltas spec defines how the proc consumes the fallback. Until that handling lands, free-entry is a captured-but-may-reject path; the operator sees the proc's rejection `Message`.

#### 3.1.3 Submit flow + rapid cavity-peer logging (D3) — minimal taps

**Submit · Create LOT** → `BlueRidge.Lots.Lot.create(editDraft, appUserId, terminalLocationId)` (existing entity method; the only change is forwarding the optional `lotName` per §3.1.1), passing `lotOriginTypeId = Manufactured`, `currentLocationId = session.custom.cell.locationId`, `toolId = activeTool.Id`, `toolCavityId` (or free-text cavity per D2), `itemId`, `pieceCount`, `weight`, `weightUomId`, `lotName` (NULL default). Result routed through `Common.Ui.notifyResult`. On `Status` success:
   - Toast shows `MintedLotName` (plus the §3.1.1 mismatch warning if applicable).
   - `view.custom.activeLotId` is set to the new id so the right-rail cumulative card and the Reject card immediately target it.
   - **"Create LOT from another cavity"** (D3) — a prominent post-success action that keeps **Cell / Tool / Item sticky** and clears **only Cavity + Piece Count + LTT scan** (Weight too), so the operator re-enters just the cavity-specific bits for the next peer LOT. A non-persisted `view.custom.peersThisSession` tally ("cavities logged this run", rendered via the `PeerTallyRow` sub-view, §3.5) gives orientation only. Each peer is an **independent `Lot_Create`** with a different cavity (flat genealogy — the UI never calls `Lot_Split`; cavity peers are NOT sublots, §5.4 FDS-05-004).

**Minimal-tap common path (overriding goal — D1):** scan LTT → (Item auto-resolves from cavity/eligibility, Tool auto-populates from the mount, cavity defaults to the single active cavity when only one exists) → **Submit**. In the single-active-cavity, cavity-derived-Item case this is **scan → Submit = 2 interactions**. For a multi-cavity press the operator adds one cavity tap. The post-submit "Create LOT from another cavity" action makes the **second** peer **cavity-tap → count → Submit** with Cell/Tool/Item already sticky. Defaulting the cavity dropdown to the sole option when `len(options) == 1`, and auto-focusing the LTT scan field on load and after each peer-clear, are explicit design requirements in service of fewest taps.

### 3.2 Checkpoint panel — `Components/PlantFloor/DieCastEntry/CheckpointPanel` — `MVP` (FDS-03-013, FDS-03-017a)

Records one `Workorder.ProductionEvent` per logging action. Embedded as an inline section / reachable via the `/checkpoint/:lotId` deep-link (it is NOT a tab — D1). Input is `params.lotId` (BIGINT, `paramDirection: "input"` — embed params are input-only; cross the boundary back to the parent with a page-scoped message, per `feedback_ignition_embed_params_input_only`).

- **Dynamic, data-driven field rendering (FDS-03-013, D5).** On `lotId` / template change, `view.custom.fields` is loaded from `BlueRidge.Parts.OperationTemplate.getFieldsForTemplate(dieCastShotTemplateId)` (existing method wrapping `OperationTemplateField_ListByTemplate`, which carries each row's `DataCollectionField.DataType` — the new column from the sql-deltas spec). The panel renders one input per field via a **flex-repeater** over `Components/PlantFloor/DieCastEntry/FieldInputRow` (the ROW sub-view). **The widget per field is chosen by `DataType` (D5), data-driven — NOT code-derived:**

  | `DataCollectionField.DataType` | Perspective widget |
  |---|---|
  | `String` | `ia.input.text-field` |
  | `Integer` / `Decimal` | `ia.input.numeric-entry-field` (`props.value`; never `ia.input.numeric-entry` — `feedback_ignition_numeric_entry_field_type`) |
  | `Boolean` | `ia.input.checkbox` (`props.selected`) |
  | `Date` | date picker (`props.value` is a ms-epoch timestamp, not an ISO string — `06`) |

  The mapping lives in the `FieldInputRow` sub-view as a presentation choice keyed off the row's `DataType` value (this is widget selection, not business logic — the *rules* about which fields exist and are required stay in the seeded `OperationTemplateField` rows + the proc, per `feedback_no_business_logic_in_python`). The repeater binds each row's value bidirectionally back into `view.custom.dcValues[<DataCollectionFieldId>]` via a page-scoped message (embed params are input-only). **Cross-spec dependency:** `DataType` is read-only consumed here; the sql-deltas spec owns adding the column + seeding it for the `DieCastShot` fields (`GoodCount`/`BadCount` → Integer, `Weight` → Decimal, `DieInfo`/`CavityInfo` → String). No fallback-to-`Code` heuristic is needed once the column ships; if a row's `DataType` is unexpectedly NULL, default to `String` (safe text-field).
- **Hot columns vs. data-collection values.** `ShotCount`, `ScrapCount` (cumulative cavity counters) and `WeightValue` map to the proc's typed parameters; the `DieCastShot` data-collection fields `GoodCount`/`BadCount` (and `DieInfo`/`CavityInfo`) shred into `@DataCollectionValuesJson`, while the `Weight` field routes to the typed `@WeightValue` (never duplicated in JSON). The panel assembles the JSON via `BlueRidge.Common.Util.convertWrapperObjectToJson(dcValues)` and passes the hot columns separately. The proc rejects a payload that duplicates a hot-column field in `ProductionEventValue` (FDS-03-017a step 2d) and rejects missing `IsRequired` fields (step 2c) — the UI surfaces those as the proc's `Message` toast; it does not pre-enforce them (no business logic in Python).
- **Cumulative semantics surfaced (D1).** Field labels read "Cumulative shots (cavity counter)" / "Cumulative scrap" so the operator enters the running counter, not a delta. The panel MAY display the last recorded `ShotCount` for this LOT (read via a `ProductionEvent` list, §6) as a hint, with copy "last checkpoint: N shots — enter the current total." Deltas are a report concern (D1), never computed in the UI.
- **D2 surfaced.** A small note clarifies a checkpoint records production metrics only and does **not** change the LOT's piece availability (`InventoryAvailable` / `TotalInProcess` stay put). This pre-empts operator confusion that "logging 500 shots" should change the basket count.
- **Submit** → `BlueRidge.Workorder.ProductionEvent.record(...)` (§6) → `Common.Ui.notifyResult`. On success the panel clears its draft and broadcasts `checkpointRecorded` (page scope) so the parent can refresh the last-shot hint.

### 3.3 Reject panel — `Components/PlantFloor/DieCastEntry/RejectPanel` — `MVP` (D3, FDS-06-019 family)

Logs a `Workorder.RejectEvent` that **decrements the LOT and closes it at zero** (D3). Embedded as the lower-right card on the main screen (mockup "REJECT ENTRY"), NOT a tab. Input `params.lotId` (= the parent's `view.custom.activeLotId`).

- **Defect Code** — `ia.input.dropdown`, options from `BlueRidge.Quality.DefectCode.getForDropdown()` (existing). Required.
- **Quantity** — numeric input (`ia.input.numeric-entry-field`), required. The proc enforces `0 < Quantity <= Lot.PieceCount` (SQL spec §4.2); the UI surfaces the rejection message rather than pre-validating.
- **Add RejectEvent** — the submit button (mockup label). Disabled when no `activeLotId` is set.
- **Charge-to-area** + **Remarks** — optional (the mockup card is minimal; these are included per the proc signature and may be progressive-disclosed).
- **D3 behavior surfaced to the operator.** Confirmation prose: "Rejecting N pieces removes them from LOT <name> (now M − N). If this empties the LOT it will be closed." On success, `notifyResult` toast shows the proc `Message` (which the SQL spec specifies includes the new piece count); when the proc returns the close-at-zero outcome, the toast level is `warning` and copy reads "LOT closed — all pieces rejected." The panel broadcasts `rejectRecorded` (page scope); the parent reloads the LOT header (piece count, status) so the closed state is visible. Reject and inventory-reduction are one operation — there is no separate "scrap" control (D3).

### 3.4 Screen composition — single screen, NO tabs (D1, withdraws the prior tab-shell)

**The earlier tab-shell recommendation (`ia.container.tab` with Entry / Checkpoint / Reject tabs) is WITHDRAWN.** Per the customer-approved mockup (D1), all surfaces live on **one screen, no tabs**: the LEFT NEW-LOT form, and the RIGHT stacked cumulative-cavity + Reject cards (§3.1). The Checkpoint entry surface (§3.2) is an inline section / deep-link, not a tab. The LOT-context (`view.custom.activeLotId`) is held on the parent and passed as the input param to the Checkpoint and Reject embeds and to the cumulative-cavity read. No `ia.container.tab` is used anywhere on this screen; grouping is by flex layout matching the mockup's two-column grid.

### 3.5 Row sub-views

- `Components/PlantFloor/DieCastEntry/FieldInputRow` — one dynamic data-collection input (label + **`DataType`-selected control** per the §3.2 D5 mapping), value bidi-bound back to the parent via page message (embed params are input-only). The row receives `params.field` (incl. its `DataType`) input-only and renders the matching widget; only the widget whose `DataType` matches is `position.display`-shown.
- `Components/PlantFloor/DieCastEntry/PeerTallyRow` — one logged cavity-peer line in the "logged this run" tally (cavity #, LotName, count). Display-only.

(Reject and the cumulative-cavity card use no row sub-views beyond `FieldInputRow`. All sub-views live under `Components/PlantFloor/DieCastEntry/<Row>` — never nested inside the page-view's own folder, per `parallel-view-authoring`.)

## 4. Page-config routes

Add to `ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json` under the existing `/shop-floor/*` family (every entry carries a `title`, `07` convention):

```jsonc
"/shop-floor/die-cast":                 { "title": "Die Cast Entry",  "viewPath": "BlueRidge/Views/ShopFloor/DieCastEntry" },
"/shop-floor/die-cast/checkpoint/:lotId": { "title": "Checkpoint",    "viewPath": "BlueRidge/Views/ShopFloor/DieCastEntry" },
"/shop-floor/die-cast/reject/:lotId":     { "title": "Reject",        "viewPath": "BlueRidge/Views/ShopFloor/DieCastEntry" }
```

Path params, not query-string dicts (project convention; mirrors `/shop-floor/lot-detail/:lotId`). The deep-link `:lotId` routes pre-select the corresponding tab and pre-load the LOT context. **`HomeRouter` reach:** add a Die Cast tile/action to `HomeRouter` that navigates to `/shop-floor/die-cast` when the terminal's resolved context (`session.custom.terminal` / `session.custom.cell`) is a Die Cast Cell. The tile is gated by the same terminal-context model the Phase 1/2 shop-floor pages already use; no new session props are introduced.

## 5. Named Queries (Core)

**All NQs live in the `Core` project** (`ignition/projects/Core/ignition/named-query/...`). Siblings (MPP, MPP_Config) cannot see each other's NQs; the inherited-NQ registry needs a **gateway RESTART** to pick up new NQs (scan is insufficient — `project_mpp_nq_core_topology`). Two new groups: `tools/` and `workorder/`. Each `resource.json` clones the v2 shape from a Designer-saved sibling (e.g. `lots/Lot_Create/resource.json`), uses Designer's own `sqlType` enum (`3` = BIGINT/Id, `2` = INTEGER, `5` = FLOAT/DECIMAL, `7` = NVARCHAR, `6` = BIT, `8` = DateTime — `04` §"sqlType integer codes"), and sets `database: "MPP"`.

| NQ path | Proc | `attributes.type` | Consumed via |
|---|---|---|---|
| `workorder/ProductionEvent_Record` | `Workorder.ProductionEvent_Record` | **`Query`** | `Common.Db.execMutation` |
| `workorder/RejectEvent_Record` | `Workorder.RejectEvent_Record` | **`Query`** | `Common.Db.execMutation` |
| `tools/ToolCavity_ListActiveByTool` | `Tools.ToolCavity_ListActiveByTool` | `Query` | `Common.Db.execList` |
| `tools/ToolAssignment_ListActiveByCell` | `Tools.ToolAssignment_ListActiveByCell` | `Query` | `Common.Db.execList` |
| `workorder/ProductionEvent_ListByLot` | `Workorder.ProductionEvent_ListByLot` (confirmed cross-spec read; sql-deltas spec owns the proc) | `Query` | `Common.Db.execList` |

**Critical:** the two mutation NQs MUST set `attributes.type: "Query"` (NOT `UpdateQuery`). Both procs end `SELECT @Status, @Message, @NewId`; `UpdateQuery` uses JDBC `executeUpdate`, which throws "A result set was generated for update" — the proc succeeds server-side but no toast fires and the UI looks dead (`feedback_ignition_nq_type_for_status_row_procs`). Each `query.sql` is a thin `EXEC` wrapper with `:param` → `@Param` mapping, mirroring `lots/Lot_Create/query.sql`.

`workorder/ProductionEvent_Record/query.sql` parameter set (mirrors SQL spec §4.1):

```sql
EXEC Workorder.ProductionEvent_Record
    @LotId                    = :lotId,
    @OperationTemplateId      = :operationTemplateId,
    @WorkOrderOperationId     = :workOrderOperationId,
    @EventAt                  = :eventAt,
    @ShotCount                = :shotCount,
    @ScrapCount               = :scrapCount,
    @WeightValue              = :weightValue,
    @WeightUomId              = :weightUomId,
    @DataCollectionValuesJson = :dataCollectionValuesJson,
    @AppUserId                = :appUserId,
    @TerminalLocationId       = :terminalLocationId,
    @Remarks                  = :remarks
```

`workorder/RejectEvent_Record/query.sql` (SQL spec §4.2):

```sql
EXEC Workorder.RejectEvent_Record
    @LotId            = :lotId,
    @DefectCodeId     = :defectCodeId,
    @Quantity         = :quantity,
    @ChargeToArea     = :chargeToArea,
    @ProductionEventId= :productionEventId,
    @Remarks          = :remarks,
    @AppUserId        = :appUserId,
    @TerminalLocationId = :terminalLocationId
```

Read NQs (`ToolCavity_ListActiveByTool`, `ToolAssignment_ListActiveByCell`, `ProductionEvent_ListByLot`) take a single Id param and have no `parameters[]`-beyond-the-Id, no cache by default. `ProductionEvent_ListByLot` feeds the right-rail cumulative-cavity card (latest `ShotCount` / `ScrapCount` / `EventAt` for the active LOT) and the Checkpoint last-shot hint.

**`lots/Lot_Create` `@LotName` one-line addition (D4).** The existing `lots/Lot_Create/query.sql` gains a single mapped line — `@LotName = :lotName` — to forward the optional name the sql-deltas spec adds to the proc (defaulting NULL → server mint). This is the only change to the existing Lot_Create NQ; `:lotName` is `sqlType` `7` (NVARCHAR), nullable. When MPP confirms "scanned LTT IS the LOT name," the entity layer passes the scanned value and nothing else in the NQ changes (§3.1.1).

## 6. Entity scripts (Core)

**All entity scripts live in the `Core` project**, schema-aligned folders (`script-python/BlueRidge/<Domain>/<Entity>/code.py`). Standard module shape (`03`): log entry/exit, `_u()` deep-unwrap at the boundary, `_currentAppUserId()` for attribution defaults, dict in / dict-or-list out, route every DB call through `Common.Db.*`. No `system.db.*` in entity scripts; no business logic (validation/rules stay in the procs).

**`BlueRidge.Lots.Lot.create` — one-param forward for D4 (NOT a rewrite).** The existing `create(...)` entity method gains a single optional `lotName=None` param that it forwards into the `lots/Lot_Create` params dict as `"lotName": lotName`. The Die Cast view's call site passes `lotName=None` by default (server mint, §3.1.1); flipping to "scanned LTT IS the name" passes `editDraft.scannedLtt`. No other behavior changes; the proc + NQ already default `@LotName`/`:lotName` to NULL. This is the only edit to an existing entity module in this spec.

### 6.1 `BlueRidge.Workorder.ProductionEvent` (net-new module)

```python
def record(data, appUserId=None, terminalLocationId=None):
    """Record one die-cast checkpoint. data: {lotId, operationTemplateId,
       shotCount, scrapCount, weightValue, weightUomId, dcValues (dict
       keyed by DataCollectionFieldId), remarks, eventAt, workOrderOperationId}.
       Returns {Status, Message, NewId}."""
    d = _u(data) or {}
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "lotId":                d.get("lotId"),
        "operationTemplateId":  d.get("operationTemplateId"),
        "workOrderOperationId": d.get("workOrderOperationId"),
        "eventAt":              d.get("eventAt"),
        "shotCount":            d.get("shotCount"),
        "scrapCount":           d.get("scrapCount"),
        "weightValue":          d.get("weightValue"),
        "weightUomId":          d.get("weightUomId"),
        "dataCollectionValuesJson":
            BlueRidge.Common.Util.convertWrapperObjectToJson(d.get("dcValues") or {}),
        "appUserId":            appUserId,
        "terminalLocationId":   terminalLocationId,
        "remarks":              d.get("remarks"),
    }
    return BlueRidge.Common.Db.execMutation("workorder/ProductionEvent_Record", params)

def listByLot(lotId):
    """Checkpoints for one LOT (last-shot hint + history). Returns list[dict]."""
    return BlueRidge.Common.Db.execList("workorder/ProductionEvent_ListByLot", {"lotId": _u(lotId)})
```

### 6.2 `BlueRidge.Workorder.RejectEvent` (net-new module)

```python
def record(data, appUserId=None, terminalLocationId=None):
    """Log a reject + decrement the LOT (D3). data: {lotId, defectCodeId,
       quantity, chargeToArea, productionEventId, remarks}.
       Returns {Status, Message, NewId}."""
    d = _u(data) or {}
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "lotId":             d.get("lotId"),
        "defectCodeId":      d.get("defectCodeId"),
        "quantity":          d.get("quantity"),
        "chargeToArea":      d.get("chargeToArea"),
        "productionEventId": d.get("productionEventId"),
        "remarks":           d.get("remarks"),
        "appUserId":         appUserId,
        "terminalLocationId": terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("workorder/RejectEvent_Record", params)
```

### 6.3 `BlueRidge.Tools.ToolCavity` (net-new module)

```python
def getActiveForDropdown(toolId):
    """Active cavities for the mounted tool. [{label, value}] for the cavity
       dropdown (label = 'Cavity N', value = ToolCavity.Id). Empty = none."""
    rows = BlueRidge.Common.Db.execList(
        "tools/ToolCavity_ListActiveByTool", {"toolId": _u(toolId)}) or []
    return [{"label": "Cavity %s" % r.get("CavityNumber"), "value": r.get("Id")}
            for r in rows]
```

### 6.4 `BlueRidge.Tools.ToolAssignment` (net-new module)

```python
def getActiveByCell(cellLocationId):
    """The tool currently mounted on a cell, or None. Drives the Tool
       confirmation card auto-populate (FDS-05-004 step 4)."""
    rows = BlueRidge.Common.Db.execList(
        "tools/ToolAssignment_ListActiveByCell",
        {"cellLocationId": _u(cellLocationId)}) or []
    return rows[0] if rows else None

def getActiveByCellOrEmpty(cellLocationId):
    """Binding-safe variant: fully-shaped dict (never None) so the Tool card's
       nested-path bindings never Component-Error (07 / 02 pre-declare rule)."""
    row = getActiveByCell(cellLocationId)
    if row is None:
        return {"ToolId": None, "ToolCode": "", "ToolName": "", "AssignmentId": None}
    return row
```

The Tool card binds to `getActiveByCellOrEmpty` (shaped-empty path); script callers that branch on absence use `getActiveByCell`. The re-assign (Edit) path reuses the **existing** `BlueRidge.Parts.Tool.releaseAssignment` / `assignToCell` — no new Tool entity work here.

## 7. Gateway script — `DieCastCycleReader` (DEFERRED / out of scope)

Per SQL spec §9, the `DieCastCycleReader` gateway script (PLC/TOPServer cycle-count ingestion that would auto-emit `ProductionEvent` checkpoints from the press counter) is **Phase 6 territory** and is **NOT built here**. The operator-override path (manual Checkpoint panel, §3.2) covers the requirement for Phase 3. This spec records only the **integration seam** so Phase 6 drops in cleanly:

- A gateway tag-change / timer script (`script-python/BlueRidge/Workorder/DieCastCycleReader/code.py`, Core) would, on a TOPServer cavity-cycle tag transition, resolve the active LOT for the press/cavity and call `BlueRidge.Workorder.ProductionEvent.record(...)` with the cumulative `shotCount` — the **same entity method** the UI uses. Because the contract is cumulative (D1), an automated reader and a manual checkpoint are interchangeable: whichever writes last carries truth (FDS-03-017a "a missed checkpoint does not compound errors").
- No tag bindings, no OPC config, no gateway timer are authored in Phase 3. The seam is purely: "Phase 6 calls the existing `ProductionEvent.record` entity method." Per `07` anti-patterns, the eventual reader is a **gateway-event/timer** script calling a one-line entity method — never a per-tag tag-change script.

## 8. Design decisions — SETTLED (baked in 2026-06-15)

The five front-end decisions are settled and are now the design above (they replace the prior open FE-D1..FE-D5). Recorded here for traceability:

- **D1 — Layout matches the mockup; NO tabs (was FE-D1).** Single two-column screen: LEFT NEW-LOT form, RIGHT stacked cumulative-cavity + Reject cards, per `mockup/plantFloor.html` `terminal/diecast`. The `ia.container.tab` shell is withdrawn (§3.1, §3.4). Overriding goal: fewest button presses on the common path (scan LTT → confirm → Submit), with single-cavity auto-default and post-submit cavity-peer reset (§3.1.3).
- **D2 — Cavity dropdown with free-entry fallback (was FE-D2-cavity).** Normally filtered to Active cavities via `ToolCavity_ListActiveByTool`; when none resolve, the dropdown allows operator free-entry (Perspective `ia.input.dropdown` custom-value capability — `props.allowCustomOptions: true` (verified 2026-06-15)). **Cross-spec dependency flagged:** the sql-deltas spec owns the `Lot_Create` no-cavity / free-entry handling (§3.1.2). (The former FE-D2-Item question — cavity-derived vs. eligibility-picker Item — is resolved as: eligibility-constrained dropdown by default, degrade to cavity-derived read-only when `ToolCavity_ListActiveByTool` carries `ItemId`.)
- **D3 — Rapid cavity-peer logging (was FE-D3).** Post-success "Create LOT from another cavity" keeps Cell/Tool/Item sticky, clears only Cavity + Piece Count + LTT (+ Weight); non-persisted "logged this run" tally; N independent `Lot_Create` calls, flat genealogy (§3.1.3).
- **D4 — Scanned LTT captured, server-mint default, one-line flip (was FE-D4).** Default `@LotName = NULL` (server mint) + capture scanned value + mismatch warning. Flipping to "scanned LTT IS the LOT name" is one line at the `Lot.create` call site (§3.1.1). **MPP confirmation expected the day after this revision;** both states documented so the answer is a config flip, not rework.
- **D5 — Data-driven checkpoint field typing (was FE-D5).** `FieldInputRow` selects the widget from `DataCollectionField.DataType` (String→text, Integer/Decimal→numeric-entry-field, Boolean→checkbox, Date→date picker), per §3.2. **Cross-spec dependency:** the `DataType` column + its `DieCastShot` seeds are owned by the sql-deltas spec; this front-end only reads the column. The earlier "derive from field `Code`" fallback is no longer needed (NULL → safe `String` default only).

## 9. Conventions & gaps

**Conventions designed to:**
- Three-layer rule strictly: view → `BlueRidge.<Domain>.<Entity>` → `Common.Db/Ui/Util`. No `system.db.*` outside `Common.Db`.
- Every mutation ends in one `Common.Ui.notifyResult(result, successTitle=...)` call (`07` "route every result through notifyResult"); never double-route with a parallel `sendMessage`.
- `editDraft`-with-explicit-Save semantics; zero auto-save; bidi form bindings into `view.custom.editDraft` / `view.custom.dcValues`.
- Atomic state writes when reseeding `selected`+`editDraft` in one property write (Item-Master `load()` rule) to avoid spurious dirty flips.
- Embed sub-views receive input-only params; cross back to the parent with page-scoped messages (`feedback_ignition_embed_params_input_only`, `feedback_ignition_message_scope`).
- `onStartup` under `events.system`, not `events.component` (`feedback_ignition_onstartup_system_domain`); `system.perspective.*` from a DOM-event script needs `scope: "G"` (`feedback_ignition_popup_open_scope`); event-script bodies start with `\t`.
- ASCII-only display strings; ≥ 44 px touch targets; no drag-and-drop (FDS-02-013, `07`).
- `mpp/` icon paths verified against `ignition/icons/mpp/mpp.svg` before use (`mpp/qr_code_scanner` confirmed present in `CellContextSelector`; `mpp/add` does not exist — use `mpp/add_circle`).
- New views authored as files + gateway scan; **but new NQs require a gateway RESTART** to register in the inherited registry (`project_mpp_nq_core_topology`).

**Cross-spec dependencies on the sql-deltas spec (RESOLVED there, consumed here):**
1. **`DataCollectionField.DataType` column** — the D5 widget driver. The sql-deltas spec adds the column and seeds it for the `DieCastShot` fields (`GoodCount`/`BadCount` → Integer, `Weight` → Decimal, `DieInfo`/`CavityInfo` → String). This front-end reads it via `OperationTemplateField_ListByTemplate` and maps it to widgets (§3.2). No code-from-`Code` heuristic remains (NULL → `String` default only). **Owned by the sql-deltas spec.**
2. **`Workorder.ProductionEvent_ListByLot` read proc** — feeds the right-rail cumulative-cavity card (latest `ShotCount`/`ScrapCount`/`EventAt`) and the checkpoint last-shot hint (§3.1-D, §3.2). Now a **confirmed** cross-spec read (the sql-deltas spec adds the thin read proc). The front-end wraps it as `workorder/ProductionEvent_ListByLot` (§5) + `BlueRidge.Workorder.ProductionEvent.listByLot` (§6).
3. **`Lots.Lot_Create` `@LotName` (optional, NULL default) + no-active-cavity / free-entry handling** — D4's name-source seam and D2's free-entered-cavity reconciliation. The sql-deltas spec adds the optional `@LotName` param and defines how the proc consumes a free-text cavity when no active mount/cavity resolves (NULL `ToolCavityId` + free-text label, or relaxed cavity-belongs-to-tool check). This front-end passes `lotName` (NULL default) and either a `ToolCavityId` or a free-text cavity value; **it authors no SQL.** **Owned by the sql-deltas spec.**

**Remaining open questions / ambiguities (need a decision before build):**
1. **MPP confirmation on the canonical LOT id (D4)** — expected the day after this revision. Determines whether `Lot.create` passes `None` (server mint, current default) or `editDraft.scannedLtt`. One-line flip either way (§3.1.1). Until confirmed, ship the server-mint default + mismatch warning.
2. **Free-entry dropdown prop (D2) — RESOLVED 2026-06-15.** `props.allowCustomOptions: true` (top-level on `ia.input.dropdown`, sibling to `search`), verified in Designer. Pack `06` documents it.
3. **Tool re-assign elevated path** depends on `Tools.ToolAssignment_Release` / `_Assign` being callable for a Die Cast cell from the operator station (they exist as Config-Tool procs via `BlueRidge.Parts.Tool`). Confirm the elevated operator role is authorized to mutate assignments from the plant floor (vs. config-tool only) — an auth-policy question, not a code one.
4. **`RejectEvent_Record` `@ScrapCount` vs. `@Quantity` naming** — the SQL spec uses `@Quantity` on `RejectEvent_Record` and `@ScrapCount` on `ProductionEvent_Record`. The NQ param names above follow the proc signatures exactly; verify against the as-built proc headers before authoring the NQ `query.sql`.

## 10. Test / smoke plan

Consistent with how Phase 2 views were smoked (`sql/scratch/smoke_seed_phase2.sql` — a deterministic, idempotent seed that prints ids + ready-to-click URLs; the dev DB holds zero persistent LOTs because the test suite tears down).

**Smoke seed — `sql/scratch/smoke_seed_phase3_diecast.sql` (dev aid, not a migration, not a test).** Idempotent wipe of `Lots.*` + `Workorder.ProductionEvent*` / `Workorder.RejectEvent` (FK-safe order: `ProductionEventValue` → `ProductionEvent` → `RejectEvent` → closure → genealogy → Lot, per `feedback_arc2_lot_test_teardown_fk_order`). Then build:
- An active `ToolAssignment` on a Die Cast Cell (so the Tool card auto-populates) with ≥ 2 Active `ToolCavity` rows (so the cavity dropdown and the cavity-peer flow exercise; `Lot_Create` skips the mount check when no active mount exists per `project_mpp_plant_floor_smoke_seed` — here we WANT the mount present to exercise FDS-05-034).
- Two cavity-peer LOTs via `Lot_Create` (same Tool, different `ToolCavityId`) to verify flat genealogy (no `LotGenealogy` edge between them).
- One `ProductionEvent` checkpoint on a peer (cumulative `ShotCount`) to verify D2 (LOT `InventoryAvailable`/`TotalInProcess` unchanged) and the `DieCastShot` `OperationTemplateField`-driven render.
- One `RejectEvent` decrementing a peer; a second reject that zeroes it (verify close-at-zero, D3).
- `PRINT` the lotIds + URLs: `/shop-floor/die-cast`, `/shop-floor/die-cast/checkpoint/<lotId>`, `/shop-floor/die-cast/reject/<lotId>`.

**Screens to exercise (operator walkthrough — single screen, no tabs):**
1. Navigate `/shop-floor/die-cast`; the context bar shows the seeded Cell; Tool auto-populates from the mount. Verify the two-column layout (LEFT NEW-LOT form, RIGHT cumulative-cavity + Reject cards) renders, and on a narrow viewport the right cards stack below the form (no tabs).
2. **Minimal-tap path (D1):** scan the LTT (single active cavity auto-defaults; Item resolves) → **Submit · Create LOT** → toast shows `MintedLotName`; if the scanned LTT ≠ minted name, the mismatch warning fires (D4). `view.custom.activeLotId` updates → the right-rail cumulative-cavity card targets the new LOT.
3. **Cavity-peer (D3):** click "Create LOT from another cavity" → Cell/Tool/Item stay sticky, Cavity + Piece Count + LTT clear; log cavity 2 as a second peer; confirm the "logged this run" tally shows 2 and (via LOT Detail / genealogy from Phase 2) the peers have no parent/child edge.
4. **Free-entry cavity (D2):** on a Cell with no active mount/cavities, confirm the Cavity dropdown allows free-entry; submit and confirm the proc's handling (per the sql-deltas spec) — until that handling lands, confirm the rejection `Message` surfaces.
5. **Checkpoint (D5/D2):** open the Checkpoint surface for a peer; verify the dynamic fields render with the **`DataType`-selected widget per field** (Integer→numeric, String→text, etc.); submit a cumulative checkpoint; confirm LOT piece availability is unchanged (D2) and a missing-required field is rejected with the proc message; confirm the right-rail cumulative card refreshes from `ProductionEvent_ListByLot`.
6. **Reject (D3):** in the right Reject card, reject < piece count (decrements); reject the remainder (closes the LOT, warning toast); confirm an over-quantity reject is rejected with the proc message.
7. Verify `notifyResult` toasts fire on every success/failure; verify nothing writes to the DB except on explicit button click; verify the Edit-Tool elevated path opens `ElevationModal`.

**Automated coverage** stays in the SQL suite (`0022_PlantFloor_DieCast`, SQL spec §7) — the front-end has no unit harness; the smoke walkthrough is the front-end verification gate. Run `.\scan.ps1` after writing the new views; **restart the gateway** after adding the new Core NQs.

## 11. Out of scope

- The `DieCastCycleReader` gateway script + all PLC/TOPServer/OPC cycle-count ingestion (Phase 6; seam noted §7).
- Scale (OmniServer) weight auto-capture (Phase 6) — weight is operator-entered in Phase 3.
- Zebra/ZPL label printing — die cast uses **pre-printed** LTTs (FDS-05-004 step 9; no `Initial` print at die cast).
- Downtime entry and warm-up shots (`Oee.DowntimeEvent` — Phase 8).
- Machining sub-LOT split (`Lot_Split` UI — different phase/area; cavity peers are NOT splits, §5.4).
- Controlled Run Tag / hold release (FDS-10-012) and vision/MIP serialized-line flows (Assembly phases).
- Any new or modified stored procedure or migration. **SQL is owned by the parallel sql-deltas spec** — the three cross-spec dependencies (`DataCollectionField.DataType`, `Workorder.ProductionEvent_ListByLot`, `Lots.Lot_Create @LotName` + no-cavity/free-entry handling, §9) live there, not here.
- `BlueRidge.Parts.Tool` re-assign procs (reused as-is, not re-authored).

## 12. Phase 3 front-end complete when

- The single **no-tabs, two-column** `DieCastEntry` page (matching the mockup, D1) + the `CheckpointPanel` / `RejectPanel` embedded cards + `FieldInputRow` / `PeerTallyRow` row sub-views authored in MPP, scanned, rendering on a tablet-width viewport with ≥ 44 px targets, stacking correctly on narrow.
- Core NQs (`workorder/ProductionEvent_Record`, `workorder/RejectEvent_Record`, `tools/ToolCavity_ListActiveByTool`, `tools/ToolAssignment_ListActiveByCell`, `workorder/ProductionEvent_ListByLot`) created with `type:"Query"` on the mutation pair; `lots/Lot_Create/query.sql` gains the `:lotName` line (D4); the gateway restarted so the new NQs register.
- Core entity modules `BlueRidge.Workorder.ProductionEvent`, `BlueRidge.Workorder.RejectEvent`, `BlueRidge.Tools.ToolCavity`, `BlueRidge.Tools.ToolAssignment` delivered (thin wrappers, no business logic); `BlueRidge.Lots.Lot.create` forwards the optional `lotName` (D4).
- Three `/shop-floor/die-cast*` routes + the HomeRouter Die Cast tile wired.
- The smoke walkthrough (§10) passes end-to-end: minimal-tap create (D1), free-entry cavity (D2), cavity-peer create (D3, flat genealogy), data-driven checkpoint (D5) + unchanged inventory (D2), reject + close-at-zero (D3), all with `notifyResult` toasts.
- The sql-deltas spec's three cross-spec dependencies (§9: `DataType`, `ProductionEvent_ListByLot`, `Lot_Create @LotName` + no-cavity handling) are delivered; the MPP D4 LOT-id confirmation is dispositioned (server-mint vs. scanned-LTT, one-line flip).
