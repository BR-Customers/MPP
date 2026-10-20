-- =============================================
-- File:        0112_ReworkReturn/030_pending_rule.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 5, Task 3 -- Lots.ufn_NextPendingRouteStep v1.2: an
--              Advance step is re-armed after a trim rework. A step at or above the
--              rework's ReEntrySequenceNumber counts as done only by a ProductionEvent
--              recorded at/after the rework started; steps below the re-entry point
--              keep the old rule. A LOT with no rework is unchanged.
--              v1.3 (final review I-1, ruling: the latest rework LOWERS the LOT's
--              effective entry point): L4 used to pin "a rework re-arms nothing below
--              EntryRouteSequence" with a hand-inserted LotRework row. It now drives a
--              cutover LOT (entry = MachiningIn) THROUGH Lot_MoveToValidated with an
--              override, and expects the opposite: the rework re-enters at TrimIn, the
--              LOT is on the Trim queue, and a TrimIn checkpoint + Trim OUT close it.
--              Fixture: item 12232-59B-0000 (DieCast > TrimIn > TrimOut > MachiningIn >
--              AssemblyOut), trim shop TRIM1. LOTs named TEST-RWP-%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0112_ReworkReturn/030_pending_rule.sql';
GO
-- ---- teardown (FK-safe) ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-RWP-%';
DELETE FROM Lots.LotRework WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.VendorReturn WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
GO

DECLARE @App   BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Sup   BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Id <> @App AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Item  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12232-59B-0000');
DECLARE @Dest  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Rt    BIGINT = (SELECT TOP 1 Id FROM Parts.RouteTemplate WHERE ItemId = @Item AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL ORDER BY VersionNumber DESC);
DECLARE @Safe  BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE l.DeprecatedAt IS NULL AND d.IsProductionDestination = 0 AND l.Id <> @Dest
      AND EXISTS (SELECT 1 FROM Location.ufn_AncestorLocationIds(l.Id) a
                  JOIN Parts.v_EffectiveItemLocation e ON e.LocationId = a.LocationId AND e.ItemId = @Item)
    ORDER BY l.Id);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @otIn  BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimIn');
DECLARE @otOut BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimOut');
DECLARE @otMac BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'MachiningIn');
DECLARE @TrimSeq INT = (SELECT rs.SequenceNumber FROM Parts.RouteStep rs WHERE rs.RouteTemplateId = @Rt AND rs.OperationTemplateId = @otIn);
DECLARE @MacSeq  INT = (SELECT rs.SequenceNumber FROM Parts.RouteStep rs WHERE rs.RouteTemplateId = @Rt AND rs.OperationTemplateId = @otMac);
DECLARE @n NVARCHAR(600);
DECLARE @e NVARCHAR(600);
DECLARE @L BIGINT;
DECLARE @Lc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @Mv TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @Te TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @Q  TABLE (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3),
    NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);

SET @n = CASE WHEN @Item IS NOT NULL AND @Dest IS NOT NULL AND @Safe IS NOT NULL AND @Sup IS NOT NULL
               AND @otIn IS NOT NULL AND @otOut IS NOT NULL AND @otMac IS NOT NULL AND @TrimSeq IS NOT NULL AND @MacSeq IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Pending] fixture: item, route, trim shop, a non-production location, a second user', @Expected = N'ok', @Actual = @n;

-- =====================================================================
-- L2: never-reworked twin, trimmed first pass (TrimIn + TrimOut events)
-- =====================================================================
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-RWP-2';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L2 BIGINT = @L;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId) VALUES (@L2, @otIn, SYSUTCDATETIME(), @App), (@L2, @otOut, SYSUTCDATETIME(), @App);
SET @n = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@L2));
EXEC test.Assert_IsEqual @TestName = N'[Pending] LOT with no rework rows: next pending unchanged (MachiningIn)', @Expected = N'MachiningIn', @Actual = @n;

-- =====================================================================
-- L1: trimmed first pass, then override move back into trim (rework opens)
-- =====================================================================
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-RWP-1';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L1 BIGINT = @L;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId) VALUES (@L1, @otIn, SYSUTCDATETIME(), @App), (@L1, @otOut, SYSUTCDATETIME(), @App);
WAITFOR DELAY '00:00:00.050';
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L1, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[Pending] fixture: override move back into trim succeeds', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L1 AND CompletedAt IS NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Pending] fixture: the rework is open', @Expected = N'1', @Actual = @n;

