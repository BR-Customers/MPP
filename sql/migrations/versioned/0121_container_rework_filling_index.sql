-- ============================================================
-- Migration:   0121_container_rework_filling_index.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-13
-- Description: One filtered, covering index so the rework-waiting read
--              (Lots.ContainerRework_ListAtLocation) finds its few containers by seek instead
--              of scanning every container ever completed.
--
--   WHY (stored-procedure review, 2026-11-13). The LineInventory component re-reads
--   BlueRidge.Lots.ContainerRework.waitingCount twice every 15 seconds (two bindings, a
--   15000 ms poll), and that function calls Lots.ContainerRework_ListAtLocation, whose
--   driving predicate is
--       FROM Lots.Container c WHERE c.ContainerStatusCodeId = 7 /* ReworkFilling */
--         AND c.CurrentLocationId IN (<the line and every location under it>)
--   Lots.Container had only its primary key and two indexes, IX_Container_OpenByCell... (0028)
--   and IX_Container_OpenByCellItemStation (0078), BOTH filtered to ContainerStatusCodeId = 1
--   (Open). Nothing serves status 7, so every poll scanned the whole container table, which
--   grows with every container ever completed, to find zero or a few rows.
--
--   The index holds only ReworkFilling containers (a handful at any time), keyed by
--   CurrentLocationId, and INCLUDEs the other Lots.Container columns the proc reads, so the
--   driving read is an index-only seek. 7 is the seeded id of ReworkFilling in
--   Lots.ContainerStatusCode; the literal is repeated by the proc (a filtered-index predicate
--   must be a literal, the same reason 0118 names Closed = 4). No change to the proc or to its
--   result set. Write cost: the index is maintained only when a container enters or leaves status
--   7 (rare). Offline build on Standard edition; seconds at any realistic size. ASCII only.
--
--   NUMBERING. 0119 is claimed by the container-as-LOT branch and 0120 by the ShippingLabel banner
--   index PR, so this is 0121. It has no dependency on either of them (it needs only Lots.Container
--   from 0028 and the ContainerStatusCode seed); renumber it if the others land in a different order.
-- ============================================================

-- The literal 7 below is only right while ReworkFilling is Id 7. Refuse rather than build an
-- index that silently filters the wrong status.
IF NOT EXISTS (SELECT 1 FROM Lots.ContainerStatusCode WHERE Id = 7 AND Code = N'ReworkFilling')
    RAISERROR(N'0121: Lots.ContainerStatusCode Id 7 is not ReworkFilling; the filtered index would be wrong.', 16, 1);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Lots.Container') AND name = N'IX_Container_ReworkFilling')
    CREATE NONCLUSTERED INDEX IX_Container_ReworkFilling
        ON Lots.Container (CurrentLocationId)
        INCLUDE (ItemId, ContainerConfigId)
        WHERE ContainerStatusCodeId = 7;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0121_container_rework_filling_index')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0121_container_rework_filling_index',
            N'Lots.Container += IX_Container_ReworkFilling (filtered ContainerStatusCodeId = 7, keyed CurrentLocationId, covering) for the 15 s rework-waiting read (stored-procedure review 2026-11-13). No proc change.');
GO
