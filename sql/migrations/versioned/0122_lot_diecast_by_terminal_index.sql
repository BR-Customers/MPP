-- ============================================================
-- Migration:   0122_lot_diecast_by_terminal_index.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-13
-- Description: One narrow filtered index so the die-cast right-rail activity log
--              (Lots.Lot_GetTerminalRecentCreations) reads its newest rows by seek instead of
--              scanning the Lots.Lot heap.
--
--   WHY (stored-procedure review, 2026-11-13). The DieCastBody view re-reads
--   BlueRidge.Lots.Lot.getTerminalRecentCreations on a 20 s tick (the tick bumps the same
--   refreshToken the binding depends on), once per open die-cast terminal view. The proc is
--       SELECT TOP (@TopN) ... FROM Lots.Lot l LEFT JOIN Tools.ToolCavity tc ON tc.Id = l.ToolCavityId
--       WHERE l.CreatedAtTerminalId = @TerminalLocationId AND l.ToolId IS NOT NULL
--       ORDER BY l.CreatedAt DESC, l.Id DESC;
--   Lots.Lot is a heap (its PK is NONCLUSTERED) and nothing indexes CreatedAtTerminalId, so every
--   tick scanned the whole table, which grows with every LOT ever made, to return 15 rows.
--
--   The index holds only die-cast LOTs (ToolId IS NOT NULL: every die-cast birth stamps a ToolId),
--   keyed (CreatedAtTerminalId, CreatedAt DESC, Id DESC) in exactly the order the proc sorts, so
--   the read is a seek that stops after TOP (@TopN) rows.
--
--   DELIBERATELY NO INCLUDE COLUMNS. The proc also returns LotName, PieceCount and ToolCavityId.
--   PieceCount is rewritten on every cavity credit (the hottest write on Lots.Lot), so including
--   it would make every credit also rewrite this index. The proc returns only @TopN (15) rows, so
--   15 row lookups cost far less than that write amplification. CreatedAtTerminalId, CreatedAt and
--   Id never change after the LOT is created, so the index is maintained only on die-cast LOT
--   inserts (and deletes). No change to the proc or to its result set. Offline build on Standard
--   edition (writes to Lots.Lot wait while it builds: seconds at ~41k rows). ASCII only.
--
--   NUMBERING. 0119 is claimed by the container-as-LOT branch, 0120 by the ShippingLabel banner
--   index PR and 0121 by the container rework index PR, so this is 0122. It depends only on
--   Lots.Lot (0020) and not on any of them; renumber if they land in another order.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_DieCastByTerminal')
    CREATE NONCLUSTERED INDEX IX_Lot_DieCastByTerminal
        ON Lots.Lot (CreatedAtTerminalId, CreatedAt DESC, Id DESC)
        WHERE ToolId IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0122_lot_diecast_by_terminal_index')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0122_lot_diecast_by_terminal_index',
            N'Lots.Lot += IX_Lot_DieCastByTerminal (filtered ToolId NOT NULL, keyed CreatedAtTerminalId, CreatedAt DESC, Id DESC; no INCLUDE) for the 20 s die-cast recent-creations read (stored-procedure review 2026-11-13). No proc change.');
GO
