-- =============================================
-- File:         0096_Trim_Partial/020_TrimPartial_Record.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-22
-- Description:  Tests for Workorder.TrimPartial_Record happy path (trim partial
--               checkpoint at shift end -- docs/superpowers/specs/2026-09-22-
--               trim-partial-shift-end-design.md).
--                 - Status 1, ProductionEventId returned
--                 - checkpoint written on the route's TrimIn template, cumulative
--                   ShotCount, ScrapCount
--                 - checkpoint stamped with the operator-picked ShiftId
--                 - the LOT does NOT move (CurrentLocationId unchanged, no new
--                   LotMovement row)
--                 - scrap decrements Lot.PieceCount and InventoryAvailable
--                 - reject row stamped Item + Cell + Shift, no cavity (trim has
--                   no die)
--                 - LOT stays Good (open)
--                 - TrimCheckpointRecorded audit in OperationLog
--                 - the LOT stays in the trim shop's WIP list, next step TrimOut
--                 - a second partial on the same LOT (spanning shifts) is accepted
--               Fixture item = 5G0-c; LOT of 953 at TRIM1; closed fixture shift.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0096_Trim_Partial/020_TrimPartial_Record.sql';
GO

-- ---- fixture cleanup (FK order: events before LOTs, events before the shift) ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TPC-%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TPC-%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TPC-%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TPC-%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TPC-%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TPC-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'TPC-%';
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
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Rcv, @CurrentLocationId = @Src, @PieceCount = 953, @AppUserId = 1, @LotName = N'TPC-020-A';
SELECT @L = NewId FROM #C; DROP TABLE #C;

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

-- ---- cleanup ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TPC-%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TPC-%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TPC-%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TPC-%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TPC-%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TPC-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'TPC-%';
DELETE FROM Oee.Shift WHERE Remarks = N'TPC-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TPC-FIXTURE-SCHED';
GO

EXEC test.EndTestFile;
GO
