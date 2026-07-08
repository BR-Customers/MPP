-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/060_Lot_GetWipQueueByLocation.sql
-- Description:  Tests for Lots.Lot_GetWipQueueByLocation v3.0 (terminal-mint §3.2).
--               Route-driven queue: a LOT surfaces at the terminal whose role = its
--               next PENDING route step; an Advance ProductionEvent advances it; a
--               ConsumeMint terminal step keeps it queued until Closed; empty loc -> 0.
--               Fixture item = 6MA-M (route MachiningIn[Advance] -> MachiningOut
--               [ConsumeMint]) at MA1-FPRPY-MOUT.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0024_PlantFloor_Movement_Trim/060_Lot_GetWipQueueByLocation.sql';
GO

DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'6MA-M');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

DECLARE @Lot BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U;
SELECT @Lot = NewId FROM #C; DROP TABLE #C;

-- Result-shape temp table matches v3.0 columns.
CREATE TABLE #Q (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3),
    NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);

-- (1) No events -> present for MachiningIn.
DELETE FROM #Q; INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'MachiningIn';
DECLARE @a1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[WipQueue] fresh LOT in MachiningIn queue', @Expected = N'1', @Actual = @a1;

-- (2) Not in MachiningOut queue yet.
DELETE FROM #Q; INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'MachiningOut';
DECLARE @a2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[WipQueue] fresh LOT NOT in MachiningOut queue', @Expected = N'0', @Actual = @a2;

-- (3) Stamp MachiningIn ProductionEvent -> advances to MachiningOut.
DECLARE @MinTpl BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND oty.Code = N'MachiningIn');
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
VALUES (@Lot, @MinTpl, SYSUTCDATETIME(), 10, @U);

DELETE FROM #Q; INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'MachiningIn';
DECLARE @a3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[WipQueue] LOT leaves MachiningIn after its event', @Expected = N'0', @Actual = @a3;

DELETE FROM #Q; INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'MachiningOut';
DECLARE @a4 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id = @Lot AND NextOperationTypeCode = N'MachiningOut');
EXEC test.Assert_IsEqual @TestName = N'[WipQueue] LOT enters MachiningOut (ConsumeMint) queue', @Expected = N'1', @Actual = @a4;
DROP TABLE #Q;
GO

-- Empty location -> 0 rows.
DECLARE @BadLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    WHERE l.DeprecatedAt IS NULL AND NOT EXISTS (SELECT 1 FROM Lots.Lot x WHERE x.CurrentLocationId = l.Id) ORDER BY l.Id);
CREATE TABLE #Q2 (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3),
    NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);
INSERT INTO #Q2 EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @BadLoc;
DECLARE @a5 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q2);
EXEC test.Assert_IsEqual @TestName = N'[WipQueue] empty location returns 0 rows', @Expected = N'0', @Actual = @a5;
DROP TABLE #Q2;
GO

-- ---- cleanup (by the fixture LOT id) ----
DECLARE @Item2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'6MA-M');
DECLARE @Line2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT');
DECLARE @Lot2 BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE ItemId = @Item2 AND CurrentLocationId = @Line2 AND PieceCount = 10 ORDER BY Id DESC);
DELETE FROM Workorder.ProductionEvent WHERE LotId = @Lot2;
DELETE FROM Lots.LotEventLog WHERE LotId = @Lot2;
DELETE FROM Lots.LotMovement WHERE LotId = @Lot2;
DELETE FROM Lots.LotStatusHistory WHERE LotId = @Lot2;
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @Lot2 OR DescendantLotId = @Lot2;
DELETE FROM Lots.Lot WHERE Id = @Lot2;
GO
