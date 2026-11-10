-- ============================================================
-- Migration:   0118_lot_open_lot_indexes.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-10
-- Description: Two filtered indexes over the NOT-CLOSED LOTs, so the plant-floor
--              queue reads find their LOTs by seek instead of scanning the
--              Lots.Lot heap.
--
--   WHY (prod incident 2026-11-10, notes/2026-11-10_prod-incident-assembly-out-
--   deadlock.md). Lots.Lot is a heap (PK_Lot is NONCLUSTERED). The Machining IN
--   read (Lots.Lot_GetTrimStorageQueueForLine) and the WIP queue read
--   (Lots.Lot_GetWipQueueByLocation) scanned the whole heap on every terminal
--   refresh, took page-level S locks, and ran in parallel. One of those scans and
--   an Assembly OUT tray close (Workorder.Assembly_CompleteTray) locked each other
--   on two heap pages; because one side was a parallel query the deadlock monitor
--   never resolved it, and the 8-connection gateway pool starved for 83 minutes.
--
--   The existing single-column indexes do not fix that on their own:
--   IX_Lot_CurrentLocationId / IX_Lot_ItemId also carry every CLOSED LOT ever
--   recorded at a cell or for a part, so a seek is followed by a lookup per closed
--   LOT and the optimiser goes back to the heap scan. IX_Lot_Active (0020) is
--   filtered to Good/Hold only, which would silently drop Scrap-status LOTs from
--   these reads (their status filter is NOT IN (Closed, Open)).
--
--   These two hold only LotStatusId <> 4. Closed is seeded with the fixed Id 4
--   (0004, IDENTITY_INSERT); a filtered-index predicate must be a literal, the
--   same reason IX_Lot_Active names (1, 2). The reads repeat that literal so the
--   optimiser can match the filter (a variable or a code-table join cannot).
--
--   Size: one row per open LOT (prod 2026-11-10: 2,400 of 41,174). Offline build
--   on Standard edition; seconds at this size. ASCII only.
-- ============================================================

-- The literal 4 below is only right while Closed is Id 4. Refuse rather than build
-- an index that silently filters the wrong status.
IF NOT EXISTS (SELECT 1 FROM Lots.LotStatusCode WHERE Id = 4 AND Code = N'Closed')
    RAISERROR(N'0118: Lots.LotStatusCode Id 4 is not Closed; the filtered indexes would be wrong.', 16, 1);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_NotClosed_Location')
    CREATE INDEX IX_Lot_NotClosed_Location
        ON Lots.Lot (CurrentLocationId)
        INCLUDE (LotStatusId, ItemId)
        WHERE LotStatusId <> 4;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_NotClosed_Item')
    CREATE INDEX IX_Lot_NotClosed_Item
        ON Lots.Lot (ItemId)
        INCLUDE (LotStatusId, CurrentLocationId)
        WHERE LotStatusId <> 4;
GO
