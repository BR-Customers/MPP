-- =============================================
-- File:         0026_Tools_CellMount/020_ListMountableForCell.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Tools.Tool_ListMountableForCell -- unmounted compatible tools
--               for a cell. Unmounted die present; mounted die excluded;
--               die excluded for a non-DieCastMachine location (compat filter).
--               Self-isolating: CMC- fixtures, own cleanup.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_Tools_CellMount/020_ListMountableForCell.sql';
GO

-- ---- setup ----
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'CMC-%');
DELETE FROM Tools.Tool WHERE Code LIKE N'CMC-%';

DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType      WHERE Code = N'Die');
DECLARE @Active  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');

CREATE TABLE #c1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #c1 EXEC Tools.Tool_Create
    @ToolTypeId = @DieType, @Code = N'CMC-DIE-FREE', @Name = N'Cell Mount Die Free',
    @StatusCodeId = @Active, @AppUserId = 1;
DROP TABLE #c1;

CREATE TABLE #c2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #c2 EXEC Tools.Tool_Create
    @ToolTypeId = @DieType, @Code = N'CMC-DIE-MNT', @Name = N'Cell Mount Die Mounted',
    @StatusCodeId = @Active, @AppUserId = 1;
DROP TABLE #c2;

-- Two distinct DieCastMachine cells; the test cell free, the other holds CMC-DIE-MNT.
DECLARE @Cell  BIGINT = (SELECT TOP 1 Id FROM Location.Location
    WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL ORDER BY Id DESC);
DECLARE @Cell2 BIGINT = (SELECT Id FROM Location.Location
    WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL
    ORDER BY Id DESC OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY);
DELETE FROM Tools.ToolAssignment WHERE CellLocationId IN (@Cell, @Cell2) AND ReleasedAt IS NULL;

DECLARE @MntTool BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CMC-DIE-MNT');
CREATE TABLE #a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #a EXEC Tools.ToolAssignment_Assign
    @ToolId = @MntTool,
    @CellLocationId = @Cell2, @Notes = N'mounted elsewhere', @AppUserId = 1;
DROP TABLE #a;

CREATE TABLE #ctx (CellId BIGINT);
INSERT INTO #ctx (CellId) VALUES (@Cell);
GO

-- ---- Test 1: free die present, mounted die absent (DieCastMachine cell) ----
DECLARE @Cell BIGINT = (SELECT CellId FROM #ctx);
CREATE TABLE #m (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #m EXEC Tools.Tool_ListMountableForCell @CellLocationId = @Cell;

DECLARE @freeCnt NVARCHAR(2) = (SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM #m WHERE Code = N'CMC-DIE-FREE');
EXEC test.Assert_IsEqual @TestName = N'[ListMountable] unmounted die present',
    @Expected = N'1', @Actual = @freeCnt;

DECLARE @mntCnt NVARCHAR(2) = (SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM #m WHERE Code = N'CMC-DIE-MNT');
EXEC test.Assert_IsEqual @TestName = N'[ListMountable] mounted die excluded',
    @Expected = N'0', @Actual = @mntCnt;
DROP TABLE #m;
GO

-- ---- Test 2: die excluded for a non-DieCastMachine location (compat filter) ----
DECLARE @Area BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD');
CREATE TABLE #m (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #m EXEC Tools.Tool_ListMountableForCell @CellLocationId = @Area;
DECLARE @freeOnArea NVARCHAR(2) = (SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM #m WHERE Code = N'CMC-DIE-FREE');
EXEC test.Assert_IsEqual @TestName = N'[ListMountable] die excluded for non-DieCastMachine location',
    @Expected = N'0', @Actual = @freeOnArea;
DROP TABLE #m;
GO

-- ---- teardown ----
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'CMC-%');
DELETE FROM Tools.Tool WHERE Code LIKE N'CMC-%';
GO

EXEC test.PrintSummary;
GO
