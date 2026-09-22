# Trim Partial Checkpoint at Shift End -- Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A blast operator can press *Record partial trim - shift end*, pick the LOT on the press, type the total trimmed so far and pick the shift, and that shift is credited with its share of the LOT when the next shift completes Trim OUT.

**Architecture:** A partial is one cumulative `Workorder.ProductionEvent` checkpoint on the LOT, written with the route's `TrimIn` operation template by a new proc `Workorder.TrimPartial_Record`; the LOT does not move, so FIFO is untouched. A new nullable `ProductionEvent.ShiftId` carries the operator-picked shift (partial) or the resolver's shift (Trim OUT). Credit = the difference between consecutive trim checkpoints; Trim OUT's operator flow is unchanged.

**Tech Stack:** SQL Server 2022 (T-SQL procs, versioned + repeatable migrations, `test.*` harness), Ignition 8.3 Perspective (file-based views, Core named queries, Jython entity scripts).

**Spec:** `docs/superpowers/specs/2026-09-22-trim-partial-shift-end-design.md`

## Global Constraints

- Every mutation proc: no `OUTPUT` params; every exit ends `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;` (FDS-11-011).
- Every rejecting validation runs **before** `BEGIN TRANSACTION`; `CATCH` is the only `ROLLBACK` site (Msg 3915 under `INSERT-EXEC`).
- `RAISERROR`, not `THROW`. Schema-qualify everything. `EXEC` params are literals or `@variables` only.
- Timestamps stored UTC (`SYSUTCDATETIME()`), displayed ET via `AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'`.
- Audit Description shape `<SUBJECT> · <CATEGORY> · <ACTION>` via `Audit.ufn_MidDot()`, capped with `Audit.ufn_TruncateActivity`.
- Seed/data strings ASCII-only.
- Operation templates resolve **by route role**, never by template code: `BlueRidge.Parts.OperationTemplate.getActiveTemplateIdForLot(lotId, "TrimIn")`.
- Every entity function takes `appUserId` from its caller and calls `BlueRidge.Common.Util.requireAppUserId`.
- All named queries live in **Core**; status-row procs use NQ `type: "Query"`.
- Existing `view.json` files (TrimBody) are edited **in the Designer**; new views are file-authored then `.\scan.ps1`.
- Every `view.custom.*` a binding reads is pre-declared with a fully-shaped default.
- Commits: stage explicit paths only (never `git add -A` / `-u`); **no `Co-Authored-By` trailer**; branch `jacques/working`.
- Migration number: this plan uses **`0096`**. Before Task 1, run `ls sql/migrations/versioned | tail -1` and `git fetch; git ls-tree --name-only origin/main sql/migrations/versioned/ | tail -1`; if `0096` is taken, use the next free number everywhere `0096` appears below (file name, `MigrationId`, test folder).

## File map

| File | Responsibility |
|---|---|
| `sql/migrations/versioned/0096_trim_partial_checkpoint.sql` (create) | `ProductionEvent.ShiftId` + FK; LogEventType 34 description |
| `sql/migrations/repeatable/R__Workorder_TrimPartial_Record.sql` (create) | The partial checkpoint mutation |
| `sql/migrations/repeatable/R__Workorder_TrimCheckpoint_GetLatestForLot.sql` (create) | "Already recorded" read |
| `sql/migrations/repeatable/R__Workorder_TrimOut_Record.sql` (modify, v1.5) | Trim-scoped guard, count required after partial, ShiftId stamp |
| `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql` (modify) | Column description for `ShiftId` |
| `sql/tests/0096_Trim_Partial/*.sql` (create) | TDD suite |
| `ignition/projects/Core/ignition/named-query/workorder/TrimPartial_Record/` (create) | NQ |
| `ignition/projects/Core/ignition/named-query/workorder/TrimCheckpoint_GetLatestForLot/` (create) | NQ |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/TrimPartial/` (create) | Thin entity module |
| `ignition/projects/MPP/.../views/BlueRidge/Components/Popups/TrimPartial/` (create) | The popup |
| `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/TrimBody/view.json` (Designer edit) | Button, opener, refresh handler, "already recorded" line |
| `MPP_MES_DATA_MODEL.md`, `PROJECT_STATUS.md` (modify) | Docs |

`...` = `com.inductiveautomation.perspective`.

---

### Task 1: Migration -- `ProductionEvent.ShiftId`

**Files:**
- Create: `sql/migrations/versioned/0096_trim_partial_checkpoint.sql`
- Modify: `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql` (Workorder.ProductionEvent block, ~line 3732)
- Test: `sql/tests/0096_Trim_Partial/010_Schema.sql`

**Interfaces:**
- Produces: column `Workorder.ProductionEvent.ShiftId BIGINT NULL`, FK `FK_ProductionEvent_Shift` -> `Oee.Shift(Id)`.

- [ ] **Step 1: Write the failing test** -- `sql/tests/0096_Trim_Partial/010_Schema.sql`

```sql
-- =============================================
-- File:         0096_Trim_Partial/010_Schema.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-22
-- Description:  Migration 0096 -- ProductionEvent.ShiftId exists, is nullable,
--               FK to Oee.Shift; LogEventType 34 no longer says "reserved".
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0096_Trim_Partial/010_Schema.sql';
GO

DECLARE @Col NVARCHAR(10) = CASE WHEN COL_LENGTH(N'Workorder.ProductionEvent', N'ShiftId') IS NULL THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName = N'[0096] ProductionEvent.ShiftId exists', @Expected = N'1', @Actual = @Col;

DECLARE @Nullable NVARCHAR(10) = CAST(COLUMNPROPERTY(OBJECT_ID(N'Workorder.ProductionEvent'), N'ShiftId', 'AllowsNull') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0096] ShiftId is nullable', @Expected = N'1', @Actual = @Nullable;

DECLARE @Fk NVARCHAR(10) = CAST((SELECT COUNT(*) FROM sys.foreign_keys
    WHERE name = N'FK_ProductionEvent_Shift'
      AND parent_object_id = OBJECT_ID(N'Workorder.ProductionEvent')
      AND referenced_object_id = OBJECT_ID(N'Oee.Shift')) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0096] FK_ProductionEvent_Shift -> Oee.Shift', @Expected = N'1', @Actual = @Fk;

DECLARE @Reserved NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Audit.LogEventType
    WHERE Id = 34 AND Code = N'TrimCheckpointRecorded' AND Description NOT LIKE N'%reserved%') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0096] LogEventType 34 describes the partial', @Expected = N'1', @Actual = @Reserved;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it to verify it fails**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0096"`
Expected: 4 failures (`ShiftId exists` expected 1 got 0, etc.). `Run-Tests` rebuilds `MPP_MES_Test` from migrations first, so it never touches `MPP_MES_Dev`.

- [ ] **Step 3: Write the migration** -- `sql/migrations/versioned/0096_trim_partial_checkpoint.sql`

```sql
-- ============================================================
-- Migration:   0096_trim_partial_checkpoint.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Description: Trim partial checkpoint at shift end
--              (docs/superpowers/specs/2026-09-22-trim-partial-shift-end-design.md).
--              1. Workorder.ProductionEvent gains ShiftId BIGINT NULL FK -> Oee.Shift.
--                 Stamped by Workorder.TrimPartial_Record (operator-picked shift) and
--                 Workorder.TrimOut_Record v1.5 (Oee.ufn_ShiftIdForInstant). Nullable:
--                 existing rows and every other writer leave it NULL; no backfill.
--                 Adding a nullable column is metadata-only, which matters because
--                 ProductionEvent is born partitioned on EventAt (0020).
--              2. LogEventType 34 TrimCheckpointRecorded stops saying "reserved".
-- ============================================================

IF COL_LENGTH(N'Workorder.ProductionEvent', N'ShiftId') IS NULL
    ALTER TABLE Workorder.ProductionEvent ADD ShiftId BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_ProductionEvent_Shift')
    ALTER TABLE Workorder.ProductionEvent
        ADD CONSTRAINT FK_ProductionEvent_Shift FOREIGN KEY (ShiftId) REFERENCES Oee.Shift(Id);
GO

UPDATE Audit.LogEventType
SET Description = N'A trim checkpoint was recorded without moving the LOT: a partial trim count at shift end (Workorder.TrimPartial_Record).'
WHERE Id = 34 AND Code = N'TrimCheckpointRecorded';
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0096_trim_partial_checkpoint')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0096_trim_partial_checkpoint',
            N'ProductionEvent.ShiftId (FK Oee.Shift) for the trim partial checkpoint at shift end; LogEventType 34 described.');
GO
PRINT 'Migration 0096 (trim_partial_checkpoint) applied.';
GO
```

- [ ] **Step 4: Add the column description.** In `R__Descriptions_ExtendedProperties.sql`, inside the `-- Workorder.ProductionEvent` block (starts ~line 3732), after the last existing column sub-block of that table (the `Remarks` column block) and before the block's closing `END`, add:

