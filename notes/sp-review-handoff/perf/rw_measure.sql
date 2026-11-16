SET NOCOUNT ON;
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Cell);
DECLARE @Site BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE ParentLocationId IS NULL);
DECLARE @Cases TABLE (Seq INT, Loc BIGINT, Label NVARCHAR(40));
INSERT @Cases VALUES (1, @Line, N'line (and everything under it)'), (2, @Cell, N'single cell'), (3, @Site, N'whole site');
CREATE TABLE #R (ContainerId BIGINT, PartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), Pieces INT, TargetParts INT, ShortBy INT, PartsPerTray INT, RunNumber NVARCHAR(50), RowNo INT IDENTITY(1,1));
DECLARE @Seq INT = 1, @Loc BIGINT, @Label NVARCHAR(40), @i INT, @t0 DATETIME2(7), @ms DECIMAL(10,3), @cold DECIMAL(10,3), @sum DECIMAL(10,3), @min DECIMAL(10,3), @max DECIMAL(10,3), @cpu0 INT, @cpu1 INT;
WHILE @Seq <= 3
BEGIN
    SELECT @Loc = Loc, @Label = Label FROM @Cases WHERE Seq = @Seq;
    PRINT '=== ' + @Label + ' ===';
    TRUNCATE TABLE #R;
    SET STATISTICS IO ON;
    INSERT #R (ContainerId, PartNumber, ItemDescription, Pieces, TargetParts, ShortBy, PartsPerTray, RunNumber) EXEC Lots.ContainerRework_ListAtLocation @LocationId = @Loc;
    SET STATISTICS IO OFF;
    SELECT COUNT(*) AS Rows, CHECKSUM_AGG(CHECKSUM(RowNo, ContainerId, PartNumber, Pieces, TargetParts, ShortBy, PartsPerTray, RunNumber)) AS OrderedChecksum FROM #R;
    ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
    TRUNCATE TABLE #R; SET @t0 = SYSUTCDATETIME();
    INSERT #R (ContainerId, PartNumber, ItemDescription, Pieces, TargetParts, ShortBy, PartsPerTray, RunNumber) EXEC Lots.ContainerRework_ListAtLocation @LocationId = @Loc;
    SET @cold = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
    SET @i = 0; SET @sum = 0; SET @min = 999999; SET @max = 0;
    SET @cpu0 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);
    WHILE @i < 30
    BEGIN
        TRUNCATE TABLE #R; SET @t0 = SYSUTCDATETIME();
        INSERT #R (ContainerId, PartNumber, ItemDescription, Pieces, TargetParts, ShortBy, PartsPerTray, RunNumber) EXEC Lots.ContainerRework_ListAtLocation @LocationId = @Loc;
        SET @ms = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
        SET @sum += @ms; IF @ms < @min SET @min = @ms; IF @ms > @max SET @max = @ms; SET @i += 1;
    END
    SET @cpu1 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);
    PRINT CONCAT('TIMING cold ', @cold, ' ms | warm avg ', CAST(@sum / 30 AS DECIMAL(10,2)), ' ms (min ', @min, ', max ', @max, ') | warm CPU avg ', CAST((@cpu1 - @cpu0) / 30.0 AS DECIMAL(10,2)), ' ms  [30 warm calls]');
    SET @Seq += 1;
END
DROP TABLE #R;
