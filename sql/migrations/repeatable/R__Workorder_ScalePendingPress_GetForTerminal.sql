-- =============================================
-- Procedure: Workorder.ScalePendingPress_GetForTerminal
-- Author:    Blue Ridge Automation
-- Created:   2026-11-19
-- Version:   1.0
--
-- Description:
--   The terminal's held scale press, if any (Workorder.ScalePendingPress,
--   StatusId Pending). 0 or 1 row; the filtered unique index allows no more.
--   ReceivedAtEt is Eastern for display.
--   Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md section 7.
--
-- Parameters:
--   @TerminalLocationId BIGINT - the scale's terminal.
--
-- Result: Id, TerminalLocationId, ReceivedAtEt, NetWeight, Uom, ScalePartCode.
--
-- Change Log:
--   2026-11-19 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Workorder.ScalePendingPress_GetForTerminal
    @TerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.Id,
           p.TerminalLocationId,
           CAST(p.ReceivedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ReceivedAtEt,
           p.NetWeight,
           p.Uom,
           p.ScalePartCode
    FROM Workorder.ScalePendingPress p
    WHERE p.TerminalLocationId = @TerminalLocationId
      AND p.StatusId = 1;
END;
GO
