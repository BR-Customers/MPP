-- =============================================
-- File: 0097_DieCast_Reconciliation/030_Functions.sql
-- The count lock (spec sec 3.3), the stale-guard stamp (sec 8) and the
-- +/-2 shift neighbourhood (sec 7.3).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/030_Functions.sql';
GO
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700201', @CavKey = N'CavA';                        -- open
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700202', @CavKey = N'CavA', @StatusCode = N'Good'; -- released, clean
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700203', @CavKey = N'CavB', @StatusCode = N'Good'; -- released, counted at trim
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700204', @CavKey = N'CavB', @StatusCode = N'Good'; -- released, count corrected
GO

-- ---- Lots.ufn_DieCastLotCountLock ----
DECLARE @Open BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700201');
DECLARE @Rel  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700202');
DECLARE @Trim BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700203');
DECLARE @Corr BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700204');
DECLARE @Usr  BIGINT = test.ufn_RC(N'Usr');
DECLARE @v NVARCHAR(400);

SET @v = CAST((SELECT IsLocked FROM Lots.ufn_DieCastLotCountLock(@Open)) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Lock] an open LOT is not locked', @Expected = N'0', @Actual = @v;
SET @v = CAST((SELECT IsLocked FROM Lots.ufn_DieCastLotCountLock(@Rel)) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Lock] a released LOT with nothing downstream is not locked', @Expected = N'0', @Actual = @v;

-- a production event at any operation other than Die Cast = counted downstream
DECLARE @Tmpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
                        INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
                        WHERE oty.Code <> N'DieCast' ORDER BY ot.Id);
IF @Tmpl IS NOT NULL
BEGIN
    INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId)
    VALUES (@Trim, @Tmpl, '2020-01-07T14:02:00', @Usr);
    SET @v = CAST((SELECT IsLocked FROM Lots.ufn_DieCastLotCountLock(@Trim)) AS NVARCHAR(400));
    EXEC test.Assert_IsEqual @TestName = N'[Lock] a LOT counted downstream is locked', @Expected = N'1', @Actual = @v;
    SET @v = (SELECT LockReason FROM Lots.ufn_DieCastLotCountLock(@Trim));
    EXEC test.Assert_Contains @TestName = N'[Lock] ...and says where', @HaystackStr = @v, @NeedleStr = N'Counted at';
END

-- a count correction after release locks it; a reconciliation's own does not
INSERT INTO Lots.LotAttributeChange (LotId, AttributeName, OldValue, NewValue, Reason, ChangedByUserId, ChangedAt)
VALUES (@Corr, N'PieceCount', N'10', N'12', N'Recount at the dock', @Usr, '2020-01-07T16:00:00');
SET @v = CAST((SELECT IsLocked FROM Lots.ufn_DieCastLotCountLock(@Corr)) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Lock] a count corrected after release locks it', @Expected = N'1', @Actual = @v;

INSERT INTO Lots.LotAttributeChange (LotId, AttributeName, OldValue, NewValue, Reason, ChangedByUserId, ChangedAt)
VALUES (@Rel, N'PieceCount', N'10', N'12', N'Shift reconciliation #4: Shift not entered', @Usr, '2020-01-07T16:00:00');
SET @v = CAST((SELECT IsLocked FROM Lots.ufn_DieCastLotCountLock(@Rel)) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Lock] a reconciliation''s own correction does not lock the LOT', @Expected = N'0', @Actual = @v;

UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed') WHERE Id = @Open;
SET @v = CAST((SELECT IsLocked FROM Lots.ufn_DieCastLotCountLock(@Open)) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Lock] a closed LOT is locked', @Expected = N'1', @Actual = @v;
GO

-- ---- Workorder.ufn_DieCastShiftStamp ----
DECLARE @S1 BIGINT = test.ufn_RC(N'S1'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Before NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S1, @Cell, @Tool);
DECLARE @Same NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S1, @Cell, @Tool);
EXEC test.Assert_IsEqual @TestName = N'[Stamp] stable while nothing changes', @Expected = @Before, @Actual = @Same;

EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700202', @ShiftKey = N'S1', @Pieces = 10, @Reading = 10, @AtUtc = '2020-01-06T16:00:00';
DECLARE @After NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S1, @Cell, @Tool);
DECLARE @Changed BIT = CASE WHEN @After <> @Before THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Stamp] changes when a row lands in the shift', @Condition = @Changed,
    @Detail = N'stamp did not change after a contribution was added';
GO

-- ---- Oee.ufn_ShiftNeighbours ----
DECLARE @S3 BIGINT = test.ufn_RC(N'S3');
DECLARE @v NVARCHAR(400);
SET @v = CAST((SELECT COUNT(*) FROM Oee.ufn_ShiftNeighbours(@S3, 2)
               WHERE ShiftId IN (test.ufn_RC(N'S1'), test.ufn_RC(N'S2'), test.ufn_RC(N'S4'), test.ufn_RC(N'S5'))) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Neighbours] two either side', @Expected = N'4', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Oee.ufn_ShiftNeighbours(@S3, 2) WHERE ShiftId = @S3) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Neighbours] never itself', @Expected = N'0', @Actual = @v;
SET @v = CAST((SELECT Offset FROM Oee.ufn_ShiftNeighbours(@S3, 2) WHERE ShiftId = test.ufn_RC(N'S1')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Neighbours] offsets are signed distances', @Expected = N'-2', @Actual = @v;

UPDATE Oee.Shift SET ActualEnd = NULL WHERE Id = test.ufn_RC(N'S5');
SET @v = CAST((SELECT COUNT(*) FROM Oee.ufn_ShiftNeighbours(@S3, 2) WHERE ShiftId = test.ufn_RC(N'S5')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Neighbours] an open shift is not a target', @Expected = N'0', @Actual = @v;
UPDATE Oee.Shift SET ActualEnd = '2020-01-07T23:00:00' WHERE Id = test.ufn_RC(N'S5');
GO

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
