-- =============================================
-- File:         0023_PlantFloor_DieCast_Deltas/030_Lot_Create_LotName_and_Cavity.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Tests for Lots.Lot_Create additive params (Phase 3 delta, Change 3):
--               D4 @LotName (mint-by-default; supplied = use verbatim, no counter
--               burn; duplicate/blank rejected) and D2 @CavityNote (manual cavity
--               when no active ToolCavity). Backward-compat: NULL params behave as
--               today (the 0021/0022 LOT tests run unmodified).
--
--               Self-contained tool fixture: a Tool 'ZZ-DC-TEST' + one Active
--               ToolCavity, mounted on an eligible Cell. LotName tests use Received
--               origin (die-cast branch skipped); D2 tests use Manufactured origin
--               (die-cast branch fires).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0023_PlantFloor_DieCast_Deltas/030_Lot_Create_LotName_and_Cavity.sql';
GO

-- ---- teardown prior fixtures (FK-safe: LOTs before Tool/Cavity) ----
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.LotMovement       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-DC-TEST');
DELETE FROM Tools.ToolCavity     WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-DC-TEST');
DELETE FROM Tools.Tool WHERE Code = N'ZZ-DC-TEST';
GO

-- ---- build the tool fixture: Tool 'ZZ-DC-TEST' + Active cavity, mounted on an eligible Cell ----
DECLARE @CellId BIGINT;
SELECT TOP 1 @CellId = eil.LocationId FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @ToolTypeId BIGINT = (SELECT TOP 1 Id FROM Tools.ToolType ORDER BY Id);
DECLARE @ToolStatusId BIGINT = (SELECT TOP 1 Id FROM Tools.ToolStatusCode ORDER BY Id);
DECLARE @CavActiveId BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');

INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedByUserId, CreatedAt)
VALUES (@ToolTypeId, N'ZZ-DC-TEST', N'Phase3 delta test die', @ToolStatusId, 1, SYSUTCDATETIME());
DECLARE @ToolId BIGINT = SCOPE_IDENTITY();

INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedByUserId, CreatedAt)
VALUES (@ToolId, 1, @CavActiveId, 1, SYSUTCDATETIME());

INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@ToolId, @CellId, SYSUTCDATETIME(), 1);
GO

-- =============================================
-- Test 1 (REGRESSION): @LotName NULL mints + advances the 'Lot' sequence by 1
-- =============================================
DECLARE @CellId BIGINT = (SELECT TOP 1 CellLocationId FROM Tools.ToolAssignment ta
    INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'ZZ-DC-TEST' AND ta.ReleasedAt IS NULL);
DECLARE @ItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @CellId ORDER BY ItemId);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @SeqBefore BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
DECLARE @Minted NVARCHAR(50);
CREATE TABLE #C1 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C1 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=5, @AppUserId=1;
SELECT @Minted = MintedLotName FROM #C1; DROP TABLE #C1;
DECLARE @SeqAfter BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
DECLARE @Delta NVARCHAR(10) = CAST(@SeqAfter - @SeqBefore AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC] NULL LotName advances sequence by 1', @Expected = N'1', @Actual = @Delta;
DECLARE @MintedNonEmpty NVARCHAR(10) = CASE WHEN @Minted IS NOT NULL AND LEN(@Minted) > 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[LC] NULL LotName returns a minted name', @Expected = N'1', @Actual = @MintedNonEmpty;
GO

-- =============================================
-- Test 2: @LotName supplied -> stored + sequence NOT advanced
-- =============================================
DECLARE @CellId BIGINT = (SELECT TOP 1 CellLocationId FROM Tools.ToolAssignment ta
    INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'ZZ-DC-TEST' AND ta.ReleasedAt IS NULL);
DECLARE @ItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @CellId ORDER BY ItemId);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @SeqBefore BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
DECLARE @Minted NVARCHAR(50); DECLARE @S BIT;
CREATE TABLE #C2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C2 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=5, @AppUserId=1, @LotName=N'TEST-LTT-0001';
SELECT @S = Status, @Minted = MintedLotName FROM #C2; DROP TABLE #C2;
DECLARE @SeqAfter BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
DECLARE @Delta NVARCHAR(10) = CAST(@SeqAfter - @SeqBefore AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC] supplied LotName does NOT advance sequence', @Expected = N'0', @Actual = @Delta;
EXEC test.Assert_IsEqual @TestName = N'[LC] supplied LotName echoed in MintedLotName', @Expected = N'TEST-LTT-0001', @Actual = @Minted;
DECLARE @Exists NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName = N'TEST-LTT-0001') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[LC] supplied LotName stored', @Expected = N'1', @Actual = @Exists;
GO

-- =============================================
-- Test 3: duplicate @LotName -> Status=0, clean message, no second row
-- =============================================
DECLARE @CellId BIGINT = (SELECT TOP 1 CellLocationId FROM Tools.ToolAssignment ta
    INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'ZZ-DC-TEST' AND ta.ReleasedAt IS NULL);
