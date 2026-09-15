SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0015_Tools_Cavity/030_ToolCavity_ItemId.sql';
GO

-- =============================================
-- Migration 0072 -- Tools.ToolCavity.ItemId, the configured cavity-to-part map
-- for FAMILY DIES (one die casting several part numbers, three cavities each).
--
-- Why it matters: a Closed or Scrapped cavity has no LOT, so before 0072 the
-- system could not name the part that cavity cuts -- the die-cast shift-output
-- screen could not label it, collect its scrap, or roll up per part. These
-- tests pin that the mapping is CONFIGURATION and survives independently of
-- any LOT.
-- =============================================

DECLARE @DieTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CI-CAV-TOOL' AND DeprecatedAt IS NULL);
IF @ToolId IS NULL
BEGIN
    DECLARE @ActiveStatus BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
    VALUES (@DieTypeId, N'CI-CAV-TOOL', N'Cavity ItemId test die', @ActiveStatus, SYSUTCDATETIME(), 1);
    SET @ToolId = SCOPE_IDENTITY();
END
-- Clear any cavities from prior runs (hard delete: test isolation only)
DELETE FROM Tools.ToolCavity WHERE ToolId = @ToolId;

-- Two live parts + one deprecated part
DECLARE @CompTypeId BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @PcsUomId BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'PCS');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'CI-PART-1')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (@CompTypeId, N'CI-PART-1', N'Family part one', @PcsUomId, SYSUTCDATETIME(), 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'CI-PART-2')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (@CompTypeId, N'CI-PART-2', N'Family part two', @PcsUomId, SYSUTCDATETIME(), 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'CI-PART-DEAD')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (@CompTypeId, N'CI-PART-DEAD', N'Retired family part', @PcsUomId, SYSUTCDATETIME(), 1);
UPDATE Parts.Item SET DeprecatedAt = SYSUTCDATETIME()
WHERE PartNumber = N'CI-PART-DEAD' AND DeprecatedAt IS NULL;
GO

-- =============================================
-- Test 1: SaveAll persists ItemId on INSERT; an unmapped cavity stays NULL
--
-- D13 (2026-09-14, design doc 4.6): ToolCavity_SaveAll now rejects any row
-- it is CREATING with no part, so cavity 'c' can no longer be bundled into
-- this SaveAll payload unmapped -- that would reject the whole save. It is
-- seeded directly via Tools.ToolCavity_Create instead (untouched by D13;
-- @ItemId there stays optional), which is exactly how a legacy unmapped row
-- exists in the first place. The point under test -- that an unmapped
-- cavity persists and reads correctly -- is unchanged.
-- =============================================
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CI-CAV-TOOL');
DECLARE @P1 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'CI-PART-1');
DECLARE @P2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'CI-PART-2');
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"CavityCode":"a","Description":"Da","StatusCode":"Active","ItemId":' + CAST(@P1 AS NVARCHAR(20)) + N'},'
  + N'{"Id":null,"CavityCode":"b","Description":"Db","StatusCode":"Active","ItemId":' + CAST(@P2 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R1; DROP TABLE #R1;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavItemAdd] Status is 1', @Expected=N'1', @Actual=@SStr;

CREATE TABLE #R1C (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1C EXEC Tools.ToolCavity_Create
    @ToolId=@ToolId, @CavityCode=N'c', @Description=N'Dc', @ItemId=NULL, @AppUserId=1;
DROP TABLE #R1C;

DECLARE @P1Str NVARCHAR(20) = CAST(@P1 AS NVARCHAR(20));
DECLARE @Cav1 NVARCHAR(20) = (SELECT CAST(ISNULL(ItemId,-1) AS NVARCHAR(20))
                              FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityCode=N'a');
EXEC test.Assert_IsEqual @TestName=N'[CavItemAdd] Cavity 1 persisted its ItemId', @Expected=@P1Str, @Actual=@Cav1;

DECLARE @Cav3 NVARCHAR(20) = (SELECT CAST(ISNULL(ItemId,-1) AS NVARCHAR(20))
                              FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityCode=N'c');
EXEC test.Assert_IsEqual @TestName=N'[CavItemAdd] Unmapped cavity keeps NULL ItemId', @Expected=N'-1', @Actual=@Cav3;
GO

-- =============================================
-- Test 2: ListByTool resolves the part number; unmapped cavity still listed
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CI-CAV-TOOL');
CREATE TABLE #L (
    Id BIGINT, ToolId BIGINT, CavityCode NVARCHAR(4),
    StatusCodeId BIGINT, StatusCode NVARCHAR(30), StatusName NVARCHAR(100),
    Description NVARCHAR(500),
    CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3),
    CreatedByUserId BIGINT, UpdatedByUserId BIGINT, DeprecatedAt DATETIME2(3),
    ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500)
);
INSERT INTO #L EXEC Tools.ToolCavity_ListByTool @ToolId = @ToolId;

