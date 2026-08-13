-- ============================================================
-- Repeatable: R__Lots_ShippingLabel_GetForBanner.sql
-- Author:     Blue Ridge Automation
-- Version:    1.0
-- Description: Brief D -- terminal print-failure banner source. Returns shipping labels
--   that have exhausted their dispatch attempts (PrintFailedAt NOT NULL) and have not yet
--   been acknowledged (BannerAcknowledgedAt NULL). PrintFailureGateway.broadcastTick sends
--   a 'print-failure-alert' per row, targeted at TerminalLocationId's session; the
--   PrintFailureBanner filters by session.custom.terminal. Read proc: one result set,
--   empty = none (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_GetForBanner
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ContainerId, TerminalLocationId, AimShipperId, LastPrintError
    FROM Lots.ShippingLabel
    WHERE PrintFailedAt IS NOT NULL
      AND BannerAcknowledgedAt IS NULL;
END;
GO
