-- =============================================
-- Procedure:   Workorder.ScaleStation_GetRecentBoxes
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Version:     1.0
--
-- Description:
--   The scale station's recently completed boxes, newest first, with their
--   shipping label status, for the screen's Recent Boxes card (spec
--   2026-10-19 scale station, sec. 7). Open boxes are not listed.
--
--   LabelStatus, from the box's latest non-void ShippingLabel:
--     Failed    -- its last print attempt failed (LastPrintErrorCondition);
--     Reprinted -- it is a reprint (Initial = 0);
--     Sent      -- otherwise;
--     NULL      -- no label row.
--   LotName is the box's last tray's finished-good LOT.
--
--   Read proc, one result set, no OUTPUT params (FDS-11-011). Times Eastern.
--
-- Parameters:
--   @TerminalLocationId BIGINT - Required.
--   @Top                INT    - Rows to return (default 5).
--
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Workorder.ScaleStation_GetRecentBoxes
    @TerminalLocationId BIGINT,
    @Top                INT = 5
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (ISNULL(@Top, 5))
        c.Id AS ContainerId,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CompletedAtEt,
        ISNULL(t.Pieces, 0) AS Pieces,
        ISNULL(t.Trays, 0)  AS Trays,
        lt.LotName,
        sl.AimShipperId,
        sl.LabelStatus
    FROM Lots.Container c
    OUTER APPLY (
        SELECT SUM(ct.PartsClosedCount) AS Pieces, COUNT(*) AS Trays
        FROM Lots.ContainerTray ct WHERE ct.ContainerId = c.Id
    ) t
    OUTER APPLY (
        SELECT TOP 1 l.LotName
        FROM Lots.ContainerTray ct JOIN Lots.Lot l ON l.Id = ct.FinishedGoodLotId
        WHERE ct.ContainerId = c.Id
        ORDER BY ct.TrayPosition DESC, ct.Id DESC
    ) lt
    OUTER APPLY (
        SELECT TOP 1 s.AimShipperId,
               CASE WHEN s.LastPrintErrorCondition IS NOT NULL THEN N'Failed'
                    WHEN s.Initial = 0 THEN N'Reprinted'
                    ELSE N'Sent' END AS LabelStatus
        FROM Lots.ShippingLabel s
        WHERE s.ContainerId = c.Id AND s.IsVoid = 0
        ORDER BY s.Id DESC
    ) sl
    WHERE c.StationLocationId = @TerminalLocationId
      AND c.CompletedAt IS NOT NULL
    ORDER BY c.CompletedAt DESC, c.Id DESC;
END;
GO
