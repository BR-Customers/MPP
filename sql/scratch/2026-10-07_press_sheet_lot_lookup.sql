-- ============================================================
-- 2026-10-07_press_sheet_lot_lookup.sql
--
-- READ-ONLY. What the MES holds for the LTTs on the Machine 202 third-shift
-- press sheet (6MA, true die "6MA Oil Pan D"), so the relabel in
-- 2026-10-07_relabel_lots_cast_on_wrong_die.sql can be scoped to exactly these.
-- 10631499-501 are the next shift's tags, listed for context only.
-- ============================================================
SET NOCOUNT ON;

DECLARE @Tags TABLE (Ord INT, LotName NVARCHAR(50), SheetQty INT, Note NVARCHAR(60));
INSERT INTO @Tags VALUES
    (1, N'10629856', 21, N'3rd'), (2, N'10629857', 60, N'3rd'), (3, N'10629858', 60, N'3rd'),
    (4, N'10629859', 60, N'3rd'), (5, N'10629860', 60, N'3rd'), (6, N'10629861', 60, N'3rd'),
    (7, N'10631498', 37, N'3rd, left open; 1st closed it at 64'),
    (8, N'10631497', 60, N'3rd'),
    (9, N'10631499', NULL, N'1st - context only'), (10, N'10631500', NULL, N'1st - context only'),
    (11, N'10631501', NULL, N'1st - context only');

-- 1. One row per tag. A NULL Status means the MES has no LOT by that name.
SELECT N'1 LOTS' AS Section, t.LotName AS Tag, t.SheetQty, t.Note,
       sc.Code AS Status, l.PieceCount AS Pcs, l.InventoryAvailable AS InvAvail,
       i.PartNumber, i.Description AS Part, tl.Code AS DieAsset, tl.Name AS Die, tc.CavityCode AS Cavity,
       pl.Name AS Press, cl.Name AS NowAt,
       CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS CreatedEt,
       (SELECT COUNT(*) FROM Workorder.DieCastContribution c WHERE c.LotId = l.Id) AS Contribs,
       (SELECT COUNT(*) FROM Workorder.RejectEvent r WHERE r.LotId = l.Id)         AS Rejects,
       (SELECT COUNT(*) FROM Workorder.ProductionEvent p WHERE p.LotId = l.Id)     AS ProdEvents,
       (SELECT COUNT(*) FROM Workorder.ConsumptionEvent ce
         WHERE ce.SourceLotId = l.Id OR ce.ProducedLotId = l.Id)                   AS Consumption,
       (SELECT COUNT(*) FROM Lots.LotGenealogy g
         WHERE g.ParentLotId = l.Id OR g.ChildLotId = l.Id)                        AS Genealogy,
       (SELECT COUNT(*) FROM Lots.LotLabel b WHERE b.LotId = l.Id)                 AS Labels
FROM @Tags t
LEFT JOIN Lots.Lot l            ON l.LotName = t.LotName
LEFT JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
LEFT JOIN Parts.Item i          ON i.Id  = l.ItemId
LEFT JOIN Tools.Tool tl         ON tl.Id = l.ToolId
LEFT JOIN Tools.ToolCavity tc   ON tc.Id = l.ToolCavityId
LEFT JOIN Location.Location pl  ON pl.Id = l.ProducedAtLocationId
LEFT JOIN Location.Location cl  ON cl.Id = l.CurrentLocationId
ORDER BY t.Ord;

-- 2. Every credit against those LOTs: how many pieces, when, under which shift.
SELECT N'2 CREDITS' AS Section, l.LotName AS Tag, c.PieceDelta, c.ShotCounterReading AS Reading,
       CAST(c.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS EventEt,
       CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name AS StampedShift,
       src.Code AS ShiftSource, u.Initials AS [By]
FROM @Tags t
INNER JOIN Lots.Lot l                      ON l.LotName = t.LotName
INNER JOIN Workorder.DieCastContribution c ON c.LotId = l.Id
LEFT  JOIN Oee.Shift s                     ON s.Id  = c.ShiftId
LEFT  JOIN Oee.ShiftSchedule ss            ON ss.Id = s.ShiftScheduleId
LEFT  JOIN Oee.ShiftAttributionSource src  ON src.Id = c.ShiftAttributionSourceId
LEFT  JOIN Location.AppUser u              ON u.Id  = c.AppUserId
ORDER BY t.Ord, c.EventAt;

-- 3. The true die's cavities -- what each LOT's cavity letter will map onto.
SELECT N'3 TRUE DIE CAVITIES' AS Section, tl.Code AS DieAsset, tl.Name AS Die, tc.CavityCode AS Cavity,
       i.PartNumber, i.Description AS Part,
       CASE WHEN tc.DeprecatedAt IS NULL THEN N'live' ELSE N'deprecated' END AS State
FROM Tools.Tool tl
LEFT JOIN Tools.ToolCavity tc ON tc.ToolId = tl.Id
LEFT JOIN Parts.Item i        ON i.Id = tc.ItemId
WHERE tl.Name = N'6MA Oil Pan D'
ORDER BY tc.CavityCode;

-- 4. What was mounted on Machine 202 around then.
SELECT N'4 MOUNTS ON 202' AS Section, tl.Code AS DieAsset, tl.Name AS Die,
       CAST(a.AssignedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS AssignedEt,
       CAST(a.ReleasedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS ReleasedEt
FROM Tools.ToolAssignment a
INNER JOIN Tools.Tool tl         ON tl.Id  = a.ToolId
INNER JOIN Location.Location loc ON loc.Id = a.CellLocationId
WHERE loc.Name = N'Machine 202'
  AND ISNULL(a.ReleasedAt, '9999-12-31') >= DATEADD(DAY, -21, SYSUTCDATETIME())
ORDER BY a.AssignedAt DESC;
