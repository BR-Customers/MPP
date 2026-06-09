-- =============================================
-- File:         0020_PlantFloor_Foundation/060_Lot_UpdateStatus.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-09
-- Description:  Tests for Lots.Lot_UpdateStatus.
--                 - valid Good -> Closed applies + writes LotStatusHistory
--                 - stale @RowVersion rejects
--                 - no-op (new = current) rejects
--                 - invalid target (Good -> Hold, not allowed Phase 1) rejects
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/060_Lot_UpdateStatus.sql';
GO

-- =============================================
-- Guard: IX_Lot_Active (0020 Section B) hardcodes WHERE LotStatusId IN (1, 2)
-- (Good, Hold) - filtered-index literals are forced and cannot reference the
-- code-table. Assert the seeded ids have not drifted so any reseed that breaks
-- the "active lots" index coverage fails the suite loudly.
-- =============================================
DECLARE @GoodIdStr NVARCHAR(20) = CAST((SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good') AS NVARCHAR(20));
DECLARE @HoldIdStr NVARCHAR(20) = CAST((SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold') AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[StatIdGuard] LotStatusCode Good id = 1 (IX_Lot_Active literal)', @Expected = N'1', @Actual = @GoodIdStr;
EXEC test.Assert_IsEqual @TestName = N'[StatIdGuard] LotStatusCode Hold id = 2 (IX_Lot_Active literal)', @Expected = N'2', @Actual = @HoldIdStr;
GO

-- ---- fixture: one Good lot via Lot_Create ----
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';

DECLARE @ItemId BIGINT, @CellId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
CREATE TABLE #mk (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #mk EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=8, @AppUserId=1;
DROP TABLE #mk;
GO

-- =============================================
-- Test 1: stale @RowVersion rejects
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @BadVer BINARY(8) = 0x0000000000000001;
DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #s1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #s1 EXEC Lots.Lot_UpdateStatus @LotId=@LotId, @NewLotStatusId=@Closed, @AppUserId=1, @RowVersion=@BadVer;
SELECT @S = Status FROM #s1;
DROP TABLE #s1;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[StatStale] Stale RowVersion rejects', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 2: invalid target (Good -> Hold) rejects (Phase 1 only Good->Closed)
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @Hold BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #s2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #s2 EXEC Lots.Lot_UpdateStatus @LotId=@LotId, @NewLotStatusId=@Hold, @AppUserId=1;
SELECT @S = Status FROM #s2;
DROP TABLE #s2;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[StatBadTarget] Good->Hold rejected in Phase 1', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 3: no-op (Good -> Good) rejects
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #s3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #s3 EXEC Lots.Lot_UpdateStatus @LotId=@LotId, @NewLotStatusId=@Good, @AppUserId=1;
SELECT @S = Status FROM #s3;
DROP TABLE #s3;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[StatNoOp] Good->Good (no-op) rejected', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 4: valid Good -> Closed applies + LotStatusHistory row written
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id);
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #s4 (Status BIT, Message NVARCHAR(500));
INSERT INTO #s4 EXEC Lots.Lot_UpdateStatus @LotId=@LotId, @NewLotStatusId=@Closed, @Reason=N'All pieces consumed', @AppUserId=1;
SELECT @S = Status FROM #s4;
DROP TABLE #s4;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[StatValid] Good->Closed applies', @Expected = N'1', @Actual = @SStr;

DECLARE @NowClosed NVARCHAR(1) = (SELECT CASE WHEN sc.Code = N'Closed' THEN N'1' ELSE N'0' END
                                  FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @LotId);
EXEC test.Assert_IsEqual @TestName = N'[StatValid] Lot status now Closed', @Expected = N'1', @Actual = @NowClosed;

DECLARE @HistCnt INT = (SELECT COUNT(*) FROM Lots.LotStatusHistory WHERE LotId = @LotId AND NewStatusId = @Closed);
DECLARE @HistStr NVARCHAR(10) = CAST(@HistCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[StatValid] LotStatusHistory transition row written', @Expected = N'1', @Actual = @HistStr;
GO

-- ---- cleanup ----
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

EXEC test.EndTestFile;
GO
