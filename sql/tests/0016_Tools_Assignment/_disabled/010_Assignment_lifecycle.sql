-- =============================================
-- File:         0016_Tools_Assignment/010_Assignment_lifecycle.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-23
-- Description:
--   Tests for Tools.ToolAssignment lifecycle:
--     Assign — happy, non-Cell rejection, tool-already-mounted, cell-occupied
--     Release — happy + no-active-assignment rejection
--     ListByTool (full history)
--     ListActiveByCell (filtered UNIQUE semantics)
-- =============================================

EXEC test.BeginTestFile @FileName = N'0016_Tools_Assignment/010_Assignment_lifecycle.sql';
GO

-- =============================================
-- Setup: two dies for mount races
-- =============================================
DECLARE @DieTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ActiveId  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');

CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Tools.Tool_Create
    @ToolTypeId = @DieTypeId, @Code = N'ASN-DIE-A', @Name = N'Assign Die A',
    @StatusCodeId = @ActiveId, @AppUserId = 1;
DROP TABLE #R1;

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Tools.Tool_Create
    @ToolTypeId = @DieTypeId, @Code = N'ASN-DIE-B', @Name = N'Assign Die B',
    @StatusCodeId = @ActiveId, @AppUserId = 1;
DROP TABLE #R2;
GO

-- =============================================
-- Test 1: Assign to Cell (DC-401) — happy
-- =============================================
DECLARE @ToolAId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ASN-DIE-A');
DECLARE @CellId BIGINT  = (SELECT Id FROM Location.Location WHERE Code = N'DC-401');

CREATE TABLE #A1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #A1 EXEC Tools.ToolAssignment_Assign
    @ToolId = @ToolAId, @CellLocationId = @CellId,
    @Notes = N'Mount A on DC-401', @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #A1);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #A1;

EXEC test.Assert_IsEqual
    @TestName = N'[Assign happy] Status is 1',
    @Expected = N'1', @Actual = @SStr;
GO

