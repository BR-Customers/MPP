-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_GetHeader.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.1
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
--              ActiveCavities IS RESOLVED AS OF THE SHIFT (1.1), by the same
--              half-open overlap Workorder.DieCastShiftReconciliation_Save uses
--              for the die's mount and, since Save 1.7, for its own cavity set.
--              The two MUST agree: the screen computes the total good it expects
--              as (good shots x ActiveCavities - no-good), and the save then
--              recomputes it from its own cavity set and refuses any mismatch.
--              Resolving one as of the shift and the other as of now would make
--              a correctly entered press sheet unsaveable the moment a cavity
--              was deprecated. The full rationale, and the status-history
--              limitation this does NOT fix, are in the Save's header under
--              "THE CAVITIES ARE RESOLVED AS OF THE SHIFT".
--
--              An OPEN shift has no ActualEnd; it takes "now" as its end, the
--              same substitution R__..._ListLots.sql and _ListShifts.sql make.
--
-- Change Log:
--   2026-09-22 - 1.0 - Initial version (die cast shift reconciliation, sec 6.2).
--   2026-09-28 - 1.1 - ActiveCavities counts the cavities that were on the die
--                      DURING the shift, not the ones on it today. Mirrors
--                      Workorder.DieCastShiftReconciliation_Save 1.7.
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
    DECLARE @StartEt DATETIME2(3), @EndEt DATETIME2(3);
    SELECT @StartEt = s.ActualStart, @EndEt = s.ActualEnd FROM Oee.Shift s WHERE s.Id = @ShiftId;
    DECLARE @StartUtc DATETIME2(3) = CAST(@StartEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    DECLARE @EndUtc   DATETIME2(3) = CASE WHEN @EndEt IS NULL THEN SYSUTCDATETIME()
                                          ELSE CAST(@EndEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) END;

    -- AS OF THE SHIFT (1.1) -- the identical predicate
    -- Workorder.DieCastShiftReconciliation_Save 1.7 sec 8 uses. See the header.
    DECLARE @Cavities INT = (SELECT COUNT(*) FROM Tools.ToolCavity tc
                             INNER JOIN Tools.ToolCavityStatusCode cs ON cs.Id = tc.StatusCodeId
                             WHERE tc.ToolId = @ToolId AND cs.Code = N'Active'
                               AND tc.CreatedAt < @EndUtc
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
