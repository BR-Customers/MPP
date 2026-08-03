-- =============================================
-- File: 0049_AimIntegration/020_Container_Complete_payload.sql
-- Desc: Container_Complete stamps the AIM post-back payload onto the claimed
--       pool row, inside the claim transaction, without changing its result shape.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0049_AimIntegration/020_Container_Complete_payload.sql';
GO

-- Arrange: build our own container (Run-Tests resets with -SkipDemoSeed, so
-- Lots.Container is EMPTY). FIXTURE BLOCK, PART = 'AIM-P1-T3'.
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId LIKE N'0009%';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId
    INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'AIM-P1-T3';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-T3');

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'AIM-P1-T3')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'AIM-P1-T3', N'AIM plan-1 test part', 1, @Now, 1);
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-T3');
UPDATE Parts.Item SET AimCustomerPartNumber = N'112006FB A000' WHERE Id = @ItemId;

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @ItemId AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@ItemId, 1, 15, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @ItemId AND DeprecatedAt IS NULL);

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @UserId BIGINT = 1;

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open
    @ItemId = @ItemId, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = @UserId;
DECLARE @ContainerId BIGINT = (SELECT NewId FROM @O);

DECLARE @TC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @TC EXEC Lots.ContainerTray_Close
    @ContainerId = @ContainerId, @TrayPosition = 1, @PartsCount = 15,
    @ClosureMethod = N'ByCount', @AppUserId = @UserId;

-- NOTE (deviation from the brief's literal fixture): ContainerTray_Close is a thin
-- tray-insert/accumulation helper (see R__Lots_ContainerTray_Close.sql header) -- it does
-- NOT mint a finished-good LOT or set ContainerTray.FinishedGoodLotId; only
-- Workorder.Assembly_CompleteTray does that, and pulling that proc in here would require a
-- full BOM + component-stock fixture unrelated to what this test is checking. Mint a
-- minimal FG LOT the same way sibling Arc2/Phase6 test fixtures do (Lots.Lot_Create,
-- Manufactured origin) and attach it to the tray directly, so Container_Complete's
-- @PostLot derivation (mirrors the established Lots.Container_GetLabelData.MfgLotNumber
-- pattern: first tray's FinishedGoodLotId ordered by TrayPosition) has something to find.
-- Lot_Create requires Direct item/location eligibility (Parts.ItemLocation) at @Cell.
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @ItemId AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt) VALUES (@ItemId, @Cell, @Now);

DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CL EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell,
    @PieceCount = 15, @AppUserId = @UserId, @LotName = N'AIM-P1-T3-LOT';
DECLARE @FgLotId BIGINT = (SELECT NewId FROM @CL);
UPDATE Lots.ContainerTray SET FinishedGoodLotId = @FgLotId
    WHERE ContainerId = @ContainerId AND TrayPosition = 1;

INSERT INTO Lots.AimShipperIdPool (AimShipperId, FetchedAt)
VALUES (N'000900101', SYSUTCDATETIME());

-- Act
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @R EXEC Lots.Container_Complete
    @ContainerId = @ContainerId, @AppUserId = @UserId, @TerminalLocationId = NULL;

DECLARE @Ok NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] Container_Complete succeeds',
    @Expected = N'1', @Actual = @Ok;

DECLARE @Serial NVARCHAR(50) = (SELECT AimShipperId FROM @R);

-- Assert: payload written on the claimed pool row.
DECLARE @Part NVARCHAR(50) = (SELECT CustomerPartNumber FROM Lots.AimShipperIdPool
                              WHERE AimShipperId = @Serial);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] claimed row carries the AIM customer part',
    @Expected = N'112006FB A000', @Actual = @Part;

DECLARE @QtyOk NVARCHAR(10) = (SELECT CASE WHEN p.Quantity =
        (SELECT ISNULL(SUM(t.PartsClosedCount), 0) FROM Lots.ContainerTray t
         WHERE t.ContainerId = @ContainerId AND t.ClosedAt IS NOT NULL)
    THEN N'1' ELSE N'0' END
    FROM Lots.AimShipperIdPool p WHERE p.AimShipperId = @Serial);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] quantity equals the sum of closed tray counts',
    @Expected = N'1', @Actual = @QtyOk;

DECLARE @Lot NVARCHAR(50) = (SELECT LotNumber FROM Lots.AimShipperIdPool
                             WHERE AimShipperId = @Serial);
EXEC test.Assert_IsNotNull
    @TestName = N'[0049] lot number captured from the first tray FG LOT',
    @Value = @Lot;

DECLARE @NotPosted NVARCHAR(10) = (SELECT CASE WHEN PostedAt IS NULL AND PostAttempts = 0
    THEN N'1' ELSE N'0' END FROM Lots.AimShipperIdPool WHERE AimShipperId = @Serial);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] row starts owed - PostedAt null, attempts zero',
    @Expected = N'1', @Actual = @NotPosted;
GO

EXEC test.EndTestFile;
GO
