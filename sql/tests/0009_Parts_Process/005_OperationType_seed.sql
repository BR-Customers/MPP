-- =============================================
-- File:         0009_Parts_Process/005_OperationType_seed.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-02
-- Description:  Operation-type model restructure (Spec 1). Asserts the new
--               Parts.OperationCategory + Parts.OperationType code tables are
--               seeded and that Parts.OperationTemplate carries OperationTypeId.
--               The AreaLocationId drop + OperationTypeId NOT NULL are asserted
--               here once the contract migration (0033) lands.
--               Read-only against seed.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/005_OperationType_seed.sql';
GO

-- =============================================
-- Test 1: OperationCategory seeded (3 rows)
-- =============================================
DECLARE @CatCnt NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Parts.OperationCategory WHERE DeprecatedAt IS NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OpType] 3 OperationCategory rows seeded', @Expected = N'3', @Actual = @CatCnt;
GO

-- =============================================
-- Test 2: OperationType seeded (8 rows), all mapped to a category
-- =============================================
DECLARE @TypCnt NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Parts.OperationType WHERE DeprecatedAt IS NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OpType] 8 OperationType rows seeded', @Expected = N'8', @Actual = @TypCnt;

DECLARE @Orphans NVARCHAR(10) = CAST((
    SELECT COUNT(*) FROM Parts.OperationType ot
    LEFT JOIN Parts.OperationCategory oc ON oc.Id = ot.OperationCategoryId
    WHERE oc.Id IS NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OpType] no OperationType with unresolved category', @Expected = N'0', @Actual = @Orphans;
GO

-- =============================================
-- Test 3: role -> category mapping spot check
-- =============================================
DECLARE @MachOut NVARCHAR(10) = CASE WHEN EXISTS (
    SELECT 1 FROM Parts.OperationType ot
    INNER JOIN Parts.OperationCategory oc ON oc.Id = ot.OperationCategoryId
    WHERE ot.Code = N'MachiningOut' AND oc.Code = N'MachiningAssembly') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[OpType] MachiningOut maps to MachiningAssembly', @Expected = N'1', @Actual = @MachOut;

DECLARE @TrimIn NVARCHAR(10) = CASE WHEN EXISTS (
    SELECT 1 FROM Parts.OperationType ot
    INNER JOIN Parts.OperationCategory oc ON oc.Id = ot.OperationCategoryId
    WHERE ot.Code = N'TrimIn' AND oc.Code = N'Trim') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[OpType] TrimIn maps to Trim', @Expected = N'1', @Actual = @TrimIn;
GO

-- =============================================
-- Test 4: OperationTemplate carries the new FK column
-- =============================================
DECLARE @HasCol NVARCHAR(10) = CASE WHEN EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID(N'Parts.OperationTemplate') AND name = N'OperationTypeId') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[OpType] OperationTemplate.OperationTypeId exists', @Expected = N'1', @Actual = @HasCol;
GO

-- =============================================
-- Test 5: contract phase (0033) -- AreaLocationId dropped, OperationTypeId NOT NULL
-- =============================================
DECLARE @HasArea NVARCHAR(10) = CASE WHEN EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID(N'Parts.OperationTemplate') AND name = N'AreaLocationId') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[OpType] AreaLocationId dropped', @Expected = N'0', @Actual = @HasArea;

DECLARE @TypeNullable NVARCHAR(10) = CASE WHEN EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID(N'Parts.OperationTemplate') AND name = N'OperationTypeId' AND is_nullable = 1) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[OpType] OperationTypeId is NOT NULL', @Expected = N'0', @Actual = @TypeNullable;
GO

EXEC test.EndTestFile;
GO
