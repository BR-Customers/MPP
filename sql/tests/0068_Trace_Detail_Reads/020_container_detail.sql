-- =============================================
-- File:         0068_Trace_Detail_Reads/020_container_detail.sql
-- Author:       Blue Ridge Automation
-- Description:  FDS-12-003 container trace payload + its two sibling reads
--               (serial list, hold history). Three procs because one proc
--               returns one result set (FDS-11-011).
--
--               The reset database has no Containers, so this builds:
--               LOT -> minted serial -> container -> tray -> ContainerSerial
--               link -> a placed-and-released hold and a still-open hold.
--               Both hold states matter: Quality.Hold_GetOpenByContainer
--               filters ReleasedAt IS NULL and therefore CANNOT serve
--               FDS-12-003's "hold history" -- Hold_ListByContainer must
--               return the released one too.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0068_Trace_Detail_Reads/020_container_detail.sql';
GO

IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
CREATE TABLE #SF (Tag NVARCHAR(30) PRIMARY KEY, Val BIGINT);

IF OBJECT_ID(N'tempdb..#CD') IS NOT NULL DROP TABLE #CD;
CREATE TABLE #CD (
    ContainerId BIGINT, ItemId BIGINT, ItemPartNumber NVARCHAR(100),
    ContainerStatusCode NVARCHAR(50), PieceCount INT, SerialCount INT,
    SourceLotCount INT, OpenedAt DATETIME2(3), CompletedAt DATETIME2(3),
    AimShipperId NVARCHAR(50), OpenHoldCount INT, TotalHoldCount INT
);
IF OBJECT_ID(N'tempdb..#CS') IS NOT NULL DROP TABLE #CS;
CREATE TABLE #CS (
    SerializedPartId BIGINT, SerialNumber NVARCHAR(50), TrayPosition INT,
    ProducingLotId BIGINT, ProducingLotName NVARCHAR(50)
);
IF OBJECT_ID(N'tempdb..#CH') IS NOT NULL DROP TABLE #CH;
CREATE TABLE #CH (
    HoldEventId BIGINT, HoldTypeCode NVARCHAR(50), HoldTypeName NVARCHAR(100),
    Reason NVARCHAR(500), PlacedByName NVARCHAR(200), PlacedAt DATETIME2(3),
    ReleasedByName NVARCHAR(200), ReleasedAt DATETIME2(3),
    ReleaseRemarks NVARCHAR(500), IsOpen INT
);
GO

-- ---- Fixture ----
DECLARE @ItemId BIGINT, @CellA BIGINT, @LotId BIGINT, @SerialId BIGINT;
DECLARE @ContainerId BIGINT, @TrayId BIGINT, @ConfigId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @UserId    BIGINT = (SELECT MIN(Id) FROM Location.AppUser);
DECLARE @HoldType  BIGINT = (SELECT MIN(Id) FROM Quality.HoldTypeCode);

SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT ItemId FROM Parts.ContainerConfig WHERE DeprecatedAt IS NULL)
ORDER BY eil.LocationId;

SELECT TOP 1 @ConfigId = Id FROM Parts.ContainerConfig
WHERE ItemId = @ItemId AND DeprecatedAt IS NULL;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 10, @AppUserId = @UserId,
    @VendorLotNumber = N'VND-CON-001';
SELECT @LotId = NewId FROM @cr;
INSERT INTO #SF (Tag, Val) VALUES (N'Lot1', @LotId);

DECLARE @sm TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO @sm EXEC Lots.SerializedPart_Mint @ItemId = @ItemId, @ProducingLotId = @LotId,
    @AppUserId = @UserId, @TerminalLocationId = @CellA;
SELECT @SerialId = NewId FROM @sm;
INSERT INTO #SF (Tag, Val) VALUES (N'Serial1', @SerialId);

DECLARE @co TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @co EXEC Lots.Container_Open @ItemId = @ItemId, @ContainerConfigId = @ConfigId,
    @CellLocationId = @CellA, @AppUserId = @UserId;
SELECT @ContainerId = NewId FROM @co;
INSERT INTO #SF (Tag, Val) VALUES (N'Container1', @ContainerId);