```sql
    IF COL_LENGTH(N'[Workorder].[ProductionEvent]', N'ShiftId') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties
                   WHERE major_id = OBJECT_ID(N'[Workorder].[ProductionEvent]')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'[Workorder].[ProductionEvent]'), N'ShiftId', 'ColumnId')
                     AND name = N'MS_Description')
            EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'The shift this checkpoint is credited to. Stamped by Workorder.TrimPartial_Record (the shift the operator picked) and Workorder.TrimOut_Record v1.5 (Oee.ufn_ShiftIdForInstant at the trim shop). NULL on rows written before migration 0096 and on every other writer. Trim credit per shift = ShotCount minus the previous trim checkpoint on the same LOT.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'ShiftId';
        ELSE
            EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'The shift this checkpoint is credited to. Stamped by Workorder.TrimPartial_Record (the shift the operator picked) and Workorder.TrimOut_Record v1.5 (Oee.ufn_ShiftIdForInstant at the trim shop). NULL on rows written before migration 0096 and on every other writer. Trim credit per shift = ShotCount minus the previous trim checkpoint on the same LOT.',
                         @level0type = N'SCHEMA', @level0name = N'Workorder',
                         @level1type = N'TABLE',  @level1name = N'ProductionEvent',
                         @level2type = N'COLUMN', @level2name = N'ShiftId';
    END
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0096"`
Expected: 4 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/versioned/0096_trim_partial_checkpoint.sql sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql sql/tests/0096_Trim_Partial/010_Schema.sql
git commit -m "feat(trim): ProductionEvent.ShiftId for the trim partial checkpoint (0096)"
```

---

### Task 2: `Workorder.TrimPartial_Record`

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_TrimPartial_Record.sql`
- Test: `sql/tests/0096_Trim_Partial/020_TrimPartial_Record.sql`, `sql/tests/0096_Trim_Partial/030_TrimPartial_validation.sql`

**Interfaces:**
- Consumes: `ProductionEvent.ShiftId` (Task 1).
- Produces: `EXEC Workorder.TrimPartial_Record @LotId BIGINT, @OperationTemplateId BIGINT, @ShotCount INT, @ScrapLinesJson NVARCHAR(MAX) = NULL, @ShiftId BIGINT, @SourceLocationId BIGINT, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL` -> one row `(Status BIT, Message NVARCHAR(500), NewId BIGINT)`; `NewId` = the `ProductionEvent.Id`. `@ScrapLinesJson` shape: `[{"defectCodeId":<bigint>,"quantity":<int>}, ...]`.

**Shared test fixture** (used verbatim at the top of 020, 030, 040, 050): item `5G0-c` (its published route has `DieCast -> TrimIn -> TrimOut -> ...`, the same item `0024/060` relies on), a LOT of 953 at `TRIM1`, a closed fixture shift.

```sql
-- ---- fixture cleanup (FK order: events before LOTs, events before the shift) ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
DELETE FROM Oee.Shift WHERE Remarks = N'TPC-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TPC-FIXTURE-SCHED';
GO

-- 5G0-c eligible at the trim shop so Lot_Create can stage it there.
DECLARE @ItemF BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @TrimF BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @ItemF AND LocationId = @TrimF AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
    VALUES (@ItemF, @TrimF, 0, SYSUTCDATETIME());

-- CLOSED shift: UIX_Shift_SingleOpen makes a leaked open shift every later suite's problem.
INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TPC-FIXTURE-SCHED', '14:00:00', '22:00:00', 127, CAST(SYSUTCDATETIME() AS DATE), 1);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES ((SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TPC-FIXTURE-SCHED'),
        DATEADD(HOUR, -8, SYSUTCDATETIME()), DATEADD(MINUTE, -5, SYSUTCDATETIME()), N'TPC-FIXTURE');
GO
```

Shared declarations (each test batch re-declares these, since `GO` ends scope):

```sql
DECLARE @Item  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Src   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Rcv   BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Shift BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TPC-FIXTURE');
DECLARE @OtIn  BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND oty.Code = N'TrimIn');
DECLARE @Dc    BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Rcv, @CurrentLocationId = @Src, @PieceCount = 953, @AppUserId = 1;
SELECT @L = NewId FROM #C; DROP TABLE #C;
```

Shared cleanup at the end of each file: the same cleanup block as above, then `EXEC test.EndTestFile; GO`.

- [ ] **Step 1: Write the happy-path test** -- `020_TrimPartial_Record.sql`: header comment block (same shape as Task 1), `SET NOCOUNT ON; SET XACT_ABORT ON; EXEC test.BeginTestFile @FileName = N'0096_Trim_Partial/020_TrimPartial_Record.sql'; GO`, the shared fixture, then:

```sql
<shared declarations>

DECLARE @Json NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Dc AS NVARCHAR(20)) + N',"quantity":5}]';
DECLARE @MovBefore NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Lots.LotMovement WHERE LotId = @L) AS NVARCHAR(10));
DECLARE @S BIT, @Msg NVARCHAR(500), @PeId BIGINT;
CREATE TABLE #T (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T EXEC Workorder.TrimPartial_Record
    @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 700, @ScrapLinesJson = @Json,
    @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @S = Status, @Msg = Message, @PeId = NewId FROM #T; DROP TABLE #T;

DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Partial] Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @Pe NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Workorder.ProductionEvent
    WHERE Id = @PeId AND LotId = @L AND OperationTemplateId = @OtIn AND ShotCount = 700 AND ScrapCount = 5) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Partial] checkpoint written: TrimIn template, cumulative 700, scrap 5', @Expected = N'1', @Actual = @Pe;

DECLARE @ShiftExp NVARCHAR(20) = CAST(@Shift AS NVARCHAR(20));
DECLARE @PeShift NVARCHAR(20) = ISNULL(CAST((SELECT ShiftId FROM Workorder.ProductionEvent WHERE Id = @PeId) AS NVARCHAR(20)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[Partial] checkpoint stamped with the picked shift', @Expected = @ShiftExp, @Actual = @PeShift;

DECLARE @SrcStr NVARCHAR(20) = CAST(@Src AS NVARCHAR(20));
DECLARE @Cur NVARCHAR(20) = CAST((SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @L) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Partial] LOT does not move', @Expected = @SrcStr, @Actual = @Cur;

DECLARE @Mov NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Lots.LotMovement WHERE LotId = @L) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Partial] no LotMovement written', @Expected = @MovBefore, @Actual = @Mov;

DECLARE @Pc NVARCHAR(10) = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @L) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Partial] scrap decrements PieceCount (953 - 5)', @Expected = N'948', @Actual = @Pc;
DECLARE @Inv NVARCHAR(10) = CAST((SELECT InventoryAvailable FROM Lots.Lot WHERE Id = @L) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Partial] scrap decrements InventoryAvailable too', @Expected = N'948', @Actual = @Inv;

DECLARE @Rj NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent
    WHERE LotId = @L AND Quantity = 5 AND DefectCodeId = @Dc AND ItemId = @Item
      AND CellLocationId = @Src AND ShiftId = @Shift AND ToolCavityId IS NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Partial] reject row stamped Item + Cell + Shift, no cavity', @Expected = N'1', @Actual = @Rj;

DECLARE @St NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @L);
EXEC test.Assert_IsEqual @TestName = N'[Partial] LOT stays Good', @Expected = N'Good', @Actual = @St;

DECLARE @Aud NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Audit.OperationLog ol
    JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
    WHERE et.Code = N'TrimCheckpointRecorded' AND ol.EntityId = @PeId) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Partial] TrimCheckpointRecorded audit', @Expected = N'1', @Actual = @Aud;

-- FIFO: the LOT stays in the trim shop's list, now waiting on Trim OUT.
CREATE TABLE #Q (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3),
    NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);
INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Src;
DECLARE @Q NVARCHAR(10) = CAST((SELECT COUNT(*) FROM #Q WHERE Id = @L AND NextOperationTypeCode = N'TrimOut') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Partial] LOT still in the trim list, next step TrimOut', @Expected = N'1', @Actual = @Q;
DROP TABLE #Q;

-- A second partial on the same LOT (a LOT spanning three shifts).
DECLARE @S2 BIT;
CREATE TABLE #T2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T2 EXEC Workorder.TrimPartial_Record
    @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 800,
    @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @S2 = Status FROM #T2; DROP TABLE #T2;
DECLARE @S2Str NVARCHAR(10) = CAST(@S2 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Partial] second partial (800) accepted', @Expected = N'1', @Actual = @S2Str;
GO
```

Then the shared cleanup and `EXEC test.EndTestFile; GO`.

- [ ] **Step 2: Write the validation test** -- `030_TrimPartial_validation.sql`: same header/fixture, then one batch that runs each rejection through a helper temp table and asserts `Status = 0` plus a message fragment. Every case uses the fixture LOT `@L` (953 at TRIM1).

