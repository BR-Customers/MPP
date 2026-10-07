-- ============================================================
-- READ-ONLY. Which Assembly OUT lines would show the low-inventory lock
-- right now?  Run AFTER the 0108 release's SQL Execute and BEFORE the MPP
-- import (the proc exists then; the banner does not yet).
--
-- For every finished good eligible at a location, and every pack-out
-- (closure method) that part has, calls the real
-- Workorder.Assembly_GetTraysRemaining -- so this cannot disagree with the
-- banner. Deliberately over-inclusive: it also lists serialized lines and
-- parts nobody is running. A row only matters if that part is the one
-- selected on a NON-serialized Assembly OUT screen at that line.
--
-- Second result: where each line's Low Inventory downtime event would be
-- recorded, and whether that unit is OEE-enabled (if not, the banner works
-- but no downtime event is written).
-- ============================================================
SET NOCOUNT ON;

DECLARE @Cand TABLE (LocationId BIGINT, ItemId BIGINT, ClosureMethod NVARCHAR(20));
INSERT INTO @Cand
SELECT DISTINCT eil.LocationId, i.Id, cc.ClosureMethod
FROM Parts.v_EffectiveItemLocation eil
JOIN Parts.Item i            ON i.Id = eil.ItemId AND i.DeprecatedAt IS NULL
JOIN Parts.ItemType it       ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood'
JOIN Parts.ContainerConfig cc ON cc.ItemId = i.Id AND cc.DeprecatedAt IS NULL AND cc.PartsPerTray > 0;

CREATE TABLE #R (ItemId BIGINT, PartNumber NVARCHAR(100), Description NVARCHAR(500), BoxQuantity INT,
                 PiecesPerTray INT, Available INT, TraysLeft INT, IsShort BIT, ThresholdTrays INT);
CREATE TABLE #Out (LineName NVARCHAR(200), FinishedGood NVARCHAR(100), ClosureMethod NVARCHAR(20),
                   ShortPart NVARCHAR(500), Available INT, PiecesPerTray INT, TraysLeft INT, IsShort BIT);

DECLARE @L BIGINT, @I BIGINT, @M NVARCHAR(20);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT LocationId, ItemId, ClosureMethod FROM @Cand;
OPEN c; FETCH NEXT FROM c INTO @L, @I, @M;
WHILE @@FETCH_STATUS = 0
BEGIN
    DELETE FROM #R;
    INSERT INTO #R EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = @L, @FinishedGoodItemId = @I, @ClosureMethod = @M;
    INSERT INTO #Out
    SELECT loc.Name, fg.PartNumber, @M, r.Description, r.Available, r.PiecesPerTray, r.TraysLeft, r.IsShort
    FROM #R r
    JOIN Location.Location loc ON loc.Id = @L
    JOIN Parts.Item fg         ON fg.Id = @I;
    FETCH NEXT FROM c INTO @L, @I, @M;
END
CLOSE c; DEALLOCATE c;

SELECT LineName, FinishedGood, ClosureMethod, ShortPart, Available, PiecesPerTray, TraysLeft,
       CASE WHEN IsShort = 1 THEN 'WOULD LOCK' ELSE '' END AS Lock
FROM #Out
ORDER BY IsShort DESC, TraysLeft, LineName, FinishedGood;

SELECT DISTINCT loc.Name AS LineName, u.Name AS DowntimeUnit,
       CASE WHEN u.IsOeeEnabled = 1 THEN 'yes' ELSE '*** NO -- no downtime event will be recorded ***' END AS OeeEnabled
FROM @Cand c
JOIN Location.Location loc ON loc.Id = c.LocationId
JOIN Location.Location u   ON u.Id = Oee.ufn_ResolveDowntimeScope(c.LocationId)
ORDER BY loc.Name;

DROP TABLE #R; DROP TABLE #Out;
