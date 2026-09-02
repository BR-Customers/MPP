-- Tests for Location.AppUser_Deprecate
EXEC test.BeginTestFile @FileName = N'03_appuser/080_AppUser_Deprecate.sql';
GO

-- Test 1: Happy path
DECLARE @UserId BIGINT, @CallerId BIGINT;
CREATE TABLE #R1a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1a EXEC Location.AppUser_Create @Initials = N'D8CA', @DisplayName = N'Caller', @Pin = N'89001', @AdAccount = N'dep080.caller@test.com', @AppUserId = 1;
SELECT @CallerId = NewId FROM #R1a;
DROP TABLE #R1a;

CREATE TABLE #R1b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1b EXEC Location.AppUser_Create @Initials = N'D8TG', @DisplayName = N'Target', @Pin = N'89002', @AdAccount = N'dep080.target@test.com', @AppUserId = 1;
SELECT @UserId = NewId FROM #R1b;
DROP TABLE #R1b;

DECLARE @LogBefore INT;
SELECT @LogBefore = COUNT(*) FROM Audit.ConfigLog cl INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'AppUser' AND cl.EntityId = @UserId;

DECLARE @S BIT, @M NVARCHAR(500);
CREATE TABLE #R1c (Status BIT, Message NVARCHAR(500));
INSERT INTO #R1c EXEC Location.AppUser_Deprecate @Id = @UserId, @AppUserId = @CallerId;
SELECT @S = Status, @M = Message FROM #R1c;
DROP TABLE #R1c;

DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[HappyPath] Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @DepAt DATETIME2(3);
SELECT @DepAt = DeprecatedAt FROM Location.AppUser WHERE Id = @UserId;
DECLARE @DepAtNotNull NVARCHAR(1) = CASE WHEN @DepAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[HappyPath] DeprecatedAt is set (not NULL)', @Expected = N'1', @Actual = @DepAtNotNull;

DECLARE @LogAfter INT;
SELECT @LogAfter = COUNT(*) FROM Audit.ConfigLog cl INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'AppUser' AND cl.EntityId = @UserId;
DECLARE @LogDiff INT = @LogAfter - @LogBefore;
EXEC test.Assert_RowCount @TestName = N'[HappyPath] ConfigLog row written for deprecation', @ExpectedCount = 1, @ActualCount = @LogDiff;
GO

-- Test 2: Cannot deprecate bootstrap (Id=1)
DECLARE @S BIT, @M NVARCHAR(500);
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R2 EXEC Location.AppUser_Deprecate @Id = 1, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R2;
DROP TABLE #R2;
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[BootstrapGuard] Status is 0', @Expected = N'0', @Actual = @SStr;

DECLARE @BootstrapDepAt DATETIME2(3);
SELECT @BootstrapDepAt = DeprecatedAt FROM Location.AppUser WHERE Id = 1;
DECLARE @StillActive NVARCHAR(1) = CASE WHEN @BootstrapDepAt IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[BootstrapGuard] Bootstrap DeprecatedAt still NULL', @Expected = N'1', @Actual = @StillActive;
GO

-- Test 3: Cannot self-deprecate
DECLARE @UserId BIGINT;
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Location.AppUser_Create @Initials = N'D8SR', @DisplayName = N'SelfRef', @Pin = N'89003', @AdAccount = N'dep080.selfref@test.com', @AppUserId = 1;
SELECT @UserId = NewId FROM #R3;
DROP TABLE #R3;

DECLARE @S BIT, @M NVARCHAR(500);
CREATE TABLE #R3b (Status BIT, Message NVARCHAR(500));
INSERT INTO #R3b EXEC Location.AppUser_Deprecate @Id = @UserId, @AppUserId = @UserId;
SELECT @S = Status, @M = Message FROM #R3b;
DROP TABLE #R3b;
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[SelfDeprecate] Status is 0', @Expected = N'0', @Actual = @SStr;

DECLARE @SelfDepAt DATETIME2(3);
SELECT @SelfDepAt = DeprecatedAt FROM Location.AppUser WHERE Id = @UserId;
DECLARE @SelfActive NVARCHAR(1) = CASE WHEN @SelfDepAt IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[SelfDeprecate] DeprecatedAt still NULL', @Expected = N'1', @Actual = @SelfActive;
GO

-- Test 4: Cannot double-deprecate
DECLARE @UserId BIGINT, @CallerId BIGINT;
CREATE TABLE #R4a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4a EXEC Location.AppUser_Create @Initials = N'D8DC', @DisplayName = N'DDCaller', @Pin = N'89004', @AdAccount = N'dep080.ddcaller@test.com', @AppUserId = 1;
SELECT @CallerId = NewId FROM #R4a;
DROP TABLE #R4a;

CREATE TABLE #R4b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4b EXEC Location.AppUser_Create @Initials = N'D8DB', @DisplayName = N'Double', @Pin = N'89005', @AdAccount = N'dep080.double@test.com', @AppUserId = 1;
SELECT @UserId = NewId FROM #R4b;
DROP TABLE #R4b;

DECLARE @S BIT, @M NVARCHAR(500);
CREATE TABLE #R4c (Status BIT, Message NVARCHAR(500));
INSERT INTO #R4c EXEC Location.AppUser_Deprecate @Id = @UserId, @AppUserId = @CallerId;
SELECT @S = Status, @M = Message FROM #R4c;
DROP TABLE #R4c;
DECLARE @SStr1 NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[DoubleDeprecate] First call: Status is 1', @Expected = N'1', @Actual = @SStr1;

CREATE TABLE #R4d (Status BIT, Message NVARCHAR(500));
INSERT INTO #R4d EXEC Location.AppUser_Deprecate @Id = @UserId, @AppUserId = @CallerId;
SELECT @S = Status, @M = Message FROM #R4d;
DROP TABLE #R4d;
DECLARE @SStr2 NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[DoubleDeprecate] Second call: Status is 0', @Expected = N'0', @Actual = @SStr2;
GO

-- Test 5: Non-existent user
DECLARE @S BIT, @M NVARCHAR(500);
CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R5 EXEC Location.AppUser_Deprecate @Id = -999999, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R5;
DROP TABLE #R5;
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[NonExistentUser] Status is 0', @Expected = N'0', @Actual = @SStr;
GO

EXEC test.PrintSummary;
GO
