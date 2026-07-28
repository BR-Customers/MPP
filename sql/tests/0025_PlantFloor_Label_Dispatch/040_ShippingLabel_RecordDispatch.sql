-- =============================================
-- File:         0025_PlantFloor_Label_Dispatch/040_ShippingLabel_RecordDispatch.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-28
-- Description:  Lots.ShippingLabel_RecordDispatch write-back.
--               Asserts:
--                 * success -> PrintedAt set, LastPrintError cleared
--                 * failure -> PrintAttempts incremented, LastPrintError stored,
--                              PrintFailedAt still NULL below the attempt cap
--                 * failure at the cap -> PrintFailedAt set
--                 * unknown ShippingLabelId -> Status = 0
--
--               Fixture is SELF-CONTAINED: Run-Tests.ps1 resets with -SkipDemoSeed, so
--               Lots.Container is EMPTY -- never reuse "TOP 1 existing container". Opens
--               its own container via Lots.Container_Open (house pattern, cf.
--               0028_PlantFloor_Assembly/040) and inserts BOTH ShippingLabel rows up
--               front, so later batches look labels up by AimShipperId and never need
--               the container id again.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0025_PlantFloor_Label_Dispatch/040_ShippingLabel_RecordDispatch.sql';
GO

DELETE FROM Lots.ShippingLabel WHERE AimShipperId LIKE N'TESTRD%';
GO

-- ---- self-contained container fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'RD-SHIP-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'RD-SHIP-TEST', N'RecordDispatch test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'RD-SHIP-TEST');

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Item, 4, 25, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open
    @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @ContainerId BIGINT = (SELECT NewId FROM @O);

DECLARE @LabelType BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');

-- Both labels created up front: later batches resolve them by AimShipperId.
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintedByUserId)
VALUES (@ContainerId, N'TESTRD0001', @LabelType, 1, 1),
       (@ContainerId, N'TESTRD0002', @LabelType, 1, 1);
GO

-- =============================================
-- Test 1: success sets PrintedAt and clears the error
-- =============================================
DECLARE @Id BIGINT = (SELECT Id FROM Lots.ShippingLabel WHERE AimShipperId = N'TESTRD0001');
DECLARE @Status BIT, @PrintedAt DATETIME2(3), @Err NVARCHAR(500);
CREATE TABLE #S1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #S1 EXEC Lots.ShippingLabel_RecordDispatch @ShippingLabelId = @Id, @Success = 1;
SELECT @Status = Status FROM #S1; DROP TABLE #S1;
SELECT @PrintedAt = PrintedAt, @Err = LastPrintError FROM Lots.ShippingLabel WHERE Id = @Id;
EXEC test.Assert_IsTrue   @TestName = N'[ShipDispatch] success returns Status=1', @Condition = @Status;
EXEC test.Assert_IsNotNull @TestName = N'[ShipDispatch] success sets PrintedAt',  @Value = @PrintedAt;
EXEC test.Assert_IsNull   @TestName = N'[ShipDispatch] success clears LastPrintError', @Value = @Err;
GO

-- =============================================
-- Test 2: failure increments attempts, stores the error, no PrintFailedAt yet
-- =============================================
DECLARE @Id BIGINT = (SELECT Id FROM Lots.ShippingLabel WHERE AimShipperId = N'TESTRD0002');
DECLARE @Attempts INT, @Err NVARCHAR(500), @FailedAt DATETIME2(3);
CREATE TABLE #S2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #S2 EXEC Lots.ShippingLabel_RecordDispatch
    @ShippingLabelId = @Id, @Success = 0, @ErrorText = N'connection refused';
DROP TABLE #S2;
SELECT @Attempts = PrintAttempts, @Err = LastPrintError, @FailedAt = PrintFailedAt
FROM Lots.ShippingLabel WHERE Id = @Id;
EXEC test.Assert_IsEqual @TestName = N'[ShipDispatch] failure increments PrintAttempts to 1',
    @Expected = N'1', @Actual = @Attempts;
EXEC test.Assert_IsEqual @TestName = N'[ShipDispatch] failure stores LastPrintError',
    @Expected = N'connection refused', @Actual = @Err;
EXEC test.Assert_IsNull @TestName = N'[ShipDispatch] below cap leaves PrintFailedAt NULL',
    @Value = @FailedAt;
GO

-- =============================================
-- Test 3: failure at the attempt cap sets PrintFailedAt
-- =============================================
DECLARE @Id BIGINT = (SELECT Id FROM Lots.ShippingLabel WHERE AimShipperId = N'TESTRD0002');
DECLARE @FailedAt DATETIME2(3);
CREATE TABLE #S3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #S3 EXEC Lots.ShippingLabel_RecordDispatch
    @ShippingLabelId = @Id, @Success = 0, @ErrorText = N'connection refused';
INSERT INTO #S3 EXEC Lots.ShippingLabel_RecordDispatch
    @ShippingLabelId = @Id, @Success = 0, @ErrorText = N'connection refused';
DROP TABLE #S3;
SELECT @FailedAt = PrintFailedAt FROM Lots.ShippingLabel WHERE Id = @Id;
EXEC test.Assert_IsNotNull @TestName = N'[ShipDispatch] third failure sets PrintFailedAt',
    @Value = @FailedAt;
GO

-- =============================================
-- Test 4: unknown id -> Status = 0
-- =============================================
DECLARE @Status BIT;
CREATE TABLE #S4 (Status BIT, Message NVARCHAR(500));
INSERT INTO #S4 EXEC Lots.ShippingLabel_RecordDispatch @ShippingLabelId = -1, @Success = 1;
SELECT @Status = Status FROM #S4; DROP TABLE #S4;
EXEC test.Assert_IsEqual @TestName = N'[ShipDispatch] unknown id -> Status=0',
    @Expected = N'0', @Actual = @Status;
GO

-- ---- teardown: labels first, then the containers they referenced, so a re-run
-- ---- does not accumulate a fresh Container_Open row every time.
DELETE FROM Lots.ShippingLabel WHERE AimShipperId LIKE N'TESTRD%';
DELETE FROM Lots.Container
WHERE ItemId = (SELECT Id FROM Parts.Item WHERE PartNumber = N'RD-SHIP-TEST');
GO
