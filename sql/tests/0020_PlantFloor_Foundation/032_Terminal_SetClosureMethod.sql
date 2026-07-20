-- =============================================
-- File: 0020_PlantFloor_Foundation/032_Terminal_SetClosureMethod.sql
-- Desc: Changeover proc: sets CurrentClosureMethod when capable, rejects an
--       incapable method, and freezes an open container at the cell.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/032_Terminal_SetClosureMethod.sql';
GO

-- ---- cleanup (FK-safe) + fixture ----
DELETE he FROM Quality.HoldEvent he INNER JOIN Lots.Container c ON c.Id = he.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'TEST-CHG-ITEM';
DELETE c FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'TEST-CHG-ITEM';
DELETE cc FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'TEST-CHG-ITEM';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CHG-ITEM';
DELETE FROM Location.TerminalPlcDevice WHERE DeviceCode = N'TEST-CHG-SCALE';
DELETE la FROM Location.LocationAttribute la INNER JOIN Location.Location l ON l.Id = la.LocationId WHERE l.Code = N'TEST-CHG-TERM';
DELETE ol FROM Audit.OperationLog ol
    WHERE ol.TerminalLocationId IN (SELECT Id FROM Location.Location WHERE Code = N'TEST-CHG-TERM')
       OR ol.LocationId IN (SELECT Id FROM Location.Location WHERE Code = N'TEST-CHG-TERM');
DELETE FROM Location.Location WHERE Code = N'TEST-CHG-TERM';
GO
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Location.Location (Code, Name, LocationTypeDefinitionId, ParentLocationId, CreatedAt)
VALUES (N'TEST-CHG-TERM', N'Changeover test terminal', 7, @Cell, @Now);
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CHG-TERM');
DECLARE @ScaleType BIGINT = (SELECT Id FROM Location.PlcDeviceType WHERE Code = N'ScaleStation');
INSERT INTO Location.TerminalPlcDevice (TerminalLocationId, PlcDeviceTypeId, DeviceCode, UdtInstancePath)
VALUES (@Term, @ScaleType, N'TEST-CHG-SCALE', N'PlcDevices/TEST_ChgScale');
DECLARE @RI TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @RI EXEC Parts.Item_Create @ItemTypeId = 4, @PartNumber = N'TEST-CHG-ITEM', @Description = N'chg item', @UomId = 1, @AppUserId = 1;
DECLARE @Item BIGINT = (SELECT NewId FROM @RI);
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 2, 24, 0, N'ByCount', @Now);
GO

DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CHG-TERM');

-- A) set ByWeight (terminal has a scale) -> Status 1 + attribute set.
CREATE TABLE #A (Status BIT, Message NVARCHAR(500));
INSERT INTO #A EXEC Location.Terminal_SetClosureMethod @TerminalLocationId = @Term, @NewMethod = N'ByWeight', @AppUserId = 1;
DECLARE @AStat NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #A);
EXEC test.Assert_IsEqual @TestName = N'[Changeover] capable method (ByWeight) Status 1', @Expected = N'1', @Actual = @AStat;
DECLARE @Cur NVARCHAR(20) = (
    SELECT la.AttributeValue FROM Location.LocationAttribute la
    INNER JOIN Location.LocationAttributeDefinition lad ON lad.Id = la.LocationAttributeDefinitionId
    WHERE la.LocationId = @Term AND lad.AttributeName = N'CurrentClosureMethod');
EXEC test.Assert_IsEqual @TestName = N'[Changeover] CurrentClosureMethod attribute = ByWeight', @Expected = N'ByWeight', @Actual = @Cur;
DROP TABLE #A;

-- B) set ByVision (no vision device) -> Status 0.
CREATE TABLE #B (Status BIT, Message NVARCHAR(500));
INSERT INTO #B EXEC Location.Terminal_SetClosureMethod @TerminalLocationId = @Term, @NewMethod = N'ByVision', @AppUserId = 1;
DECLARE @BStat NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #B);
EXEC test.Assert_IsEqual @TestName = N'[Changeover] incapable method (ByVision) Status 0', @Expected = N'0', @Actual = @BStat;
DROP TABLE #B;
GO

-- C) with an OPEN container at the cell, changeover freezes it.
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CHG-TERM');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CHG-ITEM');
DECLARE @Config BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, OpenedAt, CreatedByUserId)
VALUES (@Item, @Config, @Cell, 1, SYSUTCDATETIME(), 1);
DECLARE @Con BIGINT = SCOPE_IDENTITY();

CREATE TABLE #C (Status BIT, Message NVARCHAR(500));
INSERT INTO #C EXEC Location.Terminal_SetClosureMethod @TerminalLocationId = @Term, @NewMethod = N'ByCount', @AppUserId = 1;
DECLARE @CStat NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[Changeover] with open container Status 1', @Expected = N'1', @Actual = @CStat;
DROP TABLE #C;

DECLARE @ConStat NVARCHAR(2) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(2)) FROM Lots.Container WHERE Id = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Changeover] open container frozen -> status Hold(4)', @Expected = N'4', @Actual = @ConStat;

DECLARE @HoldCnt NVARCHAR(2) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM Quality.HoldEvent he
    INNER JOIN Quality.HoldTypeCode ht ON ht.Id = he.HoldTypeCodeId
    WHERE he.ContainerId = @Con AND ht.Code = N'Changeover' AND he.ReleasedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Changeover] open Changeover HoldEvent on the container', @Expected = N'1', @Actual = @HoldCnt;
GO

-- ---- teardown ----
DELETE he FROM Quality.HoldEvent he INNER JOIN Lots.Container c ON c.Id = he.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'TEST-CHG-ITEM';
DELETE c FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'TEST-CHG-ITEM';
DELETE cc FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'TEST-CHG-ITEM';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CHG-ITEM';
DELETE FROM Location.TerminalPlcDevice WHERE DeviceCode = N'TEST-CHG-SCALE';
DELETE la FROM Location.LocationAttribute la INNER JOIN Location.Location l ON l.Id = la.LocationId WHERE l.Code = N'TEST-CHG-TERM';
DELETE ol FROM Audit.OperationLog ol
    WHERE ol.TerminalLocationId IN (SELECT Id FROM Location.Location WHERE Code = N'TEST-CHG-TERM')
       OR ol.LocationId IN (SELECT Id FROM Location.Location WHERE Code = N'TEST-CHG-TERM');
DELETE FROM Location.Location WHERE Code = N'TEST-CHG-TERM';
GO
EXEC test.EndTestFile;
GO
