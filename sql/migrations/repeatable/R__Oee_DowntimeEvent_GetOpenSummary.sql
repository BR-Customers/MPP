-- ============================================================
-- Repeatable:  R__Oee_DowntimeEvent_GetOpenSummary.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-17
-- Version:     1.0
-- Description: Plant-wide open-downtime summary for the Supervisor Dashboard
--              (Arc 2 Phase 8). Counts currently-open downtime events, split by
--              whether a reason has been assigned (B7 triage signal -- unclassified
--              open downtime needs attention). READ proc: one result set, one row.
-- ============================================================

CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_GetOpenSummary
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        COUNT(*)                                                              AS TotalOpen,
        SUM(CASE WHEN de.DowntimeReasonCodeId IS NOT NULL THEN 1 ELSE 0 END)  AS WithReason,
        SUM(CASE WHEN de.DowntimeReasonCodeId IS NULL THEN 1 ELSE 0 END)      AS WithoutReason
    FROM Oee.DowntimeEvent de
    WHERE de.EndedAt IS NULL;
END;
GO
