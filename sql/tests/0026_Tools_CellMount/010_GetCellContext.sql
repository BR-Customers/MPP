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
DELETE FROM Lots.LotGenealogyClosure
WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'CMC-%')
   OR AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'CMC-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'CMC-%';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'CMC-%');
DELETE FROM Tools.ToolCavity WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'CMC-%');
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
    AssignedAt DATETIME2(3), AssignedBy NVARCHAR(200), OpenBasketCount INT);
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

DECLARE @obc NVARCHAR(10) = (SELECT CAST(OpenBasketCount AS NVARCHAR(10)) FROM #g);
EXEC test.Assert_IsEqual @TestName = N'[GetCellContext empty] OpenBasketCount = 0',
    @Expected = N'0', @Actual = @obc;
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
    AssignedAt DATETIME2(3), AssignedBy NVARCHAR(200), OpenBasketCount INT);
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

DECLARE @obc2 NVARCHAR(10) = (SELECT CAST(OpenBasketCount AS NVARCHAR(10)) FROM #g);
EXEC test.Assert_IsEqual @TestName = N'[GetCellContext occupied, no baskets] OpenBasketCount = 0',
    @Expected = N'0', @Actual = @obc2;
DROP TABLE #g;
GO

-- ---- Test 3: non-mount-target location (Site MPP-MAD or any non-DieCastMachine) ----
DECLARE @Area BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD');
CREATE TABLE #g (IsMountTarget BIT, ToolAssignmentId BIGINT, ToolId BIGINT,
    ToolCode NVARCHAR(50), ToolName NVARCHAR(100), ToolTypeCode NVARCHAR(50),
    AssignedAt DATETIME2(3), AssignedBy NVARCHAR(200), OpenBasketCount INT);
INSERT INTO #g EXEC Tools.ToolAssignment_GetCellContext @CellLocationId = @Area;
DECLARE @imt3 NVARCHAR(1) = (SELECT CAST(IsMountTarget AS NVARCHAR(1)) FROM #g);
EXEC test.Assert_IsEqual @TestName = N'[GetCellContext non-target] IsMountTarget=0',
    @Expected = N'0', @Actual = @imt3;
DROP TABLE #g;
GO

-- ---- Test 4: unknown cell id -> one row, IsMountTarget=0 ----
CREATE TABLE #g (IsMountTarget BIT, ToolAssignmentId BIGINT, ToolId BIGINT,
    ToolCode NVARCHAR(50), ToolName NVARCHAR(100), ToolTypeCode NVARCHAR(50),
    AssignedAt DATETIME2(3), AssignedBy NVARCHAR(200), OpenBasketCount INT);
