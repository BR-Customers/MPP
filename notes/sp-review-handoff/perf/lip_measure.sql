SET NOCOUNT ON;
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Station BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'INSP-SORT-T1');
DECLARE @Cases TABLE (Seq INT, Loc BIGINT, Ex BIT, Label NVARCHAR(40));
INSERT @Cases VALUES (1, @Cell, 0, N'cell 46, all parts'), (2, @Cell, 1, N'cell 46, exclude FG'), (3, @Station, 0, N'station (40 open LOTs)');
CREATE TABLE #R (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LotId BIGINT, LotName NVARCHAR(50), InventoryAvailable INT, ArrivedAt DATETIME2(3), LotStatusCode NVARCHAR(20), RowNo INT IDENTITY(1,1));
DECLARE @Seq INT = 1, @Loc BIGINT, @Ex BIT, @Label NVARCHAR(40), @i INT, @t0 DATETIME2(7), @ms DECIMAL(10,1), @cold DECIMAL(10,1), @sum DECIMAL(10,1), @min DECIMAL(10,1), @max DECIMAL(10,1), @cpu0 INT, @cpu1 INT;
WHILE @Seq <= 3
BEGIN
    SELECT @Loc = Loc, @Ex = Ex, @Label = Label FROM @Cases WHERE Seq = @Seq;
    PRINT '=== ' + @Label + ' ===';
    TRUNCATE TABLE #R;
    SET STATISTICS IO ON;
    INSERT #R (ItemId, PartNumber, Description, LotId, LotName, InventoryAvailable, ArrivedAt, LotStatusCode)
        EXEC Lots.Lot_GetLineInventoryByPart @LocationId = @Loc, @ExcludeFinishedGoods = @Ex;
    SET STATISTICS IO OFF;
    SELECT COUNT(*) AS Rows, CHECKSUM_AGG(CHECKSUM(RowNo, ItemId, PartNumber, LotId, LotName, InventoryAvailable, ArrivedAt, LotStatusCode)) AS OrderedChecksum FROM #R;
    ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
    TRUNCATE TABLE #R; SET @t0 = SYSUTCDATETIME();
    INSERT #R (ItemId, PartNumber, Description, LotId, LotName, InventoryAvailable, ArrivedAt, LotStatusCode) EXEC Lots.Lot_GetLineInventoryByPart @LocationId = @Loc, @ExcludeFinishedGoods = @Ex;
    SET @cold = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
    SET @i = 0; SET @sum = 0; SET @min = 999999; SET @max = 0;
    SET @cpu0 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);
    WHILE @i < 20
    BEGIN
        TRUNCATE TABLE #R; SET @t0 = SYSUTCDATETIME();
        INSERT #R (ItemId, PartNumber, Description, LotId, LotName, InventoryAvailable, ArrivedAt, LotStatusCode) EXEC Lots.Lot_GetLineInventoryByPart @LocationId = @Loc, @ExcludeFinishedGoods = @Ex;
        SET @ms = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
        SET @sum += @ms; IF @ms < @min SET @min = @ms; IF @ms > @max SET @max = @ms; SET @i += 1;
    END
    SET @cpu1 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);
    PRINT CONCAT('TIMING cold ', @cold, ' ms | warm avg ', CAST(@sum / 20 AS DECIMAL(10,1)), ' ms (min ', @min, ', max ', @max, ') | warm CPU avg ', CAST((@cpu1 - @cpu0) / 20.0 AS DECIMAL(10,1)), ' ms');
    SET @Seq += 1;
END
DROP TABLE #R;
