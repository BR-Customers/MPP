-- =============================================
-- File:         0069_Aggregate_Reports/040_hold_and_shipping.sql
-- Author:       Blue Ridge Automation
-- Description:  FDS-12-010 Hold Status + FDS-12-011 Shipping History.
--
--               Also pins the FREEZE on Quality.Hold_ListOpen: it backs the
--               Hold Management screen, so the report got a sibling read rather
--               than a widened signature -- the same guard the Lot_Search
--               parity assertion provides in 0067.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0069_Aggregate_Reports/040_hold_and_shipping.sql';
GO

IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
CREATE TABLE #SF (Tag NVARCHAR(30) PRIMARY KEY, Val BIGINT);
IF OBJECT_ID(N'tempdb..#H') IS NOT NULL DROP TABLE #H;
CREATE TABLE #H (HoldEventId BIGINT, SubjectKind NVARCHAR(20), SubjectName NVARCHAR(50),
                 ItemPartNumber NVARCHAR(100), LotPieceCount INT, CurrentLocationName NVARCHAR(200),
                 HoldTypeCode NVARCHAR(50), HoldTypeName NVARCHAR(100), Reason NVARCHAR(500),
                 PlacedByName NVARCHAR(200), PlacedAt DATETIME2(3), HoursOnHold INT);
IF OBJECT_ID(N'tempdb..#S') IS NOT NULL DROP TABLE #S;
CREATE TABLE #S (ContainerId BIGINT, ItemPartNumber NVARCHAR(100), AimShipperId NVARCHAR(50),
                 PieceCount INT, SourceLotCount INT, OpenedAt DATETIME2(3),
                 CompletedAt DATETIME2(3), CurrentLocationName NVARCHAR(200));
GO

-- ---- Fixture: one held LOT (6h ago), one released hold, one shipped container ----
DECLARE @ItemId BIGINT, @CellA BIGINT, @LotId BIGINT, @ContainerId BIGINT, @ConfigId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @UserId    BIGINT = (SELECT MIN(Id) FROM Location.AppUser);
DECLARE @HoldType  BIGINT = (SELECT MIN(Id) FROM Quality.HoldTypeCode);

SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
  AND eil.ItemId IN (SELECT ItemId FROM Parts.ContainerConfig WHERE DeprecatedAt IS NULL)
ORDER BY eil.LocationId;

IF @ItemId IS NULL
    SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
    FROM Parts.v_EffectiveItemLocation eil
    WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
    ORDER BY eil.LocationId;

SELECT TOP 1 @ConfigId = Id FROM Parts.ContainerConfig
WHERE ItemId = @ItemId AND DeprecatedAt IS NULL;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 42, @AppUserId = @UserId,
    @VendorLotNumber = N'VND-HLD-001';
SELECT @LotId = NewId FROM @cr;
INSERT INTO #SF (Tag, Val) VALUES (N'Lot1', @LotId);

-- Open hold placed 6 hours ago.
INSERT INTO Quality.HoldEvent (LotId, HoldTypeCodeId, Reason, PlacedByUserId, PlacedAt)
VALUES (@LotId, @HoldType, N'Report fixture - open', @UserId,
        DATEADD(HOUR, -6, SYSUTCDATETIME()));

-- Released hold: must NOT appear on a currently-on-hold report.
INSERT INTO Quality.HoldEvent (LotId, HoldTypeCodeId, Reason, PlacedByUserId, PlacedAt,
                               ReleasedByUserId, ReleasedAt)
VALUES (@LotId, @HoldType, N'Report fixture - released', @UserId,
        DATEADD(HOUR, -9, SYSUTCDATETIME()), @UserId, DATEADD(HOUR, -8, SYSUTCDATETIME()));

-- A shipped container closed two days ago.
IF @ConfigId IS NOT NULL
BEGIN
    INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId,
                                ContainerStatusCodeId, OpenedAt, CompletedAt, CreatedByUserId)
    VALUES (@ItemId, @ConfigId, @CellA, 3, DATEADD(DAY, -3, SYSUTCDATETIME()),
            DATEADD(DAY, -2, SYSUTCDATETIME()), @UserId);
    SET @ContainerId = SCOPE_IDENTITY();
    INSERT INTO #SF (Tag, Val) VALUES (N'Container1', @ContainerId);
    INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount,
                                    ClosedAt, ClosedByUserId)
    VALUES (@ContainerId, 1, 24, DATEADD(DAY, -2, SYSUTCDATETIME()), @UserId);
