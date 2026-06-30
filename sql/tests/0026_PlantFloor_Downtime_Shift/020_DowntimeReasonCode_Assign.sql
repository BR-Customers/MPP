-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/020_DowntimeReasonCode_Assign.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Arc 2 Phase 8 late-binding reason assignment (B7, FDS-09-010).
--               PLC opens an event with NULL reason; operator assigns it later.
--               Asserts: PLC-source start with NULL reason; assign sets the
--               reason (Status=1); a second assign with a different code is
--               rejected (B7 no-overwrite) and the reason is unchanged.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/020_DowntimeReasonCode_Assign.sql';
GO

IF OBJECT_ID(N'tempdb..#AsFix') IS NOT NULL DROP TABLE #AsFix;
CREATE TABLE #AsFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO

DECLARE @CellId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 4 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @PlcId    BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'PLC');
-- Ensure break reason codes exist: the 0012 DowntimeReasonCode tests run earlier
-- and wipe the table, so re-seed our breaks idempotently (the Break type survives).
DECLARE @SiteId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 1 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @BreakTypeId BIGINT = (SELECT Id FROM Oee.DowntimeReasonType WHERE Code = N'Break');
INSERT INTO Oee.DowntimeReasonCode (Code, Description, AreaLocationId, DowntimeReasonTypeId, IsExcused, StandardDurationMinutes, CreatedByUserId)
SELECT v.Code, v.Descr, @SiteId, @BreakTypeId, 1, v.Mins, 1
FROM (VALUES (N'LUNCH', N'Scheduled lunch', 30), (N'BREAK1', N'Scheduled break 1', 15), (N'BREAK2', N'Scheduled break 2', 15)) v(Code, Descr, Mins)
WHERE NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode rc WHERE rc.Code = v.Code);
DECLARE @Reason1  BIGINT = (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'LUNCH');
DECLARE @Reason2  BIGINT = (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'BREAK1');
INSERT INTO #AsFix (Tag, Val) VALUES (N'CELL', @CellId), (N'PLC', @PlcId), (N'R1', @Reason1), (N'R2', @Reason2);
GO

-- =============================================
-- Test 1: PLC-source start with NULL reason; assign sets the reason
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #AsFix WHERE Tag = N'CELL');
DECLARE @Plc  BIGINT = (SELECT Val FROM #AsFix WHERE Tag = N'PLC');
DECLARE @R1   BIGINT = (SELECT Val FROM #AsFix WHERE Tag = N'R1');
DECLARE @st TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @st EXEC Oee.DowntimeEvent_Start @LocationId = @Cell, @DowntimeSourceCodeId = @Plc;  -- AppUserId NULL (PLC)
DECLARE @EvtId BIGINT = (SELECT NewId FROM @st);
INSERT INTO #AsFix (Tag, Val) VALUES (N'EVT', @EvtId);
DECLARE @nullReason INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE Id = @EvtId AND DowntimeReasonCodeId IS NULL);
EXEC test.Assert_RowCount @TestName = N'[Assign] PLC start has NULL reason', @ExpectedCount = 1, @ActualCount = @nullReason;

DECLARE @as TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @as EXEC Oee.DowntimeReasonCode_Assign @DowntimeEventId = @EvtId, @DowntimeReasonCodeId = @R1, @AppUserId = 1;
DECLARE @okA BIT = (SELECT Status FROM @as);
EXEC test.Assert_IsTrue @TestName = N'[Assign] assign reason succeeds (Status=1)', @Condition = @okA;
DECLARE @setReason INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE Id = @EvtId AND DowntimeReasonCodeId = @R1);
EXEC test.Assert_RowCount @TestName = N'[Assign] reason is now set', @ExpectedCount = 1, @ActualCount = @setReason;
GO

-- =============================================
-- Test 2: second assign with a different code rejected (B7), reason unchanged
-- =============================================
DECLARE @EvtId BIGINT = (SELECT Val FROM #AsFix WHERE Tag = N'EVT');
DECLARE @R1    BIGINT = (SELECT Val FROM #AsFix WHERE Tag = N'R1');
DECLARE @R2    BIGINT = (SELECT Val FROM #AsFix WHERE Tag = N'R2');
DECLARE @as2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @as2 EXEC Oee.DowntimeReasonCode_Assign @DowntimeEventId = @EvtId, @DowntimeReasonCodeId = @R2, @AppUserId = 1;
DECLARE @b7cond BIT = CASE WHEN (SELECT Status FROM @as2) = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Assign] overwrite of an assigned reason rejected (B7)', @Condition = @b7cond;
DECLARE @stillR1 INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE Id = @EvtId AND DowntimeReasonCodeId = @R1);
EXEC test.Assert_RowCount @TestName = N'[Assign] reason unchanged after rejected overwrite', @ExpectedCount = 1, @ActualCount = @stillR1;
GO

-- ---- cleanup (FK-safe) ----
DECLARE @Cell BIGINT = (SELECT Val FROM #AsFix WHERE Tag = N'CELL');
DELETE ol FROM Audit.OperationLog ol
    INNER JOIN Oee.DowntimeEvent de ON de.Id = ol.EntityId
    WHERE de.LocationId = @Cell
      AND ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent');
DELETE FROM Oee.DowntimeEvent WHERE LocationId = @Cell;
IF OBJECT_ID(N'tempdb..#AsFix') IS NOT NULL DROP TABLE #AsFix;
GO
