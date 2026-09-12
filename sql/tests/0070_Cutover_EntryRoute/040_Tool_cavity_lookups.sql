-- =============================================
-- File:         0070_Cutover_EntryRoute/040_Tool_cavity_lookups.sql
-- Description:  Part -> die and (part, die) -> cavity lookups that drive the
--               cutover scan screen. Tools.ToolCavity is keyed
--               (ToolId, ItemId, CavityCode), so both are single indexed reads.
--
--               A part resolving to exactly ONE die is what lets the scan screen
--               show the die as a resolved value instead of a picker -- measured
--               against Dev, that is 13 of 14 parts under the family-die model.
--
--               This file builds its OWN tool + cavities rather than leaning on
--               whatever ToolCavity rows other test files happen to have left
--               behind, so it is order-independent inside the suite.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/040_Tool_cavity_lookups.sql';
GO

DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @DieTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');

-- Pre-flight: clear this file's own fixtures from any earlier failed run.
DECLARE @StaleTool BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CUTOVER-DIE-A');
IF @StaleTool IS NOT NULL
BEGIN
    DELETE FROM Tools.ToolCavity WHERE ToolId = @StaleTool;
    DELETE FROM Tools.Tool WHERE Id = @StaleTool;
END

-- Fixture: one die running one part, with three cavities a/b/c.
DECLARE @Tool BIGINT;
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedByUserId)
VALUES (@DieTypeId, N'CUTOVER-DIE-A', N'Cutover scan fixture die', @ToolActive, @U);
SET @Tool = SCOPE_IDENTITY();

INSERT INTO Tools.ToolCavity (ToolId, ItemId, CavityCode, StatusCodeId, CreatedByUserId)
VALUES (@Tool, @Item, N'a', @CavActive, @U),
       (@Tool, @Item, N'b', @CavActive, @U),
       (@Tool, @Item, N'c', @CavActive, @U);

CREATE TABLE #T (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
CREATE TABLE #V (Id BIGINT, CavityCode NVARCHAR(4), Description NVARCHAR(500));

-- (1) The part resolves the die.
INSERT INTO #T EXEC Tools.Tool_ListForItem @ItemId = @Item;
DECLARE @d1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #T WHERE Id = @Tool);
EXEC test.Assert_IsEqual @TestName = N'[Tools] part resolves its die',
    @Expected = N'1', @Actual = @d1;

-- (2) Each die appears ONCE even though it carries three cavity rows for the
--     part -- the screen shows a die list, not a cavity list.
DECLARE @d2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #T WHERE Code = N'CUTOVER-DIE-A');
EXEC test.Assert_IsEqual @TestName = N'[Tools] a multi-cavity die is listed once, not per cavity',
    @Expected = N'1', @Actual = @d2;

-- (3) (part, die) yields its cavities, ordered by code.
INSERT INTO #V EXEC Tools.ToolCavity_ListForItemTool @ItemId = @Item, @ToolId = @Tool;
DECLARE @d3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #V);
EXEC test.Assert_IsEqual @TestName = N'[Tools] (part,die) yields its three cavities',
    @Expected = N'3', @Actual = @d3;

DECLARE @d4 NVARCHAR(20) = (SELECT STRING_AGG(CavityCode, N',') WITHIN GROUP (ORDER BY CavityCode) FROM #V);
EXEC test.Assert_IsEqual @TestName = N'[Tools] cavity codes come back ordered',
    @Expected = N'a,b,c', @Actual = @d4;

-- (4) Codes are the per-part lowercase alphabetic codes from migration 0076 --
--     the lowercase letter the operator reads off the LTT (tags write 'Da'/'Db',
--     capital = die revision, lowercase = cavity).
DECLARE @d5 NVARCHAR(10) = (SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM #V WHERE CavityCode IS NULL OR CavityCode <> LOWER(CavityCode))
    THEN N'1' ELSE N'0' END);
EXEC test.Assert_IsEqual @TestName = N'[Tools] cavity codes are lowercase and non-null',
    @Expected = N'1', @Actual = @d5;

-- (5) A deprecated cavity drops out.
UPDATE Tools.ToolCavity SET DeprecatedAt = SYSUTCDATETIME()
WHERE ToolId = @Tool AND ItemId = @Item AND CavityCode = N'c';
DELETE FROM #V; INSERT INTO #V EXEC Tools.ToolCavity_ListForItemTool @ItemId = @Item, @ToolId = @Tool;
DECLARE @d6 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #V);
EXEC test.Assert_IsEqual @TestName = N'[Tools] a deprecated cavity is excluded',
    @Expected = N'2', @Actual = @d6;

-- (6) Read contract: an unknown item returns an EMPTY SET, not an error and not
--     an invented row (FDS-11-011).
DELETE FROM #T; INSERT INTO #T EXEC Tools.Tool_ListForItem @ItemId = -1;
DECLARE @d7 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tools] unknown item returns an empty set',
    @Expected = N'0', @Actual = @d7;

DELETE FROM #V; INSERT INTO #V EXEC Tools.ToolCavity_ListForItemTool @ItemId = -1, @ToolId = -1;
DECLARE @d8 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #V);
EXEC test.Assert_IsEqual @TestName = N'[Tools] unknown (item,die) returns an empty set',
    @Expected = N'0', @Actual = @d8;

DROP TABLE #T; DROP TABLE #V;

-- Teardown.
DELETE FROM Tools.ToolCavity WHERE ToolId = @Tool;
DELETE FROM Tools.Tool WHERE Id = @Tool;
GO
