-- =============================================
-- File:         0096_Trim_Partial/050_TrimCheckpoint_GetLatestForLot.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-22
-- Description:  Tests for Workorder.TrimCheckpoint_GetLatestForLot (trim partial
--               checkpoint at shift end -- docs/superpowers/specs/2026-09-22-
--               trim-partial-shift-end-design.md).
--                 - no trim checkpoint recorded yet -> empty result (no invented 404)
--                 - after two TrimPartial_Record calls, returns the newest checkpoint
--                   (highest ShotCount / most recent EventAt)
--                 - ShiftLabel formatted "<ScheduleName> - MM/dd"
--                 - Initials carried from the recording AppUser
--               Fixture item = 5G0-c; LOT of 953 at TRIM1; closed fixture shift.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0096_Trim_Partial/050_TrimCheckpoint_GetLatestForLot.sql';
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
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Rcv, @CurrentLocationId = @Src, @PieceCount = 953, @AppUserId = 1, @LotName = N'TPC-050-A';
SELECT @L = NewId FROM #C; DROP TABLE #C;

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