DECLARE @ItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @CellId ORDER BY ItemId);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @S BIT;
CREATE TABLE #C3 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C3 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=5, @AppUserId=1, @LotName=N'TEST-LTT-0001';
SELECT @S = Status FROM #C3; DROP TABLE #C3;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC] duplicate LotName rejected', @Expected = N'0', @Actual = @SStr;
DECLARE @Cnt NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Lots.Lot WHERE LotName = N'TEST-LTT-0001') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC] duplicate LotName: still one row', @Expected = N'1', @Actual = @Cnt;
GO

-- =============================================
-- Test 4: blank @LotName -> Status=0
-- =============================================
DECLARE @CellId BIGINT = (SELECT TOP 1 CellLocationId FROM Tools.ToolAssignment ta
    INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'ZZ-DC-TEST' AND ta.ReleasedAt IS NULL);
DECLARE @ItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @CellId ORDER BY ItemId);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @S BIT;
CREATE TABLE #C4 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C4 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=5, @AppUserId=1, @LotName=N'   ';
SELECT @S = Status FROM #C4; DROP TABLE #C4;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC] blank LotName rejected', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 5: D2 manual cavity (Manufactured origin, ToolCavityId NULL + CavityNote)
-- =============================================
DECLARE @CellId BIGINT = (SELECT TOP 1 CellLocationId FROM Tools.ToolAssignment ta
    INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'ZZ-DC-TEST' AND ta.ReleasedAt IS NULL);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-DC-TEST');
DECLARE @ItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @CellId ORDER BY ItemId);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @S5 BIT, @New5 BIGINT;
CREATE TABLE #C5 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C5 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginMfg, @CurrentLocationId=@CellId,
    @PieceCount=5, @AppUserId=1, @ToolId=@ToolId, @ToolCavityId=NULL, @CavityNote=N'C3';
SELECT @S5 = Status, @New5 = NewId FROM #C5; DROP TABLE #C5;
DECLARE @S5Str NVARCHAR(10) = CAST(@S5 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC][D2] manual cavity accepted', @Expected = N'1', @Actual = @S5Str;
DECLARE @CavNum NVARCHAR(50) = (SELECT CavityNumber FROM Lots.Lot WHERE Id = @New5);
EXEC test.Assert_IsEqual @TestName = N'[LC][D2] CavityNumber stored', @Expected = N'C3', @Actual = @CavNum;
DECLARE @TcNull NVARCHAR(10) = CASE WHEN (SELECT ToolCavityId FROM Lots.Lot WHERE Id = @New5) IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[LC][D2] ToolCavityId NULL on manual path', @Expected = N'1', @Actual = @TcNull;
GO

-- =============================================
-- Test 6: D2 reject (Manufactured, ToolCavityId NULL + CavityNote NULL) -> Status=0
-- =============================================
DECLARE @CellId BIGINT = (SELECT TOP 1 CellLocationId FROM Tools.ToolAssignment ta
    INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'ZZ-DC-TEST' AND ta.ReleasedAt IS NULL);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-DC-TEST');
DECLARE @ItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @CellId ORDER BY ItemId);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @S6 BIT;
CREATE TABLE #C6 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C6 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginMfg, @CurrentLocationId=@CellId,
    @PieceCount=5, @AppUserId=1, @ToolId=@ToolId, @ToolCavityId=NULL, @CavityNote=NULL;
SELECT @S6 = Status FROM #C6; DROP TABLE #C6;
DECLARE @S6Str NVARCHAR(10) = CAST(@S6 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC][D2] no cavity + no note rejected', @Expected = N'0', @Actual = @S6Str;
GO

-- =============================================
-- Test 7: D2 validated path unchanged (Manufactured + valid cavity) -> Status=1, CavityNumber NULL
-- =============================================
DECLARE @CellId BIGINT = (SELECT TOP 1 CellLocationId FROM Tools.ToolAssignment ta
    INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'ZZ-DC-TEST' AND ta.ReleasedAt IS NULL);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-DC-TEST');
DECLARE @CavId BIGINT = (SELECT TOP 1 tc.Id FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
    WHERE tc.ToolId = @ToolId AND sc.Code = N'Active' ORDER BY tc.Id);
DECLARE @ItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @CellId ORDER BY ItemId);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @S7 BIT, @New7 BIGINT;
CREATE TABLE #C7 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C7 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginMfg, @CurrentLocationId=@CellId,
    @PieceCount=5, @AppUserId=1, @ToolId=@ToolId, @ToolCavityId=@CavId;
SELECT @S7 = Status, @New7 = NewId FROM #C7; DROP TABLE #C7;
DECLARE @S7Str NVARCHAR(10) = CAST(@S7 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC][D2] validated cavity path still works', @Expected = N'1', @Actual = @S7Str;
DECLARE @CavNull NVARCHAR(10) = CASE WHEN (SELECT CavityNumber FROM Lots.Lot WHERE Id = @New7) IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[LC][D2] validated path leaves CavityNumber NULL', @Expected = N'1', @Actual = @CavNull;
GO

-- ---- teardown ----
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.LotMovement       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-DC-TEST');
DELETE FROM Tools.ToolCavity     WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-DC-TEST');
DELETE FROM Tools.Tool WHERE Code = N'ZZ-DC-TEST';
GO
EXEC test.EndTestFile;
GO
