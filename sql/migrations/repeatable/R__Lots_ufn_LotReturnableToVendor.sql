-- ============================================================
-- Repeatable:  R__Lots_ufn_LotReturnableToVendor.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-20
-- Version:     1.0
-- Change Log:  2026-10-20 - 1.0 - Super-lot piece 5, final review: THE single definition
--                                  of "can this LOT be returned to a vendor".
-- Description: Inline TVF. One row for an existing LOT (no row for an unknown id):
--                LotId, LotName, LotOriginCode, LotStatusCode,
--                CanReturnToVendor BIT, Reason NVARCHAR(500) (NULL when returnable).
--
--              The rule, first failing part is the Reason:
--                1. origin must be Received or ReceivedOffsite (MPP-made material
--                   is never returned to a vendor);
--                2. status must not be Closed, Scrap or Open (Good and Hold pass --
--                   a held box is a prime return candidate).
--              Quantity is NOT part of it: that is per request, checked by the
--              mutation against the LOT's pieces.
--
--              Consumers -- change the rule HERE, never in a caller:
--                * Lots.VendorReturn_Mark (the refusal text is this Reason);
--                * Quality.ControlledRunResult_Record (ReturnToSupplier on a LOT member);
--                * Quality.ControlledRun_ListMemberOrigin (the Results tab's tile);
--                * Lots.VendorReturn_GetEligibility (the LOT Detail vendor-return tab).
--
--              Deploy order: repeatables run alphabetically, so the procs above can
--              be created before this function -- fine, a TVF in FROM / APPLY gets
--              deferred name resolution inside a PROCEDURE. Do NOT reference it from
--              another FUNCTION sorted before it (no deferred resolution there).
--
--              INLINE on purpose so it folds into the caller's plan.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_LotReturnableToVendor (@LotId BIGINT)
RETURNS TABLE
AS RETURN
    SELECT
        l.Id      AS LotId,
        l.LotName AS LotName,
        ot.Code   AS LotOriginCode,
        sc.Code   AS LotStatusCode,
        CAST(CASE WHEN (ot.Code IN (N'Received', N'ReceivedOffsite'))
                   AND (sc.Code NOT IN (N'Closed', N'Scrap', N'Open'))
                  THEN 1 ELSE 0 END AS BIT) AS CanReturnToVendor,
        CAST(CASE WHEN (ISNULL(ot.Code, N'') NOT IN (N'Received', N'ReceivedOffsite'))
                  THEN N'LOT ' + l.LotName + N' was made at MPP; only purchased or received material can be returned to a vendor.'
                  WHEN (sc.Code IN (N'Closed', N'Scrap', N'Open'))
                  THEN N'LOT ' + l.LotName + N' is ' + sc.Name + N' (status ' + sc.Code + N') and cannot be returned to a vendor.'
                  ELSE NULL END AS NVARCHAR(500)) AS Reason
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc      ON sc.Id = l.LotStatusId
    LEFT  JOIN Lots.LotOriginType ot      ON ot.Id = l.LotOriginTypeId
    WHERE l.Id = @LotId;
GO
