-- ============================================================
-- Repeatable:  R__Lots_Lot_GetOpenByTool.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-07-29
-- Version:     1.0
-- Description: Die-Cast Per-Cavity Lifecycle plan, Task 7. Read proc: ONE ROW
--              PER OPEN (status 'Open') accumulator basket LOT for @ToolId,
--              one per cavity currently holding an open basket (a cavity with
--              no open basket simply has no row -- unlike Lot_GetShiftCavityTally
--              this is NOT a per-configured-cavity report). Surfaces the
--              running PieceCount + when it was opened (ET) + how many
--              distinct operators have contributed to it this basket's life
--              (Workorder.DieCastContribution, not shift-scoped).
--
--              Columns: ToolCavityId, CavityNumber, LotId, LotName, PieceCount,
--              MaxPieceCount (basket size, from Lot.MaxPieceCount; NULL = uncapped),
--              BelowStandardRelease (BIT -- 1 when this basket holds < 95% of its
--              basket size, i.e. releasing it now is under the standard fill;
--              the 5% release tolerance is a UI-advisory policy and lives ONLY
--              here, integer-safe as PieceCount*100 < MaxPieceCount*95; NULL/0
--              max never trips it), OpenedAt (ET, from Lot.CreatedAt),
--              ContributorCount (DISTINCT AppUserId across all
--              DieCastContribution rows for the LOT).
--
--              Read proc: single result set, no status row, no OUTPUT params
--              (FDS-11-011). Empty result set = no open baskets for this tool.
--              No mutation, no transaction, no audit.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetOpenByTool
    @ToolId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        tc.Id                                          AS ToolCavityId,
        tc.CavityNumber                                AS CavityNumber,
        l.Id                                            AS LotId,
        l.LotName                                       AS LotName,
        l.PieceCount                                    AS PieceCount,
        l.MaxPieceCount                                 AS MaxPieceCount,
        CAST(CASE WHEN l.MaxPieceCount IS NOT NULL AND l.PieceCount * 100 < l.MaxPieceCount * 95
                  THEN 1 ELSE 0 END AS BIT)             AS BelowStandardRelease,
        CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedAt,
        (SELECT COUNT(DISTINCT c.AppUserId) FROM Workorder.DieCastContribution c WHERE c.LotId = l.Id) AS ContributorCount
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code = N'Open'
    INNER JOIN Tools.ToolCavity tc   ON tc.Id = l.ToolCavityId
    WHERE l.ToolId = @ToolId
    ORDER BY tc.CavityNumber;
END;
GO
