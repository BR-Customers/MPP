-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_ListMembers.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.1
-- Change Log:  2026-10-21 - 1.1 - Piece 6 (spec 3.8): WasCompleteAtJoin appended LAST
--                                 (the unit was pulled back from finished stock).
--                                 Callers capture by column list.
-- Description: READ. The members of one super-lot, in the order they joined.
--              @IncludeEnded = 0 (default) returns current members only; 1 also
--              returns members that were removed or ended with the run.
--
--              CrtActive is the member's tag NOW (a container is tagged while
--              any of its tray LOTs is) -- Quality.ufn_ControlledRunMemberState.
--              Timestamps Eastern. No status row, no OUTPUT params (FDS-11-011).
--              Empty set = no members / unknown run.
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_ListMembers
    @Id           BIGINT,
    @IncludeEnded BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ms.MemberId,
        ms.Kind,
        ms.LotId,
        ms.ContainerId,
        ms.DisplayName,
        i.PartNumber,
        lo.Name AS CurrentLocationName,
        ms.PieceCount,
        ms.CrtActive,
        jm.Name AS JoinMethodName,
        CAST(ms.AddedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS AddedAt,
        CAST(ms.EndedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EndedAt,
        er.Name AS EndReasonName,
        m.WasCompleteAtJoin
    FROM Quality.ufn_ControlledRunMemberState(@Id) ms
    INNER JOIN Quality.ControlledRunMember m           ON m.Id  = ms.MemberId
    INNER JOIN Quality.ControlledRunJoinMethod jm      ON jm.Id = ms.ControlledRunJoinMethodId
    LEFT JOIN Quality.ControlledRunMemberEndReason er  ON er.Id = ms.ControlledRunMemberEndReasonId
    LEFT JOIN Parts.Item i                             ON i.Id  = ms.ItemId
    LEFT JOIN Location.Location lo                     ON lo.Id = ms.CurrentLocationId
    WHERE ISNULL(@IncludeEnded, 0) = 1 OR ms.EndedAt IS NULL
    ORDER BY ms.AddedAt ASC, ms.MemberId ASC;
END;
GO
