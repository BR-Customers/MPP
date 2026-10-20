-- =============================================
-- Procedure:   Workorder.ScaleStation_GetShiftTally
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Version:     1.0
--
-- Description:
--   "This shift at this scale" for the scale station screen (spec 2026-10-19
--   scale station, sec. 7): trays closed, parts packed, boxes completed, and
--   presses refused (under / over / other), for the shift covering now at
--   the terminal (Oee.ufn_ShiftIdForInstant -- the attribution authority).
--
--   Closes and boxes come from production records (Lots.ContainerTray /
--   Lots.Container by StationLocationId), so a close made any other way is
--   counted too. Refusals come from the interface log press rows (the same
--   filter as ScaleStation_GetPressLog).
--
--   No covering shift -> ONE row of zeros (never an empty set), so the
--   screen's binding keeps its shape.
--
--   Read proc, one result set, no OUTPUT params (FDS-11-011). Times Eastern.
--
-- Parameters:
--   @TerminalLocationId BIGINT - Required.
--
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Workorder.ScaleStation_GetShiftTally
    @TerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ShiftName NVARCHAR(100), @StartLocal DATETIME2(3), @EndLocal DATETIME2(3),
            @FromUtc DATETIME2(3), @ToUtc DATETIME2(3);

    SELECT TOP 1 @ShiftName = ScheduleName,
                 @StartLocal = CAST(StartLocal AS DATETIME2(3)),
                 @EndLocal   = CAST(EndLocal AS DATETIME2(3))
    FROM Oee.ufn_ShiftIdForInstant(@TerminalLocationId, SYSUTCDATETIME());

    SET @FromUtc = CAST(@StartLocal AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    SET @ToUtc   = CAST(@EndLocal   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

    SELECT @ShiftName AS ShiftName,
           @StartLocal AS ShiftStartEt,
           @EndLocal AS ShiftEndEt,
           ISNULL(tr.TraysClosed, 0)   AS TraysClosed,
           ISNULL(tr.PartsPacked, 0)   AS PartsPacked,
           ISNULL(bx.BoxesCompleted, 0) AS BoxesCompleted,
           ISNULL(rf.Refused, 0)       AS Refused,
           ISNULL(rf.RefusedUnder, 0)  AS RefusedUnder,
           ISNULL(rf.RefusedOver, 0)   AS RefusedOver,
           ISNULL(rf.RefusedOther, 0)  AS RefusedOther
    FROM (SELECT 1 AS One) x
    OUTER APPLY (
        SELECT COUNT(*) AS TraysClosed, SUM(ct.PartsClosedCount) AS PartsPacked
        FROM Lots.ContainerTray ct
        JOIN Lots.Container c ON c.Id = ct.ContainerId
        WHERE c.StationLocationId = @TerminalLocationId
          AND ct.ClosedAt >= @FromUtc AND ct.ClosedAt < @ToUtc
    ) tr
    OUTER APPLY (
        SELECT COUNT(*) AS BoxesCompleted
        FROM Lots.Container c
        WHERE c.StationLocationId = @TerminalLocationId
          AND c.CompletedAt >= @FromUtc AND c.CompletedAt < @ToUtc
    ) bx
    OUTER APPLY (
        SELECT COUNT(*) AS Refused,
               SUM(CASE WHEN p.Verdict = N'Under' THEN 1 ELSE 0 END) AS RefusedUnder,
               SUM(CASE WHEN p.Verdict = N'Over'  THEN 1 ELSE 0 END) AS RefusedOver,
               SUM(CASE WHEN ISNULL(p.Verdict, N'') NOT IN (N'Under', N'Over') THEN 1 ELSE 0 END) AS RefusedOther
        FROM (
            SELECT JSON_VALUE(j.Body, '$.verdict') AS Verdict
            FROM Audit.InterfaceLog il
            CROSS APPLY (SELECT CASE WHEN ISJSON(il.RequestPayload) = 1 THEN il.RequestPayload END AS Body) j
            WHERE il.LocationId = @TerminalLocationId
              AND il.LoggedAt >= @FromUtc AND il.LoggedAt < @ToUtc
              AND il.SystemName LIKE N'PLC:%'
              AND JSON_VALUE(j.Body, '$.v') IS NOT NULL
              AND (il.ErrorCondition IS NULL OR il.ErrorCondition NOT LIKE N'ScaleFlags%')
              AND il.LotId IS NULL
        ) p
        WHERE ISNULL(p.Verdict, N'') <> N'Ok'
    ) rf;
END;
GO