```sql
<shared declarations>

DECLARE @Other BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM2');
DECLARE @DeadDc BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NOT NULL ORDER BY Id);
DECLARE @BadJson NVARCHAR(MAX) = N'not json';
DECLARE @ZeroQty NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Dc AS NVARCHAR(20)) + N',"quantity":0}]';
DECLARE @DeadJson NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(ISNULL(@DeadDc, -1) AS NVARCHAR(20)) + N',"quantity":1}]';
DECLARE @Big NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Dc AS NVARCHAR(20)) + N',"quantity":10}]';
DECLARE @Res TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @St NVARCHAR(10), @M NVARCHAR(500);

-- 1. missing ShiftId
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 100, @ShiftId = NULL, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)), @M = Message FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] missing ShiftId rejects', @Expected = N'0', @Actual = @St;

-- 1b. missing ShotCount
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = NULL, @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] missing ShotCount rejects', @Expected = N'0', @Actual = @St;

-- 2. bad JSON / zero quantity / deprecated defect code
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 100, @ScrapLinesJson = @BadJson, @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] invalid scrap JSON rejects', @Expected = N'0', @Actual = @St;

DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 100, @ScrapLinesJson = @ZeroQty, @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] zero scrap quantity rejects', @Expected = N'0', @Actual = @St;

DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 100, @ScrapLinesJson = @DeadJson, @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] deprecated/unknown defect code rejects', @Expected = N'0', @Actual = @St;

-- 3. bad template
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = -1, @ShotCount = 100, @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] unknown template rejects', @Expected = N'0', @Actual = @St;

-- 4. unknown LOT
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = -1, @OperationTemplateId = @OtIn, @ShotCount = 100, @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)), @M = Message FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] unknown LOT rejects', @Expected = N'0', @Actual = @St;

-- 5. LOT not at this trim shop
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 100, @ShiftId = @Shift, @SourceLocationId = @Other, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)), @M = Message FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] LOT at another shop rejects', @Expected = N'0', @Actual = @St;
DECLARE @HasAt NVARCHAR(10) = CASE WHEN @M LIKE N'%not at this Trim station%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] ...with the not-at-this-station message', @Expected = N'1', @Actual = @HasAt;

-- 6. unknown shift
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 100, @ShiftId = -1, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] unknown shift rejects', @Expected = N'0', @Actual = @St;

-- 7. negative / over the LOT (950 + 10 scrap > 953)
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = -1, @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] negative count rejects', @Expected = N'0', @Actual = @St;

DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 950, @ScrapLinesJson = @Big, @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] count + scrap over PieceCount rejects', @Expected = N'0', @Actual = @St;

-- 8. below the previous trim checkpoint: record 500, then try 400
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 500, @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] setup: 500 accepted', @Expected = N'1', @Actual = @St;
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 400, @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] count below last trim checkpoint rejects', @Expected = N'0', @Actual = @St;

-- 9. nothing to record: same 500 again with no scrap
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 500, @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[Partial-] no progress and no scrap rejects', @Expected = N'0', @Actual = @St;

-- Rejections write nothing: exactly the one accepted checkpoint exists.
DECLARE @N NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Workorder.ProductionEvent WHERE LotId = @L) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Partial-] rejections wrote no checkpoints', @Expected = N'1', @Actual = @N;
DECLARE @Pc NVARCHAR(10) = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @L) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Partial-] rejections left PieceCount alone', @Expected = N'953', @Actual = @Pc;
GO
```

- [ ] **Step 3: Run to verify both fail**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0096"`
Expected: 020/030 fail (`Could not find stored procedure 'Workorder.TrimPartial_Record'`).

- [ ] **Step 4: Write the proc** -- `sql/migrations/repeatable/R__Workorder_TrimPartial_Record.sql`

```sql
-- ============================================================
-- Repeatable:  R__Workorder_TrimPartial_Record.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: Trim partial checkpoint at shift end
--              (docs/superpowers/specs/2026-09-22-trim-partial-shift-end-design.md).
--              Writes ONE cumulative Workorder.ProductionEvent on the LOT with the
--              route's TrimIn template and the shift the OPERATOR PICKED (never
--              defaulted -- the die cast shift-picker defect came from a preselected
--              shift). The LOT does NOT move: its FIFO position is untouched and
--              Trim OUT later closes it exactly as today. Credit per shift is
--              ShotCount minus the previous TRIM checkpoint on the LOT.
--
--              Optional by design: the tumblers never call it.
--
--              Scrap: one RejectEvent per line, stamped ItemId + CellLocationId +
--              ShiftId (0084 identity), ProductionEventId NULL (mirror of Trim OUT
--              v1.4); the LOT is decremented once by the total, as Trim OUT does.
--
--              Flow (FDS-11-011 + Msg-3915): every rejecting check runs BEFORE
--              BEGIN TRANSACTION; each check only runs while @Message IS NULL, and a
--              single exit logs the failure and returns the status row. CATCH is
--              the only ROLLBACK site. No OUTPUT params; NewId = ProductionEventId.
--              Audit 'TrimCheckpointRecorded' (LogEventType 34).
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.TrimPartial_Record
    @LotId               BIGINT,
    @OperationTemplateId BIGINT,
    @ShotCount           INT,
    @ScrapLinesJson      NVARCHAR(MAX) = NULL,   -- [{"defectCodeId":<bigint>,"quantity":<int>}, ...]
    @ShiftId             BIGINT,
    @SourceLocationId    BIGINT,
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = NULL;
    DECLARE @NewId   BIGINT        = NULL;   -- ProductionEventId

    DECLARE @ProcName NVARCHAR(200) = N'Workorder.TrimPartial_Record';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @OperationTemplateId AS OperationTemplateId,
               @ShotCount AS ShotCount, LEFT(@ScrapLinesJson, 2000) AS ScrapLinesJson,
               @ShiftId AS ShiftId, @SourceLocationId AS SourceLocationId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @FromLocationId BIGINT;
    DECLARE @ItemId         BIGINT;
    DECLARE @LotName        NVARCHAR(50);
    DECLARE @LotPieceCount  INT;
    DECLARE @StatusCode     NVARCHAR(20);
    DECLARE @StatusName     NVARCHAR(100);
    DECLARE @Blocks         BIT;
    DECLARE @PrevShot       INT;
    DECLARE @ScrapTotal     INT = 0;
    DECLARE @Scrap TABLE (DefectCodeId BIGINT, Quantity INT);

    BEGIN TRY
        -- ---- 1. Required parameters (ShotCount + ShiftId are required here) ----
        IF @LotId IS NULL OR @OperationTemplateId IS NULL OR @ShotCount IS NULL
           OR @ShiftId IS NULL OR @SourceLocationId IS NULL OR @AppUserId IS NULL
            SET @Message = N'Required parameter missing (LotId, OperationTemplateId, ShotCount, ShiftId, SourceLocationId, AppUserId).';

        -- ---- 2. Scrap lines ----
        IF @Message IS NULL AND @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) <> 1
            SET @Message = N'ScrapLinesJson is not valid JSON.';

        IF @Message IS NULL AND @ScrapLinesJson IS NOT NULL
        BEGIN
            INSERT INTO @Scrap (DefectCodeId, Quantity)
            SELECT j.defectCodeId, j.quantity
            FROM OPENJSON(@ScrapLinesJson)
                 WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') j;
            SET @ScrapTotal = ISNULL((SELECT SUM(Quantity) FROM @Scrap), 0);
        END

        IF @Message IS NULL AND EXISTS (SELECT 1 FROM @Scrap WHERE Quantity IS NULL OR Quantity <= 0)
            SET @Message = N'Each scrap line quantity must be positive.';

        IF @Message IS NULL AND EXISTS (
            SELECT 1 FROM @Scrap s
            WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc
                              WHERE dc.Id = s.DefectCodeId AND dc.DeprecatedAt IS NULL))
            SET @Message = N'One or more scrap defect codes are invalid or deprecated.';

        -- ---- 3. Template ----
        IF @Message IS NULL AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate
                                            WHERE Id = @OperationTemplateId AND DeprecatedAt IS NULL)
            SET @Message = N'OperationTemplate not found or deprecated.';

        -- ---- 4. LOT existence + not-blocked (mirror of TrimOut_Record step 3) ----
        IF @Message IS NULL
            SELECT @FromLocationId = l.CurrentLocationId,
                   @ItemId         = l.ItemId,
                   @LotName        = l.LotName,
                   @LotPieceCount  = l.PieceCount,
                   @StatusCode     = sc.Code,
                   @StatusName     = sc.Name,
                   @Blocks         = sc.BlocksProduction
            FROM Lots.Lot l
            INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
            WHERE l.Id = @LotId;

        IF @Message IS NULL AND @StatusCode IS NULL
            SET @Message = N'LOT not found.';

        IF @Message IS NULL AND (@Blocks = 1 OR @StatusCode IN (N'Closed', N'Open'))
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode + N') and cannot record a partial trim.';

        -- ---- 5. The LOT is checked in at this trim zone (mirror of TrimOut step 3b) ----
        IF @Message IS NULL AND NOT EXISTS (
            SELECT 1 FROM Location.ufn_AncestorLocationIds(@FromLocationId)
            WHERE LocationId = @SourceLocationId)
            SET @Message = N'LOT is not at this Trim station (currently at '
                         + ISNULL((SELECT Name FROM Location.Location WHERE Id = @FromLocationId), N'an unknown location')
                         + N').';

        -- ---- 6. Shift ----
        IF @Message IS NULL AND NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE Id = @ShiftId)
            SET @Message = N'Shift not found.';

        -- ---- 7. Counts ----
        IF @Message IS NULL AND @ShotCount < 0
            SET @Message = N'Trimmed count cannot be negative.';

        IF @Message IS NULL AND (@ShotCount + @ScrapTotal) > @LotPieceCount
            SET @Message = N'Trimmed ' + CAST(@ShotCount AS NVARCHAR(20))
                         + N' + scrap ' + CAST(@ScrapTotal AS NVARCHAR(20))
                         + N' exceeds the LOT piece count ' + CAST(@LotPieceCount AS NVARCHAR(20)) + N'.';

        -- ---- 8. Cumulative: never below the LOT's last TRIM checkpoint ----
        IF @Message IS NULL
            SELECT TOP 1 @PrevShot = pe.ShotCount
            FROM Workorder.ProductionEvent pe
            INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
            INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
            WHERE pe.LotId = @LotId AND pe.ShotCount IS NOT NULL
              AND oty.Code IN (N'TrimIn', N'TrimOut')
            ORDER BY pe.EventAt DESC, pe.Id DESC;

        IF @Message IS NULL AND @PrevShot IS NOT NULL AND @ShotCount < @PrevShot
            SET @Message = N'Trimmed so far (' + CAST(@ShotCount AS NVARCHAR(20))
                         + N') is less than the ' + CAST(@PrevShot AS NVARCHAR(20))
                         + N' already recorded on this LOT.';

        -- ---- 9. Nothing to record ----
        IF @Message IS NULL AND @ShotCount = ISNULL(@PrevShot, 0) AND @ScrapTotal = 0
            SET @Message = N'Nothing to record: no pieces trimmed since the last count and no scrap.';

        -- ---- single rejection exit (no transaction open) ----
        IF @Message IS NOT NULL
        BEGIN
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                    @EntityId = @LotId, @LogEventTypeCode = N'TrimCheckpointRecorded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        DECLARE @ShiftLabel NVARCHAR(200) = (
            SELECT ss.Name + N' ' + FORMAT(s.ActualStart, N'MM-dd')
            FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
            WHERE s.Id = @ShiftId);

        BEGIN TRANSACTION;

        -- (a) the checkpoint (mirror of the Trim OUT inline insert, + ShiftId)
        INSERT INTO Workorder.ProductionEvent (
            LotId, OperationTemplateId, WorkOrderOperationId, EventAt,
            ShotCount, ScrapCount, ScrapSourceId,
            WeightValue, WeightUomId, AppUserId, TerminalLocationId, Remarks, ShiftId
        )
        VALUES (
            @LotId, @OperationTemplateId, NULL, SYSUTCDATETIME(),
            @ShotCount, @ScrapTotal, NULL,
            NULL, NULL, @AppUserId, @TerminalLocationId, N'Partial trim - shift end', @ShiftId
        );
        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- (b) scrap rows, stamped with their own identity + the picked shift
        IF EXISTS (SELECT 1 FROM @Scrap)
            INSERT INTO Workorder.RejectEvent
                (ProductionEventId, LotId, ItemId, CellLocationId, ShiftId, DefectCodeId, Quantity,
                 ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt)
            SELECT NULL, @LotId, @ItemId, @SourceLocationId, @ShiftId, s.DefectCodeId, s.Quantity,
                   NULL, N'Trim partial scrap', @AppUserId, @TerminalLocationId, SYSUTCDATETIME()
            FROM @Scrap s;

        -- (c) scrap comes out of the LOT (mirror of the Trim OUT decrement; never negative, guard 7)
        IF @ScrapTotal > 0
            UPDATE Lots.Lot
            SET PieceCount         = PieceCount - @ScrapTotal,
                InventoryAvailable = InventoryAvailable - @ScrapTotal,
                UpdatedAt          = SYSUTCDATETIME(),
                UpdatedByUserId    = @AppUserId
            WHERE Id = @LotId;

        -- (d) audit
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @LotName + N' ' + Audit.ufn_MidDot() + N' Trim ' + Audit.ufn_MidDot()
            + N' Partial ' + CAST(@ShotCount AS NVARCHAR(20)) + N' trimmed, '
            + CAST(@ScrapTotal AS NVARCHAR(20)) + N' scrap (' + ISNULL(@ShiftLabel, N'shift ?') + N')');

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT
                pe.Id, pe.ShotCount, pe.ScrapCount,
                JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                            FROM Lots.Lot l WHERE l.Id = pe.LotId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                JSON_QUERY((SELECT s.Id, ss.Name AS Code, @ShiftLabel AS Name
                            FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
                            WHERE s.Id = pe.ShiftId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Shift,
                JSON_QUERY((SELECT ot.Id, ot.Code, ot.Name
                            FROM Parts.OperationTemplate ot WHERE ot.Id = pe.OperationTemplateId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS OperationTemplate
            FROM Workorder.ProductionEvent pe WHERE pe.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @FromLocationId,
            @LogEntityTypeCode  = N'ProductionEvent',
            @EntityId           = @NewId,
            @LogEventTypeCode   = N'TrimCheckpointRecorded',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Partial trim recorded: ' + CAST(@ShotCount AS NVARCHAR(20))
                     + N' trimmed so far on ' + @LotName + N'.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @NewId   = NULL;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'TrimCheckpointRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

- [ ] **Step 5: Run to verify it passes**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0096"`
Expected: 010, 020, 030 all pass, 0 failures. If `[Partial] LOT still in the trim list, next step TrimOut` fails, stop and report: it means `Lots.ufn_NextPendingRouteStep` treats the TrimIn-template checkpoint differently from the spec's assumption (D5), and that decision needs Jacques.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_TrimPartial_Record.sql sql/tests/0096_Trim_Partial/020_TrimPartial_Record.sql sql/tests/0096_Trim_Partial/030_TrimPartial_validation.sql
git commit -m "feat(trim): Workorder.TrimPartial_Record -- cumulative partial checkpoint, picked shift, LOT stays put"
```

---

### Task 3: `Workorder.TrimOut_Record` v1.5

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_TrimOut_Record.sql`
- Test: `sql/tests/0096_Trim_Partial/040_TrimOut_after_partial.sql`

