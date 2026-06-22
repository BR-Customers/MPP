-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/080_ShippingLabel_Void_Reprint.sql
-- Description:  Lots.ShippingLabel_Void / _Reprint (Arc 2 Phase 7). Void marks IsVoid +
--               VoidedAt; double-void rejects; Reprint inserts a NEW append-only row
--               (Initial=0 + PrintReasonCode) leaving the original row unchanged.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/080_ShippingLabel_Void_Reprint.sql';
GO

DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-SHIP-TEST';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P7-SHIP-TEST';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-SHIP-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-SHIP-TEST');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P7-SHIP-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P7-SHIP-TEST', N'Phase7 ship test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-SHIP-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 1, 1, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P7-SHIP-TEST', @AimShipperId = N'AIM-VR-1';

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1; DECLARE @Con BIGINT = (SELECT NewId FROM @O);
DECLARE @TC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @Con, @TrayPosition = 1, @PartsCount = 1, @ClosureMethod = N'ByCount', @AppUserId = 1;
DECLARE @CMP TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CMP EXEC Lots.Container_Complete @ContainerId = @Con, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @Slid BIGINT = (SELECT ShippingLabelId FROM @CMP);

-- void
DECLARE @V TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @V EXEC Lots.ShippingLabel_Void @ShippingLabelId = @Slid, @VoidReason = N'sort cage repack', @AppUserId = 2;
DECLARE @VS NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @V); DELETE FROM @V;
EXEC test.Assert_IsEqual @TestName = N'[Void] void Status 1', @Expected = N'1', @Actual = @VS;
DECLARE @IsVoid NVARCHAR(10) = (SELECT CAST(IsVoid AS NVARCHAR(10)) FROM Lots.ShippingLabel WHERE Id = @Slid);
EXEC test.Assert_IsEqual @TestName = N'[Void] IsVoid=1 + VoidedAt set', @Expected = N'1', @Actual = @IsVoid;
DECLARE @VAt NVARCHAR(10) = (SELECT CASE WHEN VoidedAt IS NOT NULL THEN N'1' ELSE N'0' END FROM Lots.ShippingLabel WHERE Id = @Slid);
EXEC test.Assert_IsEqual @TestName = N'[Void] VoidedAt populated', @Expected = N'1', @Actual = @VAt;
-- double-void rejects
INSERT INTO @V EXEC Lots.ShippingLabel_Void @ShippingLabelId = @Slid, @AppUserId = 2; DECLARE @VS2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @V); DELETE FROM @V;
EXEC test.Assert_IsEqual @TestName = N'[Void] double-void rejects', @Expected = N'0', @Actual = @VS2;

-- reprint -> new append-only row, original unchanged
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Lots.ShippingLabel_Reprint @ShippingLabelId = @Slid, @PrintReasonCode = N'Reprint', @AppUserId = 2;
DECLARE @RS NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @NewLbl BIGINT = (SELECT NewId FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Reprint] reprint Status 1', @Expected = N'1', @Actual = @RS;
DECLARE @IsNew NVARCHAR(10) = CASE WHEN @NewLbl IS NOT NULL AND @NewLbl <> @Slid THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Reprint] new label row (distinct Id)', @Expected = N'1', @Actual = @IsNew;
DECLARE @NewInit NVARCHAR(10) = (SELECT CAST(Initial AS NVARCHAR(10)) FROM Lots.ShippingLabel WHERE Id = @NewLbl);
EXEC test.Assert_IsEqual @TestName = N'[Reprint] reprint row Initial=0', @Expected = N'0', @Actual = @NewInit;
DECLARE @OrigStill NVARCHAR(10) = (SELECT CAST(IsVoid AS NVARCHAR(10)) FROM Lots.ShippingLabel WHERE Id = @Slid);
EXEC test.Assert_IsEqual @TestName = N'[Reprint] original row unchanged (still void)', @Expected = N'1', @Actual = @OrigStill;
GO

DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-SHIP-TEST';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P7-SHIP-TEST';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-SHIP-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-SHIP-TEST');
GO

EXEC test.EndTestFile;
GO
