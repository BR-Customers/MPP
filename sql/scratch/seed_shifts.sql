-- =============================================
-- sql/scratch/seed_shifts.sql
-- DEV-ONLY. Builds a clean trailing shift timeline in MPP_MES_Dev by inserting
-- a single anchor shift ~2 days back at a real boundary, then letting
-- Oee.Shift_Reconcile backfill the full timeline up to now and open the current
-- shift. Reuses the proc, so it also exercises it end-to-end. Local time.
--
-- Run:  sqlcmd -S localhost -d MPP_MES_Dev -E -C -I -i sql/scratch/seed_shifts.sql
-- Safe to re-run: clears prior Oee.Shift rows first (dependent test rows must be
-- clear -- run against a shift-clean dev DB, or delete DowntimeEvent/diecast
-- shift-output rows first).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- FK-safe clear (adjust if your dev DB has dependent rows you want to keep).
DELETE FROM Oee.Shift;

DECLARE @First BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'First Shift' AND DeprecatedAt IS NULL);
IF @First IS NULL
BEGIN
    RAISERROR('No active "First Shift" schedule found in this DB. Seed the real schedules first.', 16, 1);
    RETURN;
END

-- Anchor: a First Shift that ENDED at 15:00 two days ago (a real boundary).
-- (DATETIME2 does not support the legacy DATETIME "+ string literal" idiom,
-- so the boundary is built via DATEADD(HOUR, ...) instead.)
DECLARE @AnchorEnd DATETIME2(3) =
    DATEADD(HOUR, 15, CAST(DATEADD(DAY, -2, CAST(SYSDATETIME() AS DATE)) AS DATETIME2(3)));
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@First, DATEADD(HOUR, -8, @AnchorEnd), @AnchorEnd, N'seed anchor');

-- Reconcile builds every scheduled instance from the anchor up to now + opens current.
DECLARE @U BIGINT = (SELECT MIN(Id) FROM Location.AppUser);
DECLARE @r TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @r EXEC Oee.Shift_Reconcile @NowLocal = NULL, @MaxBackfillDays = 7, @AppUserId = @U;

SELECT Message, ShiftsBackfilled, ShiftOpened FROM @r;
SELECT s.Id, ss.Name, CONVERT(varchar, s.ActualStart, 120) AS ActualStart,
       CONVERT(varchar, s.ActualEnd, 120) AS ActualEnd
FROM Oee.Shift s JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
ORDER BY s.ActualStart DESC;
GO
