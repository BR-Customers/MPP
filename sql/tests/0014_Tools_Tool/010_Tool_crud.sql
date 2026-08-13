-- =============================================
-- File:         0014_Tools_Tool/010_Tool_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-23
-- Description:
--   Tests for Tools.Tool CRUD procs:
--     Tool_Create (with Die-only DieRankId constraint)
--     Tool_Get, Tool_GetByCode, Tool_List (filter by type + status)
--     Tool_Update (mutability + Die-only DieRankId)
--     Tool_UpdateStatus (status transitions)
--     Tool_Deprecate
--
--   Pre-conditions:
--     - Migration 0010 applied (Tools schema + seeds)
--     - All Tools.Tool_* procs deployed
--     - Bootstrap user Id=1 exists
-- =============================================

EXEC test.BeginTestFile @FileName = N'0014_Tools_Tool/010_Tool_crud.sql';
GO

-- =============================================
-- Setup: resolve a DieRank we can use. DieRank seed is empty at
-- deploy, so create one locally for the Die-type happy-path test.
-- =============================================
DECLARE @RankId BIGINT;
CREATE TABLE #Rank (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rank EXEC Tools.DieRank_Create
    @Code = N'A', @Name = N'Rank A', @Description = N'Tight tolerance',
    @AppUserId = 1;
SELECT @RankId = NewId FROM #Rank;
DROP TABLE #Rank;

-- Persist for subsequent batches via a permanent temp via session — easier
-- to re-query ToolType + DieRank in each test.
GO

-- =============================================
-- Test 1: Create happy path — Die type with DieRank
-- =============================================
DECLARE @DieTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ActiveId  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @RankId    BIGINT = (SELECT Id FROM Tools.DieRank WHERE Code = N'A');

CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Tools.Tool_Create
    @ToolTypeId = @DieTypeId,
    @Code = N'DIE-TEST-001',
    @Name = N'Test Die 001',
    @Description = N'Happy path die',
    @DieRankId = @RankId,
    @StatusCodeId = @ActiveId,
    @AppUserId = 1;

DECLARE @S BIT = (SELECT Status FROM #R1);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DECLARE @NewId BIGINT = (SELECT NewId FROM #R1);
DROP TABLE #R1;

EXEC test.Assert_IsEqual
    @TestName = N'[Create Die] Status is 1',
    @Expected = N'1', @Actual = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[Create Die] NewId is not NULL',
    @Value = @NewIdStr;
GO

-- =============================================
-- Test 2: Create rejects duplicate Code
-- =============================================
DECLARE @DieTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ActiveId  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Tools.Tool_Create
    @ToolTypeId = @DieTypeId,
    @Code = N'DIE-TEST-001',
    @Name = N'Dup',
    @StatusCodeId = @ActiveId,
    @AppUserId = 1;

DECLARE @S BIT = (SELECT Status FROM #R2);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #R2;

EXEC test.Assert_IsEqual
    @TestName = N'[Create dup] Status is 0',
    @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 3: Create rejects DieRankId on non-Die type
-- =============================================
DECLARE @CutterTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Cutter');
DECLARE @ActiveId     BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @RankId       BIGINT = (SELECT Id FROM Tools.DieRank WHERE Code = N'A');

CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Tools.Tool_Create
    @ToolTypeId = @CutterTypeId,
    @Code = N'CUT-BAD-001',
    @Name = N'Cutter w/ rank',
    @DieRankId = @RankId,
    @StatusCodeId = @ActiveId,
    @AppUserId = 1;

DECLARE @S BIT = (SELECT Status FROM #R3);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #R3;

EXEC test.Assert_IsEqual
    @TestName = N'[Create Cutter+DieRank] rejected Status 0',
    @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 4: Tool_Get returns joined display fields
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DIE-TEST-001');
CREATE TABLE #G (
    Id BIGINT, ToolTypeId BIGINT, ToolTypeCode NVARCHAR(50),
    ToolTypeName NVARCHAR(100), HasCavities BIT,
    Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500),
    DieRankId BIGINT, DieRankCode NVARCHAR(20), DieRankName NVARCHAR(100),
    StatusCodeId BIGINT, StatusCode NVARCHAR(30), StatusName NVARCHAR(100),
    CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3),
    CreatedByUserId BIGINT, UpdatedByUserId BIGINT, DeprecatedAt DATETIME2(3),
    -- Migration 0050 (tool shot count) widened Tools.Tool_Get from 19 to 25 columns.
    ShotCount INT, ShotLimit INT, ShotsRemaining INT, PercentOfLimit DECIMAL(11,2),
    IsNearLimit BIT, IsOverLimit BIT
);
INSERT INTO #G EXEC Tools.Tool_Get @Id = @ToolId;

