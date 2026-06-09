-- ============================================================
-- Repeatable:  R__Oee_Shift_GetOpen.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-09
-- Version:     1.0
-- Description: Returns the currently-OPEN runtime Oee.Shift instance
--              (ActualEnd IS NULL), joined to its schedule for naming. Under
--              the B3 single-open invariant there is at most one; TOP 1 +
--              ORDER BY guards against any historical multiplicity.
--
--              Read proc: ONE result set, empty = no open shift. No OUTPUT
--              params, no audit.
-- ============================================================

CREATE OR ALTER PROCEDURE Oee.Shift_GetOpen
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        s.Id,
        s.ShiftScheduleId,
        ss.Name            AS ScheduleName,
        s.ActualStart,
        s.ActualEnd,
        s.Remarks,
        s.CreatedAt
    FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
    WHERE s.ActualEnd IS NULL
    ORDER BY s.ActualStart DESC, s.Id DESC;
END;
GO
