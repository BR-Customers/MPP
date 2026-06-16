-- =============================================
-- File:         0023_PlantFloor_DieCast_Deltas/040_RejectEvent_concurrency_guard.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Tests for the RejectEvent_Record TOCTOU guard (Phase 3 build, A5).
--               A true concurrent race is not deterministically reproducible in a
--               single session, so this asserts the guard INVARIANT: a valid reject
--               decrements correctly and PieceCount is never negative anywhere. The
--               in-transaction guard (IF @NewPieceCount < 0 RAISERROR) is verified by
--               code review + this invariant; a real race needs a gateway concurrency
--               test. The existing 0022/020 reject tests cover the happy + over-qty
--               paths and must remain green alongside the guard.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0023_PlantFloor_DieCast_Deltas/040_RejectEvent_concurrency_guard.sql';
GO

-- ---- teardown ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-CG';
GO

DECLARE @AreaId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE l.DeprecatedAt IS NULL AND lt.Code = N'Area' ORDER BY l.Id);
INSERT INTO Quality.DefectCode (Code, Description, AreaLocationId, IsExcused, CreatedAt)
VALUES (N'TEST-DEF-CG', N'Concurrency guard test', @AreaId, 0, SYSUTCDATETIME());
GO

-- Build a 10-piece LOT, valid reject of 4 -> PieceCount=6; assert never negative.
DECLARE @CellId BIGINT, @ItemId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
DECLARE @LotId BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=10, @AppUserId=1;
SELECT @LotId = NewId FROM #C; DROP TABLE #C;
DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-CG');
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.RejectEvent_Record @LotId=@LotId, @DefectCodeId=@Defect, @Quantity=4, @AppUserId=1;
DROP TABLE #R;
DECLARE @Pc NVARCHAR(10) = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id=@LotId) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CG] valid reject 10-4=6', @Expected = N'6', @Actual = @Pc;
DECLARE @Neg NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Lots.Lot WHERE PieceCount < 0) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CG] no negative PieceCount in Lots.Lot', @Expected = N'0', @Actual = @Neg;
GO

-- ---- teardown ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-CG';
GO
EXEC test.EndTestFile;
GO
