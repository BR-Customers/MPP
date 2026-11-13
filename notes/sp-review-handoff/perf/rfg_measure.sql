SET NOCOUNT ON;
-- make the perf finished good eligible at the inspection station (idempotent)
DECLARE @Station BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'INSP-SORT-T1');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PERF-GTR-FG');
IF @Fg IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Fg AND LocationId = @Station AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Fg, @Station, 0, SYSUTCDATETIME());
DECLARE @Cases TABLE (Seq INT, Loc BIGINT, Label NVARCHAR(80));
INSERT @Cases VALUES (1, @Station, N'inspection station (2,280 LOTs of the part)'), (2, @Cell, N'assembly cell 46');
CREATE TABLE #R (Id BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LinesSatisfied INT, IsRecommended INT, RowNo INT IDENTITY(1,1));
DECLARE @Seq INT = 1, @Loc BIGINT, @Label NVARCHAR(60), @i INT, @t0 DATETIME2(7), @ms DECIMAL(10,3), @cold DECIMAL(10,3), @sum DECIMAL(10,3), @min DECIMAL(10,3), @max DECIMAL(10,3), @cpu0 INT, @cpu1 INT;
WHILE @Seq <= 2
BEGIN
    SELECT @Loc = Loc, @Label = Label FROM @Cases WHERE Seq = @Seq;
    PRINT '=== ' + @Label + ' ===';
    TRUNCATE TABLE #R;
    SET STATISTICS IO ON;
    INSERT #R (Id, PartNumber, Description, LinesSatisfied, IsRecommended) EXEC Parts.Item_ListEligibleFinishedGoodsRanked @LocationId = @Loc;
    SET STATISTICS IO OFF;
    SELECT COUNT(*) AS Rows, MAX(LinesSatisfied) AS MaxLines, CHECKSUM_AGG(CHECKSUM(RowNo, Id, PartNumber, LinesSatisfied, IsRecommended)) AS OrderedChecksum FROM #R;
    ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
    TRUNCATE TABLE #R; SET @t0 = SYSUTCDATETIME();
    INSERT #R (Id, PartNumber, Description, LinesSatisfied, IsRecommended) EXEC Parts.Item_ListEligibleFinishedGoodsRanked @LocationId = @Loc;
    SET @cold = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
    SET @i = 0; SET @sum = 0; SET @min = 999999; SET @max = 0;
    SET @cpu0 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);
    WHILE @i < 20
    BEGIN
        TRUNCATE TABLE #R; SET @t0 = SYSUTCDATETIME();
        INSERT #R (Id, PartNumber, Description, LinesSatisfied, IsRecommended) EXEC Parts.Item_ListEligibleFinishedGoodsRanked @LocationId = @Loc;
        SET @ms = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
        SET @sum += @ms; IF @ms < @min SET @min = @ms; IF @ms > @max SET @max = @ms; SET @i += 1;
    END
    SET @cpu1 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);
    PRINT CONCAT('TIMING cold ', @cold, ' ms | warm avg ', CAST(@sum / 20 AS DECIMAL(10,2)), ' ms (min ', @min, ', max ', @max, ') | warm CPU avg ', CAST((@cpu1 - @cpu0) / 20.0 AS DECIMAL(10,2)), ' ms  [20 warm calls]');
    SET @Seq += 1;
END
DROP TABLE #R;
