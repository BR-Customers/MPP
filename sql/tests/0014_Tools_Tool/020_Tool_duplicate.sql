-- =============================================
-- File:         0014_Tools_Tool/020_Tool_duplicate.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-18
-- Description:
--   Tests for Tools.Tool_Duplicate -- the "Duplicate Die" clone proc.
--
--   Covers the COPY / RESET contract documented in
--   R__Tools_Tool_Duplicate.sql:
--     COPIED  - ToolTypeId, Description, DieRankId, ShotLimit,
--               ToolCavity layout, ToolAttribute values
--     RESET   - Code, Name, StatusCodeId ('Active'), ShotCount (0),
--               ToolCavity.StatusCodeId (copied as-is), DeprecatedAt (NULL),
--               ToolAssignment (not copied at all)
--     GUARDS  - deprecated source DieRank -> NULL (not an error)
--               deprecated attribute definition -> value skipped
--               duplicate Code / missing source / blank Code rejected
--
--   Pre-conditions:
--     - Migration 0010 (+ 0050 for ShotCount / ShotLimit) applied
--     - Tools.Tool_Duplicate and the Tools.Tool_* / ToolCavity_* /
--       ToolAttribute* procs deployed
--     - Bootstrap user Id=1 exists
--     - At least one Cell-tier Location (DefId 8) for the mount test
-- =============================================

EXEC test.BeginTestFile @FileName = N'0014_Tools_Tool/020_Tool_duplicate.sql';
GO

-- =============================================
-- Setup: ranks, source die, cavities, attributes, shot count, mount
-- =============================================
DECLARE @DieTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ActiveId  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');

-- Two ranks: one stays active, one gets deprecated for the guard test.
CREATE TABLE #RK1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RK1 EXEC Tools.DieRank_Create
    @Code = N'DUPA', @Name = N'Dup Rank A', @AppUserId = 1;
DROP TABLE #RK1;

CREATE TABLE #RK2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RK2 EXEC Tools.DieRank_Create
    @Code = N'DUPZ', @Name = N'Dup Rank Z', @AppUserId = 1;
DROP TABLE #RK2;

DECLARE @RankAId BIGINT = (SELECT Id FROM Tools.DieRank WHERE Code = N'DUPA');

-- Source die
CREATE TABLE #SRC (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #SRC EXEC Tools.Tool_Create
    @ToolTypeId   = @DieTypeId,
    @Code         = N'DUP-SRC',
    @Name         = N'Duplicate Source Die',
    @Description  = N'Source configuration',
    @DieRankId    = @RankAId,
    @StatusCodeId = @ActiveId,
    @AppUserId    = 1;
DECLARE @SrcId BIGINT = (SELECT NewId FROM #SRC);
DROP TABLE #SRC;

-- ShotLimit is design (copied); ShotCount is wear (reset). Set both directly --
-- ShotCount is only ever written by the die-cast shift-output proc.
UPDATE Tools.Tool SET ShotLimit = 50000, ShotCount = 1234 WHERE Id = @SrcId;

-- Three cavities. #2 Closed and #3 Scrapped -- wear states that must NOT clone.
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #C EXEC Tools.ToolCavity_Create
    @ToolId = @SrcId, @CavityNumber = 1, @Description = N'Cav one', @AppUserId = 1;
DELETE FROM #C;
INSERT INTO #C EXEC Tools.ToolCavity_Create
    @ToolId = @SrcId, @CavityNumber = 2, @Description = N'Cav two', @AppUserId = 1;
DELETE FROM #C;
INSERT INTO #C EXEC Tools.ToolCavity_Create
    @ToolId = @SrcId, @CavityNumber = 3, @Description = N'Cav three', @AppUserId = 1;
DROP TABLE #C;

DECLARE @Cav2Id BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @SrcId AND CavityNumber = 2);
DECLARE @Cav3Id BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @SrcId AND CavityNumber = 3);

CREATE TABLE #CS (Status BIT, Message NVARCHAR(500));
INSERT INTO #CS EXEC Tools.ToolCavity_UpdateStatus
    @Id = @Cav2Id, @StatusCode = N'Closed', @AppUserId = 1;
DELETE FROM #CS;
INSERT INTO #CS EXEC Tools.ToolCavity_UpdateStatus
    @Id = @Cav3Id, @StatusCode = N'Scrapped', @AppUserId = 1;
DROP TABLE #CS;

