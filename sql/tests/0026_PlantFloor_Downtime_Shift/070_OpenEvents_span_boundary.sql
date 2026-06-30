-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/070_OpenEvents_span_boundary.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Arc 2 Phase 8 shift-boundary semantics (UJ-10 Option D / OI-03):
--               Oee.Shift_End closes the shift but does NOT auto-close open
--               downtime events. Open events span the boundary; the incoming
--               operator closes them. Asserts the shift closes AND the open
--               DowntimeEvent is left untouched (EndedAt still NULL).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/070_OpenEvents_span_boundary.sql';
GO

IF OBJECT_ID(N'tempdb..#BndFix') IS NOT NULL DROP TABLE #BndFix;
CREATE TABLE #BndFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO

-- Defensive: clear any leftover boundary-test schedule/shift (single-open invariant).
DELETE s FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule sc ON sc.Id = s.ShiftScheduleId WHERE sc.Name LIKE N'P8 BND%';
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'P8 BND%';
GO

DECLARE @CellId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 4 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @Op BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');

DECLARE @sched BIGINT, @shift BIGINT;
INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'P8 BND Test', '06:00', '14:00', 31, '2026-01-01', 1);
SET @sched = SCOPE_IDENTITY();
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES (@sched, SYSUTCDATETIME());
SET @shift = SCOPE_IDENTITY();

DECLARE @s TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @s EXEC Oee.DowntimeEvent_Start @LocationId = @CellId, @DowntimeSourceCodeId = @Op, @AppUserId = 1;
DECLARE @evt BIGINT = (SELECT NewId FROM @s);

INSERT INTO #BndFix (Tag, Val) VALUES (N'CELL', @CellId), (N'SCHED', @sched), (N'SHIFT', @shift), (N'EVT', @evt);
GO

-- =============================================
-- Test 1: Shift_End closes the shift but leaves the open downtime untouched
-- =============================================
DECLARE @Shift BIGINT = (SELECT Val FROM #BndFix WHERE Tag = N'SHIFT');
DECLARE @Evt   BIGINT = (SELECT Val FROM #BndFix WHERE Tag = N'EVT');
DECLARE @se TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @se EXEC Oee.Shift_End @ActualEnd = NULL, @AppUserId = 1;
DECLARE @shiftClosed INT = (SELECT COUNT(*) FROM Oee.Shift WHERE Id = @Shift AND ActualEnd IS NOT NULL);
EXEC test.Assert_RowCount @TestName = N'[Boundary] Shift_End closed the shift', @ExpectedCount = 1, @ActualCount = @shiftClosed;
DECLARE @evtStillOpen INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE Id = @Evt AND EndedAt IS NULL);
EXEC test.Assert_RowCount @TestName = N'[Boundary] open downtime untouched by Shift_End (UJ-10/OI-03)',
    @ExpectedCount = 1, @ActualCount = @evtStillOpen;
GO

-- ---- cleanup ----
DECLARE @Cell BIGINT = (SELECT Val FROM #BndFix WHERE Tag = N'CELL');
DECLARE @Sched BIGINT = (SELECT Val FROM #BndFix WHERE Tag = N'SCHED');
DECLARE @Shift BIGINT = (SELECT Val FROM #BndFix WHERE Tag = N'SHIFT');
DELETE ol FROM Audit.OperationLog ol INNER JOIN Oee.DowntimeEvent de ON de.Id = ol.EntityId
    WHERE de.LocationId = @Cell AND ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent');
DELETE FROM Oee.DowntimeEvent WHERE LocationId = @Cell;
DELETE FROM Oee.Shift WHERE Id = @Shift;
DELETE FROM Oee.ShiftSchedule WHERE Id = @Sched;
IF OBJECT_ID(N'tempdb..#BndFix') IS NOT NULL DROP TABLE #BndFix;
GO
