-- =============================================
-- File:         02_audit_readers/050_ConfigLog_List.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Description:
--   Tests for Audit.ConfigLog_List.
--   Covers: date range returning rows, historical range returning
--   0 rows, entity type filter, invalid entity type filter returns 0 rows,
--   @DescriptionLike substring match, and @LogSeverityCode filter.
--
--   Pre-conditions:
--     - Migration 0001 applied (audit lookup seeds present)
--     - Location.AppUser Id=1 (system.bootstrap) present
--     - Audit.Audit_LogConfigChange deployed
--     - Audit.ConfigLog_List deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'02_audit_readers/050_ConfigLog_List.sql';
GO

-- =============================================
-- Setup: Insert rows used by filter tests below.
--   2 rows for AppUser entity, 1 row for Location entity.
--   All rows written now (UTC) so they fall inside a
--   [-1h, +1h] window used in Test 1 and Test 3.
-- =============================================
EXEC Audit.Audit_LogConfigChange
    @AppUserId         = 1,
    @LogEntityTypeCode = N'AppUser',
    @EntityId          = 201,
    @LogEventTypeCode  = N'Created',
    @LogSeverityCode   = N'Info',
    @Description       = N'Test 050: AppUser row A',
    @OldValue          = NULL,
    @NewValue          = NULL;

EXEC Audit.Audit_LogConfigChange
    @AppUserId         = 1,
    @LogEntityTypeCode = N'AppUser',
    @EntityId          = 202,
    @LogEventTypeCode  = N'Updated',
    @LogSeverityCode   = N'Info',
    @Description       = N'Test 050: AppUser row B',
    @OldValue          = NULL,
    @NewValue          = NULL;

EXEC Audit.Audit_LogConfigChange
    @AppUserId         = 1,
    @LogEntityTypeCode = N'Location',
    @EntityId          = 201,
    @LogEventTypeCode  = N'Created',
    @LogSeverityCode   = N'Info',
    @Description       = N'Test 050: Location row A',
    @OldValue          = NULL,
    @NewValue          = NULL;
GO

-- =============================================
-- Test 1: Date range covering now returns rows.
--   Use [-1h, +1h] window. Expect at least the 3 rows inserted in setup above.
-- =============================================
DECLARE @StartDate DATETIME2(3) = DATEADD(HOUR, -1, SYSUTCDATETIME());
DECLARE @EndDate   DATETIME2(3) = DATEADD(HOUR,  1, SYSUTCDATETIME());

CREATE TABLE #List1 (
    Id                BIGINT,
    LoggedAt          DATETIME2(3),
    UserId            BIGINT,
    UserDisplayName   NVARCHAR(200),
    LogEntityTypeCode NVARCHAR(50),
    LogEntityTypeName NVARCHAR(100),
    EntityId          BIGINT,
    LogEventTypeId    BIGINT,
    LogEventTypeCode  NVARCHAR(50),
    LogSeverityId     BIGINT,
    LogSeverityCode   NVARCHAR(50),
    Description       NVARCHAR(500),
    OldValue          NVARCHAR(MAX),
    NewValue          NVARCHAR(MAX),
    TotalCount        INT
);

INSERT INTO #List1
EXEC Audit.ConfigLog_List
    @StartDate         = @StartDate,
    @EndDate           = @EndDate,
    @LogEntityTypeCode = NULL,
    @AppUserId         = NULL;

-- Assert 1a: at least the 3 setup rows are present in results
DECLARE @SetupCount  INT = (
    SELECT COUNT(*)
    FROM #List1
    WHERE Description IN (
        N'Test 050: AppUser row A',
        N'Test 050: AppUser row B',
        N'Test 050: Location row A'
    )
);
DECLARE @Condition1a BIT = CASE WHEN @SetupCount >= 3 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'ConfigLog_List date range now: at least 3 setup rows returned',
    @Condition = @Condition1a;

DROP TABLE #List1;
GO

-- =============================================
-- Test 2: Historical date range returns 0 rows.
--   Window 2020-01-01 to 2020-01-02 - no MES data exists that early.
-- =============================================
DECLARE @StartDate DATETIME2(3) = CAST(N'2020-01-01T00:00:00.000' AS DATETIME2(3));
DECLARE @EndDate   DATETIME2(3) = CAST(N'2020-01-02T00:00:00.000' AS DATETIME2(3));

