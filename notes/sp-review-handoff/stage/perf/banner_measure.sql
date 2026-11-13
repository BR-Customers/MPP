SET NOCOUNT ON;
CREATE TABLE #R (Id BIGINT, ContainerId BIGINT, TerminalLocationId BIGINT, AimShipperId NVARCHAR(50), LastPrintError NVARCHAR(500), LastPrintErrorCondition NVARCHAR(50));
SET STATISTICS IO ON;
INSERT #R EXEC Lots.ShippingLabel_GetForBanner;
SET STATISTICS IO OFF;
SELECT COUNT(*) AS Rows, CHECKSUM_AGG(CHECKSUM(Id, ContainerId, TerminalLocationId, AimShipperId, LastPrintError, LastPrintErrorCondition)) AS Checksum FROM #R;
DECLARE @i INT, @t0 DATETIME2(7), @ms DECIMAL(10,3), @cold DECIMAL(10,3), @sum DECIMAL(10,3) = 0, @min DECIMAL(10,3) = 999999, @max DECIMAL(10,3) = 0, @cpu0 INT, @cpu1 INT;
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
TRUNCATE TABLE #R; SET @t0 = SYSUTCDATETIME();
INSERT #R EXEC Lots.ShippingLabel_GetForBanner;
SET @cold = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
SET @i = 0; SET @cpu0 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);
WHILE @i < 50
BEGIN
    TRUNCATE TABLE #R; SET @t0 = SYSUTCDATETIME();
    INSERT #R EXEC Lots.ShippingLabel_GetForBanner;
    SET @ms = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
    SET @sum += @ms; IF @ms < @min SET @min = @ms; IF @ms > @max SET @max = @ms; SET @i += 1;
END
SET @cpu1 = (SELECT cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID);
PRINT CONCAT('TIMING cold ', @cold, ' ms | warm avg ', CAST(@sum / 50 AS DECIMAL(10,3)), ' ms (min ', @min, ', max ', @max, ') | warm CPU avg ', CAST((@cpu1 - @cpu0) / 50.0 AS DECIMAL(10,2)), ' ms  [50 warm calls]');
DROP TABLE #R;