-- (gap 1) the reworked LOT is listed in the Trim queue
INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Dest, @OperationTypeCode = N'TrimIn', @IncludeDescendants = 0;
SET @n = CAST((SELECT COUNT(*) FROM @Q WHERE Id = @L1) AS NVARCHAR(10)); DELETE FROM @Q;
EXEC test.Assert_IsEqual @TestName = N'[Pending] reworked LOT is listed in the Trim queue after the override move', @Expected = N'1', @Actual = @n;
SET @n = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@L1));
EXEC test.Assert_IsEqual @TestName = N'[Pending] reworked LOT next pending = TrimIn', @Expected = N'TrimIn', @Actual = @n;
INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Dest, @OperationTypeCode = N'TrimIn', @IncludeDescendants = 0;
SET @n = CAST((SELECT COUNT(*) FROM @Q WHERE Id = @L1 AND NextOperationTypeCode = N'TrimIn') AS NVARCHAR(10)); DELETE FROM @Q;
EXEC test.Assert_IsEqual @TestName = N'[Pending] reworked LOT listed by Lot_GetWipQueueByLocation for the trim area, TrimIn', @Expected = N'1', @Actual = @n;
SET @n = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@L2));
EXEC test.Assert_IsEqual @TestName = N'[Pending] twin still MachiningIn while the reworked LOT is re-armed', @Expected = N'MachiningIn', @Actual = @n;

-- after the TrimIn checkpoint, next pending = TrimOut
INSERT INTO @Te EXEC Workorder.ProductionEvent_Record @LotId = @L1, @OperationTemplateId = @otIn, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Te; DELETE FROM @Te;
EXEC test.Assert_IsEqual @TestName = N'[Pending] fixture: TrimIn checkpoint recorded during the rework', @Expected = N'1', @Actual = @n;
SET @n = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@L1));
EXEC test.Assert_IsEqual @TestName = N'[Pending] after TrimIn checkpoint, next pending = TrimOut', @Expected = N'TrimOut', @Actual = @n;

-- =====================================================================
-- L3: already picked at Machining IN, then reworked; re-run Trim IN + OUT
-- =====================================================================
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-RWP-3';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L3 BIGINT = @L;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId) VALUES (@L3, @otIn, SYSUTCDATETIME(), @App), (@L3, @otOut, SYSUTCDATETIME(), @App), (@L3, @otMac, SYSUTCDATETIME(), @App);
WAITFOR DELAY '00:00:00.050';
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L3, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[Pending] fixture: override move of a machined LOT back into trim succeeds', @Expected = N'1', @Actual = @n;
SET @n = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@L3));
EXEC test.Assert_IsEqual @TestName = N'[Pending] machined-then-reworked LOT: next pending = TrimIn', @Expected = N'TrimIn', @Actual = @n;
WAITFOR DELAY '00:00:00.050';
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId) VALUES (@L3, @otIn, SYSUTCDATETIME(), @App), (@L3, @otOut, SYSUTCDATETIME(), @App);
SET @n = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@L3));
EXEC test.Assert_IsEqual @TestName = N'[Pending] after re-run Trim OUT, next pending = MachiningIn (the old pick no longer counts)', @Expected = N'MachiningIn', @Actual = @n;
INSERT INTO @Q EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId = @Safe;
SET @n = CAST((SELECT COUNT(*) FROM @Q WHERE Id = @L3) AS NVARCHAR(10)); DELETE FROM @Q;
EXEC test.Assert_IsEqual @TestName = N'[Pending] ...and it is listed by Lot_GetTrimStorageQueueForLine', @Expected = N'1', @Actual = @n;

