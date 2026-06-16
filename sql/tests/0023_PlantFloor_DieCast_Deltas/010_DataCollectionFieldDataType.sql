-- =============================================
-- File:         0023_PlantFloor_DieCast_Deltas/010_DataCollectionFieldDataType.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Tests for Phase 3 delta Change 1 — Parts.DataCollectionFieldDataType
--               code table + DataCollectionField.DataTypeId NOT NULL FK (migration
--               0023) and Parts.DataCollectionField_List v3.0 (returns DataType).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0023_PlantFloor_DieCast_Deltas/010_DataCollectionFieldDataType.sql';
GO

-- Test 1: the 5 datatype codes exist
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Parts.DataCollectionFieldDataType
                    WHERE Code IN (N'String',N'Integer',N'Decimal',N'Boolean',N'Date'));
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[DT] 5 datatype codes present', @Expected = N'5', @Actual = @CntStr;
GO

-- Test 2: no DataCollectionField row is untyped
DECLARE @Null INT = (SELECT COUNT(*) FROM Parts.DataCollectionField WHERE DataTypeId IS NULL);
DECLARE @NullStr NVARCHAR(10) = CAST(@Null AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[DT] no untyped DataCollectionField', @Expected = N'0', @Actual = @NullStr;
GO

-- Test 3: backfill correctness (spot-check each datatype)
DECLARE @W NVARCHAR(20) = (SELECT dt.Code FROM Parts.DataCollectionField dcf
    INNER JOIN Parts.DataCollectionFieldDataType dt ON dt.Id = dcf.DataTypeId WHERE dcf.Code = N'Weight');
EXEC test.Assert_IsEqual @TestName = N'[DT] Weight->Decimal', @Expected = N'Decimal', @Actual = @W;
DECLARE @G NVARCHAR(20) = (SELECT dt.Code FROM Parts.DataCollectionField dcf
    INNER JOIN Parts.DataCollectionFieldDataType dt ON dt.Id = dcf.DataTypeId WHERE dcf.Code = N'GoodCount');
EXEC test.Assert_IsEqual @TestName = N'[DT] GoodCount->Integer', @Expected = N'Integer', @Actual = @G;
DECLARE @D NVARCHAR(20) = (SELECT dt.Code FROM Parts.DataCollectionField dcf
    INNER JOIN Parts.DataCollectionFieldDataType dt ON dt.Id = dcf.DataTypeId WHERE dcf.Code = N'DieInfo');
EXEC test.Assert_IsEqual @TestName = N'[DT] DieInfo->String', @Expected = N'String', @Actual = @D;
DECLARE @M NVARCHAR(20) = (SELECT dt.Code FROM Parts.DataCollectionField dcf
    INNER JOIN Parts.DataCollectionFieldDataType dt ON dt.Id = dcf.DataTypeId WHERE dcf.Code = N'MaterialVerification');
EXEC test.Assert_IsEqual @TestName = N'[DT] MaterialVerification->Boolean', @Expected = N'Boolean', @Actual = @M;
GO

-- Test 4: FK rejects an invalid DataTypeId
DECLARE @Threw NVARCHAR(10) = N'0';
BEGIN TRY
    INSERT INTO Parts.DataCollectionField (Code, Name, DataTypeId)
    VALUES (N'ZZ-DT-NEG-TEST', N'neg', 999999999);
END TRY
BEGIN CATCH
    SET @Threw = N'1';
END CATCH
DELETE FROM Parts.DataCollectionField WHERE Code = N'ZZ-DT-NEG-TEST';
EXEC test.Assert_IsEqual @TestName = N'[DT] FK rejects invalid DataTypeId', @Expected = N'1', @Actual = @Threw;
GO

-- Test 5: DataCollectionField_List v3.0 surfaces DataTypeCode/Name
DECLARE @Cols TABLE (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500),
                     DataTypeId BIGINT, DataTypeCode NVARCHAR(20), DataTypeName NVARCHAR(50),
                     CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3));
INSERT INTO @Cols EXEC Parts.DataCollectionField_List @IncludeDeprecated = 0;
DECLARE @WDt NVARCHAR(20) = (SELECT DataTypeCode FROM @Cols WHERE Code = N'Weight');
EXEC test.Assert_IsEqual @TestName = N'[DT] _List returns DataTypeCode for Weight', @Expected = N'Decimal', @Actual = @WDt;
DECLARE @Untyped INT = (SELECT COUNT(*) FROM @Cols WHERE DataTypeCode IS NULL);
DECLARE @UntypedStr NVARCHAR(10) = CAST(@Untyped AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[DT] _List rows all carry a DataTypeCode', @Expected = N'0', @Actual = @UntypedStr;
GO

EXEC test.EndTestFile;
GO
