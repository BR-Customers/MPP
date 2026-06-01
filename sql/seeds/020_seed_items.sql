-- ============================================================
-- Seed:        seed_items.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-05-20
-- Description: Dummy Parts data for the Item Master Configuration
--              Tool screen. Idempotent (IF NOT EXISTS guards).
--
--              Seeds:
--                - AppUser Id 2 (dev user, matches Common.Util
--                  ._currentAppUserId fallback)
--                - 4 OperationTemplates (Die Cast, Trim, CNC, Assembly)
--                - 5 Items: 5G0, 5G0-C, PNA, 6MA-HSG, RPY
--                - ContainerConfig per Item
--                - Published RouteTemplate + 4 RouteSteps for 5G0
--                - Published Bom + 2 BomLines for 5G0
--                - 2 QualitySpecs linked to 5G0
--
--              Dependencies:
--                - seed_locations.sql (Location Ids 3=DIECAST,
--                  4=MACHSHOP, 5=QC, 13=TRIM)
-- ============================================================

SET NOCOUNT ON;

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

-- ============================================================
-- AppUser Id 2 (dev user)
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = 2)
BEGIN
    SET IDENTITY_INSERT Location.AppUser ON;
    INSERT INTO Location.AppUser (Id, AdAccount, DisplayName, IgnitionRole, Initials, CreatedAt)
    VALUES (2, N'dev.user', N'Dev User', N'Admin', N'DEV', @Now);
    SET IDENTITY_INSERT Location.AppUser OFF;
END

-- ============================================================
-- OperationTemplates (need AreaLocationId)
--   3=DIECAST, 13=TRIM, 4=MACHSHOP, 5=QC
-- ============================================================

SET IDENTITY_INSERT Parts.OperationTemplate ON;

IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = 1)
    INSERT INTO Parts.OperationTemplate (Id, Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt)
    VALUES (1, N'DC-5G0', 1, N'Die Cast 5G0 Front Cover', 3, N'Die cast operation for the 5G0 front cover assembly.', @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = 2)
    INSERT INTO Parts.OperationTemplate (Id, Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt)
    VALUES (2, N'TRIM-5G0', 1, N'Trim 5G0 Front Cover', 13, N'Trim/deflash operation for the 5G0 front cover.', @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = 3)
    INSERT INTO Parts.OperationTemplate (Id, Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt)
    VALUES (3, N'CNC-5G0', 1, N'CNC Machining 5G0', 4, N'CNC machining operation for the 5G0 front cover.', @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = 4)
    INSERT INTO Parts.OperationTemplate (Id, Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt)
    VALUES (4, N'ASSY-FRONT', 1, N'Assembly Front Cover', 5, N'Final assembly of the 5G0 front cover.', @Now);

SET IDENTITY_INSERT Parts.OperationTemplate OFF;

-- ============================================================
-- Parts.Item (5 items matching mockup)
--   ItemType:  1=RawMaterial 2=Component 3=SubAssembly 4=FinishedGood 5=PassThrough
--   Uom:       1=EA 2=LB 3=KG
-- ============================================================

SET IDENTITY_INSERT Parts.Item ON;

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = 1)
    INSERT INTO Parts.Item (Id, ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (1, 4, N'5G0',     N'5G0 Front Cover Assembly',    N'5G0-FC-001', 24, NULL, 1, 3.25, 2, N'US', 500, @Now, 2);

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = 2)
    INSERT INTO Parts.Item (Id, ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (2, 2, N'5G0-C',   N'5G0 Front Cover Casting',     N'5G0-CST-001', 48, NULL, 1, 2.80, 2, N'US', NULL, @Now, 2);

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = 3)
    INSERT INTO Parts.Item (Id, ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (3, 2, N'PNA',     N'Mounting Pin',                N'PIN-A-002',   100, NULL, 1, 0.05, 2, N'US', NULL, @Now, 2);

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = 4)
    INSERT INTO Parts.Item (Id, ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (4, 5, N'6MA-HSG', N'Cam Holder Housing',          N'HSG-6MA-001', 50, NULL, 1, 1.10, 2, N'JP', NULL, @Now, 2);

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = 5)
    INSERT INTO Parts.Item (Id, ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (5, 4, N'RPY',     N'Assembly Set',                N'RPY-SET-001', 12, NULL, 1, 5.50, 2, N'US', 300, @Now, 2);

SET IDENTITY_INSERT Parts.Item OFF;

-- ============================================================
-- Parts.ContainerConfig (one per Item)
-- ============================================================

SET IDENTITY_INSERT Parts.ContainerConfig ON;

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE Id = 1)
    INSERT INTO Parts.ContainerConfig (Id, ItemId, TraysPerContainer, PartsPerTray, IsSerialized, DunnageCode, CustomerCode, ClosureMethod, TargetWeight, CreatedAt)
    VALUES (1, 1, 4,  12,  1, N'RD-5G0F',  N'HONDA-5G0',  N'ByCount',  NULL,  @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE Id = 2)
    INSERT INTO Parts.ContainerConfig (Id, ItemId, TraysPerContainer, PartsPerTray, IsSerialized, DunnageCode, CustomerCode, ClosureMethod, TargetWeight, CreatedAt)
    VALUES (2, 2, 6,  24,  0, N'RD-5G0C',  NULL,           N'ByCount',  NULL,  @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE Id = 3)
    INSERT INTO Parts.ContainerConfig (Id, ItemId, TraysPerContainer, PartsPerTray, IsSerialized, DunnageCode, CustomerCode, ClosureMethod, TargetWeight, CreatedAt)
    VALUES (3, 3, 10, 100, 0, N'BAG-PIN',  NULL,           N'ByCount',  NULL,  @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE Id = 4)
    INSERT INTO Parts.ContainerConfig (Id, ItemId, TraysPerContainer, PartsPerTray, IsSerialized, DunnageCode, CustomerCode, ClosureMethod, TargetWeight, CreatedAt)
    VALUES (4, 4, 4,  25,  0, N'RD-6MA',   N'HONDA-6MA',   N'ByCount',  NULL,  @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE Id = 5)
    INSERT INTO Parts.ContainerConfig (Id, ItemId, TraysPerContainer, PartsPerTray, IsSerialized, DunnageCode, CustomerCode, ClosureMethod, TargetWeight, CreatedAt)
    VALUES (5, 5, 2,  6,   1, N'RD-RPY',   N'HONDA-RPY',   N'ByCount',  NULL,  @Now);

