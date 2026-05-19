-- =============================================
-- File:         02_audit_readers/100_FailureLog_DistinctProcedures.sql
-- Description:  Tests for Audit.FailureLog_DistinctProcedures (proc
--               returns DISTINCT ProcedureName across all FailureLog
--               rows, sorted ascending, no NULLs).
-- =============================================

EXEC test.BeginTestFile @FileName = N'02_audit_readers/100_FailureLog_DistinctProcedures.sql';
GO

-- Seed 3 failure rows with 2 distinct procedure names
EXEC Audit.Audit_LogFailure
    @AppUserId           = 1,
    @LogEntityTypeCode   = N'Location',
    @EntityId            = NULL,
    @LogEventTypeCode    = N'Created',
    @FailureReason       = N'Test reason A',
    @ProcedureName       = N'test.ProcAlpha',
    @AttemptedParameters = N'{}';
EXEC Audit.Audit_LogFailure
    @AppUserId           = 1,
    @LogEntityTypeCode   = N'Location',
    @EntityId            = NULL,
    @LogEventTypeCode    = N'Created',
    @FailureReason       = N'Test reason A2',
    @ProcedureName       = N'test.ProcAlpha',
    @AttemptedParameters = N'{}';
EXEC Audit.Audit_LogFailure
    @AppUserId           = 1,
    @LogEntityTypeCode   = N'Location',
    @EntityId            = NULL,
    @LogEventTypeCode    = N'Created',
    @FailureReason       = N'Test reason B',
    @ProcedureName       = N'test.ProcBravo',
    @AttemptedParameters = N'{}';
GO

CREATE TABLE #DP (ProcedureName NVARCHAR(200));
INSERT INTO #DP EXEC Audit.FailureLog_DistinctProcedures;

DECLARE @AlphaCount INT;
SELECT @AlphaCount = COUNT(*) FROM #DP WHERE ProcedureName = N'test.ProcAlpha';
DECLARE @AlphaCountStr NVARCHAR(10) = CAST(@AlphaCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'DistinctProcedures: test.ProcAlpha appears once',
    @Expected = N'1',
    @Actual   = @AlphaCountStr;

DECLARE @BravoCount INT;
SELECT @BravoCount = COUNT(*) FROM #DP WHERE ProcedureName = N'test.ProcBravo';
DECLARE @BravoCountStr NVARCHAR(10) = CAST(@BravoCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'DistinctProcedures: test.ProcBravo appears once',
    @Expected = N'1',
    @Actual   = @BravoCountStr;

DECLARE @NullCount INT;
SELECT @NullCount = COUNT(*) FROM #DP WHERE ProcedureName IS NULL;
DECLARE @NullCountStr NVARCHAR(10) = CAST(@NullCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'DistinctProcedures: no NULL entries returned',
    @Expected = N'0',
    @Actual   = @NullCountStr;

DROP TABLE #DP;
GO

EXEC test.EndTestFile;
GO
