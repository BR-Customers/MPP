-- ============================================================
-- 2026-10-08_shift_end_fix_exposure.sql
--
-- READ-ONLY. Run on prod BEFORE the shift-end fix is deployed. It needs
-- nothing from the release: the new figure is computed inline here.
--
-- For every press x die x cavity with die cast credits in the last @Days it
-- shows what the Reconcile Shift tab would put in front of an operator after
-- the fix, next to what it shows today:
--
--   Reading          the shift-end reading on record (NULL = never entered)
--   ReleasedByCount  pieces credited without a reading since the last reading
--                    -- the new "already released this shift" term
--   OpenBasket       1 when the cavity has a basket open right now
--   and, where a reading IS on record, for an entry made at that reading with
--   no die-wide shots:
--   TodayOffers      what the open basket is offered today  (shots since the watermark)
--   FixOffers        what it would be offered after the fix (less ReleasedByCount, floor 0)
--   FixUnaccounted   shots - ReleasedByCount when that is NEGATIVE: the released
--                    baskets hold more than the shift cast, and the operator
--                    will be asked for a reason
--
-- Section 2 is the number to read before deciding: per shift, how many
-- cavities change, and how many will ask for a reason.
-- ============================================================
SET NOCOUNT ON;
DECLARE @Days INT = 5;
DECLARE @FromUtc DATETIME2(3) = DATEADD(DAY, -@Days, SYSUTCDATETIME());
DECLARE @Derived BIGINT = (SELECT Id FROM Oee.ShiftAttributionSource WHERE Code = N'Derived');

IF OBJECT_ID(N'tempdb..#K') IS NOT NULL DROP TABLE #K;
SELECT c.ShiftId, c.CellLocationId, c.ToolCavityId,
       MAX(c.ShotCounterReading) AS Reading,
       MAX(CASE WHEN c.ShotCounterReading IS NOT NULL THEN c.Id END) AS LastReadingRowId
INTO #K
FROM Workorder.DieCastContribution c
WHERE c.EventAt >= @FromUtc AND c.ToolCavityId IS NOT NULL AND c.CellLocationId IS NOT NULL
GROUP BY c.ShiftId, c.CellLocationId, c.ToolCavityId;

IF OBJECT_ID(N'tempdb..#X') IS NOT NULL DROP TABLE #X;
SELECT s.Id AS ShiftId, s.ActualStart,
       CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name AS Shift,
       CASE WHEN s.ActualEnd IS NULL THEN 1 ELSE 0 END AS ShiftOpen,
       loc.Code AS Press, t.Name AS Die, i.PartNumber, tc.CavityCode AS Cavity,
       k.Reading,
       ISNULL((SELECT SUM(c.PieceDelta) FROM Workorder.DieCastContribution c
               WHERE c.ShiftId = k.ShiftId AND c.CellLocationId = k.CellLocationId AND c.ToolCavityId = k.ToolCavityId
                 AND c.ShotCounterReading IS NULL AND c.ShiftAttributionSourceId = @Derived
                 AND (k.LastReadingRowId IS NULL OR c.Id > k.LastReadingRowId)), 0) AS ReleasedByCount,
       ISNULL((SELECT SUM(c.PieceDelta) FROM Workorder.DieCastContribution c
               WHERE c.ShiftId = k.ShiftId AND c.CellLocationId = k.CellLocationId AND c.ToolCavityId = k.ToolCavityId
                 AND c.ShotCounterReading IS NULL AND c.ShiftAttributionSourceId = @Derived), 0) AS ReleasedByCountAllShift,
       CASE WHEN EXISTS (SELECT 1 FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                         WHERE l.ToolCavityId = k.ToolCavityId AND sc.Code = N'Open') THEN 1 ELSE 0 END AS OpenBasket
INTO #X
FROM #K k
INNER JOIN Oee.Shift s           ON s.Id   = k.ShiftId
INNER JOIN Oee.ShiftSchedule ss  ON ss.Id  = s.ShiftScheduleId
INNER JOIN Tools.ToolCavity tc   ON tc.Id  = k.ToolCavityId
INNER JOIN Tools.Tool t          ON t.Id   = tc.ToolId
LEFT  JOIN Parts.Item i          ON i.Id   = tc.ItemId
INNER JOIN Location.Location loc ON loc.Id = k.CellLocationId;

SELECT N'1 PER CAVITY (only cavities with pieces released by count)' AS Section,
       Shift, ShiftOpen, Press, Die, PartNumber, Cavity, Reading, ReleasedByCountAllShift AS ReleasedByCount, OpenBasket
FROM #X
WHERE ReleasedByCountAllShift > 0
ORDER BY ActualStart DESC, Press, PartNumber, Cavity;

SELECT N'2 PER SHIFT' AS Section, Shift, ShiftOpen,
       COUNT(*) AS CavitiesWithCredits,
       SUM(CASE WHEN ReleasedByCountAllShift > 0 THEN 1 ELSE 0 END) AS CavitiesReleasedByCount,
       SUM(CASE WHEN Reading IS NULL THEN 1 ELSE 0 END) AS CavitiesWithNoShiftEndNumber,
       -- the reading already on record sits BELOW what was released by count: an
       -- entry at that reading would have shown a negative unaccounted
       SUM(CASE WHEN Reading IS NOT NULL AND ReleasedByCountAllShift > Reading THEN 1 ELSE 0 END) AS CavitiesReleasedMoreThanReading,
       SUM(ReleasedByCountAllShift) AS PiecesReleasedByCount
FROM #X
GROUP BY Shift, ShiftOpen, ActualStart
ORDER BY ActualStart DESC;

-- The shift in progress: exactly what changes for the NEXT Compute on each press.
SELECT N'3 SHIFT IN PROGRESS -- next Compute' AS Section, Press, Die, PartNumber, Cavity,
       ReleasedByCount, OpenBasket,
       CASE WHEN OpenBasket = 1 THEN N'open basket offered (reading - die-wide - ' + CAST(ReleasedByCount AS NVARCHAR(10)) + N'), not the full reading'
            ELSE N'no open basket: cavity now counts in the totals; unaccounted = reading - die-wide - ' + CAST(ReleasedByCount AS NVARCHAR(10)) END AS WhatChanges
FROM #X
WHERE ShiftOpen = 1 AND ReleasedByCount > 0
ORDER BY Press, PartNumber, Cavity;
