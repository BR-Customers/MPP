-- =============================================
-- File:        0113_SuperLotVisibility/060_trace.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 6, Task 6 -- the five trace readers show a repacked
--              container truthfully: Lots.SerializedPart_GetTraceDetail,
--              Lots.GlobalTrace_Resolve (Serial rows), Lots.Container_GetTraceDetail,
--              Lots.Container_ListShipped, Quality.Hold_ListAssociatedContainers.
--              New columns RemovedAt (ET), RemovedReason, MovedInFromContainerName;
--              container-level reads also ReplacedSerial, ReplacedSerialVoidedAt,
--              ReworkOpenedAt, ReworkOpenedByInitials. Untouched = all NULL.
--              Fixture rows: TEST-SLT-*.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0113_SuperLotVisibility/060_trace.sql';
GO
DECLARE @TdCon TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdCon (Id) SELECT DISTINCT t.ContainerId FROM Lots.ContainerTray t JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId WHERE l.LotName LIKE N'TEST-SLT-%';
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id)
SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-SLT-%'
UNION SELECT t.FinishedGoodLotId FROM Lots.ContainerTray t WHERE t.ContainerId IN (SELECT Id FROM @TdCon) AND t.FinishedGoodLotId IS NOT NULL;
DELETE FROM Lots.ContainerSerialHistory WHERE ContainerSerialId IN (SELECT cs.Id FROM Lots.ContainerSerial cs JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId WHERE sp.SerialNumber LIKE N'TEST-SLT-SN%');
DELETE cs FROM Lots.ContainerSerial cs JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId WHERE sp.SerialNumber LIKE N'TEST-SLT-SN%';
DELETE FROM Lots.SerializedPart WHERE SerialNumber LIKE N'TEST-SLT-SN%';
DELETE FROM Workorder.ConsumptionEvent WHERE SourceLotId IN (SELECT Id FROM @TdLot) OR ProducedLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @TdLot) OR ChildLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM @TdLot) OR ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.ShippingLabel WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId LIKE N'TEST-SLT-%';
DELETE FROM Lots.ContainerRework WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
GO

DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @CfgS  BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE IsSerialized = 1 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @ItemS BIGINT = (SELECT ItemId FROM Parts.ContainerConfig WHERE Id = @CfgS);
DECLARE @Term BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId IS NOT NULL ORDER BY l.Id);
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
DECLARE @Qa   BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL AND Id NOT IN (@Line, @Term) AND ParentLocationId IS NOT NULL ORDER BY Id DESC);
DECLARE @Def  BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @DefText NVARCHAR(200) = (SELECT Description FROM Quality.DefectCode WHERE Id = @Def);
DECLARE @LabelType BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');
DECLARE @n NVARCHAR(600);
DECLARE @e NVARCHAR(600);
DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));

SET @n = CASE WHEN @App IS NOT NULL AND @CfgS IS NOT NULL AND @Term IS NOT NULL AND @Qa IS NOT NULL AND @Def IS NOT NULL AND @LabelType IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Trace] fixture: serialized config, terminal, location, defect, label type exist', @Expected = N'ok', @Actual = @n;

-- ConS1 (two serials, live label OLD), ConS2 (one serial), ConU (untouched)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
VALUES (N'TEST-SLT-S1', @ItemS, 1, 4, 2, 0, @Qa, @App, @Term, 0),
       (N'TEST-SLT-S2', @ItemS, 1, 4, 1, 0, @Qa, @App, @Term, 0),
       (N'TEST-SLT-U',  @ItemS, 1, 4, 1, 0, @Qa, @App, @Term, 0);
