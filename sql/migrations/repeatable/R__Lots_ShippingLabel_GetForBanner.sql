-- ============================================================
-- Repeatable: R__Lots_ShippingLabel_GetForBanner.sql
-- Author:     Blue Ridge Automation
-- Version:    1.1
-- Description: Brief D -- terminal print-failure banner source. Returns shipping labels
--   that have exhausted their dispatch attempts (PrintFailedAt NOT NULL) and have not yet
--   been acknowledged (BannerAcknowledgedAt NULL). PrintFailureGateway.broadcastTick sends
--   a 'print-failure-alert' per row, targeted at TerminalLocationId's session; the
--   PrintFailureBanner filters by session.custom.terminal. Read proc: one result set,
--   empty = none (FDS-11-011).
--
--   v1.1 (2026-10-01, migration 0102): + LastPrintErrorCondition. The raw text alone
--   could not be turned into an instruction -- BlueRidge.Lots.LabelTransport.
--   operatorGuidance keys on the taxonomy NAME, so without this column every async
--   print failure reached the operator as the generic "tell a supervisor". NOTE this
--   changes the result-set shape: anything capturing it via INSERT-EXEC needs the
--   sixth column.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_GetForBanner
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ContainerId, TerminalLocationId, AimShipperId, LastPrintError,
           LastPrintErrorCondition
    FROM Lots.ShippingLabel
    WHERE PrintFailedAt IS NOT NULL
      AND BannerAcknowledgedAt IS NULL;
END;
GO
