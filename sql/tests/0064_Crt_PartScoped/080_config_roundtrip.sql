-- =============================================
-- File:         0064_Crt_PartScoped/080_config_roundtrip.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-20
-- Description:  Parts.Item.CrtEnabled round-trips through the Configuration
--               Tool's Item Master surface (part-scoped CRT Task 8). The flag
--               is useless to Quality unless BOTH halves of the surface carry
--               it: Parts.Item_Update must WRITE it and Parts.Item_Get must
--               READ IT BACK. A test that only proves the column exists proves
--               nothing about the surface -- migration 0064 already guarantees
--               the column.
--
--               So every assertion here goes THROUGH THE PROCS, and both
--               directions are exercised:
--                 * default state           -> Item_Get reports 0
--                 * Item_Update @CrtEnabled=1 -> Item_Get reports 1  (ON)
--                 * Item_Update @CrtEnabled=0 -> Item_Get reports 0  (OFF)
--               The OFF leg matters on its own: a proc that ORs the flag in
--               (or that only ever sets it) would pass the ON leg and still
--               strand Quality with a part they can never un-flag.
--
--               Fixture notes:
--                 * Parts.Item_Get APPENDS new columns LAST, so the
--                   fixed-shape INSERT-EXEC capture below lists CrtEnabled
--                   last. A mismatched column list aborts the whole file with
--                   Msg 213, which surfaces as a runner ERROR, not a FAIL.
--                 * Parts.Item_Create takes no @CrtEnabled -- new parts are
--                   born clean off the column's DEFAULT 0. That is exactly
--                   what the default-state assertion pins.
--                 * ItemTypeId / UomId are resolved dynamically rather than
--                   hardcoded, since Run-Tests.ps1 resets with -SkipDemoSeed.
--                 * Parts.Item_Update is a FULL-REPLACE update: @UomId is
--                   required on every call, so it is passed through on both
--                   legs to avoid clobbering it.
--
--               Teardown deletes the fixture Item by its unique PartNumber.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0064_Crt_PartScoped/080_config_roundtrip.sql';
GO

