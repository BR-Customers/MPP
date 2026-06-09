-- =============================================
-- File:         0020_PlantFloor_Foundation/025_AppUser_AuthenticateAd.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-09
-- Description:  Tests for Location.AppUser_AuthenticateAd (per-action AD
--               elevation). Per the Task D design decisions there is NO DB-side
--               authorization: the proc authenticates the (already AD-password-
--               validated-by-Ignition) AD account, returns Id + IgnitionRole
--               for the UI to authorize on, and records the elevation outcome.
--               There is NO "wrong role" or "unknown action code" rejection.
--               Covered paths:
--                 (a) active AD user + any @ActionCode -> Status=1 + correct
--                     AppUserId + IgnitionRole + OperationLog 'ElevationGranted'
--                 (b) unknown @AdAccount -> Status=0 + FailureLog 'ElevationDenied'
--                 (c) deprecated AD user -> Status=0 + FailureLog 'ElevationDenied'
--                 (d) missing/NULL @AdAccount -> Status=0 + FailureLog 'ElevationDenied'
--
--               Fixtures: one active interactive AppUser (AdAccount + Role) and
--               one deprecated interactive AppUser, created here and cleaned up
--               FK-safe. Audit rows are asserted by counting new OperationLog/
--               FailureLog rows for the elevation event type with Id above a
--               captured baseline.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/025_AppUser_AuthenticateAd.sql';
GO

-- ---- fixtures ----
-- Clean any prior fixture artifacts (audit rows reference these user ids, but
-- AppUser has no FK back from the logs; deleting the AppUser is safe).
DELETE FROM Location.AppUser WHERE AdAccount IN (N'p1.elev.active', N'p1.elev.dep');
GO

-- Active interactive user
DECLARE @CA TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @CA
EXEC Location.AppUser_Create
    @Initials     = N'P1EA',
    @DisplayName  = N'Phase1 Elevation Active',
    @AdAccount    = N'p1.elev.active',
    @IgnitionRole = N'Supervisor',
    @AppUserId    = 1;
GO

-- Deprecated interactive user
DECLARE @CD TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @CD
EXEC Location.AppUser_Create
    @Initials     = N'P1ED',
    @DisplayName  = N'Phase1 Elevation Deprecated',
    @AdAccount    = N'p1.elev.dep',
    @IgnitionRole = N'Supervisor',
    @AppUserId    = 1;
DECLARE @DepId BIGINT = (SELECT TOP 1 NewId FROM @CD);

DECLARE @RD TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @RD EXEC Location.AppUser_Deprecate @Id = @DepId, @AppUserId = 1;
GO

-- =============================================
-- Test (a): active AD user + an @ActionCode -> Status=1, correct AppUserId +
--           IgnitionRole, and a new OperationLog 'ElevationGranted' row.
-- =============================================
DECLARE @ActiveId BIGINT = (SELECT Id FROM Location.AppUser WHERE AdAccount = N'p1.elev.active');
DECLARE @GrantedEvtId BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ElevationGranted');
DECLARE @OpBaseline BIGINT =
    ISNULL((SELECT MAX(Id) FROM Audit.OperationLog WHERE LogEventTypeId = @GrantedEvtId), 0);

CREATE TABLE #A (Status BIT, Message NVARCHAR(500), AppUserId BIGINT, IgnitionRole NVARCHAR(100));
INSERT INTO #A EXEC Location.AppUser_AuthenticateAd
    @AdAccount  = N'p1.elev.active',
    @ActionCode = N'MaterialSubstituteOverride',
    @AppUserId  = 1;

DECLARE @aS BIT, @aUid BIGINT, @aRole NVARCHAR(100);
SELECT @aS = Status, @aUid = AppUserId, @aRole = IgnitionRole FROM #A;
DROP TABLE #A;

