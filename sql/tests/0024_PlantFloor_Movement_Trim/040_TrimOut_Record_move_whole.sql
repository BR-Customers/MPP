-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/040_TrimOut_Record_move_whole.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Tests for Workorder.TrimOut_Record happy path (Arc 2 Phase 4 sec 4.3).
--                 - whole LOT moved to destination; CurrentLocationId updated
--                 - closing ProductionEvent written (TrimOut template)
--                 - LotMovement row written
--                 - parent stays open (Good) -- NO split, NO children
--                   (LotGenealogyClosure still just the Depth=0 self-row)
--                 - LOT visible via Lot_GetWipQueueByLocation at destination
--                 - TrimOutRecorded audit in OperationLog
--               Fixture item = 1 (5G0); M05 -> M06 (both eligible); Received origin.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0024_PlantFloor_Movement_Trim/040_TrimOut_Record_move_whole.sql';
GO

-- ---- fixture cleanup ----
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @LocB BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M06');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');

DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 20, @AppUserId = 1;
SELECT @L = NewId FROM #C; DROP TABLE #C;

DECLARE @S BIT, @PeId BIGINT;
CREATE TABLE #T (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T EXEC Workorder.TrimOut_Record
    @ParentLotId = @L, @OperationTemplateId = @OtId,
    @ShotCount = 20, @ScrapCount = 2, @DestinationCellLocationId = @LocB, @AppUserId = 1;
SELECT @S = Status, @PeId = NewId FROM #T; DROP TABLE #T;

DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOut] Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @PeStr NVARCHAR(20) = CAST(@PeId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[TrimOut] ProductionEventId returned', @Value = @PeStr;

DECLARE @PeCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ProductionEvent WHERE Id = @PeId AND LotId = @L AND OperationTemplateId = @OtId);
EXEC test.Assert_IsEqual @TestName = N'[TrimOut] closing ProductionEvent (TrimOut template)', @Expected = N'1', @Actual = @PeCnt;

DECLARE @Cur NVARCHAR(20) = (SELECT CAST(CurrentLocationId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @L);
DECLARE @LocBStr NVARCHAR(20) = CAST(@LocB AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[TrimOut] whole LOT moved to destination', @Expected = @LocBStr, @Actual = @Cur;

DECLARE @MovCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotMovement WHERE LotId = @L AND ToLocationId = @LocB);
EXEC test.Assert_IsEqual @TestName = N'[TrimOut] LotMovement row to destination', @Expected = N'1', @Actual = @MovCnt;

-- parent stays open (Good) -- no split
DECLARE @StatusCode NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @L);
EXEC test.Assert_IsEqual @TestName = N'[TrimOut] parent LOT stays Good (open)', @Expected = N'Good', @Actual = @StatusCode;

-- no children: closure still just the Depth=0 self-row
DECLARE @ClosCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @L OR DescendantLotId = @L);
EXEC test.Assert_IsEqual @TestName = N'[TrimOut] no split (only Depth=0 self-row)', @Expected = N'1', @Actual = @ClosCnt;

-- visible in the destination WIP queue
CREATE TABLE #Q (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3));
INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @LocB;
DECLARE @InQ NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id = @L);
DROP TABLE #Q;
EXEC test.Assert_IsEqual @TestName = N'[TrimOut] LOT visible in destination FIFO queue', @Expected = N'1', @Actual = @InQ;

-- audit
DECLARE @AudCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol
    INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
    WHERE et.Code = N'TrimOutRecorded' AND ol.EntityId = @PeId);
EXEC test.Assert_IsEqual @TestName = N'[TrimOut] TrimOutRecorded audit in OperationLog', @Expected = N'1', @Actual = @AudCnt;
GO

-- ---- cleanup ----
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

EXEC test.EndTestFile;
GO
