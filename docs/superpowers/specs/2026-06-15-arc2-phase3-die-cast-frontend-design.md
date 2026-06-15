# Arc 2 Phase 3 — Die Cast Operator Station: FRONT-END (Ignition Perspective) — Design

**Date:** 2026-06-15
**Status:** Draft for review
**Scope:** The **Perspective / Named-Query / entity-script / gateway layer** for the Die Cast workflow — the deferred follow-on the Phase 3 SQL spec explicitly hands off ("a separate front-end spec", SQL spec §9). It wraps the SQL foundation already designed/built in migration `0022` and three net-new procs. This spec adds: the Die Cast LOT Entry view, the Checkpoint and Reject embedded components, the cavity-peer creation flow, the Core Named Queries that front the five procs, the Core entity-script modules that call them, the page-config routes, and the integration seam for the (out-of-scope) `DieCastCycleReader` gateway script. **No SQL is authored or modified here** — the procs are the contracts; this layer is a thin, business-logic-free caller (FDS-13-002, "no business logic in Python").

## 1. Source of truth

- **Phase 3 SQL spec** — `docs/superpowers/specs/2026-06-12-arc2-phase3-die-cast-sql-design.md`. The proc contracts wrapped here, plus decisions D1 (cumulative `ShotCount`), D2 (checkpoints don't move inventory), D3 (`RejectEvent` decrements LOT + close-at-zero). This front-end spec MUST NOT reinterpret those decisions; it surfaces their effects to the operator.
- **Phased plan** — `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` § "Phase 3 — Die Cast Operator Station"; task list `MPP_MES_TASK_LIST_PLANT_FLOOR.csv` T082–T085 (the deferred UI/gateway subset the SQL spec named).
- **FDS** — §5.2 **FDS-05-004** (Manufactured LOT creation at Die Cast), **FDS-05-034 / FDS-05-035** (Tool+Cavity required on die-cast `Lot_Create`; Tools system-of-record on `Lot`), **FDS-05-036** (lazy, operator-driven LOT creation), **FDS-03-013 / FDS-03-017a** (operation-template-driven dynamic screen rendering; checkpoint shape), **FDS-05-038** (Pausable LOT indicator — already shipped in Phase 2, reused), **§5.4 FDS-05-004 note** (cavity-parallel peers = N independent LOTs, flat genealogy), **FDS-02-013** (tablet design constraint — touch targets ≥ 44 px, portrait), **FDS-10-012** (Controlled Run Tag — relevant only as an out-of-scope seam).
- **Data Model** — `Workorder.ProductionEvent` / `ProductionEventValue` / `RejectEvent`; `Lots.Lot` `ToolId`/`ToolCavityId`; `Parts.OperationTemplate` / `OperationTemplateField` / `DataCollectionField`.
- **Ignition context pack** — `07_conventions_and_antipatterns.md` (view authoring, three-layer rule, save semantics), `02_perspective_views.md`, `06_component_quirks.md`, `03_script_python.md`, `04_named_queries.md`.
- **Shipped Phase 1/2 plant-floor surface** — reference implementations this spec mirrors: `CellContextSelector`, `InitialsField`, `ElevationModal`, `PausedLotIndicator`, `LotDetail`, and the `BlueRidge.Lots.Lot` entity module (`ignition/projects/Core/.../BlueRidge/Lots/Lot/code.py`).

## 2. Reconciliation to shipped resources

What already exists and is **reused, not rebuilt**:

- **Procs (SQL spec, migration 0022):** `Workorder.ProductionEvent_Record`, `Workorder.RejectEvent_Record`, `Tools.ToolCavity_ListActiveByTool`, plus the pre-shipped `Tools.ToolAssignment_ListActiveByCell` and the Phase 1/2 `Lots.Lot_Create`, `Lots.Lot_AssertNotBlocked`. Seeded `DieCastShot` `OperationTemplate` + its `OperationTemplateField` rows (`DieInfo`, `CavityInfo`, `Weight`, `Good`, `Bad`, `ShotCount`).
- **Entity scripts (Core):** `BlueRidge.Lots.Lot.create(...)` already wraps `Lot_Create` with `toolId` / `toolCavityId` params — the Die Cast LOT Entry view calls it unchanged. `BlueRidge.Quality.DefectCode` already lists defect codes for the reject dropdown.
- **Named Queries (Core):** `lots/Lot_Create` (carries `toolId`/`toolCavityId`/`weight`/`pieceCount`), `quality/DefectCode_List`, `parts/OperationTemplateField_ListByTemplate`, `parts/DataCollectionField_List`, `parts/OperationTemplate_List`, `lots/Lot_AssertNotBlocked`. **No `tools/` or `workorder/` NQ group exists yet** — this spec creates them (§5).
- **Perspective components (MPP):** `Components/PlantFloor/CellContextSelector` (Cell resolution by terminal context, dropdown, and scan), `Components/PlantFloor/InitialsField` + `ElevationModal` (operator attribution + AD elevation), `Components/PlantFloor/PausedLotIndicator` (FDS-05-038 — embedded unchanged on the Die Cast screen). `session.custom.cell`, `session.custom.terminal.terminalLocationId`, and `session.custom.appUserId` are the established context model.
- **Routes:** `BlueRidge/Views/ShopFloor/HomeRouter` is the terminal entry point; `page-config/config.json` already routes `/shop-floor/*`. This spec adds three entries under that prefix.

Net-new in this spec: 3 view trees + their row sub-views, 5 NQs (2 read, 3 mutation/read), 2 entity-script modules, 3 page-config routes, 1 deferred-gateway seam note.

## 3. The views and components

All views live in the **MPP** project (`ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/...`). Flex-repeater ROW sub-views live under `Components/PlantFloor/<Page>/<Row>` — **never nested inside a page-view's own folder** (Ignition will not register a view nested under another view; per `parallel-view-authoring` memory). Every view's root keeps `meta.name: "root"`. Every binding-read `view.custom.*` prop is pre-declared with a fully-shaped default (`07` → "Pre-declare every custom property a binding reads").

### 3.1 Die Cast LOT Entry — `Views/ShopFloor/DieCastEntry` — `MVP` (FDS-05-004, FDS-05-034, FDS-05-036)

The primary screen. Route `/shop-floor/die-cast`. Portrait-first, single-column flex, ≥ 44 px touch targets throughout (FDS-02-013). Layout top-to-bottom:

1. **Header band** — page title, embedded `CellContextSelector` (`replyMessage: "cellContextChanged"`), embedded `InitialsField`, embedded `PausedLotIndicator` (bound to `session.custom.cell.locationId` — FDS-05-038). These are existing components; the view embeds them and subscribes to `cellContextChanged` (page scope) to drive its own context reload.

2. **Tool confirmation card** — on Cell change, `view.custom.activeTool` is loaded from `BlueRidge.Tools.ToolAssignment.getActiveByCell(cellLocationId)` (§6). Card shows Tool code + name and the confirmation prose from FDS-05-004 step 4 ("Confirm this die matches the physical tool"). Two actions:
   - **Confirm** — sets `view.custom.toolConfirmed = true` (local; no DB write).
   - **Edit (elevated)** — opens `ElevationModal`; on elevation success, opens the Tool re-assign flow. Per FDS-05-004 the correction is `Tools.ToolAssignment_Release` + `Tools.ToolAssignment_Assign`, which already exist as `BlueRidge.Parts.Tool.releaseAssignment` / `assignToCell`. **This spec WIRES those existing entity methods through the elevated path; it does not author new release/assign procs.** When no active assignment is found, the card shows an empty-state ("No die mounted on this cell — mount a tool in the Tools screen or use Edit to assign") and the cavity dropdown is disabled.

3. **Entry form** (bidi-bound to `view.custom.editDraft`, the established `editDraft` pattern):
   - **Cavity** — `ia.input.dropdown`, options from `BlueRidge.Tools.ToolCavity.getActiveForDropdown(toolId)` (wraps `Tools.ToolCavity_ListActiveByTool`, Active cavities only). Required.
   - **Item (part)** — `ia.input.dropdown`, options constrained to Items eligible at this Cell per FDS-02-012. Sourced from the existing eligibility read (`BlueRidge.Parts.Eligibility` / `Location_ListForEligibilityPicker` family). If the SQL spec's note holds (Item per cavity carried on `ToolCavity_ListActiveByTool`), the Item auto-populates from the selected cavity and this dropdown becomes a confirm/override; **design decision FE-D2 below.**
   - **Piece count** — text-field (numeric coercion in the proc, per the project's `text-field`-for-numbers convention; `numeric-entry-field` is the alt, see `06`). Required. The UI MAY preflight `pieceCount <= Item.MaxLotSize` (`PartsPerBasket`) for UX, but the proc remains authoritative (FDS-05-004 step 6).
   - **Weight + Weight UOM** — text-field + dropdown. Optional (scale integration is Phase 6).
   - **LTT scan** — text-field with `mpp/qr_code_scanner` adornment, mirroring `CellContextSelector`'s scan input. Per FDS-05-004 the LTT is pre-printed; the scanned barcode is the minted `LotName` the operator affixes. (The current `Lot_Create` mints the name server-side and returns `MintedLotName`; the scanned value is captured for reconciliation/audit. **Design decision FE-D4 below** on whether the operator-scanned LTT must equal the minted name.)

4. **Create LOT** button — wired to `BlueRidge.Lots.Lot.create(editDraft, appUserId, terminalLocationId)` (existing entity method, unchanged), passing `lotOriginTypeId = Manufactured`, `currentLocationId = session.custom.cell.locationId`, `toolId = activeTool.Id`, `toolCavityId`, `itemId`, `pieceCount`, `weight`, `weightUomId`. Result routed through `Common.Ui.notifyResult`. On `Status` success:
   - Toast shows the `MintedLotName`.
   - The view **does NOT** clear the Cell / Tool context — it clears only cavity/item/count/weight/scan so the operator can immediately log the **next cavity peer**. This realizes "N active cavities = N independent LOTs, flat genealogy" (§5.4 FDS-05-004): each cavity peer is a separate `Lot_Create` call with a different `toolCavityId`; no parent/child FK is created, because the UI never calls `Lot_Split`. The screen offers a small "cavities logged this run" tally bound to a local `view.custom.peersThisSession` list for operator orientation only (not persisted).
   - The view then prompts (inline banner, not modal — FDS-05-038 "no auto-prompt" ethos) "Record opening checkpoint?" linking to the Checkpoint panel pre-loaded with the new `lotId`.

5. **Checkpoint + Reject access** — the new LOT id (and any LOT resolved by scanning an existing LTT) feeds the Checkpoint and Reject panels (§3.2, §3.3), which are embedded as collapsible sections on the same view OR reachable via the `ia.container.tab` (see §3.4). **Design decision FE-D1 below** chooses tab vs. single-scroll.

### 3.2 Checkpoint panel — `Components/PlantFloor/DieCastEntry/CheckpointPanel` — `MVP` (FDS-03-013, FDS-03-017a)

Records one `Workorder.ProductionEvent` per logging action. Input is `params.lotId` (BIGINT, `paramDirection: "input"` — embed params are input-only; cross the boundary back to the parent with a page-scoped message, per `feedback_ignition_embed_params_input_only`).

- **Dynamic field rendering (FDS-03-013).** On `lotId` / template change, `view.custom.fields` is loaded from `BlueRidge.Parts.OperationTemplate.getFieldsForTemplate(dieCastShotTemplateId)` (existing method wrapping `OperationTemplateField_ListByTemplate`). The panel renders one input per field via a **flex-repeater** over `Components/PlantFloor/DieCastEntry/FieldInputRow` (the ROW sub-view). The row picks a type-aware input (text-field / numeric / dropdown for Boolean) keyed off the field's data type. **GAP — see §9: `DataCollectionField` has no `DataType` column in the shipped schema.** Until that gap is resolved the row derives the input kind from the field `Code` (the seeded `DieCastShot` set is fixed: `ShotCount`/`Good`/`Bad` → integer, `Weight` → decimal, `DieInfo`/`CavityInfo` → string). The repeater binds each row's value bidirectionally into `view.custom.dcValues[<DataCollectionFieldId>]`.
- **Hot columns vs. data-collection values.** `ShotCount`, `ScrapCount` (the `Bad`/`Good` aggregate per the proc), `WeightValue` map to the proc's typed parameters; everything else is shredded into `@DataCollectionValuesJson`. The panel assembles the JSON via `BlueRidge.Common.Util.convertWrapperObjectToJson(dcValues)` and passes the hot columns separately. The proc rejects a payload that duplicates a hot-column field in `ProductionEventValue` (FDS-03-017a step 2d) and rejects missing `IsRequired` fields (step 2c) — the UI surfaces those as the proc's `Message` toast; it does not pre-enforce them (no business logic in Python).
- **Cumulative semantics surfaced (D1).** Field labels read "Cumulative shots (cavity counter)" / "Cumulative scrap" so the operator enters the running counter, not a delta. The panel MAY display the last recorded `ShotCount` for this LOT (read via a `ProductionEvent` list, §6) as a hint, with copy "last checkpoint: N shots — enter the current total." Deltas are a report concern (D1), never computed in the UI.
- **D2 surfaced.** A small note clarifies a checkpoint records production metrics only and does **not** change the LOT's piece availability (`InventoryAvailable` / `TotalInProcess` stay put). This pre-empts operator confusion that "logging 500 shots" should change the basket count.
- **Submit** → `BlueRidge.Workorder.ProductionEvent.record(...)` (§6) → `Common.Ui.notifyResult`. On success the panel clears its draft and broadcasts `checkpointRecorded` (page scope) so the parent can refresh the last-shot hint.

### 3.3 Reject panel — `Components/PlantFloor/DieCastEntry/RejectPanel` — `MVP` (D3, FDS-06-019 family)

Logs a `Workorder.RejectEvent` that **decrements the LOT and closes it at zero** (D3). Input `params.lotId`.

- **Defect code** — `ia.input.dropdown`, options from `BlueRidge.Quality.DefectCode.getForDropdown()` (existing). Required.
- **Quantity** — text-field, required. The proc enforces `0 < Quantity <= Lot.PieceCount` (SQL spec §4.2); the UI surfaces the rejection message rather than pre-validating.
- **Charge-to-area** + **Remarks** — optional.
- **D3 behavior surfaced to the operator.** Confirmation prose: "Rejecting N pieces removes them from LOT <name> (now M − N). If this empties the LOT it will be closed." On success, `notifyResult` toast shows the proc `Message` (which the SQL spec specifies includes the new piece count); when the proc returns the close-at-zero outcome, the toast level is `warning` and copy reads "LOT closed — all pieces rejected." The panel broadcasts `rejectRecorded` (page scope); the parent reloads the LOT header (piece count, status) so the closed state is visible. Reject and inventory-reduction are one operation — there is no separate "scrap" control (D3).

### 3.4 Container / tab shell

The three surfaces (Entry / Checkpoint / Reject) are presented in one operator screen. Per project convention, multi-section grouping uses the **`ia.container.tab`** component (`props.tabs` + children with `position.tabIndex` + the `tab-strip` / `tab-item` / `tab-item-active` / `tab-content-fill` style slots — `feedback_ignition_tab_container_slots`), never a hand-rolled button strip. The LOT-context (current `lotId`) is held on `view.custom.activeLotId` and passed as the input param to the Checkpoint and Reject embeds. **Design decision FE-D1** confirms tab-shell vs. single scroll for the tablet form factor.

### 3.5 Row sub-views

- `Components/PlantFloor/DieCastEntry/FieldInputRow` — one dynamic data-collection input (label + type-aware control), value bidi-bound back to the parent via page message (embed params are input-only).
- `Components/PlantFloor/DieCastEntry/PeerTallyRow` — one logged cavity-peer line in the "logged this run" tally (cavity #, LotName, count). Display-only.

(Reject and Checkpoint use no row sub-views beyond `FieldInputRow`.)

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
| `workorder/ProductionEvent_ListByLot` | (read; see GAP §9) | `Query` | `Common.Db.execList` |

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

Read NQs (`ToolCavity_ListActiveByTool`, `ToolAssignment_ListActiveByCell`) take a single Id param and have no `parameters[]`-beyond-the-Id, no cache by default.

## 6. Entity scripts (Core)

**All entity scripts live in the `Core` project**, schema-aligned folders (`script-python/BlueRidge/<Domain>/<Entity>/code.py`). Standard module shape (`03`): log entry/exit, `_u()` deep-unwrap at the boundary, `_currentAppUserId()` for attribution defaults, dict in / dict-or-list out, route every DB call through `Common.Db.*`. No `system.db.*` in entity scripts; no business logic (validation/rules stay in the procs).

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

## 8. Design decisions to confirm at review

Like the SQL spec's D1–D3, these are the genuine front-end calls. Everything else follows the established plant-floor patterns verbatim.

- **FE-D1 — Screen composition: one `ia.container.tab` shell vs. single scrolling form.** Recommendation: **tab shell** (Entry / Checkpoint / Reject) with the active `lotId` on `view.custom.activeLotId`, because on a portrait tablet a single scroll past three forms buries the Create action and the dynamic checkpoint fields. Confirm whether the operator prefers all-on-one-scroll for a glanceable workflow.
- **FE-D2 — Item source at Die Cast: cavity-derived vs. operator-selected.** The SQL spec left open whether `ToolCavity_ListActiveByTool` carries the producing `ItemId` per cavity or whether the view resolves Item from Cell eligibility (FDS-02-012). **Recommendation:** if the proc returns `ItemId` per cavity, auto-populate the Item field from the selected cavity (confirm/override); otherwise present the eligibility-constrained Item dropdown. Confirm which the shipped proc does — it changes the form's interaction model.
- **FE-D3 — Cavity-peer logging UX.** N active cavities = N independent `Lot_Create` calls (flat genealogy, §5.4 FDS-05-004). **Recommendation:** keep Cell/Tool sticky after each create and clear only cavity/item/count so the operator can rapid-log peers, with a non-persisted "logged this run" tally. Confirm whether MPP wants an explicit "log all active cavities" batch action instead of one-at-a-time (would still be N separate proc calls — no batching at the SQL layer).
- **FE-D4 — Scanned LTT vs. minted `LotName`.** `Lot_Create` mints the name and returns `MintedLotName`; the LTT is pre-printed (FDS-05-004 step 2–3). **Recommendation:** capture the scanned barcode for audit/reconciliation and surface a mismatch warning if the scanned value ≠ minted name, but let the proc remain the name authority. Confirm whether the pre-printed LTT barcode IS the LOT name (in which case `Lot_Create` must accept a caller-supplied name — **a proc change, out of this spec's scope**, to flag back to the SQL spec).
- **FE-D5 — Dynamic field input typing (depends on the §9 GAP).** Until `DataCollectionField` carries a `DataType`, `FieldInputRow` derives the input kind from the seeded field `Code`. Confirm whether to (a) add a `DataType` column to `DataCollectionField` (cleaner, a small SQL change) or (b) live with code-driven typing for the fixed `DieCastShot` set. Recommendation: (a), tracked as a follow-on SQL task — but Phase 3 ships with (b) so the front-end is not blocked.

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

**Gaps / ambiguities surfaced (need a decision before build):**
1. **`DataCollectionField` has no `DataType` column** (data model §, confirmed in shipped `DataCollectionField_List` and `OperationTemplate` entity script). The prompt's "type-aware String/Integer/Decimal/Boolean/Date rendering" has no schema backing. Phase 3 derives input type from field `Code` for the fixed `DieCastShot` set; resolving cleanly needs a small SQL change (FE-D5). **Flagged to the SQL spec owner.**
2. **`ProductionEvent_ListByLot` read proc is not in the SQL spec.** The "last checkpoint shots" hint (§3.2) and any checkpoint history need a read proc the SQL spec did not enumerate (it specified only the three net-new procs + the reused reads). Either add a thin `Workorder.ProductionEvent_ListByLot` read proc (recommended — small) or drop the last-shot hint for Phase 3. **Flagged; the hint is a nice-to-have, not load-bearing.**
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

**Screens to exercise (operator walkthrough):**
1. Navigate `/shop-floor/die-cast`; select the seeded Die Cast Cell → Tool card auto-populates; confirm Tool.
2. Pick cavity 1, eligible Item, piece count, weight → Create → toast shows `MintedLotName`; Cell/Tool stay; form clears for the next peer.
3. Log cavity 2 as a second peer; confirm the "logged this run" tally shows 2 and (via LOT Detail / genealogy from Phase 2) that the peers have no parent/child edge.
4. Open Checkpoint for a peer; verify the dynamic fields render from `DieCastShot`; submit a cumulative checkpoint; confirm LOT piece availability is unchanged (D2) and a missing-required field is rejected with the proc message.
5. Open Reject for a peer; reject < piece count (decrements); reject the remainder (closes the LOT, warning toast); confirm an over-quantity reject is rejected with the proc message.
6. Verify `notifyResult` toasts fire on every success/failure; verify nothing writes to the DB except on explicit button click; verify the Edit-Tool elevated path opens `ElevationModal`.

**Automated coverage** stays in the SQL suite (`0022_PlantFloor_DieCast`, SQL spec §7) — the front-end has no unit harness; the smoke walkthrough is the front-end verification gate. Run `.\scan.ps1` after writing the new views; **restart the gateway** after adding the new Core NQs.

## 11. Out of scope

- The `DieCastCycleReader` gateway script + all PLC/TOPServer/OPC cycle-count ingestion (Phase 6; seam noted §7).
- Scale (OmniServer) weight auto-capture (Phase 6) — weight is operator-entered in Phase 3.
- Zebra/ZPL label printing — die cast uses **pre-printed** LTTs (FDS-05-004 step 9; no `Initial` print at die cast).
- Downtime entry and warm-up shots (`Oee.DowntimeEvent` — Phase 8).
- Machining sub-LOT split (`Lot_Split` UI — different phase/area; cavity peers are NOT splits, §5.4).
- Controlled Run Tag / hold release (FDS-10-012) and vision/MIP serialized-line flows (Assembly phases).
- Any new or modified stored procedure or migration (SQL spec owns SQL; §9 gaps 1–2 + FE-D4 are flagged BACK to the SQL spec, not solved here).
- `BlueRidge.Parts.Tool` re-assign procs (reused as-is, not re-authored).

## 12. Phase 3 front-end complete when

- Views `DieCastEntry` + `CheckpointPanel` + `RejectPanel` + `FieldInputRow` / `PeerTallyRow` row sub-views authored in MPP, scanned, rendering on a tablet-width viewport with ≥ 44 px targets.
- Core NQs (`workorder/ProductionEvent_Record`, `workorder/RejectEvent_Record`, `tools/ToolCavity_ListActiveByTool`, `tools/ToolAssignment_ListActiveByCell`, and — if FE/§9 gap 2 accepted — `workorder/ProductionEvent_ListByLot`) created with `type:"Query"` on the mutation pair, and the gateway restarted so they register.
- Core entity modules `BlueRidge.Workorder.ProductionEvent`, `BlueRidge.Workorder.RejectEvent`, `BlueRidge.Tools.ToolCavity`, `BlueRidge.Tools.ToolAssignment` delivered (thin wrappers, no business logic).
- Three `/shop-floor/die-cast*` routes + the HomeRouter Die Cast tile wired.
- The smoke walkthrough (§10) passes end-to-end: cavity-peer create (flat genealogy), checkpoint (D1/D2), reject + close-at-zero (D3), all with `notifyResult` toasts.
- FE-D1..FE-D5 confirmed with Jacques/MPP; §9 gaps 1–2 and FE-D4 dispositioned by the SQL spec owner.
