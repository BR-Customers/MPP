SET NOCOUNT ON;
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'INSP-SORT-T1');
DECLARE @Pt BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-INSP-TP');
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PERF-GTR-FG');
DECLARE @Cases TABLE (Seq INT, Item BIGINT, Label NVARCHAR(40));
INSERT @Cases VALUES (1, @Pt, N'repack path (no BOM)'), (2, @Fg, N'BOM path (PassThrough child)');
CREATE TABLE #R (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), BoxQuantity INT, PiecesPerTray INT, Available INT, TraysLeft INT, IsShort BIT, ThresholdTrays INT);
DECLARE @Seq INT = 1, @Item BIGINT, @Label NVARCHAR(40), @i INT, @t0 DATETIME2(7), @ms DECIMAL(10,1), @cold DECIMAL(10,1), @sum DECIMAL(10,1), @min DECIMAL(10,1), @max DECIMAL(10,1), @cpu0 INT, @cpu1 INT;
WHILE @Seq <= 2
BEGIN
    SELECT @Item = Item, @Label = Label FROM @Cases WHERE Seq = @Seq;
    PRINT '=== ' + @Label + ' ===';
    TRUNCATE TABLE #R;
    SET STATISTICS IO ON;
    INSERT #R EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = @Cell, @FinishedGoodItemId = @Item, @ClosureMethod = N'ByCount';
    SET STATISTICS IO OFF;
    SELECT COUNT(*) AS Rows, MAX(Available) AS Available, MAX(TraysLeft) AS TraysLeft,
           CHECKSUM_AGG(CHECKSUM(ItemId, PartNumber, PiecesPerTray, Available, TraysLeft, IsShort, ThresholdTrays)) AS Checksum FROM #R;
    ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
    SET @t0 = SYSUTCDATETIME();
    INSERT #R EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = @Cell, @FinishedGoodItemId = @Item, @ClosureMethod = N'ByCount';
    SET @cold = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
    SET @i = 0; SET @sum = 0; SET @min = 999999; SET @max = 0;
    SET @cpu0 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);
    WHILE @i < 20
    BEGIN
        TRUNCATE TABLE #R; SET @t0 = SYSUTCDATETIME();
        INSERT #R EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = @Cell, @FinishedGoodItemId = @Item, @ClosureMethod = N'ByCount';
        SET @ms = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
        SET @sum += @ms; IF @ms < @min SET @min = @ms; IF @ms > @max SET @max = @ms; SET @i += 1;
    END
    SET @cpu1 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);
    PRINT CONCAT('TIMING cold ', @cold, ' ms | warm avg ', CAST(@sum / 20 AS DECIMAL(10,1)), ' ms (min ', @min, ', max ', @max, ') | warm CPU avg ', CAST((@cpu1 - @cpu0) / 20.0 AS DECIMAL(10,1)), ' ms');
    SET @Seq += 1;
END
DROP TABLE #R;
