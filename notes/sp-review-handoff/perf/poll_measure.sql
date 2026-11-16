SET NOCOUNT ON;
DECLARE @Station BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'INSP-SORT-T1');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Pt BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-INSP-TP');
CREATE TABLE #Q (ExistingPieceCount BIGINT);
CREATE TABLE #S (ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT, Level NVARCHAR(10), BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
DECLARE @i INT, @t0 DATETIME2(7), @ms DECIMAL(10,3), @sum DECIMAL(10,3), @min DECIMAL(10,3), @max DECIMAL(10,3), @cold DECIMAL(10,3);

PRINT '=== Lot_GetCellLineQuantity (station, the purchased part: 2,280 LOTs of it there) ===';
SET STATISTICS IO ON; INSERT #Q EXEC Lots.Lot_GetCellLineQuantity @LocationId = @Station, @ItemId = @Pt; SET STATISTICS IO OFF;
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
SET @t0 = SYSUTCDATETIME(); TRUNCATE TABLE #Q; INSERT #Q EXEC Lots.Lot_GetCellLineQuantity @LocationId = @Station, @ItemId = @Pt; SET @cold = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
SET @i = 0; SET @sum = 0; SET @min = 999999; SET @max = 0;
WHILE @i < 30 BEGIN TRUNCATE TABLE #Q; SET @t0 = SYSUTCDATETIME(); INSERT #Q EXEC Lots.Lot_GetCellLineQuantity @LocationId = @Station, @ItemId = @Pt; SET @ms = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0; SET @sum += @ms; IF @ms < @min SET @min = @ms; IF @ms > @max SET @max = @ms; SET @i += 1; END
DECLARE @res BIGINT = (SELECT ExistingPieceCount FROM #Q);
PRINT CONCAT('TIMING cold ', @cold, ' ms | warm avg ', CAST(@sum / 30 AS DECIMAL(10,2)), ' ms (min ', @min, ', max ', @max, ') [30 warm calls]  result=', @res);

PRINT '=== Lot_GetLineInventorySummary (assembly cell 46, AssemblyOut role) ===';
TRUNCATE TABLE #S;
SET STATISTICS IO ON; INSERT #S EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Cell, @TerminalRole = N'AssemblyOut', @LineWide = 0; SET STATISTICS IO OFF;
SELECT COUNT(*) AS Rows FROM #S;
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
SET @t0 = SYSUTCDATETIME(); TRUNCATE TABLE #S; INSERT #S EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Cell, @TerminalRole = N'AssemblyOut', @LineWide = 0; SET @cold = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0;
SET @i = 0; SET @sum = 0; SET @min = 999999; SET @max = 0;
WHILE @i < 30 BEGIN TRUNCATE TABLE #S; SET @t0 = SYSUTCDATETIME(); INSERT #S EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Cell, @TerminalRole = N'AssemblyOut', @LineWide = 0; SET @ms = DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()) / 1000.0; SET @sum += @ms; IF @ms < @min SET @min = @ms; IF @ms > @max SET @max = @ms; SET @i += 1; END
PRINT CONCAT('TIMING cold ', @cold, ' ms | warm avg ', CAST(@sum / 30 AS DECIMAL(10,2)), ' ms (min ', @min, ', max ', @max, ') [30 warm calls]');
DROP TABLE #Q; DROP TABLE #S;
