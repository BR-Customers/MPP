-- ============================================================
-- Repeatable:  R__Lots_Lot_GetAncestorSteps.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Per-ancestor process history for the LOT Detail traceability report.
--              Returns ONE ROW PER (ancestor path, lifecycle step): every LOT that
--              was consumed into @LotId, each repeated once per event in its own
--              lifecycle, so the report can show not just WHICH lots were involved
--              but WHAT HAPPENED to them.
--
--              READ proc (FDS-11-011): no @Status/@Message, no status row, ONE result
--              set, empty set = not found, no OUTPUT params. Timestamps converted
--              UTC->Eastern at the read boundary.
--
--              WHY THIS EXISTS RATHER THAN A NESTED REPORT QUERY
--              -------------------------------------------------
--              The original design had the report run Lots.Lot_GetLifecycle as a
--              NESTED child query, once per ancestor row, and render it as a table
--              nested inside the ancestors table. The data half of that works; the
--              LAYOUT half does not. Verified by render on 2026-08-26: a <table>
--              nested inside a <table> renders NOTHING on this gateway (confirmed on
--              two independent reports), and a column-keyed <grouping> emits a single
--              band carrying the FIRST row's value instead of one band per group.
--              Every grouping in every MPP report is dataset-level for that reason.
--              So the hierarchy is flattened HERE, in SQL, and the report draws it
--              with the one table shape that demonstrably renders.
--
--              PATH SEMANTICS -- mirrors Lots.Lot_GetGenealogyEdgeTree exactly
--              ---------------------------------------------------------------
--              The ancestor walk is a verbatim copy of that proc's Up CTE, including
--              the path-string cycle guard and OPTION(MAXRECURSION 100), so this proc
--              and the report's ancestors table can never disagree about which lots
--              are ancestors. Emission is per DISTINCT PATH, not per node: a lot
--              reachable by two paths appears under both, and its steps appear under
--              both. Consumers MUST NOT SUM PieceCount across rows -- summing
--              double-counts shared upstream edges where paths reconverge.
--
--              A lot with no logged events still appears, once, with NULL step
--              columns (LEFT JOIN) -- an ancestor that did nothing is a real answer
--              and must not silently vanish from a traceability document.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetAncestorSteps
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Up AS (
        -- Seed on the subject's direct parents, recurse up. Verbatim from
        -- Lots.Lot_GetGenealogyEdgeTree so the two can never diverge.
        SELECT g.ParentLotId AS RelatedLotId, g.RelationshipTypeId, g.PieceCount,
               1 AS Depth,
               CAST(N'/' + CAST(g.ParentLotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX)) AS Path
        FROM Lots.LotGenealogy g
        WHERE g.ChildLotId = @LotId
        UNION ALL
        SELECT g.ParentLotId, g.RelationshipTypeId, g.PieceCount, u.Depth + 1,
               CAST(u.Path + CAST(g.ParentLotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX))
        FROM Lots.LotGenealogy g
        INNER JOIN Up u ON g.ChildLotId = u.RelatedLotId
        WHERE u.Path NOT LIKE N'%/' + CAST(g.ParentLotId AS NVARCHAR(20)) + N'/%'
    )
    SELECT u.RelatedLotId,
           l.LotName        AS RelatedLotName,
           i.PartNumber     AS PartNumber,
           u.Depth          AS Depth,
           CAST(el.LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventAtEt,
           CAST(et.Name AS NVARCHAR(100)) AS EventTypeName,
           loc.Name         AS LocationName,
           au.DisplayName   AS OperatorName
    FROM Up u
    INNER JOIN Lots.Lot   l ON l.Id = u.RelatedLotId
    INNER JOIN Parts.Item i ON i.Id = l.ItemId
    LEFT  JOIN Lots.LotEventLog     el  ON el.LotId = u.RelatedLotId
    LEFT  JOIN Audit.LogEventType   et  ON et.Id    = el.LogEventTypeId
    LEFT  JOIN Location.Location    loc ON loc.Id   = COALESCE(el.LocationId, el.TerminalLocationId)
    LEFT  JOIN Location.AppUser     au  ON au.Id    = el.UserId
    ORDER BY u.Depth ASC, l.LotName ASC, el.LoggedAt ASC
    OPTION (MAXRECURSION 100);
END;
GO