INSERT INTO #g EXEC Tools.ToolAssignment_GetCellContext @CellLocationId = 999999999;
DECLARE @rc4 INT = (SELECT COUNT(*) FROM #g);
EXEC test.Assert_RowCount @TestName = N'[GetCellContext unknown] exactly one row',
    @ExpectedCount = 1, @ActualCount = @rc4;
DECLARE @imt4 NVARCHAR(1) = (SELECT CAST(IsMountTarget AS NVARCHAR(1)) FROM #g);
EXEC test.Assert_IsEqual @TestName = N'[GetCellContext unknown] IsMountTarget=0',
    @Expected = N'0', @Actual = @imt4;
DROP TABLE #g;
GO

-- ---- Test 5: OpenBasketCount counts open baskets on LIVE cavities only ----
-- The die is still mounted from Test 2. Two live cavities carry an open
-- basket; a third is deprecated while holding one, which is exactly the row
-- shape Lots.Lot_GetOpenByTool hides -- so the count must be 2, not 3.
DECLARE @Cell BIGINT = (SELECT CellId FROM #ctx);
DECLARE @Tool BIGINT = (SELECT ToolId FROM #ctx);
DECLARE @OpenId   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
DECLARE @OriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @ItemId   BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @CavA BIGINT, @CavB BIGINT, @CavC BIGINT;

CREATE TABLE #cv (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #cv EXEC Tools.ToolCavity_Create
    @ToolId = @Tool, @CavityCode = N'a', @Description = N'CMC a', @AppUserId = 1;
SET @CavA = (SELECT NewId FROM #cv);
DELETE FROM #cv;
INSERT INTO #cv EXEC Tools.ToolCavity_Create
    @ToolId = @Tool, @CavityCode = N'b', @Description = N'CMC b', @AppUserId = 1;
SET @CavB = (SELECT NewId FROM #cv);
DELETE FROM #cv;
INSERT INTO #cv EXEC Tools.ToolCavity_Create
    @ToolId = @Tool, @CavityCode = N'c', @Description = N'CMC c', @AppUserId = 1;
SET @CavC = (SELECT NewId FROM #cv);
DROP TABLE #cv;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      ToolId, ToolCavityId, CurrentLocationId, CreatedByUserId)
VALUES (N'CMC-LOT-A', @ItemId, @OriginId, @OpenId, 11, @Tool, @CavA, @Cell, 1),
       (N'CMC-LOT-B', @ItemId, @OriginId, @OpenId, 12, @Tool, @CavB, @Cell, 1),
       (N'CMC-LOT-C', @ItemId, @OriginId, @OpenId, 13, @Tool, @CavC, @Cell, 1);

-- Direct UPDATE: ToolCavity_Deprecate v1.1 now refuses this, and the point of
-- the case is the historical row it used to allow.
UPDATE Tools.ToolCavity SET DeprecatedAt = SYSUTCDATETIME() WHERE Id = @CavC;

CREATE TABLE #g (IsMountTarget BIT, ToolAssignmentId BIGINT, ToolId BIGINT,
    ToolCode NVARCHAR(50), ToolName NVARCHAR(100), ToolTypeCode NVARCHAR(50),
    AssignedAt DATETIME2(3), AssignedBy NVARCHAR(200), OpenBasketCount INT);
INSERT INTO #g EXEC Tools.ToolAssignment_GetCellContext @CellLocationId = @Cell;

DECLARE @obc5 NVARCHAR(10) = (SELECT CAST(OpenBasketCount AS NVARCHAR(10)) FROM #g);
EXEC test.Assert_IsEqual @TestName = N'[GetCellContext] OpenBasketCount = 2 (deprecated cavity not counted)',
    @Expected = N'2', @Actual = @obc5;

-- ---- Test 6: the count the popup shows equals the list the screen shows ----
-- Asserted against Lots.Lot_GetOpenByTool rather than a literal, because the
-- literal is what rots when either predicate moves. Whatever the guard counts,
-- the screen must show.
CREATE TABLE #ob (ToolCavityId BIGINT, CavityCode NVARCHAR(4), LotId BIGINT,
    LotName NVARCHAR(50), PieceCount INT, MaxPieceCount INT,
    BelowStandardRelease BIT, OpenedAt DATETIME2(3), ContributorCount INT,
    CavityDescription NVARCHAR(500), CavityStatusCode NVARCHAR(50),
    ConfiguredItemId BIGINT, ConfiguredPartNumber NVARCHAR(100));
INSERT INTO #ob EXEC Lots.Lot_GetOpenByTool @ToolId = @Tool;

DECLARE @screen INT = (SELECT COUNT(*) FROM #ob WHERE LotId IS NOT NULL);
DECLARE @guard  INT = (SELECT OpenBasketCount FROM #g);
DECLARE @match  BIT = CASE WHEN @screen = @guard THEN 1 ELSE 0 END;
DECLARE @detail NVARCHAR(1000) = N'Lot_GetOpenByTool visible = '
    + CAST(@screen AS NVARCHAR(10)) + N', GetCellContext.OpenBasketCount = '
    + CAST(@guard AS NVARCHAR(10));
EXEC test.Assert_IsTrue
    @TestName = N'[GetCellContext] OpenBasketCount equals the screen basket list',
    @Condition = @match, @Detail = @detail;

DROP TABLE #ob;
DROP TABLE #g;
GO

-- ---- teardown ----
DELETE FROM Lots.LotGenealogyClosure
WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'CMC-%')
   OR AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'CMC-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'CMC-%';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'CMC-%');
DELETE FROM Tools.ToolCavity WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code LIKE N'CMC-%');
DELETE FROM Tools.Tool WHERE Code LIKE N'CMC-%';
GO

EXEC test.PrintSummary;
GO
