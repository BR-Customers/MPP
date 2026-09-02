-- =============================================
-- File:         03_appuser/046_AppUser_Pin_lookups.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-02
-- Description:
--   Tests for the PIN sign-in resolvers Location.AppUser_GetActiveByPin
--   (presence gate, active rows only) and Location.AppUser_GetByPin
--   (history lookup, includes deprecated rows).
--
--   The pair mirrors AppUser_GetActiveByInitials / AppUser_GetByInitials:
--   a person whose row is deprecated must FAIL the presence gate but still
--   RESOLVE through the history lookup, so the login screen can say
--   "deactivated" instead of offering self-registration on a PIN that is
--   already taken.
--
--   Test 5 guards the single most likely production failure: a leading-zero
--   PIN (full-time employees' codes start with 0) being eaten by a numeric
--   coercion somewhere in the chain.
--
--   Pre-conditions:
--     - Migration 0069 applied (Location.AppUser.Pin exists)
--     - Location.AppUser_Create deployed (v4.0 with @Pin)
--     - Location.AppUser_Deprecate deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'03_appuser/046_AppUser_Pin_lookups.sql';
GO

-- =============================================
-- Arrange: create an active operator with a known PIN.
-- =============================================
CREATE TABLE #MkActive (Status BIT, Message NVARCHAR(500), NewId BIGINT);

INSERT INTO #MkActive
EXEC Location.AppUser_Create
    @Initials    = N'PT1',
    @DisplayName = N'Pin Test Active',
    @Pin         = N'90001',
    @AppUserId   = 1;

DROP TABLE #MkActive;
GO

-- =============================================
-- Test 1: GetActiveByPin resolves an active operator.
-- =============================================
CREATE TABLE #Act1 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act1
EXEC Location.AppUser_GetActiveByPin @Pin = N'90001';

DECLARE @Count1 INT = (SELECT COUNT(*) FROM #Act1);

EXEC test.Assert_RowCount
    @TestName      = N'GetActiveByPin active: 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count1;

DECLARE @Initials1 NVARCHAR(10) = (SELECT TOP 1 Initials FROM #Act1);
DROP TABLE #Act1;

EXEC test.Assert_IsEqual
    @TestName = N'GetActiveByPin active: Initials come back with the row',
    @Expected = N'PT1',
    @Actual   = @Initials1;
GO

-- =============================================
-- Test 2: GetActiveByPin returns nothing for an unknown PIN.
-- =============================================
CREATE TABLE #Act2 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act2
EXEC Location.AppUser_GetActiveByPin @Pin = N'99999';

DECLARE @Count2 INT = (SELECT COUNT(*) FROM #Act2);
DROP TABLE #Act2;

EXEC test.Assert_RowCount
    @TestName      = N'GetActiveByPin unknown: 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @Count2;
GO

-- =============================================
-- Test 3: a deprecated operator FAILS the presence gate ...
-- =============================================
CREATE TABLE #MkDep (Status BIT, Message NVARCHAR(500), NewId BIGINT);

INSERT INTO #MkDep
EXEC Location.AppUser_Create
    @Initials    = N'PT2',
    @DisplayName = N'Pin Test Deprecated',
    @Pin         = N'90002',
    @AppUserId   = 1;

DECLARE @DepId BIGINT = (SELECT NewId FROM #MkDep);
DROP TABLE #MkDep;

CREATE TABLE #DepRes (Status BIT, Message NVARCHAR(500));
INSERT INTO #DepRes
EXEC Location.AppUser_Deprecate @Id = @DepId, @AppUserId = 1;
DROP TABLE #DepRes;

CREATE TABLE #Act3 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act3
EXEC Location.AppUser_GetActiveByPin @Pin = N'90002';

DECLARE @Count3 INT = (SELECT COUNT(*) FROM #Act3);
DROP TABLE #Act3;

EXEC test.Assert_RowCount
    @TestName      = N'GetActiveByPin deprecated: 0 rows (presence gate blocks)',
    @ExpectedCount = 0,
    @ActualCount   = @Count3;
GO

-- =============================================
-- Test 4: ... but STILL resolves through the history lookup.
--   This is what lets the login screen say "deactivated" rather than
--   offering self-registration on a PIN that is already taken.
-- =============================================
CREATE TABLE #Act4 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act4
EXEC Location.AppUser_GetByPin @Pin = N'90002';

DECLARE @Count4 INT = (SELECT COUNT(*) FROM #Act4);
DROP TABLE #Act4;

EXEC test.Assert_RowCount
    @TestName      = N'GetByPin deprecated: 1 row (history lookup allows)',
    @ExpectedCount = 1,
    @ActualCount   = @Count4;
GO

-- =============================================
-- Test 5: a LEADING-ZERO PIN round-trips intact.
--   Full-time employees' codes start with 0; temps' do not. If anything
--   in the chain coerces the PIN to a number the zero is eaten and every
--   full-time employee is locked out. This asserts the SQL layer is clean;
--   the NQ layer is guarded separately by sqlType 7 (String).
-- =============================================
CREATE TABLE #MkZero (Status BIT, Message NVARCHAR(500), NewId BIGINT);

INSERT INTO #MkZero
EXEC Location.AppUser_Create
    @Initials    = N'PT3',
    @DisplayName = N'Pin Test Leading Zero',
    @Pin         = N'09003',
    @AppUserId   = 1;

DROP TABLE #MkZero;

CREATE TABLE #Act5 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act5
EXEC Location.AppUser_GetActiveByPin @Pin = N'09003';

DECLARE @Pin5 NVARCHAR(5) = (SELECT TOP 1 Pin FROM #Act5);
DROP TABLE #Act5;

EXEC test.Assert_IsEqual
    @TestName = N'GetActiveByPin: leading zero survives the round trip',
    @Expected = N'09003',
    @Actual   = @Pin5;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
