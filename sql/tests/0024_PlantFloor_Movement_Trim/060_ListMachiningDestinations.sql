-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/060_ListMachiningDestinations.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Updated:      2026-07-06 - line-deposit model: destinations are the LINES
--               (WorkCenter/HierarchyLevel 3 ProductionLine), not the HL4
--               'Machining In' cells. Trim OUT deposits the whole LOT at the
--               line; Machining IN reads the line's FIFO via its terminal zone.
-- Description:  Tests for Location.Location_ListMachiningDestinations (Arc 2 Phase 4
--               tail): the Trim OUT dropdown's Machining-line destinations.
--                 - at least one destination returned
--                 - every returned row is a WorkCenter-tier (HierarchyLevel 3)
--                   ProductionLine that has a 'Machining In%' receiving cell
--                 - a known Machining line (MA1-5GOF) IS present
--                 - the Machining-In CELL (MA1-5GOF-MIN) is NOT present (it is a
--                   child cell, not the line)
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

-- every row is a WorkCenter-tier (HierarchyLevel 3) ProductionLine with a Machining-In child cell
DECLARE @Bad INT = (
    SELECT COUNT(*)
    FROM #D d
    LEFT JOIN Location.Location l ON l.Id = d.Id
    LEFT JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    LEFT JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel <> 3
       OR ltd.Code <> N'ProductionLine'
       OR l.DeprecatedAt IS NOT NULL
       OR NOT EXISTS (SELECT 1 FROM Location.Location c
                      WHERE c.ParentLocationId = l.Id
                        AND c.DeprecatedAt IS NULL
                        AND c.Name LIKE N'Machining In%'));
EXEC test.Assert_RowCount @TestName = N'[MachDest] every row is a ProductionLine with a Machining-In cell',
    @ExpectedCount = 0, @ActualCount = @Bad;

-- a known Machining line is present (the LINE, not its Machining-In cell)
DECLARE @HasLine INT = (SELECT COUNT(*) FROM #D d INNER JOIN Location.Location l ON l.Id = d.Id WHERE l.Code = N'MA1-5GOF');
EXEC test.Assert_RowCount @TestName = N'[MachDest] MA1-5GOF (Machining line) present',
    @ExpectedCount = 1, @ActualCount = @HasLine;

-- the Machining-In CELL is NOT present (destinations are lines now, not cells)
DECLARE @HasCell INT = (SELECT COUNT(*) FROM #D d INNER JOIN Location.Location l ON l.Id = d.Id WHERE l.Code = N'MA1-5GOF-MIN');
EXEC test.Assert_RowCount @TestName = N'[MachDest] Machining-In CELL excluded (line-deposit model)',
    @ExpectedCount = 0, @ActualCount = @HasCell;

-- a known label printer Cell is NOT present
DECLARE @HasPrinter INT = (SELECT COUNT(*) FROM #D d INNER JOIN Location.Location l ON l.Id = d.Id WHERE l.Code = N'MA1-COMPBR-MIN-P1');
EXEC test.Assert_RowCount @TestName = N'[MachDest] label printer Cell excluded',
    @ExpectedCount = 0, @ActualCount = @HasPrinter;

-- a known Machining-OUT terminal is NOT present (only lines are destinations)
DECLARE @HasMout INT = (SELECT COUNT(*) FROM #D d INNER JOIN Location.Location l ON l.Id = d.Id WHERE l.Code = N'MA1-FPRPY-MOUT');
EXEC test.Assert_RowCount @TestName = N'[MachDest] Machining-OUT terminal excluded',
    @ExpectedCount = 0, @ActualCount = @HasMout;
GO

IF OBJECT_ID(N'tempdb..#D') IS NOT NULL DROP TABLE #D;
GO

EXEC test.EndTestFile;
GO
