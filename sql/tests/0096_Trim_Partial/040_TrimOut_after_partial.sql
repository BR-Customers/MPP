-- =============================================
-- File:         0096_Trim_Partial/040_TrimOut_after_partial.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-22
-- Description:  Tests for Workorder.TrimOut_Record v1.5 (trim partial checkpoint
--               at shift end -- docs/superpowers/specs/2026-09-22-trim-partial-
--               shift-end-design.md sec 5.2).
--                 - NULL @ShotCount after a partial checkpoint rejects (the
--                   partial shift's credit would be undefined)
--                 - a Trim OUT count below the last partial rejects
--                 - Trim OUT after a partial is accepted; the shift credit
--                   splits correctly (700 to the partial shift, 246 to the OUT
--                   shift -- spec 3.2)
--                 - the closing checkpoint and its scrap rows are stamped with
--                   ShiftId from Oee.ufn_ShiftIdForInstant at the trim shop
--                 - the trim-scoped monotonic guard ignores a non-trim
--                   ProductionEvent even when its count is higher
--               Fixture item = 5G0-c; LOTs TPC-040-A (953) / TPC-040-B (953) at
--               TRIM1; closed fixture shift.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0096_Trim_Partial/040_TrimOut_after_partial.sql';
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
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Rcv, @CurrentLocationId = @Src, @PieceCount = 953, @AppUserId = 1, @LotName = N'TPC-040-A';
SELECT @L = NewId FROM #C; DROP TABLE #C;

DECLARE @OtOut BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND oty.Code = N'TrimOut');
DECLARE @J5 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Dc AS NVARCHAR(20)) + N',"quantity":5}]';
DECLARE @J2 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Dc AS NVARCHAR(20)) + N',"quantity":2}]';
DECLARE @Big NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Dc AS NVARCHAR(20)) + N',"quantity":300}]';
DECLARE @Res TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @St NVARCHAR(10), @OutId BIGINT;

-- 2nd shift: partial 700, scrap 5 -> LOT 948
INSERT INTO @Res EXEC Workorder.TrimPartial_Record @LotId = @L, @OperationTemplateId = @OtIn, @ShotCount = 700,
    @ScrapLinesJson = @J5, @ShiftId = @Shift, @SourceLocationId = @Src, @AppUserId = 1;

-- Trim OUT with NULL count after a partial -> rejected
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimOut_Record @ParentLotId = @L, @OperationTemplateId = @OtOut, @ShotCount = NULL,
    @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] NULL count after a partial rejects', @Expected = N'0', @Actual = @St;

-- Trim OUT whose count falls below the partial (648 good + 300 scrap = 948) -> rejected
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimOut_Record @ParentLotId = @L, @OperationTemplateId = @OtOut, @ShotCount = 648,
    @ScrapLinesJson = @Big, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)) FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] count below the partial rejects', @Expected = N'0', @Actual = @St;

-- 3rd shift: Trim OUT as the screen sends it: 948 - 2 = 946
DELETE FROM @Res;
INSERT INTO @Res EXEC Workorder.TrimOut_Record @ParentLotId = @L, @OperationTemplateId = @OtOut, @ShotCount = 946,
    @ScrapLinesJson = @J2, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @St = CAST(Status AS NVARCHAR(10)), @OutId = NewId FROM @Res;
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] Trim OUT after partial accepted', @Expected = N'1', @Actual = @St;

-- Credit split: 700 then 246 (spec 3.2)
DECLARE @Credit TABLE (Id BIGINT, Trimmed INT);
INSERT INTO @Credit
SELECT pe.Id, pe.ShotCount - ISNULL(LAG(pe.ShotCount) OVER (PARTITION BY pe.LotId ORDER BY pe.EventAt, pe.Id), 0)
FROM Workorder.ProductionEvent pe
JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE pe.LotId = @L AND oty.Code IN (N'TrimIn', N'TrimOut');
DECLARE @First NVARCHAR(10) = CAST((SELECT TOP 1 Trimmed FROM @Credit ORDER BY Id) AS NVARCHAR(10));
DECLARE @Second NVARCHAR(10) = CAST((SELECT Trimmed FROM @Credit WHERE Id = @OutId) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] partial shift credited 700', @Expected = N'700', @Actual = @First;
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] finishing shift credited 246', @Expected = N'246', @Actual = @Second;

-- ShiftId stamped from the resolver at the trim shop (NULL-safe compare: the test DB may have no running shift)
DECLARE @ExpShift NVARCHAR(20) = ISNULL(CAST((SELECT TOP 1 ShiftId FROM Oee.ufn_ShiftIdForInstant(@Src, SYSUTCDATETIME())) AS NVARCHAR(20)), N'<NULL>');
DECLARE @OutShift NVARCHAR(20) = ISNULL(CAST((SELECT ShiftId FROM Workorder.ProductionEvent WHERE Id = @OutId) AS NVARCHAR(20)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] checkpoint ShiftId = ufn_ShiftIdForInstant', @Expected = @ExpShift, @Actual = @OutShift;
DECLARE @RjShift NVARCHAR(20) = ISNULL(CAST((SELECT TOP 1 ShiftId FROM Workorder.RejectEvent WHERE LotId = @L AND Remarks = N'Trim OUT scrap') AS NVARCHAR(20)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] scrap ShiftId = ufn_ShiftIdForInstant', @Expected = @ExpShift, @Actual = @RjShift;
GO

-- Trim-scoped guard: a non-trim ProductionEvent with a HIGHER count does not block Trim OUT.
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
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Rcv, @CurrentLocationId = @Src, @PieceCount = 953, @AppUserId = 1, @LotName = N'TPC-040-B';
SELECT @L = NewId FROM #C; DROP TABLE #C;

DECLARE @OtOut BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND oty.Code = N'TrimOut');
DECLARE @OtDc BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND oty.Code = N'DieCast');
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
VALUES (@L, @OtDc, SYSUTCDATETIME(), 5000, 1);
DECLARE @Res2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Res2 EXEC Workorder.TrimOut_Record @ParentLotId = @L, @OperationTemplateId = @OtOut, @ShotCount = 953,
    @SourceLocationId = @Src, @AppUserId = 1;
DECLARE @St2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @Res2);
EXEC test.Assert_IsEqual @TestName = N'[OUT v1.5] guard ignores non-trim checkpoints', @Expected = N'1', @Actual = @St2;
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
