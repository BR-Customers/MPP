-- =============================================
-- File: 0097_DieCast_Reconciliation/060_Save_Refusals.sql
-- Everything the save refuses, and the words it refuses with (spec sec 5.2,
-- 7.4, sec 8). Every one of these is a clean Status = 0 row -- no exception,
-- no open transaction (the Msg 3915 rule).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/060_Save_Refusals.sql';
GO
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700501', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700501', @ShiftKey = N'S4', @Pieces = 100, @Reading = 110, @AtUtc = '2020-01-07T13:00:00';
GO

CREATE TABLE #Res (Status BIT, Message NVARCHAR(500), NewId BIGINT);
GO

DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @S1 BIGINT = test.ufn_RC(N'S1');
DECLARE @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700501');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Other  BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'Other');
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @Code999 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999');
DECLARE @m NVARCHAR(500);

-- a stale stamp
DELETE FROM #Res;
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @LoadedStamp = N'0.0.0.0.0', @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a shift that changed since it was loaded', @HaystackStr = @m, @NeedleStr = N'changed since you opened it';

-- Other without a note
DELETE FROM #Res;
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Other,
    @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] Other needs a note', @HaystackStr = @m, @NeedleStr = N'needs a note';

-- the die was never mounted on that press
DECLARE @OtherCell BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                             INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
                             WHERE d.Code = N'DieCastMachine' AND l.Id <> @Cell ORDER BY l.Id);
IF @OtherCell IS NOT NULL
BEGIN
    DECLARE @StampOther NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @OtherCell, @Tool);
    DELETE FROM #Res;
    INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
        @ShiftId = @S4, @CellLocationId = @OtherCell, @ToolId = @Tool, @ReasonId = @Reason,
        @LoadedStamp = @StampOther, @AppUserId = @Usr;
    SET @m = (SELECT Message FROM #Res);
    EXEC test.Assert_Contains @TestName = N'[Refuse] the die was not mounted on that press', @HaystackStr = @m, @NeedleStr = N'was not mounted on';
END

-- production on record with no actual figure (the orphan check)
DELETE FROM #Res;
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":110,"goodShots":100,"warmUpShots":10}';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = N'[]', @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a LOT on record with no actual figure', @HaystackStr = @m, @NeedleStr = N'no actual figure';
EXEC test.Assert_Contains @TestName = N'[Refuse] ...naming it', @HaystackStr = @m, @NeedleStr = N'99700501';

-- the totals do not add up
DELETE FROM #Res;
DECLARE @Lots NVARCHAR(MAX) = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":190}]';
SET @Actual = N'{"totalShots":111,"goodShots":100,"warmUpShots":10}';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] total shots must equal good + warm-up', @HaystackStr = @m, @NeedleStr = N'has a typo';

-- the LOT list does not equal total good
DELETE FROM #Res;
SET @Actual = N'{"totalShots":110,"goodShots":100,"warmUpShots":10}';
SET @Lots = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":150}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] the LOT list must equal actual total good', @HaystackStr = @m, @NeedleStr = N'LOT list totals';

-- one LOT holding more than the shift made
DELETE FROM #Res;
SET @Lots = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":200}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a LOT cannot hold more than the shift''s good shots', @HaystackStr = @m, @NeedleStr = N'More pieces than';

-- an LTT from another die
DELETE FROM #Res;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700502', @CavKey = N'CavA', @StatusCode = N'Good';
UPDATE Lots.Lot SET ToolId = NULL WHERE LotName = N'99700502';
SET @Lots = N'[{"ltt":"99700502","quantity":10}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] an LTT that is not a LOT from this die', @HaystackStr = @m, @NeedleStr = N'Not a LOT from';

-- a malformed LTT
DELETE FROM #Res;
SET @Lots = N'[{"ltt":"12345","toolCavityId":' + CAST(test.ufn_RC(N'CavA') AS NVARCHAR(20)) + N',"quantity":10}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] not a valid LTT', @HaystackStr = @m, @NeedleStr = N'8 or 9 digits';

-- a reject amount that does not divide across the cavities it covers
DELETE FROM #Res;
SET @Lots = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":189}]';
DECLARE @Rej NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"quantity":11}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a reject amount that will not divide across the cavities', @HaystackStr = @m, @NeedleStr = N'does not divide evenly';

-- warm-up is not a reject line
DELETE FROM #Res;
SET @Rej = N'[{"defectCodeId":' + CAST(@Code999 AS NVARCHAR(20)) + N',"quantity":10}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] warm-up belongs in warm-up shots', @HaystackStr = @m, @NeedleStr = N'entered as warm-up shots';

-- a move to a shift more than two away
DELETE FROM #Res;
DECLARE @C BIGINT = (SELECT Id FROM Workorder.DieCastContribution WHERE LotId = @Lot AND PieceDelta = 100);
DECLARE @Moves NVARCHAR(MAX) = N'[{"entityType":"Contribution","entityId":' + CAST(@C AS NVARCHAR(20))
    + N',"toShiftId":' + CAST(@S1 AS NVARCHAR(20)) + N'}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @MovesJson = @Moves, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a move further than two shifts away', @HaystackStr = @m, @NeedleStr = N'within two shifts';

-- nothing to do
DELETE FROM #Res;
SET @Lots = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":100}]';
SET @Actual = N'{"totalShots":110,"goodShots":100,"warmUpShots":5}';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] totals that still do not add up', @HaystackStr = @m, @NeedleStr = N'has a typo';

-- nothing was written by ANY of the refusals
DECLARE @v NVARCHAR(50) = CAST((SELECT COUNT(*) FROM Workorder.DieCastShiftReconciliation WHERE ToolId = @Tool) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Refuse] not one refusal wrote a header row', @Expected = N'0', @Actual = @v;
SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @Lot) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Refuse] and no LOT count moved', @Expected = N'100', @Actual = @v;
GO

DROP TABLE #Res;
EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