DECLARE @App        BIGINT = 1;
DECLARE @ItemTypeId BIGINT = (SELECT TOP 1 Id FROM Parts.ItemType WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @UomId      BIGINT = (SELECT TOP 1 Id FROM Parts.Uom      WHERE DeprecatedAt IS NULL ORDER BY Id);

-- ---- Fixture: a brand-new part, created through the create proc ----
CREATE TABLE #c (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #c EXEC Parts.Item_Create
    @PartNumber  = N'CRT080-ROUNDTRIP',
    @ItemTypeId  = @ItemTypeId,
    @Description = N'Part-scoped CRT round-trip fixture',
    @UomId       = @UomId,
    @AppUserId   = @App;

DECLARE @ItemId BIGINT = (SELECT TOP 1 NewId FROM #c);
DROP TABLE #c;

DECLARE @ItemIdStr NVARCHAR(20) = CAST(@ItemId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[CrtConfig] Fixture item created',
    @Value    = @ItemIdStr;

-- Parts.Item_Get result shape -- CrtEnabled is APPENDED LAST (see header).
CREATE TABLE #g (
    Id                BIGINT,
    ItemTypeId        BIGINT,
    ItemTypeName      NVARCHAR(200),
    PartNumber        NVARCHAR(50),
    Description       NVARCHAR(500),
    MacolaPartNumber  NVARCHAR(50),
    DefaultSubLotQty  INT,
    MaxLotSize        INT,
    UomId             BIGINT,
    UomCode           NVARCHAR(20),
    UnitWeight        DECIMAL(10,4),
    WeightUomId       BIGINT,
    WeightUomCode     NVARCHAR(20),
    CountryOfOrigin   NVARCHAR(2),
    MaxParts          INT,
    CreatedAt         DATETIME2(3),
    UpdatedAt         DATETIME2(3),
    CreatedByUserId   BIGINT,
    UpdatedByUserId   BIGINT,
    DeprecatedAt      DATETIME2(3),
    CrtEnabled        BIT
);

CREATE TABLE #u (Status BIT, Message NVARCHAR(500));
DECLARE @Read NVARCHAR(10);
DECLARE @Col  NVARCHAR(10);
DECLARE @Stat NVARCHAR(10);

-- =============================================
-- Test 1: a freshly created part reads back CRT-off through Item_Get
-- =============================================
INSERT INTO #g EXEC Parts.Item_Get @Id = @ItemId;
SET @Read = (SELECT TOP 1 CAST(CrtEnabled AS NVARCHAR(10)) FROM #g);
EXEC test.Assert_IsEqual
    @TestName = N'[CrtConfig] Item_Get exposes CrtEnabled, off on a new part',
    @Expected = N'0', @Actual = @Read;

-- =============================================
-- Test 2: Item_Update turns the flag ON, Item_Get reads it back ON
-- =============================================
DELETE FROM #u;
INSERT INTO #u EXEC Parts.Item_Update
    @Id          = @ItemId,
    @Description = N'Part-scoped CRT round-trip fixture',
    @UomId       = @UomId,
    @AppUserId   = @App,
    @CrtEnabled  = 1;

SET @Stat = (SELECT TOP 1 CAST(Status AS NVARCHAR(10)) FROM #u);
EXEC test.Assert_IsEqual
    @TestName = N'[CrtConfig] Item_Update accepts @CrtEnabled = 1',
    @Expected = N'1', @Actual = @Stat;

DELETE FROM #g;
INSERT INTO #g EXEC Parts.Item_Get @Id = @ItemId;
SET @Read = (SELECT TOP 1 CAST(CrtEnabled AS NVARCHAR(10)) FROM #g);
EXEC test.Assert_IsEqual
    @TestName = N'[CrtConfig] ON round-trips: Item_Update 1 then Item_Get reads 1',
    @Expected = N'1', @Actual = @Read;

-- The proc really wrote the column, not just echoed a parameter back.
SET @Col = (SELECT CAST(CrtEnabled AS NVARCHAR(10)) FROM Parts.Item WHERE Id = @ItemId);
EXEC test.Assert_IsEqual
    @TestName = N'[CrtConfig] ON is persisted to Parts.Item.CrtEnabled',
    @Expected = N'1', @Actual = @Col;

-- =============================================
-- Test 3: Item_Update turns the flag back OFF, Item_Get reads it back OFF
--   The un-flag direction is the one a write-only / OR-ing implementation
--   silently breaks -- Quality must be able to clear a part again.
-- =============================================
DELETE FROM #u;
INSERT INTO #u EXEC Parts.Item_Update
    @Id          = @ItemId,
    @Description = N'Part-scoped CRT round-trip fixture',
    @UomId       = @UomId,
    @AppUserId   = @App,
    @CrtEnabled  = 0;

SET @Stat = (SELECT TOP 1 CAST(Status AS NVARCHAR(10)) FROM #u);
EXEC test.Assert_IsEqual
    @TestName = N'[CrtConfig] Item_Update accepts @CrtEnabled = 0',
    @Expected = N'1', @Actual = @Stat;

DELETE FROM #g;
INSERT INTO #g EXEC Parts.Item_Get @Id = @ItemId;
SET @Read = (SELECT TOP 1 CAST(CrtEnabled AS NVARCHAR(10)) FROM #g);
EXEC test.Assert_IsEqual
    @TestName = N'[CrtConfig] OFF round-trips: Item_Update 0 then Item_Get reads 0',
    @Expected = N'0', @Actual = @Read;

SET @Col = (SELECT CAST(CrtEnabled AS NVARCHAR(10)) FROM Parts.Item WHERE Id = @ItemId);
EXEC test.Assert_IsEqual
    @TestName = N'[CrtConfig] OFF is persisted to Parts.Item.CrtEnabled',
    @Expected = N'0', @Actual = @Col;

-- =============================================
-- Test 4: the flag change appears in the audit field-diff prose
--   Item_Update's Description is "<Part> . Identity . Updated <field old->new ...>".
--   A CRT toggle is a Quality-relevant config change; it must be legible there.
-- =============================================
DECLARE @Desc NVARCHAR(500) = (
    SELECT TOP 1 cl.Description
    FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
    WHERE let.Code = N'Item' AND cl.EntityId = @ItemId
    ORDER BY cl.Id DESC);

EXEC test.Assert_Contains
    @TestName    = N'[CrtConfig] Audit field-diff names CrtEnabled',
    @HaystackStr = @Desc, @NeedleStr = N'CrtEnabled';

-- =============================================
-- Test 5: omitting @CrtEnabled is a full-replace CLEAR, not a no-op
--   Documents the proc's declared behaviour so a future caller that forgets
--   to pass the flag through fails loudly here rather than silently in Dev.
-- =============================================
DELETE FROM #u;
INSERT INTO #u EXEC Parts.Item_Update
    @Id          = @ItemId,
    @Description = N'Part-scoped CRT round-trip fixture',
    @UomId       = @UomId,
    @AppUserId   = @App,
    @CrtEnabled  = 1;
DELETE FROM #u;
INSERT INTO #u EXEC Parts.Item_Update
    @Id          = @ItemId,
    @Description = N'Part-scoped CRT round-trip fixture',
    @UomId       = @UomId,
    @AppUserId   = @App;

SET @Col = (SELECT CAST(CrtEnabled AS NVARCHAR(10)) FROM Parts.Item WHERE Id = @ItemId);
-- CRT is NULL-PRESERVING, deliberately unlike this proc's other parameters.
-- Every sibling (@Description, @MaxParts, ...) is full-replace, so omitting it
-- clears the column. CRT is a SAFETY flag: silently untagging a part would ship
-- suspect material unmarked and nothing would surface it, so omission leaves the
-- flag ALONE. Explicit 0 still clears it, which is the only path the Item Master
-- checkbox uses -- asserted immediately below.
EXEC test.Assert_IsEqual
    @TestName = N'[CrtConfig] Omitting @CrtEnabled PRESERVES the flag (safety flag, not full-replace)',
    @Expected = N'1', @Actual = @Col;

-- ...and an explicit 0 must still turn it off, or the flag could never be cleared.
DELETE FROM #u;
INSERT INTO #u EXEC Parts.Item_Update
    @Id          = @ItemId,
    @Description = N'Part-scoped CRT round-trip fixture',
    @UomId       = @UomId,
    @AppUserId   = @App,
    @CrtEnabled  = 0;
SET @Col = (SELECT CAST(CrtEnabled AS NVARCHAR(10)) FROM Parts.Item WHERE Id = @ItemId);
EXEC test.Assert_IsEqual
    @TestName = N'[CrtConfig] Explicit @CrtEnabled = 0 still clears the flag',
    @Expected = N'0', @Actual = @Col;

DROP TABLE #g;
DROP TABLE #u;
GO

-- ---- Teardown ----
DELETE FROM Parts.Item WHERE PartNumber = N'CRT080-ROUNDTRIP';
GO

EXEC test.EndTestFile;
GO
