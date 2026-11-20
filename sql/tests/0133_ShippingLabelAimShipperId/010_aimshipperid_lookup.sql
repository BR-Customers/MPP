-- =============================================
-- File:         0133_ShippingLabelAimShipperId/010_aimshipperid_lookup.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-16
-- Description:  Migration 0133 (IX_ShippingLabel_AimShipperId, stored-procedure review):
--               the index behind the shipper-id branch of Lots.GlobalTrace_Resolve.
--               Part 1 pins the index definition (keyed on AimShipperId, INCLUDE
--               ContainerId, not unique -- a reprint repeats the shipper id -- not
--               filtered) and that the migration recorded itself once. Part 2 pins the
--               matching semantics the index must not change; it passes on the proc
--               without the index too (same rows):
--                 * exact shipper id -> its container's source LOT, MatchType Shipper;
--                 * case and surrounding blanks do not matter (CI collation + trim);
--                 * shipper id is EXACT only: a prefix of it matches no shipper row;
--                 * another container's label is not returned.
--               The rest of the proc is covered by
--               0037_PlantFloor_Quality_Capture/050_GlobalTrace_Resolve.sql.
--               Fixture: part T0133-PART, two LOTs, two containers (one tray each),
--               labels T0133-AIM-0001 and T0133-AIM-0002.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0133_ShippingLabelAimShipperId/010_aimshipperid_lookup.sql';
GO

-- =============================================
-- Part 1: index definition
-- =============================================
DECLARE @IxId INT = (SELECT index_id FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ShippingLabel') AND name = N'IX_ShippingLabel_AimShipperId');
DECLARE @S NVARCHAR(400);

SET @S = CAST(CASE WHEN @IxId IS NULL THEN 0 ELSE 1 END AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[0133] IX_ShippingLabel_AimShipperId exists', @Expected = N'1', @Actual = @S;

SET @S = ISNULL((SELECT type_desc + N'/unique=' + CAST(is_unique AS NVARCHAR(1)) + N'/filtered=' + CAST(has_filter AS NVARCHAR(1))
                 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ShippingLabel') AND index_id = @IxId), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0133] index is NONCLUSTERED, not unique (reprints repeat the id), not filtered',
    @Expected = N'NONCLUSTERED/unique=0/filtered=0', @Actual = @S;

SET @S = ISNULL((SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY ic.key_ordinal)
                 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = OBJECT_ID(N'Lots.ShippingLabel') AND ic.index_id = @IxId AND ic.is_included_column = 0), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0133] key column is AimShipperId', @Expected = N'AimShipperId', @Actual = @S;

-- GlobalTrace_Resolve branch 4 reads Id (clustered key), AimShipperId and ContainerId
SET @S = ISNULL((SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY c.name)
                 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = OBJECT_ID(N'Lots.ShippingLabel') AND ic.index_id = @IxId AND ic.is_included_column = 1), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0133] index INCLUDEs ContainerId (covers the Global Trace shipper lookup)',
    @Expected = N'ContainerId', @Actual = @S;

SET @S = CAST((SELECT COUNT(*) FROM dbo.SchemaVersion WHERE MigrationId = N'0133_shippinglabel_aimshipperid_index') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0133] migration recorded in dbo.SchemaVersion exactly once', @Expected = N'1', @Actual = @S;
GO

-- =============================================
-- Part 2: matching semantics (pass with or without the index)
-- =============================================
-- ---- fixture cleanup (re-runnable; children before parents) ----
DELETE sl FROM Lots.ShippingLabel sl WHERE sl.AimShipperId LIKE N'T0133-AIM-%';
DELETE ct FROM Lots.ContainerTray ct INNER JOIN Lots.Container c ON c.Id = ct.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'T0133-PART';
DELETE c  FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'T0133-PART';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'T0133-PART';
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'T0133-PART';
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'T0133-PART';
DELETE gc FROM Lots.LotGenealogyClosure gc INNER JOIN Lots.Lot l ON l.Id = gc.AncestorLotId OR l.Id = gc.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'T0133-PART';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'T0133-PART');
GO

-- ---- fixture build ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'T0133-PART')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (2, N'T0133-PART', N'0133 shipper-id lookup test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T0133-PART');

DECLARE @Loc BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Loc AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @Loc, 0, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO test.ContainerConfigInsert (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Item, 4, 25, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);

DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Loc, @PieceCount = 25, @AppUserId = 1, @LotName = N'T0133-LOT-1';
DECLARE @Lot1 BIGINT = (SELECT NewId FROM @CL); DELETE FROM @CL;
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Loc, @PieceCount = 25, @AppUserId = 1, @LotName = N'T0133-LOT-2';
DECLARE @Lot2 BIGINT = (SELECT NewId FROM @CL);

INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, OpenedAt, CreatedByUserId)
VALUES (@Item, @Config, @Loc, 1, @Now, 1);
DECLARE @Con1 BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, OpenedAt, CreatedByUserId)
VALUES (@Item, @Config, @Loc, 1, @Now, 1);
DECLARE @Con2 BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, FinishedGoodLotId) VALUES (@Con1, 1, 25, @Lot1);
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, FinishedGoodLotId) VALUES (@Con2, 1, 25, @Lot2);

