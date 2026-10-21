-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_PreviewSelection.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.0
-- Description: READ. The candidate list for a super-lot, before anything is
--              written. Union of: the suspect (anchor) LOT; LOTs of a part
--              minted at/under a line inside a time window; and every
--              genealogy descendant of the anchor. Candidates are folded and
--              judged by Quality.ufn_ControlledRunResolveMembers, so a row
--              shown Eligible here is exactly what ControlledRun_Open accepts.
--
--              The by-production arm needs a part AND a start time (explicit,
--              or the anchor's CreatedAt) -- a part alone would be everything.
--              "Made at a line" means where the LOT was MINTED
--              (Lot.CreatedAtTerminalId at or under @LocationId), not where it
--              is now. A LOT with no CreatedAtTerminalId is therefore invisible
--              to the line filter; it is still found by genealogy or by hand.
--
--              @FromAtEastern / @ToAtEastern are WALL-CLOCK EASTERN and are
--              converted here; ProducedAt is returned Eastern. Ineligible rows
--              are returned, not hidden. No status row, no OUTPUT params
--              (FDS-11-011). Empty set = nothing matched.
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_PreviewSelection
    @AnchorLotId        BIGINT       = NULL,
    @ItemId             BIGINT       = NULL,
    @LocationId         BIGINT       = NULL,
    @FromAtEastern      DATETIME2(3) = NULL,
    @ToAtEastern        DATETIME2(3) = NULL,
    @IncludeDescendants BIT          = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FromUtc DATETIME2(3) = CAST(@FromAtEastern AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    DECLARE @ToUtc   DATETIME2(3) = CAST(@ToAtEastern   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    IF @FromUtc IS NULL AND @AnchorLotId IS NOT NULL
        SET @FromUtc = (SELECT CreatedAt FROM Lots.Lot WHERE Id = @AnchorLotId);
    IF @ToUtc IS NULL SET @ToUtc = SYSUTCDATETIME();

    DECLARE @Cand TABLE (LotId BIGINT NOT NULL PRIMARY KEY, FoundRank INT NOT NULL);

    -- 1. the anchor itself
    IF @AnchorLotId IS NOT NULL AND EXISTS (SELECT 1 FROM Lots.Lot WHERE Id = @AnchorLotId)
        INSERT INTO @Cand (LotId, FoundRank) VALUES (@AnchorLotId, 1);

    -- 2. by production: part + (line) + window. Needs a part AND a start, or it is "everything".
    IF @ItemId IS NOT NULL AND @FromUtc IS NOT NULL
    BEGIN
        ;WITH Descendants AS (
            SELECT @LocationId AS Id WHERE @LocationId IS NOT NULL
            UNION ALL
            SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
        )
        INSERT INTO @Cand (LotId, FoundRank)
        SELECT l.Id, 2
        FROM Lots.Lot l
        WHERE l.ItemId = @ItemId
          AND l.CreatedAt >= @FromUtc AND l.CreatedAt <= @ToUtc
          AND (@LocationId IS NULL OR l.CreatedAtTerminalId IN (SELECT Id FROM Descendants))
          AND NOT EXISTS (SELECT 1 FROM @Cand x WHERE x.LotId = l.Id)
        OPTION (MAXRECURSION 8);
    END

    -- 3. by genealogy: everything made from the anchor
    IF @IncludeDescendants = 1 AND @AnchorLotId IS NOT NULL
        INSERT INTO @Cand (LotId, FoundRank)
        SELECT gc.DescendantLotId, 3
        FROM Lots.LotGenealogyClosure gc
        WHERE gc.AncestorLotId = @AnchorLotId AND gc.Depth > 0
          AND NOT EXISTS (SELECT 1 FROM @Cand x WHERE x.LotId = gc.DescendantLotId);

    DECLARE @Json NVARCHAR(MAX) = (SELECT LotId AS lotId FROM @Cand FOR JSON PATH);

    SELECT
        r.Kind, r.LotId, r.ContainerId, r.DisplayName,
        i.PartNumber,
        loc.Name AS CurrentLocationName,
        r.StatusCode, r.PieceCount,
        CAST(r.ProducedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ProducedAt,
        r.CrtActive,
        CASE fr.FoundRank WHEN 1 THEN N'Suspect LOT' WHEN 2 THEN N'Line + time' ELSE N'Made from suspect LOT' END AS FoundBy,
        CONVERT(BIT, CASE WHEN r.IneligibleReason IS NULL THEN 1 ELSE 0 END) AS Eligible,
        r.IneligibleReason
    FROM Quality.ufn_ControlledRunResolveMembers(@Json) r
    LEFT JOIN Parts.Item i          ON i.Id = r.ItemId
    LEFT JOIN Location.Location loc ON loc.Id = r.CurrentLocationId
    OUTER APPLY (
        -- a LOT keeps its own rank; a container takes the best rank of its tray LOTs
        SELECT MIN(c.FoundRank) AS FoundRank
        FROM @Cand c
        WHERE (r.ContainerId IS NULL AND c.LotId = r.LotId)
           OR (r.ContainerId IS NOT NULL AND c.LotId IN (SELECT t.FinishedGoodLotId FROM Lots.ContainerTray t WHERE t.ContainerId = r.ContainerId))
    ) fr
    ORDER BY r.ProducedAt ASC, r.ContainerId ASC, r.LotId ASC;
END;
GO
