-- =============================================
-- File:         0070_Cutover_EntryRoute/020_EntryRouteSequence.sql
-- Description:  A casting created with EntryRouteSequence at the MachiningIn step
--               is absent from the Trim queues and present at Machining IN --
--               WITHOUT any synthetic ProductionEvent rows. Also covers the NULL
--               regression (every pre-cutover LOT behaves exactly as before) and
--               Lot_Create's new validations.
--
--               Fixture: casting 5G0-c at MA1-5GOF, route
--               DieCast(OriginMint) -> TrimIn -> TrimOut -> MachiningIn (Advance)
--               -> MachiningOut (ConsumeMint).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/020_EntryRouteSequence.sql';
GO

DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

-- The MachiningIn step's SequenceNumber on this item's active published route.
DECLARE @MinSeq INT = (SELECT rs.SequenceNumber
    FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
      AND oty.Code = N'MachiningIn');

-- Pre-flight: this file deliberately reuses a fixed LTT ('10625131'), so a run
-- that fails mid-way can strand it and block every subsequent run. Clear it by
-- NAME before starting -- the id-based teardown at the foot cannot, because a
-- failed create leaves the id NULL.
DECLARE @Stale BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'10625131');
IF @Stale IS NOT NULL
BEGIN
    DELETE FROM Lots.LotEventLog WHERE LotId = @Stale;
    DELETE FROM Lots.LotMovement WHERE LotId = @Stale;
    DELETE FROM Lots.LotStatusHistory WHERE LotId = @Stale;
    DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @Stale OR DescendantLotId = @Stale;
    DELETE FROM Lots.Lot WHERE Id = @Stale;
END

CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
CREATE TABLE #Q (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3),
    NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);

-- (1) Migrated LOT: entry point at MachiningIn, no ProductionEvents at all.
DECLARE @Mig BIGINT;
DELETE FROM #C;
-- PieceCount is 20, NOT a realistic 3298-piece basket: the 5G0-c fixture carries
-- Item.MaxLotSize = 24 and Lot_Create rightly rejects anything above it. That cap
-- is covered by 0020_PlantFloor_Foundation/041_Lot_Create_maxparts.sql; this file
-- is about the route entry point and must not entangle the two. (Real cutover
-- parts DO need caps that admit ~3000 -- that is a pre-cutover config check, not
-- a code change. See the readiness script in sql/scratch/.)
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 20, @AppUserId = @U,
    @LotName = N'10625131', @EntryRouteSequence = @MinSeq, @CastDate = '2026-08-04';
SELECT @Mig = NewId FROM #C;
DECLARE @b0 NVARCHAR(20) = CAST(@Mig AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[Entry] migrated LOT created', @Value = @b0;

DECLARE @b1 NVARCHAR(30) = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@Mig));
EXEC test.Assert_IsEqual @TestName = N'[Entry] next pending skips to MachiningIn',
    @Expected = N'MachiningIn', @Actual = @b1;

DECLARE @b2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Workorder.ProductionEvent WHERE LotId = @Mig);
EXEC test.Assert_IsEqual @TestName = N'[Entry] no synthetic events were written',
    @Expected = N'0', @Actual = @b2;

-- The scanned LTT is the LOT name verbatim -- no re-tagging.
DECLARE @b2b NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @Mig);
EXEC test.Assert_IsEqual @TestName = N'[Entry] scanned LTT is the LOT name verbatim',
    @Expected = N'10625131', @Actual = @b2b;

-- (2) Absent from the Trim queues, present at Machining IN.
DELETE FROM #Q; INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'TrimIn';
DECLARE @b3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id = @Mig);
EXEC test.Assert_IsEqual @TestName = N'[Entry] absent from TrimIn queue', @Expected = N'0', @Actual = @b3;

DELETE FROM #Q; INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'TrimOut';
DECLARE @b4 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id = @Mig);
EXEC test.Assert_IsEqual @TestName = N'[Entry] absent from TrimOut queue', @Expected = N'0', @Actual = @b4;

DELETE FROM #Q; INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'MachiningIn';
DECLARE @b5 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id = @Mig);
EXEC test.Assert_IsEqual @TestName = N'[Entry] present in MachiningIn queue', @Expected = N'1', @Actual = @b5;

-- (3) NULL EntryRouteSequence behaves exactly as before (explicit regression --
--     this is what protects every pre-cutover row in production).
DECLARE @Plain BIGINT;
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U;
SELECT @Plain = NewId FROM #C;
DECLARE @b6 NVARCHAR(30) = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@Plain));
EXEC test.Assert_IsEqual @TestName = N'[Entry] NULL entry point unchanged (TrimIn)',
    @Expected = N'TrimIn', @Actual = @b6;

-- (4) An EntryRouteSequence matching no step on the route is rejected. Without
--     this the LOT would be invisible at every terminal.
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U,
    @EntryRouteSequence = 9999;
DECLARE @b7 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[Entry] bogus EntryRouteSequence rejected',
    @Expected = N'0', @Actual = @b7;

-- (5) A future CastDate is rejected.
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U,
    @CastDate = '2099-01-01';
DECLARE @b8 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[Entry] future CastDate rejected',
    @Expected = N'0', @Actual = @b8;

-- (6) A duplicate LTT is rejected with a readable message naming the tag (the
--     guard already in Lot_Create), not a UQ_Lot_LotName constraint violation.
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U,
    @LotName = N'10625131';
DECLARE @b9s NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[Entry] duplicate LTT rejected',
    @Expected = N'0', @Actual = @b9s;
DECLARE @b9 NVARCHAR(500) = (SELECT Message FROM #C);
EXEC test.Assert_Contains @TestName = N'[Entry] duplicate LTT message names the tag',
    @HaystackStr = @b9, @NeedleStr = N'10625131';

-- (7) The persisted values round-trip.
DECLARE @b10 NVARCHAR(30) = (SELECT CAST(EntryRouteSequence AS NVARCHAR(10)) + N'|' + CONVERT(NVARCHAR(10), CastDate, 23)
                             FROM Lots.Lot WHERE Id = @Mig);
-- EXEC params must be literals or @variables -- never inline CAST / arithmetic.
DECLARE @b10exp NVARCHAR(30) = CAST(@MinSeq AS NVARCHAR(10)) + N'|2026-08-04';
EXEC test.Assert_IsEqual @TestName = N'[Entry] EntryRouteSequence + CastDate persisted',
    @Expected = @b10exp, @Actual = @b10;

DROP TABLE #Q; DROP TABLE #C;

-- Teardown. LotGenealogyClosure before Lot (Msg 547). Resolve the migrated LOT
-- by NAME as well as by captured id -- if an earlier assertion failed, @Mig is
-- NULL and an id-only teardown would leave the LTT behind.
IF @Mig IS NULL SET @Mig = (SELECT Id FROM Lots.Lot WHERE LotName = N'10625131');
DELETE FROM Lots.LotEventLog WHERE LotId IN (@Mig, @Plain);
DELETE FROM Lots.LotMovement WHERE LotId IN (@Mig, @Plain);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (@Mig, @Plain);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (@Mig, @Plain) OR DescendantLotId IN (@Mig, @Plain);
DELETE FROM Lots.Lot WHERE Id IN (@Mig, @Plain);
GO
