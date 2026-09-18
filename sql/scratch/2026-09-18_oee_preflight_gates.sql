-- 2026-09-18 release pre-flight: OEE-enabled locations (0090). READ-ONLY (writes only a #temp table).
-- Run BEFORE the deploy:  sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -I -W -s "|" -i sql\scratch\2026-09-18_oee_preflight_gates.sql
-- Source + full explanation: notes/2026-09-18_prod-release-handoff-oee-enabled-locations.md section 3.
SET NOCOUNT ON;
-- Prelude: the set 0090 WILL flag (mirror of 0090 section 2).
IF OBJECT_ID('tempdb..#WillFlag') IS NOT NULL DROP TABLE #WillFlag;
;WITH Tree AS (
    SELECT l.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN l.Id END AS BIGINT) AS NearestWorkCenterId
    FROM Location.Location l
    JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE l.ParentLocationId IS NULL
    UNION ALL
    SELECT c.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN c.Id ELSE t.NearestWorkCenterId END AS BIGINT)
    FROM Location.Location c
    JOIN Tree t                              ON c.ParentLocationId = t.Id
    JOIN Location.LocationTypeDefinition ltd ON ltd.Id = c.LocationTypeDefinitionId
    JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
)
SELECT l.Id INTO #WillFlag
FROM Location.Location l
JOIN Tree t                              ON t.Id   = l.Id
JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
WHERE l.DeprecatedAt IS NULL
  AND lt.Code IN (N'WorkCenter', N'Cell')
  AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Receiving', N'Scale')
  AND COALESCE(t.NearestWorkCenterId, l.Id) = l.Id
OPTION (MAXRECURSION 20);

-- Gate A -- what the backfill will flag. Read it; its row count is what 0090 prints.
SELECT ltd.Code AS Definition, p.Code AS Parent, l.Code, l.Name
FROM #WillFlag w
JOIN Location.Location l                 ON l.Id   = w.Id
JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
LEFT JOIN Location.Location p            ON p.Id   = l.ParentLocationId
ORDER BY ltd.Code, p.Code, l.Code;

-- Gate B -- downtime (open, or started in the last 30 days) on a location that will NOT be
-- flagged. Expect 0 rows. A row = someone is logging there today and will be refused tomorrow
-- (or has an open event the Downtime Manager will no longer show).
SELECT l.Code, l.Name, ltd.Code AS Definition, COUNT(*) AS Events,
       SUM(CASE WHEN de.EndedAt IS NULL THEN 1 ELSE 0 END) AS StillOpen,
       MAX(de.StartedAt) AS LatestStartUtc
