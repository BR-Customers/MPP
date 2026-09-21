-- ============================================================
-- 2026-09-21_diecast_on_record_window.sql
--
-- READ-ONLY. SELECTs only; the working sets are table variables. No writes to
-- any table, no transaction, no temp tables. Safe against MPP_MES_Prod during
-- production.
--
-- Purpose: everything the MES holds for DIE CAST over the last @Hours hours
-- (default 168 = 7 days),
-- laid out so it can be read side by side with the paper press sheets
-- (DCFM-0485). Input to the design of the supervisor shift-reconciliation /
-- backfill screen (notes/2026-09-17_shift-reconciliation-backfill-trim-followup.md).
--
-- Result sets, each tagged in its first column:
--   A  Window       -- what the window resolved to, and which database
--   B  Shifts       -- every Oee.Shift instance overlapping the window
--   C  Mounts       -- which die was on which press, and when
--   D  Rollup       -- per Shift x Press x Die x Cavity: baskets opened,
--                      pieces credited, scrap, last counter reading.
--                      THIS is the "what is on record" figure to hold against
--                      a paper sheet row.
--   E  Lots         -- every die-cast LOT touched in the window, with how it
--                      was created (die cast screen vs Lot_Create, i.e. the
--                      cutover stopgap) and what has happened to it since
--   F  Contribs     -- every Workorder.DieCastContribution row (piece credits)
--   G  Rejects      -- every die-cast Workorder.RejectEvent row (scrap)
--   H  Anchors      -- counter anchors ("Fix counter")
--   I  Dies         -- current ShotCount / ShotLimit of every die involved
--
-- TIME: every *Et column is Eastern wall clock. Oee.Shift.ActualStart/End are
-- ALREADY Eastern (the project's documented UTC exception, OI-38) and are
-- emitted raw; every other timestamp is UTC in the table and converted here.
-- ============================================================
SET NOCOUNT ON;

DECLARE @Hours INT = 168;  -- WINDOW_HOURS (Run-DieCastOnRecord.ps1 rewrites this line)
DECLARE @NowUtc  DATETIME2(3) = SYSUTCDATETIME();
DECLARE @FromUtc DATETIME2(3) = DATEADD(HOUR, -@Hours, @NowUtc);
DECLARE @FromEt  DATETIME2(3) = CAST(@FromUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));
DECLARE @NowEt   DATETIME2(3) = CAST(@NowUtc  AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));

-- ---------- working sets ----------
DECLARE @Press TABLE (Id BIGINT PRIMARY KEY, Code NVARCHAR(100), Name NVARCHAR(200));
INSERT @Press (Id, Code, Name)
SELECT l.Id, l.Code, l.Name
FROM Location.Location l
INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
WHERE d.Name = N'Die Cast Machine';

-- A die-cast LOT is one minted against a cavity. Touched = created, cast-dated,
-- credited, scrapped or status-changed inside the window.
DECLARE @Lot TABLE (Id BIGINT PRIMARY KEY);
INSERT @Lot (Id)
SELECT l.Id
FROM Lots.Lot l
WHERE l.ToolCavityId IS NOT NULL
  AND (   l.CreatedAt >= @FromUtc
       OR l.CastDate  >= CAST(@FromEt AS DATE)
       OR EXISTS (SELECT 1 FROM Workorder.DieCastContribution c WHERE c.LotId = l.Id AND c.EventAt    >= @FromUtc)
       OR EXISTS (SELECT 1 FROM Workorder.RejectEvent        r WHERE r.LotId = l.Id AND r.RecordedAt >= @FromUtc)
       OR EXISTS (SELECT 1 FROM Lots.LotStatusHistory        h WHERE h.LotId = l.Id AND h.ChangedAt  >= @FromUtc));

-- Shift lookup for a UTC instant: convert to Eastern, then find the instance.
-- (Inlined as OUTER APPLY below; kept identical everywhere it appears.)

-- ---------- A. Window ----------
SELECT N'A Window' AS [Set], DB_NAME() AS DatabaseName, @Hours AS Hours,
       @FromEt AS FromEt, @NowEt AS NowEt,
       (SELECT COUNT(*) FROM @Press) AS DieCastPresses,
       (SELECT COUNT(*) FROM @Lot)   AS DieCastLotsTouched;

-- ---------- B. Shifts ----------
SELECT N'B Shifts' AS [Set], s.Id AS ShiftId, ss.Name AS Schedule,
       s.ActualStart AS StartEt, s.ActualEnd AS EndEt,
       CASE WHEN s.ActualEnd IS NULL THEN 1 ELSE 0 END AS IsOpen
FROM Oee.Shift s
INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
WHERE ISNULL(s.ActualEnd, '9999-12-31') > @FromEt
ORDER BY s.ActualStart;

