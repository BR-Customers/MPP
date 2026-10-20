-- =============================================
-- Procedure:   Workorder.ScaleStation_GetPressLog
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Version:     1.1
--
-- Description:
--   Every press at a By Weight scale station, newest first, for the screen's
--   press log and last-press card (spec 2026-10-19 scale station, sec. 7).
--
--   Source: Audit.InterfaceLog, one row per press (the EPrint watcher writes
--   LocationId + a JSON RequestPayload, migration 0113). A good close is
--   joined to production records through LotId: the tray it closed, the box,
--   and that box's shipping label. A refused press exists only here.
--
--   Rows skipped: anything not a PLC row, a payload that is not JSON or has
--   no "v" (written before 0113), and the 'Scale flags warning' rows (the
--   press row already carries the flags and the agreement). JSON is only read
--   through a CASE on ISJSON, so a text payload can never raise an error.
--
--   Outcome: Closed (a LOT was minted), Refused (the verdict was not Ok, or
--   the press never reached a verdict), Failed (Ok, but the close failed).
--
--   Read proc, one result set, no OUTPUT params (FDS-11-011). Times Eastern.
--
-- Parameters:
--   @TerminalLocationId BIGINT - Required.
--   @Top                INT    - Rows to return (default 20).
--
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
--   2026-10-20 - 1.1 - Last 30 days only (bounded read on a partitioned, growing table).
-- =============================================
CREATE OR ALTER PROCEDURE Workorder.ScaleStation_GetPressLog
    @TerminalLocationId BIGINT,
    @Top                INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (ISNULL(@Top, 20))
        il.Id AS InterfaceLogId,
        CAST(il.LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LoggedAtEt,
        TRY_CAST(JSON_VALUE(j.Body, '$.net')  AS DECIMAL(10,4)) AS Net,
        JSON_VALUE(j.Body, '$.uom')                             AS Uom,
        JSON_VALUE(j.Body, '$.verdict')                         AS Verdict,
        TRY_CAST(JSON_VALUE(j.Body, '$.low')  AS DECIMAL(10,4)) AS Low,
        TRY_CAST(JSON_VALUE(j.Body, '$.high') AS DECIMAL(10,4)) AS High,
        JSON_VALUE(j.Body, '$.scaleVerdict')                    AS ScaleVerdict,
        CAST(CASE JSON_VALUE(j.Body, '$.agree') WHEN 'true' THEN 1 WHEN 'false' THEN 0 END AS BIT) AS FlagsAgree,
        CASE WHEN il.LotId IS NOT NULL THEN N'Closed'
             WHEN ISNULL(JSON_VALUE(j.Body, '$.verdict'), N'') <> N'Ok' THEN N'Refused'
             ELSE N'Failed' END                                 AS Outcome,
        il.ErrorDescription                                     AS Detail,
        il.Description,
        il.LotId,
        l.LotName,
        tr.ContainerId,
        tr.TrayPosition,
        cc.TraysPerContainer,
        sl.AimShipperId,
        sl.LabelStatus
    FROM Audit.InterfaceLog il
    CROSS APPLY (SELECT CASE WHEN ISJSON(il.RequestPayload) = 1 THEN il.RequestPayload END AS Body) j
    LEFT JOIN Lots.Lot l ON l.Id = il.LotId
    OUTER APPLY (
        SELECT TOP 1 ct.ContainerId, ct.TrayPosition
        FROM Lots.ContainerTray ct WHERE il.LotId IS NOT NULL AND ct.FinishedGoodLotId = il.LotId
        ORDER BY ct.Id DESC
    ) tr
    LEFT JOIN Lots.Container c ON c.Id = tr.ContainerId
    LEFT JOIN Parts.ContainerConfig cc ON cc.Id = c.ContainerConfigId
    OUTER APPLY (
        SELECT TOP 1 s.AimShipperId,
               CASE WHEN s.LastPrintErrorCondition IS NOT NULL THEN N'Failed'
                    WHEN s.Initial = 0 THEN N'Reprinted'
                    ELSE N'Sent' END AS LabelStatus
        FROM Lots.ShippingLabel s
        WHERE s.ContainerId = tr.ContainerId AND s.IsVoid = 0
        ORDER BY s.Id DESC
    ) sl
    WHERE il.LocationId = @TerminalLocationId
      AND il.LoggedAt >= DATEADD(DAY, -30, SYSUTCDATETIME())   -- recent presses only: keeps the seek to the newest partitions
      AND il.SystemName LIKE N'PLC:%'
      AND JSON_VALUE(j.Body, '$.v') IS NOT NULL
      AND (il.ErrorCondition IS NULL OR il.ErrorCondition NOT LIKE N'ScaleFlags%')
    ORDER BY il.LoggedAt DESC, il.Id DESC;
END;
GO
