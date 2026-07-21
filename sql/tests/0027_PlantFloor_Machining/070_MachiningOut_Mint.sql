-- =============================================
-- File:         0027_PlantFloor_Machining/070_MachiningOut_Mint.sql
-- Description:  Workorder.MachiningOut_Mint (terminal-mint §3.4/§3.6). Mints a
--               SubAssembly LOT by consuming the casting; Consumption genealogy
--               (RelationshipTypeId=3), NOT Split; flexible qty; casting stays open
--               on a partial mint, closes when fully consumed; over-mint rejected.
--               Fixture: casting 5G0-c, SubAssembly 5G0-SA, seed BOM 5G0-SA<-5G0-c
--               (020_seed_items), at line cell MA1-5GOF-MOUT (both eligible via the
--               5G0 line). Casting basket cap = 24, so the fixture places 24 pcs.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/070_MachiningOut_Mint.sql';
GO

DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Uom BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'PCS');
DECLARE @Casting BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Machined BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-SA');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MoTpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
    WHERE oty.Code = N'MachiningOut' AND rk.Code = N'ConsumeMint' AND ot.DeprecatedAt IS NULL);

-- Fixture BOM: 6MA-M <- 6MA-C x1 (makes 6MA-C BOM-eligible where 6MA-M is eligible).
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Machined AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DECLARE @bc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    DECLARE @bl TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    DECLARE @bp TABLE (Status BIT, Message NVARCHAR(500));
    INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId = @Machined, @AppUserId = @U;
    DECLARE @Bom BIGINT = (SELECT NewId FROM @bc);
    INSERT INTO @bl EXEC Parts.BomLine_Add @BomId = @Bom, @ChildItemId = @Casting, @QtyPer = 1, @UomId = @Uom, @AppUserId = @U;
    INSERT INTO @bp EXEC Parts.Bom_Publish @Id = @Bom, @AppUserId = @U;
END

-- Place a 24-pc casting at the line.
DECLARE @CastLot BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Casting, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 24, @AppUserId = @U;
SELECT @CastLot = NewId FROM #C; DROP TABLE #C;

DECLARE @castCreated NVARCHAR(10) = CASE WHEN @CastLot IS NULL THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName = N'[MoMint] casting fixture placed', @Expected = N'1', @Actual = @castCreated;

-- Mint 10 (partial): casting -> 14 remaining; 10-pc machined LOT born at the line.
DECLARE @m TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
INSERT INTO @m EXEC Workorder.MachiningOut_Mint @SourceLotId = @CastLot, @OperationTemplateId = @MoTpl, @PieceCount = 10, @AppUserId = @U, @TerminalLocationId = @Line;
DECLARE @mStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @m);
EXEC test.Assert_IsEqual @TestName = N'[MoMint] mint succeeds', @Expected = N'1', @Actual = @mStatus;
DECLARE @MachLot BIGINT = (SELECT NewId FROM @m);

-- Sublot name is derived from the casting LTT + '-01' (first child of this casting).
DECLARE @castName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @CastLot);
DECLARE @machName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @MachLot);
DECLARE @exp1 NVARCHAR(50) = @castName + N'-01';
EXEC test.Assert_IsEqual @TestName = N'[MoMint] first sublot name is <casting>-01', @Expected = @exp1, @Actual = @machName;
DECLARE @seqBeforeMint BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');

DECLARE @machItem NVARCHAR(20) = (SELECT CAST(ItemId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @MachLot);
DECLARE @machExp NVARCHAR(20) = CAST(@Machined AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[MoMint] minted LOT is the SubAssembly item', @Expected = @machExp, @Actual = @machItem;

DECLARE @machPc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @MachLot);
EXEC test.Assert_IsEqual @TestName = N'[MoMint] minted LOT is 10 pcs', @Expected = N'10', @Actual = @machPc;

DECLARE @machLoc NVARCHAR(20) = (SELECT CAST(CurrentLocationId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @MachLot);
DECLARE @lineExp NVARCHAR(20) = CAST(@Line AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[MoMint] minted LOT is line-resident', @Expected = @lineExp, @Actual = @machLoc;

DECLARE @castRemain NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @CastLot);
EXEC test.Assert_IsEqual @TestName = N'[MoMint] casting decrements to 14', @Expected = N'14', @Actual = @castRemain;

DECLARE @castOpen NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @CastLot);
EXEC test.Assert_IsEqual @TestName = N'[MoMint] casting stays open on partial mint', @Expected = N'Good', @Actual = @castOpen;

DECLARE @consEdge NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotGenealogy WHERE ParentLotId = @CastLot AND ChildLotId = @MachLot AND RelationshipTypeId = 3);
EXEC test.Assert_IsEqual @TestName = N'[MoMint] Consumption edge casting->machined', @Expected = N'1', @Actual = @consEdge;

