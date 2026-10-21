-- ============================================================
-- Repeatable:  R__Quality_ufn_zz_ControlledRunMemberState.sql
-- Object:      Quality.ufn_ControlledRunMemberState
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.0
-- Description: One row per member of a super-lot (open and ended), with the
--              things every reader needs and none should re-derive: what to
--              call it, its part and current location, its piece count, and
--              whether it is still CRT-tagged.
--
--              A LOT member reads straight off Lots.Lot. A CONTAINER member is
--              the sum of its tray LOTs' pieces, and is "tagged" while ANY tray
--              LOT is CrtActive (D3 -- the container stands for its trays).
--
--              Used by ControlledRun_List / _Get / _ListMembers (display and
--              totals) and by ControlledRun_RemoveMember / _Close (is anything
--              still tagged?). One definition, so the count on the screen and
--              the count that refuses a close cannot disagree.
--
--              FILE NAME IS ORDER-SENSITIVE: 'zz_' is a deploy-order marker
--              (functions get no deferred name resolution), same convention as
--              R__Lots_ufn_zz_CrtBlocks.sql. Do not "tidy" it.
--
-- Result set:  MemberId, ControlledRunId, LotId, ContainerId, Kind,
--              DisplayName, ItemId, CurrentLocationId, PieceCount, CrtActive,
--              ControlledRunJoinMethodId, AddedAt (UTC), EndedAt (UTC),
--              ControlledRunMemberEndReasonId
-- ============================================================
CREATE OR ALTER FUNCTION Quality.ufn_ControlledRunMemberState (@ControlledRunId BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT
        m.Id AS MemberId,
        m.ControlledRunId,
        m.LotId,
        m.ContainerId,
        CASE WHEN m.ContainerId IS NOT NULL THEN N'Container' ELSE N'Lot' END AS Kind,
        CAST(CASE WHEN m.ContainerId IS NOT NULL THEN N'Container ' + CAST(m.ContainerId AS NVARCHAR(20))
                  ELSE l.LotName END AS NVARCHAR(60)) AS DisplayName,
        COALESCE(c.ItemId, l.ItemId)                       AS ItemId,
        COALESCE(c.CurrentLocationId, l.CurrentLocationId) AS CurrentLocationId,
        CASE WHEN m.ContainerId IS NOT NULL THEN ISNULL(ct.Pieces, 0) ELSE l.PieceCount END AS PieceCount,
        CONVERT(BIT, CASE WHEN m.ContainerId IS NOT NULL THEN ISNULL(ct.AnyCrt, 0) ELSE l.CrtActive END) AS CrtActive,
        m.ControlledRunJoinMethodId,
        m.AddedAt,
        m.EndedAt,
        m.ControlledRunMemberEndReasonId
    FROM Quality.ControlledRunMember m
    LEFT JOIN Lots.Lot l       ON l.Id = m.LotId
    LEFT JOIN Lots.Container c ON c.Id = m.ContainerId
    OUTER APPLY (
        SELECT SUM(tl.PieceCount) AS Pieces, MAX(CAST(tl.CrtActive AS INT)) AS AnyCrt
        FROM Lots.ContainerTray t
        INNER JOIN Lots.Lot tl ON tl.Id = t.FinishedGoodLotId
        WHERE t.ContainerId = m.ContainerId
    ) ct
    WHERE m.ControlledRunId = @ControlledRunId
);
GO