-- Two attribute definitions; the second is deprecated after its value is set.
CREATE TABLE #AD (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #AD EXEC Tools.ToolAttributeDefinition_Create
    @ToolTypeId = @DieTypeId, @Code = N'DUP_TON', @Name = N'Dup Tonnage',
    @DataType = N'Integer', @AppUserId = 1;
DELETE FROM #AD;
INSERT INTO #AD EXEC Tools.ToolAttributeDefinition_Create
    @ToolTypeId = @DieTypeId, @Code = N'DUP_OLD', @Name = N'Dup Retired Attr',
    @DataType = N'String', @AppUserId = 1;
DROP TABLE #AD;

DECLARE @DefTonId BIGINT = (SELECT Id FROM Tools.ToolAttributeDefinition
                            WHERE Code = N'DUP_TON' AND ToolTypeId = @DieTypeId);
DECLARE @DefOldId BIGINT = (SELECT Id FROM Tools.ToolAttributeDefinition
                            WHERE Code = N'DUP_OLD' AND ToolTypeId = @DieTypeId);

CREATE TABLE #AV (Status BIT, Message NVARCHAR(500));
INSERT INTO #AV EXEC Tools.ToolAttribute_Upsert
    @ToolId = @SrcId, @ToolAttributeDefinitionId = @DefTonId,
    @Value = N'850', @AppUserId = 1;
DELETE FROM #AV;
INSERT INTO #AV EXEC Tools.ToolAttribute_Upsert
    @ToolId = @SrcId, @ToolAttributeDefinitionId = @DefOldId,
    @Value = N'legacy', @AppUserId = 1;
DROP TABLE #AV;

CREATE TABLE #DD (Status BIT, Message NVARCHAR(500));
INSERT INTO #DD EXEC Tools.ToolAttributeDefinition_Deprecate
    @Id = @DefOldId, @AppUserId = 1;
DROP TABLE #DD;

-- Mount the source on a Cell so we can prove assignments are NOT cloned.
DECLARE @CellId BIGINT = (SELECT TOP 1 Id FROM Location.Location
                          WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL
                          ORDER BY SortOrder, Id);
IF @CellId IS NOT NULL
BEGIN
    CREATE TABLE #MT (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO #MT EXEC Tools.ToolAssignment_Assign
        @ToolId = @SrcId, @CellLocationId = @CellId,
        @Notes = N'Dup source mount', @AppUserId = 1;
    DROP TABLE #MT;
END
GO

-- =============================================
-- Test 1: Duplicate happy path - Status 1, NewId returned
-- =============================================
DECLARE @SrcId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DUP-SRC');

CREATE TABLE #D1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #D1 EXEC Tools.Tool_Duplicate
    @SourceToolId = @SrcId, @Code = N'DUP-NEW', @Name = N'Duplicate New Die',
    @AppUserId = 1;

DECLARE @S BIT = (SELECT Status FROM #D1);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DECLARE @NewId BIGINT = (SELECT NewId FROM #D1);
DECLARE @Msg NVARCHAR(500) = (SELECT Message FROM #D1);
DROP TABLE #D1;

EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate happy] Status is 1',
    @Expected = N'1', @Actual = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[Duplicate happy] NewId is not NULL',
    @Value = @NewIdStr;

EXEC test.Assert_Contains
    @TestName = N'[Duplicate happy] Message names the source',
    @HaystackStr = @Msg, @NeedleStr = N'DUP-SRC';
GO

-- =============================================
-- Test 2: Identity is NEW, configuration is COPIED
-- =============================================
DECLARE @SrcId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DUP-SRC');
DECLARE @NewId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DUP-NEW');

DECLARE @NewName NVARCHAR(100) = (SELECT Name FROM Tools.Tool WHERE Id = @NewId);
EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate copy] Name is the operator-supplied one',
    @Expected = N'Duplicate New Die', @Actual = @NewName;

DECLARE @SameType NVARCHAR(1) = (SELECT CASE WHEN n.ToolTypeId = s.ToolTypeId THEN N'1' ELSE N'0' END
                                 FROM Tools.Tool n, Tools.Tool s
                                 WHERE n.Id = @NewId AND s.Id = @SrcId);
EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate copy] ToolTypeId carried over',
    @Expected = N'1', @Actual = @SameType;

DECLARE @NewDesc NVARCHAR(500) = (SELECT Description FROM Tools.Tool WHERE Id = @NewId);
EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate copy] Description carried over',
    @Expected = N'Source configuration', @Actual = @NewDesc;

