-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/010_DowntimeEvent_lifecycle.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Arc 2 Phase 8 downtime lifecycle (FDS-09-005/010):
--                 * Oee.DowntimeEvent_Start -> Status, Message, NewId
--                 * Oee.DowntimeEvent_End   -> Status, Message  (Task 3)
--               Asserts: Start opens a row (EndedAt NULL); double-start at the
--               same Location is rejected (B3 one-open invariant); End closes the
--               event; End of an already-closed event is rejected.
--               Fixture: any active Cell (HierarchyLevel 4) + Operator source.
--               'DowntimeEvent' audits to Audit.OperationLog -- teardown sweeps it.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/010_DowntimeEvent_lifecycle.sql';
GO

-- ---- shared fixtures ----
IF OBJECT_ID(N'tempdb..#DtFix') IS NOT NULL DROP TABLE #DtFix;
CREATE TABLE #DtFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO

DECLARE @CellId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 4 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @SrcId BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
INSERT INTO #DtFix (Tag, Val) VALUES (N'CELL', @CellId), (N'SRC', @SrcId);
GO

-- =============================================
-- Test 1: start opens an event (Status=1, open row exists)
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #DtFix WHERE Tag = N'CELL');
DECLARE @Src  BIGINT = (SELECT Val FROM #DtFix WHERE Tag = N'SRC');
EXEC test.Assert_IsNotNull @TestName = N'[Downtime] fixture Cell (HierarchyLevel 4) exists', @Value = @Cell;
DECLARE @s1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @s1 EXEC Oee.DowntimeEvent_Start
    @LocationId = @Cell, @DowntimeSourceCodeId = @Src, @AppUserId = 1;
DECLARE @ok1 BIT = (SELECT Status FROM @s1);
DECLARE @id1 BIGINT = (SELECT NewId FROM @s1);
EXEC test.Assert_IsTrue   @TestName = N'[Downtime] start succeeds (Status=1)', @Condition = @ok1;
EXEC test.Assert_IsNotNull @TestName = N'[Downtime] start returns a NewId', @Value = @id1;
DECLARE @open1 INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE Id = @id1 AND EndedAt IS NULL);
EXEC test.Assert_RowCount @TestName = N'[Downtime] the event is open (EndedAt NULL)',
    @ExpectedCount = 1, @ActualCount = @open1;
INSERT INTO #DtFix (Tag, Val) VALUES (N'EVT', @id1);
GO

-- =============================================
-- Test 2: double-start at the same Location rejected (B3)
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #DtFix WHERE Tag = N'CELL');
DECLARE @Src  BIGINT = (SELECT Val FROM #DtFix WHERE Tag = N'SRC');
DECLARE @s2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @s2 EXEC Oee.DowntimeEvent_Start
    @LocationId = @Cell, @DowntimeSourceCodeId = @Src, @AppUserId = 1;
DECLARE @s2cond BIT = CASE WHEN (SELECT Status FROM @s2) = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Downtime] double-start at same Location rejected (B3)', @Condition = @s2cond;
DECLARE @openCnt INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent
                        WHERE LocationId = @Cell AND EndedAt IS NULL);
EXEC test.Assert_RowCount @TestName = N'[Downtime] still exactly one open event after double-start',
    @ExpectedCount = 1, @ActualCount = @openCnt;
GO

-- =============================================
-- Test 3: end closes the event (EndedAt set)
-- =============================================
DECLARE @EvtId BIGINT = (SELECT Val FROM #DtFix WHERE Tag = N'EVT');
DECLARE @e3 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @e3 EXEC Oee.DowntimeEvent_End
    @DowntimeEventId = @EvtId, @Remarks = N'Resolved', @AppUserId = 1;
DECLARE @ok3 BIT = (SELECT Status FROM @e3);
EXEC test.Assert_IsTrue @TestName = N'[Downtime] end succeeds (Status=1)', @Condition = @ok3;
DECLARE @closed3 INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE Id = @EvtId AND EndedAt IS NOT NULL);
EXEC test.Assert_RowCount @TestName = N'[Downtime] event is closed (EndedAt set)',
    @ExpectedCount = 1, @ActualCount = @closed3;
GO

-- =============================================
-- Test 4: end of an already-closed event is rejected
-- =============================================
DECLARE @EvtId BIGINT = (SELECT Val FROM #DtFix WHERE Tag = N'EVT');
DECLARE @e4 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @e4 EXEC Oee.DowntimeEvent_End @DowntimeEventId = @EvtId, @AppUserId = 1;
DECLARE @s4cond BIT = CASE WHEN (SELECT Status FROM @e4) = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Downtime] end of already-closed event rejected', @Condition = @s4cond;
GO

-- ---- cleanup (FK-safe) ----
DECLARE @Cell BIGINT = (SELECT Val FROM #DtFix WHERE Tag = N'CELL');
DELETE ol FROM Audit.OperationLog ol
    INNER JOIN Oee.DowntimeEvent de ON de.Id = ol.EntityId
    WHERE de.LocationId = @Cell
      AND ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent');
DELETE FROM Oee.DowntimeEvent WHERE LocationId = @Cell;
IF OBJECT_ID(N'tempdb..#DtFix') IS NOT NULL DROP TABLE #DtFix;
GO
