-- =============================================
-- File:         0129_RejectEventItemIndex/010_part_matrix_children_item_index.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-16
-- Description:  Migration 0129 (IX_RejectEvent_ItemRecordedAt) for the Rejects Part
--               Matrix child queries Quality.Reject_GetPartMatrixByParty and
--               Quality.Reject_GetPartMatrixDefects. Pins what 0069/050 does not:
--                 * the index exists with key (ItemId, RecordedAt) and INCLUDE
--                   (DefectCodeId, Quantity), and is ALIGNED to ps_MonthlyUtc on
--                   RecordedAt -- as is every other index on RejectEvent;
--                 * a partition TRUNCATE of RejectEvent still succeeds with it present
--                   (the sliding window needs every index aligned);
--                 * both children honour the ET date window at its exact edges
--                   (lower inclusive, upper exclusive) and count lot-free rows;
--                 * with no window, both children equal a plain SUM by ItemId.
--               The behaviour assertions pass with and without the index.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0129_RejectEventItemIndex/010_part_matrix_children_item_index.sql';
GO

-- ---- index definition + alignment ----
DECLARE @obj INT = OBJECT_ID(N'Workorder.RejectEvent');
DECLARE @ix INT = (SELECT index_id FROM sys.indexes WHERE object_id = @obj AND name = N'IX_RejectEvent_ItemRecordedAt');
EXEC test.Assert_IsNotNull N'[0129] IX_RejectEvent_ItemRecordedAt exists', @ix;

DECLARE @keys NVARCHAR(400) = (
    SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY ic.key_ordinal)
    FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE ic.object_id = @obj AND ic.index_id = @ix AND ic.key_ordinal > 0);
EXEC test.Assert_IsEqual N'[0129] key is (ItemId, RecordedAt)', N'ItemId,RecordedAt', @keys;

DECLARE @incl NVARCHAR(400) = (
    SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY c.name)
    FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE ic.object_id = @obj AND ic.index_id = @ix AND ic.is_included_column = 1);
EXEC test.Assert_IsEqual N'[0129] INCLUDE (DefectCodeId, Quantity)', N'DefectCodeId,Quantity', @incl;

DECLARE @ds NVARCHAR(128) = (SELECT ds.name FROM sys.indexes i JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
                             WHERE i.object_id = @obj AND i.index_id = @ix);
EXEC test.Assert_IsEqual N'[0129] index is on partition scheme ps_MonthlyUtc (aligned)', N'ps_MonthlyUtc', @ds;

DECLARE @pcol NVARCHAR(128) = (SELECT c.name FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                               WHERE ic.object_id = @obj AND ic.index_id = @ix AND ic.partition_ordinal = 1);
EXEC test.Assert_IsEqual N'[0129] index partitioning column is RecordedAt', N'RecordedAt', @pcol;

DECLARE @unaligned NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM sys.indexes i
    LEFT JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
    WHERE i.object_id = @obj AND ISNULL(ds.name, N'') <> N'ps_MonthlyUtc');
EXEC test.Assert_IsEqual N'[0129] every index on RejectEvent is aligned to ps_MonthlyUtc', N'0', @unaligned;
GO

-- ---- partition TRUNCATE still works with the index present ----
-- A row in a far-future partition, truncated inside a transaction that is rolled
-- back, then removed by Id. TRUNCATE ... WITH (PARTITIONS) raises Msg 3756 if any
-- index on the table is not aligned (verified with a deliberately unaligned index).
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Dc   BIGINT = (SELECT MIN(Id) FROM Quality.DefectCode);
DECLARE @At   DATETIME2(3) = '2030-01-15T12:00:00';
INSERT INTO Workorder.RejectEvent (LotId, ItemId, DefectCodeId, Quantity, Remarks, AppUserId, RecordedAt)
VALUES (NULL, @Item, @Dc, 1, N'T0129-TRUNC', 1, @At);
DECLARE @RowId BIGINT = SCOPE_IDENTITY();
DECLARE @p INT = $PARTITION.pf_MonthlyUtc(@At);
DECLARE @sql NVARCHAR(400) = N'TRUNCATE TABLE Workorder.RejectEvent WITH (PARTITIONS (' + CAST(@p AS NVARCHAR(10)) + N'));';
DECLARE @err NVARCHAR(2000) = NULL, @left INT = NULL;
BEGIN TRY
    BEGIN TRANSACTION;
    EXEC sys.sp_executesql @sql;
    SET @left = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE $PARTITION.pf_MonthlyUtc(RecordedAt) = @p);
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
END CATCH
EXEC test.Assert_IsNull N'[0129] partition TRUNCATE of RejectEvent succeeds with the index present', @err;
EXEC test.Assert_IsEqual N'[0129] the truncated partition was emptied', N'0', @left;
DELETE FROM Workorder.RejectEvent WHERE Id = @RowId;
GO

