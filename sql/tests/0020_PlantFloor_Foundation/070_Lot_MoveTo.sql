-- =============================================
-- File:         0020_PlantFloor_Foundation/070_Lot_MoveTo.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-09
-- Description:  Tests for Lots.Lot_MoveTo.
--                 - valid move updates CurrentLocationId + inserts LotMovement
--                 - move of a blocked (Hold) lot rejects (B2 guard)
--                 - move to a non-existent location rejects
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/070_Lot_MoveTo.sql';
GO

-- ---- fixture: two lots (one stays Good, one flipped to Hold) ----
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';

DECLARE @ItemId BIGINT, @CellId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
CREATE TABLE #mk (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #mk EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=8, @AppUserId=1;  -- stays Good
INSERT INTO #mk EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=8, @AppUserId=1;  -- will flip to Hold
DROP TABLE #mk;

-- flip the second (highest-id) lot to Hold directly
DECLARE @HoldId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
UPDATE Lots.Lot SET LotStatusId = @HoldId WHERE Id = (SELECT MAX(Id) FROM Lots.Lot WHERE LotName LIKE N'MESL%');
GO

-- =============================================
-- Test 1: valid move (Good lot) updates CurrentLocationId + inserts LotMovement
-- =============================================
DECLARE @GoodLot BIGINT = (SELECT MIN(Id) FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DECLARE @FromLoc BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @GoodLot);
DECLARE @ToLoc   BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL AND Id <> @FromLoc ORDER BY Id);
DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #m1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #m1 EXEC Lots.Lot_MoveTo @LotId=@GoodLot, @ToLocationId=@ToLoc, @AppUserId=1;
SELECT @S = Status FROM #m1;
DROP TABLE #m1;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[MoveValid] Move succeeds', @Expected = N'1', @Actual = @SStr;

DECLARE @NowAt NVARCHAR(1) = (SELECT CASE WHEN CurrentLocationId = @ToLoc THEN N'1' ELSE N'0' END FROM Lots.Lot WHERE Id = @GoodLot);
EXEC test.Assert_IsEqual @TestName = N'[MoveValid] CurrentLocationId updated', @Expected = N'1', @Actual = @NowAt;

DECLARE @MoveCnt INT = (SELECT COUNT(*) FROM Lots.LotMovement WHERE LotId = @GoodLot AND ToLocationId = @ToLoc AND FromLocationId = @FromLoc);
DECLARE @MoveStr NVARCHAR(10) = CAST(@MoveCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MoveValid] LotMovement row inserted (From=prior, To=new)', @Expected = N'1', @Actual = @MoveStr;
GO

-- =============================================
-- Test 2: move of a blocked (Hold) lot rejects (B2 guard)
-- =============================================
DECLARE @HoldLot BIGINT = (SELECT MAX(Id) FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DECLARE @FromLoc BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @HoldLot);
DECLARE @ToLoc   BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL AND Id <> @FromLoc ORDER BY Id);
DECLARE @S BIT, @SStr NVARCHAR(1), @M NVARCHAR(500);
CREATE TABLE #m2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #m2 EXEC Lots.Lot_MoveTo @LotId=@HoldLot, @ToLocationId=@ToLoc, @AppUserId=1;
SELECT @S = Status, @M = Message FROM #m2;
DROP TABLE #m2;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[MoveBlocked] Move of Hold lot rejected', @Expected = N'0', @Actual = @SStr;
EXEC test.Assert_Contains @TestName = N'[MoveBlocked] Message names the Hold status', @HaystackStr = @M, @NeedleStr = N'Hold';
GO

-- =============================================
-- Test 3: move to a non-existent location rejects
-- =============================================
DECLARE @GoodLot BIGINT = (SELECT MIN(Id) FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #m3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #m3 EXEC Lots.Lot_MoveTo @LotId=@GoodLot, @ToLocationId=9999999999, @AppUserId=1;
SELECT @S = Status FROM #m3;
DROP TABLE #m3;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[MoveBadLoc] Move to non-existent location rejected', @Expected = N'0', @Actual = @SStr;
GO

-- ---- cleanup ----
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

EXEC test.EndTestFile;
GO
