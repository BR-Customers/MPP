-- =============================================
-- File:         0109_Lot_ListByVendorLot/020_vendor_lot_index.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-16
-- Description:  Pins migration 0123's index (stored-procedure review) that lets
--               Lots.Lot_ListByVendorLot seek on VendorLotNumber instead of scanning
--               the Lots.Lot heap. The proc's behaviour is pinned by 010_matches.sql.
--               IX_Lot_VendorLotNumber is NONCLUSTERED, non-unique (a supplier lot can
--               repeat: that is what the warning reports), filtered on
--               VendorLotNumber IS NOT NULL, keyed (VendorLotNumber), with NO included
--               columns (PieceCount / LotStatusId / CurrentLocationId are rewritten
--               constantly and must stay out of this index).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0109_Lot_ListByVendorLot/020_vendor_lot_index.sql';
GO

DECLARE @IxId INT = (SELECT index_id FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_VendorLotNumber');
DECLARE @S NVARCHAR(400);

SET @S = CAST(CASE WHEN @IxId IS NULL THEN 0 ELSE 1 END AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[0123] IX_Lot_VendorLotNumber exists', @Expected = N'1', @Actual = @S;

SET @S = ISNULL((SELECT type_desc + N'/unique=' + CAST(is_unique AS NVARCHAR(1)) + N'/filtered=' + CAST(has_filter AS NVARCHAR(1))
                 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND index_id = @IxId), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0123] index is NONCLUSTERED, not unique (a supplier lot may repeat), filtered',
    @Expected = N'NONCLUSTERED/unique=0/filtered=1', @Actual = @S;

SET @S = ISNULL((SELECT filter_definition FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND index_id = @IxId), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0123] filter is exactly VendorLotNumber IS NOT NULL (an "<> NONE" filter could not serve "= @V")',
    @Expected = N'([VendorLotNumber] IS NOT NULL)', @Actual = @S;

SET @S = ISNULL((SELECT STRING_AGG(c.name + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END, N',') WITHIN GROUP (ORDER BY ic.key_ordinal)
                 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = OBJECT_ID(N'Lots.Lot') AND ic.index_id = @IxId AND ic.is_included_column = 0), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0123] key is (VendorLotNumber), the proc''s only predicate',
    @Expected = N'VendorLotNumber', @Actual = @S;

SET @S = CAST((SELECT COUNT(*) FROM sys.index_columns WHERE object_id = OBJECT_ID(N'Lots.Lot') AND index_id = @IxId AND is_included_column = 1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0123] NO included columns (PieceCount / status / location are hot writes and must stay out)',
    @Expected = N'0', @Actual = @S;

SET @S = CAST((SELECT COUNT(*) FROM dbo.SchemaVersion WHERE MigrationId = N'0123_lot_vendor_lot_index') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0123] migration recorded in dbo.SchemaVersion exactly once', @Expected = N'1', @Actual = @S;
GO

EXEC test.EndTestFile;
GO
