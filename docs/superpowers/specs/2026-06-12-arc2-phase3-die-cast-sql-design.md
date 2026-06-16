# Arc 2 Phase 3 — Die Cast Operator Station: SQL Foundation — Design

**Date:** 2026-06-12
**Status:** Draft for review
**Scope:** The **SQL foundation** for the Die Cast workflow — migration `0022` seeds, three net-new stored procs, and the `0022_PlantFloor_DieCast` test suite. The Perspective Die Cast LOT Entry view, its embedded components, and the optional `DieCastCycleReader` gateway script are a **separate front-end spec** (deferred follow-on), consistent with the Phase 1/2 SQL-first pattern.

## 1. Source of truth

- Phased plan: `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` § "Phase 3 — Die Cast Operator Station" (the authoritative narrative + API table).
- Task list: `MPP_MES_TASK_LIST_PLANT_FLOOR.csv` T073–T081, T086 (the SQL subset; T082–T085 are the deferred UI/gateway tasks).

## 2. Reconciliation to shipped SQL

- **All tables already exist** (built in `0020`, Phase 1): `Workorder.ProductionEvent`, `Workorder.ProductionEventValue`, `Workorder.RejectEvent`. **Phase 3 adds no tables.** Confirmed shapes:
  - `ProductionEvent(Id, LotId, OperationTemplateId, WorkOrderOperationId NULL, EventAt, ShotCount NULL, ScrapCount NULL, ScrapSourceId NULL, WeightValue NULL, WeightUomId NULL, AppUserId, TerminalLocationId NULL, Remarks NULL)`; PK NONCLUSTERED `(Id)`; clustered `(LotId, EventAt)` partition-aligned.
  - `ProductionEventValue(Id, ProductionEventId →CASCADE, DataCollectionFieldId, Value NVARCHAR(255), NumericValue NULL, UomId NULL, CreatedAt)`; `UNIQUE(ProductionEventId, DataCollectionFieldId)`.
  - `RejectEvent(Id, ProductionEventId NULL, LotId, DefectCodeId, Quantity, ChargeToArea NULL, Remarks NULL, AppUserId, RecordedAt)`; PK `(Id, RecordedAt)` partitioned. **No `TerminalLocationId` column.**
- **`Tools.ToolAssignment_ListActiveByCell` already shipped** — verify its result shape feeds the LOT-entry Tool auto-populate; do not recreate. Only `Tools.ToolCavity_ListActiveByTool` is the net-new read proc.
- Next migration number is **`0022`** (disk has through `0021`).

## 3. Migration `0022_arc2_phase3_die_cast.sql` — seeds only

Versioned migration, `SchemaVersion` row + idempotent guards, **no tables, no ALTERs**. ASCII-only Name/Description.

1. **`Parts.OperationTemplate` `DieCastShot`** — seed Draft → Published (three-state versioned entity; `VersionNumber=1`, `PublishedAt` set). One template.
2. **`OperationTemplateField` children for `DieCastShot`** — the data-collection fields per the plan: `DieInfo`, `CavityInfo`, `Weight`, `Good`, `Bad`, `ShotCount` (code-table-backed field types via `Parts.DataCollectionField`; ordered). **No** `DieIdentifier` / `CavityNumber` / `WarmupShotCount` fields — Tool/Cavity live on `Lot` (B13), warm-up lives on `DowntimeEvent` (UJ-14).
3. **`Audit.LogEventType`** — `DieCastCheckpointRecorded`, `RejectEventRecorded` (idempotent `IF NOT EXISTS` / `MERGE`; skip if already seeded).

(`Lot` LogEntityType + `LotCreated` event already seeded in Phase 1/2; `ProductionEvent` / `RejectEvent` LogEntityType rows: confirm they exist from `0020`/`0021`, add here if absent.)

## 4. Stored procedures (net-new)

All follow FDS-11-011 (single result set; `@Status`/`@Message`/`@NewId` locals; no OUTPUT params), three-tier `RAISERROR` error handling, schema-qualified refs, audit via the established routing (`Audit.Audit_LogOperation` for Workorder entities → `OperationLog`).

### 4.1 `Workorder.ProductionEvent_Record`

```
@LotId BIGINT, @OperationTemplateId BIGINT, @WorkOrderOperationId BIGINT = NULL,
@EventAt DATETIME2(3) = NULL,  -- defaults SYSUTCDATETIME()
@ShotCount INT = NULL, @ScrapCount INT = NULL,
@WeightValue DECIMAL(12,4) = NULL, @WeightUomId BIGINT = NULL,
@DataCollectionValuesJson NVARCHAR(MAX) = NULL,
@AppUserId BIGINT, @TerminalLocationId BIGINT = NULL, @Remarks NVARCHAR(500) = NULL
→ Status, Message, NewId
```

