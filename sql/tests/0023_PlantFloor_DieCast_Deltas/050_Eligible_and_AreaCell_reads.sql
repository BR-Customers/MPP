-- =============================================
-- File:    0023_PlantFloor_DieCast_Deltas/050_Eligible_and_AreaCell_reads.sql
-- Author:  Blue Ridge Automation
-- Created: 2026-06-16
-- Description: Tests for the two die-cast-entry dropdown read procs:
--   * Parts.Item_ListEligibleForLocation  (eligibility-constrained Item dropdown)
--   * Location.Location_ListCellsForArea   (area-scoped Cell dropdown; excludes
--                                           Terminal/Printer infrastructure)
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0023_PlantFloor_DieCast_Deltas/050_Eligible_and_AreaCell_reads.sql';
GO

-- =============================================
-- Test 1: Item_ListEligibleForLocation returns the eligible Items for a location
-- =============================================
DECLARE @Loc BIGINT, @Item BIGINT;
SELECT TOP 1 @Loc = eil.LocationId, @Item = eil.ItemId
FROM Parts.v_EffectiveItemLocation eil
INNER JOIN Parts.Item i ON i.Id = eil.ItemId AND i.DeprecatedAt IS NULL
ORDER BY eil.LocationId, eil.ItemId;

DECLARE @R TABLE (Id BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), MaxLotSize INT, MaxParts INT);
INSERT INTO @R EXEC Parts.Item_ListEligibleForLocation @LocationId = @Loc;

DECLARE @HasItem NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM @R WHERE Id = @Item) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[EL] eligible Item present for its location', @Expected = N'1', @Actual = @HasItem;

-- count matches the distinct non-deprecated eligible items at that location
DECLARE @ExpCnt INT = (SELECT COUNT(DISTINCT eil.ItemId) FROM Parts.v_EffectiveItemLocation eil
    INNER JOIN Parts.Item i ON i.Id = eil.ItemId AND i.DeprecatedAt IS NULL
    WHERE eil.LocationId = @Loc);
DECLARE @GotCnt INT = (SELECT COUNT(*) FROM @R);
DECLARE @ExpStr NVARCHAR(10) = CAST(@ExpCnt AS NVARCHAR(10));
DECLARE @GotStr NVARCHAR(10) = CAST(@GotCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[EL] count matches distinct eligible items', @Expected = @ExpStr, @Actual = @GotStr;

-- PartNumber populated (resolved-name join)
DECLARE @NullPn INT = (SELECT COUNT(*) FROM @R WHERE PartNumber IS NULL);
DECLARE @NullPnStr NVARCHAR(10) = CAST(@NullPn AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[EL] PartNumber populated', @Expected = N'0', @Actual = @NullPnStr;
GO

-- =============================================
-- Test 2: ineligible location -> 0 rows (no error)
-- =============================================
DECLARE @R2 TABLE (Id BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), MaxLotSize INT, MaxParts INT);
INSERT INTO @R2 EXEC Parts.Item_ListEligibleForLocation @LocationId = 999999999;
DECLARE @C2 NVARCHAR(10) = CAST((SELECT COUNT(*) FROM @R2) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[EL] unknown location returns 0 rows', @Expected = N'0', @Actual = @C2;
GO

-- =============================================
-- Test 3: Location_ListCellsForArea returns equipment cells, excludes Terminal/Printer
-- =============================================
DECLARE @AreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1');
DECLARE @MachineId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M01');
DECLARE @TermId    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-T1');
DECLARE @PrinterId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-T1-P1');

DECLARE @AC TABLE (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Kind NVARCHAR(200));
INSERT INTO @AC EXEC Location.Location_ListCellsForArea @AreaLocationId = @AreaId;

DECLARE @HasMachine NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM @AC WHERE LocationId = @MachineId) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[AC] DieCastMachine cell included', @Expected = N'1', @Actual = @HasMachine;

DECLARE @HasTerm NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM @AC WHERE LocationId = @TermId) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[AC] Terminal cell EXCLUDED', @Expected = N'0', @Actual = @HasTerm;

DECLARE @HasPrinter NVARCHAR(10) = CASE WHEN @PrinterId IS NOT NULL AND EXISTS (SELECT 1 FROM @AC WHERE LocationId = @PrinterId) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[AC] Printer cell EXCLUDED', @Expected = N'0', @Actual = @HasPrinter;

-- count matches the DieCastMachine cells under DC1 computed independently
DECLARE @ExpCells INT = (
    SELECT COUNT(*) FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE l.ParentLocationId = @AreaId AND l.DeprecatedAt IS NULL
      AND lt.Code = N'Cell' AND ltd.Code NOT IN (N'Terminal', N'Printer'));
DECLARE @GotCells INT = (SELECT COUNT(*) FROM @AC);
DECLARE @ExpCellsStr NVARCHAR(10) = CAST(@ExpCells AS NVARCHAR(10));
DECLARE @GotCellsStr NVARCHAR(10) = CAST(@GotCells AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[AC] equipment-cell count matches', @Expected = @ExpCellsStr, @Actual = @GotCellsStr;
GO

-- =============================================
-- Test 4: unknown area -> 0 rows
-- =============================================
DECLARE @AC2 TABLE (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Kind NVARCHAR(200));
INSERT INTO @AC2 EXEC Location.Location_ListCellsForArea @AreaLocationId = 999999999;
DECLARE @C4 NVARCHAR(10) = CAST((SELECT COUNT(*) FROM @AC2) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[AC] unknown area returns 0 rows', @Expected = N'0', @Actual = @C4;
GO

EXEC test.EndTestFile;
GO
