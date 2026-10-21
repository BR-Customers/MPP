-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_ReportMembers.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.0
-- Change Log:  2026-10-21 - 1.0 - Super-lot piece 6: the report's one-row-per-member summary.
-- Description: READ. One row per member of one super-lot -- current AND ended --
--              oldest first, for the super-lot report (spec 3.4, mock 7). A summary,
--              not each member's event history (6b).
--
--              JoinedText  '<join method> <MM/dd>' (ET).
--              LeftText    NULL while the member is still in; else '<end reason> <MM/dd>'.
--              AcceptedQty / ScrapQty come from Quality.ufn_ControlledRunMemberResults
--              (the one definition of per-member results).
--              OtherText   '; '-joined notes, oldest first, each only if it started on or
--                          after the member joined: 'repack <old> -> <new>' (container
--                          rework, old = the serial it had, new = the serial claimed since,
--                          '(none yet)' if not yet re-completed), 'trim rework <MM/dd>'
--                          (LOT), 'returned <qty>' (LOT, non-cancelled vendor returns).
--                          NULL when there is nothing to say.
--
--              Lots.Container has no name column: DisplayName is 'Container <Id>'.
--              No status row, no OUTPUT params (FDS-11-011). Empty set = unknown run.
--
-- Result set:  MemberName, PartNumber, PieceCount, JoinedText, LeftText,
--              AcceptedQty, ScrapQty, OtherText
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_ReportMembers
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ms.DisplayName AS MemberName,
        i.PartNumber,
        ms.PieceCount,
        CAST(jm.Name + N' ' + FORMAT(CAST(ms.AddedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), 'MM/dd') AS NVARCHAR(100)) AS JoinedText,
        CAST(CASE WHEN ms.EndedAt IS NULL THEN NULL
                  ELSE ISNULL(er.Name, N'Ended') + N' ' + FORMAT(CAST(ms.EndedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), 'MM/dd') END AS NVARCHAR(100)) AS LeftText,
        mr.AcceptedQty,
        mr.ScrapQty,
        CAST(notes.Txt AS NVARCHAR(500)) AS OtherText
    FROM Quality.ufn_ControlledRunMemberState(@Id) ms
    INNER JOIN Quality.ufn_ControlledRunMemberResults(@Id) mr ON mr.MemberId = ms.MemberId
    INNER JOIN Quality.ControlledRunJoinMethod jm              ON jm.Id = ms.ControlledRunJoinMethodId
    LEFT JOIN Quality.ControlledRunMemberEndReason er          ON er.Id = ms.ControlledRunMemberEndReasonId
    LEFT JOIN Parts.Item i                                     ON i.Id = ms.ItemId
    OUTER APPLY (
        SELECT STRING_AGG(n.Txt, N'; ') WITHIN GROUP (ORDER BY n.At, n.Seq) AS Txt
        FROM (
            SELECT cr.OpenedAt AS At, 1 AS Seq,
                   N'repack ' + ISNULL(cr.OriginalAimShipperId, N'(no serial)') + N' -> '
                   + ISNULL((SELECT TOP 1 p.AimShipperId FROM Lots.AimShipperIdPool p
                             WHERE p.ConsumedByContainerId = cr.ContainerId AND p.VoidedAt IS NULL
                               AND p.ConsumedAt >= cr.OpenedAt
                               AND (cr.OriginalAimShipperId IS NULL OR p.AimShipperId <> cr.OriginalAimShipperId)
                             ORDER BY p.ConsumedAt DESC, p.Id DESC), N'(none yet)') AS Txt
            FROM Lots.ContainerRework cr
            WHERE cr.ContainerId = ms.ContainerId AND cr.VoidedAt IS NULL AND cr.OpenedAt >= ms.AddedAt
            UNION ALL
            SELECT lr.StartedAt, 2,
                   N'trim rework ' + FORMAT(CAST(lr.StartedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), 'MM/dd')
            FROM Lots.LotRework lr
            WHERE lr.LotId = ms.LotId AND lr.StartedAt >= ms.AddedAt
            UNION ALL
            SELECT MIN(vr.MarkedAt), 3, N'returned ' + CAST(SUM(vr.Quantity) AS NVARCHAR(20))
            FROM Lots.VendorReturn vr
            WHERE vr.LotId = ms.LotId AND vr.CancelledAt IS NULL AND vr.MarkedAt >= ms.AddedAt
            HAVING COUNT(*) > 0
        ) n
    ) notes
    ORDER BY ms.AddedAt ASC, ms.MemberId ASC;
END;
GO