-- =============================================
-- File:         0012_Oee_Reference/030_DowntimeReasonCode_BulkLoad.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-15
-- Description:
--   Tests for Oee.DowntimeReasonCode_BulkLoadFromSeed (Phase 8).
--
--   Pre-conditions:
--     - Migrations 0001-0009 applied
--     - AppUser Id=1 exists
--     - Location seed loaded:
--         Die Cast    Id=3  Code='DIECAST'
--         Machine Shop Id=4 Code='MACHSHOP'
--         Trim Shop   Id=13 Code='TRIM'
--
--   Test fixture: 6-row JSON
--     1. DC, ReasonId=9001, TypeId=6 (Unscheduled)        -> insert as DC-9001
--     2. MS, ReasonId=9002, TypeId=5 (Setup)              -> insert as MS-9002
--     3. TS, ReasonId=9003, TypeId=NULL                   -> insert as TS-9003
--     4. DC, ReasonId=9004, TypeId=99 (invalid -> nulled) -> insert as DC-9004
--     5. DeptCode='XX' (invalid)                          -> rejected
--     6. Missing ReasonId                                 -> rejected
--
--   The 9001-9004 ReasonId range is high enough to avoid colliding
--   with any production CSV rows (CSV is 1-based and tops out well
--   below 9000).
-- =============================================

EXEC test.BeginTestFile @FileName = N'0012_Oee_Reference/030_DowntimeReasonCode_BulkLoad.sql';
GO

-- =============================================
-- Pre-cleanup: remove any leftover rows from a prior failed test run
-- =============================================
DELETE FROM Oee.DowntimeReasonCode
WHERE Code IN (N'DC-9001', N'MS-9002', N'TS-9003', N'DC-9004');
GO

-- =============================================
-- Test 1: Bulk-load happy path — 4 inserted, 0 skipped, 2 rejected
-- =============================================
DECLARE @TestJson NVARCHAR(MAX) = N'[
    {"ReasonId":9001, "ReasonDesc":"Bulk test DC unscheduled", "DeptCode":"DC", "TypeId":6, "Excused":0},
    {"ReasonId":9002, "ReasonDesc":"Bulk test MS setup",       "DeptCode":"MS", "TypeId":5, "Excused":0},
    {"ReasonId":9003, "ReasonDesc":"Bulk test TS no type",     "DeptCode":"TS",             "Excused":0},
    {"ReasonId":9004, "ReasonDesc":"Bulk test DC bad type",    "DeptCode":"DC", "TypeId":99,"Excused":0},
    {"ReasonId":9005, "ReasonDesc":"Bulk test bad dept",       "DeptCode":"XX", "TypeId":1, "Excused":0},
    {                  "ReasonDesc":"Bulk test missing reason","DeptCode":"DC", "TypeId":1, "Excused":0}
]';

DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @InsertedCount INT, @SkippedCount INT, @RejectedCount INT;
DECLARE @RejectedRowsJson NVARCHAR(MAX);

CREATE TABLE #B1 (
    Status BIT, Message NVARCHAR(500),
    InsertedCount INT, SkippedCount INT, RejectedCount INT,
    RejectedRowsJson NVARCHAR(MAX)
);
INSERT INTO #B1 EXEC Oee.DowntimeReasonCode_BulkLoadFromSeed
    @RowsJson         = @TestJson,
    @DcAreaLocationId = 3,
    @MsAreaLocationId = 4,
    @TsAreaLocationId = 13,
    @AppUserId        = 1;

SELECT @S = Status, @M = Message,
       @InsertedCount = InsertedCount,
       @SkippedCount  = SkippedCount,
       @RejectedCount = RejectedCount,
       @RejectedRowsJson = RejectedRowsJson
FROM #B1;
DROP TABLE #B1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'BulkLoad[FreshLoad]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @InsStr NVARCHAR(10) = CAST(@InsertedCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'BulkLoad[FreshLoad]: InsertedCount is 4',
    @Expected = N'4',
    @Actual   = @InsStr;