**Interfaces:**
- Consumes: `TrimPartial_Record` (Task 2), `Oee.ufn_ShiftIdForInstant(@LocationId BIGINT, @InstantUtc DATETIME2(3))` -> table with column `ShiftId`.
- Produces: unchanged signature; Trim OUT rows now carry `ShiftId`.

- [ ] **Step 1: Write the failing test** -- `040_TrimOut_after_partial.sql` (header, BeginTestFile, shared fixture), then:

```sql
<shared declarations>

DECLARE @OtOut BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND oty.Code = N'TrimOut');
DECLARE @J5 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Dc AS NVARCHAR(20)) + N',"quantity":5}]';
DECLARE @J2 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Dc AS NVARCHAR(20)) + N',"quantity":2}]';
DECLARE @Big NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Dc AS NVARCHAR(20)) + N',"quantity":300}]';
DECLARE @Res TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @St NVARCHAR(10), @OutId BIGINT;

-- 2nd shift: partial 700, scrap 5 -> LOT 948
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 700,
    @ScrapLinesJson = @J5, @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;

-- Trim OUT with NULL count after a partial -> rejected
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimOut_Record @ParentLotId = @L, @OperationTemplateId = @OtOut, @ShotCount = NULL,
    @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] NULL count after a partial rejects', @Expected = N'0', @Actual = @St;

-- Trim OUT whose count falls below the partial (648 good + 300 scrap = 948) -> rejected
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimOut_Record @ParentLotId = @L, @OperationTemplateId = @OtOut, @ShotCount = 648,
    @ScrapLinesJson = @Big, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] count below the partial rejects', @Expected = N'0', @Actual = @St;

-- 3rd shift: Trim OUT as the screen sends it: 948 - 2 = 946
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimOut_Record @ParentLotId = @L, @OperationTemplateId = @OtOut, @ShotCount = 946,
    @ScrapLinesJson = @J2, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)), @OutId = NewId FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] Trim OUT after partial accepted', @Expected = N'1', @Actual = @St;

-- Credit split: 700 then 246 (spec 3.2)
DECLARE @Credit TABLE (Id BIGINT, Trimmed INT);
INSERT INTO @Credit
SELECT pe.Id, pe.ShotCount - ISNULL(LAG(pe.ShotCount) OVER (PARTITION BY pe.LotId ORDER BY pe.EventAt, pe.Id), 0)
FROM Workorder.ProductionEvent pe
JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE pe.LotId = @L AND oty.Code IN (N'TrimIn', N'TrimOut');
DECLARE @First NVARCHAR(10) = CAST((SELECT TOP 1 Trimmed FROM @Credit ORDER BY Id) AS NVARCHAR(10));
DECLARE @Second NVARCHAR(10) = CAST((SELECT Trimmed FROM @Credit WHERE Id = @OutId) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] partial shift credited 700', @Expected = N'700', @Actual = @First;
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] finishing shift credited 246', @Expected = N'246', @Actual = @Second;

-- ShiftId stamped from the resolver at the trim shop (NULL-safe compare: the test DB may have no running shift)
DECLARE @ExpShift NVARCHAR(20) = ISNULL(CAST((SELECT TOP 1 ShiftId FROM Oee.ufn_ShiftIdForInstant(@Src, SYSUTCDATETIME())) AS NVARCHAR(20)), N'<NULL>');
DECLARE @OutShift NVARCHAR(20) = ISNULL(CAST((SELECT ShiftId FROM Workorder.ProductionEvent WHERE Id = @OutId) AS NVARCHAR(20)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] checkpoint ShiftId = ufn_ShiftIdForInstant', @Expected = @ExpShift, @Actual = @OutShift;
DECLARE @RjShift NVARCHAR(20) = ISNULL(CAST((SELECT TOP 1 ShiftId FROM Workorder.RejectEvent WHERE LotId = @L AND Remarks = N'Trim OUT scrap') AS NVARCHAR(20)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] scrap ShiftId = ufn_ShiftIdForInstant', @Expected = @ExpShift, @Actual = @RjShift;
GO

-- Trim-scoped guard: a non-trim ProductionEvent with a HIGHER count does not block Trim OUT.
<shared declarations>
DECLARE @OtOut BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND oty.Code = N'TrimOut');
DECLARE @OtDc BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND oty.Code = N'DieCast');
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
VALUES (@L, @OtDc, SYSUTCDATETIME(), 5000, 1);
DECLARE @Res2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Res2 EXEC Workorder.TrimOut_Record @ParentLotId = @L, @OperationTemplateId = @OtOut, @ShotCount = 953,
    @SourceLocationId = @Src, @AppUserId = 1;
DECLARE @St2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @Res2);
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] guard ignores non-trim checkpoints', @Expected = N'1', @Actual = @St2;
GO
```

