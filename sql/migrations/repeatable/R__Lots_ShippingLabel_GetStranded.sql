-- ============================================================
-- Repeatable: R__Lots_ShippingLabel_GetStranded.sql
-- Author:     Blue Ridge Automation
-- Version:    1.0
-- Description: Brief D -- stranded-print sweep source. Returns shipping labels that were
--   born (Container_Complete committed) but never dispatched: PrintedAt NULL AND
--   PrintFailedAt NULL AND older than 60s (a Gateway restart between the complete commit
--   and the async dispatch). PrintFailureGateway.sweepTick re-dispatches each. Read proc:
--   one result set, empty = none (FDS-11-011). Uses the filtered IX_ShippingLabel_Stranded.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_GetStranded
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ContainerId, AimShipperId, TerminalLocationId, ZplContent, PrintAttempts
    FROM Lots.ShippingLabel
    WHERE PrintedAt IS NULL
      AND PrintFailedAt IS NULL
      AND CreatedAt < DATEADD(SECOND, -60, SYSUTCDATETIME());
END;
GO
