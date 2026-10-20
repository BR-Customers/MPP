-- =============================================
-- Procedure:   Workorder.ScaleStation_ListEligibleParts
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Version:     1.0
--
-- Description:
--   The scale station's part picker: every finished good the terminal's
--   line may run By Weight right now (Workorder.ufn_ScaleStationEligibleParts),
--   closest to ready first, with the checkweigh window. Read proc, one
--   result set, no OUTPUT params (FDS-11-011). Empty = nothing eligible.
--
-- Parameters:
--   @TerminalLocationId BIGINT - Required.
--
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Workorder.ScaleStation_ListEligibleParts
    @TerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT e.ItemId, e.PartNumber, e.Description, e.PartsPerTray, e.TraysPerContainer,
           e.TargetWeight, e.ToleranceWeight, e.LinesTotal, e.LinesCovered, e.ShareCovered,
           e.CastLinesCovered, e.TraysCovered, e.ReadyRank,
           e.TargetWeight - e.ToleranceWeight AS LowLimit,
           e.TargetWeight + e.ToleranceWeight AS HighLimit
    FROM Workorder.ufn_ScaleStationEligibleParts(@TerminalLocationId) e
    ORDER BY e.ReadyRank;
END;
GO
