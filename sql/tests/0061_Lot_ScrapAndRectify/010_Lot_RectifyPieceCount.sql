-- =============================================
-- File:         0061_Lot_ScrapAndRectify/010_Lot_RectifyPieceCount.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-19
-- Description:  Tests for Lots.Lot_RectifyPieceCount (backlog 5.3 -- LOT Detail
--               count correction with a MANDATORY reason). Asserts:
--                 - a blank / NULL reason is rejected BEFORE any mutation
--                 - a valid correction succeeds, moves PieceCount, moves
--                   InventoryAvailable by the SAME delta, and writes exactly one
--                   Lots.LotAttributeChange row carrying the Reason (0060)
--                 - the reason lands in the LotEventLog audit NewValue JSON
--                 - a correction below the pieces already consumed is rejected
--                 - <= 0 is rejected (scrap/void the LOT instead)
--                 - a no-change correction is rejected as a no-op
--                 - a blocked (Hold) LOT is rejected
--
--               Fixtures use a NON-DieCast 'Received' origin on an eligible
--               (Item, Cell) pair with NO active ToolAssignment, so no Tool /
--               Cavity setup is required (mirrors 0021/010_Lot_Update.sql).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0061_Lot_ScrapAndRectify/010_Lot_RectifyPieceCount.sql';
GO

IF OBJECT_ID(N'tempdb..#RectFix') IS NOT NULL DROP TABLE #RectFix;
CREATE TABLE #RectFix (Slot NVARCHAR(1) PRIMARY KEY, LotId BIGINT);
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- LOT A: happy path + reason assertions.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 100, @AppUserId = 1;
INSERT INTO #RectFix (Slot, LotId) VALUES (N'A', (SELECT NewId FROM @cr));

-- LOT B: consumed-below guard + <=0 guard + no-change guard.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 100, @AppUserId = 1;
INSERT INTO #RectFix (Slot, LotId) VALUES (N'B', (SELECT NewId FROM @cr));

-- LOT C: blocked (Hold) test.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 100, @AppUserId = 1;
INSERT INTO #RectFix (Slot, LotId) VALUES (N'C', (SELECT NewId FROM @cr));
GO

-- =============================================
-- Test 1: blank reason rejected, nothing mutated.
-- =============================================
DECLARE @LotA BIGINT = (SELECT LotId FROM #RectFix WHERE Slot = N'A');
DECLARE @r1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r1 EXEC Lots.Lot_RectifyPieceCount
    @LotId = @LotA, @NewPieceCount = 80, @Reason = N'   ', @AppUserId = 1;

DECLARE @s1 BIT = (SELECT CASE WHEN Status = 0 THEN 1 ELSE 0 END FROM @r1);
EXEC test.Assert_IsTrue @TestName = N'[Rectify] blank reason rejected', @Condition = @s1;

DECLARE @m1 NVARCHAR(500) = (SELECT Message FROM @r1);
EXEC test.Assert_Contains @TestName = N'[Rectify] blank-reason message mentions reason',
    @HaystackStr = @m1, @NeedleStr = N'reason is required';

DECLARE @pcA INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotA);
DECLARE @pcAStr NVARCHAR(20) = CAST(@pcA AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Rectify] blank reason did not mutate PieceCount',
    @Expected = N'100', @Actual = @pcAStr;
GO

-- =============================================
-- Test 2: valid correction succeeds; PieceCount + InventoryAvailable move by the
--         same delta; one LotAttributeChange row carries the Reason.
-- =============================================
DECLARE @LotA BIGINT = (SELECT LotId FROM #RectFix WHERE Slot = N'A');
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r2 EXEC Lots.Lot_RectifyPieceCount
    @LotId = @LotA, @NewPieceCount = 80, @Reason = N'Miskeyed at die cast entry', @AppUserId = 1;

DECLARE @s2 BIT = (SELECT Status FROM @r2);
EXEC test.Assert_IsTrue @TestName = N'[Rectify] valid correction succeeds', @Condition = @s2;

DECLARE @pc2 INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotA);
DECLARE @pc2Str NVARCHAR(20) = CAST(@pc2 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Rectify] PieceCount corrected to 80',
    @Expected = N'80', @Actual = @pc2Str;

DECLARE @ia2 INT = (SELECT InventoryAvailable FROM Lots.Lot WHERE Id = @LotA);
DECLARE @ia2Str NVARCHAR(20) = CAST(@ia2 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Rectify] InventoryAvailable moved by the same delta',
    @Expected = N'80', @Actual = @ia2Str;

DECLARE @ac2 INT = (SELECT COUNT(*) FROM Lots.LotAttributeChange
                    WHERE LotId = @LotA AND AttributeName = N'PieceCount');
EXEC test.Assert_RowCount @TestName = N'[Rectify] exactly one LotAttributeChange row',
    @ExpectedCount = 1, @ActualCount = @ac2;

DECLARE @rsn2 NVARCHAR(500) = (SELECT TOP 1 Reason FROM Lots.LotAttributeChange
                               WHERE LotId = @LotA ORDER BY Id DESC);
EXEC test.Assert_IsEqual @TestName = N'[Rectify] reason stored on LotAttributeChange',
    @Expected = N'Miskeyed at die cast entry', @Actual = @rsn2;
GO

