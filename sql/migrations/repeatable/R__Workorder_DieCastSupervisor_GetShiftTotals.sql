-- ============================================================
-- Repeatable:  R__Workorder_DieCastSupervisor_GetShiftTotals.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-19
-- Version:     1.0
-- Description: Backlog 3.5 (Die Cast supervisor dashboard) -- REGISTERED
--              PRODUCTION for one shift, broken down by press / die / part.
--
--              AUTHORITATIVE SOURCE. Registered die-cast production for a shift
--              is SUM(Workorder.DieCastContribution.PieceDelta) filtered on
--              DieCastContribution.ShiftId. Rationale (verified 2026-08-19):
--                * DieCastContribution is the only die-cast table that carries a
--                  ShiftId FK. It is append-only, written exactly once per
--                  (lot, recording) by Workorder.DieCastShiftOutput_Record, and
--                  PieceDelta is the operator-CONFIRMED net good count -- i.e.
--                  literally "registered production".
--                * Workorder.ProductionEvent is NOT written by any die-cast proc
--                  (DieCastLot_Open / _Release / _Void and
--                  DieCastShiftOutput_Record all insert RejectEvent rows with
--                  ProductionEventId = NULL and never create a ProductionEvent).
--                  It would report zero.
--                * Tools.Tool.ShotCount is a CUMULATIVE lifetime counter bumped
--                  by @GrossShots inside DieCastShiftOutput_Record. It has no
--                  shift attribution and no history, so a per-shift figure
--                  cannot be recovered from it. (It is also the subject of
--                  backlog 3.2 -- it does not increment on the Register Shot
--                  Loss path.)
--                * Lots.Lot.PieceCount is a materialized running total on the
--                  BASKET, not per shift; a basket that spans two shifts cannot
--                  be split by it. Lots.Lot_GetShiftCavityTally derives its
--                  numbers from PieceCount plus a time window and is therefore a
--                  LIVE MACHINE card, not a shift ledger -- do not reuse it here.
--
--              SHIFT WINDOWS ARE NEVER USED. Aggregating on the stamped ShiftId
--              FK (not on EventAt BETWEEN start AND end) is what makes this proc
--              immune to the per-equipment shift-override work (backlog 6.1):
--              changing which hours a shift covers for a press cannot re-bucket
--              production that was already registered against a shift id.
--              Resolution of "which shift is current/previous" lives entirely in
--              the sibling Workorder.DieCastSupervisor_GetShiftContext.
--
--              PRESS ATTRIBUTION. DieCastContribution stores TerminalLocationId
--              (the entry terminal), not the machine. The machine is derived:
--              contribution -> Lots.Lot.ToolId (stamped at basket creation and
--              immutable) -> the Tools.ToolAssignment that was active at the
--              contribution's EventAt -> CellLocationId. OUTER APPLY TOP 1 so a
--              die that was moved mid-shift attributes each contribution to the
--              press it was on at the time, and a die with no assignment history
--              yields CellLocationId NULL (surfaced as an "(unassigned die)"
--              bucket) rather than dropping the pieces.
--
--              SCRAP IS DELIBERATELY ABSENT (backlog 3.5 explore, 2026-08-19).
--              Workorder.RejectEvent has NO ShiftId and no
--              operation discriminator, so die-cast scrap for a shift can only
--              be guessed at by a RecordedAt time window plus a free-text
--              Remarks match -- both are wrong often enough to be worse than
--              showing nothing. Adding RejectEvent.ShiftId (stamped by
--              DieCastShiftOutput_Record / DieCastLot_Release) makes it a
--              two-line addition here.
--
--              Timestamps: stored UTC, displayed Eastern. LastEntryEt is
--              converted at this boundary and CAST back to DATETIME2(3) (a raw
--              datetimeoffset breaks the Ignition JDBC result read -- the NQ
--              logs the call but no rows= line and the bound property is empty;
--              sqlcmd hides it).
--
--              Read proc: ONE result set, no OUTPUT params, no status row, no
--              transaction, no audit. Empty result set = the shift registered no
--              die-cast production (or @ShiftId is unknown) -- NOT an error.
--
-- Parameters:
--   @ShiftId        BIGINT       - Oee.Shift.Id. Unknown id -> empty set.
--   @AreaLocationId BIGINT NULL  - Optional. When supplied, only presses that
--                                  are Location descendants of this Area are
--                                  returned; contributions whose die had no
--                                  assignment (CellLocationId NULL) are then
--                                  excluded, because they cannot be proven to
--                                  belong to the area. NULL = every press
--                                  (recommended default -- DieCastContribution
--                                  rows are by construction die-cast only).
--
-- Result set (one row per Cell x Tool x Item, ordered by press then part):
--   CellLocationId, CellCode, CellName,
--   ToolId, ToolCode, ToolName,
--   ItemId, PartNumber, ItemDescription,
--   GoodPieces, LotCount, EntryCount, LastEntryEt,
--   ShiftGoodTotal, ShiftLotTotal, ShiftPressTotal   (grand totals, identical
--                                                     on every row -- window
--                                                     functions, so the KPI
--                                                     header can bind row 0)
--
-- Dependencies:
--   Workorder.DieCastContribution, Lots.Lot, Parts.Item, Tools.Tool,
--   Tools.ToolAssignment, Location.Location
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastSupervisor_GetShiftTotals
    @ShiftId        BIGINT,
    @AreaLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @ShiftId IS NULL
    BEGIN
        -- Shaped empty result set: same columns, no rows. Keeps the Ignition
        -- binding's column contract stable on the "no shift yet" path.
        SELECT TOP 0
            CAST(NULL AS BIGINT)        AS CellLocationId,
            CAST(NULL AS NVARCHAR(50))  AS CellCode,
            CAST(NULL AS NVARCHAR(200)) AS CellName,
            CAST(NULL AS BIGINT)        AS ToolId,
            CAST(NULL AS NVARCHAR(50))  AS ToolCode,
            CAST(NULL AS NVARCHAR(100)) AS ToolName,
            CAST(NULL AS BIGINT)        AS ItemId,
            CAST(NULL AS NVARCHAR(50))  AS PartNumber,
            CAST(NULL AS NVARCHAR(500)) AS ItemDescription,
            CAST(NULL AS INT)           AS GoodPieces,
            CAST(NULL AS INT)           AS LotCount,
            CAST(NULL AS INT)           AS EntryCount,
            CAST(NULL AS DATETIME2(3))  AS LastEntryEt,
            CAST(NULL AS INT)           AS ShiftGoodTotal,
            CAST(NULL AS INT)           AS ShiftLotTotal,
            CAST(NULL AS INT)           AS ShiftPressTotal;
        RETURN;
    END

    -- Area scope (only materialized when an area filter was supplied).
    ;WITH AreaCells AS (
        SELECT l.Id
        FROM Location.Location l
        WHERE @AreaLocationId IS NOT NULL
          AND l.ParentLocationId = @AreaLocationId
          AND l.DeprecatedAt IS NULL
        UNION ALL
        SELECT c.Id
        FROM Location.Location c
        INNER JOIN AreaCells d ON c.ParentLocationId = d.Id
        WHERE c.DeprecatedAt IS NULL
    ),
    -- One row per contribution, with the press the die was mounted on AT THE
    -- MOMENT the pieces were registered.
    Contrib AS (
        SELECT
            c.Id            AS ContributionId,
            c.LotId         AS LotId,
            c.PieceDelta    AS PieceDelta,
            c.EventAt       AS EventAt,
            l.ItemId        AS ItemId,
            l.ToolId        AS ToolId,
            ta.CellLocationId AS CellLocationId
        FROM Workorder.DieCastContribution c
        INNER JOIN Lots.Lot l ON l.Id = c.LotId
        OUTER APPLY (
            SELECT TOP 1 a.CellLocationId
            FROM Tools.ToolAssignment a
            WHERE a.ToolId = l.ToolId
              AND a.AssignedAt <= c.EventAt
              AND (a.ReleasedAt IS NULL OR a.ReleasedAt > c.EventAt)
            ORDER BY a.AssignedAt DESC, a.Id DESC
        ) ta
        WHERE c.ShiftId = @ShiftId
    ),
    Scoped AS (
        SELECT x.*
        FROM Contrib x
        WHERE @AreaLocationId IS NULL
           OR x.CellLocationId IN (SELECT Id FROM AreaCells)
    ),
    -- Grand totals computed off the row-level set (NOT as window functions over
    -- Grouped): SQL Server has no COUNT(DISTINCT ...) OVER (), and counting
    -- distinct LOTs/presses per group and summing would double-count a die that
    -- moved presses mid-shift. COUNT(DISTINCT CellLocationId) ignores NULL, so
    -- the "(unassigned die)" bucket correctly does not count as a press.
    Totals AS (
        SELECT
            CAST(ISNULL(SUM(s.PieceDelta), 0)        AS INT) AS ShiftGoodTotal,
            CAST(COUNT(DISTINCT s.LotId)             AS INT) AS ShiftLotTotal,
            CAST(COUNT(DISTINCT s.CellLocationId)    AS INT) AS ShiftPressTotal
        FROM Scoped s
    ),
    Grouped AS (
        SELECT
            s.CellLocationId,
            s.ToolId,
            s.ItemId,
            CAST(SUM(s.PieceDelta) AS INT)          AS GoodPieces,
            CAST(COUNT(DISTINCT s.LotId) AS INT)    AS LotCount,
            CAST(COUNT(*) AS INT)                   AS EntryCount,
            MAX(s.EventAt)                          AS LastEntryUtc
        FROM Scoped s
        GROUP BY s.CellLocationId, s.ToolId, s.ItemId
    )
    SELECT
        g.CellLocationId,
        cl.Code                                      AS CellCode,
        cl.Name                                      AS CellName,
        g.ToolId,
        t.Code                                       AS ToolCode,
        t.Name                                       AS ToolName,
        g.ItemId,
        i.PartNumber                                 AS PartNumber,
        i.Description                                AS ItemDescription,
        g.GoodPieces,
        g.LotCount,
        g.EntryCount,
        CAST(g.LastEntryUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastEntryEt,
        tot.ShiftGoodTotal,
        tot.ShiftLotTotal,
        tot.ShiftPressTotal
    FROM Grouped g
    CROSS JOIN Totals tot
    LEFT JOIN Location.Location cl ON cl.Id = g.CellLocationId
    LEFT JOIN Tools.Tool        t  ON t.Id  = g.ToolId
    INNER JOIN Parts.Item       i  ON i.Id  = g.ItemId
    ORDER BY cl.Code, t.Code, i.PartNumber
    OPTION (MAXRECURSION 8);  -- ISA-95 depth below an Area is <= 4 in any real plant
END;
GO
