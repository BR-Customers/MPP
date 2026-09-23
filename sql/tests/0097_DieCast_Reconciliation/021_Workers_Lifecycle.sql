-- =============================================
-- File: 0097_DieCast_Reconciliation/021_Workers_Lifecycle.sql
-- The LOT-lifecycle workers lifted out of the live die cast procedures so the
-- reconciliation Save can reuse exactly the same write logic inside one
-- transaction (spec 2026-09-21 sec 5).
-- Each worker emits NO result set, owns NO transaction and has NO TRY/CATCH.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/021_Workers_Lifecycle.sql';
GO
EXEC test.DieCastRecon_Setup;
GO

-- ---- DieCastLot_Mint ----
DECLARE @Cell BIGINT = test.ufn_RC(N'Cell'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Tool BIGINT = test.ufn_RC(N'Tool'), @CavB BIGINT = test.ufn_RC(N'CavB'), @ItemB BIGINT = test.ufn_RC(N'ItemB');
DECLARE @Cast DATE = '2020-01-06';
DECLARE @Note NVARCHAR(100) = N' (shift reconciliation #9)';
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

EXEC Lots.DieCastLot_Mint @LotName = N'99700102', @ItemId = @ItemB, @ToolId = @Tool, @ToolCavityId = @CavB,
    @CurrentLocationId = @Cell, @ProducedAtLocationId = @Cell, @CastDate = @Cast, @AuditNote = @Note,
    @AppUserId = @Usr;

DECLARE @New BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700102');
SET @v = (SELECT CONCAT(sc.Code, N'|', l.PieceCount, N'|', CONVERT(NVARCHAR(10), l.CastDate, 23), N'|', l.ProducedAtLocationId, N'|', l.ToolCavityId)
          FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @New);
SET @Want = CONCAT(N'Open|0|2020-01-06|', @Cell, N'|', @CavB);
EXEC test.Assert_IsEqual @TestName = N'[Mint] Open at zero, with cast date, press and cavity', @Expected = @Want, @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @New AND DescendantLotId = @New AND Depth = 0) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Mint] genealogy self-row', @Expected = N'1', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Lots.LotMovement WHERE LotId = @New AND FromLocationId IS NULL AND ToLocationId = @Cell) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Mint] first placement movement', @Expected = N'1', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Lots.LotStatusHistory h JOIN Lots.LotStatusCode n ON n.Id = h.NewStatusId
               WHERE h.LotId = @New AND h.OldStatusId IS NULL AND n.Code = N'Open') AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Mint] status history opens the LOT', @Expected = N'1', @Actual = @v;
