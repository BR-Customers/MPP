-- =============================================
-- File:         0115_TerminalDefaultMachines/010_Terminal_ListDefaultMachines.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-23
-- Description:  Tests for Location.Terminal_ListDefaultMachines (migration 0115).
--               Asserts:
--                 * Listed ids that are active equipment cells under the
--                   terminal's parent come back, ordered by Code.
--                 * A deprecated press, a press in ANOTHER room, the terminal
--                   itself, junk text and blanks in the list are all dropped.
--                 * No attribute row / blank value -> empty set.
--                 * Unknown terminal id -> empty set.
--
--               Fixture:
--                 TEST-DM-AREA (Area, DefId 3)
--                   +- TEST-DM-M1, TEST-DM-M2, TEST-DM-M3 (DieCastMachine, DefId 8)
--                   +- TEST-DM-MDEP (DieCastMachine, deprecated)
--                   +- TEST-DM-TERM  (Terminal, DefId 7) -- DefaultMachines set
--                   +- TEST-DM-TERM2 (Terminal, DefId 7) -- no attribute
--                   +- TEST-DM-TERM3 (Terminal, DefId 7) -- blank attribute
--                 TEST-DM-AREA2 (Area)
--                   +- TEST-DM-OTHER (DieCastMachine) -- another room
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0115_TerminalDefaultMachines/010_Terminal_ListDefaultMachines.sql';
GO

-- ---- teardown any prior fixtures (attributes, then children, then parents) ----
DELETE la FROM Location.LocationAttribute la
INNER JOIN Location.Location l ON l.Id = la.LocationId
WHERE l.Code LIKE N'TEST-DM-%';
DELETE FROM Location.Location WHERE Code IN (N'TEST-DM-M1', N'TEST-DM-M2', N'TEST-DM-M3', N'TEST-DM-MDEP',
                                              N'TEST-DM-TERM', N'TEST-DM-TERM2', N'TEST-DM-TERM3', N'TEST-DM-OTHER');
DELETE FROM Location.Location WHERE Code IN (N'TEST-DM-AREA', N'TEST-DM-AREA2');
GO

-- ---- build the fixture ----
DECLARE @SiteId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (3, @SiteId, N'Test DM Area',  N'TEST-DM-AREA',  N'DefaultMachines test area', 960),
       (3, @SiteId, N'Test DM Area2', N'TEST-DM-AREA2', N'DefaultMachines other room', 961);

DECLARE @AreaId  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DM-AREA');
DECLARE @Area2Id BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DM-AREA2');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (8, @AreaId,  N'DM Machine 1', N'TEST-DM-M1',    N'Press', 1),
       (8, @AreaId,  N'DM Machine 2', N'TEST-DM-M2',    N'Press', 2),
       (8, @AreaId,  N'DM Machine 3', N'TEST-DM-M3',    N'Press', 3),
       (7, @AreaId,  N'DM Terminal',  N'TEST-DM-TERM',  N'Terminal with defaults', 4),
       (7, @AreaId,  N'DM Terminal2', N'TEST-DM-TERM2', N'Terminal without attribute', 5),
       (7, @AreaId,  N'DM Terminal3', N'TEST-DM-TERM3', N'Terminal with blank attribute', 6),
       (8, @Area2Id, N'DM Other',     N'TEST-DM-OTHER', N'Press in another room', 1);

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, DeprecatedAt)
VALUES (8, @AreaId, N'DM Machine Depr', N'TEST-DM-MDEP', N'Deprecated press', 7, SYSUTCDATETIME());

DECLARE @DefId BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                         WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'DefaultMachines' AND DeprecatedAt IS NULL);
DECLARE @M1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DM-M1');
DECLARE @M3 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DM-M3');
DECLARE @MDep BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DM-MDEP');
DECLARE @Other BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DM-OTHER');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DM-TERM');
DECLARE @Term3 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DM-TERM3');

-- M3 listed before M1 (order must come from Code), plus every kind of junk the
-- proc has to drop: deprecated press, another room's press, the terminal
-- itself, non-numeric text, and empty entries.
DECLARE @List NVARCHAR(400) = CAST(@M3 AS NVARCHAR(20)) + N', ' + CAST(@M1 AS NVARCHAR(20)) + N','
    + CAST(@MDep AS NVARCHAR(20)) + N',' + CAST(@Other AS NVARCHAR(20)) + N',' + CAST(@Term AS NVARCHAR(20))
    + N',abc,,';

INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue)
VALUES (@Term,  @DefId, @List),
       (@Term3, @DefId, N'  ');
GO

-- =============================================
-- Test 0: migration 0115 seeded the definition on LTD 7
-- =============================================
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Location.LocationAttributeDefinition
                    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'DefaultMachines'
                      AND DataType = N'NVARCHAR' AND IsRequired = 0 AND DeprecatedAt IS NULL);
EXEC test.Assert_RowCount
    @TestName = N'[DefaultMachines] 0115 seeded one optional NVARCHAR definition on Terminal',
    @ExpectedCount = 1, @ActualCount = @Cnt;
GO

-- =============================================
-- Test 1: only the qualifying presses come back, ordered by Code
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DM-TERM');
DECLARE @Rows INT, @Codes NVARCHAR(400);
CREATE TABLE #DM (LocationId BIGINT, Code NVARCHAR(50));
INSERT INTO #DM EXEC Location.Terminal_ListDefaultMachines @TerminalId = @Term;
SELECT @Rows = COUNT(*) FROM #DM;
SELECT @Codes = STRING_AGG(Code, N',') WITHIN GROUP (ORDER BY Code) FROM #DM;
DROP TABLE #DM;
EXEC test.Assert_RowCount
    @TestName = N'[DefaultMachines] Two of the seven listed ids qualify',
    @ExpectedCount = 2, @ActualCount = @Rows;
EXEC test.Assert_IsEqual
    @TestName = N'[DefaultMachines] M1+M3 kept; deprecated, other room, terminal, junk dropped',
    @Expected = N'TEST-DM-M1,TEST-DM-M3', @Actual = @Codes;
GO

-- =============================================
-- Test 2: no attribute row -> empty set
-- =============================================
DECLARE @Term2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DM-TERM2');
DECLARE @Rows INT;
CREATE TABLE #DM2 (LocationId BIGINT, Code NVARCHAR(50));
INSERT INTO #DM2 EXEC Location.Terminal_ListDefaultMachines @TerminalId = @Term2;
SELECT @Rows = COUNT(*) FROM #DM2;
DROP TABLE #DM2;
EXEC test.Assert_RowCount
    @TestName = N'[DefaultMachines] Terminal with no attribute -> empty set',
    @ExpectedCount = 0, @ActualCount = @Rows;
GO

-- =============================================
-- Test 3: blank attribute value -> empty set
-- =============================================
DECLARE @Term3 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DM-TERM3');
DECLARE @Rows INT;
CREATE TABLE #DM3 (LocationId BIGINT, Code NVARCHAR(50));
INSERT INTO #DM3 EXEC Location.Terminal_ListDefaultMachines @TerminalId = @Term3;
SELECT @Rows = COUNT(*) FROM #DM3;
DROP TABLE #DM3;
EXEC test.Assert_RowCount
    @TestName = N'[DefaultMachines] Blank attribute value -> empty set',
    @ExpectedCount = 0, @ActualCount = @Rows;
GO

-- =============================================
-- Test 4: unknown terminal id -> empty set (never errors)
-- =============================================
DECLARE @Rows INT;
CREATE TABLE #DM4 (LocationId BIGINT, Code NVARCHAR(50));
INSERT INTO #DM4 EXEC Location.Terminal_ListDefaultMachines @TerminalId = -1;
SELECT @Rows = COUNT(*) FROM #DM4;
DROP TABLE #DM4;
EXEC test.Assert_RowCount
    @TestName = N'[DefaultMachines] Unknown terminal id -> empty set',
    @ExpectedCount = 0, @ActualCount = @Rows;
GO

-- ---- cleanup ----
DELETE la FROM Location.LocationAttribute la
INNER JOIN Location.Location l ON l.Id = la.LocationId
WHERE l.Code LIKE N'TEST-DM-%';
DELETE FROM Location.Location WHERE Code IN (N'TEST-DM-M1', N'TEST-DM-M2', N'TEST-DM-M3', N'TEST-DM-MDEP',
                                              N'TEST-DM-TERM', N'TEST-DM-TERM2', N'TEST-DM-TERM3', N'TEST-DM-OTHER');
DELETE FROM Location.Location WHERE Code IN (N'TEST-DM-AREA', N'TEST-DM-AREA2');
GO

EXEC test.EndTestFile;
GO
