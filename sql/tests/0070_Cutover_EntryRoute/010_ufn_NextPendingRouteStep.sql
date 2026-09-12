-- =============================================
-- File:         0070_Cutover_EntryRoute/010_ufn_NextPendingRouteStep.sql
-- Description:  Tests for Lots.ufn_NextPendingRouteStep -- the extracted
--               next-pending-route-step predicate (Phase A, behaviour-neutral).
--               Fixture: casting 5G0-c, whose published route is
--                 1 DieCast     OriginMint
--                 2 TrimIn      Advance
--                 3 TrimOut     Advance
--                 4 MachiningIn Advance
--                 5 MachiningOut ConsumeMint
--               line-resident at MA1-5GOF.
--
--               The function answers ONLY the route question -- it does not
--               filter by LOT status or location, because those predicates
--               differ per caller (Lot_GetWipQueueByLocation excludes Closed AND
--               Open; its siblings exclude only Closed). Test (5) pins that.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/010_ufn_NextPendingRouteStep.sql';
GO

DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

DECLARE @Lot BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U;
SELECT @Lot = NewId FROM #C; DROP TABLE #C;

-- (1) A fresh LOT: DieCast is OriginMint (never pending), so the next pending
--     step is TrimIn.
DECLARE @a1 NVARCHAR(30) = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@Lot));
EXEC test.Assert_IsEqual @TestName = N'[ufn] fresh LOT next pending = TrimIn',
    @Expected = N'TrimIn', @Actual = @a1;

-- (2) Exactly one row is ever returned.
DECLARE @a2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ufn_NextPendingRouteStep(@Lot));
EXEC test.Assert_IsEqual @TestName = N'[ufn] returns exactly one row',
    @Expected = N'1', @Actual = @a2;

-- (2b) The SequenceNumber is the TrimIn step's, not just any step's.
DECLARE @TrimInSeq NVARCHAR(10) = (SELECT CAST(rs.SequenceNumber AS NVARCHAR(10))
    FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
      AND oty.Code = N'TrimIn');
DECLARE @a2b NVARCHAR(10) = (SELECT CAST(SequenceNumber AS NVARCHAR(10)) FROM Lots.ufn_NextPendingRouteStep(@Lot));
EXEC test.Assert_IsEqual @TestName = N'[ufn] SequenceNumber is the TrimIn step',
    @Expected = @TrimInSeq, @Actual = @a2b;

-- (3) Stamp TrimIn + TrimOut -> advances to MachiningIn.
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Lot, rs.OperationTemplateId, SYSUTCDATETIME(), 10, @U
FROM Parts.RouteTemplate rt
JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
  AND oty.Code IN (N'TrimIn', N'TrimOut');

DECLARE @a3 NVARCHAR(30) = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@Lot));
EXEC test.Assert_IsEqual @TestName = N'[ufn] after Trim events next pending = MachiningIn',
    @Expected = N'MachiningIn', @Actual = @a3;

-- (4) Stamp MachiningIn -> the ConsumeMint MachiningOut step, which is
--     unconditionally pending while the LOT is open.
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Lot, rs.OperationTemplateId, SYSUTCDATETIME(), 10, @U
FROM Parts.RouteTemplate rt
JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
  AND oty.Code = N'MachiningIn';

DECLARE @a4 NVARCHAR(30) = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@Lot));
EXEC test.Assert_IsEqual @TestName = N'[ufn] ConsumeMint step stays pending while open',
    @Expected = N'MachiningOut', @Actual = @a4;

-- (5) The function does NOT filter by status: a Closed LOT still reports its
--     ConsumeMint step. Status filtering is the caller's job, and folding it in
--     here would change behaviour for the callers that filter differently.
DECLARE @ClosedId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
UPDATE Lots.Lot SET LotStatusId = @ClosedId WHERE Id = @Lot;
DECLARE @a5 NVARCHAR(30) = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@Lot));
EXEC test.Assert_IsEqual @TestName = N'[ufn] does not filter by LOT status',
    @Expected = N'MachiningOut', @Actual = @a5;

-- (6) A LOT id that does not exist returns zero rows (read contract: empty set,
--     never an invented row).
DECLARE @a6 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ufn_NextPendingRouteStep(-1));
EXEC test.Assert_IsEqual @TestName = N'[ufn] unknown LotId returns no rows',
    @Expected = N'0', @Actual = @a6;

-- Teardown. LotGenealogyClosure before Lot (Msg 547).
DELETE FROM Workorder.ProductionEvent WHERE LotId = @Lot;
DELETE FROM Lots.LotEventLog WHERE LotId = @Lot;
DELETE FROM Lots.LotMovement WHERE LotId = @Lot;
DELETE FROM Lots.LotStatusHistory WHERE LotId = @Lot;
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @Lot OR DescendantLotId = @Lot;
DELETE FROM Lots.Lot WHERE Id = @Lot;
GO
