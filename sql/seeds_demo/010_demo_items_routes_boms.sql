-- ============================================================
-- Seed:        010_demo_items_routes_boms.sql   (MPP_MES_Demo ONLY)
-- Description: The sample plant's parts (the demo's config.js), their eligibility, published
--              routes, published BOMs and finished-good container configs -- all through the
--              application's procs, the way scratch/seed_jp_validation.sql builds them.
--              Castings HSG-410 / HSG-440 end at MachiningOut (minted into -M sub-assemblies on
--              the housing line); CVR-220 / BRK-230 end at AssemblyOut (cover line, no Machining
--              OUT). Sub-assemblies route to AssemblyOut -- the shape CLAUDE.md names as the fix
--              for the Machining OUT pick-list wart. ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @Sys BIGINT = 1;
DECLARE @Pcs BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'PCS');
DECLARE @r  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @msg NVARCHAR(500), @i INT;

-- ---- items ---------------------------------------------------------------------------------------
DECLARE @Items TABLE (Seq INT IDENTITY, Pn NVARCHAR(50), TypeCode NVARCHAR(20), Descr NVARCHAR(200), SubLot INT NULL, Basket INT NULL);
INSERT INTO @Items (Pn, TypeCode, Descr, SubLot, Basket) VALUES
    (N'HSG-410',   N'Component',    N'Housing casting',             16,   48),
    (N'HSG-440',   N'Component',    N'Pump housing casting',        16,   40),
    (N'CVR-220',   N'Component',    N'Cover casting',               NULL, 60),
    (N'BRK-230',   N'Component',    N'Bracket casting',             NULL, 60),
    (N'SEAL-01',   N'Component',    N'Seal kit (purchased)',        NULL, NULL),
    (N'HSG-410-M', N'SubAssembly',  N'Machined housing',            16,   NULL),
    (N'HSG-440-M', N'SubAssembly',  N'Machined pump housing',       16,   NULL),
    (N'FG-4100',   N'FinishedGood', N'Housing assembly',            NULL, NULL),
    (N'FG-4400',   N'FinishedGood', N'Pump housing assembly',       NULL, NULL),
    (N'FG-2200',   N'FinishedGood', N'Cover assembly',              NULL, NULL);
DECLARE @pn NVARCHAR(50), @tc NVARCHAR(20), @ds NVARCHAR(200), @sub INT, @bsk INT, @tid BIGINT;
SET @i = 1;
WHILE @i <= (SELECT COUNT(*) FROM @Items)
BEGIN
    SELECT @pn = Pn, @tc = TypeCode, @ds = Descr, @sub = SubLot, @bsk = Basket FROM @Items WHERE Seq = @i;
    SET @tid = (SELECT Id FROM Parts.ItemType WHERE Code = @tc);
    IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = @pn)
    BEGIN
        DELETE @r;
        INSERT INTO @r EXEC Parts.Item_Create @PartNumber = @pn, @ItemTypeId = @tid, @Description = @ds,
            @DefaultSubLotQty = @sub, @MaxLotSize = @bsk, @UomId = @Pcs, @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1)
        BEGIN SELECT @msg = Message FROM @r; RAISERROR('Item_Create %s: %s', 16, 1, @pn, @msg); END
    END
    SET @i += 1;
END

-- ---- eligibility: where each part may be, and where it is consumed --------------------------------
DECLARE @Elig TABLE (Seq INT IDENTITY, Pn NVARCHAR(50), LocCode NVARCHAR(50), Consume BIT);
INSERT INTO @Elig (Pn, LocCode, Consume) VALUES
    (N'HSG-410', N'DC', 0), (N'HSG-410', N'TRIM', 0), (N'HSG-410', N'L-1', 0),
    (N'HSG-440', N'DC', 0), (N'HSG-440', N'TRIM', 0), (N'HSG-440', N'L-1', 0),
    (N'CVR-220', N'DC', 0), (N'CVR-220', N'TRIM', 0), (N'CVR-220', N'L-2', 1),
    (N'BRK-230', N'DC', 0), (N'BRK-230', N'TRIM', 0), (N'BRK-230', N'L-2', 1),
    (N'HSG-410-M', N'L-1', 1), (N'HSG-440-M', N'L-1', 1), (N'SEAL-01', N'L-1', 1),
    (N'FG-4100', N'L-1', 0), (N'FG-4400', N'L-1', 0), (N'FG-2200', N'L-2', 0);
