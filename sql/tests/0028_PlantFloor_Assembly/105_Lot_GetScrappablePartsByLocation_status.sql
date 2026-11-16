-- =============================================
-- File:         0028_PlantFloor_Assembly/105_Lot_GetScrappablePartsByLocation_status.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-16
-- Description:  Pins the result of Lots.Lot_GetScrappablePartsByLocation
--               across LOT statuses and quantities, so the v1.1 literal
--               predicate (LotStatusId <> 4 beside the Good test, to reach the
--               0118 filtered index) cannot change what the popup lists.
--               Passes on v1.0 and v1.1. Fixture at MA1-COMPBR-MIN:
--                 Part X (Description 'zz'): Good 12/12, Good 9/6 (lesser 6),
--                   Hold 50/50, CLOSED 40/40 (quantities left non-zero on
--                   purpose: only the status keeps it out), Good 0/0
--                 Part Y (Description NULL -> sorts by PartNumber 'P-GSP-Y'):
--                   Good 3/3
--                 Part Z: only a Closed LOT and a Good LOT elsewhere -> no row
--               Covers: Good only, closed excluded even with stock, zero-qty
--               excluded, lesser-of quantity, LotCount, other location
--               excluded, order ISNULL(Description, PartNumber), PartNumber.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/105_Lot_GetScrappablePartsByLocation_status.sql';
GO

-- ---- cleanup ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'GSPT-%';
GO

-- ---- fixture ----
DECLARE @Now    DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @Other  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Good   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Hold   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-GSP-X')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P-GSP-X', N'zz scrappable status part X', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-GSP-Y')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P-GSP-Y', NULL, 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-GSP-Z')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P-GSP-Z', N'scrappable status part Z', 1, @Now, 1);
DECLARE @X BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-GSP-X');
DECLARE @Y BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-GSP-Y');
DECLARE @Z BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-GSP-Z');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES
    (N'GSPT-X1',  @X, 1, @Good,   12, 12, @Cell,  1, @Now),
    (N'GSPT-X2',  @X, 1, @Good,    9,  6, @Cell,  1, @Now),
    (N'GSPT-XH',  @X, 1, @Hold,   50, 50, @Cell,  1, @Now),
    (N'GSPT-XC',  @X, 1, @Closed, 40, 40, @Cell,  1, @Now),
    (N'GSPT-X0',  @X, 1, @Good,    0,  0, @Cell,  1, @Now),
    (N'GSPT-Y1',  @Y, 1, @Good,    3,  3, @Cell,  1, @Now),
    (N'GSPT-ZC',  @Z, 1, @Closed, 15, 15, @Cell,  1, @Now),
    (N'GSPT-ZO',  @Z, 1, @Good,   15, 15, @Other, 1, @Now);
GO

-- =============================================
-- Test: one row per part with Good stock; closed / held / empty / elsewhere out
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
CREATE TABLE #P (Seq INT IDENTITY(1,1), ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), QuantityAvailable INT, LotCount INT);
INSERT INTO #P (ItemId, PartNumber, Description, QuantityAvailable, LotCount)
    EXEC Lots.Lot_GetScrappablePartsByLocation @LocationId = @Cell;

DECLARE @Rows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #P WHERE PartNumber LIKE N'P-GSP-%');
EXEC test.Assert_IsEqual @TestName = N'[GspStatus] two parts listed (Z has only closed stock here)', @Expected = N'2', @Actual = @Rows;

DECLARE @QtyX NVARCHAR(10) = (SELECT CAST(QuantityAvailable AS NVARCHAR(10)) FROM #P WHERE PartNumber = N'P-GSP-X');
EXEC test.Assert_IsEqual @TestName = N'[GspStatus] X qty = 12 + lesser(9,6) = 18 (held, closed, empty out)', @Expected = N'18', @Actual = @QtyX;
DECLARE @CntX NVARCHAR(10) = (SELECT CAST(LotCount AS NVARCHAR(10)) FROM #P WHERE PartNumber = N'P-GSP-X');
EXEC test.Assert_IsEqual @TestName = N'[GspStatus] X LotCount = 2', @Expected = N'2', @Actual = @CntX;
DECLARE @QtyY NVARCHAR(10) = (SELECT CAST(QuantityAvailable AS NVARCHAR(10)) + N'/' + CAST(LotCount AS NVARCHAR(10)) FROM #P WHERE PartNumber = N'P-GSP-Y');
EXEC test.Assert_IsEqual @TestName = N'[GspStatus] Y qty/LotCount = 3/1', @Expected = N'3/1', @Actual = @QtyY;
DECLARE @RowZ NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #P WHERE PartNumber = N'P-GSP-Z');
EXEC test.Assert_IsEqual @TestName = N'[GspStatus] Z not listed (closed here, Good only elsewhere)', @Expected = N'0', @Actual = @RowZ;

-- order: Y sorts by PartNumber 'P-GSP-Y', which is before X's Description 'zz...'
DECLARE @Order NVARCHAR(200) = (SELECT STRING_AGG(PartNumber, N',') WITHIN GROUP (ORDER BY Seq) FROM #P WHERE PartNumber LIKE N'P-GSP-%');
EXEC test.Assert_IsEqual @TestName = N'[GspStatus] order ISNULL(Description, PartNumber)', @Expected = N'P-GSP-Y,P-GSP-X', @Actual = @Order;
DROP TABLE #P;
GO

-- ---- cleanup ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'GSPT-%';
GO

EXEC test.EndTestFile;
GO