DECLARE @SameRank NVARCHAR(1) = (SELECT CASE WHEN n.DieRankId = s.DieRankId THEN N'1' ELSE N'0' END
                                 FROM Tools.Tool n, Tools.Tool s
                                 WHERE n.Id = @NewId AND s.Id = @SrcId);
EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate copy] DieRankId carried over',
    @Expected = N'1', @Actual = @SameRank;

DECLARE @NewLimit NVARCHAR(20) = (SELECT CAST(ShotLimit AS NVARCHAR(20)) FROM Tools.Tool WHERE Id = @NewId);
EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate copy] ShotLimit (design life) carried over',
    @Expected = N'50000', @Actual = @NewLimit;
GO

-- =============================================
-- Test 3: Per-asset state is RESET, not cloned
-- =============================================
DECLARE @NewId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DUP-NEW');

DECLARE @NewCount NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id = @NewId);
EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate reset] ShotCount starts at 0',
    @Expected = N'0', @Actual = @NewCount;

DECLARE @NewStatus NVARCHAR(20) = (SELECT sc.Code FROM Tools.Tool t
                                   INNER JOIN Tools.ToolStatusCode sc ON sc.Id = t.StatusCodeId
                                   WHERE t.Id = @NewId);
EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate reset] Status forced to Active',
    @Expected = N'Active', @Actual = @NewStatus;

DECLARE @NewDep NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), DeprecatedAt, 126) FROM Tools.Tool WHERE Id = @NewId);
EXEC test.Assert_IsNull
    @TestName = N'[Duplicate reset] DeprecatedAt is NULL',
    @Value = @NewDep;

DECLARE @AsnCount INT = (SELECT COUNT(*) FROM Tools.ToolAssignment WHERE ToolId = @NewId);
EXEC test.Assert_RowCount
    @TestName = N'[Duplicate reset] No ToolAssignment rows cloned',
    @ExpectedCount = 0, @ActualCount = @AsnCount;
GO

-- =============================================
-- Test 4: Cavity rows cloned WHOLE -- layout and status carry over as-is
-- =============================================
DECLARE @NewId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DUP-NEW');

DECLARE @CavCount INT = (SELECT COUNT(*) FROM Tools.ToolCavity
                         WHERE ToolId = @NewId AND DeprecatedAt IS NULL);
EXEC test.Assert_RowCount
    @TestName = N'[Duplicate cavities] All 3 cavities cloned',
    @ExpectedCount = 3, @ActualCount = @CavCount;

-- The source fixture is deliberately mixed: cavity 1 Active, cavity 2 Closed,
-- cavity 3 Scrapped. Each must land on the clone with the SAME status -- a
-- Closed / Scrapped cavity is a die-DESIGN decision, not wear, so it carries.
DECLARE @Cav1Status NVARCHAR(30) = (SELECT sc.Code FROM Tools.ToolCavity c
                                    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = c.StatusCodeId
                                    WHERE c.ToolId = @NewId AND c.CavityNumber = 1);
EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate cavities] Active cavity stays Active',
    @Expected = N'Active', @Actual = @Cav1Status;

DECLARE @Cav2Status NVARCHAR(30) = (SELECT sc.Code FROM Tools.ToolCavity c
                                    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = c.StatusCodeId
                                    WHERE c.ToolId = @NewId AND c.CavityNumber = 2);
EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate cavities] Closed cavity carries over as Closed',
    @Expected = N'Closed', @Actual = @Cav2Status;

DECLARE @Cav3Status NVARCHAR(30) = (SELECT sc.Code FROM Tools.ToolCavity c
                                    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = c.StatusCodeId
                                    WHERE c.ToolId = @NewId AND c.CavityNumber = 3);
EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate cavities] Scrapped cavity carries over as Scrapped',
    @Expected = N'Scrapped', @Actual = @Cav3Status;

DECLARE @Cav2Desc NVARCHAR(500) = (SELECT Description FROM Tools.ToolCavity
                                   WHERE ToolId = @NewId AND CavityNumber = 2);
EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate cavities] Cavity description carried over',
    @Expected = N'Cav two', @Actual = @Cav2Desc;
GO

-- =============================================
-- Test 5: Attributes cloned; deprecated definitions skipped
-- =============================================
DECLARE @NewId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DUP-NEW');

