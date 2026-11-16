-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/140_Lot_GetInProcessByLocation.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-16
-- Description:  Pins the result set of Oee.Lot_GetInProcessByLocation (the
--               Shift-end Summary "in-process LOTs at this Cell" list) so the
--               v1.1 performance rewrite (per-LOT ConsumptionEvent sums instead
--               of joining Lots.v_LotDerivedQuantities) is provably identical to
--               v1.0. Passes on both versions.
--                 * status filter: Good + Hold listed; Scrap + Closed not
--                 * InProcessPieceCount = v_LotDerivedQuantities.TotalInProcess
--                   (produced-into minus consumed-from, incl. a NULL-produced
--                   consumption and a negative net)
--                 * ArrivedAtEt = latest move INTO this Location (a later move
--                   to another Location is ignored), converted UTC -> Eastern
--                 * order: ArrivedAt DESC, then LotId ASC on a tie
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/140_Lot_GetInProcessByLocation.sql';
GO

IF OBJECT_ID(N'tempdb..#IpFix') IS NOT NULL DROP TABLE #IpFix;
CREATE TABLE #IpFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO

-- ---- fixture: five LOTs at one Cell, one per status case ----
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
ORDER BY eil.LocationId, eil.ItemId;
DECLARE @OtherLoc BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE Id <> @CellId ORDER BY Id);

INSERT INTO #IpFix (Tag, Val) VALUES (N'CELL', @CellId), (N'ITEM', @ItemId), (N'OTHER', @OtherLoc);

DECLARE @Tags TABLE (Seq INT PRIMARY KEY, Tag NVARCHAR(20));
INSERT INTO @Tags VALUES (1, N'A'), (2, N'B'), (3, N'C'), (4, N'D'), (5, N'E');
DECLARE @i INT = 1, @Tag NVARCHAR(20);
DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
WHILE @i <= 5
BEGIN
    SET @Tag = (SELECT Tag FROM @Tags WHERE Seq = @i);
    DELETE FROM @cr;
    INSERT INTO @cr EXEC Lots.Lot_Create
        @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
        @PieceCount = 50, @AppUserId = 1;
    INSERT INTO #IpFix (Tag, Val) SELECT @Tag, NewId FROM @cr;
    SET @i += 1;
END

