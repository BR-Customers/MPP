-- ============================================================
-- Repeatable:  R__Workorder_DieCastShift_ListUnreconciled.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     2.0
-- Description: The supervisor dashboard's "shifts not reconciled" tile (spec
--              2026-09-21 sec 6.4). One row per CLOSED shift x press x die,
--              under one of TWO claims. The claim is ON THE ROW, in the same
--              StatusCode vocabulary the landing list uses, and only ONE of
--              the two alerts -- so the screen can show, group or suppress
--              either without a SQL change:
--
--                ReleasedNoShiftEnd   IsAlerting = 1. THE finding. Production
--                                     is on record and no shift-end number
--                                     ever followed it: no counter reading on
--                                     any contribution, no counter anchor, no
--                                     reconciliation header. A positive
--                                     finding, not an absence -- those LOTs
--                                     were released with a count and the shift
--                                     was never settled, which is what Machine
--                                     202 did every shift of the week the
--                                     design was written against. This claim
--                                     is unchanged from v1.0.
--
--                NoEntry              IsAlerting = 0. IDLE, informational. A
--                                     die was assigned to the press across the
--                                     whole closed shift and NOTHING was
--                                     recorded: no production, no scrap, no
--                                     counter anchor, no header. Building 2's
--                                     3rd shift on 2026-09-16 -- the case this
--                                     feature was built for -- is exactly this
--                                     shape, and v1.0 could not see it at all.
--
--              WHY NoEntry IS IDLE AND NOT AN ALERT (owner ruling 2026-09-25).
--              Operators may leave a die assigned in the MES until the next one
--              is mounted, so "assigned but nothing recorded" fires constantly
--              -- weekends, prep time, between runs. The owner's chosen
--              discriminator is the SHIFT SHOT TOTAL: when no shot total was
--              ever entered for a shift x press x die that also recorded no
--              production, the press was not actually running, and the row is
--              idle. That is a deliberate signal, NOT an oversight to be fixed
--              later. It is reported so the screen can render it, and flagged
--              IsAlerting = 0 so it can never inflate the count of real work.
--              Do not merge the two claims into one number.
--
--              (The absence of a shot total does NOT make ReleasedNoShiftEnd
--              idle -- that claim has production on record, which is what
--              makes it a finding. The idle rule applies only to rows with
--              nothing recorded at all.)
--
--              Scrap is an EXCLUSION here, not a third source. A shift whose
--              only record is cavity-attributed scrap (0084: RejectEvent
--              carries its own ToolId, LotId nullable) is on the LANDING list
--              -- something was recorded, so it is not NoEntry, and no
--              production was released, so it is not ReleasedNoShiftEnd. The
--              tile is deliberately the narrower read.
--
--              @AtMoment is a UTC "now" override for tests.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShift_ListUnreconciled
    @Days     INT          = 7,
    @AtMoment DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @NowUtc DATETIME2(3) = ISNULL(@AtMoment, SYSUTCDATETIME());
    DECLARE @NowEt  DATETIME2(3) = CAST(@NowUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));
    DECLARE @FromEt DATETIME2(3) = DATEADD(DAY, -@Days, @NowEt);

    ;WITH sh AS (
        -- Closed shifts only. Oee.Shift times are Eastern wall clock (OI-38);
        -- ToolAssignment times are UTC, so the overlap test needs both in UTC.
        SELECT s.Id, s.ActualStart, ss.Name,
               CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) AS StartUtc,
               CAST(s.ActualEnd   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) AS EndUtc
        FROM Oee.Shift s
        INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
        WHERE s.ActualEnd IS NOT NULL AND s.ActualStart >= @FromEt AND s.ActualStart <= @NowEt
    ),
    dies AS (
        -- (a) a die assigned to a die cast press across the shift, half-open
        --     overlap. This arm is what makes the NoEntry claim possible.
        SELECT sh.Id AS ShiftId, ta.CellLocationId, ta.ToolId
        FROM sh
        INNER JOIN Tools.ToolAssignment ta
            ON ta.AssignedAt < sh.EndUtc
           AND ISNULL(ta.ReleasedAt, '9999-12-31') > sh.StartUtc
        INNER JOIN Location.Location loc ON loc.Id = ta.CellLocationId
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = loc.LocationTypeDefinitionId
        WHERE ltd.Code = N'DieCastMachine'
        UNION
        -- (b) a die that produced in the shift.
        SELECT c.ShiftId, c.CellLocationId, l.ToolId
        FROM Workorder.DieCastContribution c
        INNER JOIN Lots.Lot l ON l.Id = c.LotId
        WHERE c.ShiftId IN (SELECT Id FROM sh) AND c.CellLocationId IS NOT NULL AND l.ToolId IS NOT NULL
    )
    SELECT d.ShiftId,
           CONVERT(NVARCHAR(5), sh.ActualStart, 110) + N' ' + sh.Name AS ShiftLabel,
           sh.ActualStart AS StartEt,
           d.CellLocationId, loc.Code AS PressCode, loc.Name AS PressName,
           d.ToolId, t.Code AS AssetNumber, t.Name AS DieName,
           ISNULL(a.Rows, 0) AS ContributionRows, ISNULL(a.Good, 0) AS GoodRecorded,
           CASE WHEN ISNULL(a.Rows, 0) = 0 THEN N'NoEntry' ELSE N'ReleasedNoShiftEnd' END AS StatusCode,
           -- Nothing recorded and no shot total entered = idle, never a count.
           CAST(CASE WHEN ISNULL(a.Rows, 0) = 0 THEN 0 ELSE 1 END AS BIT) AS IsAlerting
    FROM dies d
    INNER JOIN sh ON sh.Id = d.ShiftId
    INNER JOIN Location.Location loc ON loc.Id = d.CellLocationId
    INNER JOIN Tools.Tool t ON t.Id = d.ToolId
    OUTER APPLY (SELECT COUNT(*) AS Rows, SUM(c.PieceDelta) AS Good, COUNT(c.ShotCounterReading) AS Readings
                 FROM Workorder.DieCastContribution c
                 INNER JOIN Lots.Lot l ON l.Id = c.LotId
                 WHERE c.ShiftId = d.ShiftId AND c.CellLocationId = d.CellLocationId AND l.ToolId = d.ToolId) a
    WHERE NOT EXISTS (SELECT 1 FROM Workorder.DieCastCounterAnchor x
                      WHERE x.ShiftId = d.ShiftId AND x.ToolId = d.ToolId AND x.CellLocationId = d.CellLocationId)
      AND NOT EXISTS (SELECT 1 FROM Workorder.DieCastShiftReconciliation h
                      WHERE h.ShiftId = d.ShiftId AND h.ToolId = d.ToolId AND h.CellLocationId = d.CellLocationId)
      AND (
            -- ReleasedNoShiftEnd: production on record, no counter reading.
            (ISNULL(a.Rows, 0) > 0 AND ISNULL(a.Readings, 0) = 0)
            -- NoEntry: nothing at all on record -- scrap counts as something.
         OR (ISNULL(a.Rows, 0) = 0
             AND NOT EXISTS (SELECT 1 FROM Workorder.RejectEvent r
                             WHERE r.ShiftId = d.ShiftId AND r.ToolId = d.ToolId AND r.CellLocationId = d.CellLocationId))
          )
    ORDER BY sh.ActualStart DESC, loc.Code, t.Code;
END;
GO
