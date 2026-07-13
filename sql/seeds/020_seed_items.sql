-- ============================================================
-- Seed:        020_seed_items.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-13 (rewritten from the correct DB configuration)
-- Description: Continuous Demo Seed Dataset -- the 13-part Honda matrix as
--              configured in MPP_MES_Dev via the Config Tool (the canonical
--              setup). Replaces the earlier 6MA/5G0-M/RD-BRKT synthetic matrix.
--              Three finished-good chains:
--                * 5G0 Front Cover (serialized):
--                    5G0-c (casting) -> 5G0-SA (machined) -> 5G0-FG + 21001 pin
--                * 59B Cam-Rocker Holder Set (non-serialized):
--                    12231/12232/12241-59B-0000 (3 castings) -> 1223A-59B -A0002
--                    + 90701-5R0-3000 (dowel)
--                * 6NA Fuel Pump (non-serialized):
--                    12270-6NA (casting) -> 12270-6NA-M (machined)
--                    -> 12270-6NA -0001 + 92900-06014-1B, 94301-08100 (fasteners)
--
--              Seeds: dev AppUser Id 2; 13 Items; 3 ContainerConfigs; 5 published
--              BOMs; 25 Parts.ItemLocation eligibility rows (Area + WorkCenter
--              tiers only -- no cell/terminal/printer rows, per the 2026-07-06
--              eligibility-tier decision; the FDS-03-014 cascade resolves cell
--              scans up to these tiers). Idempotent (IF NOT EXISTS on natural
--              keys -- PartNumber / Code -- never a hardcoded Id). ASCII-only.
--
--              Routes (RouteTemplate/RouteStep) live in 029_seed_item_routes.sql
--              (numbered after the OperationTemplate seeds 022/024/026/027 so the
--              role templates exist). Quality specs are not part of this seed.
--
--              Dependencies: 011_seed_locations_mpp_plant.sql (Location.Code:
--              DC1/DC2/DC3, TRIM1, MA1/MA2, MA1-5GOF, MA2-59B, MA1-FP6NA).
-- ============================================================

SET NOCOUNT ON;

-- ============================================================
-- AppUser Id 2 (dev user, matches Common.Util._currentAppUserId fallback)
-- ============================================================
DECLARE @Now0 DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = 2)
BEGIN
    SET IDENTITY_INSERT Location.AppUser ON;
    INSERT INTO Location.AppUser (Id, AdAccount, DisplayName, IgnitionRole, Initials, CreatedAt)
    VALUES (2, N'dev.user', N'Dev User', N'Admin', N'DEV', @Now0);
    SET IDENTITY_INSERT Location.AppUser OFF;
END
GO

-- ============================================================
-- Parts.Item -- 13-part Honda matrix.
--   ItemType (Code, migration 0004): Component/SubAssembly/FinishedGood
--   Uom (Code): PCS (5G0 family) / EA (59B, 6NA families)
--   MaxLotSize column = "Parts Per Basket" (Config Tool label); DefaultSubLotQty
--   = machining-out sub-lot split qty.
-- ============================================================
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Dev BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @TComp BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @TSub  BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'SubAssembly');
DECLARE @TFG   BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
DECLARE @PCS BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'PCS');
DECLARE @EA  BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');

-- ---- 5G0 Front Cover family ----
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'5G0-c')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TComp, N'5G0-c', N'5G0 Front Cover Casting', 12, 24, @PCS, @Now, @Dev);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'5G0-SA')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TSub, N'5G0-SA', N'5G0 Front Cover Sub-Assembly', 12, 24, @PCS, @Now, @Dev);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'5G0-FG')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, WeightUomId, CreatedAt, CreatedByUserId)
    VALUES (@TFG, N'5G0-FG', N'5G0 Front Cover Finished Good', @PCS, @EA, @Now, @Dev);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'21001 pin')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TComp, N'21001 pin', N'Pin 21001', @PCS, @Now, @Dev);