SET @v = (SELECT TOP 1 Description FROM Lots.LotEventLog WHERE (LotId = @New OR EntityId = @New) ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[Mint] audit carries the caller''s note', @HaystackStr = @v, @NeedleStr = N'(shift reconciliation #9)';
GO

-- ---- Lot_ApplyPieceCountCorrection ----
-- The Mint section above left 99700102 at zero. Credit it the way the live
-- press path would, so the correction below has a real count to move off.
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700102', @ShiftKey = N'S1', @Pieces = 50,
    @AtUtc = '2020-01-06T13:00:00';
GO

DECLARE @New BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700102');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason NVARCHAR(500) = N'Shift reconciliation #9: Shift not entered';
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

EXEC Lots.Lot_ApplyPieceCountCorrection @LotId = @New, @NewPieceCount = 60, @Reason = @Reason,
    @ExpectedPieceCount = 50, @AppUserId = @Usr;
SET @v = (SELECT CONCAT(PieceCount, N'|', InventoryAvailable) FROM Lots.Lot WHERE Id = @New);
EXEC test.Assert_IsEqual @TestName = N'[Correct] count and availability move by the same delta', @Expected = N'60|60', @Actual = @v;
SET @v = (SELECT TOP 1 CONCAT(OldValue, N'|', NewValue, N'|', Reason) FROM Lots.LotAttributeChange
          WHERE LotId = @New AND AttributeName = N'PieceCount' ORDER BY Id DESC);
SET @Want = N'50|60|Shift reconciliation #9: Shift not entered';
EXEC test.Assert_IsEqual @TestName = N'[Correct] the change row carries old, new and the reason', @Expected = @Want, @Actual = @v;

DECLARE @Err NVARCHAR(4000) = N'(no error)';
BEGIN TRY
    EXEC Lots.Lot_ApplyPieceCountCorrection @LotId = @New, @NewPieceCount = 70, @Reason = @Reason,
        @ExpectedPieceCount = 50, @AppUserId = @Usr;
END TRY
BEGIN CATCH
    SET @Err = ERROR_MESSAGE();
END CATCH
EXEC test.Assert_Contains @TestName = N'[Correct] a stale expected count is refused',
    @HaystackStr = @Err, @NeedleStr = N'changed while the correction was being entered';
GO

-- ---- DieCastEntry_Restamp ----
-- What a reconciliation Save would have in front of it: an open basket on cavity
-- a with a shift-1 credit, a shift-1 scrap row against the same basket, and the
-- header the moves are filed under.
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700101', @CavKey = N'CavA';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700101', @ShiftKey = N'S1', @Pieces = 40,
    @AtUtc = '2020-01-06T12:30:00';
GO

DECLARE @SeedLot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700101');
DECLARE @SeedS1  BIGINT = test.ufn_RC(N'S1');
DECLARE @SeedUsr BIGINT = test.ufn_RC(N'Usr');
DECLARE @SeedCell BIGINT = test.ufn_RC(N'Cell');

INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId,
                                   CellLocationId, DefectCodeId, Quantity, ChargeToArea, Remarks,
                                   AppUserId, TerminalLocationId, RecordedAt)
SELECT NULL, @SeedLot, l.ItemId, l.ToolId, l.ToolCavityId, @SeedS1, @SeedCell,
       (SELECT TOP 1 Id FROM Quality.DefectCode ORDER BY Id), 3, NULL, N'fixture',
       @SeedUsr, NULL, '2020-01-06T12:30:00'
FROM Lots.Lot l WHERE l.Id = @SeedLot;

INSERT INTO Workorder.DieCastShiftReconciliation
    (ShiftId, CellLocationId, ToolId, ReasonId, Note, DieShotCountBefore, DieShotCountAfter, AppUserId)
VALUES (@SeedS1, @SeedCell, test.ufn_RC(N'Tool'),
        (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'WrongShift'),
        N'021 worker test', 0, 0, @SeedUsr);
GO

DECLARE @H BIGINT = (SELECT Id FROM Workorder.DieCastShiftReconciliation WHERE Note = N'021 worker test');
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700101');
DECLARE @S1 BIGINT = test.ufn_RC(N'S1'), @S2 BIGINT = test.ufn_RC(N'S2'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @C BIGINT = (SELECT Id FROM Workorder.DieCastContribution WHERE LotId = @Lot AND PieceDelta = 40);
DECLARE @R BIGINT = (SELECT Id FROM Workorder.RejectEvent WHERE LotId = @Lot AND Quantity = 3);
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

DECLARE @Moves NVARCHAR(MAX) =
      N'[{"entityType":"Contribution","entityId":' + CAST(@C AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S2 AS NVARCHAR(20)) + N'},'
    + N'{"entityType":"Reject","entityId":' + CAST(@R AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S2 AS NVARCHAR(20)) + N'}]';
EXEC Workorder.DieCastEntry_Restamp @ReconciliationId = @H, @MovesJson = @Moves, @AppUserId = @Usr;

SET @v = CAST((SELECT ShiftId FROM Workorder.DieCastContribution WHERE Id = @C) AS NVARCHAR(400));
SET @Want = CAST(@S2 AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Restamp] the contribution now belongs to the target shift', @Expected = @Want, @Actual = @v;
SET @v = CAST((SELECT ShiftId FROM Workorder.RejectEvent WHERE Id = @R) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Restamp] so does the reject row', @Expected = @Want, @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastReconciliationMove m
               WHERE m.ReconciliationId = @H AND m.FromShiftId = @S1 AND m.ToShiftId = @S2) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Restamp] both moves are recorded with where they came from', @Expected = N'2', @Actual = @v;

SET @v = (SELECT TOP 1 ol.Description FROM Audit.OperationLog ol
          JOIN Audit.LogEntityType et ON et.Id = ol.LogEntityTypeId
          JOIN Audit.LogEventType  ev ON ev.Id = ol.LogEventTypeId
          WHERE ol.EntityId = @H AND et.Code = N'DieCastShiftReconciliation' AND ev.Code = N'DieCastEntryMoved'
          ORDER BY ol.Id DESC);
EXEC test.Assert_Contains @TestName = N'[Restamp] one audit row naming what moved', @HaystackStr = @v, @NeedleStr = N'Moved 2 rows';
GO

EXEC test.EndTestFile;
GO
