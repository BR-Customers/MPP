-- =============================================
-- File: 0097_DieCast_Reconciliation/070_Save_Writes.sql
-- The three shapes the design was written against, on the fixture die:
--   A  an entry filed against the wrong shift, and the shift's own production
--      missing (Machine 11, 09-17);
--   B  a shift with NOTHING recorded, entered from its LTTs (Machine 202);
--   C  a reduction -- recorded is higher than actual.
-- Shift end S4 = 15:00 ET = 20:00 UTC, so backfilled rows land at 19:59:59 (A1).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/070_Save_Writes.sql';
GO
EXEC test.DieCastRecon_Setup;
-- the two LOTs the misfiled entry credited (released, then counted at trim)
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700601', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700602', @CavKey = N'CavB', @StatusCode = N'Good';
-- the two LOTs this shift's production belongs in: one correctable, one locked
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700603', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700604', @CavKey = N'CavB', @StatusCode = N'Good';
GO
-- the misfiled entry: the NIGHT shift's numbers, filed under S4, entered 08:35 ET
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700601', @ShiftKey = N'S4', @Pieces = 953, @Reading = 991, @AtUtc = '2020-01-07T13:35:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700602', @ShiftKey = N'S4', @Pieces = 953, @Reading = 991, @AtUtc = '2020-01-07T13:35:01';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavA', @DefectCode = N'999', @Qty = 35, @AtUtc = '2020-01-07T13:35:02';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavB', @DefectCode = N'999', @Qty = 35, @AtUtc = '2020-01-07T13:35:02';
-- earlier production already in the two S4 LOTs, from S2
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700603', @ShiftKey = N'S2', @Pieces = 500, @Reading = 500, @AtUtc = '2020-01-06T22:00:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700604', @ShiftKey = N'S2', @Pieces = 500, @Reading = 500, @AtUtc = '2020-01-06T22:00:01';
GO
-- 99700604 has been counted at trim: its count stands (spec 3.3)
DECLARE @Tmpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
                        INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
                        WHERE oty.Code <> N'DieCast' ORDER BY ot.Id);
IF @Tmpl IS NOT NULL
    INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId)
    SELECT l.Id, @Tmpl, '2020-01-08T14:00:00', test.ufn_RC(N'Usr') FROM Lots.Lot l WHERE l.LotName = N'99700604';
GO

-- ============ A: move the misfiled entry, then backfill the shift ============
DECLARE @S3 BIGINT = test.ufn_RC(N'S3'), @S4 BIGINT = test.ufn_RC(N'S4');
DECLARE @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @L3 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700603');
DECLARE @L4 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700604');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

DECLARE @Moves NVARCHAR(MAX) = (
    SELECT STRING_AGG(x.j, N',') FROM (
        SELECT N'{"entityType":"Contribution","entityId":' + CAST(c.Id AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S3 AS NVARCHAR(20)) + N'}' AS j
        FROM Workorder.DieCastContribution c INNER JOIN Lots.Lot l ON l.Id = c.LotId
        WHERE c.ShiftId = @S4 AND l.LotName IN (N'99700601', N'99700602')
        UNION ALL
        SELECT N'{"entityType":"Reject","entityId":' + CAST(r.Id AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S3 AS NVARCHAR(20)) + N'}'
        FROM Workorder.RejectEvent r WHERE r.ShiftId = @S4 AND r.ToolId = @Tool) x);
SET @Moves = N'[' + @Moves + N']';

-- actual: 1121 shots, 1083 good, 38 warm-up; 6 test parts across 2 cavities;
-- total good = 1083 x 2 - 6 = 2160, so 1080 in each of the two LOTs.
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":1121,"goodShots":1083,"warmUpShots":38}';
DECLARE @Lots NVARCHAR(MAX) = N'[{"lotId":' + CAST(@L3 AS NVARCHAR(20)) + N',"quantity":1080},'
                            + N'{"lotId":' + CAST(@L4 AS NVARCHAR(20)) + N',"quantity":1080}]';
DECLARE @Rej NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"quantity":6,"approvedByUserId":' + CAST(@Usr AS NVARCHAR(20)) + N'}]';

