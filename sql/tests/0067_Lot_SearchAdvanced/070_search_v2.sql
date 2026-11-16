-- =============================================
-- File:         0067_Lot_SearchAdvanced/070_search_v2.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-04
-- Description:  Lot_Search v2 / Lot_SearchAdvanced (container-as-LOT spec 8.2):
--               an exact LOT name is found whatever its age; every other match
--               (partial name, part number, vendor LOT) looks at the last 90 days
--               unless @IncludeOlder = 1 (Advanced: or an explicit date range);
--               no COUNT(*) OVER() -- TotalCount = rows returned, HasMore = there
--               were more than @LimitRows.
--               Fixture: one LOT 200 days old (T118-080-OLD); 101 recent LOTs of
--               part P118-SRCH (T118-080-R001..R101).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0067_Lot_SearchAdvanced/070_search_v2.sql';
GO

CREATE OR ALTER PROCEDURE dbo.T118_Shape @Proc NVARCHAR(200)
AS
BEGIN
    IF OBJECT_ID('tempdb..##R118') IS NOT NULL DROP TABLE ##R118;
    DECLARE @cols NVARCHAR(MAX) = (
        SELECT STRING_AGG(CAST(QUOTENAME(name) + N' ' + system_type_name + N' NULL' AS NVARCHAR(MAX)), N', ')
               WITHIN GROUP (ORDER BY column_ordinal)
        FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID(@Proc), 0));
    EXEC (N'CREATE TABLE ##R118 (' + @cols + N')');
END;
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Loc BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
VALUES (3, N'P118-SRCH', N'0118 search part', 1, @Now, 1);
DECLARE @Item BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'T118-080-OLD', @Item, 1, 1, 1, @Loc, 1, DATEADD(DAY, -200, @Now));
;WITH n AS (SELECT TOP (101) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS k FROM sys.all_objects)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAt)
SELECT N'T118-080-R' + RIGHT(N'000' + CAST(k AS NVARCHAR(3)), 3), @Item, 1, 1, 1, @Loc, 1, DATEADD(MINUTE, -k, @Now) FROM n;
GO

DECLARE @c BIT, @has BIT, @n INT;

EXEC dbo.T118_Shape N'Lots.Lot_Search';
SET @c = CASE WHEN COL_LENGTH('tempdb..##R118', 'HasMore') IS NOT NULL THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Search] result carries HasMore', @Condition = @c;
IF @c = 0 GOTO Done;

