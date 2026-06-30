# Phase 5 — Machining SQL Layer (+ Phase 4 SQL tail) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the Phase 5 Machining SQL layer — the FIFO-pick + BOM-driven rename (`MachiningIn_PickAndConsume`), PLC auto-complete (`MachiningOut_AutoComplete`), and operator sub-LOT split (`MachiningOut_RecordSplit`) — plus the two CLI-doable Phase 4 SQL-tail items, all green under the test suite.

**Architecture:** One versioned migration (`0027`) for the `RequiresSubLotSplit` ALTER + seeds; three repeatable mutation procs following FDS-11-011 + the orchestrating-proc INLINE rule; a TDD test suite `0027_PlantFloor_Machining`. Reads/consumers (`Lot_GetWipQueueByLocation`) already exist from Phase 4.

**Tech Stack:** SQL Server 2022, `sqlcmd`, the project test framework (`test.Assert_*`), Ignition Named Queries + Jython entity scripts (Core project).

---

## Conventions every task follows (read once)

- **Proc template:** `sql/scripts/_TEMPLATE_stored_procedure.sql`. Three-tier error hierarchy; `RAISERROR` (not `THROW`) in CATCH with nested TRY/CATCH failure logging; schema-qualify everything; `EXEC` args are literals/`@vars` only.
- **FDS-11-011 (no OUTPUT params):** `@Status`/`@Message`/`@NewId` are LOCAL variables; every exit path ends with `SELECT @Status AS Status, @Message AS Message [, @NewId AS NewId];` (one result set per proc). Read procs: empty result set = not found.
- **Orchestrating procs INLINE their sub-mutations** (do NOT `EXEC Lot_Create`/`Lot_Split`/`Lot_MoveTo`/`Lot_UpdateStatus` from a proc that itself returns a status row and is captured via `INSERT-EXEC`). All rejecting validations run BEFORE `BEGIN TRANSACTION` (each rejection SELECTs the status row + `RETURN`); the only legal `ROLLBACK` is in the CATCH on a doomed `XACT_ABORT` exception (a `ROLLBACK` inside an `INSERT-EXEC`-captured proc throws Msg 3915). **Reference impls: `R__Lots_Lot_Split.sql` and `R__Lots_Lot_Merge.sql`** — their headers document this rationale; mirror their structure exactly.
- **Audit:** call `Audit.Audit_LogOperation` INSIDE the transaction (it emits no result set). Description shape `<SUBJECT> · <CATEGORY?> · <ACTION>` via `Audit.ufn_MidDot()`; `OldValue`/`NewValue` JSON carry resolved-name FK sub-objects; wrap with `Audit.ufn_TruncateActivity()`.
- **Timestamps:** persist `SYSUTCDATETIME()`; any operator-facing read converts `CAST(<col> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))` (raw `datetimeoffset` breaks the JDBC read).
- **Test framework:** `test.Assert_IsEqual`, `test.Assert_IsTrue`, `test.Assert_IsNotNull`, `test.Assert_RowCount`. Capture a status-row proc via `INSERT #t (...) EXEC <proc> ...;` then assert against `#t`. Mirror an existing suite file (e.g. `sql/tests/0026_PlantFloor_Downtime_Shift/010_DowntimeEvent_lifecycle.sql`).
- **Guarded reset/test (CRITICAL):** the Ignition gateway holds a single-user-mode connection pool to `MPP_MES_Dev`. Before any reset/test run: `sqlcmd -S localhost -d master -E -C -b -Q "ALTER LOGIN ignition DISABLE;"`, run `.\sql\tests\Run-Tests.ps1`, then `ALTER LOGIN ignition ENABLE;` (wrap in try/finally). Filtered-index DELETEs need `sqlcmd -I`.
- **Audit-Id allocation (prevents the Phase-3 collision):** before seeding any `Audit.LogEventType`/`LogEntityType` rows, run `SELECT MAX(Id) FROM Audit.LogEventType;` (currently 41 after Phase 8) and `SELECT MAX(Id) FROM Audit.LogEntityType;` (currently 47). Assign the NEXT free ids sequentially. Do NOT hardcode ids from the stale Phased Plan.