-- ---- 59B Cam Holder family ----
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'12231-59B-0000')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TComp, N'12231-59B-0000', N'59B Cam Holder IN #1 Casting', 15, 30, @EA, @Now, @Dev);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'12232-59B-0000')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TComp, N'12232-59B-0000', N'59B Cam Holder IN #2 Casting', 15, 30, @EA, @Now, @Dev);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'12241-59B-0000')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TComp, N'12241-59B-0000', N'59B Cam Holder EX #1 Casting', 15, 30, @EA, @Now, @Dev);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'90701-5R0-3000')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TComp, N'90701-5R0-3000', N'Dowel Pin 9x10 (purchased)', @EA, @Now, @Dev);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'1223A-59B -A0002')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TFG, N'1223A-59B -A0002', N'59B Cam-Rocker Holder Set', @EA, @Now, @Dev);

-- ---- 6NA Fuel Pump family ----
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'12270-6NA')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TComp, N'12270-6NA', N'6NA Fuel Pump Base Casting (raw)', 6, 12, @EA, @Now, @Dev);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'12270-6NA-M')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TSub, N'12270-6NA-M', N'6NA Fuel Pump Base Machined (synth SA)', 6, 12, @EA, @Now, @Dev);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'92900-06014-1B')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TComp, N'92900-06014-1B', N'Stud Bolt 6x14 (purchased)', @EA, @Now, @Dev);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'94301-08100')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TComp, N'94301-08100', N'Dowel Pin 8x10 (purchased)', @EA, @Now, @Dev);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TFG, N'12270-6NA -0001', N'6NA Fuel Pump', @EA, @Now, @Dev);
GO

-- ============================================================
-- Parts.ContainerConfig -- one per finished good.
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'5G0-FG' AND cc.DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, TargetWeight, CreatedAt)
    SELECT Id, 4, 12, 1, N'ByCount', NULL, SYSUTCDATETIME() FROM Parts.Item WHERE PartNumber = N'5G0-FG';

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'1223A-59B -A0002' AND cc.DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, TargetWeight, CreatedAt)
    SELECT Id, 4, 15, 0, N'ByWeight', 75.0, SYSUTCDATETIME() FROM Parts.Item WHERE PartNumber = N'1223A-59B -A0002';

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'12270-6NA -0001' AND cc.DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, TargetWeight, CreatedAt)
    SELECT Id, 4, 6, 0, N'ByVision', NULL, SYSUTCDATETIME() FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001';
GO

-- ============================================================
-- Parts.Bom + Parts.BomLine (published v1).
--   5G0-SA <- 5G0-c x1                        (machining rename)
--   5G0-FG <- 5G0-SA x1 + 21001 pin x6
--   1223A-59B -A0002 <- 12231 x1 + 12232 x1 + 12241 x1 + 90701-5R0-3000 x19
--   12270-6NA-M <- 12270-6NA x1               (machining rename)
--   12270-6NA -0001 <- 12270-6NA-M x1 + 92900-06014-1B x1 + 94301-08100 x2
-- ============================================================
DECLARE @Bom BIGINT, @P NVARCHAR(60);

-- helper pattern repeated per BOM (direct-insert, resolve child by PartNumber)
-- 5G0-SA <- 5G0-c
IF NOT EXISTS (SELECT 1 FROM Parts.Bom b JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber=N'5G0-SA' AND b.VersionNumber=1)
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, '2026-01-15', '2026-01-14', u.Id, SYSUTCDATETIME() FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber=N'5G0-SA' AND u.Initials=N'DEV';
SET @Bom = (SELECT b.Id FROM Parts.Bom b JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber=N'5G0-SA' AND b.VersionNumber=1);
IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl JOIN Parts.Item c ON c.Id=bl.ChildItemId WHERE bl.BomId=@Bom AND c.PartNumber=N'5G0-c')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder)
    SELECT @Bom, c.Id, 1.0, c.UomId, 1 FROM Parts.Item c WHERE c.PartNumber=N'5G0-c';
