-- =============================================
-- File:         03_appuser/030_AppUser_GetByAdAccount.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Description:
--   Tests for Location.AppUser_GetByAdAccount.
--   Covers: find bootstrap user, non-existent account returns 0 rows,
--   and deprecated users are still returned (no DeprecatedAt filter).
--
--   Pre-conditions:
--     - Migration 0001 applied (Location.AppUser seed present)
--     - Location.AppUser Id=1 (system.bootstrap) present
--     - Location.AppUser_GetByAdAccount deployed (v2.0, no OUTPUT params)
--     - Location.AppUser_Create deployed (v2.0, returns SELECT)
--     - Location.AppUser_Deprecate deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'03_appuser/030_AppUser_GetByAdAccount.sql';
GO

-- =============================================
-- Test 1: Find bootstrap user by AdAccount. Expect exactly 1 row.
-- =============================================
CREATE TABLE #ByAd1 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);

INSERT INTO #ByAd1
EXEC Location.AppUser_GetByAdAccount @AdAccount = N'system.bootstrap';

DECLARE @RowCount1 INT = (SELECT COUNT(*) FROM #ByAd1);
DROP TABLE #ByAd1;

EXEC test.Assert_RowCount
    @TestName      = N'GetByAdAccount bootstrap: 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @RowCount1;
GO

-- =============================================
-- Test 2: Non-existent AdAccount returns 0 rows.
-- =============================================
CREATE TABLE #ByAd2 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);

INSERT INTO #ByAd2
EXEC Location.AppUser_GetByAdAccount @AdAccount = N'no.such.user';

DECLARE @RowCount2 INT = (SELECT COUNT(*) FROM #ByAd2);
DROP TABLE #ByAd2;

EXEC test.Assert_RowCount
    @TestName      = N'GetByAdAccount non-existent: 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @RowCount2;
GO

-- =============================================
-- Test 3: Deprecated user is still returned (proc does NOT filter DeprecatedAt).
-- =============================================

-- Create a test user (AppUser_Create returns SELECT, capture via INSERT-EXEC)
CREATE TABLE #Create3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Create3
EXEC Location.AppUser_Create
    @Initials     = N'TD30',
    @DisplayName  = N'Test Deprecated 030',
    @Pin = N'94001',
    @AdAccount    = N'test.deprecated.030',
    @IgnitionRole = NULL,
    @AppUserId    = 1;

DECLARE @NewId BIGINT = (SELECT TOP 1 NewId FROM #Create3);
DROP TABLE #Create3;

DECLARE @DepStatus  BIT           = 0;
DECLARE @DepMessage NVARCHAR(500) = NULL;

CREATE TABLE #RDep (Status BIT, Message NVARCHAR(500));
INSERT INTO #RDep
EXEC Location.AppUser_Deprecate
    @Id        = @NewId,
    @AppUserId = 1;
SELECT @DepStatus = Status, @DepMessage = Message FROM #RDep;
DROP TABLE #RDep;
GO

-- Lookup the deprecated user in a fresh batch
CREATE TABLE #ByAd3 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);

INSERT INTO #ByAd3
EXEC Location.AppUser_GetByAdAccount @AdAccount = N'test.deprecated.030';

DECLARE @RowCount3 INT = (SELECT COUNT(*) FROM #ByAd3);
EXEC test.Assert_RowCount
    @TestName      = N'GetByAdAccount deprecated: 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @RowCount3;

DECLARE @DeprecatedAtStr NVARCHAR(50) =
    CAST((SELECT TOP 1 DeprecatedAt FROM #ByAd3) AS NVARCHAR(50));
EXEC test.Assert_IsNotNull
    @TestName = N'GetByAdAccount deprecated: DeprecatedAt is set on returned row',
    @Value    = @DeprecatedAtStr;

DROP TABLE #ByAd3;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
