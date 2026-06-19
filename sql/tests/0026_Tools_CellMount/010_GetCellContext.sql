-- =============================================
-- File:         0026_Tools_CellMount/010_GetCellContext.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Tools.ToolAssignment_GetCellContext -- one row always.
--               empty mount-target / occupied mount-target / non-target /
--               unknown cell. DieCastMachine (DefId 8) is the mount target.
--               Self-isolating: CMC- fixtures, own cleanup.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_Tools_CellMount/010_GetCellContext.sql';
GO

-- ---- setup ----
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'CMC-%');
DELETE FROM Tools.Tool WHERE Code LIKE N'CMC-%';

DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType      WHERE Code = N'Die');
DECLARE @Active  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');

CREATE TABLE #c (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #c EXEC Tools.Tool_Create
    @ToolTypeId = @DieType, @Code = N'CMC-DIE-1', @Name = N'Cell Mount Die 1',
    @StatusCodeId = @Active, @AppUserId = 1;
DROP TABLE #c;

-- Pick a DieCastMachine cell (DefId 8); guarantee it is free.
DECLARE @Cell BIGINT = (SELECT TOP 1 Id FROM Location.Location
    WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL ORDER BY Id DESC);
DELETE FROM Tools.ToolAssignment WHERE CellLocationId = @Cell AND ReleasedAt IS NULL;

CREATE TABLE #ctx (CellId BIGINT, ToolId BIGINT);
INSERT INTO #ctx (CellId, ToolId)
VALUES (@Cell, (SELECT Id FROM Tools.Tool WHERE Code = N'CMC-DIE-1'));
GO

-- ---- Test 1: empty mount-target cell ----
DECLARE @Cell BIGINT = (SELECT CellId FROM #ctx);
CREATE TABLE #g (IsMountTarget BIT, ToolAssignmentId BIGINT, ToolId BIGINT,
    ToolCode NVARCHAR(50), ToolName NVARCHAR(100), ToolTypeCode NVARCHAR(50),
    AssignedAt DATETIME2(3), AssignedBy NVARCHAR(200));
INSERT INTO #g EXEC Tools.ToolAssignment_GetCellContext @CellLocationId = @Cell;

DECLARE @rc INT = (SELECT COUNT(*) FROM #g);
EXEC test.Assert_RowCount @TestName = N'[GetCellContext empty] exactly one row',
    @ExpectedCount = 1, @ActualCount = @rc;

DECLARE @imt NVARCHAR(1) = (SELECT CAST(IsMountTarget AS NVARCHAR(1)) FROM #g);
EXEC test.Assert_IsEqual @TestName = N'[GetCellContext empty] IsMountTarget=1',
    @Expected = N'1', @Actual = @imt;

DECLARE @nullTool NVARCHAR(1) = (SELECT CASE WHEN ToolId IS NULL THEN N'1' ELSE N'0' END FROM #g);
EXEC test.Assert_IsEqual @TestName = N'[GetCellContext empty] ToolId is NULL',
    @Expected = N'1', @Actual = @nullTool;
DROP TABLE #g;
GO

-- ---- Test 2: occupied mount-target cell ----
DECLARE @Cell BIGINT = (SELECT CellId FROM #ctx);
DECLARE @Tool BIGINT = (SELECT ToolId FROM #ctx);
CREATE TABLE #a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #a EXEC Tools.ToolAssignment_Assign
    @ToolId = @Tool, @CellLocationId = @Cell, @Notes = N'CMC test', @AppUserId = 1;
DROP TABLE #a;

CREATE TABLE #g (IsMountTarget BIT, ToolAssignmentId BIGINT, ToolId BIGINT,
    ToolCode NVARCHAR(50), ToolName NVARCHAR(100), ToolTypeCode NVARCHAR(50),
    AssignedAt DATETIME2(3), AssignedBy NVARCHAR(200));
INSERT INTO #g EXEC Tools.ToolAssignment_GetCellContext @CellLocationId = @Cell;

DECLARE @code NVARCHAR(50) = (SELECT ToolCode FROM #g);
EXEC test.Assert_IsEqual @TestName = N'[GetCellContext occupied] ToolCode = CMC-DIE-1',
    @Expected = N'CMC-DIE-1', @Actual = @code;

DECLARE @ttc NVARCHAR(50) = (SELECT ToolTypeCode FROM #g);
EXEC test.Assert_IsEqual @TestName = N'[GetCellContext occupied] ToolTypeCode = Die',
    @Expected = N'Die', @Actual = @ttc;

DECLARE @by NVARCHAR(200) = (SELECT AssignedBy FROM #g);
EXEC test.Assert_IsNotNull @TestName = N'[GetCellContext occupied] AssignedBy resolved',
    @Value = @by;

DECLARE @imt2 NVARCHAR(1) = (SELECT CAST(IsMountTarget AS NVARCHAR(1)) FROM #g);
EXEC test.Assert_IsEqual @TestName = N'[GetCellContext occupied] IsMountTarget=1',
    @Expected = N'1', @Actual = @imt2;
DROP TABLE #g;
GO

-- ---- Test 3: non-mount-target location (Site MPP-MAD or any non-DieCastMachine) ----
DECLARE @Area BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD');
CREATE TABLE #g (IsMountTarget BIT, ToolAssignmentId BIGINT, ToolId BIGINT,
    ToolCode NVARCHAR(50), ToolName NVARCHAR(100), ToolTypeCode NVARCHAR(50),
    AssignedAt DATETIME2(3), AssignedBy NVARCHAR(200));
INSERT INTO #g EXEC Tools.ToolAssignment_GetCellContext @CellLocationId = @Area;
DECLARE @imt3 NVARCHAR(1) = (SELECT CAST(IsMountTarget AS NVARCHAR(1)) FROM #g);
EXEC test.Assert_IsEqual @TestName = N'[GetCellContext non-target] IsMountTarget=0',
    @Expected = N'0', @Actual = @imt3;
DROP TABLE #g;
GO

-- ---- Test 4: unknown cell id -> one row, IsMountTarget=0 ----
CREATE TABLE #g (IsMountTarget BIT, ToolAssignmentId BIGINT, ToolId BIGINT,
    ToolCode NVARCHAR(50), ToolName NVARCHAR(100), ToolTypeCode NVARCHAR(50),
    AssignedAt DATETIME2(3), AssignedBy NVARCHAR(200));
INSERT INTO #g EXEC Tools.ToolAssignment_GetCellContext @CellLocationId = 999999999;
DECLARE @rc4 INT = (SELECT COUNT(*) FROM #g);
EXEC test.Assert_RowCount @TestName = N'[GetCellContext unknown] exactly one row',
    @ExpectedCount = 1, @ActualCount = @rc4;
DECLARE @imt4 NVARCHAR(1) = (SELECT CAST(IsMountTarget AS NVARCHAR(1)) FROM #g);
EXEC test.Assert_IsEqual @TestName = N'[GetCellContext unknown] IsMountTarget=0',
    @Expected = N'0', @Actual = @imt4;
DROP TABLE #g;
GO

-- ---- teardown ----
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'CMC-%');
DELETE FROM Tools.Tool WHERE Code LIKE N'CMC-%';
GO

EXEC test.PrintSummary;
GO
