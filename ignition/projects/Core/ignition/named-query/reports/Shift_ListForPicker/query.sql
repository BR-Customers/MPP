-- Recent shifts for the Reports landing-page shift picker.
-- Returns human label ("First Shift - Aug 10, 2026") + the internal ShiftId value.
-- The operator never sees the surrogate id; the dropdown carries it as the option value.
--
-- TIME BASIS: Oee.Shift.ActualStart is stored in LOCAL Eastern, not UTC -- a
-- deliberate exception for the shift subsystem (OI-38; see
-- docs/superpowers/specs/2026-07-31-shift-boundary-reconcile-design.md D4).
-- So NO AT TIME ZONE conversion belongs here. The previous version applied the
-- standard UTC->Eastern conversion, subtracting a further 4-5 hours from an
-- already-local value; any shift starting between midnight and 04:00 local was
-- labelled with the PREVIOUS day's date.
SELECT TOP 60
    sh.Id AS value,
    ss.Name + ' - ' + FORMAT(CAST(sh.ActualStart AS DATE), 'MMM d, yyyy') AS label
FROM Oee.Shift sh
JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
ORDER BY sh.ActualStart DESC;
