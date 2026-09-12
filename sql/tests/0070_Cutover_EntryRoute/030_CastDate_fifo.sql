-- =============================================
-- File:         0070_Cutover_EntryRoute/030_CastDate_fifo.sql
-- Description:  Migrated stock consumes oldest-CAST-first, not oldest-arrived.
--               Two LOTs are created in an order that makes LotMovement.MovedAt
--               the OPPOSITE of true age; CastDate must win. A NULL CastDate
--               keeps arrival ordering, which is every pre-cutover LOT.
--
--               Queue position is captured with an IDENTITY column on the temp
--               table -- reading a heap back without ORDER BY does not guarantee
--               insertion order, so ROW_NUMBER() OVER (ORDER BY (SELECT 1)) is
--               not a sound way to assert "what position did the proc return".
--
--               Fixture 5G0-c carries Item.MaxLotSize = 24, so piece counts here
--               are small; that cap is exercised in 0020/041, not here.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/030_CastDate_fifo.sql';
GO

DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MinSeq INT = (SELECT rs.SequenceNumber
    FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
      AND oty.Code = N'MachiningIn');

-- Pre-flight: clear stranded fixtures from any earlier failed run (by NAME --
-- a failed create leaves the id NULL and an id-only teardown cannot reach it).
DECLARE @StaleIds TABLE (Id BIGINT);
INSERT INTO @StaleIds SELECT Id FROM Lots.Lot WHERE LotName IN (N'CASTFIFO-NEW', N'CASTFIFO-OLD');
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @StaleIds);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @StaleIds);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @StaleIds);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @StaleIds)
                                        OR DescendantLotId IN (SELECT Id FROM @StaleIds);
DELETE FROM Lots.Lot                WHERE Id IN (SELECT Id FROM @StaleIds);

CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- Created FIRST (so it has the EARLIER LotMovement) but cast LATER.
DECLARE @Newer BIGINT;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U,
    @LotName = N'CASTFIFO-NEW', @EntryRouteSequence = @MinSeq, @CastDate = '2026-08-20';
SELECT @Newer = NewId FROM #C;
DECLARE @g0 NVARCHAR(20) = CAST(@Newer AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[CastDate] later-cast LOT created', @Value = @g0;

-- Created SECOND (LATER LotMovement) but cast EARLIER. This one must sort first.
DECLARE @Older BIGINT;
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U,
    @LotName = N'CASTFIFO-OLD', @EntryRouteSequence = @MinSeq, @CastDate = '2026-08-01';
SELECT @Older = NewId FROM #C;
DECLARE @g0b NVARCHAR(20) = CAST(@Older AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[CastDate] earlier-cast LOT created', @Value = @g0b;

-- Sanity: arrival order really is the OPPOSITE of cast order, so the assertion
-- below cannot pass by accident.
DECLARE @ArrivalOpposite NVARCHAR(10) = (
    SELECT CASE WHEN (SELECT MAX(MovedAt) FROM Lots.LotMovement WHERE LotId = @Newer)
                   < (SELECT MAX(MovedAt) FROM Lots.LotMovement WHERE LotId = @Older)
                THEN N'1' ELSE N'0' END);
EXEC test.Assert_IsEqual @TestName = N'[CastDate] fixture: arrival order is the inverse of cast order',
    @Expected = N'1', @Actual = @ArrivalOpposite;

-- IDENTITY captures the order the proc actually returned.
CREATE TABLE #Q (Ord INT IDENTITY(1,1), Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT,
    ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), PieceCount INT,
    LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3),
    NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);

INSERT INTO #Q (Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount,
                LotStatusId, LotStatusCode, LastMovementAt, NextOperationTypeCode, NextSequenceNumber)
EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'MachiningIn';

DECLARE @PosOld INT = (SELECT Ord FROM #Q WHERE Id = @Older);
DECLARE @PosNew INT = (SELECT Ord FROM #Q WHERE Id = @Newer);
DECLARE @g1 NVARCHAR(10) = CASE WHEN @PosOld < @PosNew THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[CastDate] earlier cast date sorts ahead of later cast date',
    @Expected = N'1', @Actual = @g1;

-- A NULL CastDate still orders by arrival: this one arrives last and must land
-- behind both migrated LOTs.
DECLARE @Plain BIGINT;
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U,
    @EntryRouteSequence = @MinSeq;
SELECT @Plain = NewId FROM #C;

DELETE FROM #Q;
INSERT INTO #Q (Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount,
                LotStatusId, LotStatusCode, LastMovementAt, NextOperationTypeCode, NextSequenceNumber)
EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'MachiningIn';

DECLARE @PosPlain INT = (SELECT Ord FROM #Q WHERE Id = @Plain);
DECLARE @PosOld2  INT = (SELECT Ord FROM #Q WHERE Id = @Older);
DECLARE @PosNew2  INT = (SELECT Ord FROM #Q WHERE Id = @Newer);
DECLARE @g2 NVARCHAR(10) = CASE WHEN @PosOld2 < @PosPlain AND @PosNew2 < @PosPlain THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[CastDate] NULL CastDate orders by arrival, behind migrated stock',
    @Expected = N'1', @Actual = @g2;

-- MachiningOut_Mint's FIFO walk must agree with the queue the operator sees.
-- Same ordering expression, asserted through the queue the mint mirrors.
DECLARE @g3 NVARCHAR(50) = (SELECT TOP 1 LotName FROM #Q ORDER BY Ord);
EXEC test.Assert_IsEqual @TestName = N'[CastDate] head of the queue is the oldest-cast LOT',
    @Expected = N'CASTFIFO-OLD', @Actual = @g3;

DROP TABLE #Q; DROP TABLE #C;

-- Teardown. LotGenealogyClosure before Lot (Msg 547); resolve by name too.
IF @Newer IS NULL SET @Newer = (SELECT Id FROM Lots.Lot WHERE LotName = N'CASTFIFO-NEW');
IF @Older IS NULL SET @Older = (SELECT Id FROM Lots.Lot WHERE LotName = N'CASTFIFO-OLD');
DELETE FROM Lots.LotEventLog WHERE LotId IN (@Newer, @Older, @Plain);
DELETE FROM Lots.LotMovement WHERE LotId IN (@Newer, @Older, @Plain);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (@Newer, @Older, @Plain);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (@Newer, @Older, @Plain)
                                        OR DescendantLotId IN (@Newer, @Older, @Plain);
DELETE FROM Lots.Lot WHERE Id IN (@Newer, @Older, @Plain);
GO