-- =============================================
-- Test 3: the reason reaches the 20-yr LOT audit log (B7 routing: 'Lot' events
--         with a non-NULL EntityId land in Lots.LotEventLog).
-- =============================================
DECLARE @LotA BIGINT = (SELECT LotId FROM #RectFix WHERE Slot = N'A');
DECLARE @EvtId BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'LotUpdated');
DECLARE @nv3 NVARCHAR(MAX) = (SELECT TOP 1 NewValue FROM Lots.LotEventLog
                              WHERE LotId = @LotA AND LogEventTypeId = @EvtId ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[Rectify] audit NewValue carries the reason',
    @HaystackStr = @nv3, @NeedleStr = N'Miskeyed at die cast entry';

DECLARE @desc3 NVARCHAR(500) = (SELECT TOP 1 Description FROM Lots.LotEventLog
                                WHERE LotId = @LotA AND LogEventTypeId = @EvtId ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[Rectify] audit Description uses the Rectify category',
    @HaystackStr = @desc3, @NeedleStr = N'Rectify';
GO

-- =============================================
-- Test 4: correcting BELOW the pieces already consumed is rejected.
--         LOT B: draw 30 pieces out of availability to simulate consumption.
-- =============================================
DECLARE @LotB BIGINT = (SELECT LotId FROM #RectFix WHERE Slot = N'B');
UPDATE Lots.Lot SET InventoryAvailable = 70 WHERE Id = @LotB;   -- 30 consumed of 100

DECLARE @r4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r4 EXEC Lots.Lot_RectifyPieceCount
    @LotId = @LotB, @NewPieceCount = 20, @Reason = N'Recount', @AppUserId = 1;

DECLARE @s4 BIT = (SELECT CASE WHEN Status = 0 THEN 1 ELSE 0 END FROM @r4);
EXEC test.Assert_IsTrue @TestName = N'[Rectify] below-consumed correction rejected', @Condition = @s4;

DECLARE @m4 NVARCHAR(500) = (SELECT Message FROM @r4);
EXEC test.Assert_Contains @TestName = N'[Rectify] below-consumed message mentions consumed',
    @HaystackStr = @m4, @NeedleStr = N'already consumed';

DECLARE @pc4 INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotB);
DECLARE @pc4Str NVARCHAR(20) = CAST(@pc4 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Rectify] below-consumed rejection did not mutate',
    @Expected = N'100', @Actual = @pc4Str;
GO

-- =============================================
-- Test 5: <= 0 rejected (scrap or void the LOT instead) + no-change rejected.
-- =============================================
DECLARE @LotB BIGINT = (SELECT LotId FROM #RectFix WHERE Slot = N'B');
DECLARE @r5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r5 EXEC Lots.Lot_RectifyPieceCount
    @LotId = @LotB, @NewPieceCount = 0, @Reason = N'Empty basket', @AppUserId = 1;
DECLARE @s5 BIT = (SELECT CASE WHEN Status = 0 THEN 1 ELSE 0 END FROM @r5);
EXEC test.Assert_IsTrue @TestName = N'[Rectify] zero piece count rejected', @Condition = @s5;

DECLARE @r5b TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r5b EXEC Lots.Lot_RectifyPieceCount
    @LotId = @LotB, @NewPieceCount = 100, @Reason = N'Same value', @AppUserId = 1;
DECLARE @s5b BIT = (SELECT CASE WHEN Status = 0 THEN 1 ELSE 0 END FROM @r5b);
EXEC test.Assert_IsTrue @TestName = N'[Rectify] no-change correction rejected', @Condition = @s5b;

DECLARE @m5b NVARCHAR(500) = (SELECT Message FROM @r5b);
EXEC test.Assert_Contains @TestName = N'[Rectify] no-change message says nothing to rectify',
    @HaystackStr = @m5b, @NeedleStr = N'nothing to rectify';
GO

-- =============================================
-- Test 6: blocked (Hold) LOT rejected.
-- =============================================
DECLARE @LotC BIGINT = (SELECT LotId FROM #RectFix WHERE Slot = N'C');
DECLARE @HoldStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
UPDATE Lots.Lot SET LotStatusId = @HoldStatusId WHERE Id = @LotC;

DECLARE @r6 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r6 EXEC Lots.Lot_RectifyPieceCount
    @LotId = @LotC, @NewPieceCount = 90, @Reason = N'Recount', @AppUserId = 1;

DECLARE @s6 BIT = (SELECT CASE WHEN Status = 0 THEN 1 ELSE 0 END FROM @r6);
EXEC test.Assert_IsTrue @TestName = N'[Rectify] blocked (Hold) LOT rejected', @Condition = @s6;

DECLARE @m6 NVARCHAR(500) = (SELECT Message FROM @r6);
EXEC test.Assert_Contains @TestName = N'[Rectify] blocked message mentions the hold',
    @HaystackStr = @m6, @NeedleStr = N'release the hold';
GO

-- =============================================
-- Test 7: the reason surfaces in the LOT history timeline (stream 1, v1.4).
-- =============================================
DECLARE @LotA BIGINT = (SELECT LotId FROM #RectFix WHERE Slot = N'A');
IF OBJECT_ID(N'tempdb..#Hist') IS NOT NULL DROP TABLE #Hist;
CREATE TABLE #Hist (EventAt DATETIME2(3), EventKind NVARCHAR(20), Detail NVARCHAR(500),
                    ByUserId BIGINT, ByUserName NVARCHAR(200));
INSERT INTO #Hist EXEC Lots.Lot_GetAttributeHistory @LotId = @LotA;

DECLARE @det7 NVARCHAR(500) = (SELECT TOP 1 Detail FROM #Hist WHERE EventKind = N'Attribute');
EXEC test.Assert_Contains @TestName = N'[Rectify] history Detail carries the reason',
    @HaystackStr = @det7, @NeedleStr = N'(Miskeyed at die cast entry)';
DROP TABLE #Hist;
GO

-- ---- cleanup (FK-safe: child rows -> LOTs) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT LotId FROM #RectFix;

DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);

IF OBJECT_ID(N'tempdb..#RectFix') IS NOT NULL DROP TABLE #RectFix;
GO

EXEC test.EndTestFile;
GO