END
GO

DECLARE @n INT, @s NVARCHAR(100);
DECLARE @Lot1 BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Lot1');
DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @Lot1);
DECLARE @ContainerId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Container1');

-- ---- Hold Status ----
INSERT INTO #H EXEC Quality.Hold_ListOpenForReport;

SELECT @n = COUNT(*) FROM #H WHERE SubjectName = @LotName;
EXEC test.Assert_IsEqual @TestName = N'[HoldStatus] the open hold appears exactly once',
    @Expected = N'1', @Actual = @n;

SELECT @n = COUNT(*) FROM #H WHERE Reason = N'Report fixture - released';
EXEC test.Assert_IsEqual @TestName = N'[HoldStatus] a RELEASED hold is excluded',
    @Expected = N'0', @Actual = @n;

SELECT @s = SubjectKind FROM #H WHERE SubjectName = @LotName;
EXEC test.Assert_IsEqual @TestName = N'[HoldStatus] a LOT hold reports SubjectKind of LOT',
    @Expected = N'LOT', @Actual = @s;

SELECT @n = HoursOnHold FROM #H WHERE SubjectName = @LotName;
EXEC test.Assert_IsEqual @TestName = N'[HoldStatus] duration on hold is computed (6h fixture)',
    @Expected = N'6', @Actual = @n;