DECLARE @aSStr NVARCHAR(1) = CAST(@aS AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[AuthOk] Status is 1', @Expected = N'1', @Actual = @aSStr;

DECLARE @aUidStr NVARCHAR(20) = CAST(@aUid AS NVARCHAR(20));
DECLARE @ActiveIdStr NVARCHAR(20) = CAST(@ActiveId AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[AuthOk] Returns the active user Id', @Expected = @ActiveIdStr, @Actual = @aUidStr;
EXEC test.Assert_IsEqual @TestName = N'[AuthOk] Returns the IgnitionRole', @Expected = N'Supervisor', @Actual = @aRole;

DECLARE @OpNew INT =
    (SELECT COUNT(*) FROM Audit.OperationLog
     WHERE LogEventTypeId = @GrantedEvtId AND Id > @OpBaseline AND EntityId = @ActiveId);
DECLARE @OpNewStr NVARCHAR(10) = CAST(@OpNew AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[AuthOk] One ElevationGranted OperationLog row', @Expected = N'1', @Actual = @OpNewStr;
GO

-- =============================================
-- Test (b): unknown @AdAccount -> Status=0 + FailureLog 'ElevationDenied'.
-- =============================================
DECLARE @DeniedEvtId BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ElevationDenied');
DECLARE @FailBaseline BIGINT =
    ISNULL((SELECT MAX(Id) FROM Audit.FailureLog WHERE LogEventTypeId = @DeniedEvtId), 0);

CREATE TABLE #B (Status BIT, Message NVARCHAR(500), AppUserId BIGINT, IgnitionRole NVARCHAR(100));
INSERT INTO #B EXEC Location.AppUser_AuthenticateAd
    @AdAccount  = N'no.such.account.zzz',
    @ActionCode = N'MaterialSubstituteOverride',
    @AppUserId  = 1;
DECLARE @bS BIT, @bUid BIGINT;
SELECT @bS = Status, @bUid = AppUserId FROM #B;
DROP TABLE #B;

DECLARE @bSStr NVARCHAR(1) = CAST(@bS AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[AuthUnknown] Status is 0', @Expected = N'0', @Actual = @bSStr;

DECLARE @bUidStr NVARCHAR(20) = CAST(@bUid AS NVARCHAR(20));
EXEC test.Assert_IsNull @TestName = N'[AuthUnknown] AppUserId is NULL', @Value = @bUidStr;

DECLARE @FailNewB INT =
    (SELECT COUNT(*) FROM Audit.FailureLog WHERE LogEventTypeId = @DeniedEvtId AND Id > @FailBaseline);
DECLARE @FailNewBStr NVARCHAR(10) = CAST(@FailNewB AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[AuthUnknown] One ElevationDenied FailureLog row', @Expected = N'1', @Actual = @FailNewBStr;
GO

-- =============================================
-- Test (c): deprecated AD user -> Status=0 + FailureLog 'ElevationDenied'.
-- =============================================
DECLARE @DeniedEvtId BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ElevationDenied');
DECLARE @FailBaseline BIGINT =
    ISNULL((SELECT MAX(Id) FROM Audit.FailureLog WHERE LogEventTypeId = @DeniedEvtId), 0);

CREATE TABLE #C (Status BIT, Message NVARCHAR(500), AppUserId BIGINT, IgnitionRole NVARCHAR(100));
INSERT INTO #C EXEC Location.AppUser_AuthenticateAd
    @AdAccount  = N'p1.elev.dep',
    @ActionCode = N'MaterialSubstituteOverride',
    @AppUserId  = 1;
DECLARE @cS BIT;
SELECT @cS = Status FROM #C;
DROP TABLE #C;

DECLARE @cSStr NVARCHAR(1) = CAST(@cS AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[AuthDeprecated] Status is 0', @Expected = N'0', @Actual = @cSStr;

DECLARE @FailNewC INT =
    (SELECT COUNT(*) FROM Audit.FailureLog WHERE LogEventTypeId = @DeniedEvtId AND Id > @FailBaseline);
DECLARE @FailNewCStr NVARCHAR(10) = CAST(@FailNewC AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[AuthDeprecated] One ElevationDenied FailureLog row', @Expected = N'1', @Actual = @FailNewCStr;
GO

-- =============================================
-- Test (d): missing/NULL @AdAccount -> Status=0 + FailureLog 'ElevationDenied'.
-- =============================================
DECLARE @DeniedEvtId BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ElevationDenied');
DECLARE @FailBaseline BIGINT =
    ISNULL((SELECT MAX(Id) FROM Audit.FailureLog WHERE LogEventTypeId = @DeniedEvtId), 0);

CREATE TABLE #D (Status BIT, Message NVARCHAR(500), AppUserId BIGINT, IgnitionRole NVARCHAR(100));
INSERT INTO #D EXEC Location.AppUser_AuthenticateAd
    @AdAccount  = NULL,
    @ActionCode = N'MaterialSubstituteOverride',
    @AppUserId  = 1;
DECLARE @dS BIT;
SELECT @dS = Status FROM #D;
DROP TABLE #D;

DECLARE @dSStr NVARCHAR(1) = CAST(@dS AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[AuthNullAd] Status is 0', @Expected = N'0', @Actual = @dSStr;

DECLARE @FailNewD INT =
    (SELECT COUNT(*) FROM Audit.FailureLog WHERE LogEventTypeId = @DeniedEvtId AND Id > @FailBaseline);
DECLARE @FailNewDStr NVARCHAR(10) = CAST(@FailNewD AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[AuthNullAd] One ElevationDenied FailureLog row', @Expected = N'1', @Actual = @FailNewDStr;
GO

-- ---- cleanup fixtures ----
DELETE FROM Location.AppUser WHERE AdAccount IN (N'p1.elev.active', N'p1.elev.dep');
GO

EXEC test.EndTestFile;
GO
