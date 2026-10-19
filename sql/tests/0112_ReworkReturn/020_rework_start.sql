-- =============================================
-- File:        0112_ReworkReturn/020_rework_start.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 5, Task 2 -- a trim rework STARTS at the supervisor
--              override move back into Trim IN (Lots.Lot_MoveToValidated v1.2).
--                * a backward TrimIn move with an override writes ONE open
--                  Lots.LotRework row (and the movement reads "trim rework");
--                * a second override TrimIn move while open writes no second row;
--                * a forward TrimIn move, or a backward move for another operation,
--                  or a move with no override, writes nothing;
--                * a CRT LOT may be reworked (rule 6 exempt) but a plain move of a CRT
--                  LOT to a production location is still refused;
--                * a Hold LOT is still refused.
--              Fixture: item 12232-59B-0000 (DieCast > TrimIn > TrimOut > MachiningIn >
--              AssemblyOut), trim shop TRIM1. LOTs named TEST-RWK-%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0112_ReworkReturn/020_rework_start.sql';
GO
-- ---- teardown (FK-safe) ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-RWK-%';
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
DECLARE @SupInit NVARCHAR(10) = (SELECT Initials FROM Location.AppUser WHERE Id = @Sup);
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
DECLARE @Defect BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @otIn  BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimIn');
DECLARE @otOut BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimOut');
DECLARE @otMac BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'MachiningIn');
DECLARE @TrimSeq INT = (SELECT rs.SequenceNumber FROM Parts.RouteStep rs WHERE rs.RouteTemplateId = @Rt AND rs.OperationTemplateId = @otIn);
DECLARE @n NVARCHAR(600);
DECLARE @e NVARCHAR(600);
DECLARE @m NVARCHAR(500);
DECLARE @L BIGINT;
DECLARE @Lc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @Mv TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @Te TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);

SET @n = CASE WHEN @Item IS NOT NULL AND @Dest IS NOT NULL AND @Safe IS NOT NULL AND @Sup IS NOT NULL
               AND @otIn IS NOT NULL AND @otOut IS NOT NULL AND @otMac IS NOT NULL AND @TrimSeq IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] fixture: item, route, trim shop, a non-production location, a second user', @Expected = N'ok', @Actual = @n;
-- (informational) whether TRIM1 is a production destination is what makes the CRT cases bite
DECLARE @DestIsProd NVARCHAR(5) = (SELECT CAST(d.IsProductionDestination AS NVARCHAR(5)) FROM Location.Location l JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId WHERE l.Id = @Dest);
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] fixture: TRIM1 is a production destination (so the CRT rule applies to it)', @Expected = N'1', @Actual = @DestIsProd;

-- =====================================================================
-- L1: a 100-piece LOT trimmed first-pass (TrimIn checkpoint, TrimOut 95 + 5 scrap)
-- =====================================================================
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 100, @AppUserId = @App, @LotName = N'TEST-RWK-1';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L1 BIGINT = @L;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L1, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn';
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] fixture: first-pass move into trim succeeds', @Expected = N'1', @Actual = @n;
INSERT INTO @Te EXEC Workorder.ProductionEvent_Record @LotId = @L1, @OperationTemplateId = @otIn, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Te; DELETE FROM @Te;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] fixture: TrimIn checkpoint recorded', @Expected = N'1', @Actual = @n;
DECLARE @Scrap NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Defect AS NVARCHAR(20)) + N',"quantity":5}]';
INSERT INTO @Te EXEC Workorder.TrimOut_Record @ParentLotId = @L1, @OperationTemplateId = @otOut, @ShotCount = 95, @ScrapLinesJson = @Scrap, @SourceLocationId = @Dest, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Te; DELETE FROM @Te;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] fixture: TrimOut recorded (95 + 5 scrap)', @Expected = N'1', @Actual = @n;

-- ---- reproduce: the override move back into trim succeeds today ----
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L1, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] reproduce: override move back into trim succeeds today', @Expected = N'1', @Actual = @n;

SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] override TrimIn backward move writes one LotRework', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT ReEntrySequenceNumber FROM Lots.LotRework WHERE LotId = @L1) AS NVARCHAR(10));
SET @e = CAST(@TrimSeq AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] ReEntrySequenceNumber = the route''s TrimIn sequence', @Expected = @e, @Actual = @n;
SET @n = CAST((SELECT ApprovedByUserId FROM Lots.LotRework WHERE LotId = @L1) AS NVARCHAR(20));
SET @e = CAST(@Sup AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] ApprovedByUserId = the override user', @Expected = @e, @Actual = @n;
SET @n = CAST((SELECT MovedByUserId FROM Lots.LotRework WHERE LotId = @L1) AS NVARCHAR(20));
SET @e = CAST(@App AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] MovedByUserId = the caller', @Expected = @e, @Actual = @n;
SET @n = CAST((SELECT LotMovementId FROM Lots.LotRework WHERE LotId = @L1) AS NVARCHAR(20));
SET @e = CAST((SELECT TOP 1 Id FROM Lots.LotMovement WHERE LotId = @L1 ORDER BY Id DESC) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] LotMovementId = the newest movement for the LOT', @Expected = @e, @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L1 AND CompletedAt IS NULL AND CompletedProductionEventId IS NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] the rework is open', @Expected = N'1', @Actual = @n;
SET @n = (SELECT TOP 1 Description FROM Lots.LotEventLog WHERE LotId = @L1 AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'LotMoved') ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[RwkStart] audit reads as a trim rework', @HaystackStr = @n, @NeedleStr = N'trim rework';
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotEventLog WHERE LotId = @L1 AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'LotReworkStarted')) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] a LotReworkStarted audit row is written', @Expected = N'1', @Actual = @n;