DECLARE @A BIGINT = (SELECT Val FROM #IpFix WHERE Tag = N'A');
DECLARE @B BIGINT = (SELECT Val FROM #IpFix WHERE Tag = N'B');
DECLARE @C BIGINT = (SELECT Val FROM #IpFix WHERE Tag = N'C');
DECLARE @D BIGINT = (SELECT Val FROM #IpFix WHERE Tag = N'D');
DECLARE @E BIGINT = (SELECT Val FROM #IpFix WHERE Tag = N'E');

-- statuses: A,B Good (as created); C Hold; D Scrap; E Closed
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold')   WHERE Id = @C;
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Scrap')  WHERE Id = @D;
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed') WHERE Id = @E;

-- arrivals (later than the create-time move): B newest; A and C tie -> LotId ASC.
-- A also moves to another Location later still; that move must be ignored.
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES
    (@A, @OtherLoc, @CellId,  1, '2030-01-01T10:00:00'),
    (@B, @OtherLoc, @CellId,  1, '2030-01-01T12:00:00'),
    (@C, @OtherLoc, @CellId,  1, '2030-01-01T10:00:00'),
    (@A, @CellId,   @OtherLoc, 1, '2030-01-02T09:00:00');

-- consumption: B gets 40 produced into it and 7 consumed out (net 33);
-- C has 5 consumed out into E (net -5); A has none (net 0).
INSERT INTO Workorder.ConsumptionEvent (SourceLotId, ProducedLotId, ConsumedItemId, ProducedItemId, PieceCount, LocationId, AppUserId, ConsumedAt) VALUES
    (@D, @B,   @ItemId, @ItemId, 40, @CellId, 1, '2030-01-01T11:00:00'),
    (@B, NULL, @ItemId, @ItemId,  7, @CellId, 1, '2030-01-01T11:30:00'),
    (@C, @E,   @ItemId, @ItemId,  5, @CellId, 1, '2030-01-01T11:45:00');
GO

-- =============================================
-- Capture the proc output once (row order kept in Seq)
-- =============================================
IF OBJECT_ID(N'tempdb..#Ip') IS NOT NULL DROP TABLE #Ip;
CREATE TABLE #Ip (Seq INT IDENTITY(1,1) PRIMARY KEY, LotId BIGINT, LotName NVARCHAR(50), ItemCode NVARCHAR(50),
    InProcessPieceCount INT, LotStatus NVARCHAR(20), ArrivedAtEt DATETIME2(3));
DECLARE @Cell BIGINT = (SELECT Val FROM #IpFix WHERE Tag = N'CELL');
INSERT INTO #Ip (LotId, LotName, ItemCode, InProcessPieceCount, LotStatus, ArrivedAtEt)
    EXEC Oee.Lot_GetInProcessByLocation @LocationId = @Cell;
GO

-- =============================================
-- Test 1: status filter + order + quantities + ET arrival, fixture LOTs only
-- =============================================
DECLARE @S NVARCHAR(MAX) = (
    SELECT STRING_AGG(CONCAT(f.Tag, N':', r.InProcessPieceCount, N':', r.LotStatus, N':',
                             CONVERT(NVARCHAR(30), r.ArrivedAtEt, 121)), N',') WITHIN GROUP (ORDER BY r.Seq)
    FROM #Ip r INNER JOIN #IpFix f ON f.Val = r.LotId AND f.Tag IN (N'A', N'B', N'C', N'D', N'E'));
EXEC test.Assert_IsEqual
    @TestName = N'[InProcess] Good+Hold only, newest arrival first (tie by LotId), net qty, arrival in ET',
    @Expected = N'B:33:Good:2030-01-01 07:00:00.000,A:0:Good:2030-01-01 05:00:00.000,C:-5:Hold:2030-01-01 05:00:00.000',
    @Actual = @S;
GO

-- =============================================
-- Test 2: every row's quantity equals the B5 diagnostic view's TotalInProcess
-- =============================================
DECLARE @Mismatch INT = (
    SELECT COUNT(*) FROM #Ip r
    INNER JOIN Lots.v_LotDerivedQuantities dq ON dq.LotId = r.LotId
    WHERE dq.TotalInProcess <> r.InProcessPieceCount);
DECLARE @Rows INT = (SELECT COUNT(*) FROM #Ip);
DECLARE @Cond BIT = CASE WHEN @Mismatch = 0 AND @Rows >= 3 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName = N'[InProcess] InProcessPieceCount matches Lots.v_LotDerivedQuantities.TotalInProcess for every row',
    @Condition = @Cond;
GO

-- =============================================
-- Test 3: LotName / ItemCode come from the LOT and its Item
-- =============================================
DECLARE @Bad INT = (
    SELECT COUNT(*) FROM #Ip r
    INNER JOIN Lots.Lot l ON l.Id = r.LotId
    INNER JOIN Parts.Item i ON i.Id = l.ItemId
    WHERE r.LotName <> l.LotName OR r.ItemCode <> i.PartNumber);
DECLARE @Cond BIT = CASE WHEN @Bad = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[InProcess] LotName and ItemCode resolved from Lot and Item', @Condition = @Cond;
GO

-- ---- cleanup (FK-safe) ----
DECLARE @Lots TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @Lots SELECT Val FROM #IpFix WHERE Tag IN (N'A', N'B', N'C', N'D', N'E');
DELETE FROM Workorder.ConsumptionEvent WHERE SourceLotId IN (SELECT Id FROM @Lots) OR ProducedLotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @Lots) OR DescendantLotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @Lots) OR ChildLotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @Lots);
IF OBJECT_ID(N'tempdb..#Ip') IS NOT NULL DROP TABLE #Ip;
IF OBJECT_ID(N'tempdb..#IpFix') IS NOT NULL DROP TABLE #IpFix;
GO
