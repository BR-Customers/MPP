-- =============================================
-- File:         0111_ContainerRework/020_ReworkFillingIndex.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-13
-- Description:  Migration 0121 (stored-procedure review): the filtered, covering index behind the
--               15 s rework-waiting read, Lots.ContainerRework_ListAtLocation. Pins the definition
--               so a later edit cannot silently turn the read back into a table scan: NONCLUSTERED,
--               non-unique, filtered on ContainerStatusCodeId = 7 (ReworkFilling, the same literal
--               the proc uses), keyed on CurrentLocationId, INCLUDEs the other Lots.Container columns
--               the proc reads. Also pins that 7 really is ReworkFilling, which the literal assumes.
--               The proc's behaviour is covered by 010_rework.sql.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0111_ContainerRework/020_ReworkFillingIndex.sql';
GO

DECLARE @IxId INT = (SELECT index_id FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Container') AND name = N'IX_Container_ReworkFilling');
DECLARE @S NVARCHAR(400);

SET @S = CAST(CASE WHEN @IxId IS NULL THEN 0 ELSE 1 END AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[0121] IX_Container_ReworkFilling exists', @Expected = N'1', @Actual = @S;

SET @S = ISNULL((SELECT type_desc + N'/unique=' + CAST(is_unique AS NVARCHAR(1)) + N'/filtered=' + CAST(has_filter AS NVARCHAR(1))
                 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Container') AND index_id = @IxId), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0121] index is NONCLUSTERED, not unique, filtered', @Expected = N'NONCLUSTERED/unique=0/filtered=1', @Actual = @S;

SET @S = ISNULL((SELECT filter_definition FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Container') AND index_id = @IxId), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0121] filter is exactly ContainerStatusCodeId = 7', @Expected = N'([ContainerStatusCodeId]=(7))', @Actual = @S;

SET @S = ISNULL((SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY ic.key_ordinal)
                 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = OBJECT_ID(N'Lots.Container') AND ic.index_id = @IxId AND ic.is_included_column = 0), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0121] key column is CurrentLocationId', @Expected = N'CurrentLocationId', @Actual = @S;

SET @S = ISNULL((SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY c.name)
                 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = OBJECT_ID(N'Lots.Container') AND ic.index_id = @IxId AND ic.is_included_column = 1), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0121] index INCLUDEs ContainerConfigId and ItemId (the other Container columns the proc reads)',
    @Expected = N'ContainerConfigId,ItemId', @Actual = @S;

-- the literal 7 in the filter and in the proc must be ReworkFilling
SET @S = ISNULL((SELECT Code FROM Lots.ContainerStatusCode WHERE Id = 7), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0121] ContainerStatusCode Id 7 is ReworkFilling (the filter literal)', @Expected = N'ReworkFilling', @Actual = @S;

SET @S = CAST((SELECT COUNT(*) FROM dbo.SchemaVersion WHERE MigrationId = N'0121_container_rework_filling_index') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0121] migration recorded in dbo.SchemaVersion exactly once', @Expected = N'1', @Actual = @S;
GO

EXEC test.EndTestFile;
GO
