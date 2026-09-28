-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_GetHeader.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.2
-- Description: What the reconciliation screen puts in its banner and its
--              Recorded column (spec 2026-09-21 sec 6.2, amendment A6).
--              ONE result set, no OUTPUT params; an empty result set means the
--              shift, press or die does not exist.
--
--              Oee.Shift times are Eastern already (OI-38) and are returned
--              raw. Everything else here is a count, not a time.
--
--              RecordedTotalShots is the die watermark -- anchor-aware, so a
--              previous reconciliation's declared total is what shows.
--              RecordedWarmUpShots divides the 999 pieces by the cavity count,
--              which is how they were fanned out in the first place.
--
--              ActiveCavities KEEPS A CAVITY THAT WAS DEPRECATED AFTER THE
--              SHIFT (1.1), by the same DeprecatedAt half Workorder.DieCast
--              ShiftReconciliation_Save uses for its own cavity set. The two
--              MUST agree: the screen computes the total good it expects as
--              (good shots x ActiveCavities - no-good), and the save then
--              recomputes it from its own cavity set and refuses any mismatch.
--              Resolving one one way and the other another would make a
--              correctly entered press sheet unsaveable the moment a cavity was
--              deprecated. The full rationale -- including WHY THERE IS NO
--              CreatedAt LOWER BOUND, which is a measured decision and not an
--              omission -- is in the Save's header under "A CAVITY DEPRECATED
--              AFTER THE SHIFT STILL COUNTS FOR IT".
--
--              THERE IS NO @EndUtc HERE (1.2). Until 1.2 this proc computed the
--              shift's end in UTC for a `tc.CreatedAt < @EndUtc` bound that has
--              since been dropped; with that bound gone nothing else in this
--              proc needs the end of the shift, so the variable went with it.
--              Do not reintroduce either. See the Save's header.
--
-- Change Log:
--   2026-09-22 - 1.0 - Initial version (die cast shift reconciliation, sec 6.2).
--   2026-09-28 - 1.1 - ActiveCavities counts the cavities that were on the die
--                      DURING the shift, not the ones on it today. Mirrors
--                      Workorder.DieCastShiftReconciliation_Save 1.7.
--   2026-09-28 - 1.2 - Drop the `tc.CreatedAt < @EndUtc` half of 1.1's window
--                      (and the now-dead @EndEt/@EndUtc that served it). 1.1
--                      shipped an interval overlap; measurement against a
--                      production snapshot the same day showed the CreatedAt
--                      half excludes real cavities wholesale -- 88 of prod's 149
--                      cavities across 17 dies were configured on 2026-09-17
--                      itself, so ActiveCavities returned 0 for the 2026-09-16
--                      night shift this feature exists to fix, and the screen
--                      had no expectation to compute at all. Mirrors
--                      Workorder.DieCastShiftReconciliation_Save 1.8, whose
--                      header carries the evidence and the reasoning.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_GetHeader
    @ShiftId        BIGINT,
    @CellLocationId BIGINT,
    @ToolId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @WarmCodeId BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999');

    -- Oee.Shift is Eastern wall clock (OI-38); Tools.ToolCavity's stamps are UTC.
    DECLARE @StartEt DATETIME2(3);
    SELECT @StartEt = s.ActualStart FROM Oee.Shift s WHERE s.Id = @ShiftId;
    DECLARE @StartUtc DATETIME2(3) = CAST(@StartEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

    -- The identical predicate Workorder.DieCastShiftReconciliation_Save sec 8
    -- builds @ActiveCav from. A cavity deprecated AFTER the shift still counts
    -- for it; there is NO CreatedAt lower bound, deliberately -- see the header
    -- and the Save's, which carries the production measurement behind it.
    DECLARE @Cavities INT = (SELECT COUNT(*) FROM Tools.ToolCavity tc
                             INNER JOIN Tools.ToolCavityStatusCode cs ON cs.Id = tc.StatusCodeId
                             WHERE tc.ToolId = @ToolId AND cs.Code = N'Active'
                               AND (tc.DeprecatedAt IS NULL OR tc.DeprecatedAt > @StartUtc));

    SELECT
        s.Id                                                              AS ShiftId,
        CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name         AS ShiftLabel,
        s.ActualStart                                                     AS StartEt,
        s.ActualEnd                                                       AS EndEt,
        CAST(CASE WHEN s.ActualEnd IS NULL THEN 1 ELSE 0 END AS BIT)      AS IsOpen,
        loc.Id                                                            AS CellLocationId,
        loc.Code                                                          AS PressCode,
        loc.Name                                                          AS PressName,
        t.Id                                                              AS ToolId,
        t.Code                                                            AS AssetNumber,
        t.Name                                                            AS DieName,
        @Cavities                                                         AS ActiveCavities,
        t.ShotCount                                                       AS DieShotCount,
        Workorder.ufn_DieShotWatermark(t.Id, s.Id, loc.Id)                AS RecordedTotalShots,
        CASE WHEN @Cavities > 0 THEN ISNULL(sc.WarmUpPieces, 0) / @Cavities ELSE 0 END AS RecordedWarmUpShots,
        ISNULL(sc.NoGoodPieces, 0)                                        AS RecordedNoGood,
        ISNULL(cr.Good, 0)                                                AS RecordedGood,
        CAST(CASE WHEN cr.Readings > 0 OR an.Anchors > 0 THEN 1 ELSE 0 END AS BIT) AS HasShiftEndNumber,
        Workorder.ufn_DieCastShiftStamp(s.Id, loc.Id, t.Id)               AS Stamp,
        lr.LastReconciledAtEt,
        lr.LastReconciledBy
    FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
    INNER JOIN Location.Location loc ON loc.Id = @CellLocationId
    INNER JOIN Tools.Tool t ON t.Id = @ToolId
    OUTER APPLY (SELECT ISNULL(SUM(c.PieceDelta), 0) AS Good, COUNT(c.ShotCounterReading) AS Readings
                 FROM Workorder.DieCastContribution c INNER JOIN Lots.Lot l ON l.Id = c.LotId
                 WHERE c.ShiftId = s.Id AND c.CellLocationId = loc.Id AND l.ToolId = t.Id) cr
    OUTER APPLY (SELECT ISNULL(SUM(CASE WHEN r.DefectCodeId = @WarmCodeId THEN r.Quantity ELSE 0 END), 0) AS WarmUpPieces,
                        ISNULL(SUM(CASE WHEN r.DefectCodeId = @WarmCodeId THEN 0 ELSE r.Quantity END), 0) AS NoGoodPieces
                 FROM Workorder.RejectEvent r
                 WHERE r.ShiftId = s.Id AND r.CellLocationId = loc.Id AND r.ToolId = t.Id) sc
    OUTER APPLY (SELECT COUNT(*) AS Anchors FROM Workorder.DieCastCounterAnchor a
                 WHERE a.ShiftId = s.Id AND a.ToolId = t.Id AND a.CellLocationId = loc.Id) an
    OUTER APPLY (SELECT TOP 1
                        CAST(h.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastReconciledAtEt,
                        u.Initials AS LastReconciledBy
                 FROM Workorder.DieCastShiftReconciliation h
                 INNER JOIN Location.AppUser u ON u.Id = h.AppUserId
                 WHERE h.ShiftId = s.Id AND h.CellLocationId = loc.Id AND h.ToolId = t.Id
                 ORDER BY h.CreatedAt DESC, h.Id DESC) lr
    WHERE s.Id = @ShiftId;
END;
GO
