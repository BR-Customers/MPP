-- ============================================================
-- Repeatable:  R__Lots_Container_GetLabelData.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Field data for the Honda container shipping label (first pass). Returns
--              one row of the mappable fields for @ContainerId, as display strings:
--                PartNumber, Description, CountryOfOrigin  (from the container's FG Item)
--                Quantity     (SUM of closed ContainerTray.PartsClosedCount)
--                MfgDate      (Container.CompletedAt, ET, mm/dd/yy; '' if still open)
--                MfgLotNumber (the first tray's finished-good LOT name)
--                Serial       (the container's non-void ShippingLabel AimShipperId; '' pre-completion)
--              The Honda-specific fields (part-# extension, D/C part level, 2D DataMatrix,
--              auditor) have no MES source yet and are intentionally omitted (rendered blank).
--              Read proc; empty rowset = container not found.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Container_GetLabelData
    @ContainerId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ContainerId IS NULL
        RETURN;

    SELECT
        i.PartNumber                              AS PartNumber,
        ISNULL(i.Description, N'')                AS Description,
        ISNULL(i.CountryOfOrigin, N'')           AS CountryOfOrigin,
        CAST((SELECT ISNULL(SUM(t.PartsClosedCount), 0)
              FROM Lots.ContainerTray t
              WHERE t.ContainerId = c.Id AND t.ClosedAt IS NOT NULL) AS NVARCHAR(20)) AS Quantity,
        ISNULL(CONVERT(NVARCHAR(8),
               CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), 1), N'') AS MfgDate,
        ISNULL((SELECT TOP 1 l.LotName
                FROM Lots.ContainerTray t
                INNER JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId
                WHERE t.ContainerId = c.Id
                ORDER BY t.TrayPosition), N'') AS MfgLotNumber,
        ISNULL((SELECT TOP 1 sl.AimShipperId
                FROM Lots.ShippingLabel sl
                WHERE sl.ContainerId = c.Id AND sl.IsVoid = 0
                ORDER BY sl.Id DESC), N'') AS Serial
    FROM Lots.Container c
    INNER JOIN Parts.Item i ON i.Id = c.ItemId
    WHERE c.Id = @ContainerId;
END;
GO
