-- ============================================================
-- Repeatable:  R__Workorder_DieCastReconciliationReason_List.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: Why a team lead is reconciling a past shift (migration 0097).
--              Read-only code table; feeds the Reason dropdown. RequiresNote
--              is surfaced so the screen can demand the note at the field
--              instead of letting the save reject.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastReconciliationReason_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.Id, r.Code, r.Name, r.RequiresNote
    FROM Workorder.DieCastReconciliationReason r
    ORDER BY r.SortOrder, r.Name;
END;
GO
