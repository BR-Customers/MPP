-- ============================================================
-- Repeatable:  R__Quality_ufn_zzz_OpenControlledRunForLot.sql
-- Object:      Quality.ufn_OpenControlledRunForLot
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.0
-- Description: Super-lot piece 6. The OPEN super-lot a LOT is in, if any: zero or
--              one row (ControlledRunId, RunNumber). Looks at the LOT's own open
--              membership and, for a tray LOT, its container's. A unit has at most
--              one open membership (D4); a container membership wins over a direct
--              one, as ControlledRun_GetOpenByMember always did.
--              FILE NAME IS ORDER-SENSITIVE: 'zzz_' sorts after
--              ufn_zz_ControlledRunMembershipsForLot, which it reads.
-- ============================================================
CREATE OR ALTER FUNCTION Quality.ufn_OpenControlledRunForLot (@LotId BIGINT)
RETURNS TABLE
AS RETURN
    SELECT TOP 1 f.ControlledRunId, f.RunNumber
    FROM Quality.ufn_ControlledRunMembershipsForLot(@LotId) f
    WHERE f.EndedAt IS NULL
    ORDER BY CASE WHEN f.ViaContainerId IS NOT NULL THEN 0 ELSE 1 END, f.ControlledRunMemberId;
GO