(The second batch runs against a second fixture LOT: `<shared declarations>` creates a fresh 953 LOT.) Then the shared cleanup + `EndTestFile`.

- [ ] **Step 2: Run to verify it fails**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0096"`
Expected FAIL: `NULL count after a partial rejects` (expected 0 got 1), both ShiftId asserts (unless the test DB has no running shift, which makes those two pass vacuously; the other failures still prove red), `guard ignores non-trim checkpoints` (expected 1 got 0).

- [ ] **Step 3: Modify `R__Workorder_TrimOut_Record.sql`**

(a) Header: set `-- Modified:    2026-09-22`, `-- Version:     1.5`, and prepend to `-- Change:`:

```sql
-- Change:      v1.5 (2026-09-22, trim partial checkpoint) - (1) the monotonic guard
--              compares against the LOT's last TRIM checkpoint (TrimIn/TrimOut
--              templates) instead of its last event of any operation, so a partial
--              is never diffed against another operation's counter; (2) when a trim
--              checkpoint exists, @ShotCount is required -- a NULL would leave the
--              partial shift's credit undefined; (3) the checkpoint and its scrap
--              rows stamp ShiftId from Oee.ufn_ShiftIdForInstant at the trim shop
--              (0096). Spec 2026-09-22-trim-partial-shift-end-design.md sec 5.2.
--              Guarded by 0096/040_TrimOut_after_partial.
```

(b) Replace the step-7 query:

```sql
        SELECT TOP 1 @PrevShot = pe.ShotCount
        FROM Workorder.ProductionEvent pe
        WHERE pe.LotId = @ParentLotId
        ORDER BY pe.EventAt DESC, pe.Id DESC;
```

with:

```sql
        -- v1.5: scoped to TRIM checkpoints (a partial is cumulative within trim only).
        SELECT TOP 1 @PrevShot = pe.ShotCount
        FROM Workorder.ProductionEvent pe
        INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
        INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
        WHERE pe.LotId = @ParentLotId AND pe.ShotCount IS NOT NULL
          AND oty.Code IN (N'TrimIn', N'TrimOut')
        ORDER BY pe.EventAt DESC, pe.Id DESC;

        -- v1.5: after a partial the count is required.
        IF @PrevShot IS NOT NULL AND @ShotCount IS NULL
        BEGIN
            SET @Message = N'A partial trim count of ' + CAST(@PrevShot AS NVARCHAR(20))
                         + N' is recorded on this LOT; Trim OUT needs the LOT''s full trimmed count.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
```

(The existing `IF @PrevShot IS NOT NULL AND @ShotCount IS NOT NULL AND @ShotCount < @PrevShot` block stays as it is, right after.)

(c) Immediately before `BEGIN TRANSACTION;` add:

```sql
        -- v1.5: the shift this OUT is credited to (not a shift-end action, so resolved, not picked).
        DECLARE @ShiftId BIGINT = (SELECT TOP 1 r.ShiftId
                                   FROM Oee.ufn_ShiftIdForInstant(@SourceLocationId, SYSUTCDATETIME()) r);
```

(d) In the `INSERT INTO Workorder.ProductionEvent` column list append `, ShiftId` after `Remarks`, and in `VALUES` append `, @ShiftId` after the final `NULL`.

(e) In the `INSERT INTO Workorder.RejectEvent` add `ShiftId` after `CellLocationId` in the column list and `@ShiftId` after `@SourceLocationId` in the `SELECT`. Update the v1.4 comment line `-- ToolId / ToolCavityId / ShiftId stay NULL deliberately: trim runs on` to `-- ToolId / ToolCavityId stay NULL deliberately (v1.5 stamps ShiftId): trim runs on`.