GO
DECLARE @Bom BIGINT;
-- 5G0-FG <- 5G0-SA x1 + 21001 pin x6
IF NOT EXISTS (SELECT 1 FROM Parts.Bom b JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber=N'5G0-FG' AND b.VersionNumber=1)
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, '2026-01-15', '2026-01-14', u.Id, SYSUTCDATETIME() FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber=N'5G0-FG' AND u.Initials=N'DEV';
SET @Bom = (SELECT b.Id FROM Parts.Bom b JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber=N'5G0-FG' AND b.VersionNumber=1);
IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl JOIN Parts.Item c ON c.Id=bl.ChildItemId WHERE bl.BomId=@Bom AND c.PartNumber=N'5G0-SA')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) SELECT @Bom, c.Id, 1.0, c.UomId, 1 FROM Parts.Item c WHERE c.PartNumber=N'5G0-SA';
IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl JOIN Parts.Item c ON c.Id=bl.ChildItemId WHERE bl.BomId=@Bom AND c.PartNumber=N'21001 pin')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) SELECT @Bom, c.Id, 6.0, c.UomId, 2 FROM Parts.Item c WHERE c.PartNumber=N'21001 pin';
GO
DECLARE @Bom BIGINT;
-- 1223A-59B -A0002 <- 12231 + 12232 + 12241 + 90701-5R0-3000 x19
IF NOT EXISTS (SELECT 1 FROM Parts.Bom b JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber=N'1223A-59B -A0002' AND b.VersionNumber=1)
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, '2026-01-15', '2026-01-14', u.Id, SYSUTCDATETIME() FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber=N'1223A-59B -A0002' AND u.Initials=N'DEV';
SET @Bom = (SELECT b.Id FROM Parts.Bom b JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber=N'1223A-59B -A0002' AND b.VersionNumber=1);
IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl JOIN Parts.Item c ON c.Id=bl.ChildItemId WHERE bl.BomId=@Bom AND c.PartNumber=N'12231-59B-0000')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) SELECT @Bom, c.Id, 1.0, c.UomId, 1 FROM Parts.Item c WHERE c.PartNumber=N'12231-59B-0000';
IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl JOIN Parts.Item c ON c.Id=bl.ChildItemId WHERE bl.BomId=@Bom AND c.PartNumber=N'12232-59B-0000')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) SELECT @Bom, c.Id, 1.0, c.UomId, 2 FROM Parts.Item c WHERE c.PartNumber=N'12232-59B-0000';
IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl JOIN Parts.Item c ON c.Id=bl.ChildItemId WHERE bl.BomId=@Bom AND c.PartNumber=N'12241-59B-0000')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) SELECT @Bom, c.Id, 1.0, c.UomId, 3 FROM Parts.Item c WHERE c.PartNumber=N'12241-59B-0000';
IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl JOIN Parts.Item c ON c.Id=bl.ChildItemId WHERE bl.BomId=@Bom AND c.PartNumber=N'90701-5R0-3000')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) SELECT @Bom, c.Id, 19.0, c.UomId, 4 FROM Parts.Item c WHERE c.PartNumber=N'90701-5R0-3000';
GO
DECLARE @Bom BIGINT;
-- 12270-6NA-M <- 12270-6NA
IF NOT EXISTS (SELECT 1 FROM Parts.Bom b JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber=N'12270-6NA-M' AND b.VersionNumber=1)
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, '2026-01-15', '2026-01-14', u.Id, SYSUTCDATETIME() FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber=N'12270-6NA-M' AND u.Initials=N'DEV';
SET @Bom = (SELECT b.Id FROM Parts.Bom b JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber=N'12270-6NA-M' AND b.VersionNumber=1);
IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl JOIN Parts.Item c ON c.Id=bl.ChildItemId WHERE bl.BomId=@Bom AND c.PartNumber=N'12270-6NA')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) SELECT @Bom, c.Id, 1.0, c.UomId, 1 FROM Parts.Item c WHERE c.PartNumber=N'12270-6NA';
GO
DECLARE @Bom BIGINT;
-- 12270-6NA -0001 <- 12270-6NA-M x1 + 92900-06014-1B x1 + 94301-08100 x2
IF NOT EXISTS (SELECT 1 FROM Parts.Bom b JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber=N'12270-6NA -0001' AND b.VersionNumber=1)
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, '2026-01-15', '2026-01-14', u.Id, SYSUTCDATETIME() FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber=N'12270-6NA -0001' AND u.Initials=N'DEV';
SET @Bom = (SELECT b.Id FROM Parts.Bom b JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber=N'12270-6NA -0001' AND b.VersionNumber=1);
IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl JOIN Parts.Item c ON c.Id=bl.ChildItemId WHERE bl.BomId=@Bom AND c.PartNumber=N'12270-6NA-M')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) SELECT @Bom, c.Id, 1.0, c.UomId, 1 FROM Parts.Item c WHERE c.PartNumber=N'12270-6NA-M';
IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl JOIN Parts.Item c ON c.Id=bl.ChildItemId WHERE bl.BomId=@Bom AND c.PartNumber=N'92900-06014-1B')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) SELECT @Bom, c.Id, 1.0, c.UomId, 2 FROM Parts.Item c WHERE c.PartNumber=N'92900-06014-1B';
IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl JOIN Parts.Item c ON c.Id=bl.ChildItemId WHERE bl.BomId=@Bom AND c.PartNumber=N'94301-08100')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) SELECT @Bom, c.Id, 2.0, c.UomId, 3 FROM Parts.Item c WHERE c.PartNumber=N'94301-08100';
GO

