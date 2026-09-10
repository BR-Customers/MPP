-- ============================================================
-- Repeatable:  R__Workorder_DieCastCounterAnchorReason_List.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-10
-- Version:     1.0
-- Description: The reasons an operator may give for re-anchoring a die cast
--              press counter (migration 0074). Read-only code table; feeds the
--              reason dropdown on the Counter Anchor dialog.
--
--              RequiresNote is derived from the Code rather than stored: only
--              'Other' has nothing else on the row to explain itself, and the
--              rule is enforced in Workorder.DieCastCounterAnchor_Record. It
--              is surfaced here so the dialog can require the note at the
--              button instead of letting the write reject.
--
--              FDS-11-011: no OUTPUT params, one result set.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastCounterAnchorReason_List
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        r.Id            AS Id,
        r.Code          AS Code,
        r.Name          AS Name,
        r.Description   AS Description,
        CAST(CASE WHEN r.Code = N'Other' THEN 1 ELSE 0 END AS BIT) AS RequiresNote
    FROM Workorder.DieCastCounterAnchorReason r
    ORDER BY r.SortOrder, r.Name;
END;
GO