CREATE TABLE #A (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #A EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @MovesJson = @Moves, @LotsJson = @Lots, @RejectsJson = @Rej,
    @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecId BIGINT = (SELECT NewId FROM #A);
SET @v = CAST((SELECT Status FROM #A) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the save succeeds', @Expected = N'1', @Actual = @v;
DROP TABLE #A;

SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution c INNER JOIN Lots.Lot l ON l.Id = c.LotId
               WHERE c.ShiftId = @S3 AND l.LotName IN (N'99700601', N'99700602')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the misfiled credits now belong to the night shift', @Expected = N'2', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE ShiftId = @S3 AND ToolId = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] so did its warm-up rows', @Expected = N'2', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastReconciliationMove WHERE ReconciliationId = @RecId) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] every moved row is recorded', @Expected = N'4', @Actual = @v;

SET @v = (SELECT CONCAT(SUM(PieceDelta), N'|', COUNT(*)) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecId);
EXEC test.Assert_IsEqual @TestName = N'[A] the shift''s own 2,160 pieces are credited, one row per LOT', @Expected = N'2160|2', @Actual = @v;
SET @v = (SELECT CONVERT(NVARCHAR(19), MIN(EventAt), 126) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecId);
EXEC test.Assert_IsEqual @TestName = N'[A] backfilled one second inside the shift (A1)', @Expected = N'2020-01-07T19:59:59', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecId AND ShotCounterReading IS NOT NULL) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] a reconciliation credit carries no reading -- the anchor does (A3)', @Expected = N'0', @Actual = @v;

SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @L3) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the released, unlocked LOT is corrected 500 -> 1,580', @Expected = N'1580', @Actual = @v;
SET @v = (SELECT TOP 1 Reason FROM Lots.LotAttributeChange WHERE LotId = @L3 ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[A] ...with the reconciliation named in the reason', @HaystackStr = @v, @NeedleStr = N'Shift reconciliation #';
SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @L4) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the LOT counted at trim keeps its count', @Expected = N'500', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecId AND LotId = @L4) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] ...but its production is still recorded in full', @Expected = N'1', @Actual = @v;

