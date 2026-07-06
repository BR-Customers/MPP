# Machining & Assembly Plant-Floor Flow — Implementation Plan (Spec 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reconcile the already-built Phase 5/6 machining/assembly flow to the customer discovery — machining-out becomes extract-one (parent stays open); assembly-out mints a finished-good LOT (`tray = LOT`) consuming `BOM × PieceCount` FIFO while retaining the Container as wrapper; plus a reusable line inventory check-in popup and a finished-goods KPI read.

**Architecture:** Targeted deltas onto built code. Machining: change `MachiningOut_RecordSplit` split semantics + a source-pick UI. Assembly: add `ContainerTray.FinishedGoodLotId`, add one inlined orchestrator `Assembly_CompleteTray` (mint LOT + consume BOM FIFO + manage container), migrate the assembly views + tests off `ContainerTray_Close`, retire that proc's consumption. Add an inventory read + popup and a KPI read. Every orchestrating proc **inlines** its sub-mutations (per the INSERT-EXEC rule) — it does not `EXEC` status-row procs.

**Tech Stack:** SQL Server 2022 (versioned + `R__` repeatable migrations, file-based SQL test suite via `Reset-DevDatabase` + `Run-Tests`), Ignition 8.3 (Core NQs + Jython entity scripts + Perspective views). Governed by `sql_best_practices_mes.md`, `sql_version_control_guide.md`.

## Global Constraints

