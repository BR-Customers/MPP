-- =============================================
-- File:         03_appuser/040_AppUser_GetByInitials.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-23
-- Description:
--   Tests for Location.AppUser_GetByInitials. Initials are the primary
--   accountability identifier under the Phase C security model.
--   Covers: find bootstrap user by its 'SYS' initials, non-existent
--   initials returns 0 rows, deprecated users are still returned.
--
--   Pre-conditions:
--     - Migration 0012 applied (Initials column populated; bootstrap = 'SYS')
--     - Location.AppUser_GetByInitials deployed
--     - Location.AppUser_Create deployed (v3.0 with @Initials)
--     - Location.AppUser_Deprecate deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'03_appuser/040_AppUser_GetByInitials.sql';
GO

-- =============================================
-- Test 1: Find bootstrap user by Initials = 'SYS'. Expect 1 row.
-- =============================================
CREATE TABLE #ByIn1 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);

INSERT INTO #ByIn1
EXEC Location.AppUser_GetByInitials @Initials = N'SYS';

DECLARE @RowCount1 INT = (SELECT COUNT(*) FROM #ByIn1);
DECLARE @BootstrapId BIGINT = (SELECT TOP 1 Id FROM #ByIn1);
DROP TABLE #ByIn1;

EXEC test.Assert_RowCount
    @TestName      = N'GetByInitials bootstrap: 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @RowCount1;

DECLARE @BootstrapIdStr NVARCHAR(20) = CAST(@BootstrapId AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'GetByInitials bootstrap: Id = 1',
    @Expected = N'1',
    @Actual   = @BootstrapIdStr;
GO

-- =============================================
-- Test 2: Non-existent initials returns 0 rows.
-- =============================================
CREATE TABLE #ByIn2 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);

INSERT INTO #ByIn2
EXEC Location.AppUser_GetByInitials @Initials = N'XXZ';

DECLARE @RowCount2 INT = (SELECT COUNT(*) FROM #ByIn2);
DROP TABLE #ByIn2;

EXEC test.Assert_RowCount
    @TestName      = N'GetByInitials non-existent: 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @RowCount2;
GO

-- =============================================
-- Test 3: Deprecated user is still returned (no DeprecatedAt filter).
--   Initials stay unique across the full lifecycle so historical events
--   stamped with a retired operator's initials still resolve.
-- =============================================
CREATE TABLE #Create3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Create3
EXEC Location.AppUser_Create
    @Initials    = N'DP40',
    @DisplayName = N'Test Deprecated 040',
    @Pin = N'95001',
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

CREATE TABLE #ByIn3 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);

INSERT INTO #ByIn3
EXEC Location.AppUser_GetByInitials @Initials = N'DP40';

DECLARE @RowCount3 INT = (SELECT COUNT(*) FROM #ByIn3);
EXEC test.Assert_RowCount
    @TestName      = N'GetByInitials deprecated: 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @RowCount3;

DECLARE @DepAtStr NVARCHAR(50) =
    CAST((SELECT TOP 1 DeprecatedAt FROM #ByIn3) AS NVARCHAR(50));
EXEC test.Assert_IsNotNull
    @TestName = N'GetByInitials deprecated: DeprecatedAt is set on returned row',
    @Value    = @DepAtStr;

DROP TABLE #ByIn3;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