DECLARE @lc NVARCHAR(50), @cp BIT, @iid BIGINT, @lid BIGINT;
SET @i = 1;
WHILE @i <= (SELECT COUNT(*) FROM @Elig)
BEGIN
    SELECT @pn = Pn, @lc = LocCode, @cp = Consume FROM @Elig WHERE Seq = @i;
    SELECT @iid = Id FROM Parts.Item WHERE PartNumber = @pn;
    SELECT @lid = Id FROM Location.Location WHERE Code = @lc;
    IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @iid AND LocationId = @lid AND DeprecatedAt IS NULL)
    BEGIN
        DELETE @r;
        INSERT INTO @r EXEC Parts.ItemLocation_Add @ItemId = @iid, @LocationId = @lid, @IsConsumptionPoint = @cp, @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1)
        BEGIN SELECT @msg = Message FROM @r; RAISERROR('ItemLocation_Add %s @ %s: %s', 16, 1, @pn, @lc, @msg); END
    END
    SET @i += 1;
END

-- ---- BOMs (drive the consume-mint child -> parent derivation) ---------------------------------------
DECLARE @Bom TABLE (Seq INT IDENTITY, Parent NVARCHAR(50), Child NVARCHAR(50), Qty DECIMAL(10,4));
INSERT INTO @Bom (Parent, Child, Qty) VALUES
    (N'HSG-410-M', N'HSG-410', 1), (N'HSG-440-M', N'HSG-440', 1),
    (N'FG-4100', N'HSG-410-M', 1), (N'FG-4100', N'SEAL-01', 1),
    (N'FG-4400', N'HSG-440-M', 1), (N'FG-4400', N'SEAL-01', 1),
    (N'FG-2200', N'CVR-220', 1),   (N'FG-2200', N'BRK-230', 1);
DECLARE @parents TABLE (Seq INT IDENTITY, Parent NVARCHAR(50));
INSERT INTO @parents (Parent) SELECT DISTINCT Parent FROM @Bom;
DECLARE @par NVARCHAR(50), @bomId BIGINT, @child NVARCHAR(50), @q DECIMAL(10,4), @cid BIGINT, @j INT;
SET @i = 1;
WHILE @i <= (SELECT COUNT(*) FROM @parents)
BEGIN
    SELECT @par = Parent FROM @parents WHERE Seq = @i;
    SET @iid = (SELECT Id FROM Parts.Item WHERE PartNumber = @par);
    IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @iid AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
    BEGIN
        DELETE @r;
        INSERT INTO @r EXEC Parts.Bom_Create @ParentItemId = @iid, @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1) BEGIN SELECT @msg = Message FROM @r; RAISERROR('Bom_Create %s: %s', 16, 1, @par, @msg); END
        SET @bomId = (SELECT NewId FROM @r);
        SET @j = 1;
        WHILE @j <= (SELECT COUNT(*) FROM @Bom)
        BEGIN
            SELECT @child = Child, @q = Qty FROM @Bom WHERE Seq = @j AND Parent = @par;
            IF @@ROWCOUNT = 1
            BEGIN
                SET @cid = (SELECT Id FROM Parts.Item WHERE PartNumber = @child);
                DELETE @r;
                INSERT INTO @r EXEC Parts.BomLine_Add @BomId = @bomId, @ChildItemId = @cid, @QtyPer = @q, @UomId = @Pcs, @AppUserId = @Sys;
                IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1) BEGIN SELECT @msg = Message FROM @r; RAISERROR('BomLine_Add %s <- %s: %s', 16, 1, @par, @child, @msg); END
            END
            SET @j += 1;
        END
        DELETE @r2;
        INSERT INTO @r2 EXEC Parts.Bom_Publish @Id = @bomId, @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r2 WHERE Status = 1) BEGIN SELECT @msg = Message FROM @r2; RAISERROR('Bom_Publish %s: %s', 16, 1, @par, @msg); END
    END
    SET @i += 1;
END

