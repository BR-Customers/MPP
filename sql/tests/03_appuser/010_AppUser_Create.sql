-- =============================================
-- File:         03_appuser/010_AppUser_Create.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Description:
--   Tests for Location.AppUser_Create.
--   Covers: happy path (all params), NULL AdAccount, NULL DisplayName,
--   duplicate AdAccount, and minimal params (optional fields all NULL).
--
--   Pre-conditions:
--     - Migration 0001 applied (Location.AppUser, Audit.ConfigLog,
--       Audit.FailureLog, audit lookup seeds all present)
--     - All audit infrastructure procs deployed
--     - Location.AppUser_Create proc deployed
--     - Bootstrap user Id=1 exists
-- =============================================

EXEC test.BeginTestFile @FileName = N'03_appuser/010_AppUser_Create.sql';
GO

-- =============================================
-- Test 1: Happy path - create user with all params
--   Assert Status=1, NewId not NULL.
--   Verify row stored with correct column values.
--   Verify ConfigLog entry written for the new user.
-- =============================================

-- Capture result from proc
CREATE TABLE #Result1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Result1
EXEC Location.AppUser_Create
    @Initials     = N'JD',
    @DisplayName  = N'John Doe',
    @Pin = N'93001',
    @AdAccount    = N'DOMAIN\jdoe',
    @IgnitionRole = N'Operator',
    @AppUserId    = 1;