DECLARE @AttrCount INT = (SELECT COUNT(*) FROM Tools.ToolAttribute WHERE ToolId = @NewId);
EXEC test.Assert_RowCount
    @TestName = N'[Duplicate attributes] Only the active definition cloned',
    @ExpectedCount = 1, @ActualCount = @AttrCount;

DECLARE @TonVal NVARCHAR(500) = (SELECT ta.Value FROM Tools.ToolAttribute ta
                                 INNER JOIN Tools.ToolAttributeDefinition tad
                                         ON tad.Id = ta.ToolAttributeDefinitionId
                                 WHERE ta.ToolId = @NewId AND tad.Code = N'DUP_TON');
EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate attributes] Value carried over verbatim',
    @Expected = N'850', @Actual = @TonVal;
GO

-- =============================================
-- Test 6: Audit ConfigLog row written with the Duplicated narrative
-- =============================================
DECLARE @NewId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DUP-NEW');
DECLARE @Desc NVARCHAR(500) = (
    SELECT TOP 1 cl.Description
    FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
    WHERE et.Code = N'Tool' AND cl.EntityId = @NewId
    ORDER BY cl.Id DESC);

EXEC test.Assert_Contains
    @TestName = N'[Duplicate audit] Description says Duplicated from',
    @HaystackStr = @Desc, @NeedleStr = N'Duplicated from DUP-SRC';

EXEC test.Assert_Contains
    @TestName = N'[Duplicate audit] Description counts the cloned children',
    @HaystackStr = @Desc, @NeedleStr = N'+3 cavities, +1 attributes';
GO

-- =============================================
-- Test 7: Duplicate Code rejected (UQ_Tool_Code is total)
-- =============================================
DECLARE @SrcId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DUP-SRC');

CREATE TABLE #D7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #D7 EXEC Tools.Tool_Duplicate
    @SourceToolId = @SrcId, @Code = N'DUP-NEW', @Name = N'Second Attempt',
    @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #D7);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DECLARE @Msg NVARCHAR(500) = (SELECT Message FROM #D7);
DROP TABLE #D7;

EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate dup-code] rejected Status 0',
    @Expected = N'0', @Actual = @SStr;

EXEC test.Assert_Contains
    @TestName = N'[Duplicate dup-code] message explains the collision',
    @HaystackStr = @Msg, @NeedleStr = N'already exists';
GO

-- =============================================
-- Test 8: Unknown source rejected
-- =============================================
CREATE TABLE #D8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #D8 EXEC Tools.Tool_Duplicate
    @SourceToolId = 99999999, @Code = N'DUP-GHOST', @Name = N'Ghost',
    @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #D8);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DECLARE @Msg NVARCHAR(500) = (SELECT Message FROM #D8);
DROP TABLE #D8;

EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate no-source] rejected Status 0',
    @Expected = N'0', @Actual = @SStr;

EXEC test.Assert_Contains
    @TestName = N'[Duplicate no-source] message says not found',
    @HaystackStr = @Msg, @NeedleStr = N'not found';
GO

-- =============================================
-- Test 9: Blank Code rejected (whitespace-only trims to empty)
-- =============================================
DECLARE @SrcId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DUP-SRC');

CREATE TABLE #D9 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #D9 EXEC Tools.Tool_Duplicate
    @SourceToolId = @SrcId, @Code = N'   ', @Name = N'Blank Code',
    @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #D9);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DROP TABLE #D9;

EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate blank-code] rejected Status 0',
    @Expected = N'0', @Actual = @SStr;

-- Nothing was written: no half-built tool row survives a rejection.
DECLARE @Orphan INT = (SELECT COUNT(*) FROM Tools.Tool WHERE Name = N'Blank Code');
EXEC test.Assert_RowCount
    @TestName = N'[Duplicate blank-code] no partial Tool row written',
    @ExpectedCount = 0, @ActualCount = @Orphan;
GO

-- =============================================
-- Test 10: Deprecated source DieRank drops to NULL (not an error)
--
--   Reachability note: Tools.DieRank_Deprecate refuses while ACTIVE tools
--   reference the rank, so "a tool pointing at a deprecated rank" only ever
--   arises once that tool is itself retired -- i.e. exactly the replacement-die
--   case this guard exists for. Retire the die first, then the rank.
-- =============================================
DECLARE @DieTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ActiveId  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @RankZId   BIGINT = (SELECT Id FROM Tools.DieRank WHERE Code = N'DUPZ');

