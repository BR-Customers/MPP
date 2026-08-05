# Finished-Goods Close / Inventory Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close a finished-goods LOT (`Good → Closed`) when its container is completed, so it drops out of line-inventory / WIP reads while staying genealogy-queryable.

**Architecture:** Introduce one *silent* helper proc `Lots.Lot_CloseInline` that performs the `Good → Closed` transition (status flip + `LotStatusHistory` row + `LotStatusChanged` audit), emitting **no result set** so it can be `EXEC`'d from INSERT-EXEC-captured orchestrating procs. Wire it into `Lots.Container_Complete` (loop the container's finished-good trays) and `Quality.Hold_Release` (close a held FG tray whose container already completed).

**Tech Stack:** SQL Server 2022 T-SQL; repeatable stored procs under `sql/migrations/repeatable/`; T-SQL test harness under `sql/tests/` run by `sql/tests/Run-Tests.ps1` (sqlcmd).

**Spec:** `docs/superpowers/specs/2026-08-05-finished-goods-close-inventory-lifecycle-design.md`

## Global Constraints

- **Branch:** commit directly to `jacques/working`. NEVER `git checkout` another branch. Stage explicit paths only (`git add <path>`) — never `git add -A`/`-u`. No `Co-Authored-By` trailer.
- **FDS-11-011 (no OUTPUT params):** mutation procs use local `@Status`/`@Message`/`@NewId` and end each exit path with one `SELECT`. The new helper is **silent** (emits NO result set) — like the `Audit.Audit_Log*` writers — so it is legal to `EXEC` it from a proc captured via `INSERT … EXEC`.
- **INSERT-EXEC rule:** `Container_Complete` and `Hold_Release` are captured via `INSERT … EXEC` by tests/callers. They MUST NOT `EXEC` a status-row proc (would pollute their single result set) and MUST NOT `ROLLBACK` inside the caller txn. The helper is silent and does no transaction control of its own — safe to call inline.
- **LOT status ids (seeded, deterministic):** `Good=1`, `Hold=2`, `Scrap=3`, `Closed=4`. **Container status ids:** `Open=1`, `Complete=2`, `Shipped=3`.
- **Audit convention:** Description shape `<SUBJECT> · <CATEGORY?> · <ACTION>` via `Audit.ufn_MidDot()`, wrapped in `Audit.ufn_TruncateActivity(...)`; Old/New value JSON carries resolved-name FK sub-objects (mirror `Lots.Lot_UpdateStatus`). Arrow char is `NCHAR(8594)`.
- **ASCII-only** in any seed/string literal that sqlcmd reads (use `Audit.ufn_MidDot()` / `NCHAR(8594)`, never a literal `·`/`→` byte).
- **No versioned migration** is required — all three files are *repeatable* procs / tests, redeployed by the reset flow. Do NOT allocate an `NNNN_` migration number.
- **DB for validation:** use a uniquely-named throwaway DB `MPP_MES_FgClose` (NEVER `MPP_MES_Dev`; avoid `MPP_MES_Test` in case another agent is using it). `Run-Tests.ps1` resets (drops/recreates) its target and applies all migrations + repeatable procs before running the filtered tests.

---

### Task 1: `Lots.Lot_CloseInline` silent close helper

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_CloseInline.sql`
- Create (test): `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/085_Lot_CloseInline.sql`

**Interfaces:**
- Produces: `Lots.Lot_CloseInline @LotId BIGINT, @Reason NVARCHAR(500), @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL` — **emits no result set.** Closes the LOT `Good → Closed` only when it is currently `Good` (id 1); otherwise returns silently (skips missing / `Hold` / `Scrap` / already-`Closed`). Writes one `Lots.LotStatusHistory` row (Old=Good, New=Closed) and one `LotStatusChanged` audit entry. Runs inside the caller's transaction; no `BEGIN/COMMIT/ROLLBACK` of its own. Consumed by Tasks 2 and 3.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/085_Lot_CloseInline.sql`:

