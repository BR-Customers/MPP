-- ============================================================
-- Repeatable:  R__Oee_DowntimeEvent_RequiresReasonGate.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Does changing THIS downtime event's reason need supervisor
--              elevation? Rule: never for a current (still-open) shift; for a
--              past shift, only once @GraceMinutes have elapsed since it
--              ended. Called fresh at the moment the operator picks a reason
--              (DowntimeManager's dtReasonSelected handler) rather than at
--              list-read time, so the grace window can't go stale between
--              when the row was fetched and when the operator actually clicks.
--
--              TIME BASIS (OI-38): Oee.Shift.ActualStart/ActualEnd are LOCAL
--              EASTERN wall-clock, NOT UTC -- a documented exception to this
--              project's usual UTC-storage rule (see
--              R__Oee_ufn_zz_ShiftIdForInstant.sql). @NowEt below is computed
--              the same way every other display-boundary conversion in this
--              codebase does it (CAST(... AT TIME ZONE 'UTC' AT TIME ZONE
--              'Eastern Standard Time' ...)), so it can be compared directly
--              to ActualEnd without a second conversion.
--
--              Fails CLOSED (gated) when the event carries no shift
--              attribution at all (ShiftId NULL, or the FK'd Shift row is
--              somehow gone) -- an unknown shift state is not grounds to skip
--              the gate. Read proc: one result set, no OUTPUT params
--              (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_RequiresReasonGate
    @DowntimeEventId BIGINT,
    @GraceMinutes    INT = 30
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasShift  BIT = 0;
    DECLARE @ActualEnd DATETIME2(3);

    SELECT @HasShift  = 1,
           @ActualEnd = sh.ActualEnd
    FROM Oee.DowntimeEvent de
    INNER JOIN Oee.Shift sh ON sh.Id = de.ShiftId
    WHERE de.Id = @DowntimeEventId;

    DECLARE @NowEt DATETIME2(3) =
        CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));

    DECLARE @Requires BIT =
        CASE
            WHEN @HasShift = 0        THEN 1  -- no shift attribution -- fail closed, gate it
            WHEN @ActualEnd IS NULL   THEN 0  -- shift still open (current shift) -- never gated
            WHEN DATEADD(MINUTE, @GraceMinutes, @ActualEnd) >= @NowEt THEN 0  -- within grace window
            ELSE 1                            -- past shift, grace window elapsed -- gate it
        END;

    SELECT @Requires AS RequiresElevation;
END;
GO