- **Branch:** `jacques/working`. Confirm `git branch --show-current` before committing. Explicit path staging only. Omit the `Co-Authored-By: Claude` trailer.
- **Depends on Spec 1** (`2026-07-02-operation-type-model-restructure.md`) for the `OperationType` role. Task M3 (operation resolution) requires Spec 1's `OperationType` table + `getOperationTypesForDropdown`/`getActiveTemplateIdByRole` to exist. Land Spec 1 first, or sequence M3 after Spec 1 merges.
- **Assumed decisions (Spec 2 §11 recommendations):** D1 — one `Assembly_CompleteTray` orchestrator. D2 — retire `ContainerTray_Close` (fold tray-insert into the orchestrator). D3 — extract-one **replaces** the batch split. D4 — dedicated `Lot_GetLineInventoryByPart` read. D5 — finished-goods KPI is a **derived** read (no materialized column). If any changes, the affected task(s) change.
- **SQL conventions:** `UpperCamelCase`; `BIGINT IDENTITY` PK; `NVARCHAR`; `DATETIME2(3)`; UTC via `GETUTCDATETIME()`; code-table-backed FKs; append-only events; `DeprecatedAt` soft deletes.
- **INSERT-EXEC rule (CLAUDE.md):** an orchestrating proc captured via `INSERT ... EXEC` must NOT `EXEC` another status-row proc and must NOT `ROLLBACK` inside an open caller transaction. **Inline** each sub-mutation (mint / consume / container ops), commenting each block as a mirror of its source-of-truth proc; run **all rejecting validations before `BEGIN TRANSACTION`**; the CATCH is the only legal `ROLLBACK` site. Reference impls: `R__Lots_Lot_Split.sql`, `R__Lots_Lot_Merge.sql`.
- **Ignition JDBC (FDS-11-011):** no `OUTPUT` params; status-row procs end each exit path with `SELECT @Status AS Status, @Message AS Message, ...;`. Read procs return one result set. Status-row mutation NQs use `attributes.type: "Query"`.
- **Audit convention:** `<SUBJECT> · <CATEGORY?> · <ACTION>` via `Audit.ufn_MidDot()`/`Audit.ufn_TruncateActivity()`; resolved-FK sub-objects in Old/New JSON.
- **Ignition sync:** `scan.ps1` after any NQ/entity-script/new-view change — **that is always sufficient, including brand-new Core NQs; NEVER a gateway restart for NQs.** New views file-authorable; **existing** views edited in **Designer** (view-edit boundary). New view folders need both `view.json` AND `resource.json`.
- **NQ topology:** all NQs in **Core**; MPP/MPP_Config inherit.
- **Migration numbers:** shown as `0032` (after Spec 1's `0030`/`0031`). Confirm the next free number at build.

---

## Part M — Machining deltas

### Task M1: `MachiningOut_RecordSplit` → extract-one / partial remainder

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_MachiningOut_RecordSplit.sql`
- Modify (tests): `sql/tests/0027_PlantFloor_Machining/070_MachiningOut_RecordSplit.sql`, `075_MachiningOut_RecordSplit_same_destination.sql`, `080_MachiningOut_RecordSplit_validation.sql`

**Interfaces:**
- Produces: `Workorder.MachiningOut_RecordSplit(@ParentLotId, @OperationTemplateId, @SplitChildrenJson, @AppUserId, @TerminalLocationId)` now allows `SUM(children) <= parent.PieceCount`; decrements the parent by the extracted total; closes the parent **only** when its remaining `PieceCount` reaches 0. `-NN` sequencing already computes `MAX(existing suffix)+1` per call, so repeated extractions sequence correctly.

- [ ] **Step 1: Rewrite the tests for extract-one semantics**

In `080_..._validation.sql`, replace the "`SUM(children)` must equal parent" rejection assertion with: over-extraction (`SUM > remaining`) is rejected; `SUM < remaining` is **accepted** and leaves the parent open with the remainder. In `070`/`075`, after a partial extraction assert the parent stays `Good` with `PieceCount = original - extracted`, and a second call mints the next `-NN` sublots; only a final extraction that zeroes the parent closes it.

- [ ] **Step 2: Run to verify fail**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `0027` split tests FAIL (proc still enforces `SUM == parent` + always closes).

- [ ] **Step 3: Update the proc**

In `R__Workorder_MachiningOut_RecordSplit.sql`, mirror `R__Lots_Lot_Split.sql`'s remainder logic:
1. Replace the equality guard with an over-extraction guard (pre-transaction):
```sql
IF (SELECT SUM(pieceCount) FROM OPENJSON(@SplitChildrenJson) WITH (pieceCount INT '$.pieceCount')) >
   (SELECT PieceCount FROM Lots.Lot WHERE Id = @ParentLotId)
BEGIN
    SELECT @Status = 0, @Message = N'Split total exceeds the parent LOT''s remaining piece count.';
    SELECT @Status AS Status, @Message AS Message, CAST(NULL AS BIGINT) AS ProductionEventId,
           CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
           CAST(NULL AS BIGINT) AS DestinationLocationId, CAST(NULL AS INT) AS PieceCount;
    RETURN;
END;
```
2. In the transaction, replace the "set parent PieceCount = 0, close" block with a decrement + conditional close (mirror `Lot_Split` lines that reduce residual + auto-close at 0):
```sql
DECLARE @ExtractedTotal INT = (SELECT SUM(pieceCount) FROM OPENJSON(@SplitChildrenJson) WITH (pieceCount INT '$.pieceCount'));
UPDATE Lots.Lot
SET PieceCount = PieceCount - @ExtractedTotal,
    InventoryAvailable = InventoryAvailable - @ExtractedTotal
WHERE Id = @ParentLotId;

IF (SELECT PieceCount FROM Lots.Lot WHERE Id = @ParentLotId) = 0
BEGIN
    UPDATE Lots.Lot SET LotStatusId = @ClosedStatusId WHERE Id = @ParentLotId;
    INSERT INTO Lots.LotStatusHistory (LotId, FromLotStatusId, ToLotStatusId, ChangedByUserId, ChangedAt)
    VALUES (@ParentLotId, @GoodStatusId, @ClosedStatusId, @AppUserId, GETUTCDATETIME());
END;
```
Keep the existing child-mint loop, `-NN` naming, genealogy Split edges + closure, and the `ProductionEvent` write unchanged.

- [ ] **Step 4: Run to verify pass**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `0027` split tests PASS; full suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_MachiningOut_RecordSplit.sql sql/tests/0027_PlantFloor_Machining/070_MachiningOut_RecordSplit.sql sql/tests/0027_PlantFloor_Machining/075_MachiningOut_RecordSplit_same_destination.sql sql/tests/0027_PlantFloor_Machining/080_MachiningOut_RecordSplit_validation.sql
git commit -m "feat(sql): MachiningOut_RecordSplit extract-one (parent stays open until zero)"
```

---

### Task M2: Machining-out source-pick + extract-one UI

**Files:**
- Modify (Designer): `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/MachiningOutSplit/view.json`

**Interfaces:**
- Consumes: `Lots.Lot.getWipQueueByLocation` (existing) for the FIFO source list; `Workorder.Machining.recordSplit` (M1 signature).

- [ ] **Step 1: Add a FIFO source-pick list**

In Designer, replace the "most-recent machined LOT" auto-selection with a FIFO queue list bound to `getWipQueueByLocation(cellLocationId)` (same pattern as `MachiningIn`), operator taps a source row → stored in `view.custom.selectedSource`.

- [ ] **Step 2: Extract-one entry**

Replace the two-destination full-split form with a single **extract** form: one destination dropdown + one piece-count entry. On confirm, call `recordSplit(selectedSource.Id, operationTemplateId, splitChildrenJson=[{pieceCount, destinationLocationId}], appUserId)`. After success, refresh the queue — the source stays in the list with its reduced count until it zeroes.

- [ ] **Step 3: Designer smoke**

Perspective session: pick a machined LOT with N pieces → extract a sublot of k<N → parent remains at N−k in the queue, child appears at the destination with the next `-NN` name → repeat to exhaustion → parent drops out when it hits 0.
Expected: passes.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/MachiningOutSplit
git commit -m "feat(ignition): MachiningOutSplit FIFO source-pick + extract-one"
```

---

### Task M3: Operation resolution by OperationType (depends on Spec 1)

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/OperationTemplate/code.py`
- Modify: `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/MachiningOutSplit/view.json` (and any view calling `getActiveTemplateIdByCode`)

**Interfaces:**
- Produces: `BlueRidge.Parts.OperationTemplate.getActiveTemplateIdForRoute(itemId, operationTypeCode)` → the active template Id for the scanned part's route step of that role.

- [ ] **Step 1: Add a role-based resolver**

Add `getActiveTemplateIdForRoute(itemId, operationTypeCode)` to the entity script: given the part's active route, return the `OperationTemplate.Id` whose `OperationType.Code = operationTypeCode` (via a new Core NQ `parts/OperationTemplate_GetForRouteRole` joining `RouteTemplate → RouteStep → OperationTemplate → OperationType`). Keep the legacy `getActiveTemplateIdByCode` until callers migrate.

- [ ] **Step 2: Repoint the machining-out view**

In Designer, replace the `getActiveTemplateIdByCode("MachiningOut")` call with `getActiveTemplateIdForRoute(scannedItemId, "MachiningOut")`.

- [ ] **Step 3: Scan + smoke**

Run: `.\scan.ps1` (registers the new Core NQ — no gateway restart). Perspective session: confirm machining-out still resolves the correct template + fields for a scanned part.
Expected: passes.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/parts/OperationTemplate_GetForRouteRole ignition/projects/Core/ignition/script-python/BlueRidge/Parts/OperationTemplate/code.py ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/MachiningOutSplit
git commit -m "feat(ignition): resolve operation template by OperationType role"
```

---

## Part A — Assembly rework (finished-good LOT)

### Task A1: Schema — `ContainerTray.FinishedGoodLotId`

**Files:**
- Create: `sql/migrations/versioned/0032_container_tray_finished_good_lot.sql`
- Create (test): `sql/tests/0028_PlantFloor_Assembly/005_ContainerTray_schema.sql`

**Interfaces:**
- Produces: `Lots.ContainerTray.FinishedGoodLotId BIGINT NULL FK → Lots.Lot(Id)` with `UNIQUE` filtered on non-null (1:1 tray↔LOT). (Nullable in this migration to keep the existing `0028` tests green until they migrate in A3; a later cleanup can tighten to NOT NULL once all trays route through the orchestrator.)

- [ ] **Step 1: Write the failing schema test**

Create `005_ContainerTray_schema.sql`:
```sql
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID(N'Lots.ContainerTray') AND name = N'FinishedGoodLotId')
    RAISERROR('FAIL 005: ContainerTray.FinishedGoodLotId missing', 16, 1);
