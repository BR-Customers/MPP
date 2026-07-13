-- =============================================
-- File: 0038_PlcIntegration/030_Item_PlcId.sql
-- Tests Item_SetPlcId + Item_GetPlcId. Borrows the lowest-Id active Item
-- (seed 020 always provides Items) and resets its PlcId to NULL at the end.
-- Assertion @Actual values are precomputed into @vars (inline CAST in an EXEC
-- param is a T-SQL syntax error).
-- =============================================
EXEC test.BeginTestFile @FileName = N'0038_PlcIntegration/030_Item_PlcId.sql';
GO

-- Test 1: set PlcId = 2 on the lowest-Id item
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @itemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R1 EXEC Parts.Item_SetPlcId @ItemId=@itemId, @PlcId=2, @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R1; DROP TABLE #R1;
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'SetPlcId=2: status 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Col NVARCHAR(10) = CAST((SELECT PlcId FROM Parts.Item WHERE Id=@itemId) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'SetPlcId=2: column updated', @Expected=N'2', @Actual=@Col;
GO

-- Test 2: GetPlcId returns 2
DECLARE @itemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
CREATE TABLE #G (PlcId INT);
INSERT INTO #G EXEC Parts.Item_GetPlcId @ItemId=@itemId;
DECLARE @code NVARCHAR(10) = CAST((SELECT TOP 1 PlcId FROM #G) AS NVARCHAR(10)); DROP TABLE #G;
EXEC test.Assert_IsEqual @TestName=N'GetPlcId = 2', @Expected=N'2', @Actual=@code;
GO

-- Test 3: set on a non-existent item is rejected
DECLARE @S BIT, @M NVARCHAR(500);
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R3 EXEC Parts.Item_SetPlcId @ItemId=999999999, @PlcId=1, @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R3; DROP TABLE #R3;
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'SetPlcId bad item: status 0', @Expected=N'0', @Actual=@SStr;
GO

-- Cleanup: reset the borrowed item's PlcId
DECLARE @itemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
UPDATE Parts.Item SET PlcId = NULL WHERE Id = @itemId;
GO

EXEC test.PrintSummary;
GO
