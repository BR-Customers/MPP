-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/060_ListMachiningDestinations.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Description:  Tests for Location.Location_ListMachiningDestinations v1.1
--               (line-resident, Jacques 2026-07-06): the Trim OUT dropdown's
--               destinations are the machining PRODUCTION LINES (WorkCenter tier).
--                 - at least one destination returned
--                 - every returned row is a WorkCenter-tier (HierarchyLevel 3)
--                   line with a 'Machining In%' Cell child
--                 - a known machining line (MA1-COMPBR) IS present
--                 - its Machining-In Cell (MA1-COMPBR-MIN) is NOT present
--                 - a known label Printer Cell (MA1-COMPBR-MIN-P1) is NOT present
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

-- every row is a WorkCenter-tier (HierarchyLevel 3) line with a Machining-In Cell child
DECLARE @Bad INT = (
    SELECT COUNT(*)
    FROM #D d
    LEFT JOIN Location.Location l ON l.Id = d.Id
    LEFT JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    LEFT JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel <> 3 OR l.DeprecatedAt IS NOT NULL
       OR NOT EXISTS (SELECT 1 FROM Location.Location c
                      WHERE c.ParentLocationId = l.Id AND c.DeprecatedAt IS NULL
                        AND c.Name LIKE N'Machining In%'));
EXEC test.Assert_RowCount @TestName = N'[MachDest] every row is a WorkCenter-tier machining line',
    @ExpectedCount = 0, @ActualCount = @Bad;

-- a known machining LINE is present
DECLARE @HasCompBr INT = (SELECT COUNT(*) FROM #D d INNER JOIN Location.Location l ON l.Id = d.Id WHERE l.Code = N'MA1-COMPBR');
EXEC test.Assert_RowCount @TestName = N'[MachDest] MA1-COMPBR (machining line) present',
    @ExpectedCount = 1, @ActualCount = @HasCompBr;

-- the line's Machining-In Cell is NOT a destination any more (line-resident)
DECLARE @HasMinCell INT = (SELECT COUNT(*) FROM #D d INNER JOIN Location.Location l ON l.Id = d.Id WHERE l.Code = N'MA1-COMPBR-MIN');
EXEC test.Assert_RowCount @TestName = N'[MachDest] Machining-In Cell excluded (line-resident)',
    @ExpectedCount = 0, @ActualCount = @HasMinCell;

-- a known label printer Cell is NOT present
DECLARE @HasPrinter INT = (SELECT COUNT(*) FROM #D d INNER JOIN Location.Location l ON l.Id = d.Id WHERE l.Code = N'MA1-COMPBR-MIN-P1');
EXEC test.Assert_RowCount @TestName = N'[MachDest] label printer Cell excluded',
    @ExpectedCount = 0, @ActualCount = @HasPrinter;
GO

IF OBJECT_ID(N'tempdb..#D') IS NOT NULL DROP TABLE #D;
GO

EXEC test.EndTestFile;
GO
