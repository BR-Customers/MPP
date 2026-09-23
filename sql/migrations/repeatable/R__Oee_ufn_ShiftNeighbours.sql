-- ============================================================
-- Repeatable:  R__Oee_ufn_ShiftNeighbours.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: The CLOSED shift instances within @Radius positions of a given
--              shift, with their signed distance. One definition, used by the
--              shift reconciliation's move targets and by the save's guard
--              that an entry only moves within two shifts of the one being
--              reconciled (spec 2026-09-21 sec 7.3).
--
--              Position is Oee.Shift ordered by ActualStart -- the B3
--              single-open invariant makes that a straight line. The open
--              shift is never a target: the live screen owns it.
-- ============================================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftNeighbours (@ShiftId BIGINT, @Radius INT)
RETURNS TABLE
AS
RETURN
WITH o AS (
    SELECT s.Id, s.ActualEnd, ROW_NUMBER() OVER (ORDER BY s.ActualStart, s.Id) AS rn
    FROM Oee.Shift s
)
SELECT o.Id AS ShiftId, CAST(o.rn - me.rn AS INT) AS Offset
FROM o
CROSS JOIN (SELECT rn FROM o WHERE Id = @ShiftId) me
WHERE o.rn BETWEEN me.rn - @Radius AND me.rn + @Radius
  AND o.Id <> @ShiftId
  AND o.ActualEnd IS NOT NULL;
GO