PRINT 'PASS 005_ContainerTray_schema';
```

- [ ] **Step 2: Run to verify fail**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `005` FAILS.

- [ ] **Step 3: Write the migration**

Create `sql/migrations/versioned/0032_container_tray_finished_good_lot.sql`:
```sql
-- 0032_container_tray_finished_good_lot.sql — tray <-> finished-good LOT 1:1 link.
SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF COL_LENGTH(N'Lots.ContainerTray', N'FinishedGoodLotId') IS NULL
    ALTER TABLE Lots.ContainerTray ADD FinishedGoodLotId BIGINT NULL
        CONSTRAINT FK_ContainerTray_FinishedGoodLot REFERENCES Lots.Lot(Id);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ContainerTray_FinishedGoodLot')
    CREATE UNIQUE INDEX UQ_ContainerTray_FinishedGoodLot
        ON Lots.ContainerTray(FinishedGoodLotId) WHERE FinishedGoodLotId IS NOT NULL;

COMMIT TRANSACTION;
```

- [ ] **Step 4: Run to verify pass**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `005` PASSES; suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0032_container_tray_finished_good_lot.sql sql/tests/0028_PlantFloor_Assembly/005_ContainerTray_schema.sql
git commit -m "feat(sql): ContainerTray.FinishedGoodLotId (tray<->LOT 1:1)"
```

---

