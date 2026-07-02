# Machining & Assembly Plant-Floor Flow — Reconciliation Design Spec

**Date:** 2026-07-02
**Status:** Draft — awaiting Jacques review
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor), Phases 5–6 — reconciliation of the built flow to the 2026-07-01/02 customer discovery
**Companion:** **Spec 2 of 2.** Depends on **Spec 1** (`2026-07-02-operation-type-model-restructure-design.md`) for the `OperationType` role that terminals resolve templates by.

> **Grounding note.** `PROJECT_STATUS.md` is stale (newest entry 2026-06-17 / Phase 8). In reality **all Arc 2 phases are built except AIM integration** — the machining/assembly/container/sort/hold/shipping SQL + views landed via the `hunter/explore` merge (PR #2), migrations `0027`–`0029`. **This spec is grounded in the actual code resources, not the status doc.** It is a set of **targeted deltas** (keep / change / add) onto that built flow to match the customer discovery — not a greenfield build. A separate housekeeping task should refresh `PROJECT_STATUS.md`.

---

## 1. The customer discovery (what changed)

From the 2026-07-01/02 walkthrough of the machining/assembly lines:

1. **Route vs BOM separation.** Each die-cast component keeps its own route ending at consumption; the finished good is its own Item # with a short assembly route + a BOM. Components join via consumption edges, not a shared route. (Foundation laid by Spec 1's `OperationType`.)
2. **Machining-out is extract-one, not full split.** The operator FIFO-picks a source LOT and extracts **one** sublot of a required count; the parent stays **open** with the remainder. (This is the already-pending FDS-05-009 / UJ-03 change.)
3. **Assembly-out mints a finished-good LOT.** `tray = LOT` (1:1). One tray closure mints one finished-good LOT whose `PieceCount` = the closure-determined finished count (1 for a single complex set, N for a multi-part tray), consuming `BOM(minted part) × PieceCount` FIFO from line inventory. The **same event** manages the Container: open if needed, add the tray (referencing the LOT), complete the container if full.
4. **Containers persist** (always wrap trays, even 1-1) — first-class for the future RFID + the pending AIM work.
5. **Line-level inventory check-in / on-hand** panel, reusable from any line terminal.
6. **Route shape is authored per part to match the line's terminals** — no runtime collapse logic (config standard).

---

## 2. Configuration/behavior vs Development — reading guide

- **[CONFIG]** — configuration / seed / behavior standard / PLC-commissioning. No new schema or code logic.
- **[DEV]** — schema DDL, stored-proc, Named Query, entity script, or Perspective view that must be written, reviewed, tested.
- **[KEEP]** — already built and already satisfies the discovery; no change.

Consolidated matrix in §10.

---

## 3. Already built — satisfies the discovery — **[KEEP]**

Grounded in the actual resources; do **not** rebuild these:

| Capability | Where | Status |
|---|---|---|
| FIFO machining-in pick + Trim→Machining rename (1-line BOM) | `MachiningIn` view + `Workorder.MachiningIn_PickAndConsume` | ✔ (default FIFO, `@QueueOverrideReason` override) |
| Sparse/coupled machining-out (auto-move via `CoupledDownstreamCellLocationId`, or complete in place) | `Workorder.MachiningOut_AutoComplete` | ✔ — this *is* the "route matches the line, no sublot on 2-terminal lines" case |
| FIFO component consumption — partial/full, many LOTs, `BOM QtyPer × count` | `Lots.ContainerTray_Close` consumption loop | ✔ mechanics; **relocated** to the LOT in §5 |
| BOM strict check + supervisor override (both user IDs audited) | `Workorder.ConsumptionEvent_RecordWithBomCheck` | ✔ |
| Eligibility-driven finished-good list (Direct ∪ BomDerived, hierarchy cascade) | `Parts.Item_ListEligibleForLocation` | ✔ SQL; surfaced as a persistent dropdown in §5 |
| Terminal → operation via distinct default views | `MachiningIn` / `MachiningOutSplit` / `AssemblyIn` set as `defaultScreen`; Dedicated/Shared/Body triads | ✔ — upgraded to resolve by `OperationType` (Spec 1) |
| Container / ContainerTray / ContainerSerial / ShippingLabel / AIM pool model | migration `0028`; `Container_Open/_Complete/_Ship`, `ContainerSerial_Add` | ✔ retained (RFID + AIM future) |
| Container closure-method axis (`ClosureMethod` ByCount/ByWeight/ByVision, `IsSerialized`) | `Parts.ContainerConfig` | ✔ config exists |

---

## 4. Machining deltas — **[DEV]**

### 4.1 `Workorder.MachiningOut_RecordSplit` → extract-one / partial-remainder

**Current:** requires `SUM(children) == parent.PieceCount` and **closes** the parent (old even-N-way split, FDS-05-009). **Change to:** allow `SUM(children) <= parent remaining`, **decrement** the parent by the extracted total, **close only at zero**. The `-NN` naming already computes `MAX(existing suffix)+1` per call, so repeated single-sublot extractions sequence correctly across draws. **Borrow the proven remainder logic from `Lots.Lot_Split`** (which already does exactly this) while keeping this proc's `ProductionEvent` + `@OperationTemplateId` wrapper. Keep the inline (no INSERT-EXEC nesting) + pre-transaction validation structure.

- Executes the pending **UJ-03** FDS action (remove even-split default → operator enters the extracted quantity).
- **[DEV]** proc change + test updates in `sql/tests/0027_PlantFloor_Machining/070,075,080`.

### 4.2 Machining-out source-pick UI

**Current:** `MachiningOutSplit` view shows the most-recent machined LOT and does a full split to two destinations. **Change to:** a **FIFO source-pick** list (the machined LOTs in the cell queue, via `Lot_GetWipQueueByLocation`) + an **extract-one** entry (pick source → enter sublot count + destination → extract, parent remainder stays in queue). **[DEV]** view (existing → Designer edit).

### 4.3 OperationType resolution swap

`MachiningOutSplit` currently resolves its template via `OperationTemplate.getActiveTemplateIdByCode("MachiningOut")`. After Spec 1, resolve by **`OperationType = MachiningOut`** against the scanned part's active route. Same pattern everywhere a view needs "the template for my operation." **[DEV]** entity-script + NQ.

---

## 5. Assembly deltas — the finished-good-LOT rework — **[DEV]**

The built assembly is Container-centric and never mints a finished-good LOT. Rework so **`tray = finished-good LOT`**, Container retained as the wrapper.

### 5.1 New orchestrating proc — `Workorder.Assembly_CompleteTray` (name TBD, D1)

Fired by a **tray-closure trigger** (§5.4). One atomic, **inlined** proc (per the INSERT-EXEC rule — inline the sub-mutations, do not `EXEC` status-row procs) that:

1. **Mints the finished-good LOT** — `@FinishedGoodItemId` (from the persistent dropdown, §5.3), `@PieceCount` (closure-determined: 1 for a single set, N for a multi-part tray), origin `Manufactured`, at the cell. (Inline mirror of `Lot_Create`; writes closure self-row, status history, first-placement movement.)
2. **Consumes the BOM FIFO** — for each `BomLine` of the finished-good Item, need `QtyPer × @PieceCount`, drawn oldest-first (`ORDER BY CreatedAt, Id`) from eligible component LOTs at the line, partial or full, decrementing (and closing at zero) each source. Each draw writes a **`ConsumptionEvent` (now `ProducedLotId` = the FG LOT, not `ProducedContainerId`)** + a **`LotGenealogy` Consumption edge + closure** to the FG LOT. Reuse the existing BOM-check + supervisor-override logic (fold in `ConsumptionEvent_RecordWithBomCheck`'s rules).
3. **Manages the Container** — resolve the open Container at the cell (open one via `Container_Open` if none); insert a **`ContainerTray` referencing the FG LOT** (§5.2); if trays now == `TraysPerContainer`, **complete** the container (`Container_Complete`: AIM claim [pending] + ShippingLabel; RFID future).

Returns a single status row `Status, Message, FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerCompleted BIT`.

### 5.2 `Lots.ContainerTray` gains `FinishedGoodLotId` — **[DEV schema]**

- Add `FinishedGoodLotId BIGINT NOT NULL FK → Lots.Lot(Id)` (new versioned migration). `tray ↔ LOT` is 1:1 → also a `UNIQUE(FinishedGoodLotId)`.
- **`ContainerTray_Close` stops consuming components** (that moves to §5.1). Its remaining job — record the tray + accumulate the container count — is subsumed by the orchestrating proc; either retire `ContainerTray_Close` or reduce it to the tray-insert helper the orchestrator inlines. Decide at build (recommend inline into §5.1, retire the standalone).
- `PartsClosedCount` becomes redundant with the FG LOT's `PieceCount` — keep as a denormalized mirror or drop (build decision).

### 5.3 Persistent eligibility-driven finished-good dropdown — **[DEV UI]**

Surface `Parts.Item_ListEligibleForLocation` as a **persistent on-screen dropdown** in the assembly view (it currently only feeds `Container_Open` implicitly). The selection **persists** for the session (Ignition holds it while the page isn't refreshed — the FDS-02-009 "scan or dropdown" + `allowCustomOptions` pattern applies). Drives the finished-good Item into §5.1. **[DEV]** view (existing → Designer).

### 5.4 Closure-method triggers → the orchestrating event — **[DEV] + [CONFIG]/PLC**

Route each closure method into §5.1, carrying the closure-determined `@PieceCount`:
- **Manual** — operator print-label button (built path) → mint. **[DEV UI]**
- **ByCount** — count target reached → mint. **[DEV]**
- **ByWeight** — PLC/button "tray complete" weight flag → mint. **[DEV + PLC commissioning]**
- **ByVision / Serialized** — PLC/camera "all parts in place" signal → mint (+ register `SerializedPart`s). **[DEV + PLC]**

The `ClosureMethod` / `IsSerialized` config already exists on `ContainerConfig` — **[CONFIG]** which method each part uses; **[DEV]** wiring each trigger into the orchestrator. PLC signal integration for weight/vision is **hardware-gated** at commissioning.

### 5.5 Serialized path alignment — **[DEV]**

Serialized assembly now **also mints a finished-good LOT** (removing the built serialized/non-serialized inconsistency where only serialized carried a `ProducingLotId`). Each `SerializedPart` sets `ProducingLotId` = the new FG LOT; `ContainerSerial` still pins serials to trays. Consumption (if any per-serial) still routes through the BOM-check proc.

### 5.6 Genealogy shape

Becomes **`Container → ContainerTray → FinishedGoodLot → components (per BOM, Consumption edges + closure)`**. Honda trace resolves uniformly through the LOT closure table; the Container→Tray→LOT hops are FK joins. Serialized adds `ContainerSerial → SerializedPart → ProducingLotId`.

---

## 6. Inventory check-in / on-hand panel — **[DEV, new]**

Genuinely not built (only `ReceivingDock` for external receipts). Add a **reusable popup component** triggered from a button in the line-terminal chrome (works on single-op and tabularized multi-use terminals):
- **On-hand read** — inventory at the **line**, grouped **part → lot**, FIFO order, with `InventoryAvailable`. Either a new `Lots.Lot_GetLineInventoryByPart` read or a grouped projection over `Lot_GetWipQueueByLocation` (build decision; recommend a dedicated read for the grouped/available shape). **[DEV]**
- **Scan-in check-in** — scan a LOT → `Lot_MoveToValidated` into the line location (eligibility + `MaxParts` already enforced server-side). **[DEV]** (reuses built proc.)
- Line-scoped context from `session.custom.terminal.zoneLocationId`; page-scoped result message; toast on success. **[DEV UI]**

Likely **resolves OI-32** ("lineside check-in IS the allocation").

---

## 7. Finished-goods KPI — **[DEV, read]**

Add a **derived** read: finished goods produced = `COUNT` of finished-good LOTs and/or `SUM(PieceCount)` by shift / cell / part. No new stored column (reuse `Lot.PieceCount`). **Materialize only if** an OEE dashboard proves the aggregate too slow — then follow the existing B5 materialized-quantity pattern. **[DEV]** read proc; **[CONFIG]** decision to materialize (deferred).

---

## 8. Data-model & migration — **[DEV]**

New versioned migration (after Spec 1's; repo ~`0029` → likely `0031`):
- `ALTER Lots.ContainerTray ADD FinishedGoodLotId BIGINT NOT NULL FK → Lots.Lot(Id)` + `UNIQUE(FinishedGoodLotId)`; reconcile/retire `PartsClosedCount`.
- Audit `LogEventType` for the new assembly-complete event (if distinct from existing).
- Repeatable procs: new `Assembly_CompleteTray`; changed `MachiningOut_RecordSplit`, `ContainerTray_Close` (retire/reduce), `ConsumptionEvent` producer-target shift; new inventory read + finished-goods KPI read.
- Data Model doc: `ContainerTray.FinishedGoodLotId`; note consumption now targets the FG LOT; revision-history row + version bump.

---

## 9. FDS amendments — **[DEV-doc]**

- **FDS-05-009 / FDS-05-010 / FDS-05-022** — replace even-N-way-split prose with **extract-one / partial-remainder** (closes **UJ-03**; the v1.3a carried action).
- **FDS-06-013** (non-serialized assembly) — reframe from Container-fill to **mint finished-good LOT (tray = LOT) + Container wrapper**; consumption targets the LOT.
- **FDS-06-010/011** (serialized) — note serialized now also mints the FG LOT.
- **FDS-06-020/021** (consumption) — `ConsumptionEvent.ProducedLotId` becomes the primary target.
- **OI-32** — close (lineside check-in = allocation, embodied by §6).
- Reconcile the **FIFO ordering** wording (FDS-06-007 `LotMovement.MovedAt` vs FDS-05-029 `CreatedAt`/cavity) into one stated rule per terminal class.
- Revision-history row; version bump.

---

## 10. Config vs Dev — consolidated matrix

| # | Deliverable | Tag |
|---|---|---|
| 1 | FIFO machining-in, coupled auto-move, component-consumption mechanics, BOM check, eligibility SQL, container model, closure-method config | **[KEEP]** |
| 2 | `MachiningOut_RecordSplit` → extract-one/partial | **[DEV]** |
| 3 | Machining-out source-pick UI (extract-one) | **[DEV]** |
| 4 | OperationType resolution swap (from Spec 1) | **[DEV]** |
| 5 | `Assembly_CompleteTray` orchestrator (mint LOT + consume BOM×count + tray + container) | **[DEV]** |
| 6 | `ContainerTray.FinishedGoodLotId` + consumption relocation | **[DEV schema+proc]** |
| 7 | Persistent finished-good dropdown | **[DEV UI]** |
| 8 | Closure-method triggers → orchestrator | **[DEV]** wiring + **[CONFIG]**/PLC per part |
| 9 | Serialized path mints FG LOT | **[DEV]** |
| 10 | Inventory check-in / on-hand popup | **[DEV, new]** |
| 11 | Finished-goods KPI (derived read) | **[DEV read]**; materialize **[CONFIG]** deferred |
| 12 | FDS + Data Model edits; PROJECT_STATUS refresh | **[DEV-doc]** |
| 13 | Which closure method per part; route shape per part matches line terminals | **[CONFIG]** |

---

## 11. Open decisions for Jacques

1. **D1** — orchestrating proc name/shape: one `Assembly_CompleteTray` doing mint+consume+container (recommended), vs splitting mint-LOT from container-manage into two procs.
2. **D2** — retire `ContainerTray_Close` (fold into the orchestrator) vs keep it as a reduced tray-insert helper.
3. **D3** — `MachiningOut_RecordSplit`: extract-one **replaces** the batch split (recommended, per UJ-03), or both coexist for lines that still do a planned N-way split?
4. **D4** — inventory on-hand read: dedicated `Lot_GetLineInventoryByPart` (recommended) vs grouped projection over the existing WIP-queue read.
5. **D5** — finished-goods KPI derived now (recommended), materialize later only if OEE needs it.

---

## 12. Risks & notes

- **Largest rework is the consumption relocation** (Container → finished-good LOT) — it touches tested Phase 6 (`0028`) procs + the `0028` test suite. Sequence: schema (`FinishedGoodLotId`) → orchestrator → retarget `ConsumptionEvent` → rework/retire `ContainerTray_Close` → update tests.
- **PLC-gated** closure triggers (weight/vision) are commissioning-time; the proc + manual/count paths are testable now via simulated triggers.
- **AIM integration remains the one unbuilt external** — `Container_Complete`'s AIM claim stays stubbed until the AIM phase; RFID is a later phase (Container persists to support it).
- **Views are existing → Designer edits** (view-edit boundary); new inventory popup is file-authorable. `scan.ps1` after NQ/script changes; gateway restart only for brand-new Core NQs needing inherited visibility.
- Keep `OperationType` codes stable (Spec 1) — the machining/assembly views bind to them.
