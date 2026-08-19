-- ============================================================
-- Repeatable:  R__Workorder_DieCastSupervisor_GetShiftContext.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-19
-- Version:     1.0
-- Description: Backlog 3.5 (Die Cast supervisor dashboard) -- THE ONE PLACE
--              that answers "which shift is CURRENT and which was PREVIOUS".
--
--              Returns AT MOST TWO rows, tagged by Slot:
--                  Slot = 'Current'   the shift the dashboard's left panel shows
--                  Slot = 'Previous'  the shift the right panel shows
--              Ordered Current first. Empty result set = no Oee.Shift rows at
--              all (a virgin/reset DB) -- NOT an error (FDS-11-011: empty = not
--              found, no invented 404).
--
--              Resolution TODAY (B3 single-open invariant, plant-wide):
--                Current  = the open instance (ActualEnd IS NULL); if none is
--                           open (a scheduling gap -- Shift_Reconcile leaves no
--                           open shift between scheduled instances) fall back to
--                           the most recent instance that STARTED at or before
--                           @AtMoment, so the dashboard still shows the shift
--                           that just ended instead of going blank.
--                Previous = the most recent instance strictly BEFORE Current's
--                           ActualStart.
--              Mirrors BlueRidge.Oee.Shift.defaultEntryShiftId()'s "open, else
--              most recent" rule so the dashboard and the die-cast entry screen
--              never disagree about what "this shift" means.
--
--              FORWARD COMPATIBILITY -- per-equipment shift overrides (backlog
--              6.1) landed concurrently as Oee.ShiftOverride +
--              Oee.ufn_ShiftWindowForLocation(@LocationId, @ShiftScheduleId,
--              @BusinessDate). Checked 2026-08-19: that model overrides a shift's
--              WINDOW for one equipment Location on one business date; it does
--              NOT create per-equipment Oee.Shift instances, so the runtime
--              instance identity this proc returns stays global and correct.
--                * @CellLocationId is ACCEPTED AND DELIBERATELY IGNORED today. It
--                  is the seam, and it is already the right key: the override
--                  table is keyed on the downtime-scope Location, which for die
--                  cast IS the press Cell. If the dashboard ever needs the
--                  press's own window (e.g. to say "shift extended to 08:00"),
--                  CROSS APPLY Oee.ufn_ShiftWindowForLocation here -- the
--                  signature, the two-row contract and every caller stay put.
--                * OPEN QUESTION for Hunter, surfaced by that work: if press A's
--                  first shift is extended past the global boundary, a basket
--                  registered during the extension is stamped by
--                  Workorder.DieCastShiftOutput_Record with whatever ShiftId the
--                  entry screen picked -- i.e. the NEXT global instance. Either
--                  overrides affect OEE availability only (production attribution
--                  stays global -- nothing to change here), or ShiftId stamping
--                  must resolve per equipment too. This proc is agnostic; the
--                  totals proc follows whatever ShiftId was stamped.
--                * The companion totals proc
--                  (Workorder.DieCastSupervisor_GetShiftTotals) takes a
--                  @ShiftId and NEVER resolves "current" itself, and it
--                  aggregates on Workorder.DieCastContribution.ShiftId (an FK
--                  stamped at record time) rather than on a time window -- so a
--                  changed shift WINDOW cannot silently re-bucket production
--                  that was already registered.
--
--              !! TIMESTAMP BASIS -- Oee.Shift IS THE PROJECT'S ONE UTC
--              EXCEPTION. Oee.Shift.ActualStart / ActualEnd are stored in LOCAL
--              (Eastern) wall clock, NOT UTC. This is a deliberate, documented
--              divergence from CLAUDE.md's store-UTC rule -- decision D4 in
--              docs/superpowers/specs/2026-07-31-shift-boundary-reconcile-design.md
--              sec 1.1, logged as OI-38 -- because the whole shift subsystem
--              (Shift_GetActive, Shift_Reconcile, the ticker's system.date.now(),
--              Oee.ShiftOverride) already compares these against the schedule's
--              local TIME(0) columns.
--
--              So ActualStartEt / ActualEndEt are emitted RAW, with NO
--              `AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'`.
--              Applying the usual conversion here shifts a first shift's 06:00
--              start to 02:00 -- silently wrong, and it LOOKS right because it
--              is still a plausible time. Verified against the dev DB
--              2026-08-19: Oee.Shift.ActualStart = 06:00 while
--              SYSUTCDATETIME() = 16:47 / SYSDATETIME() = 12:47.
--
--              Contrast the sibling totals proc: it converts
--              Workorder.DieCastContribution.EventAt, which IS genuine
--              SYSUTCDATETIME() UTC, and therefore DOES need the conversion plus
--              the mandatory CAST back to DATETIME2(3) (a raw datetimeoffset
--              breaks the Ignition JDBC result read -- the NQ logs the call but
--              no rows= line and the bound property is empty).
--
--              Oee.Shift.CreatedAt (DEFAULT SYSUTCDATETIME()) is UTC, unlike
--              ActualStart/ActualEnd on the same row. It is not returned here.
--
--              Read proc: ONE result set, no OUTPUT params, no status row, no
--              transaction, no audit.
--
-- Parameters:
--   @AtMoment       DATETIME2(3) NULL - UTC "now" override (tests). Default now.
--   @CellLocationId BIGINT       NULL - RESERVED for per-equipment shift
--                                       overrides. Ignored in v1.0.
--
-- Result set (Slot ASC by SlotOrder: Current, Previous):
--   Slot, SlotOrder, ShiftId, ShiftScheduleId, ScheduleName, IsOpen,
--   ActualStartEt, ActualEndEt   (already Eastern -- see the basis note above)
--
-- Dependencies: Oee.Shift, Oee.ShiftSchedule
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastSupervisor_GetShiftContext
    @AtMoment       DATETIME2(3) = NULL,
    @CellLocationId BIGINT       = NULL   -- reserved: per-equipment overrides
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Moment DATETIME2(3) = ISNULL(@AtMoment, SYSUTCDATETIME());

    -- Current: the open instance, else the most recent one already started.
    DECLARE @CurrentShiftId BIGINT =
        (SELECT TOP 1 s.Id
         FROM Oee.Shift s
         WHERE s.ActualEnd IS NULL
         ORDER BY s.ActualStart DESC, s.Id DESC);

    IF @CurrentShiftId IS NULL
        SET @CurrentShiftId =
            (SELECT TOP 1 s.Id
             FROM Oee.Shift s
             WHERE s.ActualStart <= @Moment
             ORDER BY s.ActualStart DESC, s.Id DESC);

    DECLARE @CurrentStart DATETIME2(3) =
        (SELECT s.ActualStart FROM Oee.Shift s WHERE s.Id = @CurrentShiftId);

    DECLARE @PreviousShiftId BIGINT =
        (SELECT TOP 1 s.Id
         FROM Oee.Shift s
         WHERE @CurrentStart IS NOT NULL
           AND (s.ActualStart < @CurrentStart
                OR (s.ActualStart = @CurrentStart AND s.Id < @CurrentShiftId))
         ORDER BY s.ActualStart DESC, s.Id DESC);

    SELECT
        v.Slot,
        v.SlotOrder,
        s.Id                                        AS ShiftId,
        s.ShiftScheduleId                           AS ShiftScheduleId,
        ss.Name                                     AS ScheduleName,
        CAST(CASE WHEN s.ActualEnd IS NULL THEN 1 ELSE 0 END AS BIT) AS IsOpen,
        -- NO AT TIME ZONE conversion: these columns are ALREADY local Eastern
        -- (OI-38 / reconcile-design D4). Converting would shift 06:00 -> 02:00.
        s.ActualStart                               AS ActualStartEt,
        s.ActualEnd                                 AS ActualEndEt
    FROM (VALUES (N'Current', 1, @CurrentShiftId),
                 (N'Previous', 2, @PreviousShiftId)) v(Slot, SlotOrder, ShiftId)
    INNER JOIN Oee.Shift          s  ON s.Id  = v.ShiftId
    INNER JOIN Oee.ShiftSchedule  ss ON ss.Id = s.ShiftScheduleId
    ORDER BY v.SlotOrder;
END;
GO
