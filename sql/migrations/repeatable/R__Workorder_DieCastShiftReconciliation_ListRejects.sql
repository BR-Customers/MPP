-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListRejects.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: The reject block's Recorded side: scrap on record for this
--              shift x press x die, by reason and part (spec sec 6.2).
--              Warm-up (999) is excluded -- it is its own field on the screen
--              and is entered in shots, not as a reject line (A7).
--              A net-zero pair (a reconciliation's compensating row cancelling
--              an earlier one) drops out: nothing is on record any more.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_ListRejects
    @ShiftId        BIGINT,
    @CellLocationId BIGINT,
    @ToolId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT re.DefectCodeId, dc.Code AS DefectCode, dc.Description AS Defect, dc.IsNonRejectScrap,
           re.ItemId, i.PartNumber, SUM(re.Quantity) AS Quantity,
           COUNT(DISTINCT re.ToolCavityId) AS Cavities, MAX(u.Initials) AS ApprovedBy
    FROM Workorder.RejectEvent re
    INNER JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId
    LEFT JOIN Parts.Item i ON i.Id = re.ItemId
    LEFT JOIN Location.AppUser u ON u.Id = re.ApprovedByUserId
    WHERE re.ShiftId = @ShiftId AND re.CellLocationId = @CellLocationId AND re.ToolId = @ToolId
      AND dc.Code <> N'999'
    GROUP BY re.DefectCodeId, dc.Code, dc.Description, dc.IsNonRejectScrap, re.ItemId, i.PartNumber
    HAVING SUM(re.Quantity) <> 0
    ORDER BY dc.Code, i.PartNumber;
END;
GO
