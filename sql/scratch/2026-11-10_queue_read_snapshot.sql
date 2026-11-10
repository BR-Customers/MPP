-- ============================================================
-- 2026-11-10_queue_read_snapshot.sql
-- READ-ONLY. Writes nothing outside #temp tables.
--
-- Run it on prod BEFORE the 0118 Execute and again AFTER. The two outputs must
-- be identical: same rows per line, same checksum. That is the proof, on prod's
-- own data, that Lot_GetWipQueueByLocation v3.3 and
-- Lot_GetTrimStorageQueueForLine v2.1 return what the old versions did, in the
-- same order (Ord is folded into the checksum, so a reorder changes it).
--
-- Covers every WorkCenter with eligible parts: the Machining IN read for the
-- line, and the WIP read for the line + descendants (all roles). The final
-- TotalRows / TotalChecksum line is the one to compare at a glance.
--
-- The plant keeps running between the two runs, so a LOT that moved or was
-- claimed in that minute changes its line's numbers legitimately. Run both
-- close together in a quiet moment; if one line differs, look at what that
-- line did in between before reading it as a problem.
--
--   sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -I -C -W -i sql\scratch\2026-11-10_queue_read_snapshot.sql
-- ============================================================
SET NOCOUNT ON;

CREATE TABLE #Q (Ord INT IDENTITY, Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50),
    ItemDescription NVARCHAR(500), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20),
    LastMovementAt DATETIME2(3), NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);
CREATE TABLE #Out (Line NVARCHAR(50), ReadName NVARCHAR(20), RowsReturned INT, RowChecksum INT);

DECLARE @id BIGINT, @code NVARCHAR(50);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT l.Id, l.Code
    FROM Location.Location l
    JOIN Location.LocationTypeDefinition t ON t.Id = l.LocationTypeDefinitionId
    WHERE t.LocationTypeId = 4
      AND l.DeprecatedAt IS NULL
      AND EXISTS (SELECT 1 FROM Parts.ItemLocation il WHERE il.LocationId = l.Id AND il.DeprecatedAt IS NULL)
    ORDER BY l.Code;
OPEN c; FETCH NEXT FROM c INTO @id, @code;
WHILE @@FETCH_STATUS = 0
BEGIN
    TRUNCATE TABLE #Q;
    INSERT INTO #Q (Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, LotStatusId, LotStatusCode, LastMovementAt, NextOperationTypeCode, NextSequenceNumber)
        EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId = @id;
    INSERT INTO #Out SELECT @code, N'MachiningIn', COUNT(*),
        ISNULL(CHECKSUM_AGG(CHECKSUM(Ord, Id, PieceCount, LotStatusId, LastMovementAt, NextOperationTypeCode, NextSequenceNumber)), 0) FROM #Q;

    TRUNCATE TABLE #Q;
    INSERT INTO #Q (Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, LotStatusId, LotStatusCode, LastMovementAt, NextOperationTypeCode, NextSequenceNumber)
        EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @id, @OperationTypeCode = NULL, @IncludeDescendants = 1;
    INSERT INTO #Out SELECT @code, N'WipQueue', COUNT(*),
        ISNULL(CHECKSUM_AGG(CHECKSUM(Ord, Id, PieceCount, LotStatusId, LastMovementAt, NextOperationTypeCode, NextSequenceNumber)), 0) FROM #Q;

    FETCH NEXT FROM c INTO @id, @code;
END
CLOSE c; DEALLOCATE c;

SELECT Line, ReadName, RowsReturned, RowChecksum FROM #Out ORDER BY Line, ReadName;
SELECT SUM(RowsReturned) AS TotalRows, CHECKSUM_AGG(CHECKSUM(Line, ReadName, RowsReturned, RowChecksum)) AS TotalChecksum FROM #Out;
