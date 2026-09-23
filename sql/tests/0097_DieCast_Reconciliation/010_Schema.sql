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

EXEC test.EndTestFile;
GO