DECLARE @LotS1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TEST-SLT-S1');
DECLARE @LotS2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TEST-SLT-S2');
DECLARE @LotU  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TEST-SLT-U');
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotS1, @LotS1, 0), (@LotS2, @LotS2, 0), (@LotU, @LotU, 0);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId) VALUES (@ItemS, @CfgS, @Qa, 2, SYSUTCDATETIME(), @App);
DECLARE @ConS1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId) VALUES (@ItemS, @CfgS, @Qa, 2, SYSUTCDATETIME(), @App);
DECLARE @ConS2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId) VALUES (@ItemS, @CfgS, @Qa, 2, SYSUTCDATETIME(), @App);
DECLARE @ConU BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, FinishedGoodLotId, ClosedAt, ClosedByUserId) VALUES (@ConS1, 1, 2, @LotS1, SYSUTCDATETIME(), @App);
DECLARE @TrayS1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, FinishedGoodLotId, ClosedAt, ClosedByUserId) VALUES (@ConS2, 1, 1, @LotS2, SYSUTCDATETIME(), @App);
DECLARE @TrayS2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, FinishedGoodLotId, ClosedAt, ClosedByUserId) VALUES (@ConU, 1, 1, @LotU, SYSUTCDATETIME(), @App);
DECLARE @TrayU BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.SerializedPart (SerialNumber, ItemId, ProducingLotId, EtchedAt, EtchedByUserId) VALUES (N'TEST-SLT-SN1', @ItemS, @LotS1, SYSUTCDATETIME(), @App);
DECLARE @Sp1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.SerializedPart (SerialNumber, ItemId, ProducingLotId, EtchedAt, EtchedByUserId) VALUES (N'TEST-SLT-SN2', @ItemS, @LotS1, SYSUTCDATETIME(), @App);
DECLARE @Sp2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.SerializedPart (SerialNumber, ItemId, ProducingLotId, EtchedAt, EtchedByUserId) VALUES (N'TEST-SLT-SN3', @ItemS, @LotS2, SYSUTCDATETIME(), @App);
DECLARE @Sp3 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.SerializedPart (SerialNumber, ItemId, ProducingLotId, EtchedAt, EtchedByUserId) VALUES (N'TEST-SLT-SN4', @ItemS, @LotU, SYSUTCDATETIME(), @App);
DECLARE @Sp4 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerSerial (ContainerId, ContainerTrayId, SerializedPartId, TrayPosition, HardwareInterlockBypassed) VALUES (@ConS1, @TrayS1, @Sp1, 1, 0);
DECLARE @Cs1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerSerial (ContainerId, ContainerTrayId, SerializedPartId, TrayPosition, HardwareInterlockBypassed) VALUES (@ConS1, @TrayS1, @Sp2, 1, 0);
DECLARE @Cs2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerSerial (ContainerId, ContainerTrayId, SerializedPartId, TrayPosition, HardwareInterlockBypassed) VALUES (@ConS2, @TrayS2, @Sp3, 1, 0);
INSERT INTO Lots.ContainerSerial (ContainerId, ContainerTrayId, SerializedPartId, TrayPosition, HardwareInterlockBypassed) VALUES (@ConU, @TrayU, @Sp4, 1, 0);
INSERT INTO Lots.AimShipperIdPool (AimShipperId, ConsumedAt, ConsumedByContainerId, ConsumedByUserId, Quantity, LotNumber, PostedAt)
VALUES (N'TEST-SLT-OLD', SYSUTCDATETIME(), @ConS1, @App, 2, N'TEST-SLT-S1', SYSUTCDATETIME()),
       (N'TEST-SLT-U',   SYSUTCDATETIME(), @ConU,  @App, 1, N'TEST-SLT-U',  SYSUTCDATETIME());
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, IsVoid) VALUES (@ConS1, N'TEST-SLT-OLD', @LabelType, 1, 0), (@ConU, N'TEST-SLT-U', @LabelType, 1, 0);

-- drive the repack: open both, scrap SN1 by serial, move SN2 into ConS2, re-complete ConS1 with a NEW serial
INSERT INTO @o EXEC Lots.ContainerRework_Open @ContainerId = @ConS1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Trace] fixture: ConS1 opened for rework', @Expected = N'1', @Actual = @n;
DELETE FROM @o; INSERT INTO @o EXEC Lots.ContainerRework_Open @ContainerId = @ConS2, @AppUserId = @App;
INSERT INTO @s EXEC Lots.ContainerRework_SetStage @ContainerId = @ConS2, @StageCode = N'Filling', @AppUserId = @App;
DELETE FROM @o; INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayS1, @DefectCodeId = @Def, @Quantity = 1, @ContainerSerialId = @Cs1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Trace] fixture: SN1 scrapped by serial', @Expected = N'1', @Actual = @n;
DELETE FROM @o; INSERT INTO @o EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @TrayS1, @ToContainerId = @ConS2, @Quantity = 1, @ContainerSerialId = @Cs2, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Trace] fixture: SN2 moved into ConS2', @Expected = N'1', @Actual = @n;
-- re-completion (simulated): the NEW serial with its live label; containers Complete again
INSERT INTO Lots.AimShipperIdPool (AimShipperId, ConsumedAt, ConsumedByContainerId, ConsumedByUserId, Quantity, LotNumber, PostedAt)
VALUES (N'TEST-SLT-NEW', SYSUTCDATETIME(), @ConS1, @App, 0, N'TEST-SLT-S1', NULL);
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, IsVoid) VALUES (@ConS1, N'TEST-SLT-NEW', @LabelType, 1, 0);
UPDATE Lots.Container SET ContainerStatusCodeId = 2, CompletedAt = SYSUTCDATETIME() WHERE Id IN (@ConS1, @ConS2);