FROM Oee.DowntimeEvent de
JOIN Location.Location l                 ON l.Id   = de.LocationId
JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
WHERE de.VoidedAt IS NULL
  AND (de.EndedAt IS NULL OR de.StartedAt >= DATEADD(DAY, -30, SYSUTCDATETIME()))
  AND NOT EXISTS (SELECT 1 FROM #WillFlag w WHERE w.Id = de.LocationId)
GROUP BY l.Code, l.Name, ltd.Code
ORDER BY Events DESC;

-- Gate C -- per terminal, the Downtime Manager dropdown today (v1.0) vs after (v2.0).
-- Expect 0 LOST rows. A LOST row = that terminal loses a choice it has today; if it was the
-- only choice, the terminal can no longer log downtime at all. GAINED rows: read them.
;WITH Term AS (
    SELECT t.Id AS TerminalId, t.Code AS TerminalCode, p.Id AS ZoneId, p.Code AS ZoneCode, plt.Code AS ZoneTier
    FROM Location.Location t
    JOIN Location.LocationTypeDefinition tltd ON tltd.Id = t.LocationTypeDefinitionId
    JOIN Location.Location p                  ON p.Id    = t.ParentLocationId
    JOIN Location.LocationTypeDefinition pltd ON pltd.Id = p.LocationTypeDefinitionId
    JOIN Location.LocationType plt            ON plt.Id  = pltd.LocationTypeId
    WHERE tltd.Code = N'Terminal' AND t.DeprecatedAt IS NULL AND p.DeprecatedAt IS NULL
      AND plt.Code IN (N'Area', N'WorkCenter', N'Cell')
), Sub AS (
    SELECT tm.TerminalId, tm.ZoneId AS Id, 0 AS Depth FROM Term tm
    UNION ALL
    SELECT s.TerminalId, c.Id, s.Depth + 1
    FROM Sub s JOIN Location.Location c ON c.ParentLocationId = s.Id
    WHERE c.DeprecatedAt IS NULL
), OldAreaCells AS (          -- v1.0, Area zone: equipment cells beneath the area
    SELECT s.TerminalId, s.Id AS ScopeId
    FROM Sub s
    JOIN Term tm ON tm.TerminalId = s.TerminalId AND tm.ZoneTier = N'Area'
    JOIN Location.Location l                 ON l.Id   = s.Id
    JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE s.Depth > 0 AND lt.Code = N'Cell'
      AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Scale')
), OldOpt AS (                -- v1.0: those cells, else the zone itself
    SELECT TerminalId, ScopeId FROM OldAreaCells
    UNION
    SELECT tm.TerminalId, tm.ZoneId FROM Term tm
    WHERE NOT EXISTS (SELECT 1 FROM OldAreaCells o WHERE o.TerminalId = tm.TerminalId)
), NewOpt AS (                -- v2.0: flagged locations in the zone subtree, zone included
    SELECT s.TerminalId, s.Id AS ScopeId FROM Sub s
    WHERE EXISTS (SELECT 1 FROM #WillFlag w WHERE w.Id = s.Id)
), Diff AS (
    SELECT TerminalId, ScopeId, N'LOST' AS Change
    FROM (SELECT TerminalId, ScopeId FROM OldOpt EXCEPT SELECT TerminalId, ScopeId FROM NewOpt) x
    UNION ALL
    SELECT TerminalId, ScopeId, N'GAINED'
    FROM (SELECT TerminalId, ScopeId FROM NewOpt EXCEPT SELECT TerminalId, ScopeId FROM OldOpt) y
)
SELECT d.Change, tm.TerminalCode, tm.ZoneCode, tm.ZoneTier, l.Code AS ScopeCode, l.Name AS ScopeName
FROM Diff d
JOIN Term tm             ON tm.TerminalId = d.TerminalId
JOIN Location.Location l ON l.Id = d.ScopeId
ORDER BY d.Change DESC, tm.TerminalCode, l.Code
OPTION (MAXRECURSION 8);

-- Gate D -- a will-be-flagged location under a will-be-flagged ancestor, at ANY depth: the
-- ancestor stops reporting its own availability and reports the mean of its children on day
-- one, and its terminals lose their preselection. Expect 0 rows.
;WITH Up AS (
    SELECT w.Id AS DescId, l.ParentLocationId AS AncId
    FROM #WillFlag w JOIN Location.Location l ON l.Id = w.Id
    WHERE l.ParentLocationId IS NOT NULL
    UNION ALL
    SELECT u.DescId, p.ParentLocationId
    FROM Up u JOIN Location.Location p ON p.Id = u.AncId
    WHERE p.ParentLocationId IS NOT NULL
)
SELECT a.Code AS BecomesRollup, d.Code AS FlaggedDescendant
FROM Up u
JOIN #WillFlag wa        ON wa.Id = u.AncId
JOIN Location.Location a ON a.Id  = u.AncId
JOIN Location.Location d ON d.Id  = u.DescId
ORDER BY a.Code, d.Code
OPTION (MAXRECURSION 20);

-- Gate E -- live shift overrides on a location that will NOT be flagged (they drop out of
-- availability and out of the Shift Overrides equipment picker). Expect 0 rows.
SELECT l.Code, so.BusinessDate, so.StartTime, so.EndTime, so.Reason
FROM Oee.ShiftOverride so
JOIN Location.Location l ON l.Id = so.LocationId
WHERE so.DeprecatedAt IS NULL
  AND NOT EXISTS (SELECT 1 FROM #WillFlag w WHERE w.Id = so.LocationId);