- [ ] **Step 4: Run the new suite and the existing trim suite**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0096"` -> 0 failures.
Run: `.\sql\tests\Run-Tests.ps1 -Filter "0024_PlantFloor_Movement_Trim"` -> 0 failures (the pre-existing Trim OUT tests stay green; `050` counter-regression still rejects because its prior event is a trim checkpoint or it compares within trim -- if `050`'s regression case now passes unexpectedly, read which template its "prior" event uses and report before changing the test).
Run: `.\sql\tests\Run-Tests.ps1` (full) -> 0 failures.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_TrimOut_Record.sql sql/tests/0096_Trim_Partial/040_TrimOut_after_partial.sql
git commit -m "feat(trim): TrimOut_Record v1.5 -- trim-scoped guard, count required after partial, ShiftId stamp"
```

---

### Task 4: `Workorder.TrimCheckpoint_GetLatestForLot`

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_TrimCheckpoint_GetLatestForLot.sql`
- Test: `sql/tests/0096_Trim_Partial/050_TrimCheckpoint_GetLatestForLot.sql`

**Interfaces:**
- Produces: `EXEC Workorder.TrimCheckpoint_GetLatestForLot @LotId BIGINT` -> 0 or 1 row: `ProductionEventId BIGINT, ShotCount INT, EventAt DATETIME2(3) (ET), OperationTypeCode NVARCHAR(20), ShiftLabel NVARCHAR(200) ('<ScheduleName> - MM/dd' or ''), Initials NVARCHAR(10)`.

- [ ] **Step 1: Write the failing test** -- `050_TrimCheckpoint_GetLatestForLot.sql` (header, fixture), then:

```sql
<shared declarations>

CREATE TABLE #R (ProductionEventId BIGINT, ShotCount INT, EventAt DATETIME2(3), OperationTypeCode NVARCHAR(20),
                 ShiftLabel NVARCHAR(200), Initials NVARCHAR(10));
INSERT INTO #R EXEC Workorder.TrimCheckpoint_GetLatestForLot @LotId = @L;
DECLARE @E NVARCHAR(10) = CAST((SELECT COUNT(*) FROM #R) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Latest] no trim checkpoint -> empty', @Expected = N'0', @Actual = @E;

DECLARE @Res TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 300,
    @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 700,
    @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;

DELETE FROM #R;
INSERT INTO #R EXEC Workorder.TrimCheckpoint_GetLatestForLot @LotId = @L;
DECLARE @Shot NVARCHAR(10) = CAST((SELECT ShotCount FROM #R) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Latest] returns the newest trim checkpoint (700)', @Expected = N'700', @Actual = @Shot;
DECLARE @Lbl NVARCHAR(10) = CASE WHEN (SELECT ShiftLabel FROM #R) LIKE N'TPC-FIXTURE-SCHED - __/__' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Latest] shift label "<schedule> - MM/dd"', @Expected = N'1', @Actual = @Lbl;
DECLARE @Ini NVARCHAR(10) = CASE WHEN (SELECT Initials FROM #R) IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Latest] carries initials', @Expected = N'1', @Actual = @Ini;
DROP TABLE #R;
GO
```

Then the shared cleanup + `EndTestFile`.

- [ ] **Step 2: Run to verify it fails** -- `.\sql\tests\Run-Tests.ps1 -Filter "0096"` -> 050 fails (proc missing).

- [ ] **Step 3: Write the proc**

```sql
-- ============================================================
-- Repeatable:  R__Workorder_TrimCheckpoint_GetLatestForLot.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: The LOT's newest TRIM checkpoint (TrimIn / TrimOut template), for
--              the "already recorded" line on the partial-trim popup and Trim OUT.
--              Empty result = no trim count recorded yet (read-proc convention:
--              no invented 404). EventAt returned ET. ShiftLabel matches
--              BlueRidge.Oee.Shift.getRecentOptions ('<Schedule> - MM/dd').
--              Spec 2026-09-22-trim-partial-shift-end-design.md sec 5.3.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.TrimCheckpoint_GetLatestForLot
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        pe.Id AS ProductionEventId,
        pe.ShotCount,
        CAST(pe.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventAt,
        oty.Code AS OperationTypeCode,
        ISNULL(ss.Name + N' - ' + FORMAT(s.ActualStart, N'MM/dd'), N'') AS ShiftLabel,
        u.Initials
    FROM Workorder.ProductionEvent pe
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
    INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
    INNER JOIN Location.AppUser u         ON u.Id = pe.AppUserId
    LEFT  JOIN Oee.Shift s                ON s.Id = pe.ShiftId
    LEFT  JOIN Oee.ShiftSchedule ss       ON ss.Id = s.ShiftScheduleId
    WHERE pe.LotId = @LotId AND pe.ShotCount IS NOT NULL
      AND oty.Code IN (N'TrimIn', N'TrimOut')
    ORDER BY pe.EventAt DESC, pe.Id DESC;
END;
GO
```

- [ ] **Step 4: Run** -- `.\sql\tests\Run-Tests.ps1 -Filter "0096"` -> 0 failures.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_TrimCheckpoint_GetLatestForLot.sql sql/tests/0096_Trim_Partial/050_TrimCheckpoint_GetLatestForLot.sql
git commit -m "feat(trim): TrimCheckpoint_GetLatestForLot read for the 'already recorded' line"
```

---

### Task 5: Core named queries + `BlueRidge.Workorder.TrimPartial`, applied to Dev

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/workorder/TrimPartial_Record/query.sql` + `resource.json`
- Create: `ignition/projects/Core/ignition/named-query/workorder/TrimCheckpoint_GetLatestForLot/query.sql` + `resource.json`
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/TrimPartial/code.py` + `resource.json`

**Interfaces:**
- Produces:
  - `BlueRidge.Workorder.TrimPartial.record(data, appUserId, terminalLocationId=None)` -> `{Status, Message, NewId}`; `data` keys `lotId, operationTemplateId, shotCount, scrapLines ([{defectCodeId, quantity}]), shiftId, sourceLocationId`.
  - `BlueRidge.Workorder.TrimPartial.getLatestCheckpoint(lotId, _refreshToken=None)` -> dict with keys `ProductionEventId, ShotCount, EventAt, OperationTypeCode, ShiftLabel, Initials` or `None`.
  - `BlueRidge.Workorder.TrimPartial.latestCheckpointLabel(lotId, _refreshToken=None)` -> `str`, `""` when none (binding-safe).

- [ ] **Step 1: Apply the SQL to Dev** (non-destructive; do NOT reset `MPP_MES_Dev`). Read the header of `sql/scripts/Update-Prod.ps1` to confirm it accepts a Dev target, then:

```bash
powershell -File sql/scripts/Update-Prod.ps1 -ServerInstance localhost -DatabaseName MPP_MES_Dev -Preview
```
Expected: lists `0096_trim_partial_checkpoint` pending plus the changed repeatables. Then rerun without `-Preview`. Verify:

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -Q "SELECT COL_LENGTH('Workorder.ProductionEvent','ShiftId') AS ShiftIdLen, OBJECT_ID('Workorder.TrimPartial_Record') AS P1, OBJECT_ID('Workorder.TrimCheckpoint_GetLatestForLot') AS P2"
```
Expected: `ShiftIdLen = 8`, both object ids non-NULL.

- [ ] **Step 2: Write `TrimPartial_Record/query.sql`**

```sql
EXEC Workorder.TrimPartial_Record
    @LotId               = :lotId,
    @OperationTemplateId = :operationTemplateId,
    @ShotCount           = :shotCount,
    @ScrapLinesJson      = :scrapLinesJson,
    @ShiftId             = :shiftId,
    @SourceLocationId    = :sourceLocationId,
    @AppUserId           = :appUserId,
    @TerminalLocationId  = :terminalLocationId
```

`resource.json`: copy `workorder/TrimOut_Record/resource.json` verbatim (`"type": "Query"`, `"database": "MPP"`), set `lastModification.timestamp` to `"2026-09-22T12:00:00Z"`, and replace `parameters` with:

```json
[
  {"type": "Parameter", "identifier": "lotId",               "sqlType": 3},
  {"type": "Parameter", "identifier": "operationTemplateId", "sqlType": 3},
  {"type": "Parameter", "identifier": "shotCount",           "sqlType": 2},
  {"type": "Parameter", "identifier": "scrapLinesJson",      "sqlType": 7},
  {"type": "Parameter", "identifier": "shiftId",             "sqlType": 3},
  {"type": "Parameter", "identifier": "sourceLocationId",    "sqlType": 3},
  {"type": "Parameter", "identifier": "appUserId",           "sqlType": 3},
  {"type": "Parameter", "identifier": "terminalLocationId",  "sqlType": 3}
]
```

- [ ] **Step 3: Write `TrimCheckpoint_GetLatestForLot/query.sql`**

```sql
EXEC Workorder.TrimCheckpoint_GetLatestForLot @LotId = :lotId
```

`resource.json`: same copy, `parameters` = `[{"type": "Parameter", "identifier": "lotId", "sqlType": 3}]`.

- [ ] **Step 4: Write the entity module** -- `BlueRidge/Workorder/TrimPartial/code.py`

```python
"""BlueRidge.Workorder.TrimPartial - thin access to the trim partial checkpoint.

   Wrappers only; every rule lives in Workorder.TrimPartial_Record.
   Spec docs/superpowers/specs/2026-09-22-trim-partial-shift-end-design.md."""


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def record(data, appUserId=None, terminalLocationId=None):
    """Partial trim at shift end: one cumulative checkpoint on the LOT, which
       stays where it is. data carries lotId, operationTemplateId (the route's
       TrimIn template), shotCount (TOTAL trimmed so far on the LOT), scrapLines
       (list of {defectCodeId, quantity}), shiftId (picked by the operator --
       never defaulted), sourceLocationId (the terminal's trim zone).
       Returns {Status, Message, NewId} (NewId = ProductionEventId)."""
    BlueRidge.Common.Util.log(
        "record data=%s appUserId=%s terminalLocationId=%s"
        % (data, appUserId, terminalLocationId)
    )
    d = _u(data) or {}
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    params = {
        "lotId":               d.get("lotId"),
        "operationTemplateId": d.get("operationTemplateId"),
        "shotCount":           d.get("shotCount"),
        "scrapLinesJson":      BlueRidge.Common.Util.convertWrapperObjectToJson(d.get("scrapLines") or []),
        "shiftId":             d.get("shiftId"),
        "sourceLocationId":    d.get("sourceLocationId"),
        "appUserId":           appUserId,
        "terminalLocationId":  terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("workorder/TrimPartial_Record", params)


def getLatestCheckpoint(lotId, _refreshToken=None):
    """The LOT's newest trim checkpoint as a dict, or None when there is none."""
    lotId = _u(lotId)
    if lotId in (None, ""):
        return None
    return BlueRidge.Common.Db.execOne("workorder/TrimCheckpoint_GetLatestForLot", {"lotId": lotId})


def latestCheckpointLabel(lotId, _refreshToken=None):
    """Binding source: 'Already recorded: 700 trimmed (2nd Shift - 09/21, JP)',
       or '' when the LOT has no trim count yet. Always a string."""
    r = getLatestCheckpoint(lotId)
    if not r or r.get("ShotCount") is None:
        return ""
    who = r.get("Initials") or "?"
    shift = r.get("ShiftLabel") or ""
    tail = ("%s, %s" % (shift, who)) if shift else who
    return "Already recorded: %s trimmed (%s)" % (r.get("ShotCount"), tail)
```

`resource.json`: copy `BlueRidge/Workorder/TrimOut/resource.json`, timestamp `"2026-09-22T12:00:00Z"`.

- [ ] **Step 5: Register and smoke the NQs.** Run `.\scan.ps1`. In the Designer Script Console (project MPP), pick a Dev LOT currently at a trim shop (`SELECT TOP 1 l.Id FROM Lots.Lot l JOIN Location.Location x ON x.Id = l.CurrentLocationId WHERE x.Code IN ('TRIM1','TRIM2')`; if none, check one in via the Trim IN screen first) and run:

```python
print BlueRidge.Workorder.TrimPartial.getLatestCheckpoint(<lotId>)
print repr(BlueRidge.Workorder.TrimPartial.latestCheckpointLabel(<lotId>))
```
Expected: `None` and `''` (no partial yet), and no "Named query not found" in the gateway log.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/workorder/TrimPartial_Record ignition/projects/Core/ignition/named-query/workorder/TrimCheckpoint_GetLatestForLot ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/TrimPartial
git commit -m "feat(trim): Core NQs + BlueRidge.Workorder.TrimPartial entity module"
```

---

### Task 6: Popup `Popups/TrimPartial` (new view)

**Files:**
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/TrimPartial/view.json`
- Create: `.../Popups/TrimPartial/resource.json`

**Interfaces:**
- Consumes: `TrimPartial.record`, `TrimPartial.latestCheckpointLabel` (Task 5); `BlueRidge.Oee.Shift.getRecentOptions()` -> `[{label, value}]`; `BlueRidge.Oee.Shift.labelFor(shiftId)` -> `str`; `BlueRidge.Parts.OperationTemplate.getActiveTemplateIdForLot(lotId, "TrimIn")`; `Components/PlantFloor/Numpad` (param `messageName`; sends page-scoped `{action: key|backspace|clear|enter, key}`).
- Produces: popup id `mpp-trim-partial`; params `lotId, lotName, pieceCount, scrapLines, scrapTotal`; on success sends page-scoped message `trimPartialRecorded` with `{lotId}` and closes itself.

- [ ] **Step 1: Write `resource.json`**

```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": [
    "view.json"
  ],
  "attributes": {
    "lastModificationSignature": "",
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-09-22T12:00:00Z"
    }
  }
}
```

- [ ] **Step 2: Write `view.json`**

```json
{
  "custom": {
    "qty": "",
    "shiftId": null,
    "shiftOptions": [],
    "lastLabel": "",
    "confirming": false,
    "confirmText": "",
    "busyUntil": 0
  },
  "params": {
    "lotId": null,
    "lotName": "",
    "pieceCount": null,
    "scrapLines": [],
    "scrapTotal": 0
  },
  "propConfig": {
    "params.lotId": {"paramDirection": "input"},
    "params.lotName": {"paramDirection": "input"},
    "params.pieceCount": {"paramDirection": "input"},
    "params.scrapLines": {"paramDirection": "input"},
    "params.scrapTotal": {"paramDirection": "input"},
    "custom.shiftOptions": {"binding": {"type": "expr", "config": {"expression": "runScript(\"BlueRidge.Oee.Shift.getRecentOptions\", 0)"}}},
    "custom.lastLabel": {"binding": {"type": "expr", "config": {"expression": "runScript(\"BlueRidge.Workorder.TrimPartial.latestCheckpointLabel\", 0, {view.params.lotId})"}}}
  },
  "props": {
    "defaultSize": {"height": 820, "width": 460}
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {"name": "root"},
    "props": {
      "direction": "column",
      "style": {"gap": "10px", "padding": "16px", "classes": "pf-inv-panel"}
    },
    "scripts": {
      "customMethods": [
        {
          "name": "review",
          "params": [],
          "script": "\traw = (\"%s\" % (self.view.custom.qty or \"\")).strip()\n\tif not raw.isdigit():\n\t\tBlueRidge.Common.Notify.toast(\"Count required\", \"Enter how many pieces of this LOT are trimmed so far.\", \"warning\")\n\t\treturn\n\tif self.view.custom.shiftId is None:\n\t\tBlueRidge.Common.Notify.toast(\"Shift required\", \"Choose the shift this work belongs to.\", \"warning\")\n\t\treturn\n\tlabel = BlueRidge.Oee.Shift.labelFor(self.view.custom.shiftId)\n\tscrap = BlueRidge.Common.Util.toIntOrNone(self.view.params.scrapTotal) or 0\n\ttail = (\" and %d scrap\" % scrap) if scrap else \"\"\n\tself.view.custom.confirmText = \"Record %s trimmed%s on %s under %s?\" % (int(raw), tail, self.view.params.lotName, label)\n\tself.view.custom.confirming = True"
        },
        {
          "name": "submit",
          "params": [],
          "script": "\tnowMs = system.date.toMillis(system.date.now())\n\tif nowMs < (self.view.custom.busyUntil or 0):\n\t\treturn\n\tself.view.custom.busyUntil = nowMs + 2000\n\tlotId = self.view.params.lotId\n\ttemplateId = BlueRidge.Parts.OperationTemplate.getActiveTemplateIdForLot(lotId, \"TrimIn\")\n\tif templateId is None:\n\t\tBlueRidge.Common.Notify.toast(\"Template missing\", \"This LOT's route has no active Trim IN step.\", \"error\")\n\t\treturn\n\tscrapLines = []\n\tfor r in (BlueRidge.Common.Util.extractQualifiedValues(self.view.params.scrapLines) or []):\n\t\tr = r or {}\n\t\tq = BlueRidge.Common.Util.toIntOrNone(r.get(\"quantity\"))\n\t\tif r.get(\"defectCodeId\") is not None and q:\n\t\t\tscrapLines.append({\"defectCodeId\": r.get(\"defectCodeId\"), \"quantity\": q})\n\tterm = self.session.custom.terminal\n\tdata = {\n\t\t\"lotId\": lotId,\n\t\t\"operationTemplateId\": templateId,\n\t\t\"shotCount\": int((\"%s\" % self.view.custom.qty).strip()),\n\t\t\"scrapLines\": scrapLines,\n\t\t\"shiftId\": self.view.custom.shiftId,\n\t\t\"sourceLocationId\": term.zoneLocationId if term else None,\n\t}\n\tres = BlueRidge.Workorder.TrimPartial.record(data, BlueRidge.Common.Session.currentAppUserId(self.session), (term.terminalLocationId if term else None))\n\tBlueRidge.Common.Ui.notifyResult(res, \"Partial trim recorded\")\n\tif res and res.get(\"Status\"):\n\t\tsystem.perspective.sendMessage(\"trimPartialRecorded\", payload={\"lotId\": lotId}, scope=\"page\")\n\t\tsystem.perspective.closePopup(\"mpp-trim-partial\")\n\telse:\n\t\tself.view.custom.confirming = False"
        }
      ],
      "extensionFunctions": null,
      "messageHandlers": [
        {
          "messageType": "trimPartialKeyPressed",
          "pageScope": true,
          "sessionScope": false,
          "viewScope": false,
          "script": "\ta = payload.get(\"action\") if payload else None\n\tq = self.view.custom.qty or \"\"\n\tself.view.custom.confirming = False\n\tif a == \"key\":\n\t\tif len(q) < 6:\n\t\t\tself.view.custom.qty = q + (\"%s\" % payload.get(\"key\"))\n\telif a == \"backspace\":\n\t\tself.view.custom.qty = q[:-1]\n\telif a == \"clear\":\n\t\tself.view.custom.qty = \"\"\n\telif a == \"enter\":\n\t\tself.review()"
        }
      ]
    },
    "children": [
      {
        "type": "ia.display.label",
        "meta": {"name": "Title"},
        "position": {"shrink": 0},
        "props": {"text": "Partial trim - shift end", "style": {"classes": "pf-inv-title"}}
      },
      {
        "type": "ia.display.label",
        "meta": {"name": "LotLine"},
        "position": {"shrink": 0},
        "props": {"style": {"classes": "pf-inv-sub"}},
        "propConfig": {
          "props.text": {"binding": {"type": "expr", "config": {"expression": "\"LOT \" + {view.params.lotName} + \" - \" + toStr({view.params.pieceCount}) + \" pcs on the LOT\""}}}
        }
      },
      {
        "type": "ia.display.label",
        "meta": {"name": "LastLine"},
        "position": {"shrink": 0},
        "props": {"style": {"classes": "pf-inv-sub"}},
        "propConfig": {
          "position.display": {"binding": {"type": "expr", "config": {"expression": "len({view.custom.lastLabel}) > 0"}}},
          "props.text": {"binding": {"type": "property", "config": {"path": "view.custom.lastLabel"}}}
        }
      },
      {
        "type": "ia.display.label",
        "meta": {"name": "QtyCaption"},
        "position": {"shrink": 0},
        "props": {"text": "Total trimmed so far on this LOT", "style": {"classes": "pf-inv-sub"}}
      },
      {
        "type": "ia.display.label",
        "meta": {"name": "QtyDisplay"},
        "position": {"shrink": 0},
        "props": {"style": {"classes": "pf-inv-qty", "fontSize": "34px", "padding": "6px 12px"}},
        "propConfig": {
          "props.text": {"binding": {"type": "expr", "config": {"expression": "if(len({view.custom.qty}) = 0, \"0\", {view.custom.qty})"}}}
        }
      },
      {
        "type": "ia.display.label",
        "meta": {"name": "ScrapLine"},
        "position": {"shrink": 0},
        "props": {"style": {"classes": "pf-inv-sub"}},
        "propConfig": {
          "position.display": {"binding": {"type": "expr", "config": {"expression": "toInt({view.params.scrapTotal}) > 0"}}},
          "props.text": {"binding": {"type": "expr", "config": {"expression": "\"Scrap from the Trim OUT form: \" + toStr({view.params.scrapTotal})"}}}
        }
      },
      {
        "type": "ia.display.view",
        "meta": {"name": "Numpad"},
        "position": {"basis": "424px", "shrink": 0},
        "props": {
          "path": "BlueRidge/Components/PlantFloor/Numpad",
          "params": {"messageName": "trimPartialKeyPressed"}
        }
      },
      {
        "type": "ia.input.dropdown",
        "meta": {"name": "ShiftPicker"},
        "position": {"shrink": 0},
        "props": {
          "placeholder": {"text": "Choose the shift this work belongs to"},
          "style": {"minHeight": "44px"}
        },
        "propConfig": {
          "props.options": {"binding": {"type": "property", "config": {"path": "view.custom.shiftOptions"}}},
          "props.value": {"binding": {"type": "property", "config": {"path": "view.custom.shiftId", "bidirectional": true}}}
        },
        "events": {"component": {"onActionPerformed": {"type": "script", "scope": "G",
          "config": {"script": "\tself.view.custom.confirming = False"}}}}
      },
      {
        "type": "ia.display.label",
        "meta": {"name": "ConfirmText"},
        "position": {"shrink": 0},
        "props": {"style": {"classes": "pf-inv-sub", "fontWeight": "bold"}},
        "propConfig": {
          "position.display": {"binding": {"type": "property", "config": {"path": "view.custom.confirming"}}},
          "props.text": {"binding": {"type": "property", "config": {"path": "view.custom.confirmText"}}}
        }
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "Buttons"},
        "position": {"shrink": 0},
        "props": {"style": {"gap": "10px"}},
        "children": [
          {
            "type": "ia.input.button",
            "meta": {"name": "Cancel"},
            "position": {"basis": "0", "grow": 1},
            "props": {"text": "Cancel", "style": {"classes": "pf-btn pf-btn-secondary", "minHeight": "44px"}},
            "events": {"component": {"onActionPerformed": {"type": "script", "scope": "G",
              "config": {"script": "\tsystem.perspective.closePopup(\"mpp-trim-partial\")"}}}}
          },
          {
            "type": "ia.input.button",
            "meta": {"name": "Review"},
            "position": {"basis": "0", "grow": 1},
            "props": {"text": "Next", "style": {"classes": "pf-btn pf-btn-primary", "minHeight": "44px"}},
            "propConfig": {
              "position.display": {"binding": {"type": "expr", "config": {"expression": "!{view.custom.confirming}"}}},
              "props.enabled": {"binding": {"type": "expr", "config": {"expression": "len({view.custom.qty}) > 0 && !isNull({view.custom.shiftId})"}}}
            },
            "events": {"component": {"onActionPerformed": {"type": "script", "scope": "G",
              "config": {"script": "\tself.view.rootContainer.review()"}}}}
          },
          {
            "type": "ia.input.button",
            "meta": {"name": "Confirm"},
            "position": {"basis": "0", "grow": 1},
            "props": {"text": "Record", "style": {"classes": "pf-btn pf-btn-primary", "minHeight": "44px"}},
            "propConfig": {
              "position.display": {"binding": {"type": "property", "config": {"path": "view.custom.confirming"}}},
              "props.enabled": {"binding": {"type": "expr", "config": {"expression": "toMillis(now(500)) > {view.custom.busyUntil}"}}}
            },
            "events": {"component": {"onActionPerformed": {"type": "script", "scope": "G",
              "config": {"script": "\tself.view.rootContainer.submit()"}}}}
          }
        ]
      }
    ]
  }
}
```

Notes: the shift picker has **no default** (`custom.shiftId: null`) -- D6; changing count or shift drops back out of the confirm step so the confirmation always reads what will be written; Record is the second deliberate tap. `BlueRidge.Common.Session.currentAppUserId(self.session)` is the attribution helper (CLAUDE.md, 2026-09-18).

- [ ] **Step 3: Validate and register**

Run: `python -c "import json;json.load(open(r'ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/TrimPartial/view.json',encoding='utf-8'));print('ok')"` -> `ok`.
Run a byte scan: `python -c "d=open(r'ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/TrimPartial/view.json','rb').read();print([b for b in d if b>127][:5])"` -> `[]` (ASCII only).
Run: `.\scan.ps1`.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/TrimPartial
git commit -m "feat(trim): TrimPartial popup -- numpad count, forced shift pick, confirm step"
```

---

### Task 7: TrimBody wiring (Designer edit)

**Files:**
- Modify (in the Designer, project MPP): `Views/ShopFloor/TrimBody`

**Interfaces:**
- Consumes: popup `BlueRidge/Components/Popups/TrimPartial` + message `trimPartialRecorded` (Task 6); `TrimPartial.latestCheckpointLabel` (Task 5).

This view is existing, so edit in the Designer (file edits race the Designer cache and fight its unicode escapes). Paste the scripts exactly; each script body starts with a tab.

- [ ] **Step 1: Add the root custom method `openTrimPartial`** (root -> Configure Scripts -> Custom Methods, no params):

```python
	lotId = self.view.custom.activeLotId
	if not lotId:
		BlueRidge.Common.Notify.toast("No LOT", "Select the LOT on the press first.", "warning")
		return
	system.perspective.openPopup(
		"mpp-trim-partial",
		"BlueRidge/Components/Popups/TrimPartial",
		params={
			"lotId": lotId,
			"lotName": self.view.custom.activeLotName,
			"pieceCount": self.view.custom.lotPieceCount,
			"scrapLines": BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.scrapLines) or [],
			"scrapTotal": self.view.custom.scrapTotal or 0,
		},
		modal=True, showCloseIcon=False, overlayDismiss=False)
