-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_ListMemberRework.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-19
-- Version:     1.0
-- Change Log:  2026-10-19 - 1.0 - Super-lot piece 5: the members that are at trim rework.
-- Description: READ. The CURRENT LOT members of one super-lot that have an OPEN trim
--              rework (Lots.LotRework with no CompletedAt), with when it started (ET)
--              and who approved the move back into trim. Feeds the "At trim rework"
--              chip on the Results and Sign-off tabs.
--
--              A separate proc on purpose: ControlledRun_ListMembers / _ListMemberResults
--              are captured by column list in tests and views, so the rework data does
--              not widen them. Container members never appear (rework is a LOT event).
--
--              StartedAt is stored UTC and returned ET. ApprovedByInitials is NULL when
--              the row carries no approver. No status row, no OUTPUT params (FDS-11-011).
--              Empty set = no member is at rework / unknown run.
--
-- Result set:  MemberId, LotReworkId, StartedAt (ET), ApprovedByInitials
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_ListMemberRework
    @ControlledRunId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ms.MemberId,
        wr.Id AS LotReworkId,
        CAST(wr.StartedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS StartedAt,
        ap.Initials AS ApprovedByInitials
    FROM Quality.ufn_ControlledRunMemberState(@ControlledRunId) ms
    CROSS APPLY Lots.ufn_OpenLotRework(ms.LotId) wr
    INNER JOIN Lots.LotRework lr ON lr.Id = wr.Id
    LEFT JOIN Location.AppUser ap ON ap.Id = lr.ApprovedByUserId
    WHERE ms.EndedAt IS NULL AND ms.LotId IS NOT NULL
    ORDER BY ms.AddedAt ASC, ms.MemberId ASC;
END;
GO
