SET NOCOUNT ON;
DECLARE @Station BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'INSP-SORT-T1');
DECLARE @Parent  BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Station);

CREATE TABLE #R (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, VendorLotNumber NVARCHAR(50), LotStatusId BIGINT, LotStatusCode NVARCHAR(20),
    LatestInspectionResult NVARCHAR(20), LatestSampledAt DATETIME2(3), ArrivedAt DATETIME2(3));

DECLARE @Cases TABLE (Seq INT, Loc BIGINT, D BIT, Label NVARCHAR(40));
INSERT @Cases VALUES (1, @Station, 0, N'station exact (wrapper default)'), (2, @Station, 1, N'station +desc'), (3, @Parent, 1, N'parent +desc');

DECLARE @Seq INT = 1, @Loc BIGINT, @D BIT, @Label NVARCHAR(40), @i INT, @t0 DATETIME2(7), @ms DECIMAL(10,1);
DECLARE @cold DECIMAL(10,1), @sum DECIMAL(10,1), @min DECIMAL(10,1), @max DECIMAL(10,1), @rows INT, @cpu0 INT, @cpu1 INT;

WHILE @Seq <= 3
BEGIN
    SELECT @Loc = Loc, @D = D, @Label = Label FROM @Cases WHERE Seq = @Seq;

    ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
    TRUNCATE TABLE #R;
    SET @t0 = SYSUTCDATETIME();
    INSERT #R EXEC Lots.Lot_GetInspectionQueueByLocation @LocationId = @Loc, @IncludeDescendants = @D;
    SET @cold = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
    SET @rows = (SELECT COUNT(*) FROM #R);

    SET @i = 0; SET @sum = 0; SET @min = 999999; SET @max = 0;
    SET @cpu0 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);
    WHILE @i < 20
    BEGIN
        TRUNCATE TABLE #R;
        SET @t0 = SYSUTCDATETIME();
        INSERT #R EXEC Lots.Lot_GetInspectionQueueByLocation @LocationId = @Loc, @IncludeDescendants = @D;
        SET @ms = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
        SET @sum += @ms; IF @ms < @min SET @min = @ms; IF @ms > @max SET @max = @ms;
        SET @i += 1;
    END
    SET @cpu1 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);

    PRINT CONCAT(RIGHT(CONCAT('                                   ', @Label), 32), ' | rows ', RIGHT(CONCAT('    ', @rows), 4),
                 ' | cold first call ', RIGHT(CONCAT('       ', @cold), 8), ' ms | warm avg ', RIGHT(CONCAT('      ', CAST(@sum / 20 AS DECIMAL(10,1))), 7),
                 ' ms (min ', @min, ', max ', @max, ') | warm CPU avg ', CAST((@cpu1 - @cpu0) / 20.0 AS DECIMAL(10,1)), ' ms');
    SET @Seq += 1;
END
DROP TABLE #R;