### Task A2: `Workorder.Assembly_CompleteTray` orchestrator

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql`
- Create (test): `sql/tests/0028_PlantFloor_Assembly/090_Assembly_CompleteTray.sql`

**Interfaces:**
- Produces: `Workorder.Assembly_CompleteTray(@FinishedGoodItemId BIGINT, @PieceCount INT, @CellLocationId BIGINT, @ClosureMethod NVARCHAR(20), @OverrideAuthorized BIT = 0, @OverrideAppUserId BIGINT = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL)` → `Status, Message, FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerCompleted`. Mints the FG LOT, consumes `BOM × PieceCount` FIFO into it, inserts a `ContainerTray` referencing the LOT, completes the container when full.

- [ ] **Step 1: Write the failing test**

Create `090_Assembly_CompleteTray.sql` — seed a finished-good Item with a 2-line BOM, seed component stock LOTs at the cell (oldest-first, some partial), then `INSERT ... EXEC Workorder.Assembly_CompleteTray`. Assert: a new FG LOT exists with `ItemId = @FinishedGoodItemId`, `PieceCount = @PieceCount`, origin `Manufactured`; each BOM component was decremented FIFO by `QtyPer × PieceCount` (oldest LOT drained first, next LOT partially consumed); a `ConsumptionEvent` row per source with `ProducedLotId = FG LOT`; a `LotGenealogy` Consumption edge + closure to the FG LOT; a `ContainerTray` row with `FinishedGoodLotId = FG LOT`; on the Nth tray that fills the container, `ContainerCompleted = 1` and a `ShippingLabel` row exists. Add an insufficient-stock case → `Status = 0`, no FG LOT minted (rolled back). Follow the assertion style of the sibling `0028` tests.

- [ ] **Step 2: Run to verify fail**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `090` FAILS (`Assembly_CompleteTray` does not exist).

- [ ] **Step 3: Write the orchestrator**

Create `R__Workorder_Assembly_CompleteTray.sql` from `sql/scripts/_TEMPLATE_stored_procedure.sql`, inlining the sub-mutations (mirror the named source procs in comments). Structure:

**A. Pre-transaction validations (all rejections here — no open txn):**
```sql
-- FG Item eligible at the cell (mirror Lot_Create's v_EffectiveItemLocation check)
IF NOT EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation v
               WHERE v.ItemId = @FinishedGoodItemId
                 AND v.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@CellLocationId)))
BEGIN SELECT @Status=0,@Message=N'Finished-good Item is not eligible at this cell.'; GOTO Reply; END;

IF @PieceCount IS NULL OR @PieceCount <= 0
BEGIN SELECT @Status=0,@Message=N'PieceCount must be a positive integer.'; GOTO Reply; END;

-- Active BOM must exist
DECLARE @BomId BIGINT = (SELECT TOP 1 Id FROM Parts.Bom
    WHERE ParentItemId = @FinishedGoodItemId AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL
    ORDER BY VersionNumber DESC);
IF @BomId IS NULL
BEGIN SELECT @Status=0,@Message=N'No active BOM for the finished-good Item.'; GOTO Reply; END;

-- Pre-check FIFO stock sufficiency for every BOM line (advisory; authoritative re-check in txn)
IF EXISTS (
    SELECT 1 FROM Parts.BomLine bl
    OUTER APPLY (
        SELECT ISNULL(SUM(l.InventoryAvailable),0) AS Avail FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.ItemId = bl.ChildItemId AND l.CurrentLocationId = @CellLocationId AND sc.Code <> N'Closed'
    ) s
    WHERE bl.BomId = @BomId AND s.Avail < CAST(bl.QtyPer * @PieceCount AS INT)
)
BEGIN SELECT @Status=0,@Message=N'Insufficient component stock at the line for one or more BOM lines.'; GOTO Reply; END;
```

**B. Transaction — mint, consume, container (mirror Lot_Create / ConsumptionEvent / Container_Open / ContainerTray / Container_Complete inline):**
```sql
BEGIN TRY
BEGIN TRANSACTION;

-- B1. Mint the finished-good LOT (mirror R__Lots_Lot_Create.sql: origin Manufactured, at the cell)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId,
                      TotalInProcess, InventoryAvailable, CreatedByUserId, CreatedAtTerminalId, CreatedAt)
VALUES (/* minted name via IdentifierSequence_Next('Lot') inline */ @MintedName,
        @FinishedGoodItemId, @ManufacturedOriginId, @GoodStatusId, @PieceCount, @CellLocationId,
        0, @PieceCount, @AppUserId, @TerminalLocationId, GETUTCDATETIME());
SET @FinishedGoodLotId = SCOPE_IDENTITY();
-- self-row closure (Depth 0), LotStatusHistory, first-placement LotMovement (From=NULL) — mirror Lot_Create

-- B2. Consume each BOM line FIFO into the FG LOT
DECLARE bomcur CURSOR LOCAL FAST_FORWARD FOR
    SELECT ChildItemId, CAST(QtyPer * @PieceCount AS INT) FROM Parts.BomLine WHERE BomId = @BomId;
