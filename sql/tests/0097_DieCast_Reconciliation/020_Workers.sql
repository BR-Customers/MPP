-- =============================================
-- File: 0097_DieCast_Reconciliation/020_Workers.sql
-- The six write workers (spec sec 5.1, amendment A12), called directly.
-- The fixture is rebuilt once at the top; sections run in order.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/020_Workers.sql';
GO
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700101', @CavKey = N'CavA';
GO

-- ---- DieCastCredit_Write ----
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700101');
DECLARE @S1 BIGINT = test.ufn_RC(N'S1'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @CavA NVARCHAR(20) = CAST(test.ufn_RC(N'CavA') AS NVARCHAR(20));
DECLARE @v NVARCHAR(200), @Want NVARCHAR(200);

EXEC Workorder.DieCastCredit_Write @LotId = @Lot, @ShiftId = @S1, @PieceDelta = 40, @CounterReading = 40,
    @CellLocationId = @Cell, @AppUserId = @Usr;
SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @Lot) AS NVARCHAR(200));
EXEC test.Assert_IsEqual @TestName = N'[Credit] applied to the LOT by default', @Expected = N'40', @Actual = @v;
SET @v = (SELECT CONCAT(ToolCavityId, N'|', ShotCounterReading, N'|', CellLocationId) FROM Workorder.DieCastContribution WHERE LotId = @Lot AND PieceDelta = 40);
SET @Want = CONCAT(@CavA, N'|40|', @Cell);
EXEC test.Assert_IsEqual @TestName = N'[Credit] row stamps the LOT cavity, the reading and the press', @Expected = @Want, @Actual = @v;

EXEC Workorder.DieCastCredit_Write @LotId = @Lot, @ShiftId = @S1, @PieceDelta = 25, @CellLocationId = @Cell,
    @ApplyToLot = 0, @AppUserId = @Usr;
SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @Lot) AS NVARCHAR(200));
EXEC test.Assert_IsEqual @TestName = N'[Credit] ApplyToLot = 0 leaves the LOT count alone', @Expected = N'40', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE LotId = @Lot AND PieceDelta = 25) AS NVARCHAR(200));
EXEC test.Assert_IsEqual @TestName = N'[Credit] ...but still writes the production row', @Expected = N'1', @Actual = @v;

INSERT INTO Workorder.DieCastShiftReconciliation (ShiftId, CellLocationId, ToolId, ReasonId, DieShotCountBefore, DieShotCountAfter, AppUserId)
VALUES (@S1, @Cell, test.ufn_RC(N'Tool'), (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry'), 0, 0, @Usr);
DECLARE @H BIGINT = SCOPE_IDENTITY();
DECLARE @At DATETIME2(3) = '2020-01-06T19:59:59';
DECLARE @Sfx NVARCHAR(100) = N' (shift reconciliation #1)';
EXEC Workorder.DieCastCredit_Write @LotId = @Lot, @ShiftId = @S1, @PieceDelta = -5, @CellLocationId = @Cell,
    @ReconciliationId = @H, @EventAt = @At, @AuditSuffix = @Sfx, @AppUserId = @Usr;
SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @Lot) AS NVARCHAR(200));
EXEC test.Assert_IsEqual @TestName = N'[Credit] a negative reconciliation credit is accepted and applied', @Expected = N'35', @Actual = @v;
SET @v = (SELECT CONCAT(ReconciliationId, N'|', CONVERT(NVARCHAR(19), EventAt, 126)) FROM Workorder.DieCastContribution WHERE LotId = @Lot AND PieceDelta = -5);
SET @Want = CONCAT(@H, N'|2020-01-06T19:59:59');
EXEC test.Assert_IsEqual @TestName = N'[Credit] carries the reconciliation and the given EventAt', @Expected = @Want, @Actual = @v;
SET @v = (SELECT TOP 1 Description FROM Lots.LotEventLog WHERE (LotId = @Lot OR EntityId = @Lot) ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[Credit] audit text carries the delta and the suffix',
    @HaystackStr = @v, @NeedleStr = N'Added -5 pc (shift reconciliation #1)';
GO

-- ---- DieCastScrap_Write ----
DECLARE @S1 BIGINT = test.ufn_RC(N'S1'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Tool BIGINT = test.ufn_RC(N'Tool'), @CavB BIGINT = test.ufn_RC(N'CavB');
DECLARE @Code BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700101');
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

DECLARE @Lines NVARCHAR(MAX) =
      N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"scrapLines":[{"defectCodeId":' + CAST(@Code AS NVARCHAR(20)) + N',"quantity":3}]},'
    + N'{"toolCavityId":' + CAST(@CavB AS NVARCHAR(20)) + N',"scrapLines":[{"defectCodeId":' + CAST(@Code AS NVARCHAR(20))
    + N',"quantity":4,"approvedByUserId":' + CAST(@Usr AS NVARCHAR(20)) + N'}]}]';
DECLARE @DieWide NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Code AS NVARCHAR(20)) + N',"quantity":2}]';
EXEC Workorder.DieCastScrap_Write @ToolId = @Tool, @ShiftId = @S1, @CellLocationId = @Cell,
    @LinesJson = @Lines, @DieWideJson = @DieWide, @AppUserId = @Usr;