DECLARE @S     BIT           = (SELECT Status FROM #Result1);
DECLARE @SStr  NVARCHAR(1)   = CAST(@S AS NVARCHAR(1));
DECLARE @NewId BIGINT        = (SELECT NewId FROM #Result1);
DROP TABLE #Result1;

EXEC test.Assert_IsEqual
    @TestName = N'[HappyPath] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[HappyPath] NewId is not NULL',
    @Value    = @NewIdStr;

-- Verify row exists in AppUser
DECLARE @RowCount INT;
SELECT @RowCount = COUNT(*)
FROM Location.AppUser
WHERE Id = @NewId;

EXEC test.Assert_RowCount
    @TestName      = N'[HappyPath] AppUser row exists',
    @ExpectedCount = 1,
    @ActualCount   = @RowCount;

-- Verify column values stored correctly
DECLARE @StoredInitials     NVARCHAR(10),
        @StoredAdAccount    NVARCHAR(100),
        @StoredDisplayName  NVARCHAR(200),
        @StoredIgnitionRole NVARCHAR(100),
        @StoredDeprecatedAt DATETIME2(3);

SELECT
    @StoredInitials     = Initials,
    @StoredAdAccount    = AdAccount,
    @StoredDisplayName  = DisplayName,
    @StoredIgnitionRole = IgnitionRole,
    @StoredDeprecatedAt = DeprecatedAt
FROM Location.AppUser
WHERE Id = @NewId;

EXEC test.Assert_IsEqual
    @TestName = N'[HappyPath] Initials stored correctly',
    @Expected = N'JD',
    @Actual   = @StoredInitials;

EXEC test.Assert_IsEqual
    @TestName = N'[HappyPath] AdAccount stored correctly',
    @Expected = N'DOMAIN\jdoe',
    @Actual   = @StoredAdAccount;

EXEC test.Assert_IsEqual
    @TestName = N'[HappyPath] DisplayName stored correctly',
    @Expected = N'John Doe',
    @Actual   = @StoredDisplayName;

EXEC test.Assert_IsEqual
    @TestName = N'[HappyPath] IgnitionRole stored correctly',
    @Expected = N'Operator',
    @Actual   = @StoredIgnitionRole;

DECLARE @DepAtStr NVARCHAR(1) = CASE WHEN @StoredDeprecatedAt IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[HappyPath] DeprecatedAt is NULL (active)',
    @Expected = N'1',
    @Actual   = @DepAtStr;

-- Verify ConfigLog entry written for this entity
DECLARE @ConfigLogCount INT;
SELECT @ConfigLogCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'AppUser'
  AND cl.EntityId = @NewId;

EXEC test.Assert_RowCount
    @TestName      = N'[HappyPath] ConfigLog entry written',
    @ExpectedCount = 1,
    @ActualCount   = @ConfigLogCount;
GO

-- =============================================
-- Test 2: NULL Initials - rejected
--   Status=0, NewId is NULL, message set.
-- =============================================
CREATE TABLE #Result2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Result2
EXEC Location.AppUser_Create
    @Initials    = NULL,
    @DisplayName = N'No Initials User',
    @Pin = N'93002',
    @AppUserId   = 1;

DECLARE @S2    BIT         = (SELECT Status FROM #Result2);
DECLARE @SStr2 NVARCHAR(1) = CAST(@S2 AS NVARCHAR(1));
DECLARE @NewId2 BIGINT     = (SELECT NewId FROM #Result2);
DROP TABLE #Result2;

EXEC test.Assert_IsEqual
    @TestName = N'[NullInitials] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr2;

DECLARE @NewIdStr2 NVARCHAR(20) = CAST(@NewId2 AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[NullInitials] NewId is NULL',
    @Value    = @NewIdStr2;
GO

-- =============================================
-- Test 3: NULL DisplayName - rejected
--   Status=0.
-- =============================================
CREATE TABLE #Result3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Result3
EXEC Location.AppUser_Create
    @Initials    = N'ND',
    @DisplayName = NULL,
    @Pin         = N'93007',
    @AppUserId   = 1;

DECLARE @S3    BIT         = (SELECT Status FROM #Result3);
DECLARE @SStr3 NVARCHAR(1) = CAST(@S3 AS NVARCHAR(1));
DROP TABLE #Result3;

EXEC test.Assert_IsEqual
    @TestName = N'[NullDisplayName] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr3;

-- Confirm no row was inserted
DECLARE @RowCount3 INT;
SELECT @RowCount3 = COUNT(*)
FROM Location.AppUser
WHERE Initials = N'ND';

EXEC test.Assert_RowCount
    @TestName      = N'[NullDisplayName] No row inserted',
    @ExpectedCount = 0,
    @ActualCount   = @RowCount3;
GO

-- =============================================
-- Test 4: Duplicate Initials - second call rejected
--   Create same Initials twice.
--   Second call: Status=0, NewId NULL.
--   Verify FailureLog entry written for the duplicate attempt.
-- =============================================

-- First call - should succeed
CREATE TABLE #Result4a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Result4a
EXEC Location.AppUser_Create
    @Initials    = N'DP',
    @DisplayName = N'Duplicate User',
    @Pin = N'93003',
    @AppUserId   = 1;

DECLARE @S4a    BIT         = (SELECT Status FROM #Result4a);
DECLARE @SStr4a NVARCHAR(1) = CAST(@S4a AS NVARCHAR(1));
DROP TABLE #Result4a;

EXEC test.Assert_IsEqual
    @TestName = N'[DuplicateInitials] First create: Status is 1',
    @Expected = N'1',
    @Actual   = @SStr4a;

-- Snapshot FailureLog count before the duplicate attempt
DECLARE @FailCountBefore INT;
SELECT @FailCountBefore = COUNT(*)
FROM Audit.FailureLog fl
INNER JOIN Audit.LogEntityType let ON let.Id = fl.LogEntityTypeId
WHERE let.Code = N'AppUser'
  AND fl.ProcedureName = N'Location.AppUser_Create';

-- Second call with the same Initials - should be rejected
CREATE TABLE #Result4b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Result4b
EXEC Location.AppUser_Create
    @Initials    = N'DP',
    @DisplayName = N'Duplicate User Again',
    @Pin = N'93004',
    @AppUserId   = 1;

DECLARE @S4b    BIT         = (SELECT Status FROM #Result4b);
DECLARE @SStr4b NVARCHAR(1) = CAST(@S4b AS NVARCHAR(1));
DECLARE @NewId4b BIGINT     = (SELECT NewId FROM #Result4b);
DROP TABLE #Result4b;

EXEC test.Assert_IsEqual
    @TestName = N'[DuplicateInitials] Second create: Status is 0',
    @Expected = N'0',
    @Actual   = @SStr4b;

DECLARE @NewId4bStr NVARCHAR(20) = CAST(@NewId4b AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[DuplicateInitials] Second create: NewId is NULL',
    @Value    = @NewId4bStr;

-- Verify FailureLog entry was written for the duplicate attempt
DECLARE @FailCountAfter INT;
SELECT @FailCountAfter = COUNT(*)
FROM Audit.FailureLog fl
INNER JOIN Audit.LogEntityType let ON let.Id = fl.LogEntityTypeId
WHERE let.Code = N'AppUser'
  AND fl.ProcedureName = N'Location.AppUser_Create';

DECLARE @FailDiff INT = @FailCountAfter - @FailCountBefore;
EXEC test.Assert_RowCount
    @TestName      = N'[DuplicateInitials] FailureLog entry written for duplicate',
    @ExpectedCount = 1,
    @ActualCount   = @FailDiff;
GO

-- =============================================
-- Test 5: Minimal params - operator without AD account
--   Only @Initials + @DisplayName + @AppUserId.
--   AdAccount and IgnitionRole default to NULL.
--   Status=1. Verify NULLs stored.
-- =============================================
CREATE TABLE #Result5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Result5
EXEC Location.AppUser_Create
    @Initials    = N'MIN',
    @DisplayName = N'Minimal Operator',
    @Pin = N'93005',
    @AppUserId   = 1;

DECLARE @S5    BIT         = (SELECT Status FROM #Result5);
DECLARE @SStr5 NVARCHAR(1) = CAST(@S5 AS NVARCHAR(1));
DECLARE @NewId5 BIGINT     = (SELECT NewId FROM #Result5);
DROP TABLE #Result5;

EXEC test.Assert_IsEqual
    @TestName = N'[MinimalParams] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr5;

DECLARE @NewId5Str NVARCHAR(20) = CAST(@NewId5 AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[MinimalParams] NewId is not NULL',
    @Value    = @NewId5Str;

-- Verify optional columns are NULL
DECLARE @StoredAd5   NVARCHAR(100),
        @StoredRole5 NVARCHAR(100);

SELECT @StoredAd5   = AdAccount,
       @StoredRole5 = IgnitionRole
FROM Location.AppUser
WHERE Id = @NewId5;

EXEC test.Assert_IsNull
    @TestName = N'[MinimalParams] AdAccount is NULL',
    @Value    = @StoredAd5;

EXEC test.Assert_IsNull
    @TestName = N'[MinimalParams] IgnitionRole is NULL',
    @Value    = @StoredRole5;
GO

-- =============================================
-- Test 6: IgnitionRole without AdAccount - rejected
--   Shop-floor operator pattern: Initials + DisplayName fine,
--   but IgnitionRole requires AdAccount. Proc must reject before
--   the CHECK constraint fires.
-- =============================================
CREATE TABLE #Result6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Result6
EXEC Location.AppUser_Create
    @Initials     = N'IR6',
    @DisplayName  = N'Role Without AD',
    @Pin = N'93006',
    @AdAccount    = NULL,
    @IgnitionRole = N'Supervisor',
    @AppUserId    = 1;

DECLARE @S6     BIT          = (SELECT Status FROM #Result6);
DECLARE @SStr6  NVARCHAR(1)  = CAST(@S6 AS NVARCHAR(1));
DECLARE @NewId6 BIGINT       = (SELECT NewId FROM #Result6);
DROP TABLE #Result6;

EXEC test.Assert_IsEqual
    @TestName = N'[IgnitionRoleWithoutAd] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr6;

DECLARE @NewId6Str NVARCHAR(20) = CAST(@NewId6 AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[IgnitionRoleWithoutAd] NewId is NULL',
    @Value    = @NewId6Str;

-- No row was inserted
DECLARE @RowCount6 INT;
SELECT @RowCount6 = COUNT(*) FROM Location.AppUser WHERE Initials = N'IR6';
EXEC test.Assert_RowCount
    @TestName      = N'[IgnitionRoleWithoutAd] No row inserted',
    @ExpectedCount = 0,
    @ActualCount   = @RowCount6;
GO

-- =============================================
-- Test 7: a 4-digit PIN is rejected.
--   Full-time employees' codes are 5 characters with a LEADING ZERO
--   (04218), never 4 digits. If this ever passes, something has coerced
--   the PIN to a number and every full-time employee is locked out.
-- =============================================
CREATE TABLE #ShortPin (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #ShortPin
EXEC Location.AppUser_Create
    @Initials    = N'SPN',
    @DisplayName = N'Short Pin',
    @Pin         = N'4218',
    @AppUserId   = 1;

DECLARE @SStr7 NVARCHAR(1) = CAST((SELECT Status FROM #ShortPin) AS NVARCHAR(1));
DROP TABLE #ShortPin;

EXEC test.Assert_IsEqual
    @TestName = N'[ShortPin] 4-digit PIN rejected',
    @Expected = N'0',
    @Actual   = @SStr7;
GO

-- =============================================
-- Test 8: a duplicate PIN is rejected.
--   PINs are UNIQUE across all rows, so a second person can never claim
--   one -- this is what stops self-registration from re-pointing an
--   existing person's attribution.
-- =============================================
CREATE TABLE #DupPinA (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #DupPinA
EXEC Location.AppUser_Create
    @Initials    = N'DPA',
    @DisplayName = N'Dup Pin A',
    @Pin         = N'93101',
    @AppUserId   = 1;
DROP TABLE #DupPinA;

CREATE TABLE #DupPinB (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #DupPinB
EXEC Location.AppUser_Create
    @Initials    = N'DPB',
    @DisplayName = N'Dup Pin B',
    @Pin         = N'93101',
    @AppUserId   = 1;

DECLARE @SStr8 NVARCHAR(1) = CAST((SELECT Status FROM #DupPinB) AS NVARCHAR(1));
DROP TABLE #DupPinB;

EXEC test.Assert_IsEqual
    @TestName = N'[DupPin] duplicate PIN rejected',
    @Expected = N'0',
    @Actual   = @SStr8;
GO

-- =============================================
-- Test 9: a leading-zero PIN is STORED with its zero intact.
-- =============================================
CREATE TABLE #ZeroPin (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #ZeroPin
EXEC Location.AppUser_Create
    @Initials    = N'ZPN',
    @DisplayName = N'Zero Pin',
    @Pin         = N'09310',
    @AppUserId   = 1;
DROP TABLE #ZeroPin;

DECLARE @StoredPin NVARCHAR(5) = (SELECT Pin FROM Location.AppUser WHERE Initials = N'ZPN');
EXEC test.Assert_IsEqual
    @TestName = N'[ZeroPin] leading zero stored intact',
    @Expected = N'09310',
    @Actual   = @StoredPin;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
