-- ============================================================
-- Repeatable:  R__Workorder_FinishedGoods_GetProducedSummary.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-06
-- Version:     1.3 (2026-11-04, container-as-LOT spec docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md) - LOT volume: each branch is range-bounded on its own time column (Lot.CreatedAt / ContainerTray.ClosedAt) + RECOMPILE.
-- Version:     1.2 (2026-11-04, container-as-LOT spec docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md) - Review M4: container-shape units count minted trays only, by MintedPieceCount.
-- Version:     1.1 (2026-11-04, container-as-LOT spec docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md) - D5 / D11: M&A good is also read from container-shape TRAYS (ShiftId + fixed MintedPieceCount at the station); container LOTs are never stamped.
-- Version:     1.0
-- Description: Finished-goods produced KPI (Spec 2 Task K1). A DERIVED read (no
--              materialized column). Finished-good LOTs are exactly the LOTs
--              referenced by a Lots.ContainerTray.FinishedGoodLotId (tray = LOT,
--              minted by Workorder.Assembly_CompleteTray). Rolls those LOTs up per
--              finished-good part: LotCount = COUNT(DISTINCT FG LOT),
--              PartCount = SUM(l.PieceCount). Optional filters: @CellLocationId
--              (l.CurrentLocationId) and a UTC shift window compared against the
--              stored UTC l.CreatedAt (>= start, < end). Read proc; empty rowset =
--              nothing produced in scope.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.FinishedGoods_GetProducedSummary
    @CellLocationId BIGINT       = NULL,
    @ShiftStartUtc  DATETIME2(3) = NULL,
    @ShiftEndUtc    DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- 0119: produced units in both shapes. Old: one LOT per tray (pieces = the tray
    -- LOT's PieceCount, at its CreatedAt). New: the trays of a container LOT (pieces =
    -- the tray, at its ClosedAt); LotCount counts the CONTAINER LOT once.
    ;WITH U AS (
        SELECT l.ItemId, N'L' + CAST(l.Id AS NVARCHAR(20)) AS UnitKey, l.PieceCount AS Pieces,
               l.CurrentLocationId AS LocId, l.CreatedAt AS At
        FROM Lots.Lot l
        INNER JOIN Lots.ContainerTray ct ON ct.FinishedGoodLotId = l.Id
        WHERE (@ShiftStartUtc IS NULL OR l.CreatedAt >= @ShiftStartUtc)   -- old-shape tray LOTs only: a set that stops growing at 0119
          AND (@ShiftEndUtc   IS NULL OR l.CreatedAt <  @ShiftEndUtc)
        UNION ALL
        -- minted trays only, by the fixed minted count (D11): a repack-move tray is not
        -- production, and later scrap is counted as scrap, not as less produced
        SELECT c.ItemId, N'C' + CAST(c.LotId AS NVARCHAR(20)), ct.MintedPieceCount,
               c.CurrentLocationId, ct.ClosedAt
        FROM Lots.ContainerTray ct
        INNER JOIN Lots.Container c ON c.Id = ct.ContainerId
        WHERE ct.FinishedGoodLotId IS NULL AND c.LotId IS NOT NULL AND ct.ClosedAt IS NOT NULL
          AND ct.MintedPieceCount IS NOT NULL
          AND (@ShiftStartUtc IS NULL OR ct.ClosedAt >= @ShiftStartUtc)   -- IX_ContainerTray_ClosedAt range
          AND (@ShiftEndUtc   IS NULL OR ct.ClosedAt <  @ShiftEndUtc)
    )
    SELECT
        u.ItemId,
        i.PartNumber,
        i.Description,
        COUNT(DISTINCT u.UnitKey) AS LotCount,
        SUM(u.Pieces)             AS PartCount
    FROM U u
    INNER JOIN Parts.Item i ON i.Id = u.ItemId
    WHERE (@CellLocationId IS NULL OR u.LocId = @CellLocationId)
      AND (@ShiftStartUtc IS NULL OR u.At >= @ShiftStartUtc)
      AND (@ShiftEndUtc   IS NULL OR u.At <  @ShiftEndUtc)
    GROUP BY u.ItemId, i.PartNumber, i.Description
    ORDER BY i.PartNumber
    OPTION (RECOMPILE);
END;
GO
