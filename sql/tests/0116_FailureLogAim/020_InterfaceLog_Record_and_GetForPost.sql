-- =============================================
-- File: 0116_FailureLogAim/020_InterfaceLog_Record_and_GetForPost.sql
-- Desc: Audit.InterfaceLog_Record returns the new Id; GetForPost v1.3 returns
--       LocationId (container cell) + LotId (LOT named by the frozen LotNumber).
-- =============================================
EXEC test.BeginTestFile @FileName = N'0116_FailureLogAim/020_InterfaceLog_Record_and_GetForPost.sql';
GO

-- ---- InterfaceLog_Record ----
DECLARE @Loc BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Audit.InterfaceLog_Record
    @SystemName = N'AIM', @Direction = N'Outbound', @LogEventTypeCode = N'LabelDispatched',
    @Description = N'Test0116 AIM postserial', @RequestPayload = N'http://x/mes/floor/99/<token>/postserial.csv',
    @ErrorCondition = N'AimCallFailed', @ErrorDescription = N'HTTP 500', @IsHighFidelity = 1,
    @LocationId = @Loc;
DECLARE @S NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R);
DECLARE @NewId BIGINT = (SELECT NewId FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[0116] InterfaceLog_Record returns Status 1',
    @Expected = N'1', @Actual = @S;
DECLARE @Found NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.InterfaceLog
                               WHERE Id = @NewId AND Description = N'Test0116 AIM postserial' AND LocationId = @Loc);
EXEC test.Assert_IsEqual @TestName = N'[0116] InterfaceLog_Record NewId is the row it wrote, with LocationId',
    @Expected = N'1', @Actual = @Found;

DELETE FROM @R;
INSERT INTO @R EXEC Audit.InterfaceLog_Record
    @SystemName = N'AIM', @Direction = N'Outbound', @LogEventTypeCode = N'LabelDispatched', @Description = NULL;
DECLARE @S2 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[0116] InterfaceLog_Record refuses a missing Description',
    @Expected = N'0', @Actual = @S2;

-- The silent writer still emits nothing (LotLabel_RecordDispatch depends on it).
DECLARE @Capture TABLE (AnyCol SQL_VARIANT);
INSERT INTO @Capture EXEC Audit.Audit_LogInterfaceCall
    @SystemName = N'AIM', @Direction = N'Outbound', @LogEventTypeCode = N'LabelDispatched',
    @Description = N'Test0116 silent';
DECLARE @Emitted NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Capture);
EXEC test.Assert_IsEqual @TestName = N'[0116] Audit_LogInterfaceCall still emits no result set',
    @Expected = N'0', @Actual = @Emitted;
GO

-- ---- GetForPost context columns ----
-- Fixture: own part + container + LOT; pool rows keyed 0116xxxxx.
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId LIKE N'0116%';
DELETE FROM Lots.Lot WHERE LotName = N'FL116-POSTLOT';
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'FL116-PART')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'FL116-PART', N'0116 FailureLog fixture part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'FL116-PART');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Item, 1, 15, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open
    @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @ContainerId BIGINT = (SELECT NewId FROM @O);

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'FL116-POSTLOT', @Item, (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received'), 1, 15, @Cell, 1);
DECLARE @LotId BIGINT = SCOPE_IDENTITY();

INSERT INTO Lots.AimShipperIdPool
    (AimShipperId, FetchedAt, ConsumedAt, ConsumedByContainerId, ConsumedByUserId, CustomerPartNumber, Quantity, LotNumber)
VALUES
    (N'011600001', @Now, @Now, @ContainerId, 1, N'FL116', 15, N'FL116-POSTLOT'),   -- names a real LOT
    (N'011600002', @Now, @Now, @ContainerId, 1, N'FL116', 15, N'FL116-NO-SUCH'),   -- names no LOT
    (N'011600003', @Now, NULL, NULL,         NULL, NULL,  NULL, NULL);             -- unconsumed, no container

DECLARE @G TABLE (Id BIGINT, AimShipperId NVARCHAR(50), CustomerPartNumber NVARCHAR(50),
                  Quantity INT, LotNumber NVARCHAR(50), PostedAt DATETIME2(3), VoidedAt DATETIME2(3), PostAttempts INT,
                  ContainerId BIGINT, ItemPartNumber NVARCHAR(50), LocationId BIGINT, LotId BIGINT);

INSERT INTO @G EXEC Lots.AimShipperIdPool_GetForPost @AimShipperId = N'011600001';
DECLARE @GLot NVARCHAR(20) = (SELECT CAST(LotId AS NVARCHAR(20)) FROM @G);
DECLARE @ELot NVARCHAR(20) = CAST(@LotId AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0116] GetForPost LotId = the LOT named by LotNumber',
    @Expected = @ELot, @Actual = @GLot;
DECLARE @GLoc NVARCHAR(20) = (SELECT CAST(LocationId AS NVARCHAR(20)) FROM @G);
DECLARE @ELoc NVARCHAR(20) = CAST(@Cell AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0116] GetForPost LocationId = the container cell',
    @Expected = @ELoc, @Actual = @GLoc;

DELETE FROM @G;
INSERT INTO @G EXEC Lots.AimShipperIdPool_GetForPost @AimShipperId = N'011600002';
DECLARE @GLot2 NVARCHAR(20) = (SELECT CAST(LotId AS NVARCHAR(20)) FROM @G);
EXEC test.Assert_IsNull @TestName = N'[0116] GetForPost LotId NULL when LotNumber names no LOT', @Value = @GLot2;
DECLARE @Rows2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[0116] GetForPost still returns the row when LotNumber names no LOT',
    @Expected = N'1', @Actual = @Rows2;

DELETE FROM @G;
INSERT INTO @G EXEC Lots.AimShipperIdPool_GetForPost @AimShipperId = N'011600003';
DECLARE @GLoc3 NVARCHAR(20) = (SELECT CAST(LocationId AS NVARCHAR(20)) FROM @G);
EXEC test.Assert_IsNull @TestName = N'[0116] GetForPost LocationId NULL with no container', @Value = @GLoc3;
GO

-- Cleanup.
DELETE FROM Audit.InterfaceLog WHERE Description LIKE N'Test0116%';
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId LIKE N'0116%';
DELETE FROM Lots.Lot WHERE LotName = N'FL116-POSTLOT';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'FL116-PART');
GO
