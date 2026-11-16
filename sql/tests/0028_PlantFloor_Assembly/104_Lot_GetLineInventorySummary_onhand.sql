-- =============================================
-- File:         0028_PlantFloor_Assembly/104_Lot_GetLineInventorySummary_onhand.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-16
-- Description:  Lots.Lot_GetLineInventorySummary v2.1 (stored-procedure review). Pins the
--   AVAILABLE step the v2.1 change touches (it added the literal 'LotStatusId <> 4' so
--   the on-hand read seeks IX_Lot_NotClosed_Location), complementing 099 (membership,
--   levels, order, scope, Hold + Closed):
--     * stock at the line AND at every descendant (child cell, grandchild) is summed;
--     * a LOT at ANOTHER line is not counted;
--     * Open-status, Scrap-status and Closed-status LOTs are not counted, and a LOT
--       with InventoryAvailable = 0 adds nothing;
--     * a part whose only stock at the line is Closed is not listed at all;
--     * the same parts read from the other line show that line's stock.
--   Must pass on v2.0 and v2.1 alike. Fixture lines: MA1-COMPBR (terminal
--   MA1-COMPBR-AOUT, child cell MA1-COMPBR-MIN, grandchild MA1-COMPBR-AOUT-P1) and
--   MA1-6MD (terminal MA1-6MD-AOUT). Assertions filter to 'T104 %' (lines are shared).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/104_Lot_GetLineInventorySummary_onhand.sql';
GO

-- ---- cleanup (LOTs -> ItemLocation -> Item) ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'T104-%';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber LIKE N'T104-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T104-%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @TCo BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId, BoxQuantity) VALUES
    (@TCo, N'T104-A', N'T104 part a', 1, @Now, 1, NULL),
    (@TCo, N'T104-B', N'T104 part b', 1, @Now, 1, NULL);

DECLARE @Line  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');
DECLARE @Child BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @Grand BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT-P1');
DECLARE @Other BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD');

-- A is a consumption part at MA1-COMPBR (Max 1000); B is not a consumption part anywhere
INSERT INTO Parts.ItemLocation (ItemId, LocationId, MaxQuantity, IsConsumptionPoint, CreatedAt)
SELECT Id, @Line, 1000, 1, @Now FROM Parts.Item WHERE PartNumber = N'T104-A';

DECLARE @Good   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Scrap  BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Scrap');
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @Open   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');

-- A at MA1-COMPBR: 10 (line) + 20 (child) + 40 (grandchild) count = 70.
--   Not counted: Open 100, Scrap 200, Closed 400 (stock still on it), Good with 0 available.
-- A at MA1-6MD: 800 (another line).
-- B at MA1-COMPBR: Closed only (900) -> B not listed there. B at MA1-6MD: 50.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
SELECT N'T104-' + v.Tag, i.Id, 2, v.St, v.Pc, v.Av, v.Loc, 1, @Now
FROM (VALUES (N'T104-A', N'A-LINE',   @Good,   10,  10,  @Line),
             (N'T104-A', N'A-CHILD',  @Good,   20,  20,  @Child),
             (N'T104-A', N'A-GRAND',  @Good,   40,  40,  @Grand),
             (N'T104-A', N'A-OPEN',   @Open,   100, 100, @Line),
             (N'T104-A', N'A-SCRAP',  @Scrap,  200, 200, @Line),
             (N'T104-A', N'A-CLOSED', @Closed, 400, 400, @Line),
             (N'T104-A', N'A-ZERO',   @Good,   5,   0,   @Line),
             (N'T104-A', N'A-OTHER',  @Good,   800, 800, @Other),
             (N'T104-B', N'B-CLOSED', @Closed, 900, 900, @Line),
             (N'T104-B', N'B-OTHER',  @Good,   50,  50,  @Other)) v(Pn, Tag, St, Pc, Av, Loc)
INNER JOIN Parts.Item i ON i.PartNumber = v.Pn;
GO

-- =============================================
-- Phase 1: MA1-COMPBR, line-wide
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @R TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT, Level NVARCHAR(10),
                  BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @LineWide = 1;
DECLARE @S NVARCHAR(400) = ISNULL((SELECT STRING_AGG(REPLACE(Description, N'T104 ', N'') + N'=' + CAST(Available AS NVARCHAR(10)) + N'/' + Level, N',')
                                          WITHIN GROUP (ORDER BY Description)
                                   FROM @R WHERE Description LIKE N'T104 %'), N'<none>');
EXEC test.Assert_IsEqual
    @TestName = N'[OnHand] line + descendants summed (70); Open/Scrap/Closed/zero and other-line stock excluded; Closed-only part not listed',
    @Expected = N'part a=70/Critical', @Actual = @S;
GO

-- =============================================
-- Phase 2: the same parts read from MA1-6MD
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD-AOUT');
DECLARE @R TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT, Level NVARCHAR(10),
                  BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @LineWide = 1;
DECLARE @S NVARCHAR(400) = ISNULL((SELECT STRING_AGG(REPLACE(Description, N'T104 ', N'') + N'=' + CAST(Available AS NVARCHAR(10)) + N'/' + Level, N',')
                                          WITHIN GROUP (ORDER BY Description)
                                   FROM @R WHERE Description LIKE N'T104 %'), N'<none>');
EXEC test.Assert_IsEqual
    @TestName = N'[OnHand] other line: its own stock only (a 800, b 50; no consumption row there -> None)',
    @Expected = N'part a=800/None,part b=50/None', @Actual = @S;
GO

-- ---- cleanup ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'T104-%';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber LIKE N'T104-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T104-%';
GO

EXEC test.EndTestFile;
GO