-- ---- second override move while open (move out plainly, override back in) ----
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L1, @ToLocationId = @Safe, @AppUserId = @App;
DELETE FROM @Mv;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L1, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] second override move while open: the move succeeds', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] second override move while open: still one rework row', @Expected = N'1', @Actual = @n;

-- ---- no override: still blocked (L1 has advanced past TrimIn only if it is not mid-rework; use a fresh LOT) ----
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-RWK-2';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L2 BIGINT = @L;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId) VALUES (@L2, @otIn, SYSUTCDATETIME(), @App), (@L2, @otOut, SYSUTCDATETIME(), @App);
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L2, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn';
SELECT @n = CAST(Status AS NVARCHAR(5)), @m = Message FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] no override: still blocked', @Expected = N'0', @Actual = @n;
SET @n = LEFT(@m, 21);
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] no override: message starts "Backward move blocked"', @Expected = N'Backward move blocked', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L2) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] no override: no rework row', @Expected = N'0', @Actual = @n;

-- ---- forward TrimIn move with an override supplied writes no rework (fresh, never trimmed) ----
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-RWK-3';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L3 BIGINT = @L;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L3, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] forward TrimIn move with an override: succeeds', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L3) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] forward TrimIn move with an override: no rework row', @Expected = N'0', @Actual = @n;

-- ---- backward move for another operation (MachiningIn, past it) writes no rework ----
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-RWK-4';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L4 BIGINT = @L;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId) VALUES (@L4, @otIn, SYSUTCDATETIME(), @App), (@L4, @otOut, SYSUTCDATETIME(), @App), (@L4, @otMac, SYSUTCDATETIME(), @App);
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L4, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'MachiningIn', @OverrideAppUserId = @Sup;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] backward MachiningIn move with an override: succeeds', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L4) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] backward move for another operation writes no rework', @Expected = N'0', @Actual = @n;

-- ---- an unknown override user is refused ----
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-RWK-5';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L5 BIGINT = @L;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId) VALUES (@L5, @otIn, SYSUTCDATETIME(), @App), (@L5, @otOut, SYSUTCDATETIME(), @App);
DECLARE @Ghost BIGINT = 999999999;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L5, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Ghost;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] a non-existent override user is refused', @Expected = N'0', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L5) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] a refused override writes no rework', @Expected = N'0', @Actual = @n;

-- ---- CRT LOT: the override rework move into trim succeeds; a plain move to production is still refused ----
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-RWK-6';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L6 BIGINT = @L;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId) VALUES (@L6, @otIn, SYSUTCDATETIME(), @App), (@L6, @otOut, SYSUTCDATETIME(), @App);
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @L6;

INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L6, @ToLocationId = @Dest, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)), @m = Message FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] CRT LOT: plain move to a production location still refused', @Expected = N'0', @Actual = @n;
EXEC test.Assert_Contains @TestName = N'[RwkStart] CRT LOT: the refusal names CRT', @HaystackStr = @m, @NeedleStr = N'marked CRT';

INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L6, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
SELECT @n = CAST(Status AS NVARCHAR(5)), @m = Message FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] CRT LOT: override rework move into trim succeeds', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L6) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] CRT LOT: the rework row is written', @Expected = N'1', @Actual = @n;

-- second override TrimIn move on the CRT LOT while open (R1): out to a safe location, override back in
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L6, @ToLocationId = @Safe, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] CRT LOT: fixture: moved out to a safe location', @Expected = N'1', @Actual = @n;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L6, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] CRT LOT: second override TrimIn move during an open rework succeeds', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L6) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] CRT LOT: still one rework row after the second move', @Expected = N'1', @Actual = @n;

-- ---- Hold LOT: the override move is still refused ----
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-RWK-7';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L7 BIGINT = @L;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId) VALUES (@L7, @otIn, SYSUTCDATETIME(), @App), (@L7, @otOut, SYSUTCDATETIME(), @App);
INSERT INTO @Te EXEC Quality.Hold_Place @LotId = @L7, @HoldTypeCodeId = 1, @Reason = N'rework start test', @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Te; DELETE FROM @Te;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] fixture: hold placed', @Expected = N'1', @Actual = @n;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L7, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] Hold LOT: override move still refused', @Expected = N'0', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L7) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[RwkStart] Hold LOT: no rework row', @Expected = N'0', @Actual = @n;
GO

-- ---- teardown ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-RWK-%';
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
