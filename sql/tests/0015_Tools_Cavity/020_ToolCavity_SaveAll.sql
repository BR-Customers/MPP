SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0015_Tools_Cavity/020_ToolCavity_SaveAll.sql';
GO

DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL' AND DeprecatedAt IS NULL);
IF @ToolId IS NULL
BEGIN
    DECLARE @ActiveStatus BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
    VALUES (@ToolTypeId, N'SA-CAV-TOOL', N'Cavity bundled save test tool', @ActiveStatus, SYSUTCDATETIME(), 1);
    SET @ToolId = SCOPE_IDENTITY();
END
-- Clear any cavities from prior runs (hard delete: test isolation only)
DELETE FROM Tools.ToolCavity WHERE ToolId = @ToolId;
GO

-- Test 1: add cavity 'a' (Active) -> Status=1, one active row
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
DECLARE @Json NVARCHAR(MAX) = N'[{"Id":null,"CavityCode":"a","Description":"Cav one","StatusCode":"Active"}]';
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R1; DROP TABLE #R1;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveAdd] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Tools.ToolCavity WHERE ToolId=@ToolId AND DeprecatedAt IS NULL);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveAdd] One active cavity', @Expected=N'1', @Actual=@CntStr;
GO

-- Test 2: change 'a' to Scrapped -> Status=1, status persists
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
DECLARE @CavId BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityCode=N'a' AND DeprecatedAt IS NULL);
DECLARE @Json NVARCHAR(MAX) = N'[{"Id":' + CAST(@CavId AS NVARCHAR(20)) + N',"CavityCode":"a","Description":"Cav one","StatusCode":"Scrapped"}]';
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R2; DROP TABLE #R2;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveScrap] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @StatusCode NVARCHAR(20) = (SELECT sc.Code FROM Tools.ToolCavity c INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id=c.StatusCodeId WHERE c.Id=@CavId);
EXEC test.Assert_IsEqual @TestName=N'[CavSaveScrap] Status is Scrapped', @Expected=N'Scrapped', @Actual=@StatusCode;
GO

-- Test 3: un-scrap 'a' back to Active -> Status=1, and it really persists.
-- Was asserted the other way until 2026-09-10 (proc v1.2). Scrapped is not
-- terminal on the floor: a cavity gets scrapped, the die is repaired, and it
-- comes back producing. The one-way lock left no route back except a hand-edit,
-- because UQ_ToolCavity_ActiveToolItemCode blocks re-adding the same code.
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
DECLARE @CavId BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityCode=N'a');
DECLARE @Json NVARCHAR(MAX) = N'[{"Id":' + CAST(@CavId AS NVARCHAR(20)) + N',"CavityCode":"a","Description":"Cav one","StatusCode":"Active"}]';
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R3; DROP TABLE #R3;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveUnscrap] Un-scrap accepted', @Expected=N'1', @Actual=@SStr;
DECLARE @BackTo NVARCHAR(20) = (SELECT sc.Code FROM Tools.ToolCavity c INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id=c.StatusCodeId WHERE c.Id=@CavId);
EXEC test.Assert_IsEqual @TestName=N'[CavSaveUnscrap] Cavity is Active again', @Expected=N'Active', @Actual=@BackTo;
GO

-- Test 4: change CavityCode on existing row -> Status=0 (immutable)
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
DECLARE @CavId BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityCode=N'a');
DECLARE @Json NVARCHAR(MAX) = N'[{"Id":' + CAST(@CavId AS NVARCHAR(20)) + N',"CavityCode":"q","Description":"Cav one","StatusCode":"Scrapped"}]';
CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R4; DROP TABLE #R4;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveImmutableCode] Status is 0', @Expected=N'0', @Actual=@SStr;
GO

-- Test 5: empty payload does NOT delete cavities (insert+update only)
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=N'[]', @AppUserId=1;
SELECT @S = Status FROM #R5; DROP TABLE #R5;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveEmpty] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Tools.ToolCavity WHERE ToolId=@ToolId AND DeprecatedAt IS NULL);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveEmpty] Cavity persists (not deleted on absent)', @Expected=N'1', @Actual=@CntStr;
GO

-- Test 6: invalid StatusCode -> Status=0
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
CREATE TABLE #R6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R6 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId,
    @RowsJson=N'[{"Id":null,"CavityCode":"e","Description":null,"StatusCode":"InvalidStatus"}]',
    @AppUserId=1;
SELECT @S = Status FROM #R6; DROP TABLE #R6;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveBadStatus] Status is 0', @Expected=N'0', @Actual=@SStr;
GO

-- =============================================
-- Tests 7-14: per-part alphabetic code rules (migration 0076)
--
-- Cavity identity is now a lowercase letter scoped to the PART, so a family
-- die casting several part numbers carries a cavity 'a' on each of them.
-- Uniqueness is (ToolId, ItemId, CavityCode) among active rows.
-- =============================================
DECLARE @T3 BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
DECLARE @P1 BIGINT = (SELECT MIN(Id) FROM Parts.Item WHERE DeprecatedAt IS NULL);
DECLARE @P2 BIGINT = (SELECT MIN(Id) FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id > @P1);

