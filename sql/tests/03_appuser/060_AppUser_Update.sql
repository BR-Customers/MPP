-- =============================================
-- File:         03_appuser/060_AppUser_Update.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Description:
--   Tests for Location.AppUser_Update.
--   Covers: happy path (fields updated, audit written), NULL DisplayName,
--   non-existent Id, and update rejected on deprecated user.
--
--   Pre-conditions:
--     - Migration 0001 applied (Location.AppUser, Audit.ConfigLog,
--       Audit.FailureLog, audit lookup seeds all present)
--     - All audit infrastructure procs deployed
--     - Location.AppUser_Create, Location.AppUser_Update,
--       Location.AppUser_Deprecate procs deployed
--     - Bootstrap user Id=1 exists
-- =============================================

EXEC test.BeginTestFile @FileName = N'03_appuser/060_AppUser_Update.sql';
GO

-- =============================================
-- Test 1: Happy path - create a user then update DisplayName
--   and IgnitionRole.
--   Assert Status=1. Verify both columns changed in the
--   AppUser row. Verify ConfigLog NewValue captures updated data.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @UserId BIGINT;

CREATE TABLE #CreateHappy (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #CreateHappy
EXEC Location.AppUser_Create
    @Initials    = N'UPH',
    @DisplayName = N'Happy User',
    @Pin = N'98001',
    @AdAccount   = N'update060.happy@test.com',
    @IgnitionRole = N'Operator',
    @AppUserId   = 1;
SELECT @UserId = NewId FROM #CreateHappy;
DROP TABLE #CreateHappy;

-- Snapshot ConfigLog count before update
DECLARE @LogCountBefore INT;
SELECT @LogCountBefore = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'AppUser'
  AND cl.EntityId = @UserId;

CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R1
EXEC Location.AppUser_Update
    @Id           = @UserId,
    @Initials     = N'UPH',
    @DisplayName  = N'Happy User Updated',
    @Pin = N'98002',
    @AdAccount    = N'update060.happy@test.com',
    @IgnitionRole = N'Supervisor',
    @AppUserId    = 1;
SELECT @S = Status, @M = Message FROM #R1;
DROP TABLE #R1;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[HappyPath] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify DisplayName and IgnitionRole changed
DECLARE @StoredDisplayName  NVARCHAR(200),
        @StoredIgnitionRole NVARCHAR(100);

SELECT
    @StoredDisplayName  = DisplayName,
    @StoredIgnitionRole = IgnitionRole
FROM Location.AppUser
WHERE Id = @UserId;

EXEC test.Assert_IsEqual
    @TestName = N'[HappyPath] DisplayName updated',
    @Expected = N'Happy User Updated',
    @Actual   = @StoredDisplayName;

EXEC test.Assert_IsEqual
    @TestName = N'[HappyPath] IgnitionRole updated',
    @Expected = N'Supervisor',
    @Actual   = @StoredIgnitionRole;

-- Verify a new ConfigLog row was written for the update
DECLARE @LogCountAfter INT;
SELECT @LogCountAfter = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'AppUser'
  AND cl.EntityId = @UserId;

DECLARE @LogDiff INT = @LogCountAfter - @LogCountBefore;
EXEC test.Assert_RowCount
    @TestName      = N'[HappyPath] ConfigLog row written for update',
    @ExpectedCount = 1,
    @ActualCount   = @LogDiff;

-- Verify NewValue in the most recent ConfigLog row is not NULL
-- (proc stores JSON snapshot of updated fields)
DECLARE @NewValueStr NVARCHAR(MAX);
SELECT TOP 1
    @NewValueStr = cl.NewValue
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
INNER JOIN Audit.LogEventType  lev ON lev.Id = cl.LogEventTypeId
WHERE let.Code = N'AppUser'
  AND lev.Code = N'Updated'
  AND cl.EntityId = @UserId
ORDER BY cl.LoggedAt DESC;

