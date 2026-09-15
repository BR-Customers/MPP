-- ============================================================
-- 2026-09-14_cavity_part_mapping_evidence.sql
--
-- READ-ONLY. No writes, no temp tables, no transaction.
-- Safe to run against MPP_MES_Prod during production.
--
-- Supports the cavity-to-part mapping reconciliation
-- (spec 2026-09-14-diecast-quantity-and-scrap-model-design.md sec 12).
--
-- Returns TWO result sets:
--   A. Every active cavity on every active die, its current part, and the
--      SHAPE of its die (single-part vs family).
--   B. For each UNMAPPED active cavity, the ranked evidence:
--        E1  LOT history       -- what this cavity has actually cast (recorded)
--        E2  Eligible parts    -- at the press it is mounted on, OR ANY ANCESTOR
--        E3  Sibling consensus -- meaningful ONLY on a single-part die
--      Name matching is deliberately NOT computed. It is the weakest signal
--      and produces confident wrong answers.
--
-- READ THIS BEFORE INTERPRETING SET A:
--   A cavity LETTER is unique per (Tool, Item, CavityCode), not per tool. On a
--   family die the same letter repeats once per part -- 6MA-B on Dev is 11 rows
--   = 3 letters x 4 parts. Set A is therefore ordered by PART then letter, the
--   same fix DieCast_GetShiftOutputBreakdown v2.2 made for the same reason.
--
-- CAVEAT on E2: eligibility is authored at the Area / WorkCenter tiers, never
--   on the Cell, so this walks the ancestor chain up from the press. That makes
--   it BROAD -- treat a count of 1 as signal and anything higher as context.
--   It is also eligibility only, not "has a published DieCast route".
-- ============================================================
SET NOCOUNT ON;

-- ---------- A. The gap, and the shape of each die ----------
WITH DieShape AS (
    SELECT tc.ToolId,
           COUNT(*)                                           AS Cavities,
           COUNT(DISTINCT tc.ItemId)                          AS MappedParts,
           COUNT(DISTINCT tc.CavityCode)                      AS Letters,
           SUM(CASE WHEN tc.ItemId IS NULL THEN 1 ELSE 0 END) AS Unmapped
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
    WHERE tc.DeprecatedAt IS NULL AND sc.Code = N'Active'
    GROUP BY tc.ToolId
)
SELECT
    t.Code                AS Die,
    t.Name                AS DieName,
    ISNULL(i.PartNumber, N'** UNMAPPED **') AS CurrentPart,
    tc.CavityCode         AS Cav,
    tc.Description        AS CavDesc,
    ds.Cavities,
    ds.Letters,
    ds.MappedParts,
    ds.Unmapped,
    CASE WHEN ds.MappedParts >  1 THEN N'FAMILY'
         WHEN ds.MappedParts =  1 THEN N'single'
         ELSE                          N'(none mapped)'
    END                   AS DieShape
FROM Tools.ToolCavity tc
INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
INNER JOIN Tools.Tool   t  ON t.Id  = tc.ToolId
INNER JOIN DieShape     ds ON ds.ToolId = tc.ToolId
LEFT  JOIN Parts.Item   i  ON i.Id  = tc.ItemId
WHERE tc.DeprecatedAt IS NULL
  AND sc.Code = N'Active'
  AND t.DeprecatedAt IS NULL
ORDER BY t.Code, ISNULL(i.PartNumber, N'zzz'), tc.CavityCode;