-- ===== 1. SerializedPart_GetTraceDetail =====
DECLARE @SD TABLE (SerialNumber NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(100), ProducingLotId BIGINT, ProducingLotName NVARCHAR(50),
    EtchedAt DATETIME2(3), ProducedAt DATETIME2(3), OperatorName NVARCHAR(200), MachineName NVARCHAR(200), ContainerId BIGINT,
    ContainerStatusCode NVARCHAR(50), AimShipperId NVARCHAR(50), CompletedAt DATETIME2(3),
    RemovedAt DATETIME2(3), RemovedReason NVARCHAR(100), MovedInFromContainerName NVARCHAR(50));
INSERT INTO @SD EXEC Lots.SerializedPart_GetTraceDetail @SerialNumber = N'TEST-SLT-SN1';
SET @n = (SELECT CASE WHEN RemovedAt IS NOT NULL THEN N'at' ELSE N'null' END + N'|' + ISNULL(RemovedReason, N'null') + N'|' + ISNULL(MovedInFromContainerName, N'null') FROM @SD);
SET @e = N'at|Scrapped (' + @DefText + N')|null';
EXEC test.Assert_IsEqual @TestName = N'[Serial detail] the scrapped serial stays, with RemovedAt and Scrapped (defect)', @Expected = @e, @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(MAX(ContainerId) AS NVARCHAR(20)) FROM @SD);
SET @e = N'1|' + CAST(@ConS1 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Serial detail] the scrapped serial is still listed against the container it was packed in', @Expected = @e, @Actual = @n;
DELETE FROM @SD; INSERT INTO @SD EXEC Lots.SerializedPart_GetTraceDetail @SerialNumber = N'TEST-SLT-SN2';
SET @n = (SELECT CASE WHEN RemovedAt IS NULL THEN N'null' ELSE N'at' END + N'|' + ISNULL(RemovedReason, N'null') + N'|' + ISNULL(MovedInFromContainerName, N'null') + N'|' + CAST(ContainerId AS NVARCHAR(20)) FROM @SD);
SET @e = N'null|null|' + CAST(@ConS1 AS NVARCHAR(20)) + N'|' + CAST(@ConS2 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Serial detail] the moved-in serial is packed (no RemovedAt) and names its source container', @Expected = @e, @Actual = @n;
DELETE FROM @SD; INSERT INTO @SD EXEC Lots.SerializedPart_GetTraceDetail @SerialNumber = N'TEST-SLT-SN4';
SET @n = (SELECT CASE WHEN RemovedAt IS NULL AND RemovedReason IS NULL AND MovedInFromContainerName IS NULL THEN N'allnull' ELSE N'set' END FROM @SD);
EXEC test.Assert_IsEqual @TestName = N'[Serial detail] an untouched serial returns NULL in every new column', @Expected = N'allnull', @Actual = @n;

-- ===== 2. GlobalTrace_Resolve =====
DECLARE @GR TABLE (MatchType NVARCHAR(20), MatchedEntityId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), Detail NVARCHAR(200),
    RemovedAt DATETIME2(3), RemovedReason NVARCHAR(100), MovedInFromContainerName NVARCHAR(50));
INSERT INTO @GR EXEC Lots.GlobalTrace_Resolve @SearchText = N'TEST-SLT-SN1';
SET @n = (SELECT MatchType + N'|' + CASE WHEN RemovedAt IS NOT NULL THEN N'at' ELSE N'null' END + N'|' + ISNULL(RemovedReason, N'null') + N'|' + ISNULL(MovedInFromContainerName, N'null') FROM @GR);
SET @e = N'Serial|at|Scrapped (' + @DefText + N')|null';
EXEC test.Assert_IsEqual @TestName = N'[Global trace] a serial match for the scrapped serial is marked scrapped', @Expected = @e, @Actual = @n;
DELETE FROM @GR; INSERT INTO @GR EXEC Lots.GlobalTrace_Resolve @SearchText = N'TEST-SLT-SN2';
SET @n = (SELECT MatchType + N'|' + ISNULL(RemovedReason, N'null') + N'|' + ISNULL(MovedInFromContainerName, N'null') FROM @GR);
SET @e = N'Serial|null|' + CAST(@ConS1 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Global trace] the moved-in serial names its source container', @Expected = @e, @Actual = @n;
DELETE FROM @GR; INSERT INTO @GR EXEC Lots.GlobalTrace_Resolve @SearchText = N'TEST-SLT-SN4';
SET @n = (SELECT CASE WHEN RemovedAt IS NULL AND RemovedReason IS NULL AND MovedInFromContainerName IS NULL THEN N'allnull' ELSE N'set' END FROM @GR);
EXEC test.Assert_IsEqual @TestName = N'[Global trace] an untouched serial returns NULL in every new column', @Expected = N'allnull', @Actual = @n;
DELETE FROM @GR; SET @e = CAST(@ConS1 AS NVARCHAR(20)); INSERT INTO @GR EXEC Lots.GlobalTrace_Resolve @SearchText = @e;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(SUM(CASE WHEN RemovedAt IS NOT NULL OR RemovedReason IS NOT NULL OR MovedInFromContainerName IS NOT NULL THEN 1 ELSE 0 END) AS NVARCHAR(5)) FROM @GR WHERE MatchType = N'Container');
EXEC test.Assert_IsEqual @TestName = N'[Global trace] a container match lists its source LOTs as before; serial columns stay NULL on LOT rows', @Expected = N'1|0', @Actual = @n;