INSERT INTO ##R118 EXEC Lots.Lot_Search @Query = N'T118-080-OLD';
SET @c = CASE WHEN (SELECT COUNT(*) FROM ##R118) = 1 AND (SELECT LotName FROM ##R118) = N'T118-080-OLD' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Search] a 200-day-old LOT is found by its exact name', @Condition = @c;

DELETE FROM ##R118;
INSERT INTO ##R118 EXEC Lots.Lot_Search @Query = N'T118-080-OL';
SET @c = CASE WHEN NOT EXISTS (SELECT 1 FROM ##R118) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Search] a partial name outside the 90-day window is not found by default', @Condition = @c;

DELETE FROM ##R118;
INSERT INTO ##R118 EXEC Lots.Lot_Search @Query = N'T118-080-OL', @IncludeOlder = 1;
SET @c = CASE WHEN (SELECT COUNT(*) FROM ##R118) = 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Search] ... and is found with @IncludeOlder = 1', @Condition = @c;

DELETE FROM ##R118;
INSERT INTO ##R118 EXEC Lots.Lot_Search @Query = N'T118-080-R';
EXEC sp_executesql N'SELECT @n = COUNT(*), @has = MAX(CAST(HasMore AS INT)) FROM ##R118 WHERE TotalCount = 100',
    N'@n INT OUTPUT, @has BIT OUTPUT', @n = @n OUTPUT, @has = @has OUTPUT;
SET @c = CASE WHEN @n = 100 AND @has = 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Search] 101 matches -> 100 rows, TotalCount 100, HasMore 1', @Condition = @c;

DELETE FROM ##R118;
INSERT INTO ##R118 EXEC Lots.Lot_Search @Query = N'P118-SRCH';
SET @c = CASE WHEN (SELECT COUNT(*) FROM ##R118) = 100
               AND NOT EXISTS (SELECT 1 FROM ##R118 WHERE LotName = N'T118-080-OLD') THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Search] part number finds the part''s recent LOTs (not the 200-day-old one)', @Condition = @c;

DELETE FROM ##R118;
INSERT INTO ##R118 EXEC Lots.Lot_Search @Query = N'T118-080-R101', @LimitRows = 5;
SET @c = CASE WHEN (SELECT COUNT(*) FROM ##R118) = 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Search] an exact name is not returned twice (exact + window)', @Condition = @c;

-- an exact name answers alone: R010 is also contained in no other name, R10 is in R100 / R101
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
SELECT N'T118-080-R10', ItemId, 1, 1, 1, CurrentLocationId, 1 FROM Lots.Lot WHERE LotName = N'T118-080-R001';
DELETE FROM ##R118;
INSERT INTO ##R118 EXEC Lots.Lot_Search @Query = N'T118-080-R10';
SET @c = CASE WHEN (SELECT COUNT(*) FROM ##R118) = 1 AND (SELECT LotName FROM ##R118) = N'T118-080-R10' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Search] an exact LOT name returns that LOT alone (no window scan for R100 / R101)', @Condition = @c;
EXEC dbo.T118_Shape N'Lots.Lot_SearchAdvanced';
INSERT INTO ##R118 EXEC Lots.Lot_SearchAdvanced @Query = N'T118-080-R10';
SET @c = CASE WHEN (SELECT COUNT(*) FROM ##R118) = 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Advanced] an exact LOT name returns that LOT alone', @Condition = @c;
EXEC dbo.T118_Shape N'Lots.Lot_Search';

-- Advanced: an explicit date range replaces the window
EXEC dbo.T118_Shape N'Lots.Lot_SearchAdvanced';
DECLARE @From DATE = CAST(DATEADD(DAY, -210, SYSUTCDATETIME()) AS DATE), @To DATE = CAST(DATEADD(DAY, -190, SYSUTCDATETIME()) AS DATE);
INSERT INTO ##R118 EXEC Lots.Lot_SearchAdvanced @Query = N'T118-080-OL', @CreatedFromEt = @From, @CreatedToEt = @To;
SET @c = CASE WHEN (SELECT COUNT(*) FROM ##R118) = 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Advanced] an explicit date range overrides the 90-day window', @Condition = @c;
DELETE FROM ##R118;
INSERT INTO ##R118 EXEC Lots.Lot_SearchAdvanced @Query = N'T118-080-OL';
SET @c = CASE WHEN NOT EXISTS (SELECT 1 FROM ##R118) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Advanced] no range: partial name limited to the window', @Condition = @c;

-- Advanced: a shift is an explicit time scope -- a LOT of a 200-day-old shift is found
DECLARE @OldLot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-080-OLD');
INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'T118-080-SCHED', '06:00:00', '14:00:00', 127, '2020-01-01', 1);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (SCOPE_IDENTITY(), DATEADD(DAY, -200, SYSUTCDATETIME()), DATEADD(HOUR, 8, DATEADD(DAY, -200, SYSUTCDATETIME())), N'T118-080-SHIFT');
DECLARE @OldShift BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'T118-080-SHIFT');
INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, EventAt, AppUserId, ShiftAttributionSourceId)
VALUES (@OldLot, @OldShift, 1, DATEADD(DAY, -200, SYSUTCDATETIME()), 1, (SELECT TOP 1 Id FROM Oee.ShiftAttributionSource ORDER BY Id));
EXEC dbo.T118_Shape N'Lots.Lot_SearchAdvanced';
INSERT INTO ##R118 EXEC Lots.Lot_SearchAdvanced @ShiftId = @OldShift;
SET @c = CASE WHEN (SELECT COUNT(*) FROM ##R118) = 1 AND (SELECT LotName FROM ##R118) = N'T118-080-OLD' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Advanced] a shift filter replaces the window: a 200-day-old shift''s LOT is found', @Condition = @c;
DELETE FROM Workorder.DieCastContribution WHERE LotId = @OldLot;
DELETE FROM Oee.Shift WHERE Id = @OldShift;
DELETE FROM Oee.ShiftSchedule WHERE Name = N'T118-080-SCHED';

Done:
DROP TABLE IF EXISTS ##R118;
GO
DROP PROCEDURE IF EXISTS dbo.T118_Shape;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
