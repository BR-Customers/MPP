-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListRejects.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.1
-- Description: The reject block's Recorded side: scrap on record for this
--              shift x press x die, by reason, part AND APPROVER (spec sec 6.2).
--              Warm-up (999) is excluded -- it is its own field on the screen
--              and is entered in shots, not as a reject line (A7).
--              A net-zero pair (a reconciliation's compensating row cancelling
--              an earlier one) drops out: nothing is on record any more.
--
--              THE GRAIN IS (DefectCode, Part, Approver) -- read this before
--              binding a screen to it. One defect code on one part, approved by
--              two different people, is TWO ROWS, each carrying only the quantity
--              that person approved. An unapproved line (ApprovedByUserId NULL)
--              is its own row alongside them; NULL groups as one value, so the
--              unapproved quantity is never folded into an approver's.
--              Callers that want a per-defect total must SUM the rows.
--
--              WHY, since a per-defect grain would be fewer rows: v1.0 grouped by
--              (DefectCodeId, ItemId) and surfaced MAX(u.Initials), so with two
--              approvers one name was picked arbitrarily, the other vanished, and
--              the whole quantity was shown against a person who had approved only
--              part of it. Scrap approval is an accountability record -- it must
--              not name the wrong person, and it must not silently lose one.
--              Ordered code, part, then approver, so a split pair reads together.
--
-- Change Log:
--   2026-09-22 - 1.0 - Initial version (die cast shift reconciliation, sec 6.2).
--   2026-09-25 - 1.1 - Group by the approver; ApprovedByUserId joins the result
--                      set. Result-set SHAPE CHANGE -- see the grain note above.
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
           COUNT(DISTINCT re.ToolCavityId) AS Cavities,
           re.ApprovedByUserId, u.Initials AS ApprovedBy
    FROM Workorder.RejectEvent re
    INNER JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId
    LEFT JOIN Parts.Item i ON i.Id = re.ItemId
    LEFT JOIN Location.AppUser u ON u.Id = re.ApprovedByUserId
    WHERE re.ShiftId = @ShiftId AND re.CellLocationId = @CellLocationId AND re.ToolId = @ToolId
      AND dc.Code <> N'999'
    -- The approver is a GROUPING KEY, not an aggregate: two approvers on one
    -- defect code give two rows, each owning its own quantity (v1.1).
    GROUP BY re.DefectCodeId, dc.Code, dc.Description, dc.IsNonRejectScrap, re.ItemId, i.PartNumber,
             re.ApprovedByUserId, u.Initials
    HAVING SUM(re.Quantity) <> 0
    ORDER BY dc.Code, i.PartNumber, u.Initials;
END;
GO
