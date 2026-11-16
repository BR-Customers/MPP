-- =============================================
-- File:         0009_Parts_Process/072_ItemLocation_ListConsumptionForLine_closed.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-16
-- Description:
--   Parts.ItemLocation_ListConsumptionForLine v1.2 (stored-procedure review). The
--   Available fill now also carries the literal LotStatusId <> 4 (Closed) so it can
--   seek migration 0118's IX_Lot_NotClosed_Location instead of reading the whole
--   Lots.Lot heap. Pins what Available counts, so the extra predicate cannot change
--   a number (passes on v1.1 and v1.2):
--     T072-A  consumption row at the line. On hand:
--               Good   50 at the line            -> counted
--               Good    7 at the terminal        -> counted (descendant of the line)
--               Closed 700 at the line           -> NOT counted (status Closed, even
--                                                   with InventoryAvailable > 0)
--               Open   20 at the line            -> NOT counted (status Open)
--               Hold  500 at the line            -> NOT counted (BlocksProduction)
--             Available = 57.
--     T072-B  consumption row at the line, only a Closed LOT (300) on hand ->
--             still listed, Available 0.
--   071_ covers membership, nearest-row resolution and the empty-set cases.
--   Every assertion filters to the fixture's own descriptions ('T072 %'),
--   because the line is shared with other suites.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/072_ItemLocation_ListConsumptionForLine_closed.sql';
GO

-- ---- cleanup ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'T072-%';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber LIKE N'T072-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T072-%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @App BIGINT = 1;
DECLARE @TPt BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');
DECLARE @UomId BIGINT = (SELECT TOP 1 Id FROM Parts.Uom WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES
    (@TPt, N'T072-A', N'T072 mixed statuses', @UomId, @Now, @App),
    (@TPt, N'T072-B', N'T072 closed only',    @UomId, @Now, @App);
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T072-A');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T072-B');

INSERT INTO Parts.ItemLocation (ItemId, LocationId, MaxQuantity, IsConsumptionPoint, CreatedAt) VALUES
    (@A, @Line, 400, 1, @Now),
    (@B, @Line, 400, 1, @Now);

DECLARE @Received BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Good   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Hold   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @Open   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES
    (N'T072-A-GOOD-LINE', @A, @Received, @Good,    50,  50, @Line, @App, @Now),
    (N'T072-A-GOOD-TERM', @A, @Received, @Good,     7,   7, @Term, @App, @Now),
    (N'T072-A-CLOSED',    @A, @Received, @Closed, 700, 700, @Line, @App, @Now),
    (N'T072-A-OPEN',      @A, @Received, @Open,    20,  20, @Line, @App, @Now),
    (N'T072-A-HOLD',      @A, @Received, @Hold,   500, 500, @Line, @App, @Now),
    (N'T072-B-CLOSED',    @B, @Received, @Closed, 300, 300, @Line, @App, @Now);
GO

-- ---- Available excludes Closed / Open / blocking, includes descendants ----
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
CREATE TABLE #R (ItemLocationId BIGINT, ItemId BIGINT, Description NVARCHAR(500), Available INT,
                 MaxQuantity INT, MinQuantity INT, RowLocationCode NVARCHAR(50), LineLocationCode NVARCHAR(50));
INSERT INTO #R EXEC Parts.ItemLocation_ListConsumptionForLine @LocationId = @Term;
DELETE FROM #R WHERE Description NOT LIKE N'T072 %';

DECLARE @S NVARCHAR(40);
SET @S = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[ConsumptionForLine v1.2] both parts listed', @Expected = N'2', @Actual = @S;
SET @S = ISNULL((SELECT CAST(Available AS NVARCHAR(10)) FROM #R WHERE Description = N'T072 mixed statuses'), N'<missing>');
EXEC test.Assert_IsEqual @TestName = N'[ConsumptionForLine v1.2] Available 57: Good at line + terminal; Closed, Open, Hold excluded', @Expected = N'57', @Actual = @S;
SET @S = ISNULL((SELECT CAST(Available AS NVARCHAR(10)) FROM #R WHERE Description = N'T072 closed only'), N'<missing>');
EXEC test.Assert_IsEqual @TestName = N'[ConsumptionForLine v1.2] closed-only part still listed with Available 0', @Expected = N'0', @Actual = @S;
DROP TABLE #R;
GO

-- ---- cleanup ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'T072-%';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber LIKE N'T072-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T072-%';
GO

EXEC test.EndTestFile;
GO
