-- =============================================
-- File:         0025_PlantFloor_Label_Dispatch/055_ShippingLabel_FailedUnackedIndex.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-13
-- Description:  Migration 0120 (stored-procedure review): the filtered, covering index behind
--               the 5 s print-failure banner read, Lots.ShippingLabel_GetForBanner.
--               Pins the definition so a later edit cannot silently turn it back into a
--               table scan: it must be NONCLUSTERED, non-unique, filtered on
--               "failed and not yet acknowledged" (the same predicate the proc uses), keyed on
--               PrintFailedAt, and INCLUDE every column the proc selects (so the read is
--               index-only). The proc's behaviour (which labels it returns) is covered by
--               050_ShippingLabel_Lifecycle.sql, part 4.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0025_PlantFloor_Label_Dispatch/055_ShippingLabel_FailedUnackedIndex.sql';
GO

DECLARE @IxId INT = (SELECT index_id FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ShippingLabel') AND name = N'IX_ShippingLabel_FailedUnacked');
DECLARE @S NVARCHAR(400);

SET @S = CAST(CASE WHEN @IxId IS NULL THEN 0 ELSE 1 END AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[0120] IX_ShippingLabel_FailedUnacked exists', @Expected = N'1', @Actual = @S;

SET @S = ISNULL((SELECT type_desc + N'/unique=' + CAST(is_unique AS NVARCHAR(1)) + N'/filtered=' + CAST(has_filter AS NVARCHAR(1))
                 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ShippingLabel') AND index_id = @IxId), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0120] index is NONCLUSTERED, not unique, filtered', @Expected = N'NONCLUSTERED/unique=0/filtered=1', @Actual = @S;

SET @S = ISNULL((SELECT filter_definition FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ShippingLabel') AND index_id = @IxId), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0120] filter is exactly the banner predicate (failed AND not acknowledged)',
    @Expected = N'([PrintFailedAt] IS NOT NULL AND [BannerAcknowledgedAt] IS NULL)', @Actual = @S;

SET @S = ISNULL((SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY ic.key_ordinal)
                 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = OBJECT_ID(N'Lots.ShippingLabel') AND ic.index_id = @IxId AND ic.is_included_column = 0), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0120] key column is PrintFailedAt', @Expected = N'PrintFailedAt', @Actual = @S;

-- every column Lots.ShippingLabel_GetForBanner selects beyond the clustered Id
SET @S = ISNULL((SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY c.name)
                 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = OBJECT_ID(N'Lots.ShippingLabel') AND ic.index_id = @IxId AND ic.is_included_column = 1), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0120] index INCLUDEs every other column the banner proc selects (covering)',
    @Expected = N'AimShipperId,ContainerId,LastPrintError,LastPrintErrorCondition,TerminalLocationId', @Actual = @S;

-- the migration is recorded
SET @S = CAST((SELECT COUNT(*) FROM dbo.SchemaVersion WHERE MigrationId = N'0120_shippinglabel_failed_banner_index') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0120] migration recorded in dbo.SchemaVersion exactly once', @Expected = N'1', @Actual = @S;
GO

EXEC test.EndTestFile;
GO