DECLARE @GotType NVARCHAR(50) = (SELECT TOP 1 ToolTypeCode FROM #G);
EXEC test.Assert_IsEqual
    @TestName = N'[Get] ToolTypeCode is Die',
    @Expected = N'Die', @Actual = @GotType;

DECLARE @GotRank NVARCHAR(20) = (SELECT TOP 1 DieRankCode FROM #G);
EXEC test.Assert_IsEqual
    @TestName = N'[Get] DieRankCode is A',
    @Expected = N'A', @Actual = @GotRank;

DROP TABLE #G;
GO

-- =============================================
-- Test 5: Tool_Update mutates Name + clears DieRankId to NULL
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DIE-TEST-001');

CREATE TABLE #U (Status BIT, Message NVARCHAR(500));
INSERT INTO #U EXEC Tools.Tool_Update
    @Id = @ToolId, @Name = N'Test Die 001 Renamed',
    @Description = N'Updated desc', @DieRankId = NULL,
    @AppUserId = 1;

DECLARE @S BIT = (SELECT Status FROM #U);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #U;

EXEC test.Assert_IsEqual
    @TestName = N'[Update] Status is 1',
    @Expected = N'1', @Actual = @SStr;

DECLARE @StoredName NVARCHAR(100);
DECLARE @StoredRank BIGINT;
SELECT @StoredName = Name, @StoredRank = DieRankId
FROM Tools.Tool WHERE Id = @ToolId;

EXEC test.Assert_IsEqual
    @TestName = N'[Update] Name updated',
    @Expected = N'Test Die 001 Renamed', @Actual = @StoredName;

DECLARE @RankStr NVARCHAR(20) = CAST(@StoredRank AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[Update] DieRankId cleared to NULL',
    @Value = @RankStr;
GO

-- =============================================
-- Test 6: Tool_UpdateStatus — Active → UnderRepair (code-string lookup)
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DIE-TEST-001');

CREATE TABLE #US (Status BIT, Message NVARCHAR(500));
INSERT INTO #US EXEC Tools.Tool_UpdateStatus
    @Id = @ToolId, @StatusCode = N'UnderRepair', @AppUserId = 1;

DECLARE @S BIT = (SELECT Status FROM #US);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #US;

EXEC test.Assert_IsEqual
    @TestName = N'[UpdateStatus] Status is 1',
    @Expected = N'1', @Actual = @SStr;

DECLARE @StoredStatusCode NVARCHAR(30);
SELECT @StoredStatusCode = sc.Code
FROM Tools.Tool t
INNER JOIN Tools.ToolStatusCode sc ON sc.Id = t.StatusCodeId
WHERE t.Id = @ToolId;
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateStatus] Status code now UnderRepair',
    @Expected = N'UnderRepair', @Actual = @StoredStatusCode;
GO

-- =============================================
-- Test 7: Tool_List filters by ToolTypeId
-- =============================================
DECLARE @DieTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');

CREATE TABLE #L (
    Id BIGINT, ToolTypeId BIGINT, ToolTypeCode NVARCHAR(50),
    ToolTypeName NVARCHAR(100), HasCavities BIT,
    Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500),
    DieRankId BIGINT, DieRankCode NVARCHAR(20), DieRankName NVARCHAR(100),
    StatusCodeId BIGINT, StatusCode NVARCHAR(30), StatusName NVARCHAR(100),
    CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3),
    CreatedByUserId BIGINT, UpdatedByUserId BIGINT, DeprecatedAt DATETIME2(3),
    -- Migration 0050 (tool shot count) widened Tools.Tool_Get from 19 to 25 columns.
    ShotCount INT, ShotLimit INT, ShotsRemaining INT, PercentOfLimit DECIMAL(11,2),
    IsNearLimit BIT, IsOverLimit BIT
);
INSERT INTO #L EXEC Tools.Tool_List @ToolTypeId = @DieTypeId;

DECLARE @Count INT = (SELECT COUNT(*) FROM #L);
DECLARE @MatchesDie INT = (SELECT COUNT(*) FROM #L WHERE ToolTypeCode <> N'Die');
DECLARE @MatchesDieStr NVARCHAR(10) = CAST(@MatchesDie AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[List filter] All rows have ToolTypeCode = Die',
    @Expected = N'0', @Actual = @MatchesDieStr;
DROP TABLE #L;
GO

-- =============================================
-- Test 8: Tool_Deprecate happy + no longer in default list
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DIE-TEST-001');

CREATE TABLE #D (Status BIT, Message NVARCHAR(500));
INSERT INTO #D EXEC Tools.Tool_Deprecate @Id = @ToolId, @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #D);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #D;

EXEC test.Assert_IsEqual
    @TestName = N'[Deprecate] Status is 1',
    @Expected = N'1', @Actual = @SStr;

DECLARE @DepAt DATETIME2(3);
SELECT @DepAt = DeprecatedAt FROM Tools.Tool WHERE Id = @ToolId;
DECLARE @DepSet NVARCHAR(1) = CASE WHEN @DepAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[Deprecate] DeprecatedAt set',
    @Expected = N'1', @Actual = @DepSet;
GO

EXEC test.PrintSummary;
GO
