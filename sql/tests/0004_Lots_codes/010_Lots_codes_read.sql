-- =============================================
-- File:         0004_Lots_codes/010_Lots_codes_read.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Rewritten:    2026-04-14 (Ignition JDBC refactor)
-- Description:
--   Tests for Lots schema reference code tables (Phase 3 read-only).
--   Covers 6 tables, each with _List and _Get procs:
--     - Lots.LotOriginType              (3 seeded rows)
--     - Lots.LotStatusCode              (5 seeded rows incl. Open, +BlocksProduction flag)
--     - Lots.ContainerStatusCode        (5 seeded rows)
--     - Lots.GenealogyRelationshipType  (3 seeded rows)
--     - Lots.PrintReasonCode            (5 seeded rows)
--     - Lots.LabelTypeCode              (4 seeded rows)
--
--   For each table:
--     - _List returns the expected seeded row count (via INSERT-EXEC)
--     - _Get(<valid Id>) returns 1 row
--
--   LotStatusCode additionally asserts BlocksProduction flag values:
--     Good=0, Hold=1, Scrap=1, Closed=0.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0004_Lots_codes/010_Lots_codes_read.sql';
GO

-- =============================================
-- == LotOriginType ===========================================
-- =============================================

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Lots.LotOriginType_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'LotOriginType_List: 3 rows returned by proc',
    @ExpectedCount = 3,
    @ActualCount   = @Count;
GO

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Lots.LotOriginType_Get @Id = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'LotOriginType_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;
GO


-- =============================================
-- == LotStatusCode ===========================================
-- =============================================

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), BlocksProduction BIT);
INSERT INTO #R EXEC Lots.LotStatusCode_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'LotStatusCode_List: 5 rows returned by proc',
    @ExpectedCount = 5,
    @ActualCount   = @Count;
GO

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), BlocksProduction BIT);
INSERT INTO #R EXEC Lots.LotStatusCode_Get @Id = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'LotStatusCode_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;
GO

-- LotStatusCode.BlocksProduction flag values: Good=0, Hold=1, Scrap=1, Closed=0
DECLARE @BpGood    BIT;
DECLARE @BpHold    BIT;
DECLARE @BpScrap   BIT;
DECLARE @BpClosed  BIT;

SELECT @BpGood   = BlocksProduction FROM Lots.LotStatusCode WHERE Code = N'Good';
SELECT @BpHold   = BlocksProduction FROM Lots.LotStatusCode WHERE Code = N'Hold';
SELECT @BpScrap  = BlocksProduction FROM Lots.LotStatusCode WHERE Code = N'Scrap';
SELECT @BpClosed = BlocksProduction FROM Lots.LotStatusCode WHERE Code = N'Closed';

DECLARE @BpGoodStr   NVARCHAR(1) = CAST(@BpGood   AS NVARCHAR(1));
DECLARE @BpHoldStr   NVARCHAR(1) = CAST(@BpHold   AS NVARCHAR(1));
DECLARE @BpScrapStr  NVARCHAR(1) = CAST(@BpScrap  AS NVARCHAR(1));
DECLARE @BpClosedStr NVARCHAR(1) = CAST(@BpClosed AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'LotStatusCode.BlocksProduction: Good is 0',
    @Expected = N'0',
    @Actual   = @BpGoodStr;

EXEC test.Assert_IsEqual
    @TestName = N'LotStatusCode.BlocksProduction: Hold is 1',
    @Expected = N'1',
    @Actual   = @BpHoldStr;

EXEC test.Assert_IsEqual
    @TestName = N'LotStatusCode.BlocksProduction: Scrap is 1',
    @Expected = N'1',
    @Actual   = @BpScrapStr;

EXEC test.Assert_IsEqual
    @TestName = N'LotStatusCode.BlocksProduction: Closed is 0',
    @Expected = N'0',
    @Actual   = @BpClosedStr;
GO


-- =============================================
-- == ContainerStatusCode =====================================
-- =============================================

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Lots.ContainerStatusCode_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'ContainerStatusCode_List: 5 rows returned by proc',
    @ExpectedCount = 5,
    @ActualCount   = @Count;
GO

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Lots.ContainerStatusCode_Get @Id = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'ContainerStatusCode_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;
GO


-- =============================================
-- == GenealogyRelationshipType ===============================
-- =============================================

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Lots.GenealogyRelationshipType_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'GenealogyRelationshipType_List: 3 rows returned by proc',
    @ExpectedCount = 3,
    @ActualCount   = @Count;
GO

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Lots.GenealogyRelationshipType_Get @Id = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'GenealogyRelationshipType_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;
GO


-- =============================================
-- == PrintReasonCode =========================================
-- =============================================

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Lots.PrintReasonCode_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'PrintReasonCode_List: 5 rows returned by proc',
    @ExpectedCount = 5,
    @ActualCount   = @Count;
GO

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Lots.PrintReasonCode_Get @Id = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'PrintReasonCode_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;
GO


-- =============================================
-- == LabelTypeCode ===========================================
-- =============================================

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Lots.LabelTypeCode_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'LabelTypeCode_List: 4 rows returned by proc',
    @ExpectedCount = 4,
    @ActualCount   = @Count;
GO

DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #R EXEC Lots.LabelTypeCode_Get @Id = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'LabelTypeCode_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;
GO


-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
