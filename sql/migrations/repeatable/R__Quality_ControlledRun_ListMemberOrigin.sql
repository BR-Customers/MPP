-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_ListMemberOrigin.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-20
-- Version:     1.1
-- Change Log:  2026-10-20 - 1.0 - Super-lot piece 5: where each member's material
--                                  came from, so the Results tab offers "Return to
--                                  vendor" only where it can be recorded.
--              2026-10-20 - 1.1 - Final review: CanReturnToVendor comes from
--                                  Lots.ufn_LotReturnableToVendor, the one rule shared with
--                                  VendorReturn_Mark / ControlledRunResult_Record. LOT status
--                                  is now part of it (a Closed / Scrap / Open member gets no
--                                  tile, matching what Record would refuse).
-- Description: READ. The CURRENT members of one super-lot with the LOT's origin code
--              (Lots.LotOriginType.Code) and CanReturnToVendor.
--
--              CanReturnToVendor is 1 for a LOT member that Lots.ufn_LotReturnableToVendor
--              accepts (origin Received / ReceivedOffsite AND status not Closed / Scrap /
--              Open), else 0 -- a container member is always 0 (Record's container
--              refusal). Same function as Lots.VendorReturn_Mark and
--              Quality.ControlledRunResult_Record, so the tile and the save agree.
--
--              A separate proc on purpose: ControlledRun_ListMembers /
--              _ListMemberResults / _ListMemberRework are captured by column list in
--              tests, so the origin does not widen them.
--
--              No status row, no OUTPUT params (FDS-11-011). Empty set = no current
--              members / unknown run.
--
-- Result set:  MemberId, LotOriginCode (NULL for a container), CanReturnToVendor
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_ListMemberOrigin
    @ControlledRunId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ms.MemberId,
        lo.Code AS LotOriginCode,
        CAST(CASE WHEN (ms.ContainerId IS NULL) AND (rv.CanReturnToVendor = 1)
                  THEN 1 ELSE 0 END AS BIT) AS CanReturnToVendor
    FROM Quality.ufn_ControlledRunMemberState(@ControlledRunId) ms
    LEFT JOIN Lots.Lot l             ON l.Id  = ms.LotId
    LEFT JOIN Lots.LotOriginType lo  ON lo.Id = l.LotOriginTypeId
    OUTER APPLY Lots.ufn_LotReturnableToVendor(ms.LotId) rv
    WHERE ms.EndedAt IS NULL
    ORDER BY ms.AddedAt ASC, ms.MemberId ASC;
END;
GO
