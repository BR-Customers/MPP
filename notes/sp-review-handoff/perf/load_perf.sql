-- Synthetic prod-scale load for MPP_MES_Perf (throwaway). ~41k LOTs, 2.4k open, ~46k movements.
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName LIKE N'PERF-%') RAISERROR(N'already loaded', 16, 1);

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

-- 60 locations (always include the assembly test cell), 10 routed items
DECLARE @Locs TABLE (Seq INT PRIMARY KEY, Id BIGINT NOT NULL);
INSERT INTO @Locs (Seq, Id)
SELECT ROW_NUMBER() OVER (ORDER BY x.k), x.Id
FROM (SELECT TOP (60) l.Id, CASE WHEN l.Code = N'MA1-COMPBR-AOUT' THEN 0 ELSE ABS(CHECKSUM(l.Id)) + 1 END AS k
      FROM Location.Location l
      ORDER BY CASE WHEN l.Code = N'MA1-COMPBR-AOUT' THEN 0 ELSE ABS(CHECKSUM(l.Id)) + 1 END) x;

DECLARE @Items TABLE (Seq INT PRIMARY KEY, Id BIGINT NOT NULL);
INSERT INTO @Items (Seq, Id)
SELECT ROW_NUMBER() OVER (ORDER BY i.Id), i.Id
FROM Parts.Item i
WHERE EXISTS (SELECT 1 FROM Parts.RouteTemplate rt WHERE rt.ItemId = i.Id AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL);

DECLARE @NL INT = (SELECT COUNT(*) FROM @Locs), @NI INT = (SELECT COUNT(*) FROM @Items);

;WITH N AS (SELECT TOP (41174) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId,
                      CrtActive, TotalInProcess, InventoryAvailable, CreatedByUserId, CreatedAt)
SELECT N'PERF-' + CAST(n AS NVARCHAR(12)),
       (SELECT Id FROM @Items WHERE Seq = 1 + (n % @NI)),
       1,
       CASE WHEN n % 17 = 0 THEN 1 ELSE 4 END,        -- ~2,400 open (Good), rest Closed
       100,
       (SELECT Id FROM @Locs WHERE Seq = 1 + (ABS(CHECKSUM(n)) % @NL)),
       0, 0,
       CASE WHEN n % 17 = 0 THEN 100 ELSE 0 END,
       1,
       DATEADD(MINUTE, -n * 25, @Now)
FROM N;

-- first movement for every LOT; extra movement for ~12% (open LOTs among them)
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
SELECT l.Id, NULL, l.CurrentLocationId, 1, NULL, l.CreatedAt
FROM Lots.Lot l WHERE l.LotName LIKE N'PERF-%';

INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
SELECT l.Id, l.CurrentLocationId, l.CurrentLocationId, 1, NULL, DATEADD(MINUTE, 5, l.CreatedAt)
FROM Lots.Lot l WHERE l.LotName LIKE N'PERF-%' AND (l.LotStatusId = 1 OR l.Id % 9 = 0);

UPDATE STATISTICS Lots.Lot WITH FULLSCAN;
UPDATE STATISTICS Lots.LotMovement WITH FULLSCAN;

SELECT (SELECT COUNT(*) FROM Lots.Lot) AS Lots,
       (SELECT COUNT(*) FROM Lots.Lot WHERE LotStatusId <> 4) AS OpenLots,
       (SELECT COUNT(*) FROM Lots.LotMovement) AS Movements,
       (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT') AS TestCell;
