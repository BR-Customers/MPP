-- =============================================
-- File:         0020_PlantFloor_Foundation/090_Partition_MaintainWindow.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-09
-- Description:  Tests for Audit.Partition_MaintainWindow — OI-35 B2 monthly
--               partition sliding-window maintenance (SPLIT / TRUNCATE / MERGE).
--
--               Pre-conditions:
--                 - Migration 0020 applied (pf_MonthlyUtc / ps_MonthlyUtc,
--                   Audit.PartitionRetention, partition audit-lookup seeds)
--                 - Audit.Partition_MaintainWindow deployed
--
--               Seed partition window (migration anchor 2026-06-01):
--                 boundaries 2026-04-01 .. 2027-07-01 (16 month-firsts).
--               All @AsOfUtc values here are FIXED so the run is deterministic.
--
--               NOTE: EXEC parameters must be literals or @variables — never
--               an inline CAST/expression (T-SQL rejects it). Numeric actuals
--               are cast into NVARCHAR @vars before each assert.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/090_Partition_MaintainWindow.sql';
GO

-- =============================================
-- Test 1: SPLIT creates the boundary for the month AFTER @AsOfUtc.
--   @AsOfUtc = 2027-07-15 (M = 2027-07, the last seeded month). M+1 =
--   2027-08-01 is NOT seeded, so the proc must SPLIT it in.
--   @RetentionMonths = 240 suppresses any purge (no table is registered yet).
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(10);

CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R1
EXEC Audit.Partition_MaintainWindow @AsOfUtc = '2027-07-15', @RetentionMonths = 240;
SELECT @S = Status, @M = Message FROM #R1;
DROP TABLE #R1;

SET @SStr = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[PartSplit] Maintenance returns Status = 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @NextExists INT = (
    SELECT COUNT(*) FROM sys.partition_range_values prv
    JOIN sys.partition_functions pf ON pf.function_id = prv.function_id
    WHERE pf.name = N'pf_MonthlyUtc' AND CAST(prv.value AS DATETIME2(3)) = '2027-08-01');
DECLARE @NextStr NVARCHAR(10) = CAST(@NextExists AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[PartSplit] Boundary for M+1 (2027-08-01) exists after maintenance',
    @Expected = N'1',
    @Actual   = @NextStr;
GO

-- =============================================
-- Test 2: SPLIT is idempotent — a second call for the same month neither
--   errors nor creates a duplicate 2027-08-01 boundary.
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(10);

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R2
EXEC Audit.Partition_MaintainWindow @AsOfUtc = '2027-07-15', @RetentionMonths = 240;
SELECT @S = Status, @M = Message FROM #R2;
DROP TABLE #R2;

SET @SStr = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[PartIdempotent] Second call returns Status = 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @DupCount INT = (
    SELECT COUNT(*) FROM sys.partition_range_values prv
    JOIN sys.partition_functions pf ON pf.function_id = prv.function_id
    WHERE pf.name = N'pf_MonthlyUtc' AND CAST(prv.value AS DATETIME2(3)) = '2027-08-01');
DECLARE @DupStr NVARCHAR(10) = CAST(@DupCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[PartIdempotent] Exactly one 2027-08-01 boundary (no duplicate)',
    @Expected = N'1',
    @Actual   = @DupStr;
GO

-- =============================================
-- Test 3: TRUNCATE ages out the out-of-window partition while in-window rows
--   survive. A synthetic table is created ON ps_MonthlyUtc and loaded with
--   one out-of-window row (2026-04-15) and one in-window row (2027-06-15).
--   Registered at 3-month retention; @AsOfUtc = 2027-07-15 => cutoff
--   2027-04-01. The 2026-04 partition is emptied; the 2027-06 row survives.
-- =============================================
-- Synthetic partitioned table mirrors the born-partitioned shape. NOTE:
-- partition-level TRUNCATE requires EVERY index (incl. the PK) to be
-- partition-aligned. A bare-(Id) nonclustered PK is NON-aligned and blocks
-- TRUNCATE, so the PK is the aligned composite (Id, EventAt) on the scheme
-- plus an aligned clustered hot-path index. (Id remains globally unique via
-- IDENTITY.) See the Section B/E/F design-correction note in 0020 migration.
IF OBJECT_ID(N'Audit.PartitionTestTable', N'U') IS NOT NULL DROP TABLE Audit.PartitionTestTable;
GO
CREATE TABLE Audit.PartitionTestTable (
    Id      BIGINT       NOT NULL IDENTITY(1,1),
    EventAt DATETIME2(3) NOT NULL,
    Payload NVARCHAR(50) NULL,
    CONSTRAINT PK_PartitionTestTable PRIMARY KEY NONCLUSTERED (Id, EventAt) ON ps_MonthlyUtc(EventAt)
);
GO
CREATE CLUSTERED INDEX CIX_PartitionTestTable ON Audit.PartitionTestTable (EventAt) ON ps_MonthlyUtc(EventAt);
GO

INSERT INTO Audit.PartitionTestTable (EventAt, Payload) VALUES
    ('2026-04-15T08:00:00', N'out-of-window'),
    ('2027-06-15T08:00:00', N'in-window');

IF NOT EXISTS (SELECT 1 FROM Audit.PartitionRetention WHERE SchemaName = N'Audit' AND TableName = N'PartitionTestTable')
    INSERT INTO Audit.PartitionRetention (SchemaName, TableName, RetentionMonths, Description)
    VALUES (N'Audit', N'PartitionTestTable', 3, N'090 partition test fixture.');
GO

DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(10);
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R3
EXEC Audit.Partition_MaintainWindow @AsOfUtc = '2027-07-15';   -- NULL override => per-table class (3)
SELECT @S = Status, @M = Message FROM #R3;
DROP TABLE #R3;

SET @SStr = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[PartPurge] Maintenance returns Status = 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @OldCount INT = (SELECT COUNT(*) FROM Audit.PartitionTestTable WHERE EventAt < '2027-04-01');
DECLARE @OldStr NVARCHAR(10) = CAST(@OldCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[PartPurge] Out-of-window partition emptied (count = 0)',
    @Expected = N'0',
    @Actual   = @OldStr;

DECLARE @KeptCount INT = (SELECT COUNT(*) FROM Audit.PartitionTestTable WHERE EventAt = '2027-06-15T08:00:00');
DECLARE @KeptStr NVARCHAR(10) = CAST(@KeptCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[PartPurge] In-window row survives (count = 1)',
    @Expected = N'1',
    @Actual   = @KeptStr;
GO

-- Cleanup fixture (reset drops the DB anyway; this keeps a live DB tidy).
DELETE FROM Audit.PartitionRetention WHERE SchemaName = N'Audit' AND TableName = N'PartitionTestTable';
IF OBJECT_ID(N'Audit.PartitionTestTable', N'U') IS NOT NULL DROP TABLE Audit.PartitionTestTable;
GO

EXEC test.EndTestFile;
GO