SELECT @n = COUNT(*) FROM #H
WHERE SubjectName = @LotName
  AND (ItemPartNumber IS NULL OR PlacedByName IS NULL
       OR HoldTypeName IS NULL OR LotPieceCount IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[HoldStatus] part, placer, type and piece count all resolve',
    @Expected = N'0', @Actual = @n;

-- Hold_ListOpen stays FROZEN at its two parameters (it backs Hold Management).
SELECT @n = COUNT(*) FROM sys.parameters WHERE object_id = OBJECT_ID(N'Quality.Hold_ListOpen');
EXEC test.Assert_IsEqual @TestName = N'[HoldStatus] Hold_ListOpen still has exactly 2 parameters (frozen)',
    @Expected = N'2', @Actual = @n;

-- ---- Shipping History ----
IF @ContainerId IS NULL
BEGIN
    EXEC test.Assert_IsEqual @TestName = N'[ShippingHistory] SKIPPED -- no item with a ContainerConfig',
        @Expected = N'1', @Actual = N'1';
END
ELSE
BEGIN
    INSERT INTO #S EXEC Lots.Container_ListShipped;
    SELECT @n = COUNT(*) FROM #S WHERE ContainerId = @ContainerId;
    EXEC test.Assert_IsEqual @TestName = N'[ShippingHistory] the shipped container is listed',
        @Expected = N'1', @Actual = @n;

    SELECT @n = PieceCount FROM #S WHERE ContainerId = @ContainerId;
    EXEC test.Assert_IsEqual @TestName = N'[ShippingHistory] piece count sums the trays',
        @Expected = N'24', @Actual = @n;

    -- Ranged on CompletedAt (container CLOSE time): there is no ship timestamp
    -- and no integration that would ever supply one.
    DELETE FROM #S;
    INSERT INTO #S EXEC Lots.Container_ListShipped @FromEt = '2000-01-01', @ToEt = '2000-01-02';
    SELECT @n = COUNT(*) FROM #S WHERE ContainerId = @ContainerId;
    EXEC test.Assert_IsEqual @TestName = N'[ShippingHistory] a past window excludes it',
        @Expected = N'0', @Actual = @n;

    -- Scope is CLOSED containers, not status-3-only. INVERTED DELIBERATELY
    -- 2026-08-26: there will never be a Shipped flag in practice (MPP ships
    -- through their own infrastructure; MES is never told), so scoping on
    -- status 3 made this report return zero rows forever. A merely Complete
    -- container MUST now appear -- that is the whole point of the change.
    UPDATE Lots.Container SET ContainerStatusCodeId = 2 WHERE Id = @ContainerId;
    DELETE FROM #S;
    INSERT INTO #S EXEC Lots.Container_ListShipped;
    SELECT @n = COUNT(*) FROM #S WHERE ContainerId = @ContainerId;
    EXEC test.Assert_IsEqual @TestName = N'[ShippingHistory] a Complete-but-not-Shipped container IS listed',
        @Expected = N'1', @Actual = @n;

    -- An OPEN container is still excluded: closure is the observable end state,
    -- so the scope widened to "closed", not to "any container".
    UPDATE Lots.Container SET ContainerStatusCodeId = 1 WHERE Id = @ContainerId;
    DELETE FROM #S;
    INSERT INTO #S EXEC Lots.Container_ListShipped;
    SELECT @n = COUNT(*) FROM #S WHERE ContainerId = @ContainerId;
    EXEC test.Assert_IsEqual @TestName = N'[ShippingHistory] an Open container is excluded',
        @Expected = N'0', @Actual = @n;

    -- The AIM shipper ID resolves from the live (non-void) label, and a closed
    -- container with NO live label is still listed, with a blank ID. Both
    -- directions are asserted: a blank-only check would pass vacuously here,
    -- because the fixture container has no label to begin with.
    UPDATE Lots.Container SET ContainerStatusCodeId = 2 WHERE Id = @ContainerId;

    DECLARE @LabelTypeId BIGINT = (SELECT MIN(Id) FROM Lots.LabelTypeCode);
    INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId,
                                    Initial, IsVoid, CreatedAt, PrintAttempts)
    VALUES (@ContainerId, N'TEST-AIM-0069', @LabelTypeId, 1, 0, SYSUTCDATETIME(), 0);

    DELETE FROM #S;
    INSERT INTO #S EXEC Lots.Container_ListShipped;
    SELECT @s = AimShipperId FROM #S WHERE ContainerId = @ContainerId;
    EXEC test.Assert_IsEqual @TestName = N'[ShippingHistory] the live label supplies the AIM shipper ID',
        @Expected = N'TEST-AIM-0069', @Actual = @s;

    -- Voiding the label must NOT drop the container -- a closed container with
    -- no live shipper ID is a reconciliation gap and has to stay visible.
    UPDATE Lots.ShippingLabel SET IsVoid = 1 WHERE ContainerId = @ContainerId;
    DELETE FROM #S;
    INSERT INTO #S EXEC Lots.Container_ListShipped;
    SELECT @n = COUNT(*) FROM #S WHERE ContainerId = @ContainerId AND AimShipperId IS NULL;
    EXEC test.Assert_IsEqual @TestName = N'[ShippingHistory] a closed container whose label is void is still listed, with a blank shipper ID',
        @Expected = N'1', @Actual = @n;
END
GO

-- ---- Teardown ----
DECLARE @LotId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Lot1');
DECLARE @ContainerId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Container1');

DELETE FROM Quality.HoldEvent WHERE LotId = @LotId;
IF @ContainerId IS NOT NULL
BEGIN
    DELETE FROM Lots.ShippingLabel WHERE ContainerId = @ContainerId;
    DELETE FROM Lots.ContainerTray WHERE ContainerId = @ContainerId;
    DELETE FROM Lots.Container     WHERE Id          = @ContainerId;
END
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @LotId OR DescendantLotId = @LotId;
DELETE FROM Lots.LotGenealogy        WHERE ParentLotId = @LotId OR ChildLotId = @LotId;
DELETE FROM Lots.LotEventLog         WHERE LotId = @LotId;
DELETE FROM Lots.LotMovement         WHERE LotId = @LotId;
DELETE FROM Lots.LotStatusHistory    WHERE LotId = @LotId;
DELETE FROM Lots.Lot                 WHERE Id    = @LotId;

IF OBJECT_ID(N'tempdb..#H') IS NOT NULL DROP TABLE #H;
IF OBJECT_ID(N'tempdb..#S') IS NOT NULL DROP TABLE #S;
IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
GO
