-- =============================================
-- Function:    Workorder.ufn_ScaleStationEligibleParts
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Version:     1.0
--
-- Description:
--   The finished goods a By Weight scale station may run right now, and how
--   close each is to ready (spec 2026-10-19 scale station, section 5.1).
--   ONE rule, used by the scale close (via ScaleStation_GetRunningPart), the
--   screen's part picker and the override setter, so they cannot disagree.
--
--   A finished good is ELIGIBLE at the terminal's line when:
--     - it is set up at the line (Parts.v_EffectiveItemLocation, the line or
--       an ancestor) -- stock never makes a part runnable where it isn't;
--     - it has an active By Weight pack-out with PartsPerTray > 0;
--     - at least ONE cast line (child ItemType Component or SubAssembly) is
--       covered (a BOM with no cast line has no cast requirement);
--     - at least 60% of its OTHER BOM lines are covered.
--   COVERED = good stock at the line (status not Closed/Open, not
--   BlocksProduction -- the predicate Assembly_CompleteTray consumes by)
--   of at least QtyPer * PartsPerTray: enough for one tray close.
--   A finished good with NO published BOM (pass-through repack) is one
--   pseudo cast line: its own Received/ReceivedOffsite stock, the rule
--   Parts.Item_ListEligibleFinishedGoodsRanked v1.1 uses.
--
--   ReadyRank 1 = closest to ready: highest ShareCovered (covered lines /
--   all lines), then the earliest-created covering stock, then PartNumber.
--   TraysCovered = whole trays the scarcest line's stock covers.
--
--   The 60% threshold is a constant here, not a setting.
--
-- Parameters:
--   @TerminalLocationId BIGINT - a Terminal (LocationTypeDefinitionId 7).
--                                Its parent is the line.
--
-- Returns: ItemId, PartNumber, Description, PartsPerTray, TraysPerContainer,
--   TargetWeight, ToleranceWeight, LinesTotal, LinesCovered, ShareCovered,
--   CastLinesCovered, TraysCovered, ReadyRank. Eligible rows only.
--
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Workorder.ufn_ScaleStationEligibleParts
(
    @TerminalLocationId BIGINT
)
RETURNS TABLE
AS
RETURN
(
    WITH Line AS (
        SELECT t.ParentLocationId AS LineId
        FROM Location.Location t
        WHERE t.Id = @TerminalLocationId
          AND t.LocationTypeDefinitionId = 7
          AND t.DeprecatedAt IS NULL
          AND t.ParentLocationId IS NOT NULL
    ),
    Fg AS (
        SELECT DISTINCT i.Id AS ItemId, i.PartNumber, i.Description,
               cc.PartsPerTray, cc.TraysPerContainer, cc.TargetWeight, cc.ToleranceWeight,
               ln.LineId
        FROM Line ln
        JOIN Parts.v_EffectiveItemLocation eil
          ON eil.LocationId IN (SELECT a.LocationId FROM Location.ufn_AncestorLocationIds(ln.LineId) a)
        JOIN Parts.Item i      ON i.Id = eil.ItemId AND i.DeprecatedAt IS NULL
        JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood'
        JOIN Parts.ContainerConfig cc
          ON cc.ItemId = i.Id AND cc.ClosureMethod = N'ByWeight'
         AND cc.DeprecatedAt IS NULL AND cc.PartsPerTray > 0
    ),
    FgBom AS (
        SELECT f.*,
               (SELECT TOP 1 b.Id FROM Parts.Bom b
                WHERE b.ParentItemId = f.ItemId AND b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL
                ORDER BY b.VersionNumber DESC) AS BomId
        FROM Fg f
    ),
    Lines AS (
        SELECT fb.ItemId,
               CASE WHEN cit.Code IN (N'Component', N'SubAssembly') THEN 1 ELSE 0 END AS IsCast,
               bl.QtyPer * fb.PartsPerTray AS NeedPerTray,
               ISNULL(st.Avail, 0) AS Avail,
               st.FirstReady
        FROM FgBom fb
        JOIN Parts.BomLine bl  ON bl.BomId = fb.BomId
        JOIN Parts.Item ci     ON ci.Id = bl.ChildItemId
        JOIN Parts.ItemType cit ON cit.Id = ci.ItemTypeId
        OUTER APPLY (
            SELECT SUM(l.InventoryAvailable) AS Avail, MIN(l.CreatedAt) AS FirstReady
            FROM Lots.Lot l
            JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
            WHERE l.ItemId = bl.ChildItemId AND l.CurrentLocationId = fb.LineId
              AND sc.Code NOT IN (N'Closed', N'Open') AND sc.BlocksProduction = 0
              AND l.InventoryAvailable > 0
        ) st
        WHERE fb.BomId IS NOT NULL
        UNION ALL
        -- Pass-through repack: no published BOM -> the part itself, Received stock.
        SELECT fb.ItemId, 1, CAST(fb.PartsPerTray AS DECIMAL(18,4)),
               ISNULL(st.Avail, 0), st.FirstReady
        FROM FgBom fb
        OUTER APPLY (
            SELECT SUM(l.InventoryAvailable) AS Avail, MIN(l.CreatedAt) AS FirstReady
            FROM Lots.Lot l
            JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
            JOIN Lots.LotOriginType o  ON o.Id = l.LotOriginTypeId
            WHERE l.ItemId = fb.ItemId AND l.CurrentLocationId = fb.LineId
              AND o.Code IN (N'Received', N'ReceivedOffsite')
              AND sc.Code NOT IN (N'Closed', N'Open') AND sc.BlocksProduction = 0
              AND l.InventoryAvailable > 0
        ) st
        WHERE fb.BomId IS NULL
    ),
    Agg AS (
        SELECT ItemId,
               COUNT(*) AS LinesTotal,
               SUM(CASE WHEN Avail >= NeedPerTray THEN 1 ELSE 0 END) AS LinesCovered,
               SUM(IsCast) AS CastLines,
               SUM(CASE WHEN IsCast = 1 AND Avail >= NeedPerTray THEN 1 ELSE 0 END) AS CastLinesCovered,
               SUM(1 - IsCast) AS OtherLines,
               SUM(CASE WHEN IsCast = 0 AND Avail >= NeedPerTray THEN 1 ELSE 0 END) AS OtherCovered,
               MIN(CAST(FLOOR(Avail / NULLIF(NeedPerTray, 0)) AS INT)) AS TraysCovered,
               MIN(FirstReady) AS FirstReady
        FROM Lines
        GROUP BY ItemId
    )
    SELECT f.ItemId, f.PartNumber, f.Description, f.PartsPerTray, f.TraysPerContainer,
           f.TargetWeight, f.ToleranceWeight,
           a.LinesTotal, a.LinesCovered,
           CAST(a.LinesCovered * 1.0 / a.LinesTotal AS DECIMAL(5,4)) AS ShareCovered,
           a.CastLinesCovered,
           ISNULL(a.TraysCovered, 0) AS TraysCovered,
           ROW_NUMBER() OVER (ORDER BY a.LinesCovered * 1.0 / a.LinesTotal DESC,
                                       a.FirstReady ASC, f.PartNumber ASC) AS ReadyRank
    FROM Fg f
    JOIN Agg a ON a.ItemId = f.ItemId
    WHERE (a.CastLines = 0 OR a.CastLinesCovered >= 1)
      AND (a.OtherLines = 0 OR a.OtherCovered * 1.0 / a.OtherLines >= 0.6)
);
GO
