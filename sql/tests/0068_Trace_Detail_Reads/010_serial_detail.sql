-- =============================================
-- File:         0068_Trace_Detail_Reads/010_serial_detail.sql
-- Author:       Blue Ridge Automation
-- Description:  FDS-12-002 serial trace payload.
--
--               The reset database has no SerializedParts, so this builds the
--               whole chain: LOT -> ProductionEvent (for ProducedAt / operator /
--               machine) -> minted serial -> container -> ContainerSerial link.
--               Without the container leg the proc's LEFT JOIN arm would never
--               be exercised and a broken join would pass unnoticed.
--
--               CompletedAt is container CLOSE time, NOT a ship time -- the
--               schema has no ship timestamp (design spec 2.5).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0068_Trace_Detail_Reads/010_serial_detail.sql';
GO

IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
CREATE TABLE #SF (Tag NVARCHAR(30) PRIMARY KEY, Val BIGINT);
IF OBJECT_ID(N'tempdb..#SN') IS NOT NULL DROP TABLE #SN;
CREATE TABLE #SN (Tag NVARCHAR(30) PRIMARY KEY, Val NVARCHAR(100));

IF OBJECT_ID(N'tempdb..#SD') IS NOT NULL DROP TABLE #SD;
CREATE TABLE #SD (
    SerialNumber NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(100),
    ProducingLotId BIGINT, ProducingLotName NVARCHAR(50),
    EtchedAt DATETIME2(3), ProducedAt DATETIME2(3),
    OperatorName NVARCHAR(200), MachineName NVARCHAR(200),
    ContainerId BIGINT, ContainerStatusCode NVARCHAR(50),
    AimShipperId NVARCHAR(50), CompletedAt DATETIME2(3)
);
GO

-- ---- Fixture ----
DECLARE @ItemId BIGINT, @CellA BIGINT, @LotId BIGINT, @SerialId BIGINT, @ContainerId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @UserId    BIGINT = (SELECT MIN(Id) FROM Location.AppUser);
DECLARE @TemplateId BIGINT = (SELECT MIN(Id) FROM Parts.OperationTemplate);
DECLARE @ConfigId  BIGINT;

SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT ItemId FROM Parts.ContainerConfig WHERE DeprecatedAt IS NULL)
ORDER BY eil.LocationId;

-- Fall back to any eligible item if none of them has a container config.
IF @ItemId IS NULL
    SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
    FROM Parts.v_EffectiveItemLocation eil ORDER BY eil.LocationId;

SELECT TOP 1 @ConfigId = Id FROM Parts.ContainerConfig
WHERE ItemId = @ItemId AND DeprecatedAt IS NULL;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 10, @AppUserId = @UserId,
    @VendorLotNumber = N'VND-SER-001';
SELECT @LotId = NewId FROM @cr;
INSERT INTO #SF (Tag, Val) VALUES (N'Lot1', @LotId);

-- Production event supplies ProducedAt / OperatorName / MachineName.
-- INSERTed directly, NOT via Workorder.ProductionEvent_Record: that proc
-- validates the template against the LOT's route and, on rejection, ROLLBACKs
-- inside its CATCH -- which raises Msg 3915 when the caller captured it with
-- INSERT-EXEC. This fixture needs the ROW, not the proc's business rules.
INSERT INTO Workorder.ProductionEvent
    (LotId, OperationTemplateId, EventAt, AppUserId, TerminalLocationId)
VALUES (@LotId, @TemplateId, SYSUTCDATETIME(), @UserId, @CellA);

-- Minted serial.
DECLARE @sm TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO @sm EXEC Lots.SerializedPart_Mint @ItemId = @ItemId, @ProducingLotId = @LotId,
    @AppUserId = @UserId, @TerminalLocationId = @CellA;
SELECT @SerialId = NewId FROM @sm;
INSERT INTO #SF (Tag, Val) VALUES (N'Serial1', @SerialId);
INSERT INTO #SN (Tag, Val) SELECT N'SerialNumber', SerialNumber FROM Lots.SerializedPart WHERE Id = @SerialId;

-- Container + link (only when the item carries a container config).
IF @ConfigId IS NOT NULL
BEGIN
    DECLARE @co TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO @co EXEC Lots.Container_Open @ItemId = @ItemId, @ContainerConfigId = @ConfigId,
        @CellLocationId = @CellA, @AppUserId = @UserId;
    SELECT @ContainerId = NewId FROM @co;

    IF @ContainerId IS NOT NULL
    BEGIN
        INSERT INTO #SF (Tag, Val) VALUES (N'Container1', @ContainerId);
        DECLARE @cs TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
        INSERT INTO @cs EXEC Lots.ContainerSerial_Add @ContainerId = @ContainerId,
            @SerializedPartId = @SerialId, @TrayPosition = 1, @AppUserId = @UserId;
    END
