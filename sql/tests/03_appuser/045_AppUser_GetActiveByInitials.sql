-- =============================================
-- File:         03_appuser/045_AppUser_GetActiveByInitials.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-07
-- Description:
--   Tests for Location.AppUser_GetActiveByInitials — the ACTIVE-ONLY presence
--   resolver (FAT-USR-090). Unlike the sibling AppUser_GetByInitials (which
--   intentionally returns deprecated rows for attribution history), this proc
--   filters DeprecatedAt IS NULL so a retired operator can never resolve at
--   presence sign-in.
--
--   Covers: active user returns 1 row; deprecated user returns 0 rows;
--   unknown initials return 0 rows.
--
--   Pre-conditions:
--     - Location.AppUser_GetActiveByInitials deployed
--     - Location.AppUser_Create deployed (v3.0 with @Initials)
--     - Location.AppUser_Deprecate deployed
--     - Bootstrap user 'SYS' present (migration 0012)
-- =============================================

EXEC test.BeginTestFile @FileName = N'03_appuser/045_AppUser_GetActiveByInitials.sql';
GO

-- =============================================
-- Test 1: Active user (bootstrap 'SYS') returns 1 row.
-- =============================================
CREATE TABLE #Act1 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act1
EXEC Location.AppUser_GetActiveByInitials @Initials = N'SYS';

DECLARE @RowCount1 INT = (SELECT COUNT(*) FROM #Act1);
DROP TABLE #Act1;

EXEC test.Assert_RowCount
    @TestName      = N'GetActiveByInitials active: 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @RowCount1;
GO

-- =============================================
-- Test 2: Unknown initials return 0 rows.
-- =============================================
CREATE TABLE #Act2 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act2
EXEC Location.AppUser_GetActiveByInitials @Initials = N'XXZ';

DECLARE @RowCount2 INT = (SELECT COUNT(*) FROM #Act2);
DROP TABLE #Act2;

EXEC test.Assert_RowCount
    @TestName      = N'GetActiveByInitials unknown: 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @RowCount2;
GO

-- =============================================
-- Test 3: Deprecated user returns 0 rows (the FAT-USR-090 requirement).
--   Contrast with 040 Test 3, where the history proc AppUser_GetByInitials
--   still returns the deprecated row.
-- =============================================
CREATE TABLE #Create3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Create3
EXEC Location.AppUser_Create
    @Initials    = N'DA45',
    @DisplayName = N'Test Deprecated 045',
    @Pin = N'96001',
    @AppUserId   = 1;
DECLARE @NewId BIGINT = (SELECT TOP 1 NewId FROM #Create3);
DROP TABLE #Create3;

CREATE TABLE #RDep (Status BIT, Message NVARCHAR(500));
INSERT INTO #RDep
EXEC Location.AppUser_Deprecate
    @Id        = @NewId,
    @AppUserId = 1;
DROP TABLE #RDep;
GO

CREATE TABLE #Act3 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act3
EXEC Location.AppUser_GetActiveByInitials @Initials = N'DA45';

DECLARE @RowCount3 INT = (SELECT COUNT(*) FROM #Act3);
DROP TABLE #Act3;

EXEC test.Assert_RowCount
    @TestName      = N'GetActiveByInitials deprecated: 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @RowCount3;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
