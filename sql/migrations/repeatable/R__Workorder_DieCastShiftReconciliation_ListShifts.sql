-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListShifts.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: The reconciliation landing list: the last @Days of shifts on
--              one press, one row per die that was mounted during the shift or
--              produced in it (spec 2026-09-21 sec 6.1). Newest first; nothing
--              is pre-selected on screen.
--
--              StatusCode, and what each one MEANS:
--                Open               the live screen owns it -- not reconcilable
--                Reconciled         a reconciliation header exists
--                ReleasedNoShiftEnd production recorded, no counter reading and
--                                   no anchor: the amber case, and the same
--                                   rule the dashboard tile counts
--                EntryRecorded      a shift-end number is on record
--                NoEntry            nothing recorded -- NEUTRAL. The MES cannot
--                                   tell a missed entry from a press that did
--                                   not run, and colouring that amber would
--                                   train people to ignore amber.
--
--              @AtMoment is a UTC "now" override for tests.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_ListShifts
    @CellLocationId BIGINT,
    @Days           INT          = 7,
    @AtMoment       DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @NowUtc DATETIME2(3) = ISNULL(@AtMoment, SYSUTCDATETIME());
    DECLARE @NowEt  DATETIME2(3) = CAST(@NowUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));
    DECLARE @FromEt DATETIME2(3) = DATEADD(DAY, -@Days, @NowEt);

    ;WITH sh AS (
        SELECT s.Id, s.ActualStart, s.ActualEnd, ss.Name,
               CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) AS StartUtc,
               CASE WHEN s.ActualEnd IS NULL THEN @NowUtc
                    ELSE CAST(s.ActualEnd AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) END AS EndUtc
        FROM Oee.Shift s
        INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
        WHERE s.ActualStart >= @FromEt AND s.ActualStart <= @NowEt
    ),
    dies AS (
        SELECT sh.Id AS ShiftId, ta.ToolId
        FROM sh
        INNER JOIN Tools.ToolAssignment ta
            ON ta.CellLocationId = @CellLocationId
           AND ta.AssignedAt < sh.EndUtc
           AND ISNULL(ta.ReleasedAt, '9999-12-31') > sh.StartUtc
        UNION
        SELECT c.ShiftId, l.ToolId
        FROM Workorder.DieCastContribution c
        INNER JOIN Lots.Lot l ON l.Id = c.LotId
        WHERE c.CellLocationId = @CellLocationId AND c.ShiftId IN (SELECT Id FROM sh) AND l.ToolId IS NOT NULL
    )
    SELECT sh.Id AS ShiftId,
           CONVERT(NVARCHAR(5), sh.ActualStart, 110) + N' ' + sh.Name AS ShiftLabel,
           sh.ActualStart AS StartEt, sh.ActualEnd AS EndEt,
           t.Id AS ToolId, t.Code AS AssetNumber, t.Name AS DieName,
           ISNULL(a.Rows, 0) AS ContributionRows, ISNULL(a.Good, 0) AS GoodRecorded,
           Workorder.ufn_DieShotWatermark(t.Id, sh.Id, @CellLocationId) AS ShiftEndReading,
           CASE WHEN sh.ActualEnd IS NULL                                THEN N'Open'
                WHEN lr.CreatedAt IS NOT NULL                            THEN N'Reconciled'
                WHEN ISNULL(a.Rows, 0) = 0                               THEN N'NoEntry'
                WHEN ISNULL(a.Readings, 0) = 0 AND ISNULL(an.Anchors, 0) = 0 THEN N'ReleasedNoShiftEnd'
                ELSE N'EntryRecorded' END AS StatusCode,
           lr.Initials AS ReconciledBy,
           CAST(lr.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ReconciledAtEt
    FROM dies d
    INNER JOIN sh ON sh.Id = d.ShiftId
    INNER JOIN Tools.Tool t ON t.Id = d.ToolId
    OUTER APPLY (SELECT COUNT(*) AS Rows, SUM(c.PieceDelta) AS Good, COUNT(c.ShotCounterReading) AS Readings
                 FROM Workorder.DieCastContribution c
                 INNER JOIN Lots.Lot l ON l.Id = c.LotId
                 WHERE c.ShiftId = sh.Id AND c.CellLocationId = @CellLocationId AND l.ToolId = t.Id) a
    OUTER APPLY (SELECT COUNT(*) AS Anchors FROM Workorder.DieCastCounterAnchor x
                 WHERE x.ShiftId = sh.Id AND x.ToolId = t.Id AND x.CellLocationId = @CellLocationId) an
    OUTER APPLY (SELECT TOP 1 h.CreatedAt, u.Initials
                 FROM Workorder.DieCastShiftReconciliation h
                 INNER JOIN Location.AppUser u ON u.Id = h.AppUserId
                 WHERE h.ShiftId = sh.Id AND h.CellLocationId = @CellLocationId AND h.ToolId = t.Id
                 ORDER BY h.CreatedAt DESC, h.Id DESC) lr
    ORDER BY sh.ActualStart DESC, t.Code;
END;
GO