CREATE TABLE #List2 (
    Id                BIGINT,
    LoggedAt          DATETIME2(3),
    UserId            BIGINT,
    UserDisplayName   NVARCHAR(200),
    LogEntityTypeCode NVARCHAR(50),
    LogEntityTypeName NVARCHAR(100),
    EntityId          BIGINT,
    LogEventTypeId    BIGINT,
    LogEventTypeCode  NVARCHAR(50),
    LogSeverityId     BIGINT,
    LogSeverityCode   NVARCHAR(50),
    Description       NVARCHAR(500),
    OldValue          NVARCHAR(MAX),
    NewValue          NVARCHAR(MAX),
    TotalCount        INT
);

INSERT INTO #List2
EXEC Audit.ConfigLog_List
    @StartDate         = @StartDate,
    @EndDate           = @EndDate,
    @LogEntityTypeCode = NULL,
    @AppUserId         = NULL;

-- Assert 2a: 0 rows returned (empty result is not an error)
DECLARE @HistCount INT = (SELECT COUNT(*) FROM #List2);
EXEC test.Assert_RowCount
    @TestName      = N'ConfigLog_List historical range: 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @HistCount;

DROP TABLE #List2;
GO

-- =============================================
-- Test 3: Entity type filter - all returned rows match the filter.
--   Filter on AppUser; verify no Location rows appear in the
--   subset of setup rows that are returned.
-- =============================================
DECLARE @StartDate DATETIME2(3) = DATEADD(HOUR, -1, SYSUTCDATETIME());
DECLARE @EndDate   DATETIME2(3) = DATEADD(HOUR,  1, SYSUTCDATETIME());

CREATE TABLE #List3 (
    Id                BIGINT,
    LoggedAt          DATETIME2(3),
    UserId            BIGINT,
    UserDisplayName   NVARCHAR(200),
    LogEntityTypeCode NVARCHAR(50),
    LogEntityTypeName NVARCHAR(100),
    EntityId          BIGINT,
    LogEventTypeId    BIGINT,
    LogEventTypeCode  NVARCHAR(50),
    LogSeverityId     BIGINT,
    LogSeverityCode   NVARCHAR(50),
    Description       NVARCHAR(500),
    OldValue          NVARCHAR(MAX),
    NewValue          NVARCHAR(MAX),
    TotalCount        INT
);

INSERT INTO #List3
EXEC Audit.ConfigLog_List
    @StartDate         = @StartDate,
    @EndDate           = @EndDate,
    @LogEntityTypeCode = N'AppUser',
    @AppUserId         = NULL;

-- Assert 3a: setup AppUser rows are present in filtered result
DECLARE @AppUserCount INT = (
    SELECT COUNT(*)
    FROM #List3
    WHERE Description IN (N'Test 050: AppUser row A', N'Test 050: AppUser row B')
);
DECLARE @Condition3a BIT = CASE WHEN @AppUserCount >= 2 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'ConfigLog_List entity filter: AppUser setup rows included',
    @Condition = @Condition3a;