DECLARE @splitEdge NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotGenealogy WHERE ChildLotId = @MachLot AND RelationshipTypeId = 1);
EXEC test.Assert_IsEqual @TestName = N'[MoMint] no Split edge written', @Expected = N'0', @Actual = @splitEdge;

DECLARE @consEvt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE SourceLotId = @CastLot AND ProducedLotId = @MachLot AND ConsumedItemId = @Casting AND ProducedItemId = @Machined AND PieceCount = 10);
EXEC test.Assert_IsEqual @TestName = N'[MoMint] ConsumptionEvent recorded', @Expected = N'1', @Actual = @consEvt;

-- Mint the remaining 14 -> casting closes.
DELETE FROM @m; INSERT INTO @m EXEC Workorder.MachiningOut_Mint @SourceLotId = @CastLot, @OperationTemplateId = @MoTpl, @PieceCount = 14, @AppUserId = @U, @TerminalLocationId = @Line;

-- Second child of the same casting -> '-02'; counter still not advanced by the mint.
DECLARE @machLot2 BIGINT = (SELECT NewId FROM @m);
DECLARE @machName2 NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @machLot2);
DECLARE @exp2 NVARCHAR(50) = @castName + N'-02';
EXEC test.Assert_IsEqual @TestName = N'[MoMint] second sublot name is <casting>-02', @Expected = @exp2, @Actual = @machName2;
DECLARE @seqAfterMint BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
DECLARE @seqDelta NVARCHAR(10) = CAST(@seqAfterMint - @seqBeforeMint AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MoMint] mint does not advance Lot counter', @Expected = N'0', @Actual = @seqDelta;

DECLARE @castClosed NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @CastLot);
EXEC test.Assert_IsEqual @TestName = N'[MoMint] casting closes when fully consumed', @Expected = N'Closed', @Actual = @castClosed;

-- Over-mint rejected.
CREATE TABLE #C2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C2 EXEC Lots.Lot_Create @ItemId = @Casting, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 5, @AppUserId = @U;
DECLARE @Small BIGINT = (SELECT NewId FROM #C2); DROP TABLE #C2;
DELETE FROM @m; INSERT INTO @m EXEC Workorder.MachiningOut_Mint @SourceLotId = @Small, @OperationTemplateId = @MoTpl, @PieceCount = 99, @AppUserId = @U, @TerminalLocationId = @Line;
DECLARE @overStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @m);
EXEC test.Assert_IsEqual @TestName = N'[MoMint] over-mint rejected', @Expected = N'0', @Actual = @overStatus;
GO

-- =============================================
-- FIFO multi-source: two castings, mint spans both (oldest-first), 2 parents
-- =============================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Casting BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Machined BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-SA');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MoTpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
    WHERE oty.Code = N'MachiningOut' AND rk.Code = N'ConsumeMint' AND ot.DeprecatedAt IS NULL);

-- clear the leftover open 5-pc casting from the preceding [MoMint] over-mint-rejected
-- block (that mint was rejected, so the casting it targeted was never consumed/closed)
-- so the FIFO queue total below is exactly @Old + @New, not @Small + @Old + @New.
UPDATE Lots.Lot SET LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed')
  WHERE ItemId=@Casting AND CurrentLocationId=@Line AND LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');

-- Oldest casting: 18 pcs. Newer casting: 24 pcs. (arrival order = creation order here)
-- NOTE: 5G0-c has Item.MaxLotSize=24 (Lot_Create rejects any PieceCount above the cap,
-- confirmed via manual repro during Task 1 TDD) -- the brief's original 30-pc newer
-- casting silently failed Lot_Create (captured Status=0 into an unchecked #FA), leaving
-- @New NULL and collapsing the FIFO queue to one casting. Capped at 24 (the item's max)
-- and the downstream assertion adjusted from 30-6=24 to 24-6=18 accordingly.
DECLARE @Old BIGINT, @New BIGINT;
CREATE TABLE #FA (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #FA EXEC Lots.Lot_Create @ItemId=@Casting, @LotOriginTypeId=@Origin, @CurrentLocationId=@Line, @PieceCount=18, @AppUserId=@U;
SELECT @Old = NewId FROM #FA; DELETE FROM #FA;
INSERT INTO #FA EXEC Lots.Lot_Create @ItemId=@Casting, @LotOriginTypeId=@Origin, @CurrentLocationId=@Line, @PieceCount=24, @AppUserId=@U;
SELECT @New = NewId FROM #FA; DROP TABLE #FA;

-- Mint 24: should draw 18 from @Old (closes it) + 6 from @New (stays open at 18).
DECLARE @fm TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
INSERT INTO @fm EXEC Workorder.MachiningOut_Mint @SourceLotId=@Old, @OperationTemplateId=@MoTpl, @PieceCount=24, @AppUserId=@U, @TerminalLocationId=@Line;
DECLARE @fmStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @fm);
DECLARE @fmLot BIGINT = (SELECT NewId FROM @fm);
EXEC test.Assert_IsEqual @TestName = N'[FIFO] mint spanning two castings succeeds', @Expected = N'1', @Actual = @fmStatus;

DECLARE @oldPc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@Old);
EXEC test.Assert_IsEqual @TestName = N'[FIFO] oldest casting drained to 0', @Expected = N'0', @Actual = @oldPc;
DECLARE @oldSt NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@Old);
EXEC test.Assert_IsEqual @TestName = N'[FIFO] oldest casting Closed', @Expected = N'Closed', @Actual = @oldSt;
DECLARE @newPc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@New);
EXEC test.Assert_IsEqual N'[FIFO] next casting 24-6=18', N'18', @newPc;
DECLARE @newSt NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@New);
EXEC test.Assert_IsEqual N'[FIFO] next casting stays Good', N'Good', @newSt;
DECLARE @parents NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotGenealogy WHERE ChildLotId=@fmLot AND RelationshipTypeId=3);
EXEC test.Assert_IsEqual N'[FIFO] minted LOT has 2 Consumption parents', N'2', @parents;
DECLARE @ce NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedLotId=@fmLot);
EXEC test.Assert_IsEqual N'[FIFO] two ConsumptionEvents (one per source)', N'2', @ce;
DECLARE @never NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE Id IN (@Old,@New) AND PieceCount < 0);
EXEC test.Assert_IsEqual N'[FIFO] no casting negative', N'0', @never;
GO

