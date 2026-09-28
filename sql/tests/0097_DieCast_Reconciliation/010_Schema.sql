-- =============================================
-- File: 0097_DieCast_Reconciliation/010_Schema.sql
-- Migration 0097 -- die cast shift reconciliation (spec 2026-09-21 sec 4 + sec 14).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/010_Schema.sql';
GO

DECLARE @v NVARCHAR(50);

SET @v = CAST((SELECT COUNT(*) FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
               WHERE s.name = N'Workorder' AND t.name IN (N'DieCastReconciliationReason', N'DieCastShiftReconciliation', N'DieCastReconciliationMove')) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[0097] three new tables exist', @Expected = N'3', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastReconciliationReason) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[0097] four reconciliation reasons seeded', @Expected = N'4', @Actual = @v;

SET @v = (SELECT CAST(RequiresNote AS NVARCHAR(50)) FROM Workorder.DieCastReconciliationReason WHERE Code = N'Other');
EXEC test.Assert_IsEqual @TestName = N'[0097] Other requires a note', @Expected = N'1', @Actual = @v;

SET @v = (SELECT Name FROM Workorder.DieCastReconciliationReason WHERE Code = N'WrongNumbers');
EXEC test.Assert_IsEqual @TestName = N'[0097] WrongNumbers says "actual", never "sheet"',
    @Expected = N'Recorded numbers did not match actual', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM sys.columns WHERE
      (object_id = OBJECT_ID(N'Workorder.DieCastContribution') AND name = N'ReconciliationId')
   OR (object_id = OBJECT_ID(N'Workorder.RejectEvent')         AND name IN (N'ReconciliationId', N'ApprovedByUserId'))
   OR (object_id = OBJECT_ID(N'Workorder.DieCastCounterAnchor') AND name = N'ReconciliationId')) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[0097] four new columns on existing tables', @Expected = N'4', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM sys.indexes i JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
               WHERE i.object_id = OBJECT_ID(N'Workorder.RejectEvent') AND i.index_id > 0 AND ds.name <> N'ps_MonthlyUtc') AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[0097] every RejectEvent index still ON ps_MonthlyUtc', @Expected = N'0', @Actual = @v;

SET @v = (SELECT Code FROM Workorder.DieCastCounterAnchorReason WHERE Code = N'ShiftReconciliation');
EXEC test.Assert_IsEqual @TestName = N'[0097] anchor reason ShiftReconciliation exists', @Expected = N'ShiftReconciliation', @Actual = @v;

CREATE TABLE #AR (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500), RequiresNote BIT);
INSERT INTO #AR EXEC Workorder.DieCastCounterAnchorReason_List;
SET @v = CAST((SELECT COUNT(*) FROM #AR WHERE Code = N'ShiftReconciliation') AS NVARCHAR(50));
DROP TABLE #AR;
EXEC test.Assert_IsEqual @TestName = N'[0097] Fix counter list does not offer ShiftReconciliation', @Expected = N'0', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Audit.LogEntityType WHERE Code IN (N'DieCastContribution', N'DieCastShiftReconciliation')) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[0097] two audit entity types', @Expected = N'2', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Audit.LogEventType WHERE Code IN (N'DieCastShiftReconciled', N'DieCastEntryMoved')) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[0097] two audit event types', @Expected = N'2', @Actual = @v;
GO

-- The CHECK: a negative credit is legal ONLY on a reconciliation row. Live paths stay non-negative.
DECLARE @Lot BIGINT = (SELECT TOP 1 Id FROM Lots.Lot ORDER BY Id);
DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift ORDER BY Id);
DECLARE @Err NVARCHAR(4000) = N'(no error)';
IF @Lot IS NOT NULL AND @Shift IS NOT NULL
BEGIN
    BEGIN TRY
        BEGIN TRAN;
        INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt)
        VALUES (@Lot, @Shift, -1, 1, SYSUTCDATETIME());
        ROLLBACK;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @Err = ERROR_MESSAGE();
    END CATCH
    EXEC test.Assert_Contains @TestName = N'[0097] negative credit without a reconciliation is refused',
        @HaystackStr = @Err, @NeedleStr = N'CK_DieCastContribution_DeltaNonNeg';
END
GO

-- Migration 0098: the same rule on the scrap side. A negative RejectEvent.Quantity
-- is legal ONLY on a reconciliation row -- DieCastScrap_Write writes the quantity
-- as given, so this CHECK is what catches a sign error in the scrap-gap arithmetic.
DECLARE @Def    BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode ORDER BY Id);
DECLARE @Usr    BIGINT = test.ufn_RC(N'Usr');
DECLARE @RcTool BIGINT, @RcCell BIGINT, @RcSh BIGINT;
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @RejErr NVARCHAR(4000) = N'(no error)';
DECLARE @AccErr NVARCHAR(4000) = N'(no error)';
DECLARE @Landed NVARCHAR(50)   = N'0';

-- (a) refused without a reconciliation
BEGIN TRY
    BEGIN TRAN;
    INSERT INTO Workorder.RejectEvent (LotId, DefectCodeId, Quantity, AppUserId, RecordedAt)
    VALUES (NULL, @Def, -1, @Usr, SYSUTCDATETIME());
    ROLLBACK;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SET @RejErr = ERROR_MESSAGE();
END CATCH
EXEC test.Assert_Contains @TestName = N'[0098] negative reject quantity without a reconciliation is refused',
    @HaystackStr = @RejErr, @NeedleStr = N'CK_RejectEvent_QuantityNonNeg';

