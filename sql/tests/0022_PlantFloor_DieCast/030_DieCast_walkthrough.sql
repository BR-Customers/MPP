-- =============================================
-- File:         0022_PlantFloor_DieCast/030_DieCast_walkthrough.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-15
-- Description:  End-to-end die-cast operator-station walkthrough (Arc 2 Phase 3).
--               Stitches the three new procs into one realistic flow on a die-cast
--               Cell with a mounted Tool + Active cavity:
--                 1. Tools.ToolCavity_ListActiveByTool returns the Active cavity
--                    (and excludes a Closed cavity)
--                 2. Lots.Lot_Create (die-cast origin, Tool/Cavity required)
--                 3. ProductionEvent_Record x3 (cumulative shots climbing) — D2
--                    leaves Lot quantities untouched
--                 4. RejectEvent_Record partial -> D3 decrements
--                 5. RejectEvent_Record to zero -> D3 close-at-zero
--                 6. final assertions: PieceCount 0, LOT Closed, 3 checkpoints,
--                    2 reject rows
--
--               TEST-DC-* tool codes avoid colliding with 040_Lot_Create's
--               TEST-LC-* codes. EXEC args are pre-assigned @variables.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/030_DieCast_walkthrough.sql';
GO

-- ---- cleanup any prior fixtures (reverse FK order) ----
DELETE FROM Workorder.ProductionEventValue WHERE ProductionEventId IN (
    SELECT pe.Id FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'MESL%' OR l.LotName LIKE N'90000%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-DC-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DC-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-DC-TOOL';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-RJ';
GO

-- ---- fixture: a DefectCode (Quality.DefectCode is empty in dev/test). ----
DECLARE @DefAreaId BIGINT = (
    SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE l.DeprecatedAt IS NULL AND lt.Code = N'Area' ORDER BY l.Id);
INSERT INTO Quality.DefectCode (Code, Description, AreaLocationId, IsExcused, CreatedAt)
VALUES (N'TEST-DEF-RJ', N'Reject test defect', @DefAreaId, 0, SYSUTCDATETIME());
GO

-- ---- fixture: die-cast cell + tool with one Active + one Closed cavity ----
DECLARE @DieCellId BIGINT;
SELECT TOP 1 @DieCellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
INNER JOIN Location.Location l ON l.Id = eil.LocationId
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
WHERE lt.Code = N'Cell' AND eil.Source = N'Direct'
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-DC-TOOL', N'Walkthrough die', @ToolStatusActive, SYSUTCDATETIME(), 1);
DECLARE @ToolId BIGINT = SCOPE_IDENTITY();

DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
DECLARE @CavClosed BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Closed');
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, 1, @CavActive, SYSUTCDATETIME(), 1);
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, 2, @CavClosed, SYSUTCDATETIME(), 1);

INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@ToolId, @DieCellId, SYSUTCDATETIME(), 1);
GO

-- =============================================
-- Step 1: ToolCavity_ListActiveByTool returns only the Active cavity
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DC-TOOL');
CREATE TABLE #Cav (
    Id BIGINT, ToolId BIGINT, ToolCode NVARCHAR(50), ToolName NVARCHAR(100),
    CavityNumber INT, StatusCodeId BIGINT, StatusCode NVARCHAR(50), StatusName NVARCHAR(100),
    Description NVARCHAR(500));
INSERT INTO #Cav EXEC Tools.ToolCavity_ListActiveByTool @ToolId = @ToolId;
DECLARE @CavCnt INT = (SELECT COUNT(*) FROM #Cav);
DECLARE @CavCntStr NVARCHAR(10) = CAST(@CavCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Walk1] One active cavity listed (Closed excluded)', @Expected = N'1', @Actual = @CavCntStr;
DECLARE @AllActive INT = (SELECT COUNT(*) FROM #Cav WHERE StatusCode <> N'Active');
DECLARE @AllActiveStr NVARCHAR(10) = CAST(@AllActive AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Walk1] Every listed cavity is Active', @Expected = N'0', @Actual = @AllActiveStr;
DROP TABLE #Cav;
GO

-- =============================================
-- Step 2: Lot_Create (die-cast, Tool/Cavity required)
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DC-TOOL');
DECLARE @DieCellId BIGINT = (SELECT CellLocationId FROM Tools.ToolAssignment WHERE ToolId = @ToolId AND ReleasedAt IS NULL);
DECLARE @CavId BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 1);
DECLARE @DieItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @DieCellId AND Source = N'Direct');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

