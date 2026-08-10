-- Recent shifts for the Reports landing-page shift picker.
-- Returns human label ("First Shift - Aug 10, 2026") + the internal ShiftId value.
-- The operator never sees the surrogate id; the dropdown carries it as the option value.
SELECT TOP 60
    sh.Id AS value,
    ss.Name + ' - '
      + FORMAT(CAST(sh.ActualStart AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATE),
               'MMM d, yyyy') AS label
FROM Oee.Shift sh
JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
ORDER BY sh.ActualStart DESC;