SET @v = CAST((SELECT SUM(Quantity) FROM Workorder.RejectEvent WHERE ReconciliationId = @RecId AND DefectCodeId = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] warm-up: 38 shots on each of two cavities', @Expected = N'76', @Actual = @v;
SET @v = CAST((SELECT SUM(Quantity) FROM Workorder.RejectEvent WHERE ReconciliationId = @RecId AND DefectCodeId = @Code008) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the 6 test parts, spread across the cavities', @Expected = N'6', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE ReconciliationId = @RecId AND ApprovedByUserId = @Usr) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] Approved by is stamped on the reject rows', @Expected = N'2', @Actual = @v;

SET @v = CAST(Workorder.ufn_DieShotWatermark(@Tool, @S4, @Cell) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the shift''s reading is now the actual total', @Expected = N'1121', @Actual = @v;
SET @v = CAST((SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] die life advanced by the shift''s shots', @Expected = N'11121', @Actual = @v;
SET @v = (SELECT CONCAT(DieShotCountBefore, N'|', DieShotCountAfter) FROM Workorder.DieCastShiftReconciliation WHERE Id = @RecId);
EXEC test.Assert_IsEqual @TestName = N'[A] the header records die life either side', @Expected = N'10000|11121', @Actual = @v;

-- re-running the same reconciliation writes nothing
DECLARE @Stamp2 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
CREATE TABLE #A2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #A2 EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp2, @AppUserId = @Usr;
SET @v = (SELECT Message FROM #A2);
EXEC test.Assert_Contains @TestName = N'[A] running it again finds nothing to do', @HaystackStr = @v, @NeedleStr = N'already matches actual';
DROP TABLE #A2;
GO

-- ============ B: a shift with nothing recorded, entered from its LTTs ============
DECLARE @S5 BIGINT = test.ufn_RC(N'S5'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr'), @CavA BIGINT = test.ufn_RC(N'CavA'), @CavB BIGINT = test.ufn_RC(N'CavB');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S5, @Cell, @Tool);
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

-- actual 110 shots, 100 good, 10 warm-up, 2 test parts => total good 198
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":110,"goodShots":100,"warmUpShots":10}';
DECLARE @Lots NVARCHAR(MAX) =
      N'[{"ltt":"99700611","toolCavityId":' + CAST(@CavA AS NVARCHAR(20)) + N',"quantity":66},'
    + N'{"ltt":"99700612","toolCavityId":' + CAST(@CavA AS NVARCHAR(20)) + N',"quantity":33},'
    + N'{"ltt":"99700613","toolCavityId":' + CAST(@CavB AS NVARCHAR(20)) + N',"quantity":99}]';
DECLARE @Rej NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"quantity":2}]';

CREATE TABLE #B (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #B EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S5, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecB BIGINT = (SELECT NewId FROM #B);
SET @v = CAST((SELECT Status FROM #B) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[B] a shift with nothing on record saves', @Expected = N'1', @Actual = @v;
DROP TABLE #B;

SET @v = (SELECT CONCAT(COUNT(*), N'|', SUM(l.PieceCount)) FROM Lots.Lot l WHERE l.LotName IN (N'99700611', N'99700612', N'99700613'));
EXEC test.Assert_IsEqual @TestName = N'[B] three LOTs created, holding what the sheet says', @Expected = N'3|198', @Actual = @v;
SET @v = (SELECT CONCAT(sc.Code, N'|', loc.Code, N'|', CONVERT(NVARCHAR(10), l.CastDate, 23), N'|', l.ProducedAtLocationId)
          FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
          JOIN Location.Location loc ON loc.Id = l.CurrentLocationId WHERE l.LotName = N'99700611');
SET @Want = CONCAT(N'Good|WHSE|2020-01-07|', @Cell);
EXEC test.Assert_IsEqual @TestName = N'[B] released to Warehouse, cast-dated, produced at the press', @Expected = @Want, @Actual = @v;
SET @v = CAST(Workorder.ufn_DieShotWatermark(@Tool, @S5, @Cell) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[B] the shift now has its reading', @Expected = N'110', @Actual = @v;
SET @v = CAST((SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[B] die life advanced again', @Expected = N'11231', @Actual = @v;
GO

-- ============ C: a reduction ============
DECLARE @S1 BIGINT = test.ufn_RC(N'S1'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'WrongNumbers');
DECLARE @v NVARCHAR(400);

EXEC test.DieCastRecon_SeedLot @Ltt = N'99700621', @CavKey = N'CavA';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700622', @CavKey = N'CavB';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700621', @ShiftKey = N'S1', @Pieces = 590, @Reading = 600, @AtUtc = '2020-01-06T16:00:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700622', @ShiftKey = N'S1', @Pieces = 590, @Reading = 600, @AtUtc = '2020-01-06T16:00:01';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S1', @CavKey = N'CavA', @DefectCode = N'999', @Qty = 10, @AtUtc = '2020-01-06T16:00:02';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S1', @CavKey = N'CavB', @DefectCode = N'999', @Qty = 10, @AtUtc = '2020-01-06T16:00:02';

DECLARE @L1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700621');
DECLARE @L2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700622');
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S1, @Cell, @Tool);
-- actual is LOWER: 580 shots, 570 good, 10 warm-up => 1,140 total good, 570 each
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":580,"goodShots":570,"warmUpShots":10}';
DECLARE @Lots NVARCHAR(MAX) = N'[{"lotId":' + CAST(@L1 AS NVARCHAR(20)) + N',"quantity":570},'
                            + N'{"lotId":' + CAST(@L2 AS NVARCHAR(20)) + N',"quantity":570}]';

CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #C EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S1, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecC BIGINT = (SELECT NewId FROM #C);
SET @v = CAST((SELECT Status FROM #C) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[C] a reduction saves', @Expected = N'1', @Actual = @v;
DROP TABLE #C;

SET @v = (SELECT CONCAT(SUM(PieceDelta), N'|', COUNT(*)) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecC);
EXEC test.Assert_IsEqual @TestName = N'[C] written as compensating rows, not by editing history', @Expected = N'-40|2', @Actual = @v;
SET @v = (SELECT CONCAT(PieceCount, N'|', InventoryAvailable) FROM Lots.Lot WHERE Id = @L1);
EXEC test.Assert_IsEqual @TestName = N'[C] the open LOT comes down to actual', @Expected = N'570|570', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution c WHERE c.ReconciliationId = @RecC AND c.PieceDelta < 0) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[C] the CHECK allows a negative only because it is a reconciliation', @Expected = N'2', @Actual = @v;
SET @v = CAST(Workorder.ufn_DieShotWatermark(@Tool, @S1, @Cell) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[C] the anchor lowers the shift''s reading 600 -> 580', @Expected = N'580', @Actual = @v;
SET @v = CAST((SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[C] die life comes down by the same 20', @Expected = N'11211', @Actual = @v;
SET @v = (SELECT TOP 1 ol.Description FROM Audit.OperationLog ol
          JOIN Audit.LogEventType ev ON ev.Id = ol.LogEventTypeId
          WHERE ol.EntityId = @RecC AND ev.Code = N'DieCastShiftReconciled' ORDER BY ol.Id DESC);
EXEC test.Assert_Contains @TestName = N'[C] the audit row names what came off', @HaystackStr = @v, @NeedleStr = N'-40 good';
GO

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