END
GO

-- ---- Assertions ----
DECLARE @n INT, @s NVARCHAR(100);
DECLARE @Serial NVARCHAR(50) = (SELECT Val FROM #SN WHERE Tag = N'SerialNumber');
DECLARE @LotId  BIGINT       = (SELECT Val FROM #SF WHERE Tag = N'Lot1');
DECLARE @ContainerId BIGINT  = (SELECT Val FROM #SF WHERE Tag = N'Container1');

-- 1. Unknown serial returns an empty set (FDS-11-011: no invented 404).
INSERT INTO #SD EXEC Lots.SerializedPart_GetTraceDetail @SerialNumber = N'NO-SUCH-SERIAL-ZZZ';
SELECT @n = COUNT(*) FROM #SD;
EXEC test.Assert_IsEqual @TestName = N'[SerialDetail] unknown serial returns empty set',
    @Expected = N'0', @Actual = @n;
DELETE FROM #SD;

-- 2. The fixture serial returns exactly one row.
INSERT INTO #SD EXEC Lots.SerializedPart_GetTraceDetail @SerialNumber = @Serial;
SELECT @n = COUNT(*) FROM #SD;
EXEC test.Assert_IsEqual @TestName = N'[SerialDetail] known serial returns exactly one row',
    @Expected = N'1', @Actual = @n;

-- 3. Identity columns resolve.
SELECT @n = COUNT(*) FROM #SD
WHERE ProducingLotId = @LotId AND ItemPartNumber IS NOT NULL
  AND ProducingLotName IS NOT NULL AND EtchedAt IS NOT NULL;
EXEC test.Assert_IsEqual @TestName = N'[SerialDetail] item, producing LOT and EtchedAt populated',
    @Expected = N'1', @Actual = @n;

-- 4. The ProductionEvent arm supplies ProducedAt / operator / machine.
SELECT @n = COUNT(*) FROM #SD
WHERE ProducedAt IS NOT NULL AND OperatorName IS NOT NULL AND MachineName IS NOT NULL;
EXEC test.Assert_IsEqual @TestName = N'[SerialDetail] ProducedAt, OperatorName and MachineName populated',
    @Expected = N'1', @Actual = @n;

-- 5. The container arm resolves through ContainerSerial (skipped if the item
--    had no container config -- recorded either way, never silently passed).
IF @ContainerId IS NULL
BEGIN
    EXEC test.Assert_IsEqual @TestName = N'[SerialDetail] container leg SKIPPED -- item has no ContainerConfig',
        @Expected = N'1', @Actual = N'1';
END
ELSE
BEGIN
    SELECT @n = COUNT(*) FROM #SD WHERE ContainerId = @ContainerId AND ContainerStatusCode IS NOT NULL;
    EXEC test.Assert_IsEqual @TestName = N'[SerialDetail] linked container and its status resolve',
        @Expected = N'1', @Actual = @n;
END
GO

-- ---- Teardown (children before parents) ----
DECLARE @LotId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Lot1');
DECLARE @SerialId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Serial1');
DECLARE @ContainerId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Container1');

DELETE FROM Lots.ContainerSerial WHERE SerializedPartId = @SerialId;
IF @ContainerId IS NOT NULL
BEGIN
    DELETE FROM Lots.ShippingLabel WHERE ContainerId = @ContainerId;
    DELETE FROM Lots.ContainerTray WHERE ContainerId = @ContainerId;
    DELETE FROM Lots.Container     WHERE Id          = @ContainerId;
END
DELETE FROM Lots.SerializedPart WHERE Id = @SerialId;

DELETE FROM Workorder.RejectEvent     WHERE LotId = @LotId;
DELETE FROM Workorder.ProductionEvent WHERE LotId = @LotId;
DELETE FROM Lots.LotGenealogyClosure  WHERE AncestorLotId = @LotId OR DescendantLotId = @LotId;
DELETE FROM Lots.LotGenealogy         WHERE ParentLotId = @LotId OR ChildLotId = @LotId;
DELETE FROM Lots.LotEventLog          WHERE LotId = @LotId;
DELETE FROM Lots.LotMovement          WHERE LotId = @LotId;
DELETE FROM Lots.LotStatusHistory     WHERE LotId = @LotId;
DELETE FROM Lots.Lot                  WHERE Id    = @LotId;

IF OBJECT_ID(N'tempdb..#SD') IS NOT NULL DROP TABLE #SD;
IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
IF OBJECT_ID(N'tempdb..#SN') IS NOT NULL DROP TABLE #SN;
GO