EXEC test.Assert_IsNotNull
    @TestName = N'[HappyPath] ConfigLog NewValue is not NULL',
    @Value    = @NewValueStr;
GO

-- =============================================
-- Test 2: NULL DisplayName - rejected.
--   Status=0. Row must not be altered.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @UserId BIGINT;

CREATE TABLE #CreateNullDN (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #CreateNullDN
EXEC Location.AppUser_Create
    @Initials    = N'UND',
    @DisplayName = N'Null DN User',
    @Pin = N'98003',
    @AppUserId   = 1;
SELECT @UserId = NewId FROM #CreateNullDN;
DROP TABLE #CreateNullDN;

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R2
EXEC Location.AppUser_Update
    @Id          = @UserId,
    @Initials    = N'UND',
    @DisplayName = NULL,
    @Pin         = N'98008',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #R2;
DROP TABLE #R2;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[NullDisplayName] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

-- Verify DisplayName unchanged
DECLARE @StoredDN NVARCHAR(200);
SELECT @StoredDN = DisplayName FROM Location.AppUser WHERE Id = @UserId;

EXEC test.Assert_IsEqual
    @TestName = N'[NullDisplayName] DisplayName unchanged',
    @Expected = N'Null DN User',
    @Actual   = @StoredDN;
GO

-- =============================================
-- Test 3: Non-existent Id - rejected.
--   Status=0.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1);

DECLARE @BogusId BIGINT = -999999;

CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R3
EXEC Location.AppUser_Update
    @Id          = @BogusId,
    @Initials    = N'GHX',
    @DisplayName = N'Ghost User',
    @Pin = N'98004',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #R3;
DROP TABLE #R3;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[NonExistentId] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 4: Cannot update a deprecated user.
--   Create user, deprecate, then attempt update.
--   Status=0. DisplayName must remain at deprecated value.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @UserId BIGINT;

-- Create
CREATE TABLE #CreateDepReject (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #CreateDepReject
EXEC Location.AppUser_Create
    @Initials    = N'UDR',
    @DisplayName = N'Dep Reject User',
    @Pin = N'98005',
    @AdAccount   = N'update060.depreject@test.com',
    @AppUserId   = 1;
SELECT @UserId = NewId FROM #CreateDepReject;
DROP TABLE #CreateDepReject;

-- Deprecate using a second helper user to avoid self-deprecate block
DECLARE @HelperUserId BIGINT;
CREATE TABLE #CreateHelper (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #CreateHelper
EXEC Location.AppUser_Create
    @Initials    = N'UDH',
    @DisplayName = N'Dep Helper',
    @Pin = N'98006',
    @AdAccount   = N'update060.dephelper@test.com',
    @AppUserId   = 1;
SELECT @HelperUserId = NewId FROM #CreateHelper;
DROP TABLE #CreateHelper;

CREATE TABLE #R4a (Status BIT, Message NVARCHAR(500));
INSERT INTO #R4a
EXEC Location.AppUser_Deprecate
    @Id        = @UserId,
    @AppUserId = @HelperUserId;
DROP TABLE #R4a;

-- Attempt to update the now-deprecated user
CREATE TABLE #R4b (Status BIT, Message NVARCHAR(500));
INSERT INTO #R4b
EXEC Location.AppUser_Update
    @Id          = @UserId,
    @Initials    = N'UDR',
    @DisplayName = N'Should Not Apply',
    @Pin = N'98007',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #R4b;
DROP TABLE #R4b;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[DeprecatedUser] Update rejected: Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

-- Verify DisplayName was not changed
DECLARE @StoredDN NVARCHAR(200);
SELECT @StoredDN = DisplayName FROM Location.AppUser WHERE Id = @UserId;

EXEC test.Assert_IsEqual
    @TestName = N'[DeprecatedUser] DisplayName not altered',
    @Expected = N'Dep Reject User',
    @Actual   = @StoredDN;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