-- ============================================================
-- Parts.ItemLocation -- eligibility at Area + WorkCenter tiers (no cells).
--   Reusable inline block: (PartNumber, LocationCode, IsConsumptionPoint,
--   MinQuantity, MaxQuantity, DefaultQuantity). Resolved by Location.Code;
--   a code that resolves to no row is skipped (SELECT yields nothing).
-- ============================================================
DECLARE @IL TABLE (Pn NVARCHAR(60), Lc NVARCHAR(50), Cp BIT, MnQ INT, MxQ INT, DfQ INT);
INSERT INTO @IL (Pn, Lc, Cp, MnQ, MxQ, DfQ) VALUES
 -- 5G0 family
 (N'5G0-c', N'DC1', 0, NULL, NULL, NULL),
 (N'5G0-c', N'TRIM1', 0, NULL, NULL, NULL),
 (N'5G0-c', N'MA1-5GOF', 0, NULL, NULL, NULL),
 (N'5G0-SA', N'MA1-5GOF', 0, NULL, NULL, NULL),
 (N'5G0-FG', N'MA1-5GOF', 0, NULL, NULL, NULL),
 (N'21001 pin', N'MA1', 0, NULL, NULL, NULL),
 (N'21001 pin', N'MA2', 0, NULL, NULL, NULL),
 -- 59B family
 (N'12231-59B-0000', N'DC2', 0, NULL, NULL, NULL),
 (N'12231-59B-0000', N'TRIM1', 0, NULL, NULL, NULL),
 (N'12231-59B-0000', N'MA2-59B', 1, 15, 100, 50),
 (N'12232-59B-0000', N'DC2', 0, NULL, NULL, NULL),
 (N'12232-59B-0000', N'TRIM1', 0, NULL, NULL, NULL),
 (N'12232-59B-0000', N'MA2-59B', 1, 15, 100, 50),
 (N'12241-59B-0000', N'DC2', 0, NULL, NULL, NULL),
 (N'12241-59B-0000', N'TRIM1', 0, NULL, NULL, NULL),
 (N'12241-59B-0000', N'MA2-59B', 1, 15, 100, 50),
 (N'90701-5R0-3000', N'MA2-59B', 1, NULL, NULL, NULL),
 (N'1223A-59B -A0002', N'MA2-59B', 0, NULL, NULL, NULL),
 -- 6NA family
 (N'12270-6NA', N'DC3', 0, NULL, NULL, NULL),
 (N'12270-6NA', N'TRIM1', 0, NULL, NULL, NULL),
 (N'12270-6NA', N'MA1-FP6NA', 1, 15, 100, 50),
 (N'12270-6NA-M', N'MA1-FP6NA', 1, 12, 96, 48),
 (N'92900-06014-1B', N'MA1-FP6NA', 1, NULL, NULL, NULL),
 (N'94301-08100', N'MA1-FP6NA', 1, NULL, NULL, NULL),
 (N'12270-6NA -0001', N'MA1-FP6NA', 0, NULL, NULL, NULL);

INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
SELECT i.Id, l.Id, il.Cp, il.MnQ, il.MxQ, il.DfQ, SYSUTCDATETIME()
FROM @IL il
JOIN Parts.Item i ON i.PartNumber = il.Pn
JOIN Location.Location l ON l.Code = il.Lc
WHERE NOT EXISTS (
    SELECT 1 FROM Parts.ItemLocation x
    WHERE x.ItemId = i.Id AND x.LocationId = l.Id AND x.DeprecatedAt IS NULL);
GO

PRINT 'seed_items: 13 Honda parts (5G0 / 59B cam holder / 6NA fuel pump chains), 3 container configs, 5 BOMs, 25 eligibility rows (Area + WorkCenter tiers). Routes in 029_seed_item_routes.sql.';
GO