SET @v = (SELECT CONCAT(ItemId, N'|', ToolCavityId, N'|', Remarks) FROM Workorder.RejectEvent WHERE LotId = @Lot AND Quantity = 3);
SET @Want = CONCAT(test.ufn_RC(N'ItemA'), N'|', test.ufn_RC(N'CavA'), N'|Die-cast per-cavity scrap');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] a LOT line takes part and cavity from the LOT', @Expected = @Want, @Actual = @v;

SET @v = (SELECT CONCAT(ISNULL(CAST(LotId AS NVARCHAR(20)), N'null'), N'|', ItemId, N'|', ApprovedByUserId, N'|', Remarks)
          FROM Workorder.RejectEvent WHERE ToolCavityId = @CavB AND Quantity = 4);
SET @Want = CONCAT(N'null|', test.ufn_RC(N'ItemB'), N'|', @Usr, N'|Die-cast per-cavity scrap (no basket)');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] a cavity line: no LOT, the cavity part, Approved by stamped', @Expected = @Want, @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE ToolId = @Tool AND Remarks = N'Die-cast die-wide scrap' AND Quantity = 2) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Scrap] die-wide fans out to both active cavities', @Expected = N'2', @Actual = @v;
SET @v = CAST((SELECT LotId FROM Workorder.RejectEvent WHERE ToolCavityId = test.ufn_RC(N'CavA') AND Remarks = N'Die-cast die-wide scrap') AS NVARCHAR(400));
SET @Want = CAST(@Lot AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Scrap] die-wide attaches the cavity''s open LOT', @Expected = @Want, @Actual = @v;

DECLARE @Rem NVARCHAR(200) = N'Die-cast shift reconciliation';
DECLARE @OneLine NVARCHAR(MAX) = N'[{"toolCavityId":' + CAST(@CavB AS NVARCHAR(20)) + N',"scrapLines":[{"defectCodeId":' + CAST(@Code AS NVARCHAR(20)) + N',"quantity":-1}]}]';
EXEC Workorder.DieCastScrap_Write @ToolId = @Tool, @ShiftId = @S1, @CellLocationId = @Cell,
    @LinesJson = @OneLine, @Remarks = @Rem, @NoLotRemarks = @Rem, @AppUserId = @Usr;
SET @v = (SELECT Remarks FROM Workorder.RejectEvent WHERE ToolCavityId = @CavB AND Quantity = -1);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] @NoLotRemarks overrides the no-LOT text', @Expected = N'Die-cast shift reconciliation', @Actual = @v;
GO

EXEC test.EndTestFile;
GO
