-- ============================================================
-- Repeatable:  R__Workorder_TrimCheckpoint_GetLatestForLot.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: The LOT's newest TRIM checkpoint (TrimIn / TrimOut template), for
--              the "already recorded" line on the partial-trim popup and Trim OUT.
--              Empty result = no trim count recorded yet (read-proc convention:
--              no invented 404). EventAt returned ET. ShiftLabel matches
--              BlueRidge.Oee.Shift.getRecentOptions ('<Schedule> - MM/dd').
--              Spec 2026-09-22-trim-partial-shift-end-design.md sec 5.3.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.TrimCheckpoint_GetLatestForLot
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        pe.Id AS ProductionEventId,
        pe.ShotCount,
        CAST(pe.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventAt,
        oty.Code AS OperationTypeCode,
        ISNULL(ss.Name + N' - ' + FORMAT(s.ActualStart, N'MM/dd'), N'') AS ShiftLabel,
        u.Initials
    FROM Workorder.ProductionEvent pe
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
    INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
    INNER JOIN Location.AppUser u         ON u.Id = pe.AppUserId
    LEFT  JOIN Oee.Shift s                ON s.Id = pe.ShiftId
    LEFT  JOIN Oee.ShiftSchedule ss       ON ss.Id = s.ShiftScheduleId
    WHERE pe.LotId = @LotId AND pe.ShotCount IS NOT NULL
      AND oty.Code IN (N'TrimIn', N'TrimOut')
    ORDER BY pe.EventAt DESC, pe.Id DESC;
END;
GO
