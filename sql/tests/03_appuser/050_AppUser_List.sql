-- =============================================
-- File:         03_appuser/050_AppUser_List.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Description:
--   Tests for Location.AppUser_List.
--   Covers: default (exclude deprecated), and IncludeDeprecated=1.
--
--   Pre-conditions:
--     - Migration 0001 applied (Location.AppUser seed present)
--     - Location.AppUser_List deployed (v2.0, no OUTPUT params)
--     - Location.AppUser_Create deployed (v2.0, returns SELECT)
--     - Location.AppUser_Deprecate deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'03_appuser/050_AppUser_List.sql';
GO

-- =============================================
-- Setup: Create one active user and one deprecated user.
-- =============================================
CREATE TABLE #CreateActive (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #CreateActive
EXEC Location.AppUser_Create
    @Initials     = N'TA50',
    @DisplayName  = N'Test Active 050',
    @Pin = N'97001',
    @AdAccount    = N'test.active.050',
    @IgnitionRole = NULL,
    @AppUserId    = 1;
DROP TABLE #CreateActive;

CREATE TABLE #CreateDep (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #CreateDep
EXEC Location.AppUser_Create
    @Initials     = N'TD50',
    @DisplayName  = N'Test Deprecated 050',
    @Pin = N'97002',
    @AdAccount    = N'test.deprecated.050',
    @IgnitionRole = NULL,
    @AppUserId    = 1;

DECLARE @DepId BIGINT = (SELECT TOP 1 NewId FROM #CreateDep);
DROP TABLE #CreateDep;

DECLARE @DepStatus  BIT           = 0;
DECLARE @DepMessage NVARCHAR(500) = NULL;
CREATE TABLE #RDep (Status BIT, Message NVARCHAR(500));
INSERT INTO #RDep
EXEC Location.AppUser_Deprecate
    @Id        = @DepId,
    @AppUserId = 1;
SELECT @DepStatus = Status, @DepMessage = Message FROM #RDep;
DROP TABLE #RDep;
GO

-- =============================================
-- Test 1: Default (IncludeDeprecated=0) excludes deprecated.
-- =============================================
CREATE TABLE #List1 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);

INSERT INTO #List1
EXEC Location.AppUser_List @IncludeDeprecated = 0;

-- Bootstrap user present
DECLARE @BootstrapCount INT = (
    SELECT COUNT(*) FROM #List1 WHERE AdAccount = N'system.bootstrap'
);
DECLARE @BootstrapCond BIT = CASE WHEN @BootstrapCount >= 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'AppUser_List default: bootstrap user included',
    @Condition = @BootstrapCond;

-- Active test user present
DECLARE @ActiveCount INT = (
    SELECT COUNT(*) FROM #List1 WHERE AdAccount = N'test.active.050'
);
DECLARE @ActiveCond BIT = CASE WHEN @ActiveCount >= 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'AppUser_List default: active test user included',
    @Condition = @ActiveCond;

-- Deprecated test user excluded
DECLARE @DepCount INT = (
    SELECT COUNT(*) FROM #List1 WHERE AdAccount = N'test.deprecated.050'
);
DECLARE @DepCountStr NVARCHAR(5) = CAST(@DepCount AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'AppUser_List default: deprecated test user excluded',
    @Expected = N'0',
    @Actual   = @DepCountStr;

-- No row in result has DeprecatedAt set
DECLARE @AnyDeprecated INT = (
    SELECT COUNT(*) FROM #List1 WHERE DeprecatedAt IS NOT NULL
);
DECLARE @AnyDeprecatedStr NVARCHAR(5) = CAST(@AnyDeprecated AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'AppUser_List default: no deprecated rows in result',
    @Expected = N'0',
    @Actual   = @AnyDeprecatedStr;

DROP TABLE #List1;
GO

-- =============================================
-- Test 2: IncludeDeprecated=1 returns all users including deprecated.
-- =============================================
CREATE TABLE #List2 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);

INSERT INTO #List2
EXEC Location.AppUser_List @IncludeDeprecated = 1;

-- Deprecated test user appears
DECLARE @DepCount2 INT = (
    SELECT COUNT(*) FROM #List2 WHERE AdAccount = N'test.deprecated.050'
);
DECLARE @DepCond2 BIT = CASE WHEN @DepCount2 >= 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'AppUser_List IncludeDeprecated=1: deprecated test user included',
    @Condition = @DepCond2;

-- At least 1 row with DeprecatedAt set
DECLARE @HasDeprecated INT = (
    SELECT COUNT(*) FROM #List2 WHERE DeprecatedAt IS NOT NULL
);
DECLARE @HasDeprecatedCond BIT = CASE WHEN @HasDeprecated >= 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'AppUser_List IncludeDeprecated=1: at least 1 deprecated row present',
    @Condition = @HasDeprecatedCond;

-- Active test user also present (no rows dropped)
DECLARE @ActiveCount2 INT = (
    SELECT COUNT(*) FROM #List2 WHERE AdAccount = N'test.active.050'
);
DECLARE @ActiveCond2 BIT = CASE WHEN @ActiveCount2 >= 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'AppUser_List IncludeDeprecated=1: active test user also included',
    @Condition = @ActiveCond2;

DROP TABLE #List2;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