```sql
-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/085_Lot_CloseInline.sql
-- Description:  Lots.Lot_CloseInline (FAT #21) silent close helper. A Good LOT closes
--               to Closed (4) with a LotStatusHistory row + LotStatusChanged audit; a
--               Hold LOT is left untouched (Good-only guard).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/085_Lot_CloseInline.sql';
GO

DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD'));
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD'));
DELETE FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD');
GO

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE ItemTypeId = 3 ORDER BY Id);

-- A Good LOT and a Hold LOT (status 2) to prove the Good-only guard.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId)
    VALUES (N'FGC-085-GOOD', @Item, 1, 1, 10, @Cell, 0, 10, 1);
DECLARE @GoodLot BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId)
    VALUES (N'FGC-085-HELD', @Item, 1, 2, 10, @Cell, 0, 10, 1);
DECLARE @HeldLot BIGINT = SCOPE_IDENTITY();

-- Act: close both via the helper (silent proc, called directly -- no INSERT-EXEC).
EXEC Lots.Lot_CloseInline @LotId = @GoodLot, @Reason = N'unit close', @AppUserId = 1, @TerminalLocationId = @Cell;
EXEC Lots.Lot_CloseInline @LotId = @HeldLot, @Reason = N'unit close', @AppUserId = 1, @TerminalLocationId = @Cell;

-- Assert: Good LOT is now Closed (4); Held LOT is untouched (still 2).
DECLARE @GoodStatus NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @GoodLot);
EXEC test.Assert_IsEqual @TestName = N'[CloseInline] Good LOT -> Closed (4)', @Expected = N'4', @Actual = @GoodStatus;
DECLARE @HeldStatus NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @HeldLot);
EXEC test.Assert_IsEqual @TestName = N'[CloseInline] Held LOT untouched (2)', @Expected = N'2', @Actual = @HeldStatus;

-- Assert: exactly one Good->Closed history row for the Good LOT.
DECLARE @Hist NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusHistory WHERE LotId = @GoodLot AND OldStatusId = 1 AND NewStatusId = 4);
EXEC test.Assert_IsEqual @TestName = N'[CloseInline] one Good->Closed history row', @Expected = N'1', @Actual = @Hist;

-- Assert: a LotStatusChanged audit entry exists for the Good LOT.
DECLARE @Aud NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId WHERE et.Code = N'LotStatusChanged' AND ol.EntityId = @GoodLot);
EXEC test.Assert_IsEqual @TestName = N'[CloseInline] LotStatusChanged audit present', @Expected = N'1', @Actual = @Aud;
GO

DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD'));
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD'));
DELETE FROM Lots.Lot WHERE LotName IN (N'FGC-085-GOOD', N'FGC-085-HELD');
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

From `sql/tests/`:

```bash
pwsh -File ./Run-Tests.ps1 -DatabaseName "MPP_MES_FgClose" -Filter "085_Lot_CloseInline"
```

Expected: the run reaches the test file but **fails** — `Lots.Lot_CloseInline` does not exist yet, so sqlcmd errors on the `EXEC Lots.Lot_CloseInline` line (`Could not find stored procedure 'Lots.Lot_CloseInline'`) and the runner reports a failure for this file. (A sqlcmd error inside a test file exits the runner non-zero — that is the red signal.)

- [ ] **Step 3: Create the helper proc**

Create `sql/migrations/repeatable/R__Lots_Lot_CloseInline.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_Lot_CloseInline.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: SILENT close helper (FAT #21). Transitions a LOT Good (1) -> Closed (4)
--              inline: status flip + LotStatusHistory row + 'LotStatusChanged' audit.
--              MIRRORS Lots.Lot_UpdateStatus's mutation block, but emits NO result set
--              so it can be EXEC'd from INSERT-EXEC-captured orchestrating procs
--              (Lots.Container_Complete, Quality.Hold_Release) which cannot EXEC the
--              status-row Lot_UpdateStatus. Runs inside the CALLER's transaction: it
--              declares no transaction and never ROLLBACKs. Good-only guard: if the LOT
--              is missing or not currently Good (Hold/Scrap/already Closed) it returns
--              silently, so callers may pass any candidate LOT without pre-filtering.
--              No OUTPUT params (FDS-11-011).
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_CloseInline
    @LotId              BIGINT,
    @Reason             NVARCHAR(500),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @GoodStatusId BIGINT = 1, @ClosedStatusId BIGINT = 4;

    -- Good-only guard: skip missing / Hold / Scrap / already-Closed LOTs.
    DECLARE @Cur BIGINT = (SELECT LotStatusId FROM Lots.Lot WHERE Id = @LotId);
    IF @Cur IS NULL OR @Cur <> @GoodStatusId
        RETURN;

    DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);

    DECLARE @OldValue NVARCHAR(MAX) = (
        SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @GoodStatusId
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @NewValue NVARCHAR(MAX) = (
        SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @ClosedStatusId
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
        @LotName + N' ' + Audit.ufn_MidDot() + N' Status ' + Audit.ufn_MidDot()
        + N' Good' + NCHAR(8594) + N'Closed'
        + CASE WHEN @Reason IS NOT NULL THEN N' (' + @Reason + N')' ELSE N'' END);

    UPDATE Lots.Lot
    SET LotStatusId = @ClosedStatusId, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
    WHERE Id = @LotId;

    INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
    VALUES (@LotId, @GoodStatusId, @ClosedStatusId, @Reason, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

    EXEC Audit.Audit_LogOperation
        @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
        @LogEntityTypeCode = N'Lot', @EntityId = @LotId, @LogEventTypeCode = N'LotStatusChanged',
        @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = @OldValue, @NewValue = @NewValue;
END;
GO
```

- [ ] **Step 4: Run the test to verify it passes**

From `sql/tests/`:

```bash
pwsh -File ./Run-Tests.ps1 -DatabaseName "MPP_MES_FgClose" -Filter "085_Lot_CloseInline"
```

Expected: PASS — the runner summary shows the 4 assertions in `085_Lot_CloseInline.sql` passing and 0 failures, exit 0.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_CloseInline.sql sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/085_Lot_CloseInline.sql
git commit -m "feat(lots): Lot_CloseInline silent Good->Closed helper (#21)"
```

---

### Task 2: Close FG LOTs on `Container_Complete`

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Container_Complete.sql` (add the FG-close loop after the container status flip, currently near line 157; bump header version note)
- Create (test): `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/090_FinishedGoodClose_OnComplete.sql`

**Interfaces:**
- Consumes: `Lots.Lot_CloseInline` (Task 1). Also `Workorder.Assembly_CompleteTray @FinishedGoodItemId, @PieceCount, @CellLocationId, @ClosureMethod, @AppUserId, @TerminalLocationId` → `SELECT Status, Message, FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerFull` (used by the test to mint linked FG trays); `Lots.Lot_GetLineInventoryByPart @LocationId` → 7 cols `(ItemId, PartNumber, Description, LotId, LotName, InventoryAvailable, ArrivedAt)`.
- Produces: `Lots.Container_Complete`'s contract is **unchanged** (`SELECT @Status, @Message, @ShippingLabelId, @AimShipperId`); its side-effect now also closes the container's Good finished-good LOTs.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/090_FinishedGoodClose_OnComplete.sql`:

```sql
-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/090_FinishedGoodClose_OnComplete.sql
-- Description:  FAT #21 -- Lots.Container_Complete closes every linked finished-good LOT
--               (tray = LOT) that is Good, and only those. Uses Assembly_CompleteTray to
--               mint real FG-LOT-linked trays (2-tray container). Also proves a
--               NULL-FinishedGoodLotId tray (ContainerTray_Close flow) does not break
--               completion, and that closed FG LOTs drop from Lot_GetLineInventoryByPart
--               while staying genealogy-queryable.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/090_FinishedGoodClose_OnComplete.sql';
GO

-- ---- teardown (FK-safe order) ----
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'));
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL');
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL');
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL')) OR ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD');
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'))) OR AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL')));
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'))) OR ParentLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName = N'STG-090');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName = N'STG-090');
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'));
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName = N'STG-090';
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

-- FG parent part + component child + published 1-line BOM.
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P21-FGC-FG')    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P21-FGC-FG', N'FAT21 FG part', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P21-FGC-CHILD', N'FAT21 component', 1, @Now, 1);
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-FG');
DECLARE @Child BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD');
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Fg AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Fg, 1, @Now, @Now, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @Child, 1, 1, 1);
END
-- 2-tray container config (target = 2 parts => two FG LOTs).
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Fg AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Fg, 2, 1, 0, N'ByCount', @Now);
-- staged component stock at the cell (plenty).
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId)
    VALUES (N'STG-090', @Child, 1, 1, 100000, @Cell, 0, 100000, 1);
-- AIM pool for the FG part (Container_Complete claims one).
DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P21-FGC-FG', @AimShipperId = N'AIM-FGC-1';

-- ---- Act: mint two FG-LOT-linked trays into one container ----
DECLARE @AT TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 1, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @Fg1 BIGINT = (SELECT FinishedGoodLotId FROM @AT); DECLARE @Con BIGINT = (SELECT ContainerId FROM @AT); DELETE FROM @AT;
INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 1, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @Fg2 BIGINT = (SELECT FinishedGoodLotId FROM @AT); DECLARE @Full BIT = (SELECT ContainerFull FROM @AT); DELETE FROM @AT;

-- Sanity: both FG LOTs are Good and appear in line inventory BEFORE completion.
DECLARE @InvBefore TABLE (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LotId BIGINT, LotName NVARCHAR(50), InventoryAvailable INT, ArrivedAt DATETIME2(3));
INSERT INTO @InvBefore EXEC Lots.Lot_GetLineInventoryByPart @LocationId = @Cell;
DECLARE @InvB NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @InvBefore WHERE LotId IN (@Fg1, @Fg2));
EXEC test.Assert_IsEqual @TestName = N'[FGClose] both FG LOTs on-hand before complete', @Expected = N'2', @Actual = @InvB;

-- ---- Act: complete the (full) container ----
DECLARE @CMP TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CMP EXEC Lots.Container_Complete @ContainerId = @Con, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @CmpStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @CMP); DELETE FROM @CMP;
EXEC test.Assert_IsEqual @TestName = N'[FGClose] container completed (Status 1)', @Expected = N'1', @Actual = @CmpStatus;

-- Assert: both FG LOTs are now Closed (4).
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[FGClose] FG LOT 1 -> Closed (4)', @Expected = N'4', @Actual = @S1;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Fg2);
EXEC test.Assert_IsEqual @TestName = N'[FGClose] FG LOT 2 -> Closed (4)', @Expected = N'4', @Actual = @S2;

-- Assert: each FG LOT got a Good->Closed history row + LotStatusChanged audit.
DECLARE @H1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusHistory WHERE LotId = @Fg1 AND OldStatusId = 1 AND NewStatusId = 4);
EXEC test.Assert_IsEqual @TestName = N'[FGClose] FG LOT 1 Good->Closed history row', @Expected = N'1', @Actual = @H1;
DECLARE @A1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId WHERE et.Code = N'LotStatusChanged' AND ol.EntityId = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[FGClose] FG LOT 1 LotStatusChanged audit present', @Expected = N'1', @Actual = @A1;

-- Assert: closed FG LOTs are excluded from line inventory.
DECLARE @InvAfter TABLE (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LotId BIGINT, LotName NVARCHAR(50), InventoryAvailable INT, ArrivedAt DATETIME2(3));
INSERT INTO @InvAfter EXEC Lots.Lot_GetLineInventoryByPart @LocationId = @Cell;
DECLARE @InvA NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @InvAfter WHERE LotId IN (@Fg1, @Fg2));
EXEC test.Assert_IsEqual @TestName = N'[FGClose] closed FG LOTs gone from line inventory', @Expected = N'0', @Actual = @InvA;

-- Assert: genealogy still queryable (closure self-row + ancestors survive the close).
DECLARE @Gen NVARCHAR(10) = (SELECT CASE WHEN COUNT(*) >= 1 THEN N'1' ELSE N'0' END FROM Lots.LotGenealogyClosure WHERE DescendantLotId = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[FGClose] FG LOT 1 genealogy intact after close', @Expected = N'1', @Actual = @Gen;
GO

-- ---- NULL-FinishedGoodLotId tray must not break completion (ContainerTray_Close flow) ----
DECLARE @Now2 DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P21-FGC-NUL') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P21-FGC-NUL', N'FAT21 null-tray part', 1, @Now2, 1);
DECLARE @Nul BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-NUL');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Nul AND DeprecatedAt IS NULL) INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Nul, 1, 1, 0, N'ByCount', @Now2);
-- ContainerTray_Close needs a published BOM + staged component (reuse P21-FGC-CHILD stock at cell).
DECLARE @NChild BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD');
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Nul AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Nul, 1, @Now2, @Now2, 1, @Now2);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @NChild, 1, 1, 1);
END
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId) VALUES (N'STG-090', @NChild, 1, 1, 100000, @Cell2, 0, 100000, 1);
DECLARE @TP2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP2 EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P21-FGC-NUL', @AimShipperId = N'AIM-NUL-1';

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @TC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Nul, @ContainerConfigId = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Nul AND DeprecatedAt IS NULL), @CellLocationId = @Cell2, @AppUserId = 1;
DECLARE @NCon BIGINT = (SELECT NewId FROM @O); DELETE FROM @O;
INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @NCon, @TrayPosition = 1, @PartsCount = 1, @ClosureMethod = N'ByCount', @AppUserId = 1; DELETE FROM @TC;
DECLARE @CMP2 TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CMP2 EXEC Lots.Container_Complete @ContainerId = @NCon, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell2;
DECLARE @NStat NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @CMP2); DELETE FROM @CMP2;
EXEC test.Assert_IsEqual @TestName = N'[FGClose] NULL-FG-tray container completes cleanly (Status 1)', @Expected = N'1', @Actual = @NStat;
GO

-- ---- teardown (FK-safe order) ----
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'));
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL');
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL');
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL')) OR ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD');
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'))) OR AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL')));
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'))) OR ParentLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName = N'STG-090');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName = N'STG-090');
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'));
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName = N'STG-090';
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

From `sql/tests/`:

```bash
pwsh -File ./Run-Tests.ps1 -DatabaseName "MPP_MES_FgClose" -Filter "090_FinishedGoodClose_OnComplete"
```

Expected: FAIL — `Container_Complete` does not yet close FG LOTs, so the assertions `[FGClose] FG LOT 1 -> Closed (4)`, `FG LOT 2 -> Closed (4)`, the history/audit rows, and `gone from line inventory` all fail (the FG LOTs stay `Good`/`1`). The runner reports non-zero failures for this file.

- [ ] **Step 3: Wire the close loop into `Container_Complete`**

In `sql/migrations/repeatable/R__Lots_Container_Complete.sql`, add two scalar decls to the existing top `DECLARE` block (after the `@claimed TABLE` declaration near line 46):

```sql
    DECLARE @FgLotId BIGINT, @FgLotName NVARCHAR(50);
```

Then insert the FG-close cursor **immediately after** the container status flip
(`UPDATE Lots.Container SET ContainerStatusCodeId = 2, CompletedAt = SYSUTCDATETIME() WHERE Id = @ContainerId;`, currently line 157) and before the container-completed audit build:

```sql
        -- FG close (FAT #21): close every linked finished-good LOT (tray = LOT) that is
        -- still Good, now that the container is Complete. Delegates the Good->Closed
        -- transition to the silent Lots.Lot_CloseInline helper (this proc is
        -- INSERT-EXEC-captured, so it cannot EXEC the status-row Lot_UpdateStatus).
        -- Trays with NULL FinishedGoodLotId (pre-0034 / ContainerTray_Close flows) have
        -- no LOT and are skipped by the join; Hold/Scrap FG LOTs are skipped by the
        -- helper's Good-only guard.
        DECLARE fg_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT l.Id, l.LotName
            FROM Lots.ContainerTray t
            INNER JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId
            WHERE t.ContainerId = @ContainerId
              AND t.FinishedGoodLotId IS NOT NULL
              AND l.LotStatusId = 1;   -- Good
        OPEN fg_cur;
        FETCH NEXT FROM fg_cur INTO @FgLotId, @FgLotName;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC Lots.Lot_CloseInline
                @LotId = @FgLotId,
                @Reason = N'Closed on container completion (finished-goods packed & shipping-ready).',
                @AppUserId = @AppUserId,
                @TerminalLocationId = @TerminalLocationId;
            FETCH NEXT FROM fg_cur INTO @FgLotId, @FgLotName;
        END
        CLOSE fg_cur; DEALLOCATE fg_cur;
```

Also update the proc header: bump `Version:` and add a one-line note that on completion it closes the container's Good finished-good LOTs via `Lots.Lot_CloseInline` (FAT #21).

- [ ] **Step 4: Run the test to verify it passes**

From `sql/tests/`:

```bash
pwsh -File ./Run-Tests.ps1 -DatabaseName "MPP_MES_FgClose" -Filter "090_FinishedGoodClose_OnComplete"
```

Expected: PASS — all `[FGClose]` assertions pass, 0 failures, exit 0.

- [ ] **Step 5: Run the neighboring container tests to confirm no regression**

The existing `030_Container_Ship` and `080_ShippingLabel_Void_Reprint` build containers via `ContainerTray_Close` (NULL `FinishedGoodLotId`), which the new loop skips. Confirm they still pass:

```bash
pwsh -File ./Run-Tests.ps1 -DatabaseName "MPP_MES_FgClose" -Filter "0029_PlantFloor_Hold_Sort_Shipping_Aim"
```

Expected: PASS — the whole 0029 suite (including 030/080 and the new 085/090) reports 0 failures.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Container_Complete.sql sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/090_FinishedGoodClose_OnComplete.sql
git commit -m "feat(lots): close finished-good LOTs on container completion (#21)"
```

---

### Task 3: Re-close a held FG tray on `Hold_Release`

**Files:**
- Modify: `sql/migrations/repeatable/R__Quality_Hold_Release.sql` (add the FG re-close after the LOT status-restore block, currently near line 77; bump header version note)
- Create (test): `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/100_FinishedGoodClose_HeldTrayReclose.sql`

**Interfaces:**
- Consumes: `Lots.Lot_CloseInline` (Task 1). Uses `Workorder.Assembly_CompleteTray`, `Quality.Hold_Place @LotId, @ContainerId, @HoldTypeCodeId, @Reason, @AppUserId, @TerminalLocationId` → `SELECT Status, Message, NewId`, `Lots.Container_Complete`, and `Quality.Hold_Release @HoldEventId, @ReleaseRemarks, @AppUserId, @TerminalLocationId` → `SELECT Status, Message`.
- Produces: `Quality.Hold_Release`'s contract is **unchanged** (`SELECT @Status, @Message`); releasing a hold on an FG tray LOT whose container is already Complete/Shipped now also closes that LOT.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/100_FinishedGoodClose_HeldTrayReclose.sql`:

```sql
-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/100_FinishedGoodClose_HeldTrayReclose.sql
-- Description:  FAT #21 -- a held FG tray LOT is SKIPPED by the completion close and
--               stays open; releasing its hold (container already Complete) closes it
--               Good->Closed (two status-history rows: Hold->Good restore, Good->Closed).
--               A container-level hold release is unaffected (no FG close).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/100_FinishedGoodClose_HeldTrayReclose.sql';
GO

-- ---- teardown (FK-safe order) ----
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG'));
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG');
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P21-FGR-FG';
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG') OR ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-CHILD');
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG')) OR AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG'));
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG')) OR ParentLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-CHILD'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG';
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100');
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG');
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100';
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG')    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P21-FGR-FG', N'FAT21 reclose FG', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P21-FGR-CHILD') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P21-FGR-CHILD', N'FAT21 reclose component', 1, @Now, 1);
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG');
DECLARE @Child BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-CHILD');
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Fg AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Fg, 1, @Now, @Now, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @Child, 1, 1, 1);
END
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Fg AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Fg, 2, 1, 0, N'ByCount', @Now);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId)
    VALUES (N'STG-100', @Child, 1, 1, 100000, @Cell, 0, 100000, 1);
DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P21-FGR-FG', @AimShipperId = N'AIM-FGR-1';

DECLARE @AT TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 1, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @Fg1 BIGINT = (SELECT FinishedGoodLotId FROM @AT); DECLARE @Con BIGINT = (SELECT ContainerId FROM @AT); DELETE FROM @AT;
INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 1, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @Fg2 BIGINT = (SELECT FinishedGoodLotId FROM @AT); DELETE FROM @AT;

-- Hold FG LOT 1 (a LOT hold) before completion.
DECLARE @HoldType BIGINT = (SELECT TOP 1 Id FROM Quality.HoldTypeCode ORDER BY Id);
DECLARE @HP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @HP EXEC Quality.Hold_Place @LotId = @Fg1, @HoldTypeCodeId = @HoldType, @Reason = N'reclose test', @AppUserId = 2, @TerminalLocationId = @Cell;
DECLARE @He BIGINT = (SELECT NewId FROM @HP); DELETE FROM @HP;

-- Complete the (full) container.
DECLARE @CMP TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CMP EXEC Lots.Container_Complete @ContainerId = @Con, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell; DELETE FROM @CMP;

-- Assert: FG LOT 2 closed; FG LOT 1 skipped (still Hold = 2).
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Fg2);
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] non-held FG LOT closed on complete (4)', @Expected = N'4', @Actual = @S2;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] held FG LOT skipped, stays Hold (2)', @Expected = N'2', @Actual = @S1;

-- Release the hold -> restores to Good, then re-closes because container is Complete.
DECLARE @RL TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @RL EXEC Quality.Hold_Release @HoldEventId = @He, @ReleaseRemarks = N'released', @AppUserId = 2, @TerminalLocationId = @Cell;
DECLARE @RlStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @RL); DELETE FROM @RL;
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] hold release succeeds (Status 1)', @Expected = N'1', @Actual = @RlStatus;

-- Assert: FG LOT 1 is now Closed (4).
DECLARE @S1b NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] released FG LOT re-closed (4)', @Expected = N'4', @Actual = @S1b;

-- Assert: the release produced BOTH history rows (Hold->Good and Good->Closed).
DECLARE @HRestore NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusHistory WHERE LotId = @Fg1 AND OldStatusId = 2 AND NewStatusId = 1);
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] Hold->Good restore history row present', @Expected = N'1', @Actual = @HRestore;
DECLARE @HClose NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusHistory WHERE LotId = @Fg1 AND OldStatusId = 1 AND NewStatusId = 4);
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] Good->Closed re-close history row present', @Expected = N'1', @Actual = @HClose;
GO

-- ---- Container-hold release is unaffected (no FG close, no error) ----
-- Reuse the completed container @Con: place a container-level hold, then release it.
DECLARE @Con2 BIGINT = (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG');
DECLARE @HoldType2 BIGINT = (SELECT TOP 1 Id FROM Quality.HoldTypeCode ORDER BY Id);
DECLARE @HPC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @HPC EXEC Quality.Hold_Place @ContainerId = @Con2, @HoldTypeCodeId = @HoldType2, @Reason = N'container hold', @AppUserId = 2, @TerminalLocationId = @Con2;
DECLARE @HeC BIGINT = (SELECT NewId FROM @HPC); DELETE FROM @HPC;
DECLARE @RLC TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @RLC EXEC Quality.Hold_Release @HoldEventId = @HeC, @ReleaseRemarks = N'released container', @AppUserId = 2;
DECLARE @RlcStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @RLC); DELETE FROM @RLC;
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] container-hold release unaffected (Status 1)', @Expected = N'1', @Actual = @RlcStatus;
GO

-- ---- teardown (FK-safe order) ----
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG'));
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG');
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P21-FGR-FG';
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG') OR ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-CHILD');
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG')) OR AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG'));
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG')) OR ParentLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-CHILD'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG';
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100');
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG');
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100';
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

From `sql/tests/`:

```bash
pwsh -File ./Run-Tests.ps1 -DatabaseName "MPP_MES_FgClose" -Filter "100_FinishedGoodClose_HeldTrayReclose"
```

Expected: FAIL — `Hold_Release` does not yet re-close; assertions `[FGReclose] released FG LOT re-closed (4)` (LOT stays Good `1`) and `[FGReclose] Good->Closed re-close history row present` (0 rows) fail. (The completion-time skip assertions pass — that behavior lands with Task 2.)

- [ ] **Step 3: Wire the re-close into `Hold_Release`**

In `sql/migrations/repeatable/R__Quality_Hold_Release.sql`, inside the `IF @LotId IS NOT NULL` block, **after** the existing `INSERT INTO Lots.LotStatusHistory (...) VALUES (@LotId, 2, @PriorStatus, ...)` line (currently line 77) and before the block's closing `END` (line 78), add:

```sql
            -- FAT #21: if this released LOT is a finished-good tray LOT whose container
            -- has already completed/shipped, close it now (Good -> Closed). The
            -- completion-time close (Lots.Container_Complete) skips held LOTs, so a hold
            -- placed before completion leaves the FG LOT open until release. Delegates to
            -- the silent Lots.Lot_CloseInline helper (this proc is INSERT-EXEC-captured,
            -- so it cannot EXEC the status-row Lot_UpdateStatus). The helper's Good-only
            -- guard makes this a no-op unless the restore returned the LOT to Good, so
            -- the recall case (Closed -> Hold -> release restores to Closed) is skipped.
            IF EXISTS (
                SELECT 1
                FROM Lots.ContainerTray t
                INNER JOIN Lots.Container c ON c.Id = t.ContainerId
                WHERE t.FinishedGoodLotId = @LotId
                  AND c.ContainerStatusCodeId IN (2, 3))   -- Complete, Shipped
            BEGIN
                EXEC Lots.Lot_CloseInline
                    @LotId = @LotId,
                    @Reason = N'Closed on hold-release (container already complete).',
                    @AppUserId = @AppUserId,
                    @TerminalLocationId = @TerminalLocationId;
            END
```

Also update the proc header: bump `Version:` and add a one-line note that releasing a hold on a finished-good tray LOT whose container is already Complete/Shipped re-closes it via `Lots.Lot_CloseInline` (FAT #21).

- [ ] **Step 4: Run the test to verify it passes**

From `sql/tests/`:

```bash
pwsh -File ./Run-Tests.ps1 -DatabaseName "MPP_MES_FgClose" -Filter "100_FinishedGoodClose_HeldTrayReclose"
```

Expected: PASS — all `[FGReclose]` assertions pass, 0 failures, exit 0.

- [ ] **Step 5: Run the existing hold tests to confirm no regression**

`010_Hold_Place_release` exercises LOT and container hold/release on non-FG LOTs (no `ContainerTray.FinishedGoodLotId`), so the new `EXISTS` block is a no-op there. Confirm:

```bash
pwsh -File ./Run-Tests.ps1 -DatabaseName "MPP_MES_FgClose" -Filter "0029_PlantFloor_Hold_Sort_Shipping_Aim"
```

Expected: PASS — the full 0029 suite (010/015/…/085/090/100) reports 0 failures.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Quality_Hold_Release.sql sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/100_FinishedGoodClose_HeldTrayReclose.sql
git commit -m "feat(quality): re-close held finished-good LOT on hold-release (#21)"
```

---

## Deployment note (non-code)

All three changed/added files are **repeatable procs and tests** — no versioned migration, no Ignition resource, no `scan.ps1`. On the live dev/deploy gateway the two altered procs (`Container_Complete`, `Hold_Release`) and the new `Lot_CloseInline` redeploy the next time the repeatable-migration runner applies `R__*.sql`. No gateway restart required.

## Self-Review

**Spec coverage:**
- §4.1 (close on Container Complete) → Task 2 (+ helper Task 1). ✔
- §4.2 (re-close on Hold_Release) → Task 3 (+ helper Task 1). ✔
- §3 D5 (inline, INSERT-EXEC-safe) → helper is silent, EXEC'd inline; Tasks 2/3 do not EXEC a status-row proc. ✔
- §4 "skip NULL trays / Hold / Scrap" → join filter (Task 2) + helper Good-only guard (Task 1); test `[FGClose] NULL-FG-tray container completes cleanly` + `[FGReclose] held FG LOT skipped`. ✔
- §4 "quantities untouched; status-only exclusion; genealogy intact" → helper touches only status/history/audit; tests `gone from line inventory` + `genealogy intact`. ✔
- §5 (no reversal) → nothing added to `ShippingLabel_Void`; noted. ✔
- §6 testing items 1–6 → covered across 085/090/100. (Item 7 "forced-failure atomicity" is optional in the spec and omitted here — the atomicity is structural: the close runs inside `Container_Complete`'s existing `XACT_ABORT` transaction, so the pre-existing CATCH `ROLLBACK` covers it.) ✔
- §7 files → Tasks create exactly `R__Lots_Lot_CloseInline.sql`, `085/090/100` tests, and modify `R__Lots_Container_Complete.sql` + `R__Quality_Hold_Release.sql`. ✔

**Placeholder scan:** none — every step has full SQL / exact commands.

**Type consistency:** `Lots.Lot_CloseInline(@LotId, @Reason, @AppUserId, @TerminalLocationId)` is defined in Task 1 and called with those exact named params in Tasks 2 and 3. Status ids (Good=1, Closed=4, Hold=2; container Complete=2/Shipped=3) are used consistently. INSERT-EXEC temp-table shapes match each proc's SELECT column list (`Container_Complete` 4 cols; `Assembly_CompleteTray` 6 cols; `Lot_GetLineInventoryByPart` 7 cols; `Hold_Place`/`Container_Open` 3 cols; `Hold_Release`/`Container_Ship` 2 cols).

## Revision History

| Date | Change | Author |
|------|--------|--------|
| 2026-08-05 | Initial implementation plan from the approved design. | Blue Ridge Automation |
