-- ============================================================
-- 2026-10-08_watermark_v4_exposure.sql
--
-- READ-ONLY. What Workorder.ufn_CavityShotWatermark v4.0 (prod, 2026-10-07
-- 16:32 ET) does to the shift-end Compute, measured on prod's own rows.
--
-- For every press x die x cavity with die cast credits in the last @Days:
--   Reading          highest counter reading recorded in the shift (NULL = none)
--   ReadinglessPcs   pieces credited WITHOUT a reading, live rows only
--   OldThrough       what v3.0 answered  (the reading, or 0)
--   NewThrough       what v4.0 answers now
-- and the verdict that matters at the terminal:
--   ZeroesCompute    1 when NewThrough is at or past the shift's own reading --
--                    i.e. Compute at that reading shows 0 shots and 0 good for
--                    the cavity. With no reading yet, 1 when the reading-less
--                    pieces already exceed @TypicalShiftShots.
-- Section 2 rolls it up per shift. This is the check that should have been
-- run BEFORE v4.0 shipped.
-- ============================================================
SET NOCOUNT ON;
DECLARE @Days INT = 4;
DECLARE @TypicalShiftShots INT = 1100;   -- only used where a shift has no reading at all
DECLARE @FromUtc DATETIME2(3) = DATEADD(DAY, -@Days, SYSUTCDATETIME());
DECLARE @Derived BIGINT = (SELECT Id FROM Oee.ShiftAttributionSource WHERE Code = N'Derived');

IF OBJECT_ID(N'tempdb..#X') IS NOT NULL DROP TABLE #X;
SELECT s.Id AS ShiftId, s.ActualStart,
       CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name AS Shift,
       CASE WHEN s.ActualEnd IS NULL THEN 1 ELSE 0 END AS IsOpen,
       loc.Code AS Press, t.Name AS Die, i.PartNumber, tc.CavityCode AS Cavity,
       MAX(c.ShotCounterReading) AS Reading,
       SUM(CASE WHEN c.ShotCounterReading IS NULL AND c.ShiftAttributionSourceId = @Derived THEN c.PieceDelta ELSE 0 END) AS ReadinglessPcs,
       SUM(CASE WHEN c.ShotCounterReading IS NULL AND c.ShiftAttributionSourceId = @Derived THEN 1 ELSE 0 END) AS ReadinglessRows,
       ISNULL(MAX(c.ShotCounterReading), 0) AS OldThrough,
       Workorder.ufn_CavityShotWatermark(c.ToolCavityId, c.ShiftId, c.CellLocationId) AS NewThrough
INTO #X
FROM Workorder.DieCastContribution c
INNER JOIN Oee.Shift s           ON s.Id   = c.ShiftId
INNER JOIN Oee.ShiftSchedule ss  ON ss.Id  = s.ShiftScheduleId
INNER JOIN Tools.ToolCavity tc   ON tc.Id  = c.ToolCavityId
INNER JOIN Tools.Tool t          ON t.Id   = tc.ToolId
LEFT  JOIN Parts.Item i          ON i.Id   = tc.ItemId
INNER JOIN Location.Location loc ON loc.Id = c.CellLocationId
WHERE c.EventAt >= @FromUtc
GROUP BY s.Id, s.ActualStart, s.ActualEnd, ss.Name, loc.Code, t.Name, i.PartNumber, tc.CavityCode,
         c.ToolCavityId, c.ShiftId, c.CellLocationId;

SELECT N'1 PER CAVITY (only where v4.0 changed the answer)' AS Section,
       Shift, IsOpen, Press, Die, PartNumber, Cavity, Reading, ReadinglessRows, ReadinglessPcs, OldThrough, NewThrough,
       CASE WHEN Reading IS NOT NULL AND NewThrough >= Reading AND NewThrough > OldThrough THEN 1
            WHEN Reading IS NULL AND NewThrough >= @TypicalShiftShots THEN 1 ELSE 0 END AS ZeroesCompute
FROM #X
WHERE NewThrough <> OldThrough
ORDER BY ActualStart DESC, Press, PartNumber, Cavity;

SELECT N'2 PER SHIFT' AS Section, Shift, IsOpen,
       COUNT(*) AS CavitiesWithCredits,
       SUM(CASE WHEN ReadinglessPcs > 0 THEN 1 ELSE 0 END) AS CavitiesReleasedWithoutReading,
       SUM(CASE WHEN Reading IS NULL THEN 1 ELSE 0 END) AS CavitiesWithNoReadingAtAll,
       SUM(CASE WHEN NewThrough <> OldThrough THEN 1 ELSE 0 END) AS CavitiesV4Changed
FROM #X
GROUP BY Shift, IsOpen, ActualStart
ORDER BY ActualStart DESC;
