-- =============================================
-- File:         0022_PlantFloor_DieCast/040_CavityParallel_peers.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-15
-- Description:  Cavity-parallelism tests for Tools.ToolCavity_ListActiveByTool
--               (Arc 2 Phase 3 §4.3) plus the parallel-cavity LOT shape.
--               A die has N cavities that run in parallel; the operator station
--               picks the active cavity to attribute a cast LOT to. Covers:
--                 - multiple Active cavities listed, ordered by CavityNumber
--                 - a Closed cavity is excluded
--                 - a soft-deleted (DeprecatedAt) cavity is excluded
--                 - a tool with zero active cavities -> empty rowset (no error)
--                 - the listed columns do NOT include a producing ItemId (the
--                   produced part is derived from LOT/WO context, not per-cavity —
--                   §4.3 resolution)
--                 - two independent LOTs cast from two different active cavities
--                   of the SAME tool are tracked separately
--
--               EXEC args are pre-assigned @variables (no inline CAST).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/040_CavityParallel_peers.sql';
GO

-- ---- cleanup any prior fixtures ----
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code IN (N'TEST-CP-MULTI', N'TEST-CP-EMPTY');
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code IN (N'TEST-CP-MULTI', N'TEST-CP-EMPTY'));
DELETE FROM Tools.Tool WHERE Code IN (N'TEST-CP-MULTI', N'TEST-CP-EMPTY');
GO

-- ---- fixture: a 4-cavity die: cavities 1,2 Active; 3 Closed; 4 Active-but-deprecated ----
DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-CP-MULTI', N'Multi-cavity die', @ToolStatusActive, SYSUTCDATETIME(), 1);
DECLARE @MultiTool BIGINT = SCOPE_IDENTITY();

DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
DECLARE @CavClosed BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Closed');
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId) VALUES (@MultiTool, 2, @CavActive, SYSUTCDATETIME(), 1);  -- inserted out of order
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId) VALUES (@MultiTool, 1, @CavActive, SYSUTCDATETIME(), 1);
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId) VALUES (@MultiTool, 3, @CavClosed, SYSUTCDATETIME(), 1);
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId, DeprecatedAt) VALUES (@MultiTool, 4, @CavActive, SYSUTCDATETIME(), 1, SYSUTCDATETIME());

-- a tool with no active cavities at all (one Closed only)
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-CP-EMPTY', N'No active cavities die', @ToolStatusActive, SYSUTCDATETIME(), 1);
DECLARE @EmptyTool BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId) VALUES (@EmptyTool, 1, @CavClosed, SYSUTCDATETIME(), 1);
GO

-- =============================================
-- Test 1: only the two Active non-deprecated cavities listed, ordered 1,2
-- =============================================
DECLARE @MultiTool BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-CP-MULTI');
CREATE TABLE #L1 (
    Id BIGINT, ToolId BIGINT, ToolCode NVARCHAR(50), ToolName NVARCHAR(100),
    CavityNumber INT, StatusCodeId BIGINT, StatusCode NVARCHAR(50), StatusName NVARCHAR(100),
    Description NVARCHAR(500));
INSERT INTO #L1 EXEC Tools.ToolCavity_ListActiveByTool @ToolId = @MultiTool;

