-- =============================================
-- File:         0015_Tools_Cavity/010_Cavity_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-23
-- Description:
--   Tests for Tools.ToolCavity CRUD:
--     ToolCavity_Create (HasCavities=1 gate)
--     ToolCavity_UpdateStatus (3-state Active/Closed/Scrapped)
--     ToolCavity_Deprecate
--     ToolCavity_ListByTool
-- =============================================

EXEC test.BeginTestFile @FileName = N'0015_Tools_Cavity/010_Cavity_crud.sql';
GO

-- =============================================
-- Setup: create a Die-type tool and a Cutter-type tool
-- =============================================
DECLARE @DieTypeId    BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @CutterTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Cutter');
DECLARE @ActiveId     BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');

CREATE TABLE #RDie (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RDie EXEC Tools.Tool_Create
    @ToolTypeId = @DieTypeId, @Code = N'CAV-TEST-DIE', @Name = N'Cavity Test Die',
    @StatusCodeId = @ActiveId, @AppUserId = 1;
DROP TABLE #RDie;

CREATE TABLE #RCut (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RCut EXEC Tools.Tool_Create
    @ToolTypeId = @CutterTypeId, @Code = N'CAV-TEST-CUT', @Name = N'Cavity Test Cutter',
    @StatusCodeId = @ActiveId, @AppUserId = 1;
DROP TABLE #RCut;
GO

-- =============================================
-- Test 1: Create cavity on Die-type tool — happy
-- =============================================
DECLARE @DieToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAV-TEST-DIE');

CREATE TABLE #C1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #C1 EXEC Tools.ToolCavity_Create
    @ToolId = @DieToolId, @CavityCode = N'a', @Description = N'Cavity a',
    @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #C1);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #C1;

EXEC test.Assert_IsEqual
    @TestName = N'[Create on Die] Status is 1',
    @Expected = N'1', @Actual = @SStr;
GO

-- =============================================
-- Test 2: Create cavity on Cutter-type tool — rejected (HasCavities=0)
-- =============================================
DECLARE @CutToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAV-TEST-CUT');

CREATE TABLE #C2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #C2 EXEC Tools.ToolCavity_Create
    @ToolId = @CutToolId, @CavityCode = N'a', @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #C2);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #C2;

EXEC test.Assert_IsEqual
    @TestName = N'[Create on Cutter] rejected Status 0',
    @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 3: Duplicate CavityCode on same Die — rejected
-- =============================================
DECLARE @DieToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAV-TEST-DIE');

CREATE TABLE #C3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #C3 EXEC Tools.ToolCavity_Create
    @ToolId = @DieToolId, @CavityCode = N'a', @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #C3);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #C3;

EXEC test.Assert_IsEqual
    @TestName = N'[Create dup] rejected Status 0',
    @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 4: UpdateStatus — Active → Closed
-- =============================================
DECLARE @DieToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAV-TEST-DIE');
DECLARE @CavityId BIGINT = (
    SELECT Id FROM Tools.ToolCavity WHERE ToolId = @DieToolId AND CavityCode = N'a');

CREATE TABLE #C4 (Status BIT, Message NVARCHAR(500));
INSERT INTO #C4 EXEC Tools.ToolCavity_UpdateStatus
    @Id = @CavityId, @StatusCode = N'Closed', @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #C4);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #C4;

EXEC test.Assert_IsEqual
    @TestName = N'[UpdateStatus Closed] Status is 1',
    @Expected = N'1', @Actual = @SStr;

DECLARE @NewStatus NVARCHAR(30);
SELECT @NewStatus = sc.Code
FROM Tools.ToolCavity tc
INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
WHERE tc.Id = @CavityId;
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateStatus Closed] StatusCode is Closed',
    @Expected = N'Closed', @Actual = @NewStatus;
GO

-- =============================================
-- Test 5: ListByTool returns only active rows by default
-- =============================================
DECLARE @DieToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAV-TEST-DIE');

-- Add a second cavity then deprecate it
CREATE TABLE #Cx (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Cx EXEC Tools.ToolCavity_Create
    @ToolId = @DieToolId, @CavityCode = N'b', @AppUserId = 1;
DECLARE @Cav2Id BIGINT = (SELECT NewId FROM #Cx);
DROP TABLE #Cx;

CREATE TABLE #Dx (Status BIT, Message NVARCHAR(500));
INSERT INTO #Dx EXEC Tools.ToolCavity_Deprecate
    @Id = @Cav2Id, @AppUserId = 1;
DROP TABLE #Dx;

CREATE TABLE #L (
    Id BIGINT, ToolId BIGINT, CavityCode NVARCHAR(4),
    StatusCodeId BIGINT, StatusCode NVARCHAR(30), StatusName NVARCHAR(100),
    Description NVARCHAR(500),
    CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3),
    CreatedByUserId BIGINT, UpdatedByUserId BIGINT, DeprecatedAt DATETIME2(3),
    -- 0072: ItemId / ItemPartNumber / ItemDescription appended by
    -- Tools.ToolCavity_ListByTool. INSERT-EXEC requires an exact
    -- column-count match, so the shape must track the proc.
    ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500)
);
INSERT INTO #L EXEC Tools.ToolCavity_ListByTool @ToolId = @DieToolId;

DECLARE @ActiveCount INT = (SELECT COUNT(*) FROM #L);
EXEC test.Assert_RowCount
    @TestName = N'[ListByTool default] 1 active cavity',
    @ExpectedCount = 1, @ActualCount = @ActiveCount;

DELETE FROM #L;
INSERT INTO #L EXEC Tools.ToolCavity_ListByTool
    @ToolId = @DieToolId, @IncludeDeprecated = 1;
DECLARE @AllCount INT = (SELECT COUNT(*) FROM #L);
EXEC test.Assert_RowCount
    @TestName = N'[ListByTool all] 2 rows (incl deprecated)',
    @ExpectedCount = 2, @ActualCount = @AllCount;
DROP TABLE #L;
GO

EXEC test.PrintSummary;
GO