-- One tray carrying a known piece count, INSERTed directly so PartsClosedCount
-- is pinned (the tray-close proc derives it from the closure method).
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId)
VALUES (@ContainerId, 1, 7, SYSUTCDATETIME(), @UserId);
SET @TrayId = SCOPE_IDENTITY();
INSERT INTO #SF (Tag, Val) VALUES (N'Tray1', @TrayId);

DECLARE @cs TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @cs EXEC Lots.ContainerSerial_Add @ContainerId = @ContainerId,
    @ContainerTrayId = @TrayId, @TrayPosition = 1,
    @SerializedPartId = @SerialId, @AppUserId = @UserId;

-- Two holds: one released (history only), one still open.
INSERT INTO Quality.HoldEvent (ContainerId, HoldTypeCodeId, Reason, PlacedByUserId,
                               PlacedAt, ReleasedByUserId, ReleasedAt, ReleaseRemarks)
VALUES (@ContainerId, @HoldType, N'Released test hold', @UserId,
        DATEADD(HOUR, -2, SYSUTCDATETIME()), @UserId, DATEADD(HOUR, -1, SYSUTCDATETIME()),
        N'Cleared');
INSERT INTO Quality.HoldEvent (ContainerId, HoldTypeCodeId, Reason, PlacedByUserId, PlacedAt)
VALUES (@ContainerId, @HoldType, N'Open test hold', @UserId, SYSUTCDATETIME());
GO

-- ---- Assertions ----
DECLARE @n INT;
DECLARE @ContainerId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Container1');
DECLARE @LotId       BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Lot1');

-- 1. Unknown ids return empty sets from all three reads.
INSERT INTO #CD EXEC Lots.Container_GetTraceDetail @ContainerId = -1;
SELECT @n = COUNT(*) FROM #CD;
EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] unknown container returns empty set',
    @Expected = N'0', @Actual = @n;
DELETE FROM #CD;

INSERT INTO #CS EXEC Lots.Container_ListSerials @ContainerId = -1;
SELECT @n = COUNT(*) FROM #CS;
EXEC test.Assert_IsEqual @TestName = N'[ContainerSerials] unknown container returns empty set',
    @Expected = N'0', @Actual = @n;
DELETE FROM #CS;

INSERT INTO #CH EXEC Quality.Hold_ListByContainer @ContainerId = -1;
SELECT @n = COUNT(*) FROM #CH;
EXEC test.Assert_IsEqual @TestName = N'[ContainerHolds] unknown container returns empty set',
    @Expected = N'0', @Actual = @n;
DELETE FROM #CH;

-- 2. The fixture container returns exactly one row with identity resolved.
INSERT INTO #CD EXEC Lots.Container_GetTraceDetail @ContainerId = @ContainerId;
SELECT @n = COUNT(*) FROM #CD;
EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] known container returns exactly one row',
    @Expected = N'1', @Actual = @n;

SELECT @n = COUNT(*) FROM #CD WHERE ItemPartNumber IS NULL OR ContainerStatusCode IS NULL
                                 OR OpenedAt IS NULL;
EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] part number, status and OpenedAt populated',
    @Expected = N'0', @Actual = @n;

-- 3. Derived counts are never NULL (the ISNULL guards) and are correct.
SELECT @n = COUNT(*) FROM #CD
WHERE PieceCount IS NULL OR SerialCount IS NULL OR SourceLotCount IS NULL
   OR OpenHoldCount IS NULL OR TotalHoldCount IS NULL;
EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] derived counts are never NULL',
    @Expected = N'0', @Actual = @n;

SELECT @n = MAX(PieceCount) FROM #CD;
EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] PieceCount sums tray PartsClosedCount',
    @Expected = N'7', @Actual = @n;

SELECT @n = MAX(SerialCount) FROM #CD;
EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] SerialCount counts the linked serial',
    @Expected = N'1', @Actual = @n;

SELECT @n = MAX(SourceLotCount) FROM #CD;
EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] SourceLotCount resolves the producing LOT',
    @Expected = N'1', @Actual = @n;

-- 4. Hold counts split open from total.
SELECT @n = MAX(TotalHoldCount) FROM #CD;
EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] TotalHoldCount counts open AND released',
    @Expected = N'2', @Actual = @n;