DECLARE @LabelType BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Primary');
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, CreatedAt) VALUES (@Con1, N'T0133-AIM-0001', @LabelType, 1, @Now);
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, CreatedAt) VALUES (@Con2, N'T0133-AIM-0002', @LabelType, 1, @Now);
GO

CREATE TABLE #R (Ord INT IDENTITY(1,1), MatchType NVARCHAR(20), MatchedEntityId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), Detail NVARCHAR(200), RemovedAt DATETIME2(3), RemovedReason NVARCHAR(500), MovedInFromContainerName NVARCHAR(50));

-- exact shipper id -> container 1's tray LOT only
INSERT INTO #R (MatchType, MatchedEntityId, LotId, LotName, ItemPartNumber, Detail, RemovedAt, RemovedReason, MovedInFromContainerName)
EXEC Lots.GlobalTrace_Resolve @SearchText = N'T0133-AIM-0001';
DECLARE @C INT = (SELECT COUNT(*) FROM #R);
EXEC test.Assert_RowCount @TestName = N'[0133] exact shipper id -> 1 row', @ExpectedCount = 1, @ActualCount = @C;
DECLARE @S NVARCHAR(200) = (SELECT MatchType + N'|' + LotName + N'|' + ItemPartNumber FROM #R WHERE Ord = 1);
EXEC test.Assert_IsEqual @TestName = N'[0133] exact shipper id -> Shipper row for container 1''s LOT',
    @Expected = N'Shipper|T0133-LOT-1|T0133-PART', @Actual = @S;
DECLARE @Exp NVARCHAR(20) = CAST((SELECT Id FROM Lots.ShippingLabel WHERE AimShipperId = N'T0133-AIM-0001') AS NVARCHAR(20));
SET @S = (SELECT CAST(MatchedEntityId AS NVARCHAR(20)) FROM #R WHERE Ord = 1);
EXEC test.Assert_IsEqual @TestName = N'[0133] MatchedEntityId = the shipping label id', @Expected = @Exp, @Actual = @S;
SET @S = (SELECT Detail FROM #R WHERE Ord = 1);
EXEC test.Assert_Contains @TestName = N'[0133] Detail names the shipper id', @HaystackStr = @S, @NeedleStr = N'T0133-AIM-0001';
TRUNCATE TABLE #R;

-- case and surrounding blanks do not matter
INSERT INTO #R (MatchType, MatchedEntityId, LotId, LotName, ItemPartNumber, Detail, RemovedAt, RemovedReason, MovedInFromContainerName)
EXEC Lots.GlobalTrace_Resolve @SearchText = N'  t0133-aim-0001  ';
SET @S = ISNULL((SELECT STRING_AGG(MatchType + N'|' + LotName, N',') FROM #R), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0133] lower-case, padded shipper id still matches (CI collation + trim)',
    @Expected = N'Shipper|T0133-LOT-1', @Actual = @S;
TRUNCATE TABLE #R;

-- a prefix of a shipper id matches no shipper row (shipper is exact only)
INSERT INTO #R (MatchType, MatchedEntityId, LotId, LotName, ItemPartNumber, Detail, RemovedAt, RemovedReason, MovedInFromContainerName)
EXEC Lots.GlobalTrace_Resolve @SearchText = N'T0133-AIM-000';
SET @C = (SELECT COUNT(*) FROM #R WHERE MatchType = N'Shipper');
EXEC test.Assert_RowCount @TestName = N'[0133] shipper id prefix -> no Shipper rows', @ExpectedCount = 0, @ActualCount = @C;
TRUNCATE TABLE #R;

-- the other label -> only its own container's LOT
INSERT INTO #R (MatchType, MatchedEntityId, LotId, LotName, ItemPartNumber, Detail, RemovedAt, RemovedReason, MovedInFromContainerName)
EXEC Lots.GlobalTrace_Resolve @SearchText = N'T0133-AIM-0002';
SET @S = ISNULL((SELECT STRING_AGG(MatchType + N'|' + LotName, N',') FROM #R), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0133] second shipper id -> only container 2''s LOT',
    @Expected = N'Shipper|T0133-LOT-2', @Actual = @S;
DROP TABLE #R;
GO

-- ---- cleanup ----
DELETE sl FROM Lots.ShippingLabel sl WHERE sl.AimShipperId LIKE N'T0133-AIM-%';
DELETE ct FROM Lots.ContainerTray ct INNER JOIN Lots.Container c ON c.Id = ct.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'T0133-PART';
DELETE c  FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'T0133-PART';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'T0133-PART';
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'T0133-PART';
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'T0133-PART';
DELETE gc FROM Lots.LotGenealogyClosure gc INNER JOIN Lots.Lot l ON l.Id = gc.AncestorLotId OR l.Id = gc.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'T0133-PART';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'T0133-PART');
GO

EXEC test.EndTestFile;
GO
