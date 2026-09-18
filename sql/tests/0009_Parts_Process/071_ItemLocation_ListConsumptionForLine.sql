-- =============================================
-- File:         0009_Parts_Process/071_ItemLocation_ListConsumptionForLine.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:
--   Tests for Parts.ItemLocation_ListConsumptionForLine, the read behind the
--   shop-floor Line Inventory "Tolerances" popup (Task R3). One row per
--   consumption part known to the line, nearest ItemLocation row wins.
--
--   Placed in this suite (not 0008_Parts_Item) alongside the other
--   ItemLocation tests (030_ItemLocation_crud.sql, 040_ItemLocation_SaveAllForItem.sql).
--
--   Fixture (called with terminal MA1-COMPBR-AOUT):
--     T071-A  PassThrough consumption rows at MA1 (area, Max 9000) AND
--             MA1-COMPBR (line, Max 300) -> the LINE row must win (nearest).
--             One Good LOT of 50 and one Hold LOT of 500 at the line
--             (held excluded from Available).
--     T071-B  PassThrough consumption row at the AREA only (Max 70), nothing
--             on hand -> Available 0, RowLocationCode resolves to MA1.
--     T071-C  PassThrough non-consumption row at the line -> never listed.
--   Every assertion filters to the fixture's own descriptions ('T071 %'),
--   because the line is shared with other suites.
--
--   Pre-conditions:
--     - Migrations through 0010 (ItemLocation consumption metadata columns)
--     - AppUser Id=1 exists
--     - MPP plant seed (011): MA1 (area) / MA1-COMPBR (line) /
--       MA1-COMPBR-AOUT (terminal) exist
--     - Parts.ItemLocation_ListConsumptionForLine deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/071_ItemLocation_ListConsumptionForLine.sql';
GO

-- =============================================
-- Cleanup (leading): LOTs -> ItemLocation -> Item
-- =============================================
DELETE FROM Lots.Lot WHERE LotName LIKE N'T071-%';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber LIKE N'T071-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T071-%';
GO

-- =============================================
-- Fixture
-- =============================================
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @App BIGINT = 1;
DECLARE @TPt BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');
DECLARE @UomId BIGINT = (SELECT TOP 1 Id FROM Parts.Uom WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');
DECLARE @Area BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1');

INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES
    (@TPt, N'T071-A', N'T071 both tiers',    @UomId, @Now, @App),
    (@TPt, N'T071-B', N'T071 area only',     @UomId, @Now, @App),
    (@TPt, N'T071-C', N'T071 non-consump',   @UomId, @Now, @App);

DECLARE @AItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T071-A');
DECLARE @BItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T071-B');
DECLARE @CItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T071-C');

-- A: consumption rows at both tiers (line row must win as nearest)
INSERT INTO Parts.ItemLocation (ItemId, LocationId, MaxQuantity, IsConsumptionPoint, CreatedAt)
VALUES (@AItemId, @Area, 9000, 1, @Now);
INSERT INTO Parts.ItemLocation (ItemId, LocationId, MaxQuantity, IsConsumptionPoint, CreatedAt)
VALUES (@AItemId, @Line, 300, 1, @Now);

-- B: consumption row at the area only
INSERT INTO Parts.ItemLocation (ItemId, LocationId, MaxQuantity, IsConsumptionPoint, CreatedAt)
VALUES (@BItemId, @Area, 70, 1, @Now);

-- C: non-consumption row at the line
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
VALUES (@CItemId, @Line, 0, @Now);

DECLARE @Received BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Hold BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES
    (N'T071-A-GOOD', @AItemId, @Received, @Good, 50, 50, @Line, @App, @Now),
    (N'T071-A-HOLD', @AItemId, @Received, @Hold, 500, 500, @Line, @App, @Now);
GO

-- =============================================
-- Phase 1: membership + values, called with the terminal
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
CREATE TABLE #R (ItemLocationId BIGINT, ItemId BIGINT, Description NVARCHAR(500), Available INT,
                 MaxQuantity INT, MinQuantity INT, RowLocationCode NVARCHAR(50), LineLocationCode NVARCHAR(50));
INSERT INTO #R EXEC Parts.ItemLocation_ListConsumptionForLine @LocationId = @Term;
DELETE FROM #R WHERE Description NOT LIKE N'T071 %';

DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[List] exactly A and B (C excluded, non-consumption)', @Expected = N'2', @Actual = @N;

DECLARE @AMax NVARCHAR(10) = (SELECT CAST(MaxQuantity AS NVARCHAR(10)) FROM #R WHERE Description = N'T071 both tiers');
EXEC test.Assert_IsEqual @TestName = N'[List] A Max 300 (line row wins over area)', @Expected = N'300', @Actual = @AMax;
DECLARE @AAvail NVARCHAR(10) = (SELECT CAST(Available AS NVARCHAR(10)) FROM #R WHERE Description = N'T071 both tiers');
EXEC test.Assert_IsEqual @TestName = N'[List] A Available 50 (held excluded)', @Expected = N'50', @Actual = @AAvail;
DECLARE @ALoc NVARCHAR(50) = (SELECT RowLocationCode FROM #R WHERE Description = N'T071 both tiers');
EXEC test.Assert_IsEqual @TestName = N'[List] A RowLocationCode is the line', @Expected = N'MA1-COMPBR', @Actual = @ALoc;
DECLARE @ALineLoc NVARCHAR(50) = (SELECT LineLocationCode FROM #R WHERE Description = N'T071 both tiers');
EXEC test.Assert_IsEqual @TestName = N'[List] A LineLocationCode is the resolved line', @Expected = N'MA1-COMPBR', @Actual = @ALineLoc;

DECLARE @BMax NVARCHAR(10) = (SELECT CAST(MaxQuantity AS NVARCHAR(10)) FROM #R WHERE Description = N'T071 area only');
EXEC test.Assert_IsEqual @TestName = N'[List] B Max 70', @Expected = N'70', @Actual = @BMax;
DECLARE @BAvail NVARCHAR(10) = (SELECT CAST(Available AS NVARCHAR(10)) FROM #R WHERE Description = N'T071 area only');
EXEC test.Assert_IsEqual @TestName = N'[List] B Available 0', @Expected = N'0', @Actual = @BAvail;
DECLARE @BLoc NVARCHAR(50) = (SELECT RowLocationCode FROM #R WHERE Description = N'T071 area only');
EXEC test.Assert_IsEqual @TestName = N'[List] B RowLocationCode is the area', @Expected = N'MA1', @Actual = @BLoc;
DROP TABLE #R;
GO

-- =============================================
-- Phase 2: an area-level call returns an empty set (no WorkCenter ancestor)
-- =============================================
DECLARE @Area BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1');
CREATE TABLE #E (ItemLocationId BIGINT, ItemId BIGINT, Description NVARCHAR(500), Available INT,
                 MaxQuantity INT, MinQuantity INT, RowLocationCode NVARCHAR(50), LineLocationCode NVARCHAR(50));
INSERT INTO #E EXEC Parts.ItemLocation_ListConsumptionForLine @LocationId = @Area;
DECLARE @EN NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #E);
EXEC test.Assert_IsEqual @TestName = N'[Empty] MA1 (area) call -> empty', @Expected = N'0', @Actual = @EN;
DROP TABLE #E;
GO

-- =============================================
-- Cleanup (trailing): LOTs -> ItemLocation -> Item
-- =============================================
DELETE FROM Lots.Lot WHERE LotName LIKE N'T071-%';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber LIKE N'T071-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T071-%';
GO

EXEC test.EndTestFile;
GO
