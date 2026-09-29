-- =============================================
-- File: 0020_PlantFloor_Foundation/030_SessionPolicy_crud.sql
-- Tests for Location.SessionPolicy_Get / _Update (global session timeouts).
--
-- ElevationMaxSeconds (0100) is the ABSOLUTE ceiling on an elevation window.
-- ElevationTimeoutSeconds is the rolling idle timeout that activity pushes
-- forward; the ceiling is what activity can never push past. A ceiling below
-- the rolling timeout would mean the window expires before one idle period has
-- elapsed, which is incoherent, so the proc refuses it.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/030_SessionPolicy_crud.sql';
GO

-- Get returns the single row, and it now carries the ceiling
CREATE TABLE #G (Id BIGINT, OperatorPresenceTimeoutSeconds INT, ElevationTimeoutSeconds INT,
                 ElevationMaxSeconds INT, UpdatedAt DATETIME2(3));
INSERT INTO #G EXEC Location.SessionPolicy_Get;
DECLARE @n NVARCHAR(10) = CAST((SELECT COUNT(*) FROM #G) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Get returns 1 row', @Expected=N'1', @Actual=@n;
DECLARE @gmax NVARCHAR(10) = CAST((SELECT ElevationMaxSeconds FROM #G) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Get carries the elevation ceiling', @Expected=N'1800', @Actual=@gmax;
DROP TABLE #G;
GO

-- Update happy path
DECLARE @S BIT, @M NVARCHAR(500);
CREATE TABLE #U (Status BIT, Message NVARCHAR(500));
INSERT INTO #U EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=120, @ElevationTimeoutSeconds=240, @ElevationMaxSeconds=900, @AppUserId=1;
SELECT @S=Status, @M=Message FROM #U; DROP TABLE #U;
DECLARE @Ss NVARCHAR(1)=CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Update Status 1', @Expected=N'1', @Actual=@Ss;
DECLARE @op NVARCHAR(10)=CAST((SELECT OperatorPresenceTimeoutSeconds FROM Location.SessionPolicy) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Update persisted', @Expected=N'120', @Actual=@op;
DECLARE @mx NVARCHAR(10)=CAST((SELECT ElevationMaxSeconds FROM Location.SessionPolicy) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] ceiling persisted', @Expected=N'900', @Actual=@mx;
GO

-- Update rejects out-of-bounds (< 30s)
DECLARE @S2 BIT, @M2 NVARCHAR(500);
CREATE TABLE #U2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #U2 EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=5, @ElevationTimeoutSeconds=240, @ElevationMaxSeconds=900, @AppUserId=1;
SELECT @S2=Status, @M2=Message FROM #U2; DROP TABLE #U2;
DECLARE @S2s NVARCHAR(1)=CAST(@S2 AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Update rejects <30s', @Expected=N'0', @Actual=@S2s;
EXEC test.Assert_Contains @TestName=N'[SessionPolicy] bounds message', @HaystackStr=@M2, @NeedleStr=N'between 30';
GO

-- The ceiling has its own upper bound: it is allowed to exceed 3600 (a long
-- reconciliation is legitimate) but not to run away. 30..28800 (8 hours, one shift).
DECLARE @S3 BIT, @M3 NVARCHAR(500);
CREATE TABLE #U3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #U3 EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=120, @ElevationTimeoutSeconds=240, @ElevationMaxSeconds=99999, @AppUserId=1;
SELECT @S3=Status, @M3=Message FROM #U3; DROP TABLE #U3;
DECLARE @S3s NVARCHAR(1)=CAST(@S3 AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] rejects a runaway ceiling', @Expected=N'0', @Actual=@S3s;
EXEC test.Assert_Contains @TestName=N'[SessionPolicy] ceiling bounds message', @HaystackStr=@M3, @NeedleStr=N'28800';
GO

-- A ceiling BELOW the rolling timeout is incoherent and is refused.
DECLARE @S4 BIT, @M4 NVARCHAR(500);
CREATE TABLE #U4 (Status BIT, Message NVARCHAR(500));
INSERT INTO #U4 EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=120, @ElevationTimeoutSeconds=600, @ElevationMaxSeconds=300, @AppUserId=1;
SELECT @S4=Status, @M4=Message FROM #U4; DROP TABLE #U4;
DECLARE @S4s NVARCHAR(1)=CAST(@S4 AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] rejects ceiling below the rolling timeout', @Expected=N'0', @Actual=@S4s;
EXEC test.Assert_Contains @TestName=N'[SessionPolicy] ordering message', @HaystackStr=@M4, @NeedleStr=N'at least';
GO

-- Equal is legal: the ceiling may equal the rolling timeout, which reproduces
-- today's behaviour exactly (one window, no extension). That equivalence is the
-- migration's safety property, so it is asserted rather than assumed.
DECLARE @S5 BIT;
CREATE TABLE #U5 (Status BIT, Message NVARCHAR(500));
INSERT INTO #U5 EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=120, @ElevationTimeoutSeconds=300, @ElevationMaxSeconds=300, @AppUserId=1;
SELECT @S5=Status FROM #U5; DROP TABLE #U5;
DECLARE @S5s NVARCHAR(1)=CAST(@S5 AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] ceiling may equal the rolling timeout', @Expected=N'1', @Actual=@S5s;
GO

-- Update writes a resolved audit ConfigLog row
DECLARE @EntTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code=N'SessionPolicy');
DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog WHERE LogEntityTypeId=@EntTypeId ORDER BY Id DESC);
DECLARE @HasAudit NVARCHAR(1) = CASE WHEN @Desc LIKE N'Session Policy %Updated%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Update audited', @Expected=N'1', @Actual=@HasAudit;
GO

-- A ceiling change is NAMED in the audit description, not silently folded in.
DECLARE @Sa BIT; CREATE TABLE #UA (Status BIT, Message NVARCHAR(500));
INSERT INTO #UA EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=120, @ElevationTimeoutSeconds=300, @ElevationMaxSeconds=1200, @AppUserId=1;
DROP TABLE #UA;
DECLARE @EntTypeId2 BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code=N'SessionPolicy');
DECLARE @Desc2 NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog WHERE LogEntityTypeId=@EntTypeId2 ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName=N'[SessionPolicy] ceiling change is named in the audit', @HaystackStr=@Desc2, @NeedleStr=N'Elevation ceiling';
GO

-- Update with NO changes must still succeed (STUFF-on-empty -> NULL Description guard)
DECLARE @Snc BIT;
CREATE TABLE #UNC (Status BIT, Message NVARCHAR(500));
INSERT INTO #UNC EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=120, @ElevationTimeoutSeconds=300, @ElevationMaxSeconds=1200, @AppUserId=1;
SELECT @Snc=Status FROM #UNC; DROP TABLE #UNC;
DECLARE @Sncs NVARCHAR(1)=CAST(@Snc AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Update with no changes succeeds', @Expected=N'1', @Actual=@Sncs;
GO

-- restore defaults for downstream tests
DECLARE @R BIT; CREATE TABLE #R (Status BIT, Message NVARCHAR(500));
INSERT INTO #R EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=180, @ElevationTimeoutSeconds=300, @ElevationMaxSeconds=1800, @AppUserId=1;
DROP TABLE #R;
GO

EXEC test.EndTestFile;
GO
