-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/060_ListMachiningDestinations.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Description:  Tests for Location.Location_ListMachiningDestinations (Arc 2 Phase 4
--               tail): the Trim OUT dropdown's Machining-line destinations.
--                 - at least one destination returned
--                 - every returned row is a Cell-tier (HierarchyLevel 4) location
--                   whose Name starts with 'Machining In'
--                 - a known Machining-In Cell (MA1-COMPBR-MIN) IS present
--                 - a known label Printer Cell (MA1-COMPBR-MIN-P1) is NOT present
--                 - a known Machining-OUT terminal (MA1-FPRPY-MOUT) is NOT present
--               Read-only -- no fixtures, no cleanup.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0024_PlantFloor_Movement_Trim/060_ListMachiningDestinations.sql';
GO

IF OBJECT_ID(N'tempdb..#D') IS NOT NULL DROP TABLE #D;
CREATE TABLE #D (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), AreaCode NVARCHAR(50), AreaName NVARCHAR(200));
INSERT INTO #D EXEC Location.Location_ListMachiningDestinations;
GO

-- at least one row
DECLARE @Cnt INT = (SELECT COUNT(*) FROM #D);
DECLARE @AtLeastOne BIT = CASE WHEN @Cnt >= 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachDest] at least one destination returned', @Condition = @AtLeastOne;

-- every row is a Cell-tier (HierarchyLevel 4) 'Machining In%' location
DECLARE @Bad INT = (
    SELECT COUNT(*)
    FROM #D d
    LEFT JOIN Location.Location l ON l.Id = d.Id
    LEFT JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    LEFT JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel <> 4 OR l.Name NOT LIKE N'Machining In%' OR l.DeprecatedAt IS NOT NULL);
EXEC test.Assert_RowCount @TestName = N'[MachDest] every row is a Cell-tier Machining-In destination',
    @ExpectedCount = 0, @ActualCount = @Bad;

-- a known Machining-In Cell is present
DECLARE @HasCompBr INT = (SELECT COUNT(*) FROM #D d INNER JOIN Location.Location l ON l.Id = d.Id WHERE l.Code = N'MA1-COMPBR-MIN');
EXEC test.Assert_RowCount @TestName = N'[MachDest] MA1-COMPBR-MIN (Machining In Cell) present',
    @ExpectedCount = 1, @ActualCount = @HasCompBr;

-- a known label printer Cell is NOT present
DECLARE @HasPrinter INT = (SELECT COUNT(*) FROM #D d INNER JOIN Location.Location l ON l.Id = d.Id WHERE l.Code = N'MA1-COMPBR-MIN-P1');
EXEC test.Assert_RowCount @TestName = N'[MachDest] label printer Cell excluded',
    @ExpectedCount = 0, @ActualCount = @HasPrinter;

-- a known Machining-OUT terminal is NOT present (only Machining-IN queues are destinations)
DECLARE @HasMout INT = (SELECT COUNT(*) FROM #D d INNER JOIN Location.Location l ON l.Id = d.Id WHERE l.Code = N'MA1-FPRPY-MOUT');
EXEC test.Assert_RowCount @TestName = N'[MachDest] Machining-OUT terminal excluded',
    @ExpectedCount = 0, @ActualCount = @HasMout;
GO

IF OBJECT_ID(N'tempdb..#D') IS NOT NULL DROP TABLE #D;
GO

EXEC test.EndTestFile;
GO