DECLARE @PN NVARCHAR(50) = (SELECT ItemPartNumber FROM #L WHERE CavityCode = N'b');
EXEC test.Assert_IsEqual @TestName=N'[CavItemList] ListByTool resolves ItemPartNumber', @Expected=N'CI-PART-2', @Actual=@PN;

-- LEFT JOIN, not INNER: the unmapped cavity must not be dropped from the list
DECLARE @Cnt INT = (SELECT COUNT(*) FROM #L);
EXEC test.Assert_RowCount @TestName=N'[CavItemList] Unmapped cavity still listed', @ExpectedCount=3, @ActualCount=@Cnt;
DROP TABLE #L;
GO

-- =============================================
-- Test 3: a non-existent part is rejected
-- =============================================
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CI-CAV-TOOL');
DECLARE @C1 BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityCode=N'a');
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@C1 AS NVARCHAR(20)) + N',"CavityCode":"a","Description":"Da","StatusCode":"Active","ItemId":999999999}]';
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R3; DROP TABLE #R3;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavItemBadPart] Non-existent part rejected', @Expected=N'0', @Actual=@SStr;
GO

-- =============================================
-- Test 4: a DEPRECATED part is rejected, and the row is left untouched
-- =============================================
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CI-CAV-TOOL');
DECLARE @C1 BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityCode=N'a');
DECLARE @Dead BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'CI-PART-DEAD');
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@C1 AS NVARCHAR(20)) + N',"CavityCode":"a","Description":"Da","StatusCode":"Active","ItemId":' + CAST(@Dead AS NVARCHAR(20)) + N'}]';
CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R4; DROP TABLE #R4;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavItemDeadPart] Deprecated part rejected', @Expected=N'0', @Actual=@SStr;

-- the validation runs pre-transaction, so nothing may have been written
DECLARE @P1Str NVARCHAR(20) = (SELECT CAST(Id AS NVARCHAR(20)) FROM Parts.Item WHERE PartNumber = N'CI-PART-1');
DECLARE @Still NVARCHAR(20) = (SELECT CAST(ISNULL(ItemId,-1) AS NVARCHAR(20)) FROM Tools.ToolCavity WHERE Id=@C1);
EXEC test.Assert_IsEqual @TestName=N'[CavItemDeadPart] Rejected save left ItemId unchanged', @Expected=@P1Str, @Actual=@Still;
GO

-- =============================================
-- Test 5a: an existing cavity can be REMAPPED to a different part -> succeeds
-- =============================================
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CI-CAV-TOOL');
DECLARE @C1 BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityCode=N'a');
DECLARE @P2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'CI-PART-2');
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@C1 AS NVARCHAR(20)) + N',"CavityCode":"a","Description":"Da","StatusCode":"Active","ItemId":' + CAST(@P2 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R5; DROP TABLE #R5;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavItemRemap] Status is 1', @Expected=N'1', @Actual=@SStr;

DECLARE @P2Str NVARCHAR(20) = CAST(@P2 AS NVARCHAR(20));
DECLARE @NewC1 NVARCHAR(20) = (SELECT CAST(ISNULL(ItemId,-1) AS NVARCHAR(20)) FROM Tools.ToolCavity WHERE Id=@C1);
EXEC test.Assert_IsEqual @TestName=N'[CavItemRemap] Cavity 1 remapped', @Expected=@P2Str, @Actual=@NewC1;
GO

-- =============================================
-- Test 5b: clearing an EXISTING mapping via SaveAll is now REJECTED.
--
-- D13 (2026-09-14, design doc 4.6): this is precisely the "existing row
-- edited to no part" case the new rule targets -- clearing a cavity's
-- ItemId is a real edit, not a no-op, so it must carry a part like any
-- other changed row. Was previously asserted to succeed and clear the
-- mapping; that assertion is now the opposite deliberately.
-- =============================================
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CI-CAV-TOOL');
DECLARE @C2 BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityCode=N'b');
DECLARE @PriorItemId BIGINT = (SELECT ItemId FROM Tools.ToolCavity WHERE Id=@C2);
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@C2 AS NVARCHAR(20)) + N',"CavityCode":"b","Description":"Db","StatusCode":"Active","ItemId":null}]';
CREATE TABLE #R5B (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5B EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R5B; DROP TABLE #R5B;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavItemClearReject] Clearing a mapping via SaveAll is rejected', @Expected=N'0', @Actual=@SStr;

DECLARE @PriorStr NVARCHAR(20) = CAST(@PriorItemId AS NVARCHAR(20));
DECLARE @StillC2 NVARCHAR(20) = (SELECT CAST(ISNULL(ItemId,-1) AS NVARCHAR(20)) FROM Tools.ToolCavity WHERE Id=@C2);
EXEC test.Assert_IsEqual @TestName=N'[CavItemClearReject] Cavity 2 mapping unchanged', @Expected=@PriorStr, @Actual=@StillC2;
GO

-- =============================================
-- Test 6: a CLOSED cavity still names its part -- the whole point of 0072
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CI-CAV-TOOL');
DECLARE @C1 BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityCode=N'a');
DECLARE @P2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'CI-PART-2');
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@C1 AS NVARCHAR(20)) + N',"CavityCode":"a","Description":"Da","StatusCode":"Closed","ItemId":' + CAST(@P2 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #R6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R6 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
DROP TABLE #R6;

DECLARE @ClosedPart NVARCHAR(50) = (
    SELECT it.PartNumber
    FROM Tools.ToolCavity c
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = c.StatusCodeId
    LEFT  JOIN Parts.Item it ON it.Id = c.ItemId
    WHERE c.Id = @C1 AND sc.Code = N'Closed');
EXEC test.Assert_IsEqual @TestName=N'[CavItemClosed] Closed cavity still names its part', @Expected=N'CI-PART-2', @Actual=@ClosedPart;
GO

EXEC test.EndTestFile;
GO