-- ---- children: window edges + lot-free rows ----
-- Window 2026-05-10 .. 2026-05-12 ET = [2026-05-10 04:00, 2026-05-13 04:00) UTC (EDT).
DECLARE @OcDieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
DECLARE @Dc    BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'001' AND OperationCategoryId = @OcDieCast);
DECLARE @Item  BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id DESC);
DECLARE @Other BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id <> @Item ORDER BY Id DESC);
INSERT INTO Workorder.RejectEvent (LotId, ItemId, DefectCodeId, Quantity, Remarks, AppUserId, RecordedAt)
VALUES (NULL, @Item,  @Dc,   3, N'T0129', 1, '2026-05-10T04:00:00.000'),   -- lower edge: IN
       (NULL, @Item,  @Dc,   4, N'T0129', 1, '2026-05-13T03:59:59.999'),   -- just inside the upper edge: IN
       (NULL, @Item,  @Dc,  50, N'T0129', 1, '2026-05-10T03:59:59.999'),   -- just before: OUT
       (NULL, @Item,  @Dc,  70, N'T0129', 1, '2026-05-13T04:00:00.000'),   -- upper edge: OUT
       (NULL, @Other, @Dc, 100, N'T0129', 1, '2026-05-11T12:00:00.000');   -- other part: OUT

DECLARE @B TABLE (ChargeToPartyCode NVARCHAR(50), ChargeToPartyName NVARCHAR(100),
                  GoodPieces BIGINT, RejectPieces BIGINT, RejectPercent DECIMAL(9,2));
DECLARE @D TABLE (DefectCode NVARCHAR(20), DefectDescription NVARCHAR(500),
                  ChargeToPartyCode NVARCHAR(50), ChargeToPartyName NVARCHAR(100),
                  IsNonRejectScrap BIT, Quantity BIGINT);
DECLARE @n NVARCHAR(20);

INSERT INTO @D EXEC Quality.Reject_GetPartMatrixDefects @ItemId = @Item, @FromEt = '2026-05-10', @ToEt = '2026-05-12';
SET @n = (SELECT CAST(SUM(Quantity) AS NVARCHAR(20)) FROM @D);
EXEC test.Assert_IsEqual N'[0129] Defects child: window edges + lot-free rows (3 + 4)', N'7', @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(20)) FROM @D);
EXEC test.Assert_IsEqual N'[0129] Defects child: one row for the one defect code', N'1', @n;

INSERT INTO @B EXEC Quality.Reject_GetPartMatrixByParty @ItemId = @Item, @FromEt = '2026-05-10', @ToEt = '2026-05-12';
SET @n = (SELECT CAST(RejectPieces AS NVARCHAR(20)) FROM @B WHERE ChargeToPartyCode = N'DieCast');
EXEC test.Assert_IsEqual N'[0129] ByParty child: window edges + lot-free rows (3 + 4)', N'7', @n;
SET @n = (SELECT CAST(SUM(RejectPieces) AS NVARCHAR(20)) FROM @B);
EXEC test.Assert_IsEqual N'[0129] ByParty child: nothing charged elsewhere', N'7', @n;

-- No window: both children equal a plain SUM by ItemId over the whole table.
DECLARE @expAll NVARCHAR(20) = (SELECT CAST(SUM(CAST(Quantity AS BIGINT)) AS NVARCHAR(20)) FROM Workorder.RejectEvent WHERE ItemId = @Item);
DECLARE @expRej NVARCHAR(20) = (SELECT CAST(ISNULL(SUM(CAST(re.Quantity AS BIGINT)), 0) AS NVARCHAR(20))
                                FROM Workorder.RejectEvent re JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId
                                WHERE re.ItemId = @Item AND dc.IsNonRejectScrap = 0);
DELETE FROM @D; DELETE FROM @B;
INSERT INTO @D EXEC Quality.Reject_GetPartMatrixDefects @ItemId = @Item;
SET @n = (SELECT CAST(SUM(Quantity) AS NVARCHAR(20)) FROM @D);
EXEC test.Assert_IsEqual N'[0129] Defects child, no window = SUM by ItemId', @expAll, @n;
INSERT INTO @B EXEC Quality.Reject_GetPartMatrixByParty @ItemId = @Item;
SET @n = (SELECT CAST(SUM(RejectPieces) AS NVARCHAR(20)) FROM @B);
EXEC test.Assert_IsEqual N'[0129] ByParty child, no window = SUM of reject (not non-reject scrap) by ItemId', @expRej, @n;

DELETE FROM Workorder.RejectEvent WHERE Remarks = N'T0129';
GO

EXEC test.EndTestFile;
GO