SET IDENTITY_INSERT Parts.ContainerConfig OFF;

-- ============================================================
-- Parts.RouteTemplate (published) for Item 1 (5G0) and 5 (RPY)
-- ============================================================

SET IDENTITY_INSERT Parts.RouteTemplate ON;

IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE Id = 1)
    INSERT INTO Parts.RouteTemplate (Id, ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (1, 1, 2, N'5G0 Production Route v2', '2026-01-15', '2026-01-14', NULL, 2, @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE Id = 2)
    INSERT INTO Parts.RouteTemplate (Id, ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (2, 5, 1, N'RPY Assembly Route v1', '2026-02-01', '2026-01-30', NULL, 2, @Now);

SET IDENTITY_INSERT Parts.RouteTemplate OFF;

-- ============================================================
-- Parts.RouteStep (steps for Route Id 1 and Route Id 2)
-- ============================================================

SET IDENTITY_INSERT Parts.RouteStep ON;

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE Id = 1)
    INSERT INTO Parts.RouteStep (Id, RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    VALUES (1, 1, 1, 1, 1, N'DieInfo, CavityInfo, Weight, GoodCount, BadCount');

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE Id = 2)
    INSERT INTO Parts.RouteStep (Id, RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    VALUES (2, 1, 2, 2, 1, N'Weight, GoodCount, BadCount');

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE Id = 3)
    INSERT INTO Parts.RouteStep (Id, RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    VALUES (3, 1, 3, 3, 1, N'GoodCount, BadCount');

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE Id = 4)
    INSERT INTO Parts.RouteStep (Id, RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    VALUES (4, 1, 4, 4, 1, N'SerialNumber, MaterialVerification, GoodCount, BadCount');

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE Id = 5)
    INSERT INTO Parts.RouteStep (Id, RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    VALUES (5, 2, 4, 1, 1, N'SerialNumber, GoodCount, BadCount');

SET IDENTITY_INSERT Parts.RouteStep OFF;

-- ============================================================
-- Parts.Bom (published) for Item 1 (5G0)
-- ============================================================

SET IDENTITY_INSERT Parts.Bom ON;

IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE Id = 1)
    INSERT INTO Parts.Bom (Id, ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (1, 1, 1, '2026-01-15', '2026-01-14', NULL, 2, @Now);

SET IDENTITY_INSERT Parts.Bom OFF;

-- ============================================================
-- Parts.BomLine
-- ============================================================

SET IDENTITY_INSERT Parts.BomLine ON;

IF NOT EXISTS (SELECT 1 FROM Parts.BomLine WHERE Id = 1)
    INSERT INTO Parts.BomLine (Id, BomId, ChildItemId, QtyPer, UomId, SortOrder)
    VALUES (1, 1, 2, 1.0, 1, 1);   -- 5G0 needs 1x 5G0-C

IF NOT EXISTS (SELECT 1 FROM Parts.BomLine WHERE Id = 2)
    INSERT INTO Parts.BomLine (Id, BomId, ChildItemId, QtyPer, UomId, SortOrder)
    VALUES (2, 1, 3, 2.0, 1, 2);   -- 5G0 needs 2x PNA (Mounting Pin)

SET IDENTITY_INSERT Parts.BomLine OFF;

-- ============================================================
-- Quality.QualitySpec for Item 1 (5G0)
-- ============================================================

SET IDENTITY_INSERT Quality.QualitySpec ON;

IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpec WHERE Id = 1)
    INSERT INTO Quality.QualitySpec (Id, Name, ItemId, OperationTemplateId, Description, CreatedAt)
    VALUES (1, N'5G0 Dimensional Spec', 1, NULL, N'Dimensional tolerances for the 5G0 front cover assembly.', @Now);

IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpec WHERE Id = 2)
    INSERT INTO Quality.QualitySpec (Id, Name, ItemId, OperationTemplateId, Description, CreatedAt)
    VALUES (2, N'5G0 Visual Inspection', 1, NULL, N'Visual inspection criteria for the 5G0 front cover.', @Now);

SET IDENTITY_INSERT Quality.QualitySpec OFF;

-- ============================================================
-- Quality.QualitySpecVersion (one published version each)
-- ============================================================

SET IDENTITY_INSERT Quality.QualitySpecVersion ON;

IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecVersion WHERE Id = 1)
    INSERT INTO Quality.QualitySpecVersion (Id, QualitySpecId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (1, 1, 2, '2026-01-15', '2026-01-14', NULL, 2, @Now);

IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecVersion WHERE Id = 2)
    INSERT INTO Quality.QualitySpecVersion (Id, QualitySpecId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (2, 2, 1, '2026-01-15', '2026-01-14', NULL, 2, @Now);

SET IDENTITY_INSERT Quality.QualitySpecVersion OFF;

PRINT 'seed_items: 5 items, 5 container configs, 2 routes (5 steps), 1 BOM (2 lines), 2 quality specs loaded.';
GO
