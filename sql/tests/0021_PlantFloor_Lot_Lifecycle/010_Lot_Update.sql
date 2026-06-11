-- =============================================
-- File:         0021_PlantFloor_Lot_Lifecycle/010_Lot_Update.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-11
-- Description:  Tests for Lots.Lot_Update (Phase 2 Task 1 / G1). Asserts:
--                 - PieceCount change succeeds: Status=1, Lot.PieceCount
--                   updated, B5 InventoryAvailable recomputed, and exactly one
--                   LotAttributeChange row written for PieceCount.
--                 - Stale @RowVersion rejected (Status=0) without mutating.
--                 - No-change call is a clean no-op (Status=1, no new change
--                   rows).
--                 - Blocked (Hold) LOT rejected (Status=0, message mentions
--                   blocked).
--
--               Fixtures use a NON-DieCast 'Received' origin on an eligible
--               (Item, Cell) pair with NO active ToolAssignment, so no Tool /
--               Cavity setup is required. Fixture LOTs carry the standard
--               MESL%% LotName (Lot_Create auto-mints); cleanup is scoped to the
--               specific NewId values created here so other suites' MESL LOTs
--               are untouched.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/010_Lot_Update.sql';
GO

-- ---- shared fixtures: three throwaway LOTs (Received origin, no Tool) ----
-- LOT A: PieceCount-change + no-op tests. LOT B: stale-RowVersion test.
-- LOT C: blocked (Hold) test. Track their ids in a persistent temp table so
-- later batches (separated by GO) can resolve them, then clean up FK-safe.
IF OBJECT_ID(N'tempdb..#UpdFix') IS NOT NULL DROP TABLE #UpdFix;
CREATE TABLE #UpdFix (Slot NVARCHAR(1) PRIMARY KEY, LotId BIGINT);
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- LOT A
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 100, @AppUserId = 1;
INSERT INTO #UpdFix (Slot, LotId) VALUES (N'A', (SELECT NewId FROM @cr));

-- LOT B
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 100, @AppUserId = 1;
INSERT INTO #UpdFix (Slot, LotId) VALUES (N'B', (SELECT NewId FROM @cr));

-- LOT C (will be forced to Hold below)
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 100, @AppUserId = 1;
INSERT INTO #UpdFix (Slot, LotId) VALUES (N'C', (SELECT NewId FROM @cr));
GO

-- =============================================
-- Test 1: PieceCount change succeeds + writes one LotAttributeChange row
--         + recomputes B5 InventoryAvailable.
-- =============================================
DECLARE @LotId BIGINT = (SELECT LotId FROM #UpdFix WHERE Slot = N'A');
DECLARE @r TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @r EXEC Lots.Lot_Update @LotId = @LotId, @PieceCount = 80, @AppUserId = 1;

DECLARE @ok BIT = (SELECT Status FROM @r);
EXEC test.Assert_IsTrue @TestName = N'[LotUpdate] PieceCount update succeeds', @Condition = @ok;

DECLARE @pc INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);
DECLARE @pcStr NVARCHAR(20) = CAST(@pc AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[LotUpdate] PieceCount now 80',
    @Expected = N'80', @Actual = @pcStr;

DECLARE @inv INT = (SELECT InventoryAvailable FROM Lots.Lot WHERE Id = @LotId);
DECLARE @invStr NVARCHAR(20) = CAST(@inv AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[LotUpdate] InventoryAvailable recomputed to 80 (B5)',
    @Expected = N'80', @Actual = @invStr;

DECLARE @chg INT = (SELECT COUNT(*) FROM Lots.LotAttributeChange
                    WHERE LotId = @LotId AND AttributeName = N'PieceCount');
EXEC test.Assert_RowCount @TestName = N'[LotUpdate] one PieceCount change row',
    @ExpectedCount = 1, @ActualCount = @chg;
GO

-- =============================================
-- Test 2: stale @RowVersion rejected (Status=0); no mutation occurs.
-- =============================================
DECLARE @LotId BIGINT = (SELECT LotId FROM #UpdFix WHERE Slot = N'B');
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @r2 EXEC Lots.Lot_Update @LotId = @LotId, @PieceCount = 70,
    @RowVersion = 0x0000000000000001, @AppUserId = 1;

DECLARE @s2 BIT = (SELECT Status FROM @r2);
DECLARE @s2cond BIT = CASE WHEN @s2 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[LotUpdate] stale RowVersion rejected', @Condition = @s2cond;

DECLARE @pc2 INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);
DECLARE @pc2Str NVARCHAR(20) = CAST(@pc2 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[LotUpdate] PieceCount unchanged after stale-RowVersion reject',
    @Expected = N'100', @Actual = @pc2Str;
GO

-- =============================================
-- Test 3: no-change call is a clean no-op (Status=1, no new change rows).
--         LOT A is already at PieceCount=80 from Test 1, with one change row.
-- =============================================
DECLARE @LotId BIGINT = (SELECT LotId FROM #UpdFix WHERE Slot = N'A');
DECLARE @before INT = (SELECT COUNT(*) FROM Lots.LotAttributeChange WHERE LotId = @LotId);
DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500));
-- Re-send the current value (80) + the other three fields NULL -> nothing differs.
INSERT INTO @r3 EXEC Lots.Lot_Update @LotId = @LotId, @PieceCount = 80, @AppUserId = 1;

DECLARE @s3 BIT = (SELECT Status FROM @r3);
EXEC test.Assert_IsTrue @TestName = N'[LotUpdate] no-change call is a clean no-op (Status=1)', @Condition = @s3;

DECLARE @after INT = (SELECT COUNT(*) FROM Lots.LotAttributeChange WHERE LotId = @LotId);
DECLARE @beforeStr NVARCHAR(20) = CAST(@before AS NVARCHAR(20));
DECLARE @afterStr  NVARCHAR(20) = CAST(@after AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[LotUpdate] no-op writes zero new change rows',
    @Expected = @beforeStr, @Actual = @afterStr;
GO

-- =============================================
-- Test 4: blocked (Hold) LOT rejected (Status=0, message mentions blocked).
-- =============================================
DECLARE @LotId BIGINT = (SELECT LotId FROM #UpdFix WHERE Slot = N'C');
DECLARE @HoldId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
UPDATE Lots.Lot SET LotStatusId = @HoldId WHERE Id = @LotId;

DECLARE @r4 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @r4 EXEC Lots.Lot_Update @LotId = @LotId, @PieceCount = 50, @AppUserId = 1;

DECLARE @s4 BIT = (SELECT Status FROM @r4);
DECLARE @s4cond BIT = CASE WHEN @s4 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[LotUpdate] blocked (Hold) LOT rejected', @Condition = @s4cond;

DECLARE @msg4 NVARCHAR(500) = (SELECT Message FROM @r4);
EXEC test.Assert_Contains @TestName = N'[LotUpdate] reject message mentions blocked',
    @HaystackStr = @msg4, @NeedleStr = N'blocked';
GO

-- ---- cleanup (FK-safe: child rows -> LOTs) ----
-- Audit.OperationLog / Audit.FailureLog have NO FK to Lots.Lot (EntityId is a
-- bare BIGINT) and attribute to AppUser, so they do not block LOT deletion and
-- are left for the reset to drop. Delete only the genuine FK-children here.
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT LotId FROM #UpdFix;

DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);

IF OBJECT_ID(N'tempdb..#UpdFix') IS NOT NULL DROP TABLE #UpdFix;
GO

EXEC test.EndTestFile;
GO