-- =============================================
-- Test 2: Assign non-Cell (Area MPP-MAD) rejected
-- =============================================
DECLARE @ToolAId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ASN-DIE-A');
DECLARE @AreaId BIGINT  = (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD');

CREATE TABLE #A2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #A2 EXEC Tools.ToolAssignment_Assign
    @ToolId = @ToolAId, @CellLocationId = @AreaId, @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #A2);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #A2;

EXEC test.Assert_IsEqual
    @TestName = N'[Assign non-Cell] rejected Status 0',
    @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 3: Assign Tool A to a second Cell — rejected (already mounted)
-- =============================================
DECLARE @ToolAId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ASN-DIE-A');
DECLARE @CellBId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC-402');

CREATE TABLE #A3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #A3 EXEC Tools.ToolAssignment_Assign
    @ToolId = @ToolAId, @CellLocationId = @CellBId, @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #A3);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #A3;

EXEC test.Assert_IsEqual
    @TestName = N'[Assign tool already mounted] rejected Status 0',
    @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 4: Assign Tool B to already-occupied Cell — rejected
-- =============================================
DECLARE @ToolBId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ASN-DIE-B');
DECLARE @CellAId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC-401');

CREATE TABLE #A4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #A4 EXEC Tools.ToolAssignment_Assign
    @ToolId = @ToolBId, @CellLocationId = @CellAId, @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #A4);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #A4;

EXEC test.Assert_IsEqual
    @TestName = N'[Assign cell occupied] rejected Status 0',
    @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 5: ListActiveByCell returns 1 row for DC-401
-- =============================================
DECLARE @CellAId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC-401');

CREATE TABLE #LA (
    Id BIGINT, ToolId BIGINT, ToolCode NVARCHAR(50),
    ToolName NVARCHAR(100), ToolTypeCode NVARCHAR(50),
    CellLocationId BIGINT, AssignedAt DATETIME2(3),
    AssignedByUserId BIGINT, Notes NVARCHAR(500)
);
INSERT INTO #LA EXEC Tools.ToolAssignment_ListActiveByCell @CellLocationId = @CellAId;
DECLARE @Count INT = (SELECT COUNT(*) FROM #LA);
EXEC test.Assert_RowCount
    @TestName = N'[ListActiveByCell DC-401] 1 active',
    @ExpectedCount = 1, @ActualCount = @Count;

DECLARE @MountedCode NVARCHAR(50) = (SELECT TOP 1 ToolCode FROM #LA);
EXEC test.Assert_IsEqual
    @TestName = N'[ListActiveByCell DC-401] ToolCode = ASN-DIE-A',
    @Expected = N'ASN-DIE-A', @Actual = @MountedCode;
DROP TABLE #LA;
GO

-- =============================================
-- Test 6: Release — happy
-- =============================================
DECLARE @ToolAId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ASN-DIE-A');

CREATE TABLE #R (Status BIT, Message NVARCHAR(500));
INSERT INTO #R EXEC Tools.ToolAssignment_Release
    @ToolId = @ToolAId, @AppUserId = 1, @Notes = N'End of run';
DECLARE @S BIT = (SELECT Status FROM #R);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #R;

EXEC test.Assert_IsEqual
    @TestName = N'[Release happy] Status is 1',
    @Expected = N'1', @Actual = @SStr;

-- After release, Cell is free
DECLARE @CellAId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC-401');
CREATE TABLE #LA (
    Id BIGINT, ToolId BIGINT, ToolCode NVARCHAR(50),
    ToolName NVARCHAR(100), ToolTypeCode NVARCHAR(50),
    CellLocationId BIGINT, AssignedAt DATETIME2(3),
    AssignedByUserId BIGINT, Notes NVARCHAR(500)
);
INSERT INTO #LA EXEC Tools.ToolAssignment_ListActiveByCell @CellLocationId = @CellAId;
DECLARE @PostCount INT = (SELECT COUNT(*) FROM #LA);
EXEC test.Assert_RowCount
    @TestName = N'[Release] DC-401 is free after release',
    @ExpectedCount = 0, @ActualCount = @PostCount;
DROP TABLE #LA;
GO

-- =============================================
-- Test 7: Release again — rejected (no active assignment)
-- =============================================
DECLARE @ToolAId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ASN-DIE-A');

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R2 EXEC Tools.ToolAssignment_Release
    @ToolId = @ToolAId, @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #R2);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #R2;

EXEC test.Assert_IsEqual
    @TestName = N'[Release twice] rejected Status 0',
    @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 8: History (ListByTool) shows released assignment
-- =============================================
DECLARE @ToolAId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ASN-DIE-A');

CREATE TABLE #H (
    Id BIGINT, ToolId BIGINT, CellLocationId BIGINT,
    CellCode NVARCHAR(50), CellName NVARCHAR(200),
    AssignedAt DATETIME2(3), ReleasedAt DATETIME2(3),
    AssignedByUserId BIGINT, ReleasedByUserId BIGINT,
    Notes NVARCHAR(500)
);
INSERT INTO #H EXEC Tools.ToolAssignment_ListByTool @ToolId = @ToolAId;
DECLARE @HistCount INT = (SELECT COUNT(*) FROM #H);
EXEC test.Assert_RowCount
    @TestName = N'[ListByTool] 1 historical assignment for ASN-DIE-A',
    @ExpectedCount = 1, @ActualCount = @HistCount;

DECLARE @RelAt DATETIME2(3) = (SELECT TOP 1 ReleasedAt FROM #H);
DECLARE @RelStr NVARCHAR(50) = CAST(@RelAt AS NVARCHAR(50));
EXEC test.Assert_IsNotNull
    @TestName = N'[ListByTool] ReleasedAt is set',
    @Value = @RelStr;
DROP TABLE #H;
GO

EXEC test.PrintSummary;
GO
