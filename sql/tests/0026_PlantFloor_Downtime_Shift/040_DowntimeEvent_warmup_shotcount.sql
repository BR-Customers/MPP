-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/040_DowntimeEvent_warmup_shotcount.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Arc 2 Phase 8 warm-up shot tracking (UJ-14). A Setup-type downtime
--               carries the warm-up ShotCount on the DowntimeEvent row itself.
--               Asserts @ShotCount persists on start.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/040_DowntimeEvent_warmup_shotcount.sql';
GO

IF OBJECT_ID(N'tempdb..#WuFix') IS NOT NULL DROP TABLE #WuFix;
CREATE TABLE #WuFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO

DECLARE @CellId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 4 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @Op BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
INSERT INTO #WuFix (Tag, Val) VALUES (N'CELL', @CellId), (N'OP', @Op);
GO

-- =============================================
-- Test 1: ShotCount persists on a Setup/warm-up downtime
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #WuFix WHERE Tag = N'CELL');
DECLARE @Op   BIGINT = (SELECT Val FROM #WuFix WHERE Tag = N'OP');
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @s EXEC Oee.DowntimeEvent_Start
    @LocationId = @Cell, @DowntimeSourceCodeId = @Op, @ShotCount = 12, @AppUserId = 1;
DECLARE @id BIGINT = (SELECT NewId FROM @s);
DECLARE @shot INT = (SELECT ShotCount FROM Oee.DowntimeEvent WHERE Id = @id);
DECLARE @shotStr NVARCHAR(10) = CAST(@shot AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Warmup] ShotCount persists (=12)', @Expected = N'12', @Actual = @shotStr;
GO

-- ---- cleanup ----
DECLARE @Cell BIGINT = (SELECT Val FROM #WuFix WHERE Tag = N'CELL');
DELETE ol FROM Audit.OperationLog ol INNER JOIN Oee.DowntimeEvent de ON de.Id = ol.EntityId
    WHERE de.LocationId = @Cell AND ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent');
DELETE FROM Oee.DowntimeEvent WHERE LocationId = @Cell;
IF OBJECT_ID(N'tempdb..#WuFix') IS NOT NULL DROP TABLE #WuFix;
GO