DECLARE @Cnt INT = (SELECT COUNT(*) FROM #L1);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CpMulti] Two active cavities listed', @Expected = N'2', @Actual = @CntStr;

DECLARE @NonActive INT = (SELECT COUNT(*) FROM #L1 WHERE StatusCode <> N'Active');
DECLARE @NonActiveStr NVARCHAR(10) = CAST(@NonActive AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CpMulti] No non-Active rows', @Expected = N'0', @Actual = @NonActiveStr;

-- ordered ascending by CavityNumber -> the first physical row is cavity 1
DECLARE @TopRowCav INT = (SELECT CavityNumber FROM (SELECT CavityNumber, ROW_NUMBER() OVER (ORDER BY (SELECT 0)) rn FROM #L1) z WHERE rn = 1);
DECLARE @TopRowCavStr NVARCHAR(10) = CAST(@TopRowCav AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CpMulti] Result ordered by CavityNumber (first=1)', @Expected = N'1', @Actual = @TopRowCavStr;

-- cavity 3 (Closed) excluded; cavity 4 (deprecated) excluded
DECLARE @HasClosed INT = (SELECT COUNT(*) FROM #L1 WHERE CavityNumber = 3);
DECLARE @HasClosedStr NVARCHAR(10) = CAST(@HasClosed AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CpMulti] Closed cavity 3 excluded', @Expected = N'0', @Actual = @HasClosedStr;
DECLARE @HasDeprecated INT = (SELECT COUNT(*) FROM #L1 WHERE CavityNumber = 4);
DECLARE @HasDeprStr NVARCHAR(10) = CAST(@HasDeprecated AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CpMulti] Deprecated cavity 4 excluded', @Expected = N'0', @Actual = @HasDeprStr;

-- §4.3 resolution: no producing ItemId column in the result set
DECLARE @HasItemIdCol INT = (SELECT COUNT(*) FROM tempdb.sys.columns WHERE object_id = OBJECT_ID('tempdb..#L1') AND name = N'ItemId');
DECLARE @HasItemIdColStr NVARCHAR(10) = CAST(@HasItemIdCol AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CpMulti] No producing ItemId column (derived, not per-cavity)', @Expected = N'0', @Actual = @HasItemIdColStr;
DROP TABLE #L1;
GO

-- =============================================
-- Test 2: tool with zero active cavities -> empty rowset, no error
-- =============================================
DECLARE @EmptyTool BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-CP-EMPTY');
CREATE TABLE #L2 (
    Id BIGINT, ToolId BIGINT, ToolCode NVARCHAR(50), ToolName NVARCHAR(100),
    CavityNumber INT, StatusCodeId BIGINT, StatusCode NVARCHAR(50), StatusName NVARCHAR(100),
    Description NVARCHAR(500));
INSERT INTO #L2 EXEC Tools.ToolCavity_ListActiveByTool @ToolId = @EmptyTool;
DECLARE @Cnt2 INT = (SELECT COUNT(*) FROM #L2);
DECLARE @Cnt2Str NVARCHAR(10) = CAST(@Cnt2 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CpEmpty] Tool with no active cavities -> empty', @Expected = N'0', @Actual = @Cnt2Str;
DROP TABLE #L2;
GO

-- =============================================
-- Test 3: non-existent tool -> empty rowset, no error
-- =============================================
CREATE TABLE #L3 (
    Id BIGINT, ToolId BIGINT, ToolCode NVARCHAR(50), ToolName NVARCHAR(100),
    CavityNumber INT, StatusCodeId BIGINT, StatusCode NVARCHAR(50), StatusName NVARCHAR(100),
    Description NVARCHAR(500));
INSERT INTO #L3 EXEC Tools.ToolCavity_ListActiveByTool @ToolId = 999999999;
DECLARE @Cnt3 INT = (SELECT COUNT(*) FROM #L3);
DECLARE @Cnt3Str NVARCHAR(10) = CAST(@Cnt3 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CpNoTool] Non-existent tool -> empty', @Expected = N'0', @Actual = @Cnt3Str;
DROP TABLE #L3;
GO

-- =============================================
-- Test 4: two LOTs cast from two different active cavities of the SAME tool
-- =============================================
DECLARE @MultiTool BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-CP-MULTI');
DECLARE @DieCellId BIGINT;
SELECT TOP 1 @DieCellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
INNER JOIN Location.Location l ON l.Id = eil.LocationId
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
WHERE lt.Code = N'Cell' AND eil.Source = N'Direct'
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@MultiTool, @DieCellId, SYSUTCDATETIME(), 1);

DECLARE @DieItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @DieCellId AND Source = N'Direct');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Cav1 BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @MultiTool AND CavityNumber = 1 AND DeprecatedAt IS NULL);
DECLARE @Cav2 BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @MultiTool AND CavityNumber = 2 AND DeprecatedAt IS NULL);

DECLARE @Lot1 BIGINT, @Lot2 BIGINT, @S1 BIT, @S2 BIT;
CREATE TABLE #LA (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #LA EXEC Lots.Lot_Create @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId, @PieceCount = 4, @ToolId = @MultiTool, @ToolCavityId = @Cav1, @AppUserId = 1, @LotName = N'900000010';
SELECT @S1 = Status, @Lot1 = NewId FROM #LA; DROP TABLE #LA;

CREATE TABLE #LB (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #LB EXEC Lots.Lot_Create @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId, @PieceCount = 6, @ToolId = @MultiTool, @ToolCavityId = @Cav2, @AppUserId = 1, @LotName = N'900000011';
SELECT @S2 = Status, @Lot2 = NewId FROM #LB; DROP TABLE #LB;

DECLARE @S1Str NVARCHAR(10) = CAST(@S1 AS NVARCHAR(10));
DECLARE @S2Str NVARCHAR(10) = CAST(@S2 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CpPeers] LOT from cavity 1 created', @Expected = N'1', @Actual = @S1Str;
EXEC test.Assert_IsEqual @TestName = N'[CpPeers] LOT from cavity 2 created', @Expected = N'1', @Actual = @S2Str;

DECLARE @LotCav1 BIGINT = (SELECT ToolCavityId FROM Lots.Lot WHERE Id = @Lot1);
DECLARE @LotCav2 BIGINT = (SELECT ToolCavityId FROM Lots.Lot WHERE Id = @Lot2);
DECLARE @Cav1Str NVARCHAR(20) = CAST(@Cav1 AS NVARCHAR(20));
DECLARE @Cav2Str NVARCHAR(20) = CAST(@Cav2 AS NVARCHAR(20));
DECLARE @LotCav1Str NVARCHAR(20) = CAST(@LotCav1 AS NVARCHAR(20));
DECLARE @LotCav2Str NVARCHAR(20) = CAST(@LotCav2 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[CpPeers] LOT1 attributed to cavity 1', @Expected = @Cav1Str, @Actual = @LotCav1Str;
EXEC test.Assert_IsEqual @TestName = N'[CpPeers] LOT2 attributed to cavity 2', @Expected = @Cav2Str, @Actual = @LotCav2Str;

-- independent checkpoints: LOT1 gets one, LOT2 stays at zero
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot');
DECLARE @SP BIT;
CREATE TABLE #PP1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #PP1 EXEC Workorder.ProductionEvent_Record @LotId = @Lot1, @OperationTemplateId = @OtId, @ShotCount = 2, @AppUserId = 1;
SELECT @SP = Status FROM #PP1; DROP TABLE #PP1;
DECLARE @SPStr NVARCHAR(10) = CAST(@SP AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CpPeers] Checkpoint on LOT1 accepted', @Expected = N'1', @Actual = @SPStr;

DECLARE @Lot1Events INT = (SELECT COUNT(*) FROM Workorder.ProductionEvent WHERE LotId = @Lot1);
DECLARE @Lot2Events INT = (SELECT COUNT(*) FROM Workorder.ProductionEvent WHERE LotId = @Lot2);
DECLARE @Lot1EvStr NVARCHAR(10) = CAST(@Lot1Events AS NVARCHAR(10));
DECLARE @Lot2EvStr NVARCHAR(10) = CAST(@Lot2Events AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CpPeers] LOT1 has its own checkpoint', @Expected = N'1', @Actual = @Lot1EvStr;
EXEC test.Assert_IsEqual @TestName = N'[CpPeers] LOT2 unaffected (zero checkpoints)', @Expected = N'0', @Actual = @Lot2EvStr;
GO

-- ---- cleanup ----
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code IN (N'TEST-CP-MULTI', N'TEST-CP-EMPTY');
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code IN (N'TEST-CP-MULTI', N'TEST-CP-EMPTY'));
DELETE FROM Tools.Tool WHERE Code IN (N'TEST-CP-MULTI', N'TEST-CP-EMPTY');
GO

EXEC test.EndTestFile;
GO