OPEN bomcur; FETCH NEXT FROM bomcur INTO @ChildItemId, @NeedRemain;
WHILE @@FETCH_STATUS = 0
BEGIN
    WHILE @NeedRemain > 0
    BEGIN
        SELECT TOP 1 @SrcLotId = l.Id, @SrcAvail = l.InventoryAvailable
        FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.ItemId = @ChildItemId AND l.CurrentLocationId = @CellLocationId
              AND sc.Code <> N'Closed' AND l.InventoryAvailable > 0
        ORDER BY l.CreatedAt, l.Id;               -- FIFO (mirror ContainerTray_Close consumption order)
        IF @SrcLotId IS NULL
        BEGIN RAISERROR(N'Component stock drained mid-consume.',16,1); END;   -- routes to CATCH -> ROLLBACK

        SET @Take = CASE WHEN @SrcAvail <= @NeedRemain THEN @SrcAvail ELSE @NeedRemain END;
        UPDATE Lots.Lot SET PieceCount = PieceCount - @Take, InventoryAvailable = InventoryAvailable - @Take
        WHERE Id = @SrcLotId;
        IF (SELECT PieceCount FROM Lots.Lot WHERE Id = @SrcLotId) = 0
            UPDATE Lots.Lot SET LotStatusId = @ClosedStatusId WHERE Id = @SrcLotId;   -- + LotStatusHistory

        -- ConsumptionEvent (ProducedLotId = FG LOT) — mirror ConsumptionEvent_RecordWithBomCheck insert
        INSERT INTO Workorder.ConsumptionEvent (SourceLotId, ProducedLotId, ConsumedItemId, ProducedItemId,
                                                PieceCount, LocationId, ConsumedByUserId, ConsumedAt)
        VALUES (@SrcLotId, @FinishedGoodLotId, @ChildItemId, @FinishedGoodItemId, @Take, @CellLocationId,
                @AppUserId, GETUTCDATETIME());
        -- LotGenealogy Consumption edge (RelationshipTypeId = Consumption) + closure ancestors -> FG LOT
        INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId, EventAt)
        VALUES (@SrcLotId, @FinishedGoodLotId, @ConsumptionRelId, @Take, @AppUserId, @TerminalLocationId, GETUTCDATETIME());
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
        SELECT c.AncestorLotId, @FinishedGoodLotId, c.Depth + 1
        FROM Lots.LotGenealogyClosure c
        WHERE c.DescendantLotId = @SrcLotId
          AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure x
                          WHERE x.AncestorLotId = c.AncestorLotId AND x.DescendantLotId = @FinishedGoodLotId);

        SET @NeedRemain = @NeedRemain - @Take;
    END;
    FETCH NEXT FROM bomcur INTO @ChildItemId, @NeedRemain;
END;
CLOSE bomcur; DEALLOCATE bomcur;

-- B3. Container management (mirror Container_Open + ContainerTray insert + Container_Complete)
SELECT @ContainerId = Id FROM Lots.Container
WHERE CurrentLocationId = @CellLocationId AND ItemId = @FinishedGoodItemId AND ContainerStatusCodeId = @OpenStatusId;
IF @ContainerId IS NULL
BEGIN
    -- inline Container_Open (resolve ContainerConfig for the Item)
    INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, OpenedAt, CreatedByUserId)
    VALUES (@FinishedGoodItemId, @ContainerConfigId, @CellLocationId, @OpenStatusId, GETUTCDATETIME(), @AppUserId);
    SET @ContainerId = SCOPE_IDENTITY();
END;

SET @TrayPosition = ISNULL((SELECT MAX(TrayPosition) FROM Lots.ContainerTray WHERE ContainerId = @ContainerId),0) + 1;
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, FinishedGoodLotId, ClosedAt, ClosedByUserId, ClosureMethod)
VALUES (@ContainerId, @TrayPosition, @PieceCount, @FinishedGoodLotId, GETUTCDATETIME(), @AppUserId, @ClosureMethod);
SET @ContainerTrayId = SCOPE_IDENTITY();

-- Complete when full (mirror Container_Complete: AIM claim [stub until AIM phase] + ShippingLabel + status flip)
IF (SELECT COUNT(*) FROM Lots.ContainerTray WHERE ContainerId = @ContainerId) >= @TraysPerContainer
BEGIN
    -- inline Container_Complete body; AIM shipper-id claim remains stubbed until the AIM phase
    UPDATE Lots.Container SET ContainerStatusCodeId = @CompleteStatusId, CompletedAt = GETUTCDATETIME() WHERE Id = @ContainerId;
    -- INSERT Lots.ShippingLabel (...);
    SET @ContainerCompleted = 1;
END;

COMMIT TRANSACTION;
SELECT @Status = 1, @Message = N'Tray completed.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    SELECT @Status = 0, @Message = ERROR_MESSAGE();  -- + failure-log per template
END CATCH;

Reply:
SELECT @Status AS Status, @Message AS Message, @FinishedGoodLotId AS FinishedGoodLotId,
       @ContainerId AS ContainerId, @ContainerTrayId AS ContainerTrayId,
       ISNULL(@ContainerCompleted,0) AS ContainerCompleted;
```
Declare all `@`-locals at the top; resolve the status/origin/relationship/status-code ids from their code tables near the top (literals-or-variables only in `EXEC`, never inline `CAST`). Confirm the real `Workorder.ConsumptionEvent` + `Lots.Container`/`ContainerTray`/`ShippingLabel` column names against migrations `0020`/`0028` as you write (the block above uses the grounded names; verify before finalizing).

- [ ] **Step 4: Run to verify pass**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `090` PASSES; suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql sql/tests/0028_PlantFloor_Assembly/090_Assembly_CompleteTray.sql
git commit -m "feat(sql): Assembly_CompleteTray mints FG LOT + consumes BOM FIFO + manages container"
```

---

