-- ============================================================
-- Migration:   0128_lot_tool_not_closed_index.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-16
-- Description: One narrow filtered index for the reads that look for a die's
--              live (not Closed) LOTs, so they stop scanning the Lots.Lot heap
--              or looking up every LOT the die has ever cast.
--
--   WHY (stored-procedure review, 2026-11-16). Four reads ask "which LOTs on
--   this die are Open?" (or Open / credited this shift):
--     * Lots.Lot_GetOpenByTool                    (die-cast screen, basket list)
--     * Workorder.DieCast_GetShiftOutputBreakdown (die-cast screen, Compute)
--     * Tools.ToolAssignment_GetCellContext       (Die Mount popup, cell card)
--     * Tools.ToolAssignment_Release              (open-basket guard)
--   The only index on ToolId is IX_Lot_ToolId (ToolId) WHERE ToolId IS NOT
--   NULL, with no INCLUDE, and the status lives on the heap. A die casts about
--   9,000 baskets a year (8 cavities x ~3 a day) and almost all of them end
--   Closed, so for one die the choice is a seek plus a row lookup for every
--   basket it has ever made, or a scan of the whole heap. Measured on a year
--   of history (131k LOTs, 90k of them die-cast): the first three read
--   3,730 Lots.Lot pages (the whole heap) or 9,032 (seek + lookups) per call.
--
--   The index holds only die-cast LOTs that are not Closed (ToolId IS NOT NULL
--   AND LotStatusId <> 4): the open basket on each cavity and the released
--   (Good / Hold) baskets still in WIP -- tens of rows per die, not thousands.
--   A read uses it only when its WHERE implies LotStatusId <> 4, so the three
--   read procs gain that literal beside their code-table status test (the
--   pattern of 0118 and PRs 9, 14, 20-22). Closed is never Open, so the
--   literal changes no result.
--
--   INCLUDE (Id, LotStatusId, ToolCavityId) makes the open-basket COUNT and
--   the "which LotIds" lookup fully covered. Id is included because Lots.Lot
--   is a heap: the index's row locator is a RID, not Id, and without it the
--   optimizer preferred scanning the heap to returning Ids by lookup
--   (measured). None of the three is touched by the hot write: PieceCount is
--   rewritten on every cavity credit and is deliberately NOT here (see 0122).
--   Id, ToolId and ToolCavityId are set once at birth; LotStatusId changes a few
--   times in a LOT's life (Open -> Good on release, Hold, Closed when consumed
--   -- the row then leaves the index). So the index is written on die-cast LOT
--   insert, release, hold and close, never on a credit.
--
--   Tools.ToolAssignment_Release is a write path and is NOT changed by this
--   migration: without the literal its guard keeps its current plan. Whether
--   to add it there is left to review.
--
--   Offline build on Standard edition (writes to Lots.Lot wait while it
--   builds: about a second at 131k rows). ASCII only.
--
--   NUMBERING. 0119 is claimed by the container-as-LOT branch; 0120-0123 and
--   0127 are used and 0124-0126 are reserved by other review sessions, so this
--   is 0128. It depends only on Lots.Lot (0020); renumber if needed.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_Tool_NotClosed')
    CREATE NONCLUSTERED INDEX IX_Lot_Tool_NotClosed
        ON Lots.Lot (ToolId)
        INCLUDE (Id, LotStatusId, ToolCavityId)
        WHERE ToolId IS NOT NULL AND LotStatusId <> 4;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0128_lot_tool_not_closed_index')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0128_lot_tool_not_closed_index',
            N'Lots.Lot += IX_Lot_Tool_NotClosed (keyed ToolId, INCLUDE Id, LotStatusId, ToolCavityId, filtered ToolId NOT NULL AND LotStatusId <> 4) for the per-die open-basket reads Lot_GetOpenByTool v2.2, DieCast_GetShiftOutputBreakdown v3.3, ToolAssignment_GetCellContext v1.2 (stored-procedure review 2026-11-16).');
GO
