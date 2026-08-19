-- ============================================================
-- Repeatable:  R__Oee_ufn_zz_ShiftOverrideConflicts.sql
-- Object:      Oee.ufn_ShiftOverrideConflicts
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
-- Description: OI-4 CONTIGUITY VALIDATION. Given a PROPOSED override window,
--              reports whether accepting it would leave the day's shift windows
--              for that one piece of equipment non-contiguous or ambiguous.
--              Oee.ShiftOverride_Create / _Update reject on a non-clean answer,
--              BEFORE BEGIN TRANSACTION.
--
--              Design D1 requires attribution to be TOTAL (every instant maps to
--              a shift) and UNAMBIGUOUS (to exactly one). Two failure modes:
--
--              (a) OVERLAP OF TWO OVERRIDES. If First is extended to 16:00 AND
--                  Second is separately overridden to still start at 14:30, the
--                  15:00 instant is claimed by two OVERRIDDEN windows and
--                  Oee.ufn_ShiftIdForInstant's precedence rule has nothing to
--                  break the tie with. Rejected.
--
--                  An override overlapping a NON-overridden (plant-global)
--                  window is NOT a conflict -- that is the ordinary extension,
--                  and the resolver's override-precedence rule (D1) is exactly
--                  what makes it unambiguous. Requiring the operator to author
--                  a matching shortening on the neighbour would also be
--                  UNIMPLEMENTABLE: the pair can only ever be created one row at
--                  a time, so a strict "no overlap at all" rule would reject
--                  both halves and no override could ever be created. That is
--                  the one place this function deliberately reads the design's
--                  OI-4 wording ("reject an override that would leave a gap or
--                  overlap") more narrowly than literally -- see the report.
--
--              (b) NEW GAP. Shortening First from 14:30 to 13:00 leaves
--                  13:00-14:30 covered by nothing, so a basket released at 13:30
--                  attributes to no shift at all. Rejected.
--
--                  Measured as a DELTA, not an absolute: total gap minutes in
--                  the day's window set AFTER the change minus BEFORE. A plant
--                  whose schedules already fail to tile the day (a genuine
--                  configuration state) must not have every override rejected
--                  because of a pre-existing hole -- only NEWLY OPENED gap
--                  minutes reject.
--
--              SCOPE. Windows are compared WITHIN one business date's set. A
--              gap between the last window of one date and the first of the
--              next is not detected (the third shift already crosses midnight,
--              so the day sets interlock); cross-date contiguity is left to the
--              resolver's deterministic tiebreak. Deprecate is NOT validated --
--              removing an override reverts the equipment to the plant-global
--              schedule, which is the baseline and cannot introduce a hole the
--              plant does not already have.
--
--              TIME BASIS: LOCAL (Eastern) wall clock throughout (OI-38). No
--              UTC appears in this function at all. EndTime < StartTime crosses
--              midnight and lands on @BusinessDate + 1 -- the same boundary
--              math as Oee.ufn_ShiftWindowForLocation, restated here because
--              the proposed window has no override row to resolve through yet.
--
--              FILE NAME IS ORDER-SENSITIVE -- 'zz_' is a DEPLOY-ORDER MARKER,
--              not part of the object name (Oee.ufn_ShiftOverrideConflicts).
--              A FUNCTION gets no deferred name resolution (Msg 4121) and this
--              one calls Oee.ufn_ShiftWindowForLocation, which sorts later
--              under its own name. See R__Oee_ufn_zz_ShiftIdForInstant.sql.
--
--              Read-only inline TVF: no OUTPUT params, no audit, no status row.
--
-- Parameters:
--   @LocationId      BIGINT  - equipment the override is for. Required.
--   @ShiftScheduleId BIGINT  - shift being overridden. Required.
--   @BusinessDate    DATE    - local date the window starts on. Required.
--   @StartTime       TIME(0) - PROPOSED local start. Required.
--   @EndTime         TIME(0) - PROPOSED local end. Required.
--
-- Result set: exactly one row.
--   NewGapMinutes       INT           - minutes of coverage the change would
--                                       DESTROY. > 0 => reject.
--   OverlapScheduleName NVARCHAR(100) - the other OVERRIDDEN shift the proposal
--                                       would collide with, else NULL.
--                                       NOT NULL => reject.
--
-- Dependencies:
--   Tables: Oee.ShiftSchedule
--   Funcs:  Oee.ufn_ShiftWindowForLocation  (deploy-order dependency)
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (OI-4).
-- ============================================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftOverrideConflicts
(
    @LocationId      BIGINT,
    @ShiftScheduleId BIGINT,
    @BusinessDate    DATE,
    @StartTime       TIME(0),
    @EndTime         TIME(0)
)
RETURNS TABLE
AS
RETURN
(
    WITH Bit AS (
        -- ISO weekday bit (Mon=1 .. Sun=64), @@DATEFIRST-independent:
        -- 1900-01-01 was a Monday.
        SELECT CAST(POWER(2, DATEDIFF(DAY, CAST(N'19000101' AS DATE), @BusinessDate) % 7) AS INT) AS DowBit
    ),
    Eff AS (
        -- BEFORE: the day's effective windows for this equipment as they stand.
        SELECT ss.Id, ss.Name, w.StartTime, w.EndTime, w.IsOverridden,
               CAST(0 AS BIT) AS IsAfter
        FROM Oee.ShiftSchedule ss
        CROSS APPLY Oee.ufn_ShiftWindowForLocation(@LocationId, ss.Id, @BusinessDate) w
        CROSS JOIN Bit b
        WHERE ss.DeprecatedAt IS NULL
          AND ss.EffectiveFrom <= @BusinessDate
          AND (w.IsOverridden = 1 OR (ss.DaysOfWeekBitmask & b.DowBit) <> 0)

        UNION ALL

        -- AFTER: the same set with the PROPOSAL substituted for @ShiftScheduleId.
        -- The proposed shift is always present in the after-set even when the
        -- bitmask excludes the date -- an override asserts its window (Saturday
        -- overtime on one press).
        SELECT ss.Id, ss.Name,
               CASE WHEN ss.Id = @ShiftScheduleId THEN @StartTime      ELSE w.StartTime    END,
               CASE WHEN ss.Id = @ShiftScheduleId THEN @EndTime        ELSE w.EndTime      END,
               CASE WHEN ss.Id = @ShiftScheduleId THEN CAST(1 AS BIT)  ELSE w.IsOverridden END,
               CAST(1 AS BIT)
        FROM Oee.ShiftSchedule ss
        CROSS APPLY Oee.ufn_ShiftWindowForLocation(@LocationId, ss.Id, @BusinessDate) w
        CROSS JOIN Bit b
        WHERE ss.DeprecatedAt IS NULL
          AND ss.EffectiveFrom <= @BusinessDate
          AND (ss.Id = @ShiftScheduleId OR w.IsOverridden = 1 OR (ss.DaysOfWeekBitmask & b.DowBit) <> 0)
    ),
    Bounded AS (
        SELECT
            e.Id, e.Name, e.IsOverridden, e.IsAfter,
            DATEADD(SECOND, DATEDIFF(SECOND, 0, e.StartTime),
                    CAST(@BusinessDate AS DATETIME2(3))) AS StartLocal,
            CASE WHEN e.EndTime > e.StartTime
                 THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, e.EndTime),
                              CAST(@BusinessDate AS DATETIME2(3)))
                 ELSE DATEADD(SECOND, DATEDIFF(SECOND, 0, e.EndTime),
                              CAST(DATEADD(DAY, 1, @BusinessDate) AS DATETIME2(3)))
            END AS EndLocal
        FROM Eff e
    ),
    Seq AS (
        SELECT b.IsAfter, b.EndLocal,
               LEAD(b.StartLocal) OVER (PARTITION BY b.IsAfter ORDER BY b.StartLocal, b.Id) AS NextStartLocal
        FROM Bounded b
    ),
    Gaps AS (
        SELECT s.IsAfter,
               SUM(CASE WHEN s.NextStartLocal IS NOT NULL AND s.NextStartLocal > s.EndLocal
                        THEN DATEDIFF(MINUTE, s.EndLocal, s.NextStartLocal)
                        ELSE 0 END) AS GapMinutes
        FROM Seq s
        GROUP BY s.IsAfter
    )
    SELECT
        (   SELECT ISNULL(MAX(CASE WHEN g.IsAfter = 1 THEN g.GapMinutes END), 0)
                 - ISNULL(MAX(CASE WHEN g.IsAfter = 0 THEN g.GapMinutes END), 0)
            FROM Gaps g
        ) AS NewGapMinutes,
        (   SELECT TOP 1 x.Name
            FROM Bounded a
            INNER JOIN Bounded x
                    ON x.IsAfter = 1
                   AND x.Id <> a.Id
                   AND x.IsOverridden = 1
                   AND a.StartLocal < x.EndLocal
                   AND x.StartLocal < a.EndLocal
            WHERE a.IsAfter = 1
              AND a.Id = @ShiftScheduleId
            ORDER BY x.StartLocal, x.Id
        ) AS OverlapScheduleName
);
GO