-- Assert 3b: Location setup row is NOT present in filtered result
DECLARE @LocationLeakCount INT = (
    SELECT COUNT(*)
    FROM #List3
    WHERE Description = N'Test 050: Location row A'
);
DECLARE @LocationLeakStr NVARCHAR(5) = CAST(@LocationLeakCount AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'ConfigLog_List entity filter: Location rows excluded',
    @Expected = N'0',
    @Actual   = @LocationLeakStr;

-- Assert 3c: every row in the result set carries the AppUser entity type name
DECLARE @NonAppUserCount INT = (
    SELECT COUNT(*)
    FROM #List3
    WHERE LogEntityTypeName <> N'Application User'
);
DECLARE @NonAppUserStr NVARCHAR(5) = CAST(@NonAppUserCount AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'ConfigLog_List entity filter: all result rows are AppUser entity type',
    @Expected = N'0',
    @Actual   = @NonAppUserStr;

DROP TABLE #List3;
GO

-- =============================================
-- Test 4: Invalid entity type filter returns 0 rows.
--   Read procs no longer return Status — invalid filters
--   simply produce empty result sets.
-- =============================================
DECLARE @StartDate DATETIME2(3) = DATEADD(HOUR, -1, SYSUTCDATETIME());
DECLARE @EndDate   DATETIME2(3) = DATEADD(HOUR,  1, SYSUTCDATETIME());

CREATE TABLE #List4 (
    Id                BIGINT,
    LoggedAt          DATETIME2(3),
    UserId            BIGINT,
    UserDisplayName   NVARCHAR(200),
    LogEntityTypeCode NVARCHAR(50),
    LogEntityTypeName NVARCHAR(100),
    EntityId          BIGINT,
    LogEventTypeId    BIGINT,
    LogEventTypeCode  NVARCHAR(50),
    LogSeverityId     BIGINT,
    LogSeverityCode   NVARCHAR(50),
    Description       NVARCHAR(500),
    OldValue          NVARCHAR(MAX),
    NewValue          NVARCHAR(MAX),
    TotalCount        INT
);

INSERT INTO #List4
EXEC Audit.ConfigLog_List
    @StartDate         = @StartDate,
    @EndDate           = @EndDate,
    @LogEntityTypeCode = N'BOGUS_ENTITY_TYPE',
    @AppUserId         = NULL;

-- Assert 4a: 0 rows returned for invalid entity type code
DECLARE @RowCount4 INT = (SELECT COUNT(*) FROM #List4);
EXEC test.Assert_RowCount
    @TestName      = N'ConfigLog_List invalid entity filter: 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @RowCount4;

DROP TABLE #List4;
GO

-- =============================================
-- Test: @DescriptionLike substring match + @LogSeverityCode filter
-- =============================================
EXEC Audit.Audit_LogConfigChange
    @AppUserId         = 1,
    @LogEntityTypeCode = N'Location',
    @EntityId          = NULL,
    @LogEventTypeCode  = N'Created',
    @LogSeverityCode   = N'Info',
    @Description       = N'Location created for SaveAll harness',
    @OldValue          = NULL,
    @NewValue          = N'{}';
EXEC Audit.Audit_LogConfigChange
    @AppUserId         = 1,
    @LogEntityTypeCode = N'Location',
    @EntityId          = NULL,
    @LogEventTypeCode  = N'Updated',
    @LogSeverityCode   = N'Warning',
    @Description       = N'Unrelated config event',
    @OldValue          = NULL,
    @NewValue          = N'{}';
GO

DECLARE @Start DATETIME2(3) = DATEADD(MINUTE, -5, SYSUTCDATETIME());
DECLARE @End   DATETIME2(3) = SYSUTCDATETIME();
CREATE TABLE #CL_Like (
    Id                BIGINT,
    LoggedAt          DATETIME2(3),
    UserId            BIGINT,
    UserDisplayName   NVARCHAR(200),
    LogEntityTypeCode NVARCHAR(50),
    LogEntityTypeName NVARCHAR(100),
    EntityId          BIGINT,
    LogEventTypeId    BIGINT,
    LogEventTypeCode  NVARCHAR(50),
    LogSeverityId     BIGINT,
    LogSeverityCode   NVARCHAR(50),
    Description       NVARCHAR(500),
    OldValue          NVARCHAR(MAX),
    NewValue          NVARCHAR(MAX),
    TotalCount        INT
);
INSERT INTO #CL_Like EXEC Audit.ConfigLog_List
    @StartDate       = @Start,
    @EndDate         = @End,
    @DescriptionLike = N'SaveAll';

DECLARE @LikeCount INT;
SELECT @LikeCount = COUNT(*) FROM #CL_Like;
DECLARE @LikeCountStr NVARCHAR(10) = CAST(@LikeCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'ConfigLog_List @DescriptionLike: only matching row returned',
    @Expected = N'1',
    @Actual   = @LikeCountStr;
DROP TABLE #CL_Like;

CREATE TABLE #CL_Sev (
    Id                BIGINT,
    LoggedAt          DATETIME2(3),
    UserId            BIGINT,
    UserDisplayName   NVARCHAR(200),
    LogEntityTypeCode NVARCHAR(50),
    LogEntityTypeName NVARCHAR(100),
    EntityId          BIGINT,
    LogEventTypeId    BIGINT,
    LogEventTypeCode  NVARCHAR(50),
    LogSeverityId     BIGINT,
    LogSeverityCode   NVARCHAR(50),
    Description       NVARCHAR(500),
    OldValue          NVARCHAR(MAX),
    NewValue          NVARCHAR(MAX),
    TotalCount        INT
);
INSERT INTO #CL_Sev EXEC Audit.ConfigLog_List
    @StartDate       = @Start,
    @EndDate         = @End,
    @LogSeverityCode = N'Warning';

DECLARE @SevCount INT;
SELECT @SevCount = COUNT(*) FROM #CL_Sev WHERE LogSeverityCode = N'Warning';
DECLARE @SevCondition BIT = CAST(IIF(@SevCount >= 1, 1, 0) AS BIT);
EXEC test.Assert_IsTrue
    @TestName  = N'ConfigLog_List @LogSeverityCode: returns at least one Warning row',
    @Condition = @SevCondition;
DROP TABLE #CL_Sev;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.EndTestFile;
GO