-- ---------- C. Die mounts ----------
SELECT N'C Mounts' AS [Set], p.Code AS Press, p.Name AS PressName,
       t.Code AS Die, t.Name AS DieName,
       CAST(ta.AssignedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS MountedEt,
       CAST(ta.ReleasedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS UnmountedEt
FROM Tools.ToolAssignment ta
INNER JOIN @Press p     ON p.Id = ta.CellLocationId
INNER JOIN Tools.Tool t ON t.Id = ta.ToolId
WHERE ISNULL(ta.ReleasedAt, '9999-12-31') > @FromUtc
ORDER BY p.Code, ta.AssignedAt;

-- ---------- D. Roll-up per Shift x Press x Die x Cavity ----------
WITH Facts AS (
    -- piece credits
    SELECT c.ShiftId, c.CellLocationId, l.ToolId, ISNULL(c.ToolCavityId, l.ToolCavityId) AS ToolCavityId,
           0 AS BasketsOpened, CAST(0 AS BIGINT) AS BasketPieces,
           c.PieceDelta AS PiecesCredited, 0 AS RejectScrap, 0 AS NonRejectScrap,
           c.ShotCounterReading AS Reading
    FROM Workorder.DieCastContribution c
    INNER JOIN Lots.Lot l ON l.Id = c.LotId
    WHERE c.EventAt >= @FromUtc
    UNION ALL
    -- scrap (die-cast rows carry their own identity since 0084)
    SELECT r.ShiftId, r.CellLocationId, ISNULL(r.ToolId, l.ToolId), ISNULL(r.ToolCavityId, l.ToolCavityId),
           0, CAST(0 AS BIGINT), 0,
           CASE WHEN dc.IsNonRejectScrap = 1 THEN 0 ELSE r.Quantity END,
           CASE WHEN dc.IsNonRejectScrap = 1 THEN r.Quantity ELSE 0 END,
           NULL
    FROM Workorder.RejectEvent r
    INNER JOIN Quality.DefectCode dc ON dc.Id = r.DefectCodeId
    LEFT  JOIN Lots.Lot l            ON l.Id = r.LotId
    WHERE r.RecordedAt >= @FromUtc
      AND (r.ShiftId IS NOT NULL OR r.ToolId IS NOT NULL OR r.LotId IN (SELECT Id FROM @Lot))
    UNION ALL
    -- baskets opened, bucketed into the shift they were created in.
    -- Only the cutover path stamps ProducedAtLocationId, so fall back to the
    -- press the die was mounted on when the basket was created.
    -- BasketPieces is Lot.PieceCount: the cutover path writes the quantity
    -- straight onto the basket and never writes a contribution row, so the
    -- ledger alone reports those shifts as zero production.
    SELECT sh.ShiftId, COALESCE(l.ProducedAtLocationId, mt.CellLocationId), l.ToolId, l.ToolCavityId,
           1, CAST(l.PieceCount AS BIGINT), 0, 0, 0, NULL
    FROM Lots.Lot l
    INNER JOIN @Lot w ON w.Id = l.Id
    OUTER APPLY (SELECT TOP 1 ta.CellLocationId FROM Tools.ToolAssignment ta
                 INNER JOIN @Press p ON p.Id = ta.CellLocationId
                 WHERE ta.ToolId = l.ToolId AND ta.AssignedAt <= l.CreatedAt
                   AND ISNULL(ta.ReleasedAt, '9999-12-31') > l.CreatedAt
                 ORDER BY ta.AssignedAt DESC) mt
    OUTER APPLY (SELECT TOP 1 s.Id AS ShiftId FROM Oee.Shift s
                 WHERE s.ActualStart <= CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
                   AND ISNULL(s.ActualEnd, '9999-12-31') > CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
                 ORDER BY s.ActualStart DESC) sh
    WHERE l.CreatedAt >= @FromUtc
)
SELECT N'D Rollup' AS [Set], f.ShiftId, ss.Name AS Schedule, s.ActualStart AS ShiftStartEt,
       pl.Code AS Press, t.Code AS Die, i.PartNumber, tc.CavityCode AS Cavity,
       SUM(f.BasketsOpened)  AS BasketsOpened,
       SUM(f.BasketPieces)   AS PiecesOnBaskets,   -- Lot.PieceCount of baskets opened this shift
       SUM(f.PiecesCredited) AS PiecesCredited,    -- the DieCastContribution ledger
       SUM(f.RejectScrap)    AS RejectScrap,
       SUM(f.NonRejectScrap) AS NonRejectScrap,   -- warm-up / test shots
       MAX(f.Reading)        AS LastCounterReading
FROM Facts f
LEFT JOIN Oee.Shift s          ON s.Id  = f.ShiftId
LEFT JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
LEFT JOIN Location.Location pl ON pl.Id = f.CellLocationId
LEFT JOIN Tools.Tool t         ON t.Id  = f.ToolId
LEFT JOIN Tools.ToolCavity tc  ON tc.Id = f.ToolCavityId
LEFT JOIN Parts.Item i         ON i.Id  = tc.ItemId
GROUP BY f.ShiftId, ss.Name, s.ActualStart, pl.Code, t.Code, i.PartNumber, tc.CavityCode
ORDER BY s.ActualStart, pl.Code, t.Code, i.PartNumber, tc.CavityCode;

-- ---------- E. LOTs ----------
SELECT N'E Lots' AS [Set], l.Id AS LotId, l.LotName, i.PartNumber,
       t.Code AS Die, tc.CavityCode AS Cavity,
       COALESCE(pp.Code, cp.Code, mt.Code) AS Press,   -- stamped, else credited at, else mounted on
       sc.Code AS Status, cl.Name AS NowAt,
       l.PieceCount, l.InventoryAvailable,
       CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CreatedEt,
       sh.ShiftId AS CreatedInShiftId, sh.Schedule AS CreatedInShift,
       l.CastDate,
       cu.Initials AS CreatedBy, ct.Name AS CreatedAtTerminal,
       CASE WHEN op.Opened = 1 THEN N'DieCastLot_Open'
            ELSE N'Lot_Create (cutover / other)' END AS CreatedVia,
       rel.ReleasedEt,
       ISNULL(cr.Pieces, 0)  AS PiecesCredited,
       ISNULL(cr.Rows_, 0)   AS ContributionRows,
       cr.LastReading,
       ISNULL(rj.Qty, 0)     AS ScrapOnLot
FROM Lots.Lot l
INNER JOIN @Lot w              ON w.Id  = l.Id
INNER JOIN Parts.Item i        ON i.Id  = l.ItemId
INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
LEFT JOIN Tools.Tool t         ON t.Id  = l.ToolId
LEFT JOIN Tools.ToolCavity tc  ON tc.Id = l.ToolCavityId
LEFT JOIN Location.Location pp ON pp.Id = l.ProducedAtLocationId
LEFT JOIN Location.Location cl ON cl.Id = l.CurrentLocationId
LEFT JOIN Location.Location ct ON ct.Id = l.CreatedAtTerminalId
LEFT JOIN Location.AppUser cu  ON cu.Id = l.CreatedByUserId
OUTER APPLY (SELECT TOP 1 s.Id AS ShiftId, ss.Name AS Schedule FROM Oee.Shift s
             INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
             WHERE s.ActualStart <= CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
               AND ISNULL(s.ActualEnd, '9999-12-31') > CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
             ORDER BY s.ActualStart DESC) sh
OUTER APPLY (SELECT 1 AS Opened WHERE EXISTS (
                 SELECT 1 FROM Lots.LotEventLog e
                 INNER JOIN Audit.LogEventType et ON et.Id = e.LogEventTypeId
                 WHERE (e.LotId = l.Id OR e.EntityId = l.Id) AND et.Code = N'DieCastLotOpened')) op
OUTER APPLY (SELECT MIN(CAST(h.ChangedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))) AS ReleasedEt
             FROM Lots.LotStatusHistory h
             INNER JOIN Lots.LotStatusCode ns ON ns.Id = h.NewStatusId
             INNER JOIN Lots.LotStatusCode os ON os.Id = h.OldStatusId
             WHERE h.LotId = l.Id AND os.Code = N'Open' AND ns.Code = N'Good') rel
OUTER APPLY (SELECT SUM(c.PieceDelta) AS Pieces, COUNT(*) AS Rows_, MAX(c.ShotCounterReading) AS LastReading,
                    MAX(c.CellLocationId) AS CellLocationId
             FROM Workorder.DieCastContribution c WHERE c.LotId = l.Id) cr
LEFT JOIN Location.Location cp ON cp.Id = cr.CellLocationId
OUTER APPLY (SELECT SUM(r.Quantity) AS Qty FROM Workorder.RejectEvent r WHERE r.LotId = l.Id) rj
OUTER APPLY (SELECT TOP 1 p.Code FROM Tools.ToolAssignment ta
             INNER JOIN @Press p ON p.Id = ta.CellLocationId
             WHERE ta.ToolId = l.ToolId AND ta.AssignedAt <= l.CreatedAt
               AND ISNULL(ta.ReleasedAt, '9999-12-31') > l.CreatedAt
             ORDER BY ta.AssignedAt DESC) mt
ORDER BY COALESCE(pp.Code, cp.Code, mt.Code), l.CreatedAt;

-- ---------- F. Contributions (piece credits) ----------
SELECT N'F Contribs' AS [Set], c.Id AS ContributionId,
       CAST(c.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventEt,
       c.ShiftId, ss.Name AS Schedule, p.Code AS Press, t.Code AS Die, tc.CavityCode AS Cavity,
       l.LotName, c.ShotCounterReading, c.PieceDelta,
       vr.Code AS VarianceReason, c.VarianceNote,
       u.Initials AS RecordedBy, tl.Name AS Terminal
FROM Workorder.DieCastContribution c
INNER JOIN Lots.Lot l          ON l.Id  = c.LotId
LEFT JOIN Oee.Shift s          ON s.Id  = c.ShiftId
LEFT JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
LEFT JOIN Location.Location p  ON p.Id  = c.CellLocationId
LEFT JOIN Tools.Tool t         ON t.Id  = l.ToolId
LEFT JOIN Tools.ToolCavity tc  ON tc.Id = ISNULL(c.ToolCavityId, l.ToolCavityId)
LEFT JOIN Workorder.DieCastVarianceReason vr ON vr.Id = c.VarianceReasonId
LEFT JOIN Location.AppUser u   ON u.Id  = c.AppUserId
LEFT JOIN Location.Location tl ON tl.Id = c.TerminalLocationId
WHERE c.EventAt >= @FromUtc
ORDER BY p.Code, c.EventAt, tc.CavityCode;

-- ---------- G. Rejects (scrap) ----------
SELECT N'G Rejects' AS [Set], r.Id AS RejectId,
       CAST(r.RecordedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS RecordedEt,
       r.ShiftId, ss.Name AS Schedule, p.Code AS Press,
       t.Code AS Die, tc.CavityCode AS Cavity, i.PartNumber, l.LotName,
       dc.Code AS DefectCode, dc.Description AS Defect, dc.IsNonRejectScrap,
       r.Quantity, r.Remarks, u.Initials AS RecordedBy, tl.Name AS Terminal
FROM Workorder.RejectEvent r
INNER JOIN Quality.DefectCode dc ON dc.Id = r.DefectCodeId
LEFT JOIN Lots.Lot l           ON l.Id  = r.LotId
LEFT JOIN Oee.Shift s          ON s.Id  = r.ShiftId
LEFT JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
LEFT JOIN Location.Location p  ON p.Id  = r.CellLocationId
LEFT JOIN Tools.Tool t         ON t.Id  = ISNULL(r.ToolId, l.ToolId)
LEFT JOIN Tools.ToolCavity tc  ON tc.Id = ISNULL(r.ToolCavityId, l.ToolCavityId)
LEFT JOIN Parts.Item i         ON i.Id  = ISNULL(r.ItemId, l.ItemId)
LEFT JOIN Location.AppUser u   ON u.Id  = r.AppUserId
LEFT JOIN Location.Location tl ON tl.Id = r.TerminalLocationId
WHERE r.RecordedAt >= @FromUtc
  AND (r.ShiftId IS NOT NULL OR r.ToolId IS NOT NULL OR r.LotId IN (SELECT Id FROM @Lot))
ORDER BY p.Code, r.RecordedAt;

-- ---------- H. Counter anchors ----------
SELECT N'H Anchors' AS [Set], a.Id AS AnchorId,
       CAST(a.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventEt,
       a.ShiftId, p.Code AS Press, t.Code AS Die, a.DeclaredReading,
       ar.Code AS Reason, a.Note, u.Initials AS RecordedBy
FROM Workorder.DieCastCounterAnchor a
INNER JOIN Tools.Tool t        ON t.Id  = a.ToolId
LEFT JOIN Location.Location p  ON p.Id  = a.CellLocationId
LEFT JOIN Workorder.DieCastCounterAnchorReason ar ON ar.Id = a.ReasonId
LEFT JOIN Location.AppUser u   ON u.Id  = a.AppUserId
WHERE a.EventAt >= @FromUtc
ORDER BY p.Code, a.EventAt;

-- ---------- I. Dies involved ----------
SELECT N'I Dies' AS [Set], t.Code AS Die, t.Name AS DieName, t.ShotCount, t.ShotLimit,
       mp.Code AS MountedOnNow
FROM Tools.Tool t
OUTER APPLY (SELECT TOP 1 p.Code FROM Tools.ToolAssignment ta
             INNER JOIN @Press p ON p.Id = ta.CellLocationId
             WHERE ta.ToolId = t.Id AND ta.ReleasedAt IS NULL) mp
WHERE t.Id IN (SELECT l.ToolId FROM Lots.Lot l INNER JOIN @Lot w ON w.Id = l.Id)
   OR t.Id IN (SELECT ta.ToolId FROM Tools.ToolAssignment ta INNER JOIN @Press p ON p.Id = ta.CellLocationId
               WHERE ISNULL(ta.ReleasedAt, '9999-12-31') > @FromUtc)
ORDER BY t.Code;
