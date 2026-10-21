-- =============================================
-- File:        0112_ReworkReturn/040_trim_pass.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 5, Task 4 -- the trim REWORK PASS starts its own count
--              and is not shift trim production (spec 4.4):
--                * Workorder.ufn_TrimPassPreviousCount ignores checkpoints from before
--                  an open rework (TrimOut_Record v1.6 guard 7, TrimPartial_Record v1.1
--                  guard 8, TrimCheckpoint_GetLatestForLot v1.1);
--                * the rework pass's checkpoints carry ShiftId NULL, its scrap rows
--                  keep a shift, the first pass is unchanged;
--                * Trim OUT completes the rework (CompletedAt, CompletedProductionEventId,
--                  a LotReworkCompleted audit row); a plain move out of trim does not;
--                * a LOT with no rework keeps the monotonic guard.
--              Fixture: item 12232-59B-0000, trim shop TRIM1, a fixture schedule that
--              covers the whole day (so the first-pass resolver finds a shift), LOTs
--              named TEST-RWT-%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0112_ReworkReturn/040_trim_pass.sql';
GO
-- ---- teardown (FK-safe) ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-RWT-%';
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
DELETE FROM Oee.Shift WHERE Remarks = N'TEST-RWT-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST-RWT-FIXTURE-SCHED';
GO

-- A whole-day fixture schedule + today's (closed) shift row, so ufn_ShiftIdForInstant resolves.
INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST-RWT-FIXTURE-SCHED', '00:00:00', '23:59:59', 127, DATEADD(DAY, -1, CAST(SYSUTCDATETIME() AS DATE)), 1);
DECLARE @LocalToday DATETIME2(3) = CAST(CAST(CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS DATE) AS DATETIME2(3));
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES ((SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST-RWT-FIXTURE-SCHED'),
        DATEADD(MINUTE, 1, @LocalToday), DATEADD(MINUTE, 2, @LocalToday), N'TEST-RWT-FIXTURE');
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
DECLARE @Defect BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Shift BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST-RWT-FIXTURE');
DECLARE @otIn  BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimIn');
DECLARE @otOut BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimOut');
DECLARE @n NVARCHAR(600);
DECLARE @e NVARCHAR(600);
DECLARE @L BIGINT;
DECLARE @Scrap5 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Defect AS NVARCHAR(20)) + N',"quantity":5}]';
DECLARE @Scrap1 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Defect AS NVARCHAR(20)) + N',"quantity":1}]';
DECLARE @Lc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @Mv TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @Te TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @Gl TABLE (ProductionEventId BIGINT, ShotCount INT, EventAt DATETIME2(3), OperationTypeCode NVARCHAR(20), ShiftLabel NVARCHAR(200), Initials NVARCHAR(10));
DECLARE @ExpShift NVARCHAR(20) = ISNULL(CAST((SELECT TOP 1 ShiftId FROM Oee.ufn_ShiftIdForInstant(@Dest, SYSUTCDATETIME())) AS NVARCHAR(20)), N'<NULL>');

SET @n = CASE WHEN @Item IS NOT NULL AND @Dest IS NOT NULL AND @Safe IS NOT NULL AND @Sup IS NOT NULL AND @Shift IS NOT NULL
               AND @otIn IS NOT NULL AND @otOut IS NOT NULL AND @Defect IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] fixture: item, route, trim shop, a second user, a shift', @Expected = N'ok', @Actual = @n;
SET @n = CASE WHEN @ExpShift <> N'<NULL>' THEN N'ok' ELSE N'unresolved' END;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] fixture: the resolver finds a shift at TRIM1 now', @Expected = N'ok', @Actual = @n;

-- =====================================================================
-- L1: first pass 95 good + 5 scrap (LOT -> 95); override back; re-run 94 + 1 scrap
-- =====================================================================
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 100, @AppUserId = @App, @LotName = N'TEST-RWT-1';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L1 BIGINT = @L;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L1, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn';
DELETE FROM @Mv;
INSERT INTO @Te EXEC Workorder.ProductionEvent_Record @LotId = @L1, @OperationTemplateId = @otIn, @AppUserId = @App;
DELETE FROM @Te;
INSERT INTO @Te EXEC Workorder.TrimOut_Record @ParentLotId = @L1, @OperationTemplateId = @otOut, @ShotCount = 95, @ScrapLinesJson = @Scrap5, @SourceLocationId = @Dest, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Te; DELETE FROM @Te;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] fixture: first pass Trim OUT 95 + 5 scrap succeeds', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @L1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] fixture: LOT is at 95 after the first pass', @Expected = N'95', @Actual = @n;

