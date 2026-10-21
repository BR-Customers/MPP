-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_ListMemberResults.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.1
-- Change Log:  2026-10-21 - 1.1 - Piece 6 (spec 3.8): AppliedReturnQty appended LAST, from
--                                 Quality.ufn_ControlledRunMemberResults v1.3 (returns a
--                                 Lots.VendorReturn has already taken off the LOT).
-- Description: READ. The CURRENT members of one super-lot with what the
--              inspection has recorded against each, in the order they joined.
--              Feeds the Results tab (one accordion item per row) and the
--              Sign-off tab's release list.
--
--              Everything a screen might be tempted to work out is a column:
--              LeftOver, HasResult and ReleaseBlockReason come from
--              Quality.ufn_ControlledRunMemberResults (the same function the
--              release proc reads); RankLocationId is where the scrap reason
--              tiles should be ranked for (the super-lot's "made at" location,
--              else where the member is now).
--
--              A separate proc from Quality.ControlledRun_ListMembers on
--              purpose: that one feeds the Members tab and is captured by column
--              list in several tests. No status row, no OUTPUT params
--              (FDS-11-011). Empty set = no current members / unknown run.
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_ListMemberResults
    @Id BIGINT
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
        mr.AcceptedQty,
        mr.ScrapQty,
        mr.ReworkQty,
        mr.ReturnQty,
        mr.UseAsIsQty,
        mr.AppliedScrapQty,
        mr.ResultQty,
        mr.LeftOver,
        mr.HasResult,
        mr.ReleaseBlockReason,
        m.WasCompleteAtJoin,
        COALESCE(r.SelectionLocationId, ms.CurrentLocationId) AS RankLocationId,
        mr.AppliedReturnQty
    FROM Quality.ufn_ControlledRunMemberState(@Id) ms
    INNER JOIN Quality.ufn_ControlledRunMemberResults(@Id) mr ON mr.MemberId = ms.MemberId
    INNER JOIN Quality.ControlledRunMember m                  ON m.Id = ms.MemberId
    INNER JOIN Quality.ControlledRun r                        ON r.Id = ms.ControlledRunId
    LEFT JOIN Parts.Item i                                    ON i.Id = ms.ItemId
    LEFT JOIN Location.Location lo                            ON lo.Id = ms.CurrentLocationId
    WHERE ms.EndedAt IS NULL
    ORDER BY ms.AddedAt ASC, ms.MemberId ASC;
END;
GO