DECLARE @LotId BIGINT, @S BIT;
CREATE TABLE #L (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #L EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 8, @ToolId = @ToolId, @ToolCavityId = @CavId, @AppUserId = 1, @LotName = N'900000002';
SELECT @S = Status, @LotId = NewId FROM #L;
DROP TABLE #L;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Walk2] Die-cast Lot_Create Status is 1', @Expected = N'1', @Actual = @SStr;
GO

-- =============================================
-- Step 3: three climbing-cumulative checkpoints; D2 Lot quantities untouched
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%' ORDER BY Id DESC);
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot');
DECLARE @PriorPc INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);

DECLARE @S BIT, @SStr NVARCHAR(10);
CREATE TABLE #P1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #P1 EXEC Workorder.ProductionEvent_Record @LotId = @LotId, @OperationTemplateId = @OtId, @ShotCount = 3, @ScrapCount = 0, @AppUserId = 1;
SELECT @S = Status FROM #P1; DROP TABLE #P1;
SET @SStr = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Walk3] Checkpoint 1 accepted', @Expected = N'1', @Actual = @SStr;

CREATE TABLE #P2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #P2 EXEC Workorder.ProductionEvent_Record @LotId = @LotId, @OperationTemplateId = @OtId, @ShotCount = 6, @ScrapCount = 1, @AppUserId = 1;
SELECT @S = Status FROM #P2; DROP TABLE #P2;
SET @SStr = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Walk3] Checkpoint 2 accepted', @Expected = N'1', @Actual = @SStr;

CREATE TABLE #P3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #P3 EXEC Workorder.ProductionEvent_Record @LotId = @LotId, @OperationTemplateId = @OtId, @ShotCount = 8, @ScrapCount = 1, @AppUserId = 1;
SELECT @S = Status FROM #P3; DROP TABLE #P3;
SET @SStr = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Walk3] Checkpoint 3 accepted', @Expected = N'1', @Actual = @SStr;

DECLARE @CkCnt INT = (SELECT COUNT(*) FROM Workorder.ProductionEvent WHERE LotId = @LotId);
DECLARE @CkStr NVARCHAR(10) = CAST(@CkCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Walk3] Three ProductionEvent rows', @Expected = N'3', @Actual = @CkStr;

DECLARE @NowPc INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);
DECLARE @PriorPcStr NVARCHAR(10) = CAST(@PriorPc AS NVARCHAR(10));
DECLARE @NowPcStr NVARCHAR(10) = CAST(@NowPc AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Walk3][D2] Lot.PieceCount unchanged by checkpoints', @Expected = @PriorPcStr, @Actual = @NowPcStr;
GO

-- =============================================
-- Step 4: partial reject (D3 decrement)
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%' ORDER BY Id DESC);
DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-RJ');
DECLARE @S BIT;
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Workorder.RejectEvent_Record @LotId = @LotId, @DefectCodeId = @Defect, @Quantity = 2, @AppUserId = 1;
SELECT @S = Status FROM #R1; DROP TABLE #R1;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Walk4] Partial reject accepted', @Expected = N'1', @Actual = @SStr;
DECLARE @Pc INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);
DECLARE @PcStr NVARCHAR(10) = CAST(@Pc AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Walk4][D3] PieceCount 8-2=6', @Expected = N'6', @Actual = @PcStr;
GO

-- =============================================
-- Step 5: reject remaining -> close-at-zero
-- =============================================
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%' ORDER BY Id DESC);
DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-RJ');
DECLARE @Remaining INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);
DECLARE @S BIT;
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Workorder.RejectEvent_Record @LotId = @LotId, @DefectCodeId = @Defect, @Quantity = @Remaining, @AppUserId = 1;
SELECT @S = Status FROM #R2; DROP TABLE #R2;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Walk5] Final reject accepted', @Expected = N'1', @Actual = @SStr;

-- =============================================
-- Step 6: final state assertions
-- =============================================
DECLARE @FinalPc INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);
DECLARE @FinalPcStr NVARCHAR(10) = CAST(@FinalPc AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Walk6] Final PieceCount is 0', @Expected = N'0', @Actual = @FinalPcStr;
DECLARE @FinalStatus NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @LotId);
EXEC test.Assert_IsEqual @TestName = N'[Walk6] LOT Closed at end', @Expected = N'Closed', @Actual = @FinalStatus;
DECLARE @RjCnt INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @LotId);
DECLARE @RjStr NVARCHAR(10) = CAST(@RjCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Walk6] Two RejectEvent rows', @Expected = N'2', @Actual = @RjStr;
GO

-- ---- cleanup ----
DELETE FROM Workorder.ProductionEventValue WHERE ProductionEventId IN (
    SELECT pe.Id FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'MESL%' OR l.LotName LIKE N'90000%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-DC-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DC-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-DC-TOOL';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-RJ';
GO

EXEC test.EndTestFile;
GO
