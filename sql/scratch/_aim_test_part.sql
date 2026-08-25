SET NOCOUNT ON;

-- Build a finished good whose AIM customer part is the CONFIRMED-WORKING '112006FB A000'.
-- Parts.ufn_AimCustomerPartNumber is REPLACE(PartNumber, '-', ''), so the item's
-- PartNumber must be '11200-6FB -A000' to strip to exactly that string.
--
-- Pack-out is deliberately small (2 trays x 3 = 6 parts) so the container fills fast.
-- Two ContainerConfigs are created, ByCount and ByVision: Assembly_CompleteTray resolves
-- the pack-out by (ItemId, ClosureMethod) with no fallback, and the terminal session
-- picks the method -- so this works whichever mode the terminal is in.

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @U BIGINT = 2;

PRINT '--- 1. create the item ---';
EXEC Parts.Item_Create
    @PartNumber = N'11200-6FB -A000', @ItemTypeId = 4,
    @Description = N'6FB Front Cover (AIM post-back test part)',
    @MacolaPartNumber = NULL, @DefaultSubLotQty = NULL, @MaxLotSize = NULL,
    @UomId = 1, @UnitWeight = NULL, @WeightUomId = NULL,
    @CountryOfOrigin = NULL, @MaxParts = NULL, @AppUserId = @U;

DECLARE @ItemId BIGINT =
    (SELECT Id FROM Parts.Item WHERE PartNumber = N'11200-6FB -A000' AND DeprecatedAt IS NULL);

PRINT '--- resolved item ---';
SELECT @ItemId AS ItemId,
       Parts.ufn_AimCustomerPartNumber(N'11200-6FB -A000') AS AimPartWillPost;

PRINT '--- 2. pack-out configs (2 trays x 3 parts = 6) ---';
EXEC Parts.ContainerConfig_Create
    @ItemId = @ItemId, @TraysPerContainer = 2, @PartsPerTray = 3, @IsSerialized = 0,
    @DunnageCode = NULL, @CustomerCode = NULL, @ClosureMethod = N'ByCount',
    @TargetWeight = NULL, @AppUserId = @U;

EXEC Parts.ContainerConfig_Create
    @ItemId = @ItemId, @TraysPerContainer = 2, @PartsPerTray = 3, @IsSerialized = 0,
    @DunnageCode = NULL, @CustomerCode = NULL, @ClosureMethod = N'ByVision',
    @TargetWeight = NULL, @AppUserId = @U;

PRINT '--- 3. BOM: 92900-06014-1B x1, 94301-08100 x2 ---';
EXEC Parts.Bom_Create @ParentItemId = @ItemId, @EffectiveFrom = @Now, @AppUserId = @U;

DECLARE @BomId BIGINT =
    (SELECT TOP 1 Id FROM Parts.Bom WHERE ParentItemId = @ItemId ORDER BY Id DESC);

EXEC Parts.BomLine_Add @BomId = @BomId, @ChildItemId = 21, @QtyPer = 1, @UomId = 1, @AppUserId = @U;
EXEC Parts.BomLine_Add @BomId = @BomId, @ChildItemId = 22, @QtyPer = 2, @UomId = 1, @AppUserId = @U;

PRINT '--- 4. publish the BOM ---';
EXEC Parts.Bom_Publish @Id = @BomId, @EffectiveFrom = @Now, @LinesJson = NULL, @AppUserId = @U;