-- ===== 3. Container_GetTraceDetail =====
DECLARE @CD TABLE (ContainerId BIGINT, ItemId BIGINT, ItemPartNumber NVARCHAR(100), ContainerStatusCode NVARCHAR(50), PieceCount INT, SerialCount INT,
    SourceLotCount INT, OpenedAt DATETIME2(3), CompletedAt DATETIME2(3), AimShipperId NVARCHAR(50), OpenHoldCount INT, TotalHoldCount INT,
    RemovedAt DATETIME2(3), RemovedReason NVARCHAR(100), MovedInFromContainerName NVARCHAR(50),
    ReplacedSerial NVARCHAR(50), ReplacedSerialVoidedAt DATETIME2(3), ReworkOpenedAt DATETIME2(3), ReworkOpenedByInitials NVARCHAR(20));
INSERT INTO @CD EXEC Lots.Container_GetTraceDetail @ContainerId = @ConS1;
SET @n = (SELECT AimShipperId + N'|' + ReplacedSerial + N'|' + CASE WHEN ReplacedSerialVoidedAt IS NOT NULL AND ReworkOpenedAt IS NOT NULL THEN N'dated' ELSE N'nodate' END + N'|' + ReworkOpenedByInitials FROM @CD);
EXEC test.Assert_IsEqual @TestName = N'[Container detail] header carries the new serial, the replaced (voided) one, when, and who opened the rework', @Expected = N'TEST-SLT-NEW|TEST-SLT-OLD|dated|SYS', @Actual = @n;
SET @n = (SELECT CASE WHEN RemovedAt IS NOT NULL THEN N'at' ELSE N'null' END + N'|' + ISNULL(RemovedReason, N'null') FROM @CD);
SET @e = N'at|Scrapped (' + @DefText + N')';
EXEC test.Assert_IsEqual @TestName = N'[Container detail] header shows the scrapped serial (scrap outranks a move-out)', @Expected = @e, @Actual = @n;
DELETE FROM @CD; INSERT INTO @CD EXEC Lots.Container_GetTraceDetail @ContainerId = @ConS2;
SET @n = (SELECT ISNULL(MovedInFromContainerName, N'null') + N'|' + ISNULL(RemovedReason, N'null') FROM @CD);
SET @e = CAST(@ConS1 AS NVARCHAR(20)) + N'|null';
EXEC test.Assert_IsEqual @TestName = N'[Container detail] the receiving container names the container a serial came from', @Expected = @e, @Actual = @n;
DELETE FROM @CD; INSERT INTO @CD EXEC Lots.Container_GetTraceDetail @ContainerId = @ConU;
SET @n = (SELECT CASE WHEN RemovedAt IS NULL AND RemovedReason IS NULL AND MovedInFromContainerName IS NULL AND ReplacedSerial IS NULL
                       AND ReplacedSerialVoidedAt IS NULL AND ReworkOpenedAt IS NULL AND ReworkOpenedByInitials IS NULL THEN N'allnull' ELSE N'set' END FROM @CD);
EXEC test.Assert_IsEqual @TestName = N'[Container detail] an untouched container returns NULL in every new column', @Expected = N'allnull', @Actual = @n;

-- ===== 4. Container_ListShipped =====
DECLARE @LS TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(100), AimShipperId NVARCHAR(50), PieceCount INT, SourceLotCount INT,
    OpenedAt DATETIME2(3), CompletedAt DATETIME2(3), CurrentLocationName NVARCHAR(200),
    RemovedAt DATETIME2(3), RemovedReason NVARCHAR(100), MovedInFromContainerName NVARCHAR(50),
    ReplacedSerial NVARCHAR(50), ReplacedSerialVoidedAt DATETIME2(3), ReworkOpenedAt DATETIME2(3), ReworkOpenedByInitials NVARCHAR(20));