-- ---------- B. Ranked evidence per UNMAPPED active cavity ----------
WITH Cav AS (
    SELECT tc.Id, tc.ToolId, tc.CavityCode, tc.Description AS CavDesc,
           t.Code AS Die, t.Name AS DieName
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
    INNER JOIN Tools.Tool t ON t.Id = tc.ToolId
    WHERE tc.DeprecatedAt IS NULL
      AND sc.Code = N'Active'
      AND t.DeprecatedAt IS NULL
      AND tc.ItemId IS NULL
),
Mount AS (                       -- the press this die is on right now
    SELECT a.ToolId, a.CellLocationId,
           ROW_NUMBER() OVER (PARTITION BY a.ToolId
                              ORDER BY a.AssignedAt DESC, a.Id DESC) AS rn
    FROM Tools.ToolAssignment a
    WHERE a.ReleasedAt IS NULL
),
MountedCell AS (
    SELECT DISTINCT m.CellLocationId
    FROM Mount m
    WHERE m.rn = 1 AND m.CellLocationId IS NOT NULL
),
Anc AS (                         -- press -> WorkCenter -> Area -> Site -> ...
    SELECT mc.CellLocationId AS CellId, l.Id AS AncId, l.ParentLocationId
    FROM MountedCell mc
    INNER JOIN Location.Location l ON l.Id = mc.CellLocationId
    UNION ALL
    SELECT a.CellId, p.Id, p.ParentLocationId
    FROM Anc a
    INNER JOIN Location.Location p ON p.Id = a.ParentLocationId
),
Sib AS (                         -- what the die's OTHER cavities are mapped to
    SELECT tc.ToolId,
           COUNT(DISTINCT tc.ItemId) AS DistinctParts,
           MIN(tc.ItemId)            AS SoleItemId
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
    WHERE tc.DeprecatedAt IS NULL AND sc.Code = N'Active' AND tc.ItemId IS NOT NULL
    GROUP BY tc.ToolId
)
SELECT
    c.Die,
    c.CavityCode                     AS Cav,
    c.CavDesc,
    -- E1 (near-certain): what this cavity has actually cast
    e1.PartNumber                    AS E1_HistoryPart,
    e1.LotCount                      AS E1_Lots,
    e1.DistinctEver                  AS E1_DistinctEver,
    -- E2 (broad): press + eligible-part count across the ancestor chain
    lc.Code                          AS E2_Press,
    e2.EligibleCount                 AS E2_EligibleCount,
    e2.SolePart                      AS E2_SolePart,
    -- E3 (strong on a single-part die, UNSAFE on a family die)
    CASE WHEN sb.DistinctParts = 1 THEN si.PartNumber END AS E3_SiblingPart,
    ISNULL(sb.DistinctParts, 0)      AS E3_SiblingDistinct,
    CASE WHEN ISNULL(sb.DistinctParts, 0) > 1
         THEN N'FAMILY DIE - use E1 only'
         ELSE N'' END                AS Warning
FROM Cav c
LEFT  JOIN Mount m               ON m.ToolId = c.ToolId AND m.rn = 1
LEFT  JOIN Location.Location lc  ON lc.Id    = m.CellLocationId
OUTER APPLY (
    SELECT TOP 1
           i.PartNumber,
           COUNT(*) AS LotCount,
           (SELECT COUNT(DISTINCT l2.ItemId)
            FROM Lots.Lot l2 WHERE l2.ToolCavityId = c.Id) AS DistinctEver
    FROM Lots.Lot l
    INNER JOIN Parts.Item i ON i.Id = l.ItemId
    WHERE l.ToolCavityId = c.Id
    GROUP BY i.PartNumber
    ORDER BY COUNT(*) DESC
) e1
OUTER APPLY (
    SELECT COUNT(*)                                          AS EligibleCount,
           CASE WHEN COUNT(*) = 1 THEN MAX(i.PartNumber) END AS SolePart
    FROM (SELECT DISTINCT v.ItemId
          FROM Parts.v_EffectiveItemLocation v
          INNER JOIN Anc an ON an.AncId = v.LocationId
          WHERE an.CellId = m.CellLocationId) x
    INNER JOIN Parts.Item i ON i.Id = x.ItemId
) e2
LEFT  JOIN Sib sb ON sb.ToolId = c.ToolId
LEFT  JOIN Parts.Item si ON si.Id = sb.SoleItemId
ORDER BY c.Die, c.CavityCode
OPTION (MAXRECURSION 8);
