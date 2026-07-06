-- ============================================================
-- Repeatable:  R__Workorder_FinishedGoods_GetProducedSummary.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-06
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

    SELECT
        l.ItemId,
        i.PartNumber,
        i.Description,
        COUNT(DISTINCT l.Id) AS LotCount,
        SUM(l.PieceCount)    AS PartCount
    FROM Lots.ContainerTray ct
    INNER JOIN Lots.Lot l   ON l.Id = ct.FinishedGoodLotId
    INNER JOIN Parts.Item i ON i.Id = l.ItemId
    WHERE (@CellLocationId IS NULL OR l.CurrentLocationId = @CellLocationId)
      AND (@ShiftStartUtc IS NULL OR l.CreatedAt >= @ShiftStartUtc)
      AND (@ShiftEndUtc   IS NULL OR l.CreatedAt <  @ShiftEndUtc)
    GROUP BY l.ItemId, i.PartNumber, i.Description
    ORDER BY i.PartNumber;
END;
GO
