-- =============================================
-- File: 0056_CrtValidation/010_schema.sql
-- Desc: Migration 0058 - CrtEnabled terminal attribute definition (LTD 7).
-- =============================================
EXEC test.BeginTestFile @FileName = N'0056_CrtValidation/010_schema.sql';
GO

DECLARE @Exists NVARCHAR(10) = CASE WHEN EXISTS (
    SELECT 1 FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'CrtEnabled' AND DeprecatedAt IS NULL)
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[0058] CrtEnabled attribute definition exists on LTD 7',
    @Expected = N'1', @Actual = @Exists;

DECLARE @Default NVARCHAR(20) = (SELECT DefaultValue FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'CrtEnabled' AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual
    @TestName = N'[0058] CrtEnabled defaults to 0 (off)',
    @Expected = N'0', @Actual = @Default;

DECLARE @Type NVARCHAR(20) = (SELECT DataType FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'CrtEnabled' AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual
    @TestName = N'[0058] CrtEnabled is NVARCHAR (0/1 like HasBarcodeScanner)',
    @Expected = N'NVARCHAR', @Actual = @Type;
GO

EXEC test.EndTestFile;