-- ---- routes (Create -> SaveAll -> Publish; route legality enforced at Publish) ------------------------
DECLARE @Routes TABLE (Pn NVARCHAR(50), Seq INT, TemplateCode NVARCHAR(50));
INSERT INTO @Routes (Pn, Seq, TemplateCode) VALUES
    (N'HSG-410', 1, N'DieCastShot'), (N'HSG-410', 2, N'TrimIn'), (N'HSG-410', 3, N'TrimOut'), (N'HSG-410', 4, N'MachiningIn'), (N'HSG-410', 5, N'MachiningOut'),
    (N'HSG-440', 1, N'DieCastShot'), (N'HSG-440', 2, N'TrimIn'), (N'HSG-440', 3, N'TrimOut'), (N'HSG-440', 4, N'MachiningIn'), (N'HSG-440', 5, N'MachiningOut'),
    (N'CVR-220', 1, N'DieCastShot'), (N'CVR-220', 2, N'TrimIn'), (N'CVR-220', 3, N'TrimOut'), (N'CVR-220', 4, N'MachiningIn'), (N'CVR-220', 5, N'AssemblyOut'),
    (N'BRK-230', 1, N'DieCastShot'), (N'BRK-230', 2, N'TrimIn'), (N'BRK-230', 3, N'TrimOut'), (N'BRK-230', 4, N'MachiningIn'), (N'BRK-230', 5, N'AssemblyOut'),
    (N'HSG-410-M', 1, N'AssemblyOut'), (N'HSG-440-M', 1, N'AssemblyOut'),
    (N'FG-4100', 1, N'AssemblyOut'), (N'FG-4400', 1, N'AssemblyOut'), (N'FG-2200', 1, N'AssemblyOut');
DECLARE @routed TABLE (Seq INT IDENTITY, Pn NVARCHAR(50));
INSERT INTO @routed (Pn) SELECT DISTINCT Pn FROM @Routes;
DECLARE @Eff DATETIME2(3) = CAST('2026-01-01' AS DATETIME2(3)), @rtId BIGINT, @steps NVARCHAR(MAX);
SET @i = 1;
WHILE @i <= (SELECT COUNT(*) FROM @routed)
BEGIN
    SELECT @pn = Pn FROM @routed WHERE Seq = @i;
    SET @iid = (SELECT Id FROM Parts.Item WHERE PartNumber = @pn);
    IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE ItemId = @iid AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
    BEGIN
        DELETE @r;
        INSERT INTO @r EXEC Parts.RouteTemplate_Create @ItemId = @iid, @Name = N'Route v1', @EffectiveFrom = @Eff, @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1) BEGIN SELECT @msg = Message FROM @r; RAISERROR('RouteTemplate_Create %s: %s', 16, 1, @pn, @msg); END
        SET @rtId = (SELECT NewId FROM @r);
        SET @steps = (
            SELECT CAST(NULL AS BIGINT) AS Id, ot.Id AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description
            FROM @Routes rr JOIN Parts.OperationTemplate ot ON ot.Code = rr.TemplateCode
            WHERE rr.Pn = @pn ORDER BY rr.Seq FOR JSON PATH, INCLUDE_NULL_VALUES);
        DELETE @r;
        INSERT INTO @r EXEC Parts.RouteTemplate_SaveAll @Id = @rtId, @Name = N'Route v1', @EffectiveFrom = @Eff, @AppUserId = @Sys, @StepsJson = @steps;
        IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1) BEGIN SELECT @msg = Message FROM @r; RAISERROR('RouteTemplate_SaveAll %s: %s', 16, 1, @pn, @msg); END
        DELETE @r2;
        INSERT INTO @r2 EXEC Parts.RouteTemplate_Publish @Id = @rtId, @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r2 WHERE Status = 1) BEGIN SELECT @msg = Message FROM @r2; RAISERROR('RouteTemplate_Publish %s: %s', 16, 1, @pn, @msg); END
    END
    SET @i += 1;
END

-- ---- container configs for the finished goods (4 trays per container) --------------------------------
DECLARE @Cc TABLE (Seq INT IDENTITY, Pn NVARCHAR(50), PartsPerTray INT);
INSERT INTO @Cc (Pn, PartsPerTray) VALUES (N'FG-4100', 12), (N'FG-4400', 10), (N'FG-2200', 24);
DECLARE @ppt INT;
SET @i = 1;
WHILE @i <= (SELECT COUNT(*) FROM @Cc)
BEGIN
    SELECT @pn = Pn, @ppt = PartsPerTray FROM @Cc WHERE Seq = @i;
    SET @iid = (SELECT Id FROM Parts.Item WHERE PartNumber = @pn);
    IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @iid)
    BEGIN
        DELETE @r;
        INSERT INTO @r EXEC Parts.ContainerConfig_Create @ItemId = @iid, @TraysPerContainer = 4, @PartsPerTray = @ppt,
            @IsSerialized = 0, @ClosureMethod = N'ByCount', @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1) BEGIN SELECT @msg = Message FROM @r; RAISERROR('ContainerConfig_Create %s: %s', 16, 1, @pn, @msg); END
    END
    SET @i += 1;
END
