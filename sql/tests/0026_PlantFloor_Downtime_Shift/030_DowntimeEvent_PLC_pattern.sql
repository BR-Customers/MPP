-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/030_DowntimeEvent_PLC_pattern.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Arc 2 Phase 8 PLC-driven downtime (FDS-09-010). The PLC opens an
--               event with source=PLC, no reason, and no operator. Asserts the
--               row carries DowntimeSourceCode=PLC, NULL reason, NULL AppUserId.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/030_DowntimeEvent_PLC_pattern.sql';
GO

IF OBJECT_ID(N'tempdb..#PlcFix') IS NOT NULL DROP TABLE #PlcFix;
CREATE TABLE #PlcFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO

DECLARE @CellId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 4 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @PlcId BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'PLC');
INSERT INTO #PlcFix (Tag, Val) VALUES (N'CELL', @CellId), (N'PLC', @PlcId);
GO

-- =============================================
-- Test 1: PLC start (no operator, no reason)
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #PlcFix WHERE Tag = N'CELL');
DECLARE @Plc  BIGINT = (SELECT Val FROM #PlcFix WHERE Tag = N'PLC');
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @s EXEC Oee.DowntimeEvent_Start @LocationId = @Cell, @DowntimeSourceCodeId = @Plc;  -- AppUserId omitted (NULL)
DECLARE @ok BIT = (SELECT Status FROM @s);
DECLARE @id BIGINT = (SELECT NewId FROM @s);
EXEC test.Assert_IsTrue @TestName = N'[PLC] PLC-source start succeeds', @Condition = @ok;
DECLARE @match INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent de
    INNER JOIN Oee.DowntimeSourceCode sc ON sc.Id = de.DowntimeSourceCodeId
    WHERE de.Id = @id AND sc.Code = N'PLC' AND de.DowntimeReasonCodeId IS NULL AND de.AppUserId IS NULL AND de.EndedAt IS NULL);
EXEC test.Assert_RowCount @TestName = N'[PLC] event is PLC-source, NULL reason, NULL user, open',
    @ExpectedCount = 1, @ActualCount = @match;
INSERT INTO #PlcFix (Tag, Val) VALUES (N'EVT', @id);
GO

-- ---- cleanup ----
DECLARE @Cell BIGINT = (SELECT Val FROM #PlcFix WHERE Tag = N'CELL');
DELETE ol FROM Audit.OperationLog ol INNER JOIN Oee.DowntimeEvent de ON de.Id = ol.EntityId
    WHERE de.LocationId = @Cell AND ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent');
DELETE FROM Oee.DowntimeEvent WHERE LocationId = @Cell;
IF OBJECT_ID(N'tempdb..#PlcFix') IS NOT NULL DROP TABLE #PlcFix;
GO
