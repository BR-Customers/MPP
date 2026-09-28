-- =============================================
-- File: 0097_DieCast_Reconciliation/030_Functions.sql
-- The count lock (spec sec 3.3), the stale-guard stamp (sec 8) and the
-- +/-2 shift neighbourhood (sec 7.3).
--
-- BATCH DISCIPLINE, load-bearing: every test batch below is wrapped in
-- TRY/CATCH. The runner invokes sqlcmd with -b, so an unhandled error does not
-- just fail one batch -- it terminates the whole file, and every batch after it
-- (including the EXEC test.DieCastRecon_Cleanup at the bottom) silently never
-- runs. That turns one bad assertion into a fixture leak: the RC-DIE tool, its
-- cavities, the RC-FIXTURE shifts/schedule and the 99700xxx LOTs all survive
-- into whatever suite runs next. Catching here converts an abort into a
-- recorded FAIL, so the file always reaches its own cleanup.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/030_Functions.sql';
GO
BEGIN TRY
    EXEC test.DieCastRecon_Setup;
    EXEC test.DieCastRecon_SeedLot @Ltt = N'99700201', @CavKey = N'CavA';                        -- open
    EXEC test.DieCastRecon_SeedLot @Ltt = N'99700202', @CavKey = N'CavA', @StatusCode = N'Good'; -- released, clean
    EXEC test.DieCastRecon_SeedLot @Ltt = N'99700203', @CavKey = N'CavB', @StatusCode = N'Good'; -- released, counted at trim
    EXEC test.DieCastRecon_SeedLot @Ltt = N'99700204', @CavKey = N'CavB', @StatusCode = N'Good'; -- released, count corrected
END TRY
BEGIN CATCH
    DECLARE @SetupErr NVARCHAR(1000) = N'fixture setup raised: ' + ERROR_MESSAGE();
    EXEC test.Assert_IsTrue @TestName = N'[Setup] the RC fixture builds', @Condition = 0, @Detail = @SetupErr;
END CATCH
GO

-- ---- Lots.ufn_DieCastLotCountLock ----
BEGIN TRY
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
END TRY
BEGIN CATCH
    DECLARE @LockErr NVARCHAR(1000) = N'batch raised: ' + ERROR_MESSAGE();
    EXEC test.Assert_IsTrue @TestName = N'[Lock] batch completed without error', @Condition = 0, @Detail = @LockErr;
END CATCH
GO

-- ---- Workorder.ufn_DieCastShiftStamp ----
BEGIN TRY
    DECLARE @S1 BIGINT = test.ufn_RC(N'S1'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
    DECLARE @Before NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S1, @Cell, @Tool);
    DECLARE @Same NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S1, @Cell, @Tool);
    EXEC test.Assert_IsEqual @TestName = N'[Stamp] stable while nothing changes', @Expected = @Before, @Actual = @Same;

    EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700202', @ShiftKey = N'S1', @Pieces = 10, @Reading = 10, @AtUtc = '2020-01-06T16:00:00';
    DECLARE @After NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S1, @Cell, @Tool);
    DECLARE @Changed BIT = CASE WHEN @After <> @Before THEN 1 ELSE 0 END;
    EXEC test.Assert_IsTrue @TestName = N'[Stamp] changes when a row lands in the shift', @Condition = @Changed,
        @Detail = N'stamp did not change after a contribution was added';
END TRY
BEGIN CATCH
    DECLARE @StampErr NVARCHAR(1000) = N'batch raised: ' + ERROR_MESSAGE();
    EXEC test.Assert_IsTrue @TestName = N'[Stamp] batch completed without error', @Condition = 0, @Detail = @StampErr;
END CATCH
GO