### Task A3: Migrate assembly tests + retire `ContainerTray_Close` consumption

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_ContainerTray_Close.sql`
- Modify (tests): `sql/tests/0028_PlantFloor_Assembly/020,070,075_*.sql` (the tray-close/consumption tests)

**Interfaces:**
- Produces: component consumption no longer occurs in `ContainerTray_Close`; it happens only in `Assembly_CompleteTray` (A2). `ContainerTray_Close` is reduced to a no-consumption tray-insert helper OR retired if unreferenced.

- [ ] **Step 1: Point the assembly consumption tests at the orchestrator**

Update `075_ContainerTray_Close_consumes_bom.sql` and `070_ContainerTray_Close_insufficient_material.sql` to exercise `Assembly_CompleteTray` (A2) for the consume + insufficient-stock behavior instead of `ContainerTray_Close`. Keep any pure tray-position/close-method assertions (`020_ContainerTray_Close_methods.sql`) only if `ContainerTray_Close` is retained as a helper; otherwise fold them into `090`.

- [ ] **Step 2: Run to verify fail**

Run: `Reset-DevDatabase; Run-Tests`
Expected: the migrated tests FAIL against the old `ContainerTray_Close` (it still consumes → double-count vs the orchestrator).

- [ ] **Step 3: Retire the consumption from `ContainerTray_Close`**

Remove the BOM-consumption loop from `R__Lots_ContainerTray_Close.sql`. If no caller remains (grep `ContainerTray_Close` across `sql/` + `ignition/`), delete the proc file + its NQ + entity method; otherwise leave a thin tray-insert body (no consumption). Update `BlueRidge.Lots.Container.trayClose` accordingly.

- [ ] **Step 4: Run to verify pass**

Run: `Reset-DevDatabase; Run-Tests`
Expected: suite green; no double consumption.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_ContainerTray_Close.sql sql/tests/0028_PlantFloor_Assembly
git commit -m "refactor(sql): move component consumption from ContainerTray_Close to Assembly_CompleteTray"
```

---

### Task A4: Serialized path mints the FG LOT

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_ContainerSerial_Add.sql` (or the serialized-complete proc)
- Modify (tests): `sql/tests/0028_PlantFloor_Assembly/030_ContainerSerial_Add_with_bypass.sql`

**Interfaces:**
- Produces: on serialized tray completion, a FG LOT is minted (via `Assembly_CompleteTray`) and each `SerializedPart.ProducingLotId` is set to it — removing the serialized/non-serialized inconsistency.

- [ ] **Step 1: Update the serialized test** to assert that completing a serialized tray mints a FG LOT and each `SerializedPart.ProducingLotId` points at it (`PieceCount` = serial count). Run to verify fail.

- [ ] **Step 2: Run to verify fail**

Run: `Reset-DevDatabase; Run-Tests`
Expected: FAILS (serialized path currently mints no FG LOT).

- [ ] **Step 3: Wire serialized completion through the orchestrator** — when the vision/PLC "all parts in place" signal closes a serialized tray, call `Assembly_CompleteTray` with `@PieceCount` = serial count, then set the pending `SerializedPart.ProducingLotId` rows to the returned `FinishedGoodLotId`. (Serialized BOM consumption stays per the existing serialized rules if any.)

- [ ] **Step 4: Run to verify pass**

Run: `Reset-DevDatabase; Run-Tests`
Expected: PASSES; suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_ContainerSerial_Add.sql sql/tests/0028_PlantFloor_Assembly/030_ContainerSerial_Add_with_bypass.sql
git commit -m "feat(sql): serialized assembly mints the finished-good LOT"
```

---

### Task A5: Assembly NQ + entity script + persistent finished-good dropdown

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/workorder/Assembly_CompleteTray/query.sql` + `resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py`
- (Item eligibility NQ `parts/Item_ListEligibleForLocation` already exists — reuse.)

**Interfaces:**
- Produces: `BlueRidge.Workorder.Assembly.completeTray(finishedGoodItemId, pieceCount, cellLocationId, closureMethod, appUserId, ...)`.

- [ ] **Step 1: Add the NQ** wrapping `Workorder.Assembly_CompleteTray` (status-row → `attributes.type: "Query"`; params typed `sqlType` `3`=BIGINT/`4`=INT/`7`=NVARCHAR).

- [ ] **Step 2: Add the entity method** `completeTray(...)` routing through the existing `BlueRidge.Common.*` DB helper; and a `getEligibleFinishedGoodsForDropdown(cellLocationId)` returning `[{label, value}]` from `parts/Item_ListEligibleForLocation`.

- [ ] **Step 3: Scan + verify**

Run: `.\scan.ps1` (registers the new Core NQ — no gateway restart). In the DB-browser/Script Console confirm `completeTray` executes and `getEligibleFinishedGoodsForDropdown` returns the eligible finished goods.
Expected: passes.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/workorder/Assembly_CompleteTray ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py
git commit -m "feat(ignition): Assembly_CompleteTray NQ + entity methods"
```

---

### Task A6: Assembly views — persistent dropdown + completion wiring (Designer)