- **Pre-validate before any write** (per the INSERT-EXEC/Msg-3915 rule — all rejecting validations before `BEGIN TRANSACTION`): `@LotId`/`@OperationTemplateId`/`@AppUserId` present; LOT exists; `Lots.Lot_AssertNotBlocked(@LotId)` clears (a held LOT rejects with its block message); `@ShotCount`/`@ScrapCount`/`@Quantity`-style non-negative.
- Insert one `ProductionEvent` row (cumulative `ShotCount`/`ScrapCount` as supplied — see Decision D1).
- If `@DataCollectionValuesJson` non-null, shred it (`OPENJSON`) into `ProductionEventValue` rows keyed by `DataCollectionFieldId` (upsert-by-unique).
- **B5 materialized columns** — see Decision D2.
- Audit `DieCastCheckpointRecorded` (Workorder entity → `OperationLog`), `Description = 'Recorded die-cast checkpoint for LOT <LotName> (shots <ShotCount>, scrap <ScrapCount>)'`, resolved-FK Old/New JSON per the audit-readability convention.
- Returns `@NewId` = the `ProductionEvent.Id`.

### 4.2 `Workorder.RejectEvent_Record`

```
@LotId BIGINT, @DefectCodeId BIGINT, @Quantity INT, @ChargeToArea NVARCHAR(100) = NULL,
@ProductionEventId BIGINT = NULL, @Remarks NVARCHAR(500) = NULL,
@AppUserId BIGINT, @TerminalLocationId BIGINT = NULL
→ Status, Message, NewId
```

- Independent of `ProductionEvent` (rejects can fire any time; `@ProductionEventId` optional link).
- **Validate (all before `BEGIN TRANSACTION`):** `@LotId`/`@DefectCodeId`/`@AppUserId` present; LOT exists; `DefectCode` exists; `@Quantity > 0`; **`@Quantity <= Lot.PieceCount`** (cannot scrap more pieces than the LOT holds — reject with a clear message).
- **One action — log the defect AND decrement the LOT (Decision D3):** inside the transaction, with `UPDLOCK`/`HOLDLOCK` on the `Lot` row (the same serialization `Lot_Split`/`Lot_Merge` use, since all three mutate `PieceCount`):
  1. Insert one `RejectEvent` row (`@TerminalLocationId` is **audit-only** — there is no such column on `RejectEvent`; it goes to the audit row, not the table).
  2. `Lot.PieceCount -= @Quantity` and `Lot.InventoryAvailable -= @Quantity` (B5 kept consistent; guard `>= 0`).
  3. **Close-at-zero:** if `PieceCount` reaches 0, set `LotStatusCode = Closed` and write a `LotStatusHistory` row — **inlined**, not via `EXEC Lots.Lot_UpdateStatus` (this proc returns a status row and is captured by `INSERT-EXEC` in tests, so it must not `EXEC` a sibling status-row proc — mirror the inline-sub-mutation pattern in `R__Lots_Lot_Split.sql`). No genealogy/closure edge — scrap creates no child LOT.
- Audit `RejectEventRecorded` (resolved defect-code + the new piece count in the prose).

### 4.3 `Tools.ToolCavity_ListActiveByTool`

```
@ToolId BIGINT  →  rowset: (Id, CavityNumber, StatusCode, ItemId?, ...)  (READ proc, no status row; empty = none)
```

- Returns `Active` cavities for the mounted Tool, feeding the LOT-entry cavity dropdown. Mirror `ToolAssignment_ListActiveByCell`'s read-proc style. Confirm whether the Item produced per cavity is carried here or derived from the Tool config (the plan says `@ItemId` is "looked up from the Tool's configuration") — include the producing `ItemId` in the result if the Tools schema models it per-cavity; otherwise the view resolves Item from the Tool.

## 5. Design decisions (confirm at review)

