-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/080_audit_shape.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Arc 2 Phase 8 audit-readability convention. A DowntimeStarted
--               OperationLog row must carry the mid-dot (NCHAR 183) narrative
--               Description and a resolved-FK Location {Id,Code,Name} in NewValue.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/080_audit_shape.sql';
GO

IF OBJECT_ID(N'tempdb..#AudFix') IS NOT NULL DROP TABLE #AudFix;
CREATE TABLE #AudFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO

DECLARE @CellId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 4 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @Op BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @s EXEC Oee.DowntimeEvent_Start @LocationId = @CellId, @DowntimeSourceCodeId = @Op, @AppUserId = 1;
DECLARE @evt BIGINT = (SELECT NewId FROM @s);
INSERT INTO #AudFix (Tag, Val) VALUES (N'CELL', @CellId), (N'EVT', @evt);
GO

-- =============================================
-- Test 1: Description carries the mid-dot; NewValue has resolved Location
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #AudFix WHERE Tag = N'CELL');
DECLARE @Evt  BIGINT = (SELECT Val FROM #AudFix WHERE Tag = N'EVT');
DECLARE @CellCode NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = @Cell);

DECLARE @desc NVARCHAR(MAX), @newVal NVARCHAR(MAX);
SELECT TOP 1 @desc = ol.Description, @newVal = ol.NewValue
FROM Audit.OperationLog ol
WHERE ol.EntityId = @Evt
  AND ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent')
  AND ol.LogEventTypeId  = (SELECT Id FROM Audit.LogEventType  WHERE Code = N'DowntimeStarted')
ORDER BY ol.Id DESC;

DECLARE @hasMidDot BIT = CASE WHEN CHARINDEX(NCHAR(183), @desc) > 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Audit] DowntimeStarted Description carries the mid-dot', @Condition = @hasMidDot;

DECLARE @resolvedCode NVARCHAR(50) = JSON_VALUE(@newVal, '$.Location.Code');
EXEC test.Assert_IsEqual @TestName = N'[Audit] NewValue has resolved Location.Code',
    @Expected = @CellCode, @Actual = @resolvedCode;
GO

-- ---- cleanup ----
DECLARE @Cell BIGINT = (SELECT Val FROM #AudFix WHERE Tag = N'CELL');
DELETE ol FROM Audit.OperationLog ol INNER JOIN Oee.DowntimeEvent de ON de.Id = ol.EntityId
    WHERE de.LocationId = @Cell AND ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent');
DELETE FROM Oee.DowntimeEvent WHERE LocationId = @Cell;
IF OBJECT_ID(N'tempdb..#AudFix') IS NOT NULL DROP TABLE #AudFix;
GO
