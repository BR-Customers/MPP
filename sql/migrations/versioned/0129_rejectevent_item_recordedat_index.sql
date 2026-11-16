-- ============================================================
-- Migration:   0129_rejectevent_item_recordedat_index.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-16
-- Description: One partition-ALIGNED covering index so the Rejects Part Matrix
--              report's two per-part child queries (Quality.Reject_GetPartMatrixByParty
--              and Quality.Reject_GetPartMatrixDefects) seek on RejectEvent.ItemId
--              instead of scanning the whole of Workorder.RejectEvent once per part.
--
--   WHY (stored-procedure review, 2026-11-16). The "Rejects Part Matrix" report
--   (Reporting Module) runs Quality.Reject_GetPartMatrix as its root query and nests
--   both children under it, so each child runs once per part row. Both filter
--       WHERE re.ItemId = @ItemId
--         AND (@FromUtc IS NULL OR re.RecordedAt >= @FromUtc)
--         AND (@ToUtc   IS NULL OR re.RecordedAt <  @ToUtc)
--   Nothing indexes ItemId, and the optional-parameter form of the date filter stops
--   partition elimination, so every call scanned the clustered index
--   CIX_RejectEvent_LotRecordedAt across ALL partitions, whatever window the report
--   asked for. The cost of one report run was (parts in the window) x 2 x (all reject
--   history ever kept), and RejectEvent is not purged (it is not registered in
--   Audit.PartitionRetention).
--
--   KEY (ItemId, RecordedAt), INCLUDE (DefectCodeId, Quantity). Equality on ItemId,
--   then the date range on the next key column. The INCLUDEs are the only other
--   RejectEvent columns either child reads, so no row lookups. Quality.Reject_GetPartMatrix
--   (the root) reads the same four columns and also uses this index, as a narrower
--   scan than the clustered index.
--
--   PARTITION-ALIGNED: ON ps_MonthlyUtc(RecordedAt). RejectEvent is born partitioned
--   (0020); TRUNCATE ... WITH (PARTITIONS ...) and SPLIT / MERGE of pf_MonthlyUtc need
--   every index on the table aligned. A non-aligned index here would silently break the
--   sliding window. Do not change the filegroup to PRIMARY.
--
--   NOT FILTERED. ItemId is NULL only for an unmapped die-cast cavity; those rows are
--   few and harmless at the front of the index.
--
--   WRITE COST. RejectEvent is insert-only (no proc UPDATEs it), so the index is
--   maintained on inserts only: measured about 3 extra logical reads per reject row.
--   Offline build on Standard edition (reject inserts wait while it builds: about
--   0.4 s at 300k rows). No proc change, no result-set change. ASCII only.
--
--   NUMBERING. 0119 = container-as-LOT branch; 0120-0128 used or reserved by other
--   review PRs, so this is 0129. It depends only on Workorder.RejectEvent.ItemId (0084);
--   renumber if the PRs land in another order.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Workorder.RejectEvent') AND name = N'IX_RejectEvent_ItemRecordedAt')
    CREATE NONCLUSTERED INDEX IX_RejectEvent_ItemRecordedAt
        ON Workorder.RejectEvent (ItemId, RecordedAt)
        INCLUDE (DefectCodeId, Quantity)
        ON ps_MonthlyUtc(RecordedAt);   -- ALIGNED. Do not change to PRIMARY.
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0129_rejectevent_item_recordedat_index')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0129_rejectevent_item_recordedat_index',
            N'Workorder.RejectEvent += IX_RejectEvent_ItemRecordedAt (ItemId, RecordedAt) INCLUDE (DefectCodeId, Quantity), aligned ON ps_MonthlyUtc(RecordedAt), for the per-part child queries of the Rejects Part Matrix report (stored-procedure review 2026-11-16). No proc change.');
GO
