-- ============================================================
-- Repeatable:  R__Lots_Lot_GetScrapSummary.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-06
-- Version:     1.0
-- Description: LOT Detail "Total Scrap" card read (Jacques 2026-07-06).
--              One row, three columns, for @LotId:
--                RejectedTotal INT - SUM(Workorder.RejectEvent.Quantity), the
--                                    per-event reject records (die cast rejects).
--                CounterScrap  INT - MAX(Workorder.ProductionEvent.ScrapCount),
--                                    the cumulative checkpoint scrap counter's
--                                    high-water (D1 counters are cumulative, so
--                                    MAX = latest; SUM would double-count).
--                TotalScrap    INT - RejectedTotal + CounterScrap. The two
--                                    channels are disjoint today (rejects are
--                                    event rows; trim/die-cast checkpoints carry
--                                    the counter), so adding them is the LOT's
--                                    best-available total scrap.
--
--              READ proc: single one-row result set, no status row, no OUTPUT
--              params (FDS-11-011). Always returns a row (zeros when no scrap).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetScrapSummary
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RejectedTotal INT = ISNULL((
        SELECT SUM(re.Quantity) FROM Workorder.RejectEvent re WHERE re.LotId = @LotId), 0);

    DECLARE @CounterScrap INT = ISNULL((
        SELECT MAX(pe.ScrapCount) FROM Workorder.ProductionEvent pe WHERE pe.LotId = @LotId), 0);

    SELECT
        @RejectedTotal                  AS RejectedTotal,
        @CounterScrap                   AS CounterScrap,
        @RejectedTotal + @CounterScrap  AS TotalScrap;
END;
GO
