-- =============================================
-- File:         0096_Trim_Partial/030_TrimPartial_validation.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-22
-- Description:  Rejection-path tests for Workorder.TrimPartial_Record (trim
--               partial checkpoint at shift end -- docs/superpowers/specs/
--               2026-09-22-trim-partial-shift-end-design.md). Every case uses
--               the fixture LOT (953 at TRIM1) and asserts Status = 0:
--                 1. missing ShiftId / missing ShotCount
--                 2. invalid scrap JSON / zero scrap quantity / deprecated or
--                    unknown defect code
--                 3. unknown OperationTemplate
--                 4. unknown LOT
--                 5. LOT not at this Trim station (checked in elsewhere)
--                 6. unknown Shift
--                 7. negative count / combined count+scrap over PieceCount
--                 8. count below the LOT's previously recorded trim checkpoint
--                 9. no progress and no scrap (nothing to record)
--               Then asserts rejections wrote no ProductionEvent rows and left
--               Lot.PieceCount untouched.
--               Fixture item = 5G0-c; LOT of 953 at TRIM1; closed fixture shift.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0096_Trim_Partial/030_TrimPartial_validation.sql';
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
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Rcv, @CurrentLocationId = @Src, @PieceCount = 953, @AppUserId = 1, @LotName = N'TPC-030-A';
SELECT @L = NewId FROM #C; DROP TABLE #C;

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