SELECT @n = MAX(OpenHoldCount) FROM #CD;
EXEC test.Assert_IsEqual @TestName = N'[ContainerDetail] OpenHoldCount counts only the unreleased hold',
    @Expected = N'1', @Actual = @n;
DELETE FROM #CD;

-- 5. The serial-list sibling agrees with SerialCount and resolves its LOT.
INSERT INTO #CS EXEC Lots.Container_ListSerials @ContainerId = @ContainerId;
SELECT @n = COUNT(*) FROM #CS;
EXEC test.Assert_IsEqual @TestName = N'[ContainerSerials] returns the linked serial',
    @Expected = N'1', @Actual = @n;

SELECT @n = COUNT(*) FROM #CS
WHERE ProducingLotId = @LotId AND ProducingLotName IS NOT NULL AND TrayPosition = 1;
EXEC test.Assert_IsEqual @TestName = N'[ContainerSerials] producing LOT and tray position resolve',
    @Expected = N'1', @Actual = @n;
DELETE FROM #CS;

-- 6. Hold HISTORY returns both states -- the reason this proc exists rather
--    than reusing the open-only Hold_GetOpenByContainer.
INSERT INTO #CH EXEC Quality.Hold_ListByContainer @ContainerId = @ContainerId;
SELECT @n = COUNT(*) FROM #CH;
EXEC test.Assert_IsEqual @TestName = N'[ContainerHolds] history returns BOTH the open and released hold',
    @Expected = N'2', @Actual = @n;

SELECT @n = COUNT(*) FROM #CH WHERE IsOpen = 0 AND ReleasedAt IS NOT NULL
                                AND ReleasedByName IS NOT NULL;
EXEC test.Assert_IsEqual @TestName = N'[ContainerHolds] released hold carries ReleasedAt and releaser',
    @Expected = N'1', @Actual = @n;

SELECT @n = COUNT(*) FROM #CH WHERE IsOpen = 1 AND ReleasedAt IS NULL;
EXEC test.Assert_IsEqual @TestName = N'[ContainerHolds] open hold flagged IsOpen with NULL ReleasedAt',
    @Expected = N'1', @Actual = @n;

SELECT @n = COUNT(*) FROM #CH WHERE PlacedByName IS NULL OR HoldTypeCode IS NULL;
EXEC test.Assert_IsEqual @TestName = N'[ContainerHolds] placer name and hold type resolve on every row',
    @Expected = N'0', @Actual = @n;
GO

-- ---- Teardown (children before parents) ----
DECLARE @ContainerId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Container1');
DECLARE @SerialId    BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Serial1');
DECLARE @LotId       BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Lot1');

DELETE FROM Quality.HoldEvent    WHERE ContainerId = @ContainerId;
DELETE FROM Lots.ContainerSerial WHERE ContainerId = @ContainerId;
DELETE FROM Lots.ShippingLabel   WHERE ContainerId = @ContainerId;
DELETE FROM Lots.ContainerTray   WHERE ContainerId = @ContainerId;
DELETE FROM Lots.Container       WHERE Id          = @ContainerId;
DELETE FROM Lots.SerializedPart  WHERE Id          = @SerialId;

DELETE FROM Workorder.RejectEvent     WHERE LotId = @LotId;
DELETE FROM Workorder.ProductionEvent WHERE LotId = @LotId;
DELETE FROM Lots.LotGenealogyClosure  WHERE AncestorLotId = @LotId OR DescendantLotId = @LotId;
DELETE FROM Lots.LotGenealogy         WHERE ParentLotId = @LotId OR ChildLotId = @LotId;
DELETE FROM Lots.LotEventLog          WHERE LotId = @LotId;
DELETE FROM Lots.LotMovement          WHERE LotId = @LotId;
DELETE FROM Lots.LotStatusHistory     WHERE LotId = @LotId;
DELETE FROM Lots.Lot                  WHERE Id    = @LotId;

IF OBJECT_ID(N'tempdb..#CD') IS NOT NULL DROP TABLE #CD;
IF OBJECT_ID(N'tempdb..#CS') IS NOT NULL DROP TABLE #CS;
IF OBJECT_ID(N'tempdb..#CH') IS NOT NULL DROP TABLE #CH;
IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
GO
