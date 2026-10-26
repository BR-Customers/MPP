-- ============================================================
-- Seed:        001_demo_plant.sql   (MPP_MES_Demo ONLY -- the sales-kit sample plant)
-- Description: Fictional "Sample Components Plant" in the same shape as the real plant model
--              (011_seed_locations_mpp_plant.sql): enterprise -> site -> areas; die cast area
--              with press cells and an area terminal; trim shop with its terminal and storage;
--              a machining & assembly area with two lines and their IN / OUT terminals;
--              warehouse and shipping; the fallback terminal under the site.
--              DC-T1 holds IpAddress 127.0.0.1 so a browser on the gateway host lands on die
--              cast; other stations are reached through the Terminal Selector.
--              Loaded only by tools/sales-kit/demo-db/Build-DemoDatabase.ps1. ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Loc TABLE (Seq INT IDENTITY, DefId BIGINT, ParentCode NVARCHAR(50) NULL, Name NVARCHAR(200), Code NVARCHAR(50), SortOrder INT);
INSERT INTO @Loc (DefId, ParentCode, Name, Code, SortOrder) VALUES
    (1,  NULL,     N'Sample Components Co.',   N'SAMPLE',            1),
    (2,  N'SAMPLE', N'Sample Components Plant', N'SITE',             1),
    (3,  N'SITE',  N'Die Cast',                N'DC',                1),
    (8,  N'DC',    N'Press 1',                 N'P-01',              1),
    (8,  N'DC',    N'Press 2',                 N'P-02',              2),
    (8,  N'DC',    N'Press 3',                 N'P-03',              3),
    (7,  N'DC',    N'Terminal',                N'DC-T1',             4),
    (3,  N'SITE',  N'Trim Shop',               N'TRIM',              2),
    (7,  N'TRIM',  N'Terminal',                N'TRIM-T1',           1),
    (14, N'TRIM',  N'Trim Storage',            N'TRIM-STORE',        2),
    (3,  N'SITE',  N'Machining & Assembly',    N'MA',                3),
    (5,  N'MA',    N'Housing line',            N'L-1',               1),
    (7,  N'L-1',   N'Machining In',            N'L1-MIN',            1),
    (7,  N'L-1',   N'Machining Out',           N'L1-MOUT',           2),
    (7,  N'L-1',   N'Assembly Out',            N'L1-AOUT',           3),
    (5,  N'MA',    N'Cover line',              N'L-2',               2),
    (7,  N'L-2',   N'Machining In',            N'L2-MIN',            1),
    (7,  N'L-2',   N'Assembly Out',            N'L2-AOUT',           2),
    (4,  N'SITE',  N'Warehouse',               N'WHSE',              4),
    (4,  N'SITE',  N'Shipping IN',             N'SHIPIN',            5),
    (4,  N'SITE',  N'Shipping OUT',            N'SHIPOUT',           6),
    (7,  N'SITE',  N'Fallback Terminal',       N'FALLBACK-TERMINAL', 7);

DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @Loc);
WHILE @i <= @n
BEGIN
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT l.DefId, p.Id, l.Name, l.Code, l.Code, l.SortOrder
    FROM @Loc l LEFT JOIN Location.Location p ON p.Code = l.ParentCode
    WHERE l.Seq = @i AND NOT EXISTS (SELECT 1 FROM Location.Location x WHERE x.Code = l.Code);
    SET @i += 1;
END

-- Terminal attributes, same names the real plant seed uses.
DECLARE @Attr TABLE (Code NVARCHAR(50), AttributeName NVARCHAR(100), Value NVARCHAR(200));
INSERT INTO @Attr VALUES
    (N'DC-T1',   N'DefaultScreen',        N'/shop-floor/die-cast'),
    (N'DC-T1',   N'IpAddress',            N'127.0.0.1'),
    (N'TRIM-T1', N'DefaultScreen',        N'/shop-floor/trim'),
    (N'L1-MIN',  N'DefaultScreen',        N'/shop-floor/machining-in'),
    (N'L1-MIN',  N'HasBarcodeScanner',    N'1'),
    (N'L1-MOUT', N'DefaultScreen',        N'/shop-floor/machining-out'),
    (N'L1-AOUT', N'DefaultScreen',        N'/shop-floor/assembly-nonserialized'),
    (N'L1-AOUT', N'CurrentClosureMethod', N'ByCount'),
    (N'L1-AOUT', N'HasBarcodeScanner',    N'0'),
    (N'L2-MIN',  N'DefaultScreen',        N'/shop-floor/machining-in'),
    (N'L2-MIN',  N'HasBarcodeScanner',    N'1'),
    (N'L2-AOUT', N'DefaultScreen',        N'/shop-floor/assembly-nonserialized'),
    (N'L2-AOUT', N'CurrentClosureMethod', N'ByCount'),
    (N'L2-AOUT', N'HasBarcodeScanner',    N'0');

INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
SELECT l.Id, ad.Id, a.Value, SYSUTCDATETIME()
FROM @Attr a
JOIN Location.Location l ON l.Code = a.Code
JOIN Location.LocationAttributeDefinition ad ON ad.LocationTypeDefinitionId = l.LocationTypeDefinitionId AND ad.AttributeName = a.AttributeName
WHERE NOT EXISTS (SELECT 1 FROM Location.LocationAttribute x WHERE x.LocationId = l.Id AND x.LocationAttributeDefinitionId = ad.Id);

-- Every attribute above must have landed: a missing definition would drop a row silently.
DECLARE @missing INT = (SELECT COUNT(*) FROM @Attr a
    WHERE NOT EXISTS (SELECT 1 FROM Location.LocationAttribute la
        JOIN Location.Location l ON l.Id = la.LocationId
        JOIN Location.LocationAttributeDefinition ad ON ad.Id = la.LocationAttributeDefinitionId
        WHERE l.Code = a.Code AND ad.AttributeName = a.AttributeName));
IF @missing > 0 RAISERROR('001_demo_plant: %d terminal attribute(s) have no definition', 16, 1, @missing);
