-- =============================================
-- File:         03_appuser/020_AppUser_Get.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Description:
--   Tests for Location.AppUser_Get.
--   Covers: bootstrap user returned by Id, non-existent Id returns 0 rows.
--
--   Pre-conditions:
--     - Migration 0001 applied (Location.AppUser seed present)
--     - Location.AppUser Id=1 (system.bootstrap) present
--     - Location.AppUser_Get deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'03_appuser/020_AppUser_Get.sql';
GO

-- =============================================
-- Test 1: Get bootstrap user by Id=1.
--   Expect exactly 1 row, AdAccount = 'system.bootstrap'.
-- =============================================
CREATE TABLE #Get1 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);

INSERT INTO #Get1
EXEC Location.AppUser_Get @Id = 1;

-- Assert 1a: exactly 1 row returned
DECLARE @RowCount1a INT = (SELECT COUNT(*) FROM #Get1);
EXEC test.Assert_RowCount
    @TestName      = N'AppUser_Get bootstrap: 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @RowCount1a;

-- Assert 1b: AdAccount = 'system.bootstrap'
DECLARE @AdAccount1b NVARCHAR(100) = (SELECT TOP 1 AdAccount FROM #Get1);
EXEC test.Assert_IsEqual
    @TestName = N'AppUser_Get bootstrap: AdAccount = system.bootstrap',
    @Expected = N'system.bootstrap',
    @Actual   = @AdAccount1b;

DROP TABLE #Get1;
GO

-- =============================================
-- Test 2: Non-existent Id=999999 returns 0 rows.
--   Empty result = not found (not an error).
-- =============================================
CREATE TABLE #Get2 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);

INSERT INTO #Get2
EXEC Location.AppUser_Get @Id = 999999;

-- Assert 2a: 0 rows returned
DECLARE @RowCount2a INT = (SELECT COUNT(*) FROM #Get2);
EXEC test.Assert_RowCount
    @TestName      = N'AppUser_Get non-existent: 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @RowCount2a;

DROP TABLE #Get2;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
