-- =============================================
-- File:         0020_PlantFloor_Foundation/045_LotGenealogyClosure_self.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-09
-- Description:  Lot_Create inserts a LotGenealogyClosure self-row
--               (Ancestor=New, Descendant=New, Depth=0). A rolled-back
--               Lot_Create leaves no closure row.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/045_LotGenealogyClosure_self.sql';
GO

-- =============================================
-- Test 1: successful Lot_Create writes exactly one self-row Depth=0
-- =============================================
DECLARE @ItemId BIGINT, @CellId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @S BIT, @NewId BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 7, @AppUserId = 1;
SELECT @S = Status, @NewId = NewId FROM #C;
DROP TABLE #C;

DECLARE @SelfCnt INT = (SELECT COUNT(*) FROM Lots.LotGenealogyClosure
                        WHERE AncestorLotId = @NewId AND DescendantLotId = @NewId AND Depth = 0);
DECLARE @SelfStr NVARCHAR(10) = CAST(@SelfCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[ClosureSelf] Exactly one self-row Depth=0',
    @Expected = N'1',
    @Actual   = @SelfStr;

-- cleanup this lot
DELETE FROM Lots.LotMovement WHERE LotId = @NewId;
DELETE FROM Lots.LotStatusHistory WHERE LotId = @NewId;
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @NewId OR DescendantLotId = @NewId;
DELETE FROM Lots.Lot WHERE Id = @NewId;
GO

-- =============================================
-- Test 2: a rolled-back Lot_Create leaves no closure row.
--   Wrap the call in a transaction and ROLLBACK; assert no closure rows for
--   the (would-be) lot. We detect via the minted LotName not existing AND no
--   orphan closure rows referencing a non-existent lot.
-- =============================================
DECLARE @ItemId BIGINT, @CellId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @BeforeClosure INT = (SELECT COUNT(*) FROM Lots.LotGenealogyClosure);
DECLARE @NewId BIGINT, @Minted NVARCHAR(50);

CREATE TABLE #C2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
BEGIN TRANSACTION;
    INSERT INTO #C2 EXEC Lots.Lot_Create
        @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
        @PieceCount = 7, @AppUserId = 1;
    SELECT @NewId = NewId, @Minted = MintedLotName FROM #C2;
ROLLBACK TRANSACTION;
DROP TABLE #C2;

-- After rollback: the lot row must not exist, and closure count is unchanged.
DECLARE @LotExists INT = (SELECT COUNT(*) FROM Lots.Lot WHERE Id = @NewId);
DECLARE @LotExistsStr NVARCHAR(10) = CAST(@LotExists AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[ClosureRollback] Rolled-back Lot does not persist',
    @Expected = N'0',
    @Actual   = @LotExistsStr;

DECLARE @AfterClosure INT = (SELECT COUNT(*) FROM Lots.LotGenealogyClosure);
DECLARE @ClosureDelta NVARCHAR(10) = CAST(@AfterClosure - @BeforeClosure AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[ClosureRollback] No closure row left after rollback',
    @Expected = N'0',
    @Actual   = @ClosureDelta;
GO

EXEC test.EndTestFile;
GO