-- Test 7: cross-part duplicate letter -> ACCEPTED
DECLARE @J1 NVARCHAR(MAX) =
    N'[{"CavityCode":"a","StatusCode":"Active","ItemId":' + CAST(@P1 AS NVARCHAR(20)) + N'},'
  + N'{"CavityCode":"a","StatusCode":"Active","ItemId":' + CAST(@P2 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #X1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X1 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J1, @AppUserId=1;
DECLARE @S1 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #X1);
DROP TABLE #X1;
EXEC test.Assert_IsEqual @TestName=N'[CavSaveCrossPart] cavity a on two different parts is accepted',
    @Expected=N'1', @Actual=@S1;

-- Test 8: same-part duplicate letter -> REJECTED
DECLARE @J2 NVARCHAR(MAX) =
    N'[{"CavityCode":"b","StatusCode":"Active","ItemId":' + CAST(@P1 AS NVARCHAR(20)) + N'},'
  + N'{"CavityCode":"b","StatusCode":"Active","ItemId":' + CAST(@P1 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #X2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X2 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J2, @AppUserId=1;
DECLARE @S2 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #X2);
DROP TABLE #X2;
EXEC test.Assert_IsEqual @TestName=N'[CavSaveSamePartDup] duplicate cavity b on the same part is rejected',
    @Expected=N'0', @Actual=@S2;

-- Test 9: numeric code -> REJECTED (the old ordinal is not a code)
DECLARE @J3 NVARCHAR(MAX) = N'[{"CavityCode":"1","StatusCode":"Active"}]';
CREATE TABLE #X3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X3 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J3, @AppUserId=1;
DECLARE @S3 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #X3);
DROP TABLE #X3;
EXEC test.Assert_IsEqual @TestName=N'[CavSaveNumericCode] numeric cavity code is rejected',
    @Expected=N'0', @Actual=@S3;

-- Test 10: empty code -> REJECTED
DECLARE @J4 NVARCHAR(MAX) = N'[{"CavityCode":"","StatusCode":"Active"}]';
CREATE TABLE #X4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X4 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J4, @AppUserId=1;
DECLARE @S4 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #X4);
DROP TABLE #X4;
EXEC test.Assert_IsEqual @TestName=N'[CavSaveEmptyCode] empty cavity code is rejected',
    @Expected=N'0', @Actual=@S4;

-- Test 11: over-length code -> REJECTED with a status row, not an exception
DECLARE @J5 NVARCHAR(MAX) = N'[{"CavityCode":"abcde","StatusCode":"Active"}]';
CREATE TABLE #X5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X5 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J5, @AppUserId=1;
DECLARE @S5 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #X5);
DROP TABLE #X5;
EXEC test.Assert_IsEqual @TestName=N'[CavSaveLongCode] over-length cavity code is rejected',
    @Expected=N'0', @Actual=@S5;

-- Test 12: uppercase is normalized to lowercase, not rejected
DECLARE @J6 NVARCHAR(MAX) =
    N'[{"CavityCode":"Z","StatusCode":"Active","ItemId":' + CAST(@P2 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #X6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X6 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J6, @AppUserId=1;
DROP TABLE #X6;
-- BIN2 so the case-insensitive default collation cannot hide a stored 'Z'
DECLARE @LowerCnt NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Tools.ToolCavity
    WHERE ToolId=@T3 AND ItemId=@P2 AND DeprecatedAt IS NULL
      AND CavityCode COLLATE Latin1_General_BIN2 = N'z');
EXEC test.Assert_IsEqual @TestName=N'[CavSaveNormalizeCase] uppercase code is normalized to lowercase',
    @Expected=N'1', @Actual=@LowerCnt;

-- Test 13: CavityCode is immutable on a saved row
DECLARE @ExistId BIGINT = (
    SELECT TOP 1 Id FROM Tools.ToolCavity
    WHERE ToolId=@T3 AND ItemId=@P1 AND CavityCode=N'a' AND DeprecatedAt IS NULL);
DECLARE @J7 NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@ExistId AS NVARCHAR(20)) + N',"CavityCode":"q","StatusCode":"Active","ItemId":'
  + CAST(@P1 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #X7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X7 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J7, @AppUserId=1;
DECLARE @S7 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #X7);
DROP TABLE #X7;
EXEC test.Assert_IsEqual @TestName=N'[CavSaveImmutableCode2] CavityCode is immutable on an existing row',
    @Expected=N'0', @Actual=@S7;

-- Test 14: an ItemId edit that lands on an occupied letter -> REJECTED.
-- P2 already has a cavity 'a', so moving P1's 'a' onto P2 duplicates it. Only
-- the projected-final-state check catches this; per-die uniqueness could not.
DECLARE @J8 NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@ExistId AS NVARCHAR(20)) + N',"CavityCode":"a","StatusCode":"Active","ItemId":'
  + CAST(@P2 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #X8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X8 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J8, @AppUserId=1;
DECLARE @S8 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #X8);
DROP TABLE #X8;
EXEC test.Assert_IsEqual @TestName=N'[CavSaveItemMoveCollide] ItemId edit that collides with an existing code is rejected',
    @Expected=N'0', @Actual=@S8;
GO

EXEC test.EndTestFile;
GO