```

- [ ] **Step 2: Add the root message handler `trimPartialRecorded`** (page scope ticked, session/view unticked):

```python
	self.view.custom.activeLotId = None
	self.view.custom.activeLotName = None
	self.view.custom.outScan = ""
	self.view.custom.shotCount = None
	self.view.custom.lotPieceCount = None
	self.view.custom.scrapLines = []
	self.view.custom.refreshToken = (self.view.custom.refreshToken or 0) + 1
	self.refreshScrapUi()
```

(The LOT stays in the trim list; the operator's selection clears so the next shift starts clean. `refreshToken` re-reads the list, which now shows the decremented piece count.)

- [ ] **Step 3: Add the button.** In `OutPanel/OutColumns/OutFormCol/CountsRow/ScrapLinesCol/OutActions`, add an `ia.input.button` named `BtnTrimPartial` **before** `BtnTrimOut`:
  - `props.text`: `Record partial trim - shift end`
  - `props.style.classes`: `pf-btn pf-btn-secondary pf-btn-large`; `props.style.minHeight`: `44px`; `props.style.minWidth`: `160px`
  - `props.enabled` expression binding: `!isNull({view.custom.activeLotId}) && toStr({view.custom.activeLotId}) != ""`
  - `onActionPerformed` script (scope Gateway): `	self.view.rootContainer.openTrimPartial()`

- [ ] **Step 4: Add the "already recorded" line.** In `OutScanField/ScanCol`, below `ActiveLotLabel`, add an `ia.display.label` named `LastPartialLabel`:
  - `props.style.classes`: `pf-inv-sub`
  - `props.text` expression binding: `runScript("BlueRidge.Workorder.TrimPartial.latestCheckpointLabel", 0, {view.custom.activeLotId}, {view.custom.refreshToken})`
  - `position.display` expression binding: `len({this.props.text}) > 0`

- [ ] **Step 5: Save, then check the file.** Save in the Designer. Then:

Run: `git diff --stat -- ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/TrimBody/view.json`
Expected: one file, a modest insertion count (no thousands of lines, which would mean live data got pickled into the view -- if so, clear `trimInventory`/`defectCodeTiles` custom values back to `[]` in the Designer and re-save).
Run: `grep -c "BtnTrimPartial\|LastPartialLabel\|openTrimPartial\|trimPartialRecorded" ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/TrimBody/view.json` -> `4` or more.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/TrimBody/view.json
git commit -m "feat(trim): 'Record partial trim - shift end' button + already-recorded line on Trim OUT"
```

