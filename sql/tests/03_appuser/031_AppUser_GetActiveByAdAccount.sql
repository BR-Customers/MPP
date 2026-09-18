-- =============================================
-- File:         03_appuser/031_AppUser_GetActiveByAdAccount.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-18
-- Description:
--   Tests for Location.AppUser_GetActiveByAdAccount -- the attribution gate
--   for an AD-authenticated session (Configuration Tool). Active rows only.
--
--   The pair with AppUser_GetByAdAccount mirrors the PIN pair: a deprecated
--   person must FAIL this gate but still resolve through the history lookup
--   (covered by 030_AppUser_GetByAdAccount.sql Test 3).
--
--   Pre-conditions:
--     - Location.AppUser Id=1 (system.bootstrap) present
--     - Location.AppUser_GetActiveByAdAccount deployed (v1.0)
--     - Location.AppUser_Create deployed (with @Pin)
--     - Location.AppUser_Deprecate deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'03_appuser/031_AppUser_GetActiveByAdAccount.sql';
GO

-- =============================================
-- Arrange: one active and one deprecated AD-linked user.
-- =============================================
CREATE TABLE #MkActive (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #MkActive
EXEC Location.AppUser_Create
    @Initials     = N'AA31',
    @DisplayName  = N'Ad Active 031',
    @Pin          = N'93131',
    @AdAccount    = N'test.adactive.031',
    @IgnitionRole = NULL,
    @AppUserId    = 1;
DECLARE @MkActiveStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #MkActive);
DROP TABLE #MkActive;

EXEC test.Assert_IsEqual
    @TestName = N'Arrange: active AD user created',
    @Expected = N'1',
    @Actual   = @MkActiveStatus;

CREATE TABLE #MkDep (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #MkDep
EXEC Location.AppUser_Create
    @Initials     = N'AD31',
    @DisplayName  = N'Ad Deprecated 031',
    @Pin          = N'93132',
    @AdAccount    = N'test.addeprecated.031',
    @IgnitionRole = NULL,
    @AppUserId    = 1;
DECLARE @DepId BIGINT = (SELECT TOP 1 NewId FROM #MkDep);
DROP TABLE #MkDep;

CREATE TABLE #RDep (Status BIT, Message NVARCHAR(500));
INSERT INTO #RDep
EXEC Location.AppUser_Deprecate @Id = @DepId, @AppUserId = 1;
DECLARE @DepStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #RDep);
DROP TABLE #RDep;

EXEC test.Assert_IsEqual
    @TestName = N'Arrange: second AD user created then deprecated',
    @Expected = N'1',
    @Actual   = @DepStatus;
GO

-- =============================================
-- Test 1: an active AD-linked user resolves.
-- =============================================
CREATE TABLE #Act1 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act1
EXEC Location.AppUser_GetActiveByAdAccount @AdAccount = N'test.adactive.031';

DECLARE @Count1 INT = (SELECT COUNT(*) FROM #Act1);
DECLARE @Initials1 NVARCHAR(10) = (SELECT TOP 1 Initials FROM #Act1);
DROP TABLE #Act1;

EXEC test.Assert_RowCount
    @TestName      = N'GetActiveByAdAccount active: 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count1;

EXEC test.Assert_IsEqual
    @TestName = N'GetActiveByAdAccount active: the right person comes back',
    @Expected = N'AA31',
    @Actual   = @Initials1;
GO

-- =============================================
-- Test 2: an unknown account returns nothing.
-- =============================================
CREATE TABLE #Act2 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act2
EXEC Location.AppUser_GetActiveByAdAccount @AdAccount = N'no.such.account.031';

DECLARE @Count2 INT = (SELECT COUNT(*) FROM #Act2);
DROP TABLE #Act2;

EXEC test.Assert_RowCount
    @TestName      = N'GetActiveByAdAccount unknown: 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @Count2;
GO

-- =============================================
-- Test 3: a deprecated user FAILS the gate.
-- =============================================
CREATE TABLE #Act3 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act3
EXEC Location.AppUser_GetActiveByAdAccount @AdAccount = N'test.addeprecated.031';

DECLARE @Count3 INT = (SELECT COUNT(*) FROM #Act3);
DROP TABLE #Act3;

EXEC test.Assert_RowCount
    @TestName      = N'GetActiveByAdAccount deprecated: 0 rows (gate blocks)',
    @ExpectedCount = 0,
    @ActualCount   = @Count3;
GO

-- =============================================
-- Test 4: a NULL account resolves nobody (an unauthenticated session).
-- =============================================
CREATE TABLE #Act4 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act4
EXEC Location.AppUser_GetActiveByAdAccount @AdAccount = NULL;

DECLARE @Count4 INT = (SELECT COUNT(*) FROM #Act4);
DROP TABLE #Act4;

EXEC test.Assert_RowCount
    @TestName      = N'GetActiveByAdAccount NULL: 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @Count4;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