**Files:**
- Modify (Designer): `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized/view.json`, `AssemblySerialized/view.json`

**Interfaces:**
- Consumes: `getEligibleFinishedGoodsForDropdown`, `completeTray` (A5).

- [ ] **Step 1: Persistent finished-good dropdown** — add an `ia.input.dropdown` (options ← `getEligibleFinishedGoodsForDropdown(cellLocationId)`, `allowCustomOptions:false`) whose selection persists in `view.custom.selectedFinishedGoodItemId` for the session.

- [ ] **Step 2: Wire completion** — route the tray-closure action (manual print-label button now; count/weight/vision triggers wired as they commission) to `completeTray(selectedFinishedGoodItemId, pieceCount, cellLocationId, closureMethod, appUserId)`; show a toast with the minted FG LOT + `ContainerCompleted` state.

- [ ] **Step 3: Designer smoke** — select a finished good → close a tray → a FG LOT mints, the container tray count increments, and on the full tray the container completes (ShippingLabel row). Confirm genealogy `Container → ContainerTray → FG LOT → components` in `/shop-floor/lot-detail`.
Expected: passes.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblySerialized
git commit -m "feat(ignition): assembly views mint FG LOT via persistent finished-good dropdown"
```

---

## Part I — Inventory check-in popup

### Task I1: `Lot_GetLineInventoryByPart` read

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_GetLineInventoryByPart.sql`
- Create (test): `sql/tests/0027_PlantFloor_Machining/100_Lot_GetLineInventoryByPart.sql`

**Interfaces:**
- Produces: `Lots.Lot_GetLineInventoryByPart(@LocationId BIGINT)` → rows `ItemId, PartNumber, Description, LotId, LotName, InventoryAvailable, ArrivedAt` for open LOTs at the location, grouped by part then FIFO by arrival (`LotMovement.MovedAt`/`CreatedAt`).

- [ ] **Step 1: Write the failing test** — seed two parts with multiple LOTs at a cell; assert the read returns them grouped by part, FIFO-ordered, with `InventoryAvailable`. Run to verify fail.

- [ ] **Step 2: Run to verify fail** — `Reset-DevDatabase; Run-Tests`; `100` FAILS.

- [ ] **Step 3: Write the proc** — SELECT open LOTs (`sc.Code <> 'Closed'`, `InventoryAvailable > 0`) at `@LocationId`, join `Parts.Item`, `ORDER BY PartNumber, arrival ASC`. ET-convert any displayed timestamp per the ET convention.

- [ ] **Step 4: Run to verify pass** — `Reset-DevDatabase; Run-Tests`; `100` PASSES.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetLineInventoryByPart.sql sql/tests/0027_PlantFloor_Machining/100_Lot_GetLineInventoryByPart.sql
git commit -m "feat(sql): Lot_GetLineInventoryByPart (on-hand grouped part->lot FIFO)"
```

---

### Task I2: Inventory check-in popup component

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/lots/Lot_GetLineInventoryByPart/query.sql` + `resource.json`
- Create: `ignition/projects/MPP/.../views/BlueRidge/Components/PlantFloor/InventoryManager/view.json` + `resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` (`getLineInventoryByPart`)

**Interfaces:**
- Consumes: `Lot_GetLineInventoryByPart` (I1); `Lots.Lot_MoveToValidated` (existing) for check-in.

- [ ] **Step 1: NQ + entity method** — wrap the read; add `BlueRidge.Lots.Lot.getLineInventoryByPart(locationId)`.

- [ ] **Step 2: File-author the popup** — a new view `Components/PlantFloor/InventoryManager` (with `resource.json`): line-scoped context from `session.custom.terminal.zoneLocationId`; an on-hand list grouped part→lot (bound to the read); a scan field → `Lots.Lot.moveToValidated(scannedLotId, lineLocationId, appUserId)`; page-scoped result message + toast on success. Follow the plant-floor `pf-*` design system.

- [ ] **Step 3: Scan + smoke** — `.\scan.ps1` (registers the new Core NQ — no gateway restart). Trigger the popup from a line terminal → on-hand list renders grouped/FIFO; scan a LOT in → it moves to the line and appears in the list.
Expected: passes.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/lots/Lot_GetLineInventoryByPart ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/InventoryManager
git commit -m "feat(ignition): reusable line inventory check-in / on-hand popup"
```

- [ ] **Step 5: Embed the popup trigger** — in Designer, add an "Inventory" button to the machining/assembly terminal chrome that opens `InventoryManager` (scope `"G"` on the dom-event handler). Commit the view edits.

---

## Part K — Finished-goods KPI

### Task K1: `FinishedGoods_GetProducedSummary` read

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_FinishedGoods_GetProducedSummary.sql`
- Create (test): `sql/tests/0028_PlantFloor_Assembly/095_FinishedGoods_KPI.sql`

