-- ============================================================
-- Repeatable:  R__Workorder_ProductionEvent_ListByLot.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: Arc 2 Phase 3 delta (sql-deltas spec Change 2, PE-1a). Header-only
--              checkpoint list for one LOT, chronological. Feeds the die-cast FE
--              cumulative-cavity card (latest ShotCount/ScrapCount/EventAt) and the
--              checkpoint last-shot hint.
--
--              Read proc: single result set, no status row, no OUTPUT params
--              (FDS-11-011). Empty result set = LOT has no checkpoints (no invented
--              404). No mutation, no transaction, no audit.
--
--              PE-1a: returns the ProductionEvent HEADER rows only. The shredded
--              Workorder.ProductionEventValue children, if the FE history panel ever
--              needs them, come from a separate sibling proc (one-result-set rule).
--
--              EventAt is returned as stored UTC (raw) — the FE formats. (Mirrors
--              ProductionEvent_Record's UTC storage; the audit BROWSER procs convert
--              UTC->ET, but the plant-floor checkpoint reads stay UTC. OI-36 tracks
--              an optional ET sweep — a trivial AT TIME ZONE add if MPP requests it.)
--
--              Resolved-name joins (OperationTemplate Code/Name, WeightUom Code,
--              ByUser DisplayName) so the FE renders without secondary lookups.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.ProductionEvent_ListByLot
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pe.Id,
        pe.LotId,
        pe.OperationTemplateId,
        ot.Code            AS OperationTemplateCode,
        ot.Name            AS OperationTemplateName,
        pe.WorkOrderOperationId,
        CAST(pe.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventAt,
        pe.ShotCount,
        pe.ScrapCount,
        pe.ScrapSourceId,
        pe.WeightValue,
        pe.WeightUomId,
        u.Code             AS WeightUomCode,        -- resolved UoM symbol (NULL-safe)
        pe.AppUserId,
        au.DisplayName     AS ByUser,               -- resolved actor (canonical AppUser display col)
        pe.TerminalLocationId,
        pe.Remarks
    FROM Workorder.ProductionEvent pe
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
    LEFT  JOIN Parts.Uom u                ON u.Id  = pe.WeightUomId
    LEFT  JOIN Location.AppUser au        ON au.Id = pe.AppUserId
    WHERE pe.LotId = @LotId
    ORDER BY pe.EventAt ASC, pe.Id ASC;   -- chronological; Id tiebreak for same-instant rows
END;
GO
