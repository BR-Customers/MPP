-- =============================================
-- File: 0020_PlantFloor_Foundation/030_SessionPolicy_crud.sql
-- Tests for Location.SessionPolicy_Get / _Update (global session timeouts).
-- =============================================
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/030_SessionPolicy_crud.sql';
GO

-- Get returns the single row
CREATE TABLE #G (Id BIGINT, OperatorPresenceTimeoutSeconds INT, ElevationTimeoutSeconds INT, UpdatedAt DATETIME2(3));
INSERT INTO #G EXEC Location.SessionPolicy_Get;
DECLARE @n NVARCHAR(10) = CAST((SELECT COUNT(*) FROM #G) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Get returns 1 row', @Expected=N'1', @Actual=@n;
DROP TABLE #G;
GO

-- Update happy path
DECLARE @S BIT, @M NVARCHAR(500);
CREATE TABLE #U (Status BIT, Message NVARCHAR(500));
INSERT INTO #U EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=120, @ElevationTimeoutSeconds=240, @AppUserId=1;
SELECT @S=Status, @M=Message FROM #U; DROP TABLE #U;
DECLARE @Ss NVARCHAR(1)=CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Update Status 1', @Expected=N'1', @Actual=@Ss;
DECLARE @op NVARCHAR(10)=CAST((SELECT OperatorPresenceTimeoutSeconds FROM Location.SessionPolicy) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Update persisted', @Expected=N'120', @Actual=@op;
GO

-- Update rejects out-of-bounds (< 30s)
DECLARE @S2 BIT, @M2 NVARCHAR(500);
CREATE TABLE #U2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #U2 EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=5, @ElevationTimeoutSeconds=240, @AppUserId=1;
SELECT @S2=Status, @M2=Message FROM #U2; DROP TABLE #U2;
DECLARE @S2s NVARCHAR(1)=CAST(@S2 AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Update rejects <30s', @Expected=N'0', @Actual=@S2s;
EXEC test.Assert_Contains @TestName=N'[SessionPolicy] bounds message', @HaystackStr=@M2, @NeedleStr=N'between 30';
GO

-- Update writes a resolved audit ConfigLog row
DECLARE @EntTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code=N'SessionPolicy');
DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog WHERE LogEntityTypeId=@EntTypeId ORDER BY Id DESC);
DECLARE @HasAudit NVARCHAR(1) = CASE WHEN @Desc LIKE N'Session Policy %Updated%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Update audited', @Expected=N'1', @Actual=@HasAudit;
GO

-- restore defaults for downstream tests
DECLARE @R BIT; CREATE TABLE #R (Status BIT, Message NVARCHAR(500));
INSERT INTO #R EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=180, @ElevationTimeoutSeconds=300, @AppUserId=1;
DROP TABLE #R;
GO

EXEC test.EndTestFile;
GO