## File structure

| File | Responsibility |
|---|---|
| `sql/scratch/smoke_seed_phase4.sql` | Dev seed: a LOT created → moved through Trim → at a Machining-line FIFO queue, so the P4 views show data. |
| `sql/migrations/repeatable/R__Location_Location_ListMachiningDestinations.sql` | Read proc: Cell-tier Machining-line destinations for the Trim OUT dropdown (excludes terminal/printer cells). |
| `sql/migrations/versioned/0027_arc2_phase5_machining.sql` | `RequiresSubLotSplit BIT` ALTER on `Parts.OperationTemplate`; `MachiningIn`/`MachiningOut` OperationTemplate seeds; `Audit.LogEventType` seeds (next free ids). |
| `sql/migrations/repeatable/R__Workorder_MachiningIn_PickAndConsume.sql` | Composite IN proc (mint machined LOT + consume source + genealogy + checkpoint). |
| `sql/migrations/repeatable/R__Workorder_MachiningOut_AutoComplete.sql` | PLC OUT proc (checkpoint + coupled auto-move). |
| `sql/migrations/repeatable/R__Workorder_MachiningOut_RecordSplit.sql` | Operator OUT split proc (N sub-LOTs to N destinations). |
| `sql/tests/0027_PlantFloor_Machining/0*.sql` | Test suite (010–090). |
| `ignition/projects/Core/ignition/named-query/workorder/MachiningIn_PickAndConsume/{query.sql,resource.json}` (+ siblings) | NQ wrappers (thin `EXEC`). |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Machining/code.py` | Entity script (start/out/split wrappers via `Common.Db.execMutation`). |

---

## Task 1: Phase 4 tail — smoke seed

**Files:** Create `sql/scratch/smoke_seed_phase4.sql`

- [ ] **Step 1: Inspect the plant hierarchy + Trim/Machining location codes.** Read `sql/seeds/011_seed_locations_mpp_plant.sql` to find: a Die Cast Cell, the Trim Shop Area, and at least one Machining-line Cell. Note their `Code`s.
- [ ] **Step 2: Write the seed** (mirror `sql/scratch/smoke_seed_phase8.sql` structure — `SET NOCOUNT ON`, resolve ids by `Code`, use `INSERT … EXEC` to capture status rows). It should: `Lot_Create` a die-cast LOT at a Die Cast Cell; `Lot_MoveTo` it to the Trim Shop Area; write a `TrimIn` checkpoint `ProductionEvent`; `TrimOut_Record` to move it whole to a Machining-line Cell. End with a SELECT reporting the LOT name + its current location + the Machining queue count.
- [ ] **Step 3: Run it** (guarded login not needed — it's additive, no reset): `sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/scratch/smoke_seed_phase4.sql`. Expected: status rows all `Status=1`, final SELECT shows the LOT at the Machining Cell.
- [ ] **Step 4: Commit** — `git add sql/scratch/smoke_seed_phase4.sql && git commit -m "chore(arc2-p4): smoke seed for Trim/Receiving/Machining-queue views"`

## Task 2: Phase 4 tail — Machining-destination read proc

**Files:** Create `sql/migrations/repeatable/R__Location_Location_ListMachiningDestinations.sql`; Test `sql/tests/0023_PlantFloor_Movement_Trim/060_ListMachiningDestinations.sql`

- [ ] **Step 1: Determine the filter.** Inspect `011_seed_locations_mpp_plant.sql` + `Location.LocationTypeDefinition` to identify how Machining-line Cells are distinguished from terminal/printer cells (likely by `LocationTypeDefinition` code or parent Area). The proc returns Cell-tier (`HierarchyLevel=4`), non-deprecated locations that are valid Trim-OUT destinations (Machining lines), ordered by `Code`.
- [ ] **Step 2: Write the failing test** `060_ListMachiningDestinations.sql`: capture `INSERT #d EXEC Location.Location_ListMachiningDestinations;`; assert `test.Assert_IsTrue` that row count ≥ 1, that every returned row is a Cell-tier Machining destination, and that a known terminal/printer cell is NOT present.
- [ ] **Step 3: Run red** (guarded): proc doesn't exist → error/empty.
- [ ] **Step 4: Implement the read proc** following the template; `SELECT Id, Code, Name` (+ AreaCode if useful) of the filtered cells. No OUTPUT params; empty set = none.
- [ ] **Step 5: Run green** (guarded full suite or just the file).
- [ ] **Step 6: Add the NQ** `ignition/projects/Core/ignition/named-query/location/Location_ListMachiningDestinations/{query.sql,resource.json}` (thin `EXEC`, mirror an existing list NQ). *(The TrimStation OUT view swap to this NQ is a Designer edit → consolidated Hunter handoff.)*
- [ ] **Step 7: Commit** — `git commit -m "feat(arc2-p4): Machining-line destination read proc + NQ for Trim OUT dropdown"`

