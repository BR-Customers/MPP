-- ============================================================
-- Repeatable:  R__Lots_Lot_GetLatestForToolCavity.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-07
-- Version:     1.0
-- Description: The reject-target resolver for the Die Cast reject panel
--              (Jacques 2026-07-06 decision: rejects record against the
--              operator-SELECTED CAVITY, not against "the last LOT created").
--              Workorder.RejectEvent requires a LotId for traceability, so the
--              cavity-scoped reject charges the most recent still-open LOT
--              cast on (tool, cavity): TOP 1 non-Closed Lot with matching
--              immutable ToolId + ToolCavityId stamps, newest first.
--
--              Closed LOTs are skipped so a fully-rejected LOT (RejectEvent
--              close-at-zero) rolls the target back to the next-latest open
--              LOT on that cavity.
--
--              READ proc: zero-or-one row, no status row, no OUTPUT params
--              (FDS-11-011). Empty result = no open LOT on that cavity.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetLatestForToolCavity
    @ToolId       BIGINT,
    @ToolCavityId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        l.Id,
        l.LotName,
        l.PieceCount,
        l.InventoryAvailable,
        tc.CavityNumber
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    INNER JOIN Tools.ToolCavity   tc ON tc.Id = l.ToolCavityId
    WHERE l.ToolId       = @ToolId
      AND l.ToolCavityId = @ToolCavityId
      AND sc.Code <> N'Closed'
    ORDER BY l.CreatedAt DESC, l.Id DESC;
END;
GO
