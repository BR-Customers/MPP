-- =============================================
-- Repeatable:  R__Oee_ufn_ProductionDay.sql
-- Object:      Oee.ufn_ProductionDay
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     1.0
-- Description: The production day a runtime shift belongs to (OEE dashboard
--              spec docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--              sec 6.6, decision D13). MPP's day runs 3rd -> 1st -> 2nd: the
--              3rd shift that starts Monday 22:30 is Tuesday's.
--
--              Rule: the LOCAL date the shift's SCHEDULED window ends. A
--              schedule whose EndTime is at or before its StartTime crosses
--              midnight and ends the next day -- except a window ending exactly
--              at 00:00, which ends on the day it started. Using the schedule,
--              not Oee.Shift.ActualEnd or an override, means an overrun never
--              moves a shift into another production day.
--
--              NOT Oee.Shift_GetAvailability's BusinessDate: that is the date a
--              shift STARTS, the key schedule windows and overrides are looked
--              up by, and it is deliberately left unchanged.
--
--              Oee.Shift.ActualStart is LOCAL (OI-38): no conversion.
--              No row for an unknown shift.
-- Change Log:
--   2026-10-29 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_ProductionDay (@ShiftId BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT CASE WHEN ss.EndTime <= ss.StartTime AND ss.EndTime > CAST('00:00:00' AS TIME(0))
                THEN DATEADD(DAY, 1, CAST(s.ActualStart AS DATE))
                ELSE CAST(s.ActualStart AS DATE)
           END AS ProductionDay
    FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
    WHERE s.Id = @ShiftId
);
GO
