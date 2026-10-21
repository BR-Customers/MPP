-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_ListByLot.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.0
-- Description: READ. Super-lot piece 6 (spec 3.1) -- LOT Detail's Super-lots tab.
--              Every super-lot membership this LOT has had, open and ended, NEWEST
--              FIRST (AddedAt DESC): as a LOT member itself, or as a tray LOT of a
--              container that was a member while the tray was in it. Rows come from
--              Quality.ufn_ControlledRunMembershipsForLot -- THE fold; nothing here
--              re-derives which memberships count. A LOT that re-joined after being
--              removed has one row per membership.
--
--              MembershipState: Open | Released | Removed | Closed | Cancelled, from
--                Quality.ufn_ControlledRunMembershipState (ContainerVoided reads
--                Removed; LeftReason says which).
--              LeftReason: the end reason's name, plus ': <remarks>' when there are any.
--              ResultsText: this membership's LIVE result entries (VoidedAt IS NULL), in
--                entry order, '<Disposition> <qty>[ (<Defect>)]' joined with ', ' --
--                the same words the per-LOT 'Result recorded' row uses. NULL = none.
--              DeviationNumbers: the run's deviations raised while this membership
--                was open (AddedAt <= RaisedAt AND (EndedAt IS NULL OR RaisedAt <
--                EndedAt) -- the cover rule of ControlledRun_Release), ', '-joined.
--              ViaContainerName: 'Container <Id>' when the LOT is in it as a tray.
--
--              Times Eastern. No status row, no OUTPUT params (FDS-11-011).
--              Empty set = never in a super-lot (or unknown LOT).
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_ListByLot
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        f.ControlledRunId,
        f.RunNumber,
        r.Reason,
        sc.Code AS RunStatusCode,
        st.MembershipState,
        jm.Name AS JoinMethodName,
        CAST(f.AddedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS JoinedAt,
        CAST(f.EndedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LeftAt,
        CAST(er.Name + ISNULL(N': ' + NULLIF(LTRIM(RTRIM(m.EndRemarks)), N''), N'') AS NVARCHAR(700)) AS LeftReason,
        res.ResultsText,
        ru.Initials AS ReleasedByInitials,
        CAST(rl.ReleasedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ReleasedAt,
        dev.DeviationNumbers,
        CAST(CASE WHEN f.ViaContainerId IS NOT NULL THEN N'Container ' + CAST(f.ViaContainerId AS NVARCHAR(20)) END AS NVARCHAR(60)) AS ViaContainerName
    FROM Quality.ufn_ControlledRunMembershipsForLot(@LotId) f
    INNER JOIN Quality.ControlledRunMember m           ON m.Id  = f.ControlledRunMemberId
    INNER JOIN Quality.ControlledRun r                 ON r.Id  = f.ControlledRunId
    INNER JOIN Quality.ControlledRunStatusCode sc      ON sc.Id = r.ControlledRunStatusId
    INNER JOIN Quality.ControlledRunJoinMethod jm      ON jm.Id = m.ControlledRunJoinMethodId
    LEFT JOIN Quality.ControlledRunMemberEndReason er  ON er.Id = m.ControlledRunMemberEndReasonId
    LEFT JOIN Quality.ControlledRunRelease rl          ON rl.Id = m.ControlledRunReleaseId
    LEFT JOIN Location.AppUser ru                      ON ru.Id = rl.ReleasedByUserId
    OUTER APPLY Quality.ufn_ControlledRunMembershipState(m.Id) st
    OUTER APPLY (
        SELECT STRING_AGG(CAST(dc.Name + N' ' + CAST(rr.Quantity AS NVARCHAR(10))
                               + ISNULL(N' (' + df.Description + N')', N'') AS NVARCHAR(MAX)), N', ')
                   WITHIN GROUP (ORDER BY rr.Id) AS ResultsText
        FROM Quality.ControlledRunResult rr
        INNER JOIN Quality.DispositionCode dc ON dc.Id = rr.DispositionCodeId
        LEFT JOIN Quality.DefectCode df       ON df.Id = rr.DefectCodeId
        WHERE rr.ControlledRunMemberId = m.Id AND rr.VoidedAt IS NULL
    ) res
    OUTER APPLY (
        SELECT STRING_AGG(CAST(d.DeviationNumber AS NVARCHAR(MAX)), N', ')
                   WITHIN GROUP (ORDER BY d.RaisedAt, d.Id) AS DeviationNumbers
        FROM Quality.ControlledRunDeviation d
        WHERE d.ControlledRunId = m.ControlledRunId
          AND m.AddedAt <= d.RaisedAt AND (m.EndedAt IS NULL OR d.RaisedAt < m.EndedAt)
    ) dev
    ORDER BY f.AddedAt DESC, f.ControlledRunMemberId DESC;
END;
GO
