-- ============================================================
-- Repeatable:  R__Lots_Lot_GetOpenByTool.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-07-29
-- Version:     2.1
-- Changelog:   2.1 (2026-09-10) Cavity alpha code (0076): CavityNumber ->
--              CavityCode NVARCHAR(4), and the ordering gains the part key.
--              A 12-cavity family die cutting four parts would otherwise
--              render a,a,a,a,b,b,b,b -- four unrelated parts interleaved.
--              2.0 (2026-09-10) CAVITY-DRIVEN, the same correction v2.1 made
--              to Workorder.DieCast_GetShiftOutputBreakdown. v1.0 selected
--              FROM Lots.Lot, so a cavity with no open basket produced no row
--              -- which is why a Closed or Scrapped cavity was invisible on
--              the Lot Release screen even after 0072/v2.1 gave it a state and
--              a part everywhere else. Rows now come FROM Tools.ToolCavity
--              with the open LOT LEFT JOINed, so every non-deprecated cavity
--              of the die appears every time and a gap in the list means a
--              deprecated cavity, never "the screen decided not to show it".
--              A cavity with no open basket returns NULL LotId/LotName and 0
--              PieceCount; callers test LotId IS NULL, never row absence.
--              APPENDED LAST: CavityDescription (the cavity's operator-facing
--              NAME -- "Cavity <N>" is an ordinal and means nothing on the
--              floor), CavityStatusCode, ConfiguredItemId, ConfiguredPartNumber.
--              INSERT-EXEC consumers add four trailing columns and must expect
--              one row per cavity rather than one per open basket.
-- Description: Die-Cast Per-Cavity Lifecycle plan, Task 7. Read proc: ONE ROW
--              PER NON-DEPRECATED CAVITY of @ToolId, carrying that cavity's
--              open (status 'Open') accumulator basket when it has one.
--              Surfaces the running PieceCount + when it was opened (ET) + how
--              many distinct operators have contributed to it this basket's
--              life (Workorder.DieCastContribution, not shift-scoped).
--
--              Columns: ToolCavityId, CavityCode, LotId, LotName, PieceCount,
--              MaxPieceCount (basket size, from Lot.MaxPieceCount; NULL = uncapped),
--              BelowStandardRelease (BIT -- 1 when this basket holds < 95% of its
--              basket size, i.e. releasing it now is under the standard fill;
--              the 5% release tolerance is a UI-advisory policy and lives ONLY
--              here, integer-safe as PieceCount*100 < MaxPieceCount*95; NULL/0
--              max never trips it), OpenedAt (ET, from Lot.CreatedAt),
--              ContributorCount (DISTINCT AppUserId across all
--              DieCastContribution rows for the LOT), CavityDescription,
--              CavityStatusCode, ConfiguredItemId, ConfiguredPartNumber.
--
--              Read proc: single result set, no status row, no OUTPUT params
--              (FDS-11-011). Empty result set = the tool has no cavities.
--              No mutation, no transaction, no audit.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetOpenByTool
    @ToolId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        tc.Id                                          AS ToolCavityId,
        tc.CavityCode                                  AS CavityCode,
        l.Id                                            AS LotId,
        l.LotName                                       AS LotName,
        ISNULL(l.PieceCount, 0)                         AS PieceCount,
        l.MaxPieceCount                                 AS MaxPieceCount,
        CAST(CASE WHEN l.Id IS NOT NULL AND l.MaxPieceCount IS NOT NULL
                       AND l.PieceCount * 100 < l.MaxPieceCount * 95
                  THEN 1 ELSE 0 END AS BIT)             AS BelowStandardRelease,
        CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedAt,
        ISNULL((SELECT COUNT(DISTINCT c.AppUserId) FROM Workorder.DieCastContribution c
                WHERE c.LotId = l.Id), 0)               AS ContributorCount,
        -- APPENDED LAST (v2.0): a cavity with no basket still has a name, a
        -- state and the part it is configured to cut.
        tc.Description                                  AS CavityDescription,
        csc.Code                                        AS CavityStatusCode,
        tc.ItemId                                       AS ConfiguredItemId,
        ci.PartNumber                                   AS ConfiguredPartNumber
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode csc ON csc.Id = tc.StatusCodeId
    LEFT  JOIN (
        SELECT l2.*
        FROM Lots.Lot l2
        INNER JOIN Lots.LotStatusCode sc2 ON sc2.Id = l2.LotStatusId AND sc2.Code = N'Open'
        WHERE l2.ToolId = @ToolId
    ) l ON l.ToolCavityId = tc.Id
    LEFT  JOIN Parts.Item ci ON ci.Id = tc.ItemId
    WHERE tc.ToolId = @ToolId
      AND tc.DeprecatedAt IS NULL
    ORDER BY ci.PartNumber, tc.CavityCode;
END;
GO
