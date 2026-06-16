-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/070_Receiving_pass_through.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Confirms Receiving = Lot_Create reuse (Arc 2 Phase 4 sec 5.4 / Confirm A).
--               A 'Received'-origin LOT captures VendorLotNumber + serial range, with
--               NULL Tool/Cavity, and audits LotCreated. No net-new SQL -- this proves
--               the existing proc covers the Receiving workflow.
--               Fixture item = 1 (5G0), eligible at DC1-M05 (stands in for the
--               Receiving Dock location in this DB).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0024_PlantFloor_Movement_Trim/070_Receiving_pass_through.sql';
GO

-- ---- fixture cleanup ----
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

DECLARE @Dock BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

DECLARE @S BIT, @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create
    @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Dock, @PieceCount = 100,
    @VendorLotNumber = N'VEND-LOT-7788', @MinSerialNumber = 5000, @MaxSerialNumber = 5099, @AppUserId = 1;
SELECT @S = Status, @L = NewId FROM #C; DROP TABLE #C;

DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Receiving] Lot_Create Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @Vendor NVARCHAR(100) = (SELECT VendorLotNumber FROM Lots.Lot WHERE Id = @L);
EXEC test.Assert_IsEqual @TestName = N'[Receiving] VendorLotNumber captured', @Expected = N'VEND-LOT-7788', @Actual = @Vendor;

DECLARE @MinS NVARCHAR(20) = (SELECT CAST(MinSerialNumber AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @L);
DECLARE @MaxS NVARCHAR(20) = (SELECT CAST(MaxSerialNumber AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @L);
EXEC test.Assert_IsEqual @TestName = N'[Receiving] MinSerialNumber captured', @Expected = N'5000', @Actual = @MinS;
EXEC test.Assert_IsEqual @TestName = N'[Receiving] MaxSerialNumber captured', @Expected = N'5099', @Actual = @MaxS;

DECLARE @ToolNull NVARCHAR(10) = (SELECT CASE WHEN ToolId IS NULL AND ToolCavityId IS NULL THEN N'1' ELSE N'0' END FROM Lots.Lot WHERE Id = @L);
EXEC test.Assert_IsEqual @TestName = N'[Receiving] NULL Tool/Cavity', @Expected = N'1', @Actual = @ToolNull;

DECLARE @OriginCode NVARCHAR(20) = (SELECT ot.Code FROM Lots.Lot l INNER JOIN Lots.LotOriginType ot ON ot.Id = l.LotOriginTypeId WHERE l.Id = @L);
EXEC test.Assert_IsEqual @TestName = N'[Receiving] origin is Received', @Expected = N'Received', @Actual = @OriginCode;

DECLARE @AudCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotEventLog le
    INNER JOIN Audit.LogEventType et ON et.Id = le.LogEventTypeId
    WHERE et.Code = N'LotCreated' AND le.EntityId = @L);
EXEC test.Assert_IsEqual @TestName = N'[Receiving] LotCreated audit present', @Expected = N'1', @Actual = @AudCnt;
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
