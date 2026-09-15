-- ============================================================
-- 2026-09-14_orphaned_basket_check.sql
--
-- READ-ONLY. No writes, no temp tables, no transaction.
-- Safe to run against MPP_MES_Prod during production.
--
-- WHY THIS EXISTS.
-- Tools.ToolAssignment_Release contains not one line about LOTs, while three
-- subsystems are written against the sentence "a changeover always closes the
-- baskets": Lots.DieCastLot_Release v2.0 derives its closing delta from a press
-- counter reading, and both ufn_DieShotWatermark / ufn_CavityShotWatermark are
-- scoped BY PRESS. Nothing enforces that invariant. It has survived only
-- because the sole release path is a Config Tool screen no operator opens --
-- which the plant-floor mount/release popup is about to change.
--
-- Releasing a die with baskets still Open produces two failure modes:
--
--   A. STRANDED. The die is unmounted, so its open baskets appear on no press
--      screen at all, while staying Open at their last location. The only
--      release path is unreachable. Their pieces are invisible WIP.
--
--   B. MISCREDITED. Re-mount that die on a DIFFERENT press and the baskets
--      surface there -- Lots.Lot_GetOpenByTool takes @ToolId with NO cell
--      filter. Releasing one then credits it against the NEW press's counter
--      chain, whose cavity watermark is press-scoped and therefore resets to 0.
--      A basket can be credited an entire foreign press's reading.
--
-- Run this BEFORE deploying any open-basket guard to ToolAssignment_Release.
-- A guard deployed over pre-existing orphans freezes a die nobody can unmount.
--
-- Set A empty and Set B empty => safe to deploy the guard as a plain block.
-- Either populated => those baskets must be released or voided FIRST.
-- ============================================================
SET NOCOUNT ON;

-- ---------- A. Open baskets on a die that is NOT mounted anywhere ----------
SELECT
    t.Code                AS Die,
    t.Name                AS DieName,
    l.LotName             AS Basket,
    tc.CavityCode         AS Cav,
    i.PartNumber          AS Part,
    l.PieceCount          AS Pieces,
    loc.Code              AS SittingAt,
    CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedEt,
    CAST(l.UpdatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastTouchedEt,
    DATEDIFF(HOUR, l.UpdatedAt, SYSUTCDATETIME())                                             AS HoursStale
FROM Lots.Lot l
INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
INNER JOIN Tools.Tool         t  ON t.Id  = l.ToolId
LEFT  JOIN Tools.ToolCavity   tc ON tc.Id = l.ToolCavityId
LEFT  JOIN Parts.Item         i  ON i.Id  = l.ItemId
LEFT  JOIN Location.Location  loc ON loc.Id = l.CurrentLocationId
WHERE sc.Code = N'Open'
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment a
                  WHERE a.ToolId = l.ToolId AND a.ReleasedAt IS NULL)
ORDER BY t.Code, tc.CavityCode;


-- ---------- B. Open baskets whose die has MOVED to another press ----------
-- The basket was last credited on one press; the die now sits on another. A
-- release here credits against the new press's watermark chain, which starts
-- from zero for this cavity.
SELECT
    t.Code                AS Die,
    l.LotName             AS Basket,
    tc.CavityCode         AS Cav,
    i.PartNumber          AS Part,
    l.PieceCount          AS Pieces,
    creditedAt.Code       AS LastCreditedOnPress,
    mountedAt.Code        AS DieNowMountedOn,
    lastc.LastReading     AS LastReadingOnOldPress,
    CAST(lastc.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastCreditEt
FROM Lots.Lot l
INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
INNER JOIN Tools.Tool         t  ON t.Id  = l.ToolId
LEFT  JOIN Tools.ToolCavity   tc ON tc.Id = l.ToolCavityId
LEFT  JOIN Parts.Item         i  ON i.Id  = l.ItemId
CROSS APPLY (
    SELECT TOP 1 c.CellLocationId, c.ShotCounterReading AS LastReading, c.EventAt
    FROM Workorder.DieCastContribution c
    WHERE c.LotId = l.Id
    ORDER BY c.EventAt DESC, c.Id DESC
) lastc
OUTER APPLY (
    SELECT TOP 1 a.CellLocationId
    FROM Tools.ToolAssignment a
    WHERE a.ToolId = l.ToolId AND a.ReleasedAt IS NULL
    ORDER BY a.AssignedAt DESC, a.Id DESC
) mount
LEFT JOIN Location.Location creditedAt ON creditedAt.Id = lastc.CellLocationId
LEFT JOIN Location.Location mountedAt  ON mountedAt.Id  = mount.CellLocationId
WHERE sc.Code = N'Open'
  AND mount.CellLocationId IS NOT NULL
  AND lastc.CellLocationId IS NOT NULL
  AND mount.CellLocationId <> lastc.CellLocationId
ORDER BY t.Code, tc.CavityCode;


-- ---------- C. Summary ----------
SELECT
    (SELECT COUNT(*) FROM Lots.Lot l
     INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
     WHERE sc.Code = N'Open'
       AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment a
                       WHERE a.ToolId = l.ToolId AND a.ReleasedAt IS NULL))  AS StrandedBaskets,
    (SELECT COUNT(*) FROM Lots.Lot l
     INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
     WHERE sc.Code = N'Open')                                                AS OpenBasketsTotal,
    (SELECT COUNT(*) FROM Tools.Tool t
     WHERE t.DeprecatedAt IS NULL
       AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment a
                       WHERE a.ToolId = t.Id AND a.ReleasedAt IS NULL))      AS UnmountedDies;
