SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0101_PrinterUsbBridge/020_SaveAll_conditional_endpoint.sql';
GO
-- Fixture: an arbitrary active Terminal to hang test printers under.
DELETE la FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId
    WHERE l.Code IN (N'TEST-PRN-UB', N'TEST-PRN-NW');
DELETE FROM Location.Location WHERE Code IN (N'TEST-PRN-UB', N'TEST-PRN-NW');
GO
DECLARE @Parent BIGINT = (SELECT TOP 1 Id FROM Location.Location
                          WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @EpDef   BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                           WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint' AND DeprecatedAt IS NULL);
DECLARE @CkDef   BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                           WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'ConnectionKind' AND DeprecatedAt IS NULL);
DECLARE @Usr     BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);

-- A UsbBridge printer saves with a BLANK Endpoint. Before this change the generic
-- required-attribute check refused it with "Required attribute missing a value".
DECLARE @Json1 NVARCHAR(MAX) =
    N'[{"LocationAttributeDefinitionId":' + CAST(@EpDef AS NVARCHAR(20)) + N',"Value":""},'
  + N' {"LocationAttributeDefinitionId":' + CAST(@CkDef AS NVARCHAR(20)) + N',"Value":"UsbBridge"}]';
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Parent, @LocationTypeDefinitionId = 16,
    @Name = N'Test Printer UB', @Code = N'TEST-PRN-UB', @Description = N'test',
    @SortOrder = 951, @AppUserId = @Usr, @AttributeValuesJson = @Json1;
DECLARE @S1 BIT, @M1 NVARCHAR(500);
SELECT @S1 = Status, @M1 = Message FROM #R1;
DROP TABLE #R1;
EXEC test.Assert_IsTrue @TestName = N'[SaveAll] UsbBridge printer saves with no endpoint', @Condition = @S1;
GO
-- A Networked printer with a blank Endpoint is still REFUSED -- the guard moved,
-- it did not disappear.
DECLARE @EpDef2 BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                          WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint' AND DeprecatedAt IS NULL);
DECLARE @CkDef2 BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                          WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'ConnectionKind' AND DeprecatedAt IS NULL);
DECLARE @Parent2 BIGINT = (SELECT TOP 1 Id FROM Location.Location
                           WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Usr2 BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @Json2 NVARCHAR(MAX) =
    N'[{"LocationAttributeDefinitionId":' + CAST(@EpDef2 AS NVARCHAR(20)) + N',"Value":""},'
  + N' {"LocationAttributeDefinitionId":' + CAST(@CkDef2 AS NVARCHAR(20)) + N',"Value":"Networked"}]';
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Parent2, @LocationTypeDefinitionId = 16,
    @Name = N'Test Printer NW', @Code = N'TEST-PRN-NW', @Description = N'test',
    @SortOrder = 952, @AppUserId = @Usr2, @AttributeValuesJson = @Json2;
DECLARE @S2 BIT, @M2 NVARCHAR(500);
SELECT @S2 = Status, @M2 = Message FROM #R2;
DROP TABLE #R2;
-- EXEC parameters must be literals or @variables, never an inline CAST
-- (CLAUDE.md, SQL conventions). Materialise it first.
DECLARE @S2Str NVARCHAR(1) = CAST(@S2 AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[SaveAll] Networked printer with no endpoint is refused',
     @Expected = N'0', @Actual = @S2Str;
EXEC test.Assert_Contains @TestName = N'[SaveAll] the refusal names the condition',
     @HaystackStr = @M2, @NeedleStr = N'unless ConnectionKind is UsbBridge';
GO
-- An ABSENT ConnectionKind reads as the DefaultValue 'Networked', so a blank
-- endpoint with no kind at all is refused too -- the common typo case.
DECLARE @EpDef3 BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                          WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint' AND DeprecatedAt IS NULL);
DECLARE @Parent3 BIGINT = (SELECT TOP 1 Id FROM Location.Location
                           WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Usr3 BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @Json3 NVARCHAR(MAX) =
    N'[{"LocationAttributeDefinitionId":' + CAST(@EpDef3 AS NVARCHAR(20)) + N',"Value":""}]';
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Parent3, @LocationTypeDefinitionId = 16,
    @Name = N'Test Printer NK', @Code = N'TEST-PRN-NK', @Description = N'test',
    @SortOrder = 953, @AppUserId = @Usr3, @AttributeValuesJson = @Json3;
DECLARE @S3 BIT;
SELECT @S3 = Status FROM #R3;
DROP TABLE #R3;
DECLARE @S3Str NVARCHAR(1) = CAST(@S3 AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[SaveAll] absent kind defaults to Networked and is refused',
     @Expected = N'0', @Actual = @S3Str;
GO
-- A NON-printer location type is unaffected by the new block.
DECLARE @Site BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId = 2 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Usr4 BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Site, @LocationTypeDefinitionId = 4,
    @Name = N'Test Support Area', @Code = N'TEST-AREA-UB', @Description = N'test',
    @SortOrder = 954, @AppUserId = @Usr4, @AttributeValuesJson = N'[]';
DECLARE @S4 BIT;
SELECT @S4 = Status FROM #R4;
DROP TABLE #R4;
EXEC test.Assert_IsTrue @TestName = N'[SaveAll] a non-printer type is unaffected', @Condition = @S4;
GO
-- Teardown. LocationAttribute BEFORE Location (FK).
DELETE la FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId
    WHERE l.Code IN (N'TEST-PRN-UB', N'TEST-PRN-NW', N'TEST-PRN-NK', N'TEST-AREA-UB');
DELETE FROM Location.Location WHERE Code IN (N'TEST-PRN-UB', N'TEST-PRN-NW', N'TEST-PRN-NK', N'TEST-AREA-UB');
GO
EXEC test.EndTestFile;
GO