INSERT INTO @LS EXEC Lots.Container_ListShipped;
SET @n = (SELECT ISNULL(AimShipperId, N'null') + N'|' + ISNULL(ReplacedSerial, N'null') + N'|' + ISNULL(RemovedReason, N'null') FROM @LS WHERE ContainerId = @ConS1);
SET @e = N'TEST-SLT-NEW|TEST-SLT-OLD|Scrapped (' + @DefText + N')';
EXEC test.Assert_IsEqual @TestName = N'[Shipped list] the repacked container shows its new serial, the replaced one and the scrapped serial', @Expected = @e, @Actual = @n;
SET @n = (SELECT ISNULL(MovedInFromContainerName, N'null') FROM @LS WHERE ContainerId = @ConS2);
SET @e = CAST(@ConS1 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Shipped list] the receiving container names its source', @Expected = @e, @Actual = @n;
SET @n = (SELECT CASE WHEN RemovedAt IS NULL AND RemovedReason IS NULL AND MovedInFromContainerName IS NULL AND ReplacedSerial IS NULL
                       AND ReplacedSerialVoidedAt IS NULL AND ReworkOpenedAt IS NULL AND ReworkOpenedByInitials IS NULL THEN N'allnull' ELSE N'set' END FROM @LS WHERE ContainerId = @ConU);
EXEC test.Assert_IsEqual @TestName = N'[Shipped list] an untouched container returns NULL in every new column', @Expected = N'allnull', @Actual = @n;

-- ===== 5. Hold_ListAssociatedContainers =====
DECLARE @HA TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(200), CurrentLocationName NVARCHAR(200), ContainerStatusCode NVARCHAR(50), AssociationKind NVARCHAR(30),
    RemovedAt DATETIME2(3), RemovedReason NVARCHAR(100), MovedInFromContainerName NVARCHAR(50));
INSERT INTO @HA EXEC Quality.Hold_ListAssociatedContainers @LotId = @LotS1;
SET @n = (SELECT ISNULL(RemovedReason, N'null') FROM @HA WHERE ContainerId = @ConS1);
SET @e = N'Scrapped (' + @DefText + N')';
EXEC test.Assert_IsEqual @TestName = N'[Hold containers] the container of the held LOT scrapped serial is listed, marked scrapped', @Expected = @e, @Actual = @n;
SET @n = (SELECT ISNULL(MovedInFromContainerName, N'null') FROM @HA WHERE ContainerId = @ConS2);
SET @e = CAST(@ConS1 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Hold containers] the container a held LOT serial moved into names its source', @Expected = @e, @Actual = @n;
DELETE FROM @HA; INSERT INTO @HA EXEC Quality.Hold_ListAssociatedContainers @LotId = @LotU;
SET @n = (SELECT CASE WHEN RemovedAt IS NULL AND RemovedReason IS NULL AND MovedInFromContainerName IS NULL THEN N'allnull' ELSE N'set' END FROM @HA WHERE ContainerId = @ConU);
EXEC test.Assert_IsEqual @TestName = N'[Hold containers] an untouched LOT container returns NULL in every new column', @Expected = N'allnull', @Actual = @n;
GO
DECLARE @TdCon TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdCon (Id) SELECT DISTINCT t.ContainerId FROM Lots.ContainerTray t JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId WHERE l.LotName LIKE N'TEST-SLT-%';
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id)
SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-SLT-%'
UNION SELECT t.FinishedGoodLotId FROM Lots.ContainerTray t WHERE t.ContainerId IN (SELECT Id FROM @TdCon) AND t.FinishedGoodLotId IS NOT NULL;
DELETE FROM Lots.ContainerSerialHistory WHERE ContainerSerialId IN (SELECT cs.Id FROM Lots.ContainerSerial cs JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId WHERE sp.SerialNumber LIKE N'TEST-SLT-SN%');
DELETE cs FROM Lots.ContainerSerial cs JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId WHERE sp.SerialNumber LIKE N'TEST-SLT-SN%';
DELETE FROM Lots.SerializedPart WHERE SerialNumber LIKE N'TEST-SLT-SN%';
DELETE FROM Workorder.ConsumptionEvent WHERE SourceLotId IN (SELECT Id FROM @TdLot) OR ProducedLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @TdLot) OR ChildLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM @TdLot) OR ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.ShippingLabel WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId LIKE N'TEST-SLT-%';
DELETE FROM Lots.ContainerRework WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
GO
EXEC test.EndTestFile;
GO