- **D1 — ShotCount semantics (A4): cumulative.** `ProductionEvent.ShotCount`/`ScrapCount` store the **cumulative** cavity counter at checkpoint time (the shipped default). Per-interval deltas are a **read/report-time** concern via `LAG(ShotCount) OVER (PARTITION BY LotId ORDER BY EventAt)`; the proc does not compute deltas. Reframe to derived-from-aggregated-quantities only if MPP elects it post-Phase-3.
- **D2 — B5 materialized columns at die cast: checkpoints do NOT change piece availability.** A die-cast `ProductionEvent` is a cumulative production *metric* (shots/scrap), not a piece *movement*. A freshly-created die-cast LOT has `InventoryAvailable = PieceCount`, `TotalInProcess = 0` (set by `Lot_Create`); recording shot checkpoints leaves both **unchanged**. The B5 columns are driven by movement/consumption events (Phases 4–6), not die-cast checkpoints. **Recommendation:** `ProductionEvent_Record` does not touch `Lot.TotalInProcess`/`InventoryAvailable` at die cast. (This refines the phased plan's generic "if B5, update" line — the precise OEE-grade recompute the Phase 2 notes deferred "to the Phase 3 event writers" applies to downstream piece-flow events, not die-cast shot metrics.)
- **D3 — RejectEvent DOES decrement the LOT (confirmed with Jacques 2026-06-12).** Two distinct scrap concepts:
  - **Die-cast production scrap** — shots that fail *during the run, before the basket is issued as a LOT*. Captured as the cumulative `ProductionEvent.ScrapCount` metric. Pre-LOT → does **not** decrement (the operator enters `PieceCount` = good parts). This half of the original D3 stands.
  - **A RejectEvent** — a part of an *already-existing* LOT is found failed/damaged, at **any** step (die cast post-issue, trim, machining, assembly). This is **one action** that logs the defect *and* scraps the part off the LOT: `RejectEvent_Record` decrements `Lot.PieceCount` + `InventoryAvailable` by `@Quantity`, and closes the LOT (status `Closed` + `LotStatusHistory`) when the count hits zero. Reject and inventory-reduction are the same operation — there is no separate "Scrap" proc. `RejectEvent_Record` is built in Phase 3 but reused at every downstream step, so this decrement behavior is the general contract, not die-cast-specific.

These three are the genuine design calls (all now settled); everything else follows the phased plan verbatim.

## 6. Conventions

- ASCII-only seed strings (byte-scan before applying). `OperationTemplate` seeded via the three-state Draft→Published pattern.
- Mutations are status-row procs → their NQs (front-end spec) need `attributes.type:"Query"`.
- Append-only event tables; no soft-delete. Validations before `BEGIN TRANSACTION`; `CATCH` is the only `ROLLBACK` site (INSERT-EXEC/Msg-3915 rule).
- Audit Description follows the `SUBJECT · CATEGORY · ACTION` readability convention with resolved-FK JSON.

## 7. Test coverage — `sql/tests/0022_PlantFloor_DieCast/`

| File | Covers |
|---|---|
| `010_ProductionEvent_Record.sql` | Checkpoint insert; `ProductionEventValue` shred from JSON; cumulative `ShotCount` stored as-supplied; `LAG`-delta = cumulative diff across two checkpoints; missing required params reject; blocked-LOT rejects (`Lot_AssertNotBlocked`); **D2** — `Lot.InventoryAvailable`/`TotalInProcess` unchanged by a checkpoint. |
| `020_RejectEvent_Record.sql` | Insert; `DefectCode` FK validation; `@Quantity > 0` enforced; `@Quantity > Lot.PieceCount` rejects; optional `@ProductionEventId` link; **D3 decrement** — `Lot.PieceCount` + `InventoryAvailable` drop by `@Quantity`; **close-at-zero** — a reject that zeroes the count sets `LotStatusCode=Closed` + writes `LotStatusHistory`; the die-cast `ProductionEvent.ScrapCount` metric (test 010) does NOT decrement. |
| `030_DieCast_walkthrough.sql` | End-to-end: `ToolAssignment_ListActiveByCell` on a selected Cell → `Lot_Create` with Tool/Cavity → first `ProductionEvent` → second at later `EventAt` → LAG delta correct. |
| `040_CavityParallel_peers.sql` | Two LOTs, same Tool, different Cavities, **no** parent/child genealogy FK; each closes independently. |

Target 50–70 assertions. INSERT-EXEC into temp tables; FK-safe teardown (closure → genealogy → ProductionEventValue → ProductionEvent/RejectEvent → child LOT tables → Lot). Suite stays green alongside the existing 1449.

## 8. Phase 3 SQL complete when

- Migration `0022` applied; `DieCastShot` OperationTemplate + fields + LogEventType seeds in place.
- `ProductionEvent_Record`, `RejectEvent_Record`, `ToolCavity_ListActiveByTool` delivered (checkpoint shape — no `GoodCount`/`NoGoodCount` params); `ToolAssignment_ListActiveByCell` confirmed reusable.
- `0022_PlantFloor_DieCast` suite passes (target 50–70); full suite green.

## 9. Out of scope (→ front-end spec)

Die Cast LOT Entry view + Reject/Checkpoint embedded components; the `DieCastCycleReader` gateway script (PLC/TOPServer — Phase 6 territory; operator-override path covers it); Named Queries wrapping these procs (built with the front-end work). Downtime entry (Phase 8). Warm-up shots (`DowntimeEvent`, Phase 8).
