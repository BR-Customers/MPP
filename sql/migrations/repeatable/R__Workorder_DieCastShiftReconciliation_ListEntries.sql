-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListEntries.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: What is already on record for this shift x press x die, grouped
--              into ENTRIES (spec 2026-09-21 sec 3.7, 6.2).
--
--              Nothing stored identifies one submission: every INSERT called
--              SYSUTCDATETIME() separately, so one entry's rows differ by
--              milliseconds. The grouping is therefore gaps-and-islands: same
--              user, same reconciliation (or none), each row within 10 seconds
--              of the previous one. It is PRESENTATION only -- the move takes
--              explicit row ids, which this proc hands back in
--              ContributionIds / RejectIds, so a wrong grouping can never
--              produce a wrong write.
--
--              EnteredDuringShift is the shift the clock says the entry was
--              made in. For releases typed at the press it is reliable and
--              disagreeing with the filed shift is the tell; for a shift-end
--              entry typed the next morning it is not, which is why the screen
--              shows it as information rather than a suggestion.
--
--              RowCount is bracketed throughout -- it is a reserved word -- but
--              the column the screen binds is named RowCount.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_ListEntries
    @ShiftId        BIGINT,
    @CellLocationId BIGINT,
    @ToolId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @WarmCodeId BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999');

    ;WITH r AS (
        SELECT CAST(N'Contribution' AS NVARCHAR(20)) AS EntityType, c.Id AS EntityId, c.AppUserId,
               c.EventAt AS At, c.ShotCounterReading AS Reading, c.PieceDelta AS Pieces,
               0 AS WarmUp, 0 AS OtherScrap, c.LotId, c.ReconciliationId
        FROM Workorder.DieCastContribution c
        INNER JOIN Lots.Lot l ON l.Id = c.LotId
        WHERE c.ShiftId = @ShiftId AND c.CellLocationId = @CellLocationId AND l.ToolId = @ToolId
        UNION ALL
        SELECT N'Reject', re.Id, re.AppUserId, re.RecordedAt, NULL, 0,
               CASE WHEN re.DefectCodeId = @WarmCodeId THEN re.Quantity ELSE 0 END,
               CASE WHEN re.DefectCodeId = @WarmCodeId THEN 0 ELSE re.Quantity END,
               re.LotId, re.ReconciliationId
        FROM Workorder.RejectEvent re
        WHERE re.ShiftId = @ShiftId AND re.CellLocationId = @CellLocationId AND re.ToolId = @ToolId
    ),
    g AS (
        SELECT r.*,
               CASE WHEN DATEDIFF(SECOND, LAG(r.At) OVER (PARTITION BY r.AppUserId, ISNULL(r.ReconciliationId, 0)
                                                          ORDER BY r.At, r.EntityId), r.At) <= 10
                    THEN 0 ELSE 1 END AS NewGrp
        FROM r
    ),
    k AS (
        SELECT g.*, SUM(g.NewGrp) OVER (PARTITION BY g.AppUserId, ISNULL(g.ReconciliationId, 0)
                                        ORDER BY g.At, g.EntityId ROWS UNBOUNDED PRECEDING) AS Grp
        FROM g
    ),
    e AS (
        SELECT CONCAT(k.AppUserId, N'-', ISNULL(k.ReconciliationId, 0), N'-', k.Grp) AS EntryKey,
               k.AppUserId, k.ReconciliationId,
               MIN(k.At) AS FirstAt, MAX(k.Reading) AS Reading, SUM(k.Pieces) AS Pieces,
               SUM(k.WarmUp) AS WarmUpPieces, SUM(k.OtherScrap) AS OtherScrapPieces,
               COUNT(DISTINCT CASE WHEN k.EntityType = N'Contribution' THEN k.LotId END) AS Lots,
               COUNT(*) AS [RowCount],
               STRING_AGG(CASE WHEN k.EntityType = N'Contribution' THEN CAST(k.EntityId AS NVARCHAR(MAX)) END, N',') AS ContributionIds,
               STRING_AGG(CASE WHEN k.EntityType = N'Reject'       THEN CAST(k.EntityId AS NVARCHAR(MAX)) END, N',') AS RejectIds
        FROM k
        GROUP BY k.AppUserId, k.ReconciliationId, k.Grp
    )
    SELECT e.EntryKey,
           CAST(e.FirstAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EnteredAtEt,
           u.Initials AS EnteredBy,
           e.ReconciliationId,
           ds.ShiftId AS EnteredDuringShiftId,
           ds.ShiftLabel AS EnteredDuringShift,
           e.Reading, e.Pieces, e.Lots, e.WarmUpPieces, e.OtherScrapPieces, e.[RowCount],
           e.ContributionIds, e.RejectIds
    FROM e
    INNER JOIN Location.AppUser u ON u.Id = e.AppUserId
    OUTER APPLY (
        SELECT TOP 1 s.Id AS ShiftId, CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name AS ShiftLabel
        FROM Oee.Shift s
        INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
        WHERE s.ActualStart <= CAST(e.FirstAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
          AND ISNULL(s.ActualEnd, '9999-12-31') > CAST(e.FirstAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
        ORDER BY s.ActualStart DESC) ds
    ORDER BY e.FirstAt;
END;
GO