-- (b) accepted WITH one (the compensating row a reconciliation writes).
-- The fixture die/shifts are built INSIDE the transaction and rolled back with
-- it, so this file still leaves no fixture rows behind for the later files.
BEGIN TRY
    BEGIN TRAN;
    EXEC test.DieCastRecon_Setup;
    SET @RcTool = test.ufn_RC(N'Tool');
    SET @RcCell = test.ufn_RC(N'Cell');
    SET @RcSh   = test.ufn_RC(N'S1');

    INSERT INTO Workorder.DieCastShiftReconciliation
        (ShiftId, CellLocationId, ToolId, ReasonId, DieShotCountBefore, DieShotCountAfter, AppUserId)
    VALUES (@RcSh, @RcCell, @RcTool, @Reason, 0, 0, @Usr);
    DECLARE @RcId BIGINT = SCOPE_IDENTITY();

    INSERT INTO Workorder.RejectEvent (LotId, DefectCodeId, Quantity, AppUserId, RecordedAt, ReconciliationId)
    VALUES (NULL, @Def, -1, @Usr, SYSUTCDATETIME(), @RcId);

    SET @Landed = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent
                        WHERE ReconciliationId = @RcId AND Quantity = -1) AS NVARCHAR(50));
    ROLLBACK;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SET @AccErr = ERROR_MESSAGE();
END CATCH
EXEC test.Assert_IsEqual @TestName = N'[0098] negative reject quantity WITH a reconciliation is accepted',
    @Expected = N'1', @Actual = @Landed;
EXEC test.Assert_IsEqual @TestName = N'[0098] the accepted insert raised no error',
    @Expected = N'(no error)', @Actual = @AccErr;
GO

-- =============================================
-- Migration 0099 -- the attribution's origin is a first-class column, and a
-- reconciliation move may come from no shift at all.
-- =============================================
DECLARE @v99 NVARCHAR(200);

-- TWO values, deliberately. The question the column answers is "is this
-- attribution still re-derivable from EventAt?", and a row
-- Oee.ShiftOverride_Restamp moved is STILL derived -- an override changes the
-- derivation RULE, not the AUTHORSHIP. A third 'Override' value would make the
-- next override skip the row and would destroy the documented reversibility of
-- deprecate-and-re-apply. This assertion is that decision, written down.
SET @v99 = (SELECT STRING_AGG(Code, N',') WITHIN GROUP (ORDER BY SortOrder) FROM Oee.ShiftAttributionSource);
EXEC test.Assert_IsEqual @TestName = N'[0099] exactly two attribution sources: Derived and Reconciled, and no Override',
    @Expected = N'Derived,Reconciled', @Actual = @v99;

SET @v99 = (SELECT CAST(c.is_nullable AS NVARCHAR(10))
            FROM sys.columns c
            WHERE c.object_id = OBJECT_ID(N'Workorder.DieCastContribution') AND c.name = N'ShiftAttributionSourceId');
EXEC test.Assert_IsEqual @TestName = N'[0099] DieCastContribution.ShiftAttributionSourceId is NOT NULL',
    @Expected = N'0', @Actual = @v99;

SET @v99 = CAST((SELECT COUNT(*) FROM sys.foreign_keys
                 WHERE name = N'FK_DieCastContribution_ShiftAttributionSource') AS NVARCHAR(200));
EXEC test.Assert_IsEqual @TestName = N'[0099] ...code-table backed by an FK, not a magic integer',
    @Expected = N'1', @Actual = @v99;

-- Nullable, so a contribution that never had a shift can be re-filed into one.
SET @v99 = (SELECT CAST(is_nullable AS NVARCHAR(10)) FROM sys.columns
            WHERE object_id = OBJECT_ID(N'Workorder.DieCastReconciliationMove') AND name = N'FromShiftId');
EXEC test.Assert_IsEqual @TestName = N'[0099] DieCastReconciliationMove.FromShiftId is nullable -- a row may come from no shift',
    @Expected = N'1', @Actual = @v99;
GO

-- The DEFAULT is the derived case, so the backfilled rows and anything that
-- inserts without naming a source keep the OLD behaviour -- the restamp still
-- owns them -- rather than silently opting out of it. Asserted here against the
-- constraint definition because this file runs before any fixture exists; the
-- runtime behaviour is asserted in 021_Workers_Lifecycle.sql, which has LOTs.
DECLARE @DefDef99 NVARCHAR(200) = (
    SELECT d.definition FROM sys.columns c
    INNER JOIN sys.default_constraints d ON d.object_id = c.default_object_id
    WHERE c.object_id = OBJECT_ID(N'Workorder.DieCastContribution') AND c.name = N'ShiftAttributionSourceId');
DECLARE @WantDef99 NVARCHAR(50) = (SELECT CAST(Id AS NVARCHAR(50)) FROM Oee.ShiftAttributionSource WHERE Code = N'Derived');
DECLARE @GotDef99  NVARCHAR(200) = CASE WHEN @DefDef99 IS NULL THEN N'(no default)'
                                        ELSE REPLACE(REPLACE(@DefDef99, N'(', N''), N')', N'') END;
EXEC test.Assert_IsEqual @TestName = N'[0099] ...and its DEFAULT is the Derived row',
    @Expected = @WantDef99, @Actual = @GotDef99;
GO

EXEC test.EndTestFile;
GO
