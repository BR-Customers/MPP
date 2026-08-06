-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/110_DowntimeEvent_approximate.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-04
-- Description:  Duration-only ("approximate") downtime capture + materialized
--               DurationMinutes (migration 0046).
--                 * Oee.DowntimeEvent_RecordApproximate -> Status, Message, NewId
--               Asserts: an approximate event is CLOSED (EndedAt set, so the
--               one-open index is satisfied), flagged IsApproximate=1, stores the
--               operator DurationMinutes, and its nominal window matches the
--               duration (DATEDIFF = DurationMinutes); zero/negative duration is
--               rejected; RecordHistorical now also stamps DurationMinutes.
--               Fixture: any active Cell (HierarchyLevel 4).
--               'DowntimeEvent' audits to Audit.OperationLog -- teardown sweeps it.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/110_DowntimeEvent_approximate.sql';
GO

-- ---- shared fixtures ----
IF OBJECT_ID(N'tempdb..#DtApx') IS NOT NULL DROP TABLE #DtApx;
CREATE TABLE #DtApx (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO

DECLARE @CellId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 4 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
INSERT INTO #DtApx (Tag, Val) VALUES (N'CELL', @CellId);
GO

-- =============================================
-- Test 1: RecordApproximate creates a closed, flagged, duration-stamped event
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #DtApx WHERE Tag = N'CELL');
EXEC test.Assert_IsNotNull @TestName = N'[DowntimeApx] fixture Cell (HierarchyLevel 4) exists', @Value = @Cell;
DECLARE @s1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @s1 EXEC Oee.DowntimeEvent_RecordApproximate
    @ScopeLocationId = @Cell, @DurationMinutes = 45, @AppUserId = 1;
DECLARE @ok1 BIT   = (SELECT Status FROM @s1);
DECLARE @id1 BIGINT = (SELECT NewId FROM @s1);
EXEC test.Assert_IsTrue    @TestName = N'[DowntimeApx] record approximate succeeds (Status=1)', @Condition = @ok1;
EXEC test.Assert_IsNotNull @TestName = N'[DowntimeApx] returns a NewId', @Value = @id1;
INSERT INTO #DtApx (Tag, Val) VALUES (N'EVT', @id1);

DECLARE @closed1 INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent
    WHERE Id = @id1 AND EndedAt IS NOT NULL AND IsApproximate = 1 AND DurationMinutes = 45);
EXEC test.Assert_RowCount @TestName = N'[DowntimeApx] event is closed, approximate, 45 min stored',
    @ExpectedCount = 1, @ActualCount = @closed1;

DECLARE @consistent INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent
    WHERE Id = @id1 AND DATEDIFF(MINUTE, StartedAt, EndedAt) = DurationMinutes);
EXEC test.Assert_RowCount @TestName = N'[DowntimeApx] nominal window matches stored duration',
    @ExpectedCount = 1, @ActualCount = @consistent;
GO

-- =============================================
-- Test 2: zero / negative duration is rejected
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #DtApx WHERE Tag = N'CELL');
DECLARE @s2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @s2 EXEC Oee.DowntimeEvent_RecordApproximate
    @ScopeLocationId = @Cell, @DurationMinutes = 0, @AppUserId = 1;
DECLARE @s2cond BIT = CASE WHEN (SELECT Status FROM @s2) = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[DowntimeApx] zero duration rejected (Status=0)', @Condition = @s2cond;
GO

-- =============================================
-- Test 3: RecordHistorical now also stamps DurationMinutes (30 min exact)
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #DtApx WHERE Tag = N'CELL');
DECLARE @s3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @s3 EXEC Oee.DowntimeEvent_RecordHistorical
    @ScopeLocationId = @Cell,
    @StartedAtEt = '2026-08-04 08:00:00',
    @EndedAtEt   = '2026-08-04 08:30:00',
    @AppUserId = 1;
DECLARE @id3 BIGINT = (SELECT NewId FROM @s3);
INSERT INTO #DtApx (Tag, Val) VALUES (N'EVT2', @id3);
DECLARE @hist INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent
    WHERE Id = @id3 AND DurationMinutes = 30 AND IsApproximate = 0);
EXEC test.Assert_RowCount @TestName = N'[DowntimeApx] RecordHistorical stamps DurationMinutes=30, exact (IsApproximate=0)',
    @ExpectedCount = 1, @ActualCount = @hist;
GO

-- ---- cleanup (FK-safe: audit rows before events) ----
DECLARE @Cell BIGINT = (SELECT Val FROM #DtApx WHERE Tag = N'CELL');
DELETE ol FROM Audit.OperationLog ol
    INNER JOIN Oee.DowntimeEvent de ON de.Id = ol.EntityId
    WHERE de.LocationId = @Cell
      AND ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent');
DELETE FROM Oee.DowntimeEvent WHERE LocationId = @Cell;
IF OBJECT_ID(N'tempdb..#DtApx') IS NOT NULL DROP TABLE #DtApx;
GO
