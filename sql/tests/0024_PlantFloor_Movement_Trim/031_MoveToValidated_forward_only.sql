-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/031_MoveToValidated_forward_only.sql
-- Author:       Blue Ridge Automation
-- Description:  Forward-only route guard on Lots.Lot_MoveToValidated.
--               A validated move may carry the OPERATION it is for (@OperationTypeCode,
--               e.g. the Trim receive screen supplies 'TrimIn'). The guard rejects a
--               BACKWARD move -- one whose operation sits at a route SequenceNumber
--               BELOW the LOT's next-pending step -- unless a supervisor override is
--               supplied. A move with no operation (plain storage/hold move) is never
--               guarded.
--                 1. forward / at-position op (== next-pending) -> allowed
--                 2. backward op (< next-pending) -> rejected
--                 3. backward op + @OverrideAppUserId -> allowed (audited)
--                 4. no operation (@OperationTypeCode NULL) -> allowed (storage move)
--               Fixture item = 12232-59B-0000 (route DieCast->TrimIn->TrimOut->
--               MachiningIn->AssemblyOut), eligible at TRIM1. LOTs tagged FONLY-*.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0024_PlantFloor_Movement_Trim/031_MoveToValidated_forward_only.sql';
GO

-- ---- fixture cleanup (FK-safe: children before LOTs; closure before LOTs) ----
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'FONLY-%');
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'FONLY-%');
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'FONLY-%');
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'FONLY-%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'FONLY-%')
                                        OR DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'FONLY-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'FONLY-%';
GO

-- =============================================
-- Test 1: forward / at-position operation allowed
--   fresh LOT (no ProductionEvents) -> next-pending = TrimIn (seq 2).
--   move to TRIM1 supplying 'TrimIn' -> not backward -> allowed.
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12232-59B-0000');
DECLARE @Dest   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Start  BIGINT = (SELECT TOP 1 e.LocationId FROM Parts.v_EffectiveItemLocation e
                          WHERE e.ItemId = @ItemId AND e.LocationId <> @Dest ORDER BY e.LocationId);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @Start, @PieceCount = 20, @AppUserId = 1, @LotName = N'FONLY-1';
SELECT @L = NewId FROM #C; DROP TABLE #C;

DECLARE @S BIT;
CREATE TABLE #M (Status BIT, Message NVARCHAR(500));
INSERT INTO #M EXEC Lots.Lot_MoveToValidated @LotId = @L, @ToLocationId = @Dest, @AppUserId = 1,
    @OperationTypeCode = N'TrimIn';
SELECT @S = Status FROM #M; DROP TABLE #M;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[FwdOnly] at-position op (TrimIn) allowed', @Expected = N'1', @Actual = @SStr;
GO

-- =============================================
-- Test 2: backward operation rejected
--   LOT with TrimIn+TrimOut+MachiningIn events -> next-pending = AssemblyOut (seq 5).
--   move to TRIM1 supplying 'TrimIn' (seq 2 < 5) -> BACKWARD -> rejected.
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12232-59B-0000');
DECLARE @Dest   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Start  BIGINT = (SELECT TOP 1 e.LocationId FROM Parts.v_EffectiveItemLocation e
                          WHERE e.ItemId = @ItemId AND e.LocationId <> @Dest ORDER BY e.LocationId);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Rt BIGINT = (SELECT TOP 1 Id FROM Parts.RouteTemplate WHERE ItemId = @ItemId
                      AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL ORDER BY VersionNumber DESC);
DECLARE @otpIn  BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimIn');
DECLARE @otpOut BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimOut');
DECLARE @otpMac BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'MachiningIn');

DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @Start, @PieceCount = 20, @AppUserId = 1, @LotName = N'FONLY-2';
SELECT @L = NewId FROM #C; DROP TABLE #C;

INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId)
VALUES (@L, @otpIn, SYSUTCDATETIME(), 1), (@L, @otpOut, SYSUTCDATETIME(), 1), (@L, @otpMac, SYSUTCDATETIME(), 1);

DECLARE @S BIT;
CREATE TABLE #M (Status BIT, Message NVARCHAR(500));
INSERT INTO #M EXEC Lots.Lot_MoveToValidated @LotId = @L, @ToLocationId = @Dest, @AppUserId = 1,
    @OperationTypeCode = N'TrimIn';
SELECT @S = Status FROM #M; DROP TABLE #M;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[FwdOnly] backward op (TrimIn past MachiningIn) rejected', @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 3: backward operation + supervisor override -> allowed
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12232-59B-0000');
DECLARE @Dest   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Start  BIGINT = (SELECT TOP 1 e.LocationId FROM Parts.v_EffectiveItemLocation e
                          WHERE e.ItemId = @ItemId AND e.LocationId <> @Dest ORDER BY e.LocationId);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Rt BIGINT = (SELECT TOP 1 Id FROM Parts.RouteTemplate WHERE ItemId = @ItemId
                      AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL ORDER BY VersionNumber DESC);
DECLARE @otpIn  BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimIn');
DECLARE @otpOut BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimOut');
DECLARE @otpMac BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'MachiningIn');

DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @Start, @PieceCount = 20, @AppUserId = 1, @LotName = N'FONLY-3';
SELECT @L = NewId FROM #C; DROP TABLE #C;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId)
VALUES (@L, @otpIn, SYSUTCDATETIME(), 1), (@L, @otpOut, SYSUTCDATETIME(), 1), (@L, @otpMac, SYSUTCDATETIME(), 1);

DECLARE @S BIT;
CREATE TABLE #M (Status BIT, Message NVARCHAR(500));
INSERT INTO #M EXEC Lots.Lot_MoveToValidated @LotId = @L, @ToLocationId = @Dest, @AppUserId = 1,
    @OperationTypeCode = N'TrimIn', @OverrideAppUserId = 1;
SELECT @S = Status FROM #M; DROP TABLE #M;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[FwdOnly] backward op + supervisor override allowed', @Expected = N'1', @Actual = @SStr;
GO

-- =============================================
-- Test 4: no operation (plain storage move) -> never guarded
--   progressed LOT, move to TRIM1 with @OperationTypeCode NULL -> allowed.
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12232-59B-0000');
DECLARE @Dest   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Start  BIGINT = (SELECT TOP 1 e.LocationId FROM Parts.v_EffectiveItemLocation e
                          WHERE e.ItemId = @ItemId AND e.LocationId <> @Dest ORDER BY e.LocationId);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Rt BIGINT = (SELECT TOP 1 Id FROM Parts.RouteTemplate WHERE ItemId = @ItemId
                      AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL ORDER BY VersionNumber DESC);
DECLARE @otpIn  BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'MachiningIn');

DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @Start, @PieceCount = 20, @AppUserId = 1, @LotName = N'FONLY-4';
SELECT @L = NewId FROM #C; DROP TABLE #C;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId)
VALUES (@L, @otpIn, SYSUTCDATETIME(), 1);

DECLARE @S BIT;
CREATE TABLE #M (Status BIT, Message NVARCHAR(500));
INSERT INTO #M EXEC Lots.Lot_MoveToValidated @LotId = @L, @ToLocationId = @Dest, @AppUserId = 1;
SELECT @S = Status FROM #M; DROP TABLE #M;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[FwdOnly] no operation (storage move) allowed', @Expected = N'1', @Actual = @SStr;
GO

-- ---- cleanup ----
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'FONLY-%');
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'FONLY-%');
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'FONLY-%');
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'FONLY-%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'FONLY-%')
                                        OR DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'FONLY-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'FONLY-%';
GO

EXEC test.EndTestFile;
GO