-- =====================================================================
-- L4: entered mid-way at cutover (EntryRouteSequence = MachiningIn), then a
-- supervisor override move back into trim. Ruling (I-1): the rework LOWERS the
-- effective entry point to TrimIn, so the rework can be worked and closed.
-- (Before v1.3 this case expected MachiningIn -- the rework re-armed nothing
-- below entry -- which left a rework no screen could ever close.)
-- =====================================================================
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-RWP-4';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L4 BIGINT = @L;
UPDATE Lots.Lot SET EntryRouteSequence = @MacSeq WHERE Id = @L4;
SET @n = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@L4));
EXEC test.Assert_IsEqual @TestName = N'[Pending] fixture: entry above TrimIn -> next pending = MachiningIn', @Expected = N'MachiningIn', @Actual = @n;
INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Dest, @OperationTypeCode = N'TrimIn', @IncludeDescendants = 0;
SET @n = CAST((SELECT COUNT(*) FROM @Q WHERE Id = @L4) AS NVARCHAR(10)); DELETE FROM @Q;
EXEC test.Assert_IsEqual @TestName = N'[Pending] cutover LOT: not on the Trim queue before any rework', @Expected = N'0', @Actual = @n;

-- the move without an override is refused (TrimIn is behind its pending MachiningIn)
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L4, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn';
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[Pending] cutover LOT: TrimIn move without override is refused (backward)', @Expected = N'0', @Actual = @n;

-- the override move writes the rework
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L4, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[Pending] cutover LOT: override move into trim succeeds', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(ReEntrySequenceNumber)) FROM Lots.LotRework WHERE LotId = @L4 AND CompletedAt IS NULL);
SET @e = CONCAT(N'1|', @TrimSeq);
EXEC test.Assert_IsEqual @TestName = N'[Pending] cutover LOT: one open rework re-entering at TrimIn', @Expected = @e, @Actual = @n;

-- the rework lowers the effective entry point: next pending = TrimIn, on the Trim queue
SET @n = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@L4));
EXEC test.Assert_IsEqual @TestName = N'[Pending] cutover LOT reworked: next pending = TrimIn (rework lowers the entry point)', @Expected = N'TrimIn', @Actual = @n;
INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Dest, @OperationTypeCode = N'TrimIn', @IncludeDescendants = 0;
SET @n = CAST((SELECT COUNT(*) FROM @Q WHERE Id = @L4 AND NextOperationTypeCode = N'TrimIn') AS NVARCHAR(10)); DELETE FROM @Q;
EXEC test.Assert_IsEqual @TestName = N'[Pending] cutover LOT reworked: listed in the Trim queue as TrimIn', @Expected = N'1', @Actual = @n;

-- TrimIn checkpoint -> next pending TrimOut
INSERT INTO @Te EXEC Workorder.ProductionEvent_Record @LotId = @L4, @OperationTemplateId = @otIn, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Te; DELETE FROM @Te;
EXEC test.Assert_IsEqual @TestName = N'[Pending] cutover LOT reworked: TrimIn checkpoint recorded', @Expected = N'1', @Actual = @n;
SET @n = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@L4));
EXEC test.Assert_IsEqual @TestName = N'[Pending] cutover LOT reworked: after TrimIn, next pending = TrimOut', @Expected = N'TrimOut', @Actual = @n;

-- Trim OUT closes the rework -> next pending MachiningIn
INSERT INTO @Te EXEC Workorder.TrimOut_Record @ParentLotId = @L4, @OperationTemplateId = @otOut, @ShotCount = 20, @SourceLocationId = @Dest, @AppUserId = @App;
SELECT @n = CONCAT(CAST(Status AS NVARCHAR(5)), N' ', Message) FROM @Te; DELETE FROM @Te;
SET @n = LEFT(@n, 1);
EXEC test.Assert_IsEqual @TestName = N'[Pending] cutover LOT reworked: Trim OUT recorded', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L4 AND CompletedAt IS NOT NULL AND CompletedProductionEventId IS NOT NULL) AS NVARCHAR(10))
       + N'|' + CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L4 AND CompletedAt IS NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Pending] cutover LOT reworked: Trim OUT closes the rework (1 closed, 0 open)', @Expected = N'1|0', @Actual = @n;
SET @n = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@L4));
EXEC test.Assert_IsEqual @TestName = N'[Pending] cutover LOT reworked: after Trim OUT, next pending = MachiningIn', @Expected = N'MachiningIn', @Actual = @n;
GO

-- ---- teardown ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-RWP-%';
DELETE FROM Lots.LotRework WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.VendorReturn WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
GO

EXEC test.EndTestFile;
GO
