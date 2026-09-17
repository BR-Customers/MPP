-- =============================================
-- File:         0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Lots.Lot_GetLineInventorySummary (line inventory sidebar spec).
--   Line MA1-COMPBR (WorkCenter); called with its Assembly Out terminal
--   MA1-COMPBR-AOUT (resolves up to the line).
--   BOM tree:  FG  <- SA x2 + PIN x3 + GASKET x1
--              SA  <- CAST x1 + PIN x1
--   so per FG: SA 2, CAST 2, PIN 3 + 2x1 = 5, GASKET 1.  Horizon 10 ->
--   thresholds SA 20, CAST 20, PIN 50, GASKET 10.
--   On hand at the line: PIN 60 (not low), CAST 5 (low), GASKET 0 (listed,
--   low), plus an unrelated PassThrough BOLT 7 (listed, no threshold) and
--   an FG LOT (never listed).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql';
GO

-- ---- cleanup ----
DECLARE @Fg0 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-FG');
DECLARE @Sa0 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-SA');
DELETE FROM Lots.Container WHERE ItemId = @Fg0;
DELETE FROM Lots.Lot WHERE LotName LIKE N'T099-%';
DELETE bl FROM Parts.BomLine bl INNER JOIN Parts.Bom b ON b.Id = bl.BomId WHERE b.ParentItemId IN (@Fg0, @Sa0);
DELETE FROM Parts.Bom WHERE ParentItemId IN (@Fg0, @Sa0);
DELETE FROM Parts.ContainerConfig WHERE ItemId = @Fg0;
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T099-%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @TFg BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
DECLARE @TSa BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'SubAssembly');
DECLARE @TCo BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @TPt BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId, BoxQuantity, LowInventoryHorizon) VALUES
    (@TFg, N'T099-FG',     N'T099 finished good', 1, @Now, 1, NULL, 10),
    (@TSa, N'T099-SA',     N'T099 sub assembly',  1, @Now, 1, NULL, NULL),
    (@TCo, N'T099-CAST',   N'T099 casting',       1, @Now, 1, NULL, NULL),
    (@TPt, N'T099-PIN',    N'T099 dowel pin',     1, @Now, 1, 5000, NULL),
    (@TPt, N'T099-GASKET', N'T099 gasket',        1, @Now, 1, NULL, NULL),
    (@TPt, N'T099-BOLT',   N'T099 bolt',          1, @Now, 1, 2000, NULL);
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-FG');
DECLARE @Sa BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-SA');
DECLARE @Ca BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-CAST');
DECLARE @Pi BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-PIN');
DECLARE @Ga BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-GASKET');
DECLARE @Bo BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-BOLT');

-- FG BOM: a Deprecated v1 (must be ignored) + Published v2
INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (@Fg, 1, @Now, @Now, @Now, 1, @Now);
INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @Pi, 99, 1, 1);
INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
    VALUES (@Fg, 2, @Now, @Now, 1, @Now);
DECLARE @FgBom BIGINT = SCOPE_IDENTITY();
INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES
    (@FgBom, @Sa, 2, 1, 1), (@FgBom, @Pi, 3, 1, 2), (@FgBom, @Ga, 1, 1, 3);
INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
    VALUES (@Sa, 1, @Now, @Now, 1, @Now);
DECLARE @SaBom BIGINT = SCOPE_IDENTITY();
INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES
    (@SaBom, @Ca, 1, 1, 1), (@SaBom, @Pi, 1, 1, 2);

DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES
    (N'T099-PIN1',  @Pi, 2, 1,       40, 40, @Line, 1, @Now),
    (N'T099-PIN2',  @Pi, 2, 1,       20, 20, @Line, 1, @Now),
    (N'T099-PINX',  @Pi, 2, @Closed, 99, 99, @Line, 1, @Now),   -- closed: excluded
    (N'T099-CAST1', @Ca, 1, 1,        5,  5, @Line, 1, @Now),
    (N'T099-BOLT1', @Bo, 2, 1,        7,  7, @Line, 1, @Now),
    (N'T099-FG1',   @Fg, 1, 1,       30, 30, @Line, 1, @Now);   -- FG: never listed

-- container config (needed for an open container)
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Fg, 4, 10, 0, N'ByCount', @Now);
GO

-- =============================================
-- Phase 1: idle line (no open container, no hint) -> only on-hand non-FG, no low
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @R TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, Threshold INT, IsLow BIT,
                  BoxQuantity INT, AddLotMode NVARCHAR(10), RunningFinishedGoods NVARCHAR(1000), LowInventoryHorizon INT);
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term;
DELETE FROM @R WHERE Description NOT LIKE N'T099 %';   -- ignore other fixtures' stock on this line

DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Idle] 3 on-hand parts (PIN, CAST, BOLT)', @Expected = N'3', @Actual = @N;
DECLARE @Low NVARCHAR(10) = (SELECT CAST(SUM(CAST(IsLow AS INT)) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Idle] nothing low', @Expected = N'0', @Actual = @Low;
DECLARE @PinAvail NVARCHAR(10) = (SELECT CAST(Available AS NVARCHAR(10)) FROM @R WHERE Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[Idle] PIN available 60 (closed LOT excluded)', @Expected = N'60', @Actual = @PinAvail;
DECLARE @FgRows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @R WHERE Description = N'T099 finished good');
EXEC test.Assert_IsEqual @TestName = N'[Idle] FG never listed', @Expected = N'0', @Actual = @FgRows;
DECLARE @RunNull NVARCHAR(1) = (SELECT TOP 1 CASE WHEN RunningFinishedGoods IS NULL THEN N'1' ELSE N'0' END FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Idle] no running FG', @Expected = N'1', @Actual = @RunNull;
GO

-- =============================================
-- Phase 2: hint FG (selected on screen, no container) -> BOM rollup + low flags
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-FG');
DECLARE @R TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, Threshold INT, IsLow BIT,
                  BoxQuantity INT, AddLotMode NVARCHAR(10), RunningFinishedGoods NVARCHAR(1000), LowInventoryHorizon INT);
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @FinishedGoodItemId = @Fg;
DELETE FROM @R WHERE Description NOT LIKE N'T099 %';

DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Hint] 5 parts (SA, CAST, PIN, GASKET, BOLT)', @Expected = N'5', @Actual = @N;
DECLARE @PinT NVARCHAR(10) = (SELECT CAST(Threshold AS NVARCHAR(10)) FROM @R WHERE Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[Hint] PIN threshold 50 (3 + 2x1, x10; deprecated BOM ignored)', @Expected = N'50', @Actual = @PinT;
DECLARE @PinL NVARCHAR(1) = (SELECT CAST(IsLow AS NVARCHAR(1)) FROM @R WHERE Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[Hint] PIN not low (60 >= 50)', @Expected = N'0', @Actual = @PinL;
DECLARE @CaT NVARCHAR(10) = (SELECT CAST(Threshold AS NVARCHAR(10)) FROM @R WHERE Description = N'T099 casting');
EXEC test.Assert_IsEqual @TestName = N'[Hint] CAST threshold 20 (1 x 2 x 10)', @Expected = N'20', @Actual = @CaT;
DECLARE @CaL NVARCHAR(1) = (SELECT CAST(IsLow AS NVARCHAR(1)) FROM @R WHERE Description = N'T099 casting');
EXEC test.Assert_IsEqual @TestName = N'[Hint] CAST low (5 < 20)', @Expected = N'1', @Actual = @CaL;
DECLARE @GaA NVARCHAR(10) = (SELECT CAST(Available AS NVARCHAR(10)) + N'/' + CAST(IsLow AS NVARCHAR(1)) FROM @R WHERE Description = N'T099 gasket');
EXEC test.Assert_IsEqual @TestName = N'[Hint] GASKET listed at 0 and low', @Expected = N'0/1', @Actual = @GaA;
DECLARE @SaL NVARCHAR(1) = (SELECT CAST(IsLow AS NVARCHAR(1)) FROM @R WHERE Description = N'T099 sub assembly');
EXEC test.Assert_IsEqual @TestName = N'[Hint] SA listed and low (0 < 20)', @Expected = N'1', @Actual = @SaL;
DECLARE @BoT NVARCHAR(1) = (SELECT CASE WHEN Threshold IS NULL AND IsLow = 0 THEN N'1' ELSE N'0' END FROM @R WHERE Description = N'T099 bolt');
EXEC test.Assert_IsEqual @TestName = N'[Hint] BOLT (not in BOM) has no threshold', @Expected = N'1', @Actual = @BoT;
DECLARE @Hz NVARCHAR(10) = (SELECT TOP 1 CAST(LowInventoryHorizon AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Hint] horizon 10 reported', @Expected = N'10', @Actual = @Hz;
DECLARE @Run NVARCHAR(1000) = (SELECT TOP 1 RunningFinishedGoods FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Hint] running FG named', @Expected = N'T099 finished good', @Actual = @Run;
GO

-- =============================================
-- Phase 3: AddLotMode + result ORDER (captured with an IDENTITY to keep proc order)
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-FG');
CREATE TABLE #O (Seq INT IDENTITY(1,1), ItemId BIGINT, Description NVARCHAR(500), Available INT, Threshold INT, IsLow BIT,
                 BoxQuantity INT, AddLotMode NVARCHAR(10), RunningFinishedGoods NVARCHAR(1000), LowInventoryHorizon INT);
INSERT INTO #O (ItemId, Description, Available, Threshold, IsLow, BoxQuantity, AddLotMode, RunningFinishedGoods, LowInventoryHorizon)
EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @FinishedGoodItemId = @Fg;
DECLARE @Order NVARCHAR(400) = (
    SELECT STRING_AGG(REPLACE(Description, N'T099 ', N''), N',') WITHIN GROUP (ORDER BY Seq)
    FROM #O WHERE Description LIKE N'T099 %');
EXEC test.Assert_IsEqual @TestName = N'[Order] low first then alphabetical',
    @Expected = N'casting,gasket,sub assembly,bolt,dowel pin', @Actual = @Order;
DECLARE @Modes NVARCHAR(200) = (
    SELECT STRING_AGG(REPLACE(Description, N'T099 ', N'') + N'=' + AddLotMode, N',') WITHIN GROUP (ORDER BY Seq)
    FROM #O WHERE Description LIKE N'T099 %');
DROP TABLE #O;
EXEC test.Assert_IsEqual @TestName = N'[Mode] OneTap / AskQty / None by type + box',
    @Expected = N'casting=None,gasket=AskQty,sub assembly=None,bolt=OneTap,dowel pin=OneTap', @Actual = @Modes;
GO

-- =============================================
-- Phase 4: open container (no hint) makes the FG "running"; NULL horizon -> no flags
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-FG');
DECLARE @Cfg BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Fg);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, OpenedAt, CreatedByUserId)
    VALUES (@Fg, @Cfg, @Term, 1, SYSUTCDATETIME(), 1);
DECLARE @R TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, Threshold INT, IsLow BIT,
                  BoxQuantity INT, AddLotMode NVARCHAR(10), RunningFinishedGoods NVARCHAR(1000), LowInventoryHorizon INT);
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term;
DECLARE @CaL NVARCHAR(1) = (SELECT CAST(IsLow AS NVARCHAR(1)) FROM @R WHERE Description = N'T099 casting');
EXEC test.Assert_IsEqual @TestName = N'[Container] open container makes FG running (CAST low)', @Expected = N'1', @Actual = @CaL;

UPDATE Parts.Item SET LowInventoryHorizon = NULL WHERE Id = @Fg;
DELETE FROM @R;
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term;
DELETE FROM @R WHERE Description NOT LIKE N'T099 %';
DECLARE @Low NVARCHAR(10) = (SELECT CAST(SUM(CAST(IsLow AS INT)) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[NoHorizon] no low flags', @Expected = N'0', @Actual = @Low;
DECLARE @GaListed NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @R WHERE Description = N'T099 gasket');
EXEC test.Assert_IsEqual @TestName = N'[NoHorizon] BOM parts still listed', @Expected = N'1', @Actual = @GaListed;
UPDATE Parts.Item SET LowInventoryHorizon = 10 WHERE Id = @Fg;
GO

-- =============================================
-- Phase 5: empty sets (NULL location, location with no WorkCenter ancestor)
-- =============================================
DECLARE @R TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, Threshold INT, IsLow BIT,
                  BoxQuantity INT, AddLotMode NVARCHAR(10), RunningFinishedGoods NVARCHAR(1000), LowInventoryHorizon INT);
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = NULL;
DECLARE @Area BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1');
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Area;
DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Empty] NULL / area-level location -> empty', @Expected = N'0', @Actual = @N;
GO

-- ---- cleanup ----
DECLARE @Fg0 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-FG');
DECLARE @Sa0 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-SA');
DELETE FROM Lots.Container WHERE ItemId = @Fg0;
DELETE FROM Lots.Lot WHERE LotName LIKE N'T099-%';
DELETE bl FROM Parts.BomLine bl INNER JOIN Parts.Bom b ON b.Id = bl.BomId WHERE b.ParentItemId IN (@Fg0, @Sa0);
DELETE FROM Parts.Bom WHERE ParentItemId IN (@Fg0, @Sa0);
DELETE FROM Parts.ContainerConfig WHERE ItemId = @Fg0;
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T099-%';
GO

EXEC test.EndTestFile;
GO
