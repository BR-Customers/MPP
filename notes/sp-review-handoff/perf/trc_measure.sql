SET NOCOUNT ON;
DECLARE @T1 BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE Code LIKE N'DC%' ORDER BY Id);
DECLARE @T2 BIGINT = (SELECT Id FROM Location.Location WHERE Code LIKE N'DC%' ORDER BY Id OFFSET 3 ROWS FETCH NEXT 1 ROWS ONLY);
DECLARE @Cases TABLE (Seq INT, Loc BIGINT, N INT, Label NVARCHAR(60));
INSERT @Cases VALUES (1, @T1, 15, N'die-cast terminal A, TOP 15 (the screen)'), (2, @T2, 15, N'die-cast terminal B, TOP 15'), (3, @T1, 100, N'terminal A, TOP 100');
CREATE TABLE #R (LotId BIGINT, LotName NVARCHAR(50), PieceCount INT, CavityText NVARCHAR(200), CreatedAt DATETIME2(3), RowNo INT IDENTITY(1,1));
DECLARE @Seq INT = 1, @Loc BIGINT, @N INT, @Label NVARCHAR(60), @i INT, @t0 DATETIME2(7), @ms DECIMAL(10,3), @cold DECIMAL(10,3), @sum DECIMAL(10,3), @min DECIMAL(10,3), @max DECIMAL(10,3), @cpu0 INT, @cpu1 INT;
WHILE @Seq <= 3
BEGIN
    SELECT @Loc = Loc, @N = N, @Label = Label FROM @Cases WHERE Seq = @Seq;
    PRINT '=== ' + @Label + ' ===';
    TRUNCATE TABLE #R;
    SET STATISTICS IO ON;
    INSERT #R (LotId, LotName, PieceCount, CavityText, CreatedAt) EXEC Lots.Lot_GetTerminalRecentCreations @TerminalLocationId = @Loc, @TopN = @N;
    SET STATISTICS IO OFF;
    SELECT COUNT(*) AS Rows, CHECKSUM_AGG(CHECKSUM(RowNo, LotId, LotName, PieceCount, CavityText, CreatedAt)) AS OrderedChecksum FROM #R;
    ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
    TRUNCATE TABLE #R; SET @t0 = SYSUTCDATETIME();
    INSERT #R (LotId, LotName, PieceCount, CavityText, CreatedAt) EXEC Lots.Lot_GetTerminalRecentCreations @TerminalLocationId = @Loc, @TopN = @N;
    SET @cold = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
    SET @i = 0; SET @sum = 0; SET @min = 999999; SET @max = 0;
    SET @cpu0 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);
    WHILE @i < 30
    BEGIN
        TRUNCATE TABLE #R; SET @t0 = SYSUTCDATETIME();
        INSERT #R (LotId, LotName, PieceCount, CavityText, CreatedAt) EXEC Lots.Lot_GetTerminalRecentCreations @TerminalLocationId = @Loc, @TopN = @N;
        SET @ms = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
        SET @sum += @ms; IF @ms < @min SET @min = @ms; IF @ms > @max SET @max = @ms; SET @i += 1;
    END
    SET @cpu1 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);
    PRINT CONCAT('TIMING cold ', @cold, ' ms | warm avg ', CAST(@sum / 30 AS DECIMAL(10,2)), ' ms (min ', @min, ', max ', @max, ') | warm CPU avg ', CAST((@cpu1 - @cpu0) / 30.0 AS DECIMAL(10,2)), ' ms  [30 warm calls]');
    SET @Seq += 1;
END
DROP TABLE #R;