---

### Task 8: End-to-end smoke on Dev + docs

**Files:**
- Modify: `MPP_MES_DATA_MODEL.md` (ProductionEvent table + Revision History), `PROJECT_STATUS.md` (append-only)

- [ ] **Step 1: Smoke on the trim terminal** (browser at the MPP trim screen, Dev gateway):
  1. Sign in by PIN. Trim IN a LOT (or use one already in trim). Note its piece count N.
  2. Trim OUT tab -> select the LOT card -> add one scrap tile (1 pc) -> **Record partial trim - shift end**.
  3. Popup: confirm the shift picker shows nothing selected and **Next** is disabled; type `100`; pick the previous shift; **Next** -> the confirmation reads `Record 100 trimmed and 1 scrap on <LOT> under <shift>?`; **Record**.
  4. Expect the toast `Partial trim recorded`, the popup closes, the LOT card is still listed with N-1 pieces.
  5. Select the LOT again -> `Already recorded: 100 trimmed (<shift>, <initials>)` shows under the LOT.
  6. **Trim OUT** it. Then verify in SQL:

```sql
SELECT pe.Id, oty.Code, pe.ShotCount, pe.ShiftId,
       pe.ShotCount - ISNULL(LAG(pe.ShotCount) OVER (ORDER BY pe.EventAt, pe.Id), 0) AS Credit
FROM Workorder.ProductionEvent pe
JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE pe.LotId = <lotId> AND oty.Code IN ('TrimIn','TrimOut')
ORDER BY pe.EventAt, pe.Id;
```
Expected: two rows -- `TrimIn 100 <picked shift> 100`, `TrimOut N-1 <resolved shift> N-101`.

- [ ] **Step 2: Data model doc.** In `MPP_MES_DATA_MODEL.md` § ProductionEvent, add a row after `Remarks`:

```markdown
| ShiftId | BIGINT | FK → Oee.Shift.Id, NULL | **Added migration `0096` (2026-09-22) -- trim partial checkpoint.** The shift this checkpoint is credited to: the operator's picked shift on `Workorder.TrimPartial_Record` (never defaulted), `Oee.ufn_ShiftIdForInstant` at the trim shop on `Workorder.TrimOut_Record` v1.5. NULL on older rows and other writers. Trim credit per shift = `ShotCount` minus the previous **trim** checkpoint (TrimIn/TrimOut templates) on the LOT. |
```

and add a Revision History row at the top of that table:

```markdown
| 2.5 | 2026-09-22 | Blue Ridge Automation | **Trim partial checkpoint (migration `0096`).** `Workorder.ProductionEvent.ShiftId` added. A blast operator can record the total trimmed so far on the LOT at shift end (`Workorder.TrimPartial_Record`, route `TrimIn` template, LOT does not move); Trim OUT is unchanged for the operator and now stamps the shift. Spec `docs/superpowers/specs/2026-09-22-trim-partial-shift-end-design.md`. |
```

(Use the next version number after the table's current top row if `2.5` is taken.)

- [ ] **Step 3: PROJECT_STATUS.md** -- append (do not rewrite) a short entry under the current status section: what shipped (0096, TrimPartial_Record, TrimOut v1.5, popup, TrimBody button), that it is Dev-only until a prod release, and that the Trim Shop Detail report / credit rollup read is the natural follow-up.

- [ ] **Step 4: Regenerate the docx and commit**

```bash
pandoc MPP_MES_DATA_MODEL.md -o MPP_MES_DATA_MODEL.docx --reference-doc=reference.docx && node style_docx_tables.js MPP_MES_DATA_MODEL.docx
git add MPP_MES_DATA_MODEL.md MPP_MES_DATA_MODEL.docx PROJECT_STATUS.md docs/superpowers/specs/2026-09-22-trim-partial-shift-end-design.md
git commit -m "docs(trim): data model + status for the trim partial checkpoint"
```

---

## Out of scope (from the spec)

- Trim Shop Detail report / credit rollup read (spec § 3.2 is its contract).
- Any change at the tumblers or to Trim IN.
- Backfilling `ShiftId`.
- Correcting a mis-filed partial (trim follow-up of shift reconciliation).
- The prod release (preview / rehearsal / execute / scoped exports / runbook) -- a separate step once Jacques decides to ship.