CREATE TABLE #Z1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Z1 EXEC Tools.Tool_Create
    @ToolTypeId = @DieTypeId, @Code = N'DUP-ZRANK', @Name = N'Deprecated Rank Die',
    @DieRankId = @RankZId, @StatusCodeId = @ActiveId, @AppUserId = 1;
DECLARE @ZSrcId BIGINT = (SELECT NewId FROM #Z1);
DROP TABLE #Z1;

CREATE TABLE #Z0 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Z0 EXEC Tools.Tool_Deprecate @Id = @ZSrcId, @AppUserId = 1;
DROP TABLE #Z0;

CREATE TABLE #Z2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Z2 EXEC Tools.DieRank_Deprecate @Id = @RankZId, @AppUserId = 1;
DECLARE @ZDep BIT = (SELECT Status FROM #Z2);
DECLARE @ZDepStr NVARCHAR(1) = CAST(@ZDep AS NVARCHAR(1));
DROP TABLE #Z2;

EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate dep-rank] setup: rank deprecated once its die retired',
    @Expected = N'1', @Actual = @ZDepStr;

CREATE TABLE #Z3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Z3 EXEC Tools.Tool_Duplicate
    @SourceToolId = @ZSrcId, @Code = N'DUP-ZRANK-2', @Name = N'Deprecated Rank Clone',
    @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #Z3);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DECLARE @Msg NVARCHAR(500) = (SELECT Message FROM #Z3);
DECLARE @ZNewId BIGINT = (SELECT NewId FROM #Z3);
DROP TABLE #Z3;

EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate dep-rank] still succeeds',
    @Expected = N'1', @Actual = @SStr;

DECLARE @ZRank NVARCHAR(20) = (SELECT CAST(DieRankId AS NVARCHAR(20)) FROM Tools.Tool WHERE Id = @ZNewId);
EXEC test.Assert_IsNull
    @TestName = N'[Duplicate dep-rank] DieRankId dropped to NULL',
    @Value = @ZRank;

EXEC test.Assert_Contains
    @TestName = N'[Duplicate dep-rank] message warns the rank was dropped',
    @HaystackStr = @Msg, @NeedleStr = N'not carried over';
GO

-- =============================================
-- Test 11: A retired (deprecated) source can still be duplicated,
--          and the clone comes back Active + not deprecated.
-- =============================================
DECLARE @SrcId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DUP-SRC');

-- Release the mount first -- Tool_Deprecate refuses a mounted tool.
CREATE TABLE #RL (Status BIT, Message NVARCHAR(500));
INSERT INTO #RL EXEC Tools.ToolAssignment_Release
    @ToolId = @SrcId, @AppUserId = 1, @Notes = N'Dup test teardown';
DROP TABLE #RL;

CREATE TABLE #DP (Status BIT, Message NVARCHAR(500));
INSERT INTO #DP EXEC Tools.Tool_Deprecate @Id = @SrcId, @AppUserId = 1;
DROP TABLE #DP;

CREATE TABLE #D11 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #D11 EXEC Tools.Tool_Duplicate
    @SourceToolId = @SrcId, @Code = N'DUP-REPL', @Name = N'Replacement Die',
    @AppUserId = 1;
DECLARE @S BIT = (SELECT Status FROM #D11);
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
DECLARE @RId BIGINT = (SELECT NewId FROM #D11);
DROP TABLE #D11;

EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate retired-source] succeeds (replacement die)',
    @Expected = N'1', @Actual = @SStr;

DECLARE @RDep NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), DeprecatedAt, 126) FROM Tools.Tool WHERE Id = @RId);
EXEC test.Assert_IsNull
    @TestName = N'[Duplicate retired-source] clone is not deprecated',
    @Value = @RDep;

DECLARE @RStatus NVARCHAR(20) = (SELECT sc.Code FROM Tools.Tool t
                                 INNER JOIN Tools.ToolStatusCode sc ON sc.Id = t.StatusCodeId
                                 WHERE t.Id = @RId);
EXEC test.Assert_IsEqual
    @TestName = N'[Duplicate retired-source] clone Status is Active',
    @Expected = N'Active', @Actual = @RStatus;

DECLARE @RCav INT = (SELECT COUNT(*) FROM Tools.ToolCavity WHERE ToolId = @RId AND DeprecatedAt IS NULL);
EXEC test.Assert_RowCount
    @TestName = N'[Duplicate retired-source] cavity layout still cloned',
    @ExpectedCount = 3, @ActualCount = @RCav;
GO

EXEC test.EndTestFile;
GO
