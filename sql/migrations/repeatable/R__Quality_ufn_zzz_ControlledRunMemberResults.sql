-- ============================================================
-- Repeatable:  R__Quality_ufn_zzz_ControlledRunMemberResults.sql
-- Object:      Quality.ufn_ControlledRunMemberResults
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-19
-- Version:     1.3
-- Change Log:  2026-10-13 - 1.1 - A container that is being reworked cannot be released (piece 4).
--              2026-10-19 - 1.2 - A LOT member with an OPEN trim rework cannot be released: 'At trim rework' (piece 5).
--              2026-10-19 - 1.3 - AppliedReturnQty (LAST column): live ReturnToSupplier entries a
--                                 Lots.VendorReturn points at; added back in LeftOver (piece 5).
-- Description: One row per member of a super-lot (open and ended) with what the
--              inspection has recorded against it so far, how many pieces are
--              still unaccounted for, and -- the part that must exist exactly
--              once -- whether the member may be released and, if not, why.
--
--              Read by the Results and Sign-off tabs (Quality.ControlledRun_
--              ListMemberResults) AND by Quality.ControlledRun_Release, so the
--              reason shown on the screen and the reason that refuses a release
--              cannot disagree.
--
--              Only LIVE entries count (VoidedAt IS NULL).
--
--              LeftOver = PieceCount + AppliedScrapQty + AppliedReturnQty - ResultQty.
--              Applied scrap and applied returns (a Lots.VendorReturn row points
--              at the entry, not cancelled) have already come out of the LOT's
--              PieceCount, so adding them back gives the pieces the member started
--              with; ResultQty (applied entries included) is what has been
--              accounted for. It is INFORMATION, never
--              a wall (spec D3): it may be above zero at release, and below zero
--              if somebody over-counted.
--
--              ReleaseBlockReason IS NULL means the member may be released:
--                * it is a current member,
--                * it is not at an open trim rework (Lots.LotRework, piece 5),
--                * it has at least one live result, and
--                * if any live result is Use-As-Is, the super-lot carries a
--                  signed deviation.
--
--              FILE NAME IS ORDER-SENSITIVE. 'zzz_' (three) is a deploy-order
--              marker: a function gets no deferred name resolution, and this one
--              reads Quality.ufn_ControlledRunMemberState, whose file is
--              R__Quality_ufn_zz_ControlledRunMemberState.sql. With two z's
--              "MemberResults" would sort BEFORE "MemberState" and a fresh
--              database would fail to build. Do not "tidy" it.
--
-- Result set:  MemberId, AcceptedQty, ScrapQty, ReworkQty, ReturnQty, UseAsIsQty,
--              AppliedScrapQty, ResultQty, LeftOver, HasResult, ReleaseBlockReason,
--              AppliedReturnQty (appended last on purpose: callers capture by column list)
-- ============================================================
CREATE OR ALTER FUNCTION Quality.ufn_ControlledRunMemberResults (@ControlledRunId BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT
        ms.MemberId,
        ISNULL(r.AcceptedQty, 0)     AS AcceptedQty,
        ISNULL(r.ScrapQty, 0)        AS ScrapQty,
        ISNULL(r.ReworkQty, 0)       AS ReworkQty,
        ISNULL(r.ReturnQty, 0)       AS ReturnQty,
        ISNULL(r.UseAsIsQty, 0)      AS UseAsIsQty,
        ISNULL(r.AppliedScrapQty, 0) AS AppliedScrapQty,
        ISNULL(r.ResultQty, 0)       AS ResultQty,
        ISNULL(ms.PieceCount, 0) + ISNULL(r.AppliedScrapQty, 0) + ISNULL(r.AppliedReturnQty, 0) - ISNULL(r.ResultQty, 0) AS LeftOver,
        CONVERT(BIT, CASE WHEN ISNULL(r.Entries, 0) > 0 THEN 1 ELSE 0 END) AS HasResult,
        CAST(CASE
            WHEN ms.EndedAt IS NOT NULL THEN N'No longer in the super-lot'
            -- Piece 5: the LOT was moved back into trim and has not yet been re-run through
            -- Trim OUT. Lots.ufn_OpenLotRework is a Lots-schema file, deployed before this one.
            WHEN ms.LotId IS NOT NULL AND EXISTS (SELECT 1 FROM Lots.ufn_OpenLotRework(ms.LotId))
                THEN N'At trim rework'
            -- Piece 4: parts are out of the box, or it is being refilled. It is released
            -- once it is complete again. A resumed rework container reads Open, so the
            -- test is the rework row, not only the two rework statuses.
            WHEN ms.ContainerId IS NOT NULL AND EXISTS (
                    SELECT 1 FROM Lots.Container c
                    WHERE c.Id = ms.ContainerId
                      AND ( c.ContainerStatusCodeId IN (6, 7)
                         OR (c.ContainerStatusCodeId = 1 AND EXISTS (
                                SELECT 1 FROM Lots.ContainerRework r
                                WHERE r.Id = (SELECT MAX(Id) FROM Lots.ContainerRework WHERE ContainerId = c.Id)
                                  AND r.ResumedAt IS NOT NULL AND r.VoidedAt IS NULL)) ))
                THEN N'Being reworked'
            WHEN ISNULL(r.Entries, 0) = 0 THEN N'No results yet'
            WHEN ISNULL(r.UseAsIsQty, 0) > 0
                 AND NOT EXISTS (SELECT 1 FROM Quality.ControlledRunDeviation d WHERE d.ControlledRunId = ms.ControlledRunId)
                THEN N'Use as is needs a deviation'
        END AS NVARCHAR(100)) AS ReleaseBlockReason,
        ISNULL(r.AppliedReturnQty, 0) AS AppliedReturnQty
    FROM Quality.ufn_ControlledRunMemberState(@ControlledRunId) ms
    OUTER APPLY (
        SELECT COUNT(*) AS Entries,
               SUM(rr.Quantity) AS ResultQty,
               SUM(CASE WHEN dc.Code = N'Accepted'         THEN rr.Quantity ELSE 0 END) AS AcceptedQty,
               SUM(CASE WHEN dc.Code = N'Scrap'            THEN rr.Quantity ELSE 0 END) AS ScrapQty,
               SUM(CASE WHEN dc.Code = N'Rework'           THEN rr.Quantity ELSE 0 END) AS ReworkQty,
               SUM(CASE WHEN dc.Code = N'ReturnToSupplier' THEN rr.Quantity ELSE 0 END) AS ReturnQty,
               SUM(CASE WHEN dc.Code = N'UseAsIs'          THEN rr.Quantity ELSE 0 END) AS UseAsIsQty,
               SUM(CASE WHEN rr.RejectEventId IS NOT NULL  THEN rr.Quantity ELSE 0 END) AS AppliedScrapQty,
               SUM(CASE WHEN vr.Id IS NOT NULL             THEN rr.Quantity ELSE 0 END) AS AppliedReturnQty
        FROM Quality.ControlledRunResult rr
        INNER JOIN Quality.DispositionCode dc ON dc.Id = rr.DispositionCodeId
        -- At most one VendorReturn points at an entry (only Record / Mark write the link).
        LEFT JOIN Lots.VendorReturn vr        ON vr.ControlledRunResultId = rr.Id AND vr.CancelledAt IS NULL
        WHERE rr.ControlledRunMemberId = ms.MemberId AND rr.VoidedAt IS NULL
    ) r
);
GO
