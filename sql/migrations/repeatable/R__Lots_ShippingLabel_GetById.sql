-- ============================================================
-- Repeatable: R__Lots_ShippingLabel_GetById.sql
-- Author:     Blue Ridge Automation
-- Version:    1.0
-- Description: Brief D -- single-row read of a shipping label incl the rendered
--   ZplContent, used by ShippingDispatcher to fetch the persisted payload to dispatch.
--   Read proc: one result set, empty = not found (FDS-11-011). No OUTPUT params.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_GetById
    @ShippingLabelId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ContainerId, AimShipperId, LabelTypeCodeId, TerminalLocationId,
           ZplContent, PrintedAt, PrintFailedAt, PrintAttempts, LastPrintError
    FROM Lots.ShippingLabel
    WHERE Id = @ShippingLabelId;
END;
GO
