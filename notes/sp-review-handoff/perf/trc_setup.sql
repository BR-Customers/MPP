-- Perf DB: 30,000 die-cast-style LOTs (ToolId not null) created at 6 terminals, mostly closed. ToolId FK not checked (throwaway DB, no Tools rows).
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName LIKE N'PERFDC-%')
BEGIN
    ALTER TABLE Lots.Lot NOCHECK CONSTRAINT ALL;
    DECLARE @T TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, Id BIGINT NOT NULL);
    INSERT @T (Id) SELECT TOP (6) Id FROM Location.Location WHERE Code LIKE N'DC%' ORDER BY Id;
    DECLARE @NT INT = (SELECT COUNT(*) FROM @T), @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item ORDER BY Id), @Now DATETIME2(3) = SYSUTCDATETIME();
    ;WITH N AS (SELECT TOP (30000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, ToolId, CreatedAtTerminalId,
                          CrtActive, TotalInProcess, InventoryAvailable, CreatedByUserId, CreatedAt)
    SELECT N'PERFDC-' + CAST(n AS NVARCHAR(12)), @Item, 1, CASE WHEN n % 25 = 0 THEN 1 ELSE 4 END, 100,
           (SELECT Id FROM @T WHERE Seq = 1 + (n % @NT)), 1, (SELECT Id FROM @T WHERE Seq = 1 + (n % @NT)),
           0, 0, 0, 1, DATEADD(MINUTE, -n * 3, @Now)
    FROM N;
    ALTER TABLE Lots.Lot WITH NOCHECK CHECK CONSTRAINT ALL;
    UPDATE STATISTICS Lots.Lot WITH FULLSCAN;
END
SELECT COUNT(*) AS Lots, SUM(CASE WHEN ToolId IS NOT NULL THEN 1 ELSE 0 END) AS DieCastLots,
       (SELECT used_page_count FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID('Lots.Lot') AND index_id = 0) AS HeapPages
FROM Lots.Lot;