-- ---- Oee.ufn_ShiftNeighbours ----
BEGIN TRY
    DECLARE @S3 BIGINT = test.ufn_RC(N'S3');
    DECLARE @S5 BIGINT = test.ufn_RC(N'S5');
    DECLARE @v NVARCHAR(400);
    SET @v = CAST((SELECT COUNT(*) FROM Oee.ufn_ShiftNeighbours(@S3, 2)
                   WHERE ShiftId IN (test.ufn_RC(N'S1'), test.ufn_RC(N'S2'), test.ufn_RC(N'S4'), @S5)) AS NVARCHAR(400));
    EXEC test.Assert_IsEqual @TestName = N'[Neighbours] two either side', @Expected = N'4', @Actual = @v;
    SET @v = CAST((SELECT COUNT(*) FROM Oee.ufn_ShiftNeighbours(@S3, 2) WHERE ShiftId = @S3) AS NVARCHAR(400));
    EXEC test.Assert_IsEqual @TestName = N'[Neighbours] never itself', @Expected = N'0', @Actual = @v;
    SET @v = CAST((SELECT Offset FROM Oee.ufn_ShiftNeighbours(@S3, 2) WHERE ShiftId = test.ufn_RC(N'S1')) AS NVARCHAR(400));
    EXEC test.Assert_IsEqual @TestName = N'[Neighbours] offsets are signed distances', @Expected = N'-2', @Actual = @v;

    -- The next assertion has to OPEN S5 for a moment. Oee.Shift carries
    -- UIX_Shift_SingleOpen -- UNIQUE on ActualEnd WHERE ActualEnd IS NULL --
    -- which permits exactly ONE open shift in the entire database, so this is
    -- the one place in the file that depends on global state it does not own.
    -- If any other suite left a shift open, the UPDATE is a duplicate-key
    -- violation. Name the squatter rather than dying on Msg 2601, which says
    -- only "the statement has been terminated" and costs an investigation.
    DECLARE @Squatter NVARCHAR(400) = (
        SELECT STRING_AGG(
                   CAST(s.Id AS NVARCHAR(20)) + N' [schedule ' + ISNULL(ss.Name, N'(none)')
                   + N', started ' + ISNULL(CONVERT(NVARCHAR(30), s.ActualStart, 126), N'(null)')
                   + N', remarks ' + ISNULL(s.Remarks, N'(none)') + N']', N'; ')
        FROM Oee.Shift s
        LEFT JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
        WHERE s.ActualEnd IS NULL AND s.Id <> @S5);

    IF @Squatter IS NOT NULL
    BEGIN
        DECLARE @Leak NVARCHAR(1000) =
              N'CROSS-SUITE LEAK -- an earlier test file left an open Oee.Shift behind. '
            + N'UIX_Shift_SingleOpen allows only one open shift database-wide, so this file '
            + N'cannot open its own S5. Leaked open shift(s): ' + @Squatter
            + N'. Fix the suite that created it (its teardown must DELETE FROM Oee.Shift, '
            + N'and must still run if the file aborts); this file owns no shift but the RC-FIXTURE five.';
        EXEC test.Assert_IsTrue @TestName = N'[Neighbours] an open shift is not a target',
            @Condition = 0, @Detail = @Leak;
    END
    ELSE
    BEGIN
        UPDATE Oee.Shift SET ActualEnd = NULL WHERE Id = @S5;
        SET @v = CAST((SELECT COUNT(*) FROM Oee.ufn_ShiftNeighbours(@S3, 2) WHERE ShiftId = @S5) AS NVARCHAR(400));
        EXEC test.Assert_IsEqual @TestName = N'[Neighbours] an open shift is not a target', @Expected = N'0', @Actual = @v;
        UPDATE Oee.Shift SET ActualEnd = '2020-01-07T23:00:00' WHERE Id = @S5;
    END
END TRY
BEGIN CATCH
    -- never leave S5 open on the way out: it would become the next file's squatter
    IF EXISTS (SELECT 1 FROM Oee.Shift WHERE Id = test.ufn_RC(N'S5') AND ActualEnd IS NULL)
        UPDATE Oee.Shift SET ActualEnd = '2020-01-07T23:00:00' WHERE Id = test.ufn_RC(N'S5');
    DECLARE @NbrErr NVARCHAR(1000) = N'batch raised: ' + ERROR_MESSAGE();
    EXEC test.Assert_IsTrue @TestName = N'[Neighbours] batch completed without error', @Condition = 0, @Detail = @NbrErr;
END CATCH
GO

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