## Task 3: Phase 5 migration `0027` (ALTER + seeds)

**Files:** Create `sql/migrations/versioned/0027_arc2_phase5_machining.sql`

- [ ] **Step 1: Check audit-Id high-water marks** (guarded): `SELECT MAX(Id) FROM Audit.LogEventType;` and `SELECT MAX(Id) FROM Audit.LogEntityType;`. Record the next-free LogEventType id (expected 42).
- [ ] **Step 2: Write the migration**, idempotent + GO-separated + ends with the standard `INSERT INTO dbo.SchemaVersion` footer (copy the footer from `0026_arc2_phase8_downtime_shift.sql`):
  - `IF COL_LENGTH('Parts.OperationTemplate','RequiresSubLotSplit') IS NULL ALTER TABLE Parts.OperationTemplate ADD RequiresSubLotSplit BIT NOT NULL CONSTRAINT DF_OperationTemplate_RequiresSubLotSplit DEFAULT 0;`
  - Seed `MachiningIn` + `MachiningOut` `Parts.OperationTemplate` rows (versioned, follow the existing `DieCastShot` seed pattern in `sql/seeds/022_*`; `MachiningOut` rows that sublot carry `RequiresSubLotSplit=1`, rest default 0). Inspect the existing OperationTemplate seed to match columns exactly.
  - Seed `Audit.LogEventType` rows at the next-free ids: `MachiningInPicked`, `MachiningOutCompleted`, `MachiningOutAutoMoved`, `MachiningOutSubLotSplit` (guard each with `IF NOT EXISTS … WHERE Code=`).
- [ ] **Step 3: Apply via guarded reset** (`Reset-DevDatabase.ps1` with `ignition` login disabled). Expected: `27 migration(s) applied`, no errors.
- [ ] **Step 4: Commit** — `git commit -m "feat(arc2-p5-sql): migration 0027 - RequiresSubLotSplit ALTER + Machining OperationTemplate + LogEventType seeds"`

## Task 4: `MachiningIn_PickAndConsume`

**Files:** Create `sql/migrations/repeatable/R__Workorder_MachiningIn_PickAndConsume.sql`; Test `sql/tests/0027_PlantFloor_Machining/010_MachiningIn_PickAndConsume_happy.sql`, `020_MachiningIn_eligibility.sql`, `030_MachiningIn_BOM_lookup_edge_cases.sql`

**Signature:** `@SourceLotId BIGINT, @CellLocationId BIGINT, @QueueOverrideReason NVARCHAR(500)=NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT=NULL` → `SELECT @Status, @Message, @NewMachinedLotId AS NewId, @NewMachinedLotName, @ConsumptionEventId, @ProductionEventId`.

