-- ============================================================
-- Repeatable:  R__Quality_Crt_GetRequiredInspections.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-10
-- Version:     1.0
-- Description: Arc 2 Phase 9 (FDS-10-012, 200% inspection surface). For a
--              location, returns the CRT-active, non-Closed LOTs whose
--              CurrentLocationId is AT or UNDER @LocationId (descendant walk
--              mirrors Lot_GetWipQueueByLocation's Descendants CTE), with the
--              inspection tallies the 200%-prompt view needs: SampleCount,
--              LastSampledAt (ET-converted) and the latest overall result code.
--
--              CRT enforcement is SURFACED, not proc-gated, in v1 (recon spec
--              delta 3): production procs do not consume this read; the view
--              renders the prompt off it.
--
--              READ proc: no status row, no OUTPUT params (FDS-11-011).
--              Empty result set = no CRT-active LOTs in scope.
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.Crt_GetRequiredInspections
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Descendants AS (
        SELECT @LocationId AS Id
        UNION ALL
        SELECT c.Id
        FROM Location.Location c
        INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    )
    SELECT
        l.Id            AS LotId,
        l.LotName,
        i.PartNumber    AS ItemPartNumber,
        l.PieceCount,
        ISNULL(t.SampleCount, 0) AS SampleCount,
        CAST(t.LastSampledAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastSampledAt,
        lr.Code         AS LastResultCode
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item         i  ON i.Id  = l.ItemId
    OUTER APPLY (
        SELECT COUNT(*) AS SampleCount, MAX(qs.SampledAt) AS LastSampledAt
        FROM Quality.QualitySample qs
        WHERE qs.LotId = l.Id
    ) t
    OUTER APPLY (
        SELECT TOP 1 ir.Code
        FROM Quality.QualitySample qs2
        INNER JOIN Quality.InspectionResultCode ir ON ir.Id = qs2.InspectionResultCodeId
        WHERE qs2.LotId = l.Id
        ORDER BY qs2.SampledAt DESC, qs2.Id DESC
    ) lr
    WHERE l.CrtActive = 1
      AND sc.Code <> N'Closed'
      AND l.CurrentLocationId IN (SELECT Id FROM Descendants)
    ORDER BY t.LastSampledAt ASC, l.Id ASC   -- never-sampled (NULL) first = most overdue
    OPTION (MAXRECURSION 8);
END;
GO
