-- =============================================
-- File:         02_audit_readers/060_FailureLog_GetByEntity.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Description:
--   Tests for Audit.FailureLog_GetByEntity.
--   Covers: returns matching rows for valid entity type + ID,
--   and 0 rows for invalid entity type code.
--
--   Pre-conditions:
--     - Migration 0001 applied (audit lookup seeds present)
--     - Location.AppUser Id=1 (system.bootstrap) present
--     - Audit.Audit_LogFailure deployed
--     - Audit.FailureLog_GetByEntity deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'02_audit_readers/060_FailureLog_GetByEntity.sql';
GO

-- =============================================
-- Setup: Insert 2 FailureLog rows for AppUser entity 77,
--        and 1 FailureLog row for Location entity 77.
--   All three rows use a unique ProcedureName prefix so
--   tests can isolate what this file inserted.
-- =============================================
EXEC Audit.Audit_LogFailure
    @AppUserId           = 1,
    @LogEntityTypeCode   = N'AppUser',
    @EntityId            = 77,
    @LogEventTypeCode    = N'Created',
    @FailureReason       = N'Test 060: AppUser 77 row 1 - duplicate AdAccount',
    @ProcedureName       = N'Test060.AppUser_Create',
    @AttemptedParameters = N'{"AdAccount":"test060a"}';

EXEC Audit.Audit_LogFailure
    @AppUserId           = 1,
    @LogEntityTypeCode   = N'AppUser',
    @EntityId            = 77,
    @LogEventTypeCode    = N'Updated',
    @FailureReason       = N'Test 060: AppUser 77 row 2 - user not found',
    @ProcedureName       = N'Test060.AppUser_Update',
    @AttemptedParameters = N'{"Id":77}';

EXEC Audit.Audit_LogFailure
    @AppUserId           = 1,
    @LogEntityTypeCode   = N'Location',
    @EntityId            = 77,
    @LogEventTypeCode    = N'Created',
    @FailureReason       = N'Test 060: Location 77 row 1 - name conflict',
    @ProcedureName       = N'Test060.Location_Create',
    @AttemptedParameters = NULL;
GO

-- =============================================
-- Test 1: Valid entity type + entity ID returns matching rows.
--   Expect exactly 2 rows for AppUser entity 77
--   inserted during setup. Location row must not leak through.
-- =============================================
CREATE TABLE #GetByEntity1 (
    Id                  BIGINT,
    AttemptedAt         DATETIME2(3),
    AppUserId           BIGINT,
    UserDisplayName     NVARCHAR(200),
    LogEntityTypeId     BIGINT,
    LogEntityTypeName   NVARCHAR(100),
    EntityId            BIGINT,
    LogEventTypeId      BIGINT,
    LogEventTypeName    NVARCHAR(100),
    FailureReason       NVARCHAR(500),
    ProcedureName       NVARCHAR(200),
    AttemptedParameters NVARCHAR(MAX),
    LocationId          BIGINT,
    LocationName        NVARCHAR(200),
    LotId               BIGINT,
    LotName             NVARCHAR(50)
);

INSERT INTO #GetByEntity1
EXEC Audit.FailureLog_GetByEntity
    @LogEntityTypeCode = N'AppUser',
    @EntityId          = 77;

-- Assert 1a: exactly 2 rows from this file returned for AppUser entity 77
DECLARE @MatchCount INT = (
    SELECT COUNT(*)
    FROM #GetByEntity1
    WHERE ProcedureName IN (N'Test060.AppUser_Create', N'Test060.AppUser_Update')
);
EXEC test.Assert_RowCount
    @TestName      = N'GetByEntity valid: 2 AppUser 77 setup rows returned',
    @ExpectedCount = 2,
    @ActualCount   = @MatchCount;

-- Assert 1b: Location row did not leak into result
DECLARE @LocationLeakCount INT = (
    SELECT COUNT(*)
    FROM #GetByEntity1
    WHERE ProcedureName = N'Test060.Location_Create'
);
DECLARE @NoLeakStr NVARCHAR(5) = CAST(@LocationLeakCount AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'GetByEntity valid: Location entity rows not returned for AppUser filter',
    @Expected = N'0',
    @Actual   = @NoLeakStr;

DROP TABLE #GetByEntity1;
GO

-- =============================================
-- Test 2: Invalid entity type code returns 0 rows.
--   Read procs no longer return Status — invalid filters
--   simply produce empty result sets.
-- =============================================
CREATE TABLE #GetByEntity2 (
    Id                  BIGINT,
    AttemptedAt         DATETIME2(3),
    AppUserId           BIGINT,
    UserDisplayName     NVARCHAR(200),
    LogEntityTypeId     BIGINT,
    LogEntityTypeName   NVARCHAR(100),
    EntityId            BIGINT,
    LogEventTypeId      BIGINT,
    LogEventTypeName    NVARCHAR(100),
    FailureReason       NVARCHAR(500),
    ProcedureName       NVARCHAR(200),
    AttemptedParameters NVARCHAR(MAX),
    LocationId          BIGINT,
    LocationName        NVARCHAR(200),
    LotId               BIGINT,
    LotName             NVARCHAR(50)
);

INSERT INTO #GetByEntity2
EXEC Audit.FailureLog_GetByEntity
    @LogEntityTypeCode = N'BOGUS_ENTITY_TYPE',
    @EntityId          = 77;

-- Assert 2a: 0 rows returned for invalid entity type code
DECLARE @RowCount2 INT = (SELECT COUNT(*) FROM #GetByEntity2);
EXEC test.Assert_RowCount
    @TestName      = N'GetByEntity invalid code: 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @RowCount2;

DROP TABLE #GetByEntity2;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