-- =============================================
-- Shortfall: reject (default) then partial (AllowPartial=1)
-- =============================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Casting BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MoTpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
    WHERE oty.Code = N'MachiningOut' AND rk.Code = N'ConsumeMint' AND ot.DeprecatedAt IS NULL);
-- clear leftover open 5G0-c castings from the prior FIFO test so the queue total is known
UPDATE Lots.Lot SET LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed')
  WHERE ItemId=@Casting AND CurrentLocationId=@Line AND LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');
DECLARE @S1 BIGINT;
CREATE TABLE #SF (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #SF EXEC Lots.Lot_Create @ItemId=@Casting, @LotOriginTypeId=@Origin, @CurrentLocationId=@Line, @PieceCount=20, @AppUserId=@U;
SELECT @S1 = NewId FROM #SF; DROP TABLE #SF;

-- request 24 with only 20 available, no partial -> reject, Available=20
DECLARE @sm TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
INSERT INTO @sm EXEC Workorder.MachiningOut_Mint @SourceLotId=@S1, @OperationTemplateId=@MoTpl, @PieceCount=24, @AppUserId=@U, @TerminalLocationId=@Line;
DECLARE @smS NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @sm);
DECLARE @smA NVARCHAR(10) = (SELECT CAST(Available AS NVARCHAR(10)) FROM @sm);
EXEC test.Assert_IsEqual N'[Shortfall] rejected (no partial)', N'0', @smS;
EXEC test.Assert_IsEqual N'[Shortfall] Available reported = 20', N'20', @smA;
DECLARE @s1pc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@S1);
EXEC test.Assert_IsEqual N'[Shortfall] nothing consumed', N'20', @s1pc;

-- request 24 with AllowPartial=1 -> mint 20, drain the queue
DELETE FROM @sm;
INSERT INTO @sm EXEC Workorder.MachiningOut_Mint @SourceLotId=@S1, @OperationTemplateId=@MoTpl, @PieceCount=24, @AppUserId=@U, @TerminalLocationId=@Line, @AllowPartial=1;
DECLARE @smS2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @sm);
DECLARE @pmLot BIGINT = (SELECT NewId FROM @sm);
EXEC test.Assert_IsEqual N'[Partial] partial mint succeeds', N'1', @smS2;
DECLARE @pmPc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@pmLot);
EXEC test.Assert_IsEqual N'[Partial] minted 20 (all available)', N'20', @pmPc;
DECLARE @s1after NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@S1);
EXEC test.Assert_IsEqual N'[Partial] source drained to 0', N'0', @s1after;
GO

-- ---- teardown (FK-safe): all LOTs of the fixture items 5G0-c / 5G0-SA ----
DECLARE @Cast BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Mach BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-SA');
DECLARE @Lots TABLE (Id BIGINT);
INSERT INTO @Lots SELECT Id FROM Lots.Lot WHERE ItemId IN (@Cast, @Mach);
DELETE FROM Workorder.ConsumptionEvent WHERE SourceLotId IN (SELECT Id FROM @Lots) OR ProducedLotId IN (SELECT Id FROM @Lots);
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @Lots) OR ChildLotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @Lots) OR DescendantLotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @Lots);
-- NOTE: 5G0-SA <- 5G0-c is a SEED BOM (020_seed_items) this test relies on -- do NOT
-- delete it in teardown; it must survive for the seed + later suites.
GO
