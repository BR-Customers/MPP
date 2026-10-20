-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_ListMemberOrigin.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-20
-- Version:     1.0
-- Change Log:  2026-10-20 - 1.0 - Super-lot piece 5: where each member's material
--                                  came from, so the Results tab offers "Return to
--                                  vendor" only where it can be recorded.
-- Description: READ. The CURRENT members of one super-lot with the LOT's origin code
--              (Lots.LotOriginType.Code) and CanReturnToVendor.
--
--              CanReturnToVendor is 1 for a LOT member whose origin is Received or
--              ReceivedOffsite, else 0 -- a container member is always 0. It mirrors
--              the origin + container guards of Quality.ControlledRunResult_Record
--              (and Lots.VendorReturn_Mark), which stay authoritative: this only
--              decides whether the tile is shown. LOT status (Closed / Scrap / Open)
--              is deliberately NOT folded in; Record refuses those with a message.
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
        CAST(CASE WHEN (ms.ContainerId IS NULL) AND (ms.LotId IS NOT NULL)
                   AND (lo.Code IN (N'Received', N'ReceivedOffsite'))
                  THEN 1 ELSE 0 END AS BIT) AS CanReturnToVendor
    FROM Quality.ufn_ControlledRunMemberState(@ControlledRunId) ms
    LEFT JOIN Lots.Lot l             ON l.Id  = ms.LotId
    LEFT JOIN Lots.LotOriginType lo  ON lo.Id = l.LotOriginTypeId
    WHERE ms.EndedAt IS NULL
    ORDER BY ms.AddedAt ASC, ms.MemberId ASC;
END;
GO