DECLARE @SkpStr NVARCHAR(10) = CAST(@SkippedCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'BulkLoad[FreshLoad]: SkippedCount is 0',
    @Expected = N'0',
    @Actual   = @SkpStr;

DECLARE @RejStr NVARCHAR(10) = CAST(@RejectedCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'BulkLoad[FreshLoad]: RejectedCount is 2',
    @Expected = N'2',
    @Actual   = @RejStr;

EXEC test.Assert_IsNotNull
    @TestName = N'BulkLoad[FreshLoad]: RejectedRowsJson is not NULL',
    @Value    = @RejectedRowsJson;
GO

-- =============================================
-- Test 2: All four expected codes exist in Oee.DowntimeReasonCode
-- =============================================
DECLARE @ExistsCount INT;
SELECT @ExistsCount = COUNT(*)
FROM Oee.DowntimeReasonCode
WHERE Code IN (N'DC-9001', N'MS-9002', N'TS-9003', N'DC-9004');
EXEC test.Assert_RowCount
    @TestName      = N'BulkLoad[FreshLoad]: all 4 generated codes exist',
    @ExpectedCount = 4,
    @ActualCount   = @ExistsCount;
GO

-- =============================================
-- Test 3: DC-9001 has DowntimeReasonTypeId = 6
-- =============================================
DECLARE @TypeId BIGINT;
SELECT @TypeId = DowntimeReasonTypeId
FROM Oee.DowntimeReasonCode WHERE Code = N'DC-9001';
DECLARE @TypeStr NVARCHAR(20) = CAST(@TypeId AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'BulkLoad: DC-9001 has DowntimeReasonTypeId=6',
    @Expected = N'6',
    @Actual   = @TypeStr;
GO

-- =============================================
-- Test 4: DC-9004 has DowntimeReasonTypeId IS NULL (invalid type was nulled out)
-- =============================================
DECLARE @TypeId BIGINT;
SELECT @TypeId = DowntimeReasonTypeId
FROM Oee.DowntimeReasonCode WHERE Code = N'DC-9004';
DECLARE @TypeStr NVARCHAR(20) = CAST(@TypeId AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'BulkLoad: DC-9004 has DowntimeReasonTypeId NULL (invalid TypeId nulled)',
    @Value    = @TypeStr;
GO

-- =============================================
-- Test 5: TS-9003 has DowntimeReasonTypeId IS NULL (input was missing)
-- =============================================
DECLARE @TypeId BIGINT;
SELECT @TypeId = DowntimeReasonTypeId
FROM Oee.DowntimeReasonCode WHERE Code = N'TS-9003';
DECLARE @TypeStr NVARCHAR(20) = CAST(@TypeId AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'BulkLoad: TS-9003 has DowntimeReasonTypeId NULL',
    @Value    = @TypeStr;
GO

-- =============================================
-- Test 6: Idempotent re-run — InsertedCount=0, SkippedCount=4, RejectedCount=2
-- =============================================
DECLARE @TestJson NVARCHAR(MAX) = N'[
    {"ReasonId":9001, "ReasonDesc":"Bulk test DC unscheduled", "DeptCode":"DC", "TypeId":6, "Excused":0},
    {"ReasonId":9002, "ReasonDesc":"Bulk test MS setup",       "DeptCode":"MS", "TypeId":5, "Excused":0},
    {"ReasonId":9003, "ReasonDesc":"Bulk test TS no type",     "DeptCode":"TS",             "Excused":0},
    {"ReasonId":9004, "ReasonDesc":"Bulk test DC bad type",    "DeptCode":"DC", "TypeId":99,"Excused":0},
    {"ReasonId":9005, "ReasonDesc":"Bulk test bad dept",       "DeptCode":"XX", "TypeId":1, "Excused":0},
    {                  "ReasonDesc":"Bulk test missing reason","DeptCode":"DC", "TypeId":1, "Excused":0}
]';

DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @InsertedCount INT, @SkippedCount INT, @RejectedCount INT;
DECLARE @RejectedRowsJson NVARCHAR(MAX);

CREATE TABLE #B2 (
    Status BIT, Message NVARCHAR(500),
    InsertedCount INT, SkippedCount INT, RejectedCount INT,
    RejectedRowsJson NVARCHAR(MAX)
);
INSERT INTO #B2 EXEC Oee.DowntimeReasonCode_BulkLoadFromSeed
    @RowsJson         = @TestJson,
    @DcAreaLocationId = 3,
    @MsAreaLocationId = 4,
    @TsAreaLocationId = 13,
    @AppUserId        = 1;

SELECT @S = Status, @M = Message,
       @InsertedCount = InsertedCount,
       @SkippedCount  = SkippedCount,
       @RejectedCount = RejectedCount,
       @RejectedRowsJson = RejectedRowsJson
FROM #B2;
DROP TABLE #B2;

DECLARE @SStr  NVARCHAR(1)  = CAST(@S AS NVARCHAR(1));
DECLARE @InsStr NVARCHAR(10) = CAST(@InsertedCount AS NVARCHAR(10));
DECLARE @SkpStr NVARCHAR(10) = CAST(@SkippedCount  AS NVARCHAR(10));
DECLARE @RejStr NVARCHAR(10) = CAST(@RejectedCount AS NVARCHAR(10));

EXEC test.Assert_IsEqual
    @TestName = N'BulkLoad[Idempotent]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'BulkLoad[Idempotent]: InsertedCount is 0 (all already existed)',
    @Expected = N'0',
    @Actual   = @InsStr;

EXEC test.Assert_IsEqual
    @TestName = N'BulkLoad[Idempotent]: SkippedCount is 4',
    @Expected = N'4',
    @Actual   = @SkpStr;

EXEC test.Assert_IsEqual
    @TestName = N'BulkLoad[Idempotent]: RejectedCount is still 2',
    @Expected = N'2',
    @Actual   = @RejStr;
GO

-- =============================================
-- Cleanup: remove the 4 test-inserted rows
-- =============================================
DELETE FROM Oee.DowntimeReasonCode
WHERE Code IN (N'DC-9001', N'MS-9002', N'TS-9003', N'DC-9004');
GO

EXEC test.EndTestFile;
GO
