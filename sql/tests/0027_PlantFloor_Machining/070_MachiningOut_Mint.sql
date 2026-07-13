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
DECLARE @m TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @m EXEC Workorder.MachiningOut_Mint @SourceLotId = @CastLot, @OperationTemplateId = @MoTpl, @PieceCount = 10, @AppUserId = @U, @TerminalLocationId = @Line;
DECLARE @mStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @m);
EXEC test.Assert_IsEqual @TestName = N'[MoMint] mint succeeds', @Expected = N'1', @Actual = @mStatus;
DECLARE @MachLot BIGINT = (SELECT NewId FROM @m);

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