**Interfaces:**
- Produces: `Workorder.FinishedGoods_GetProducedSummary(@CellLocationId BIGINT = NULL, @ShiftStartUtc DATETIME2(3) = NULL, @ShiftEndUtc DATETIME2(3) = NULL)` → `LotCount` (COUNT of finished-good LOTs) + `PartCount` (SUM of `PieceCount`), grouped by finished-good part.

- [ ] **Step 1: Write the failing test** — after minting a couple of FG LOTs via `Assembly_CompleteTray`, assert the KPI returns the right `LotCount`/`PartCount` per part within the window. Run to verify fail.

- [ ] **Step 2: Run to verify fail** — `Reset-DevDatabase; Run-Tests`; `095` FAILS.

- [ ] **Step 3: Write the derived read** — aggregate over finished-good LOTs (origin `Manufactured`, Item is a `Finished Good` ItemType) filtered by cell + created-at window; `COUNT(*)` + `SUM(PieceCount)` grouped by `ItemId`. No materialized column (D5).

- [ ] **Step 4: Run to verify pass** — `Reset-DevDatabase; Run-Tests`; `095` PASSES.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_FinishedGoods_GetProducedSummary.sql sql/tests/0028_PlantFloor_Assembly/095_FinishedGoods_KPI.sql
git commit -m "feat(sql): finished-goods produced KPI (derived read)"
```

---

## Part D — Docs

### Task D1: FDS + Data Model + OIR

**Files:**
- Modify: `MPP_MES_FDS.md`, `MPP_MES_DATA_MODEL.md`, `MPP_MES_Open_Issues_Register.md`

- [ ] **Step 1: FDS edits**
- **FDS-05-009 / FDS-05-010 / FDS-05-022** — replace even-N-way-split prose with **extract-one / partial-remainder** (parent stays open until zero). Closes **UJ-03** / executes the v1.3a carried action.
- **FDS-06-013** — reframe non-serialized assembly to **mint a finished-good LOT (`tray = LOT`)** consuming `BOM × PieceCount` FIFO, Container retained as wrapper; consumption targets the LOT.
- **FDS-06-010/011** — serialized also mints the FG LOT.
- **FDS-06-020/021** — `ConsumptionEvent.ProducedLotId` is the primary consumption target.
- Reconcile the **FIFO ordering** wording (FDS-06-007 `LotMovement.MovedAt` vs FDS-05-029 `CreatedAt`/cavity) to one stated rule per terminal class.
- Revision-history row + version bump.

- [ ] **Step 2: Data Model edits** — `Lots.ContainerTray.FinishedGoodLotId`; note consumption now targets the FG LOT; revision-history row + version bump.

- [ ] **Step 3: OIR** — close **OI-32** (lineside check-in IS the allocation, embodied by the inventory popup). Regenerate the `.docx` per the doc-generation convention.

- [ ] **Step 4: Commit**

```bash
git add MPP_MES_FDS.md MPP_MES_DATA_MODEL.md MPP_MES_Open_Issues_Register.md
git commit -m "docs: machining extract-one + assembly finished-good LOT (FDS/Data Model/OIR)"
```

---

## Self-Review

**Spec coverage** (Spec 2 §10 matrix):
- MachiningOut extract-one → M1. ✔  Source-pick UI → M2. ✔  OperationType resolution → M3. ✔
- `Assembly_CompleteTray` orchestrator → A2. ✔  `ContainerTray.FinishedGoodLotId` + consumption relocation → A1 + A3. ✔
- Persistent finished-good dropdown → A5 + A6. ✔  Serialized mints FG LOT → A4. ✔
- Inventory check-in popup → I1 + I2. ✔  Finished-goods KPI → K1. ✔
- FDS + Data Model + OIR → D1. ✔  [KEEP] items carry no task (correct).

**Placeholder scan:** the orchestrator (A2 Step 3) is a full skeleton with real SQL per phase; it explicitly flags "verify the `ConsumptionEvent`/`Container*` column names against migrations 0020/0028 as you write" — a verification instruction, not a placeholder, because exact column lists must be confirmed against the built schema at implementation time. No TBD/TODO elsewhere.

**Type consistency:** `Assembly_CompleteTray` returns `FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerCompleted` — consumed by A5's entity method + A6's toast. `getEligibleFinishedGoodsForDropdown` → `[{label, value}]` consumed by A6. `Lot_GetLineInventoryByPart` shape consumed by I2. `MachiningOut_RecordSplit` keeps its multi-row result shape (M1).

**Ordering note:** Part M (machining) is independent of Part A (assembly) and can run in parallel with it; A1→A2→A3→A4 are strictly ordered (schema → orchestrator → retire old consumption → serialized); A5/A6 (Ignition) follow A2; M3 requires Spec 1. Parts I and K are independent. Docs (D1) last.

**Green-per-task:** A1 (additive column) and A2 (new proc alongside the old one) keep the suite green; A3 is the one task that deliberately goes red (migrated tests) → green (consumption retired) within the task. Ignition tasks verify via `scan.ps1` + Designer smoke (no gateway restart).
