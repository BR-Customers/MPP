-- =============================================
-- File:         0005_Quality_codes/010_Quality_codes_read.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Rewritten:    2026-04-14 (Ignition JDBC refactor)
-- Description:
--   Tests for Quality schema reference code tables (Phase 3 read-only).
--   Covers 4 tables, each with _List and _Get procs:
--     - Quality.InspectionResultCode  (3 seeded rows)
--     - Quality.SampleTriggerCode     (9 seeded rows: 4 from 0004 + 5 FDS-08-014 triggers from 0037)
--     - Quality.HoldTypeCode          (3 seeded rows)
--     - Quality.DispositionCode       (4 seeded rows)
--
--   For each table:
--     - _List returns the expected seeded row count (via INSERT-EXEC)
--     - _Get(<valid Id>) returns 1 row
-- =============================================

EXEC test.BeginTestFile @FileName = N'0005_Quality_codes/010_Quality_codes_read.sql';
GO

-- =============================================
-- == InspectionResultCode ====================================
-- =============================================

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Quality.InspectionResultCode_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'InspectionResultCode_List: 3 rows returned by proc',
    @ExpectedCount = 3,
    @ActualCount   = @Count;
GO

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Quality.InspectionResultCode_Get @Id = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'InspectionResultCode_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;
GO


-- =============================================
-- == SampleTriggerCode =======================================
-- =============================================

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Quality.SampleTriggerCode_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'SampleTriggerCode_List: 9 rows returned by proc (4 from 0004 + 5 from 0037)',
    @ExpectedCount = 9,
    @ActualCount   = @Count;
GO

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Quality.SampleTriggerCode_Get @Id = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'SampleTriggerCode_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;
GO


-- =============================================
-- == HoldTypeCode ============================================
-- =============================================

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Quality.HoldTypeCode_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'HoldTypeCode_List: 4 rows returned by proc',
    @ExpectedCount = 4,
    @ActualCount   = @Count;
GO

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Quality.HoldTypeCode_Get @Id = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'HoldTypeCode_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;
GO


-- =============================================
-- == DispositionCode =========================================
-- =============================================

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Quality.DispositionCode_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'DispositionCode_List: 4 rows returned by proc',
    @ExpectedCount = 4,
    @ActualCount   = @Count;
GO

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Quality.DispositionCode_Get @Id = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'DispositionCode_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;
GO


-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
