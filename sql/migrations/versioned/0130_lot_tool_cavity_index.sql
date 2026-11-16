-- ============================================================
-- Migration:   0130_lot_tool_cavity_index.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-16
-- Description: One narrow filtered index so the reads that ask "does this
--              cavity have an Open basket?" stop scanning the Lots.Lot heap.
--
--   WHY (stored-procedure review, 2026-11-16). Four procs look up a die-cast
--   LOT by ToolCavityId and a code-table status test (sc.Code = N'Open' or
--   <> N'Closed'):
--     * Lots.DieCastLot_Open              one-open-per-(tool, cavity) guard,
--                                         run every time an operator opens a
--                                         basket on the die-cast screen
--     * Workorder.DieCastScrap_Write      die-wide shot loss: OUTER APPLY per
--                                         active cavity, inside the caller's
--                                         transaction (DieCastShiftOutput_Record
--                                         with a shot-loss quantity; the
--                                         other callers pass only LotIds)
--     * Tools.ToolCavity_Deprecate        open-basket guard (admin, rare)
--     * Lots.Lot_GetLatestForToolCavity   (no UI caller today)
--   No index has ToolCavityId as a key. IX_Lot_ToolId (ToolId) has no INCLUDE
--   and a die casts ~9,000 baskets a year, so the optimizer scans the whole
--   heap instead. IX_Lot_Tool_NotClosed (0128) does not help: it needs the
--   literal LotStatusId <> 4 in the WHERE, and these procs (three of them write
--   paths) test the status by code. Measured on a year of history (131k LOTs,
--   90k die-cast, 10 dies x 8 cavities): every call read 3,723 Lots.Lot pages
--   (~11 ms); the die-wide scrap write read 29,800 (one heap pass per cavity,
--   ~300 ms) while its caller holds its transaction open.
--
--   Keyed (ToolCavityId, LotStatusId) so "the Open basket on this cavity" is a
--   two-column seek (LotStatusCode resolves Open -> Id first): 3 pages. INCLUDE
--   (Id, ToolId): Id because Lots.Lot is a heap and the row locator is a RID,
--   not Id (DieCastScrap_Write returns l.Id); ToolId for DieCastLot_Open's
--   l.ToolId = @ToolId. Not filtered on status (the procs carry no literal);
--   filtered on ToolCavityId IS NOT NULL so only die-cast LOTs are in it.
--
--   WRITE COST. All four columns are set at birth; only LotStatusId changes
--   (Open -> Good on release, Hold, Closed). So the index is written on die-cast
--   LOT insert, release, hold and close -- never on a cavity credit:
--   PieceCount is rewritten on every credit and is deliberately NOT here (see
--   0122, 0128). Measured: credit 3 reads with and without; release / close
--   +12 reads; no measurable time difference (all under 0.1 ms).
--
--   ONE READ GETS SLOWER: Lots.Lot_GetShiftCavityTally (19 ms -> 29 ms on the
--   test history) switches from a heap scan to a seek plus row lookups. It has
--   no UI caller today (only BlueRidge.Lots.Lot helpers no view uses).
--
--   Offline build on Standard edition (writes to Lots.Lot wait while it
--   builds: well under a second at 131k rows). ASCII only.
--
--   NUMBERING. 0119 is claimed by the container-as-LOT branch and 0120-0129
--   are used or claimed by other review sessions. It depends only on Lots.Lot
--   (0020); renumber if needed.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_ToolCavity_Status')
    CREATE NONCLUSTERED INDEX IX_Lot_ToolCavity_Status
        ON Lots.Lot (ToolCavityId, LotStatusId)
        INCLUDE (Id, ToolId)
        WHERE ToolCavityId IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0130_lot_tool_cavity_index')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0130_lot_tool_cavity_index',
            N'Lots.Lot += IX_Lot_ToolCavity_Status (keyed ToolCavityId, LotStatusId, INCLUDE Id, ToolId, filtered ToolCavityId NOT NULL) for the per-cavity open-basket reads in DieCastLot_Open, DieCastScrap_Write, ToolCavity_Deprecate, Lot_GetLatestForToolCavity (stored-procedure review 2026-11-16).');
GO