-- first pass checkpoint carries a shift (unchanged behaviour)
SET @n = ISNULL(CAST((SELECT TOP 1 pe.ShiftId FROM Workorder.ProductionEvent pe JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
        WHERE pe.LotId = @L1 AND pe.ShotCount = 95) AS NVARCHAR(20)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] first-pass checkpoint carries a ShiftId', @Expected = @ExpShift, @Actual = @n;

-- put the first pass clearly before the rework's StartedAt
UPDATE Workorder.ProductionEvent SET EventAt = DATEADD(MINUTE, -5, EventAt) WHERE LotId = @L1;
UPDATE Workorder.RejectEvent SET RecordedAt = DATEADD(MINUTE, -5, RecordedAt) WHERE LotId = @L1;

INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L1, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] fixture: override move back into trim succeeds', @Expected = N'1', @Actual = @n;

-- the popup shows no prior count for the new pass
INSERT INTO @Gl EXEC Workorder.TrimCheckpoint_GetLatestForLot @LotId = @L1;
SET @n = CAST((SELECT COUNT(*) FROM @Gl) AS NVARCHAR(10)); DELETE FROM @Gl;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] TrimCheckpoint_GetLatestForLot returns nothing right after the rework move', @Expected = N'0', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Workorder.ufn_TrimPassPreviousCount(@L1)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] ufn_TrimPassPreviousCount is empty right after the rework move', @Expected = N'0', @Actual = @n;

INSERT INTO @Te EXEC Workorder.ProductionEvent_Record @LotId = @L1, @OperationTemplateId = @otIn, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Te; DELETE FROM @Te;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] fixture: rework TrimIn checkpoint recorded', @Expected = N'1', @Actual = @n;

-- re-run: 94 good + 1 scrap = 95 <= the LOT's 95, and 94 is NOT compared with the first pass's 95
INSERT INTO @Te EXEC Workorder.TrimOut_Record @ParentLotId = @L1, @OperationTemplateId = @otOut, @ShotCount = 94, @ScrapLinesJson = @Scrap1, @SourceLocationId = @Dest, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)), @e = CAST(NewId AS NVARCHAR(20)) FROM @Te; DELETE FROM @Te;
DECLARE @RerunPe NVARCHAR(20) = @e;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] re-run Trim OUT 94 + 1 scrap succeeds', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @L1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] re-run: LOT PieceCount 94', @Expected = N'94', @Actual = @n;
SET @n = CAST((SELECT InventoryAvailable FROM Lots.Lot WHERE Id = @L1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] re-run: LOT InventoryAvailable 94', @Expected = N'94', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent re WHERE re.LotId = @L1 AND re.Quantity = 1 AND re.ShiftId IS NOT NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] re-run: the new RejectEvent carries a ShiftId', @Expected = N'1', @Actual = @n;
SET @n = ISNULL(CAST((SELECT ShiftId FROM Workorder.ProductionEvent WHERE Id = CAST(@RerunPe AS BIGINT)) AS NVARCHAR(20)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] re-run checkpoint carries ShiftId NULL', @Expected = N'<NULL>', @Actual = @n;

-- Trim OUT completes the rework
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L1 AND CompletedAt IS NOT NULL AND CompletedProductionEventId = CAST(@RerunPe AS BIGINT)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] Trim OUT completes the rework (CompletedAt + CompletedProductionEventId)', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.ufn_OpenLotRework(@L1)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] no open rework remains', @Expected = N'0', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotEventLog WHERE LotId = @L1 AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'LotReworkCompleted')) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] a LotReworkCompleted audit row is written', @Expected = N'1', @Actual = @n;

-- =====================================================================
-- L2: partial on the re-run, then Trim OUT (monotonic within the pass)
-- =====================================================================
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 100, @AppUserId = @App, @LotName = N'TEST-RWT-2';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L2 BIGINT = @L;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L2, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn';
DELETE FROM @Mv;
INSERT INTO @Te EXEC Workorder.ProductionEvent_Record @LotId = @L2, @OperationTemplateId = @otIn, @AppUserId = @App;
DELETE FROM @Te;
INSERT INTO @Te EXEC Workorder.TrimOut_Record @ParentLotId = @L2, @OperationTemplateId = @otOut, @ShotCount = 95, @ScrapLinesJson = @Scrap5, @SourceLocationId = @Dest, @AppUserId = @App;
DELETE FROM @Te;
UPDATE Workorder.ProductionEvent SET EventAt = DATEADD(MINUTE, -5, EventAt) WHERE LotId = @L2;
UPDATE Workorder.RejectEvent SET RecordedAt = DATEADD(MINUTE, -5, RecordedAt) WHERE LotId = @L2;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L2, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
DELETE FROM @Mv;
INSERT INTO @Te EXEC Workorder.ProductionEvent_Record @LotId = @L2, @OperationTemplateId = @otIn, @AppUserId = @App;
DELETE FROM @Te;

