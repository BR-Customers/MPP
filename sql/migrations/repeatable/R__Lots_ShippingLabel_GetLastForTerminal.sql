-- ============================================================
-- Repeatable: R__Lots_ShippingLabel_GetLastForTerminal.sql
-- Author:     Blue Ridge Automation
-- Version:    1.0
-- Description: Most recent non-void shipping label printed at a terminal, so a
--   plant-floor "Reprint" button can find the label to act on (e.g. a dropped
--   or damaged label) without the operator knowing a ShippingLabelId. Read
--   proc: one result set, empty = none printed yet at this terminal
--   (FDS-11-011). No OUTPUT params.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_GetLastForTerminal
    @TerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1) Id, ContainerId, AimShipperId, CreatedAt, PrintedAt, PrintFailedAt
    FROM Lots.ShippingLabel
    WHERE TerminalLocationId = @TerminalLocationId
      AND IsVoid = 0
    ORDER BY CreatedAt DESC;
END;
GO
