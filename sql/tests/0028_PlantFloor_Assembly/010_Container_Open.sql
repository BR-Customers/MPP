-- =============================================
-- File:         0028_PlantFloor_Assembly/010_Container_Open.sql
-- Description:  Lots.Container_Open (Arc 2 Phase 6). Opens a container at a cell:
--               Status=1 + NewId; ContainerStatusCodeId defaults to Open (1);
--               ContainerOpened audit in Audit.OperationLog; invalid config rejects.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/010_Container_Open.sql';
GO

-- ---- cleanup (transient containers only; Item/Config are persistent fixtures) ----
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-ASM-TEST', N'Phase6 assembly test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Item, 4, 25, 1, N'ByVision', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

-- happy path
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @O);
DECLARE @Cid BIGINT = (SELECT NewId FROM @O);
DECLARE @CidStr NVARCHAR(20) = CAST(@Cid AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Open] Status is 1', @Expected = N'1', @Actual = @S;
EXEC test.Assert_IsNotNull @TestName = N'[Open] NewId returned', @Value = @CidStr;

DECLARE @StatusCode NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[Open] container status defaults to Open (1)', @Expected = N'1', @Actual = @StatusCode;

DECLARE @LocOk NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Cid AND CurrentLocationId = @Cell AND ItemId = @Item);
EXEC test.Assert_IsEqual @TestName = N'[Open] container at the cell with the item', @Expected = N'1', @Actual = @LocOk;

DECLARE @Aud NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId WHERE et.Code = N'ContainerOpened' AND ol.EntityId = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[Open] ContainerOpened audit in OperationLog', @Expected = N'1', @Actual = @Aud;

-- invalid config rejects
DECLARE @O2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O2 EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = 0, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @O2);
EXEC test.Assert_IsEqual @TestName = N'[Open] invalid config rejects (Status 0)', @Expected = N'0', @Actual = @S2;
GO

DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASM-TEST');
GO

EXEC test.EndTestFile;
GO