INSERT INTO @Te EXEC Workorder.TrimPartial_Record @LotId = @L2, @OperationTemplateId = @otIn, @ShotCount = 40, @ShiftId = @Shift, @SourceLocationId = @Dest, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)), @e = CAST(NewId AS NVARCHAR(20)) FROM @Te; DELETE FROM @Te;
DECLARE @PartialPe NVARCHAR(20) = @e;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] partial on the re-run: 40 accepted (not compared with the first pass)', @Expected = N'1', @Actual = @n;
SET @n = ISNULL(CAST((SELECT ShiftId FROM Workorder.ProductionEvent WHERE Id = CAST(@PartialPe AS BIGINT)) AS NVARCHAR(20)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] partial on the re-run: checkpoint ShiftId NULL', @Expected = N'<NULL>', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.ufn_OpenLotRework(@L2)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] a partial does not complete the rework', @Expected = N'1', @Actual = @n;

INSERT INTO @Gl EXEC Workorder.TrimCheckpoint_GetLatestForLot @LotId = @L2;
SET @n = CAST((SELECT ShotCount FROM @Gl) AS NVARCHAR(10)); DELETE FROM @Gl;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] TrimCheckpoint_GetLatestForLot then returns the partial', @Expected = N'40', @Actual = @n;

INSERT INTO @Te EXEC Workorder.TrimOut_Record @ParentLotId = @L2, @OperationTemplateId = @otOut, @ShotCount = 30, @SourceLocationId = @Dest, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Te; DELETE FROM @Te;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] Trim OUT 30 after the partial 40 is refused (monotonic within the pass)', @Expected = N'0', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.ufn_OpenLotRework(@L2)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] a refused Trim OUT leaves the rework open', @Expected = N'1', @Actual = @n;

INSERT INTO @Te EXEC Workorder.TrimOut_Record @ParentLotId = @L2, @OperationTemplateId = @otOut, @ShotCount = 94, @SourceLocationId = @Dest, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Te; DELETE FROM @Te;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] partial on the re-run: then Trim OUT 94 accepted', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.LotRework WHERE LotId = @L2 AND CompletedAt IS NOT NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] partial then Trim OUT: the rework is completed', @Expected = N'1', @Actual = @n;

-- =====================================================================
-- L3: a plain move out of trim leaves the rework open (Review Focus 1)
-- =====================================================================
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 100, @AppUserId = @App, @LotName = N'TEST-RWT-3';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L3 BIGINT = @L;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L3, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn';
DELETE FROM @Mv;
INSERT INTO @Te EXEC Workorder.ProductionEvent_Record @LotId = @L3, @OperationTemplateId = @otIn, @AppUserId = @App;
DELETE FROM @Te;
INSERT INTO @Te EXEC Workorder.TrimOut_Record @ParentLotId = @L3, @OperationTemplateId = @otOut, @ShotCount = 95, @ScrapLinesJson = @Scrap5, @SourceLocationId = @Dest, @AppUserId = @App;
DELETE FROM @Te;
UPDATE Workorder.ProductionEvent SET EventAt = DATEADD(MINUTE, -5, EventAt) WHERE LotId = @L3;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L3, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
DELETE FROM @Mv;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L3, @ToLocationId = @Safe, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] fixture: plain move out of trim succeeds', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.ufn_OpenLotRework(@L3)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] plain move out of trim leaves the rework open', @Expected = N'1', @Actual = @n;

-- =====================================================================
-- L4: no rework -- guard 7 unchanged (a first-pass Trim OUT below a partial is refused)
-- =====================================================================
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 100, @AppUserId = @App, @LotName = N'TEST-RWT-4';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L4 BIGINT = @L;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L4, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn';
DELETE FROM @Mv;
INSERT INTO @Te EXEC Workorder.ProductionEvent_Record @LotId = @L4, @OperationTemplateId = @otIn, @AppUserId = @App;
DELETE FROM @Te;
INSERT INTO @Te EXEC Workorder.TrimPartial_Record @LotId = @L4, @OperationTemplateId = @otIn, @ShotCount = 60, @ShiftId = @Shift, @SourceLocationId = @Dest, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)), @e = CAST(NewId AS NVARCHAR(20)) FROM @Te; DELETE FROM @Te;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] fixture: first-pass partial 60 accepted', @Expected = N'1', @Actual = @n;
SET @n = ISNULL(CAST((SELECT ShiftId FROM Workorder.ProductionEvent WHERE Id = CAST(@e AS BIGINT)) AS NVARCHAR(20)), N'<NULL>');
SET @e = CAST(@Shift AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] no rework: partial checkpoint keeps the picked ShiftId', @Expected = @e, @Actual = @n;
INSERT INTO @Te EXEC Workorder.TrimOut_Record @ParentLotId = @L4, @OperationTemplateId = @otOut, @ShotCount = 50, @SourceLocationId = @Dest, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Te; DELETE FROM @Te;
EXEC test.Assert_IsEqual @TestName = N'[TrimPass] no rework: guard 7 unchanged (Trim OUT 50 below partial 60 refused)', @Expected = N'0', @Actual = @n;
GO

-- ---- teardown ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-RWT-%';
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
DELETE FROM Oee.Shift WHERE Remarks = N'TEST-RWT-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST-RWT-FIXTURE-SCHED';
GO

EXEC test.EndTestFile;
GO
