-- ============================================================
-- Repeatable:  R__Oee_ufn_zz_ShiftIdForInstant.sql
-- Object:      Oee.ufn_ShiftIdForInstant
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
-- Description: THE attribution authority. Given a piece of OEE equipment and a
--              UTC instant, answers "which Oee.Shift row does work performed at
--              that instant on that equipment belong to?".
--
--              Spec: docs/superpowers/specs/2026-08-19-shift-override-attribution-design.md
--              sec 4.1. Companion to Oee.ufn_ShiftWindowForLocation, which
--              answers the WINDOW question; this one answers the INSTANT
--              question and is what every stamping site routes through.
--
--              FILE NAME IS ORDER-SENSITIVE -- the 'zz_' is a DEPLOY-ORDER
--              MARKER, not part of the object name (the object is plain
--              Oee.ufn_ShiftIdForInstant). Reset-DevDatabase deploys
--              repeatables in filename order and a FUNCTION gets no deferred
--              name resolution (Msg 4121) -- unlike a procedure, which does.
--              This function calls Oee.ufn_ShiftWindowForLocation, and
--              'ShiftIdForInstant' sorts BEFORE 'ShiftWindowForLocation'
--              ('I' < 'W'), so an unmarked filename would fail on a clean
--              build. Same constraint that named R__Oee_ufn_ResolveOeeEquipment.
--              Do not "tidy" the filename.
--
--              -------- RESOLUTION RULES --------
--
--              (1) HALF-OPEN BOUNDS. A window covers [StartLocal, EndLocal).
--                  An instant exactly on a boundary lands in the LATER shift
--                  and in exactly one shift -- back-to-back shifts can never
--                  both match.
--
--              (2) (-1, 0) BUSINESS-DATE SPINE. Two candidate business dates
--                  are probed: the instant's local date and the day before.
--                  A 02:00 instant therefore attributes to the PREVIOUS
--                  business date's third shift, which started at 22:30 the
--                  night before -- not to a phantom shift on today's date.
--
--              (3) OVERRIDE PRECEDENCE (design D1). When an override extends
--                  First to 16:00 for one press but the plant-global Second
--                  still starts at 14:30, a 15:00 instant is covered by BOTH
--                  windows. The OVERRIDDEN window wins, which is exactly what
--                  D1 means by "an override moves a boundary": Second
--                  effectively starts at 16:00 FOR THAT PRESS, without needing
--                  a second override row to say so. Two OVERRIDDEN windows
--                  covering the same instant is a genuine authoring conflict
--                  and is rejected up front by Oee.ufn_ShiftOverrideConflicts;
--                  should one slip through across a date boundary, the
--                  later-starting window wins deterministically.
--
--              (4) DAY-OF-WEEK BITMASK. A schedule is a candidate on a date
--                  only when its DaysOfWeekBitmask includes that date's ISO
--                  weekday -- UNLESS an override supplies the window, because
--                  an override ASSERTS the window regardless of the bitmask
--                  (Saturday overtime on one press). Matches
--                  Oee.ShiftOverride_Create's documented semantics.
--                  The weekday bit is derived from DATEDIFF against
--                  1900-01-01 (a Monday) so it is deterministic and
--                  @@DATEFIRST-independent -- a UDF must not depend on session
--                  state.
--
--              -------- TIME BASIS (OI-38 -- read this) --------
--
--              @InstantUtc is UTC (Oee.DowntimeEvent.StartedAt,
--              Workorder.DieCastContribution.EventAt, SYSUTCDATETIME()).
--              Oee.Shift.ActualStart, Oee.ShiftSchedule.StartTime and
--              Oee.ShiftOverride.StartTime are LOCAL EASTERN wall clock -- a
--              deliberate exception for the shift subsystem (OI-38, spec
--              2026-07-31-shift-boundary-reconcile-design D4). Mixing the two
--              produced six defects on 2026-08-19, two of which corrupted
--              stored data.
--              The conversion happens ONCE, at the top: @InstantUtc is brought
--              into local Eastern with AT TIME ZONE (DST-aware) and the
--              mandatory CAST(... AS DATETIME2(3)) -- a raw datetimeoffset
--              silently breaks the Ignition JDBC result read. EVERYTHING below
--              that line is local, and no local value is ever converted back.
--
--              DST: wall-clock windows spanning a transition are 23/25 hours
--              of clock but 22/26 of elapsed time, so an instant inside the
--              repeated 01:00-02:00 hour on fall-back resolves to whichever
--              shift AT TIME ZONE maps it to. Inherited from OI-38, not
--              introduced here.
--
--              -------- CONTRACT --------
--
--              AT MOST ONE ROW.
--                * Zero rows  = no shift runs on this equipment at that instant
--                               (a real answer, NOT an error -- callers leave
--                               ShiftId NULL).
--                * One row with ShiftId NOT NULL = the attribution.
--                * One row with ShiftId NULL     = a shift is SCHEDULED at that
--                               instant but no Oee.Shift runtime instance exists
--                               for it (never started / never reconciled).
--                               Distinguished deliberately so a caller can tell
--                               "no shift" from "shift not instantiated".
--
--              It maps an instant to an EXISTING Oee.Shift row. It never
--              creates one -- OI-35 B3 (plant-global, single-open Oee.Shift)
--              is untouched. When a press is still on First at 15:00 but
--              First's Oee.Shift row is already closed, that row still exists
--              and is what gets returned.
--
--              The runtime instance for (schedule, business date) is the
--              Oee.Shift row whose CAST(ActualStart AS DATE) = business date.
--              That is the exact inverse of Oee.Shift_GetAvailability's
--              BusinessDate = CAST(s.ActualStart AS DATE), so the two cannot
--              disagree.
--
--              Read-only inline TVF: no OUTPUT params, no audit, no status row.
--
-- Parameters:
--   @LocationId BIGINT       - OEE equipment (die cast press / M&A WorkCenter).
--                              NULL is legal and means "no override lookup" --
--                              the plant-global schedule answer.
--   @InstantUtc DATETIME2(3) - The UTC instant being attributed.
--
-- Result set (0 or 1 row):
--   ShiftId          BIGINT       - Oee.Shift.Id, or NULL (see contract).
--   ShiftScheduleId  BIGINT       - the schedule that covers the instant.
--   ScheduleName     NVARCHAR(100)
--   BusinessDate     DATE         - date the covering window STARTS on.
--   InstantLocal     DATETIME2(3) - the converted probe (diagnostics).
--   StartLocal       DATETIME2(3)
--   EndLocal         DATETIME2(3)
--   IsOverridden     BIT
--   ShiftOverrideId  BIGINT
--
-- Dependencies:
--   Tables: Oee.ShiftSchedule, Oee.Shift
--   Funcs:  Oee.ufn_ShiftWindowForLocation  (deploy-order dependency -- see header)
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (shift-override attribution, sec 4.1).
-- ============================================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftIdForInstant
(
    @LocationId BIGINT,
    @InstantUtc DATETIME2(3)
)
RETURNS TABLE
AS
RETURN
(
    WITH L AS (
        -- THE ONE conversion. UTC -> local Eastern, DST-aware, cast back to
        -- DATETIME2(3) so no datetimeoffset ever escapes this function.
        SELECT CAST(@InstantUtc AT TIME ZONE 'UTC'
                                AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS InstantLocal
    ),
    Spine AS (
        -- (-1, 0) business-date spine: a 02:00 instant belongs to yesterday's
        -- third shift, so yesterday must be probed as well as today.
        SELECT v.BusinessDate
        FROM L
        CROSS APPLY (VALUES
            (CAST(DATEADD(DAY, -1, L.InstantLocal) AS DATE)),
            (CAST(L.InstantLocal AS DATE))
        ) v (BusinessDate)
    ),
    Cand AS (
        SELECT
            w.ShiftScheduleId,
            w.ScheduleName,
            sp.BusinessDate,
            w.StartLocal,
            w.EndLocal,
            w.IsOverridden,
            w.ShiftOverrideId
        FROM Spine sp
        CROSS JOIN Oee.ShiftSchedule ss
        CROSS APPLY Oee.ufn_ShiftWindowForLocation(@LocationId, ss.Id, sp.BusinessDate) w
        WHERE ss.DeprecatedAt IS NULL
          AND ss.EffectiveFrom <= sp.BusinessDate
          -- Bitmask gates the GLOBAL window only; an override asserts its
          -- window regardless of which days the schedule normally runs.
          AND ( w.IsOverridden = 1
                OR ( ss.DaysOfWeekBitmask
                     & CAST(POWER(2, DATEDIFF(DAY, CAST(N'19000101' AS DATE), sp.BusinessDate) % 7) AS INT)
                   ) <> 0 )
    ),
    Hit AS (
        -- Half-open: >= start, < end.
        SELECT TOP 1
            c.ShiftScheduleId, c.ScheduleName, c.BusinessDate,
            c.StartLocal, c.EndLocal, c.IsOverridden, c.ShiftOverrideId,
            l.InstantLocal
        FROM Cand c
        CROSS JOIN L l
        WHERE l.InstantLocal >= c.StartLocal
          AND l.InstantLocal <  c.EndLocal
        -- Override precedence (rule 3); then the later-starting window, then a
        -- stable id tiebreak so the answer is never arbitrary.
        ORDER BY c.IsOverridden DESC, c.StartLocal DESC, c.ShiftScheduleId DESC
    )
    SELECT
        s.ShiftId,
        h.ShiftScheduleId,
        h.ScheduleName,
        h.BusinessDate,
        h.InstantLocal,
        h.StartLocal,
        h.EndLocal,
        h.IsOverridden,
        h.ShiftOverrideId
    FROM Hit h
    -- OUTER APPLY, not INNER JOIN: a covering window with no runtime instance
    -- must still report WHICH schedule covered it (ShiftId NULL), rather than
    -- silently falling through to a lower-priority window that happens to have
    -- an instance.
    OUTER APPLY (
        SELECT TOP 1 sh.Id AS ShiftId
        FROM Oee.Shift sh
        WHERE sh.ShiftScheduleId = h.ShiftScheduleId
          AND CAST(sh.ActualStart AS DATE) = h.BusinessDate
        ORDER BY sh.ActualStart ASC, sh.Id ASC
    ) s
);
GO
