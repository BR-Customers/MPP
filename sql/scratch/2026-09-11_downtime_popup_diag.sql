-- ============================================================
-- READ-ONLY diagnostic: why the Downtime Manager popup is blank at die cast.
--
-- The popup lists Oee.DowntimeEvent_GetByScope(@press, 1, @ShiftId).
-- With the shift dropdown on "Current shift" (@ShiftId NULL) the proc takes
-- the LATEST OPEN Oee.Shift and shows only events whose ShiftId EQUALS it.
-- The writers stamp ShiftId from Oee.ufn_ShiftIdForInstant(press, instant)
-- instead. When the two disagree -- or ShiftId is NULL -- the event exists
-- but never appears.
--
-- Oee.Shift.ActualStart/ActualEnd are Eastern WALL-CLOCK; DowntimeEvent
-- times are UTC (shown here converted to ET).
-- No writes. Run:
--   sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -C -W -s "|" -i sql\scratch\2026-09-11_downtime_popup_diag.sql
-- ============================================================
SET NOCOUNT ON;

DECLARE @NowEt DATETIME2(0) = CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0));
DECLARE @PopupShift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC);

PRINT '== 1. Recent Oee.Shift rows (is ShiftBoundaryTicker rolling them?)';
SELECT TOP 8 s.Id, ss.Name AS Schedule, s.ActualStart AS StartET, s.ActualEnd AS EndET,
       CAST(s.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS RowCreatedET
FROM Oee.Shift s LEFT JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
ORDER BY s.ActualStart DESC;

PRINT '== 2. Now, and the shift the popup uses for "Current shift"';
SELECT @NowEt AS NowET, @PopupShift AS PopupShiftId,
       (SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NULL) AS OpenShiftRows;

PRINT '== 3. Shift a NEW downtime event would be stamped with right now, per die cast press';
SELECT l.Code AS Press, r.ShiftId AS WriterShiftId, r.ScheduleName, r.BusinessDate, r.IsOverridden,
       CASE WHEN r.ShiftId IS NULL THEN 'NULL -> never shown'
            WHEN r.ShiftId = @PopupShift THEN 'matches popup'
            ELSE 'DIFFERENT -> hidden' END AS Verdict
FROM Location.Location l
JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
JOIN Location.Location a ON a.Id = l.ParentLocationId
OUTER APPLY Oee.ufn_ShiftIdForInstant(l.Id, SYSUTCDATETIME()) r
WHERE ltd.Name = N'Die Cast Machine' AND l.DeprecatedAt IS NULL AND a.Code LIKE N'DC%'
ORDER BY l.Code;

PRINT '== 4. Downtime events, last 7 days, and whether the popup shows them on "Current shift"';
SELECT de.Id, loc.Code AS Location, lt.Code AS Tier,
       CAST(de.StartedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS StartedET,
       CAST(de.EndedAt   AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS EndedET,
       de.ShiftId, ss.Name AS StampedSchedule, sh.ActualStart AS StampedShiftStartET,
       de.IsApproximate, CASE WHEN de.VoidedAt IS NULL THEN 0 ELSE 1 END AS Voided,
       CASE WHEN de.ShiftId IS NULL THEN 'no - ShiftId NULL'
            WHEN de.ShiftId = @PopupShift THEN 'YES'
            ELSE 'no - other shift' END AS ShownOnCurrentShift
FROM Oee.DowntimeEvent de
JOIN Location.Location loc ON loc.Id = de.LocationId
JOIN Location.LocationTypeDefinition ltd ON ltd.Id = loc.LocationTypeDefinitionId
JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
LEFT JOIN Oee.Shift sh ON sh.Id = de.ShiftId
LEFT JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
WHERE de.StartedAt >= DATEADD(DAY, -7, SYSUTCDATETIME())
ORDER BY de.StartedAt DESC;

PRINT '== 5. Summary (last 7 days)';
SELECT COUNT(*) AS Events,
       SUM(CASE WHEN ShiftId IS NULL THEN 1 ELSE 0 END) AS ShiftIdNull,
       SUM(CASE WHEN ShiftId = @PopupShift THEN 1 ELSE 0 END) AS OnPopupShift,
       SUM(CASE WHEN ShiftId IS NOT NULL AND ShiftId <> @PopupShift THEN 1 ELSE 0 END) AS OnOtherShifts
FROM Oee.DowntimeEvent WHERE StartedAt >= DATEADD(DAY, -7, SYSUTCDATETIME());