**Operation sequence (mirror `R__Lots_Lot_Split.sql` — INLINE all sub-mutations):**
1. Validations BEFORE `BEGIN TRANSACTION` (each: SELECT status row + RETURN): source LOT exists + open; `Lot_AssertNotBlocked(@SourceLotId)` (inline the check, don't EXEC); resolve the machined Item via the active `Parts.Bom` whose single `BomLine.ChildItemId` = source LOT's Item at `QtyPer=1` — reject if no BOM (`'No active BOM renames {SourceItem} at this cell.'`) or multiple matching BOMs (`'Ambiguous BOM rename for {SourceItem}.'`); eligibility of the machined Item at `@CellLocationId` via `v_EffectiveItemLocation` (reject FDS-02-012 message).
2. `BEGIN TRY / BEGIN TRANSACTION`.
3. INLINE-mint the machined LOT (mirror what `Lot_Create` produces: `Lots.Lot` row with the machined Item + `CurrentLocationId=@CellLocationId` + origin, the `LotStatusHistory 'Good'` row, `LotGenealogyClosure` self-row Depth=0, first `LotMovement` From=NULL). Capture `@NewMachinedLotId`, `@NewMachinedLotName` (via `IdentifierSequence_Next`).
4. Write `Workorder.ConsumptionEvent` (source LOT consumed, full piece count) → `@ConsumptionEventId`.
5. Write `Lots.LotGenealogy` (+ closure) linking source → machined (INLINE the closure maintenance as `LotGenealogy_RecordConsumption` does).
6. Write checkpoint `Workorder.ProductionEvent` (`OperationTemplateId=MachiningIn`, cumulative counters, `EventAt=SYSUTCDATETIME()`) → `@ProductionEventId`; if `@QueueOverrideReason` not null, write it as a `ProductionEventValue`.
7. Close the source LOT (INLINE the status transition to a closed/consumed status).
8. `Audit.Audit_LogOperation` (`MachiningInPicked`, resolved-FK JSON for source+machined LOT).
9. `COMMIT`; set `@Status=1`. CATCH: `IF XACT_STATE()<>0 ROLLBACK`, log failure, `RAISERROR`.

- [ ] **Step 1: Write `010` failing test** — seed a whole cast/trim LOT in a Machining Cell's queue (use the smoke-seed approach) + an active BOM (machined Item ← source Item). Capture the proc. Assert: `Status=1`; `NewId` (machined LOT) not null; machined LOT carries the machined Item; `ConsumptionEvent` row exists for the source; `LotGenealogy` edge source→machined exists; checkpoint `ProductionEvent` written; source LOT now closed.
- [ ] **Step 2: Run red** (guarded) — proc missing.
- [ ] **Step 3: Implement** the proc per the sequence above.
- [ ] **Step 4: Run `010` green** (guarded).
- [ ] **Step 5: Write `020` (eligibility) + `030` (BOM edge cases)** — `020`: BomDerived eligibility resolves through the machined Item's BOM; ineligible source rejects with FDS-02-012 message. `030`: missing BOM rejects; multiple matching BOMs reject with the ambiguity message; deprecated BOM not used.
- [ ] **Step 6: Run `020`/`030` green** (guarded).
- [ ] **Step 7: Commit** — `git commit -m "feat(arc2-p5-sql): MachiningIn_PickAndConsume + tests (010/020/030)"`

## Task 5: `MachiningOut_AutoComplete`

**Files:** Create `sql/migrations/repeatable/R__Workorder_MachiningOut_AutoComplete.sql`; Test `040_MachiningOut_AutoComplete_coupled.sql`, `050_MachiningOut_AutoComplete_uncoupled.sql`, `060_MachiningOut_blocked_lot.sql`

**Signature:** `@LotId BIGINT, @CellLocationId BIGINT, @AppUserId BIGINT, @TerminalLocationId BIGINT=NULL` → `SELECT @Status, @Message, @ProductionEventId, @AutoMoved AS AutoMoved, @ToLocationId AS ToLocationId`.

**Operation sequence:**
1. Validations before txn: LOT exists + at `@CellLocationId`; inline `Lot_AssertNotBlocked` (reject if blocked).
2. TRY/TRANSACTION: write `MachiningOut` checkpoint `ProductionEvent` → `@ProductionEventId`.
3. Read `CoupledDownstreamCellLocationId` from `Location.Location` for `@CellLocationId` (it's the column added by migration `0019`). If non-NULL: INLINE-move the LOT (`LotMovement` row + update `Lot.CurrentLocationId`) to that cell; `@AutoMoved=1`, `@ToLocationId=<coupled>`; audit `MachiningOutAutoMoved`. If NULL: `@AutoMoved=0`, `@ToLocationId=NULL`; audit `MachiningOutCompleted`.
4. COMMIT; `@Status=1`. CATCH as standard.

- [ ] **Step 1: Write `040` (coupled) failing test** — Machining Cell with `CoupledDownstreamCellLocationId` set; machined LOT present. Assert `Status=1`, `ProductionEvent` written, `LotMovement` to the coupled cell, `AutoMoved=1`, `Lot.CurrentLocationId` = coupled cell.
- [ ] **Step 2: Run red** (guarded).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `040` green.**
- [ ] **Step 5: Write `050` (uncoupled: `CoupledDownstreamCellLocationId` NULL → ProductionEvent only, no LotMovement, `AutoMoved=0`) + `060` (held LOT rejects via the not-blocked check).**
- [ ] **Step 6: Run `050`/`060` green.**
- [ ] **Step 7: Commit** — `git commit -m "feat(arc2-p5-sql): MachiningOut_AutoComplete + tests (040/050/060)"`

## Task 6: `MachiningOut_RecordSplit`

**Files:** Create `sql/migrations/repeatable/R__Workorder_MachiningOut_RecordSplit.sql`; Test `070_MachiningOut_RecordSplit.sql`, `075_MachiningOut_RecordSplit_same_destination.sql`, `080_MachiningOut_RecordSplit_validation.sql`

**Signature:** `@ParentLotId BIGINT, @OperationTemplateId BIGINT, @SplitChildrenJson NVARCHAR(MAX), @AppUserId BIGINT, @TerminalLocationId BIGINT=NULL` where JSON = `[{"pieceCount":N,"destinationLocationId":L}, ...]` → multi-row: header `SELECT @Status, @Message, @ProductionEventId` then per-child `SELECT ChildLotId, ChildLotName, DestinationLocationId` (build into a table var, SELECT at the end — single logical result set; see how `Lot_Split` returns its child rows).

**Operation sequence (mirror `R__Lots_Lot_Split.sql` exactly — it is the canonical N-child split):**
1. Validations before txn: parent exists + open; inline `Lot_AssertNotBlocked`; `OPENJSON` parse the children; reject if 0 children, if any `pieceCount<=0`, if any destination invalid, or if `SUM(pieceCount) <> parent.PieceCount` (`'Split children ({sum}) must equal parent piece count ({parent}).'`).
2. TRY/TRANSACTION: write the closing `MachiningOut` `ProductionEvent` → `@ProductionEventId`.
3. For each child (cursor or set-based over the parsed JSON): INLINE-create the child LOT (machined Item inherited, piece count from JSON), write `LotGenealogy` Split edge + closure rows, INLINE-move the child to its `destinationLocationId`. Mirror `Lot_Split`'s inlined child creation precisely.
4. Close the parent LOT (INLINE).
5. `Audit.Audit_LogOperation` `MachiningOutSubLotSplit` (resolved-FK JSON: parent + N children).
6. COMMIT; build + SELECT the per-child result rows.

- [ ] **Step 1: Write `070` failing test** — `RequiresSubLotSplit=1` line, 2-way split into two destinations. Assert: `Status=1`; two child LOTs created with the machined Item; `LotGenealogy` Split edges + closure rows present; `LotMovement` per child to its destination; parent closed; each child visible in its destination queue via `Lot_GetWipQueueByLocation`.
- [ ] **Step 2: Run red** (guarded).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `070` green.**
- [ ] **Step 5: Write `075` (N children all to the same destination — legitimate) + `080` (validation: sum≠parent rejects; missing/invalid destination rejects; blocked parent rejects).**
- [ ] **Step 6: Run `075`/`080` green.**
- [ ] **Step 7: Commit** — `git commit -m "feat(arc2-p5-sql): MachiningOut_RecordSplit + tests (070/075/080)"`

## Task 7: Rework-LOT queue test

**Files:** Create `sql/tests/0027_PlantFloor_Machining/090_Rework_LOT_in_queue.sql`

- [ ] **Step 1: Write the test** — a rework LOT whose `CurrentLocationId` is a Machining Cell appears in that Cell's FIFO queue (`Lot_GetWipQueueByLocation`) and flows through `MachiningIn_PickAndConsume` with no special handling (consumes the rework LOT, produces a new machined LOT under the same Item). Assert the pick succeeds + genealogy edge written. (No new proc — exercises existing procs.)
- [ ] **Step 2: Run green** (guarded full suite — target 80–110 assertions across `0027`).
- [ ] **Step 3: Commit** — `git commit -m "test(arc2-p5-sql): rework-LOT-in-queue (090)"`

## Task 8: Named Queries + entity script

**Files:** Create NQ folders under `ignition/projects/Core/ignition/named-query/workorder/` for `MachiningIn_PickAndConsume`, `MachiningOut_AutoComplete`, `MachiningOut_RecordSplit` (each `{query.sql,resource.json}`); Create `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Machining/code.py` + `resource.json`.

- [ ] **Step 1: Write the three NQs** — thin `EXEC Workorder.<Proc> @p = :p, ...` mirroring an existing mutation NQ (e.g. `workorder/TrimOut_Record/query.sql`). Match `sqlType` codes to param types. **No UTF-8 BOM** (use `[System.IO.File]::WriteAllBytes` or PS7 `-Encoding utf8NoBOM`).
- [ ] **Step 2: Write the entity script** `BlueRidge.Workorder.Machining` — `pickAndConsume(...)`, `autoComplete(...)`, `recordSplit(...)` wrappers routing through `BlueRidge.Common.Db.execMutation`; `appUserId` defaults to `Common.Util._currentAppUserId()` when None; entry log via `Common.Util.log(...)` at default INFO for the mutations (NOT debug — these are meaningful events). Mirror `BlueRidge.Oee.DowntimeEvent`.
- [ ] **Step 3: Validate** the NQ `query.sql` files have no BOM (`scan.ps1`), JSON parses on `resource.json` + `code.py` compiles (`python -c "import py_compile..."`).
- [ ] **Step 4: Commit** — `git commit -m "feat(arc2-p5-ignition): Machining NQs + entity script (Core)"`

---

## Self-Review

**Spec coverage** (against Phased Plan Phase 5 "complete when"): migration `0027` + `RequiresSubLotSplit` ALTER + seeds → Task 3 ✓; `MachiningIn_PickAndConsume` → Task 4 ✓; `MachiningOut_AutoComplete` → Task 5 ✓; `MachiningOut_RecordSplit` → Task 6 ✓; suite `0027` 80–110 → Tasks 4–7 ✓. Views + `MachiningOpCompleteWatcher` gateway script are a SEPARATE just-in-time plan (deferred per the roadmap — not in this SQL unit). Phase 4 tail (smoke seed + destination proc) → Tasks 1–2 ✓.

**Placeholder scan:** none — each proc task gives signature + numbered op-sequence + validations + reference impl; each test task lists concrete assertions. Two deliberate inspection points (Task 1 Step 1 location codes; Task 2 Step 1 destination filter; Task 3 Step 1 audit-Id high-water) are codebase-lookups, not placeholders.

**Type consistency:** proc names + signatures match the Phased Plan API table and the file map. Output shapes follow FDS-11-011 single-result-set rule. `RequiresSubLotSplit` spelled consistently.

**Numbering:** migration `0027`, suite `0027_PlantFloor_Machining`, audit ids allocated at runtime from `MAX(Id)` (not the stale plan's numbers) — per the collision-prevention convention.
