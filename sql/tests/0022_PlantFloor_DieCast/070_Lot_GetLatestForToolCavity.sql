-- =============================================
-- File:         0022_PlantFloor_DieCast/070_Lot_GetLatestForToolCavity.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-07
-- Description:  Tests for Lots.Lot_GetLatestForToolCavity (the cavity-scoped
--               reject target resolver, Jacques 2026-07-06 decision):
--                 - returns the NEWEST open LOT for (tool, cavity)
--                 - a Closed LOT is skipped (target rolls back to next-latest)
--                 - a cavity with no LOTs returns 0 rows
--               TEST-RTC-* fixture codes.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/070_Lot_GetLatestForToolCavity.sql';
GO

-- ---- cleanup ----
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-RTC-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-RTC-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-RTC-TOOL';
GO

-- ---- fixture: tool mounted on an unassigned eligible cell, cavities 1 + 2, three lots ----
DECLARE @DieCellId BIGINT;
SELECT TOP 1 @DieCellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
INNER JOIN Location.Location l ON l.Id = eil.LocationId
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
WHERE lt.Code = N'Cell' AND eil.Source = N'Direct'
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-RTC-TOOL', N'Reject-target test die', @ToolStatusActive, SYSUTCDATETIME(), 1);
DECLARE @ToolId BIGINT = SCOPE_IDENTITY();

DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, 1, @CavActive, SYSUTCDATETIME(), 1);
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, 2, @CavActive, SYSUTCDATETIME(), 1);

INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@ToolId, @DieCellId, SYSUTCDATETIME(), 1);
GO

DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-RTC-TOOL');
DECLARE @Cav1 BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 1);
DECLARE @Cav2 BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 2);
DECLARE @DieCellId BIGINT = (SELECT CellLocationId FROM Tools.ToolAssignment WHERE ToolId = @ToolId AND ReleasedAt IS NULL);
DECLARE @DieItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @DieCellId AND Source = N'Direct');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

-- older cavity-1 lot
DECLARE @LotOld BIGINT;
CREATE TABLE #L1 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #L1 EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 10, @ToolId = @ToolId, @ToolCavityId = @Cav1, @AppUserId = 1, @LotName = N'900000030';
SELECT @LotOld = NewId FROM #L1; DROP TABLE #L1;

-- newer cavity-1 lot (created later -> the expected target)
WAITFOR DELAY '00:00:00.010';
DECLARE @LotNew BIGINT;
CREATE TABLE #L2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #L2 EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 8, @ToolId = @ToolId, @ToolCavityId = @Cav1, @AppUserId = 1, @LotName = N'900000031';
SELECT @LotNew = NewId FROM #L2; DROP TABLE #L2;

-- ---- newest open lot on cavity 1 is returned ----
CREATE TABLE #T1 (Id BIGINT, LotName NVARCHAR(50), PieceCount INT, InventoryAvailable INT, CavityNumber INT);
INSERT INTO #T1 EXEC Lots.Lot_GetLatestForToolCavity @ToolId = @ToolId, @ToolCavityId = @Cav1;
DECLARE @Got NVARCHAR(20) = (SELECT CAST(Id AS NVARCHAR(20)) FROM #T1);
DECLARE @Want NVARCHAR(20) = CAST(@LotNew AS NVARCHAR(20));
DROP TABLE #T1;
EXEC test.Assert_IsEqual @TestName = N'[RejTarget] newest open cavity-1 LOT returned', @Expected = @Want, @Actual = @Got;

-- ---- Closed newest lot is skipped -> older lot becomes the target ----
DECLARE @ClosedId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
UPDATE Lots.Lot SET LotStatusId = @ClosedId WHERE Id = @LotNew;

CREATE TABLE #T2 (Id BIGINT, LotName NVARCHAR(50), PieceCount INT, InventoryAvailable INT, CavityNumber INT);
INSERT INTO #T2 EXEC Lots.Lot_GetLatestForToolCavity @ToolId = @ToolId, @ToolCavityId = @Cav1;
DECLARE @Got2 NVARCHAR(20) = (SELECT CAST(Id AS NVARCHAR(20)) FROM #T2);
DECLARE @Want2 NVARCHAR(20) = CAST(@LotOld AS NVARCHAR(20));
DROP TABLE #T2;
EXEC test.Assert_IsEqual @TestName = N'[RejTarget] Closed LOT skipped, next-latest returned', @Expected = @Want2, @Actual = @Got2;

-- ---- empty cavity returns no rows ----
CREATE TABLE #T3 (Id BIGINT, LotName NVARCHAR(50), PieceCount INT, InventoryAvailable INT, CavityNumber INT);
INSERT INTO #T3 EXEC Lots.Lot_GetLatestForToolCavity @ToolId = @ToolId, @ToolCavityId = @Cav2;
DECLARE @Cnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #T3);
DROP TABLE #T3;
EXEC test.Assert_IsEqual @TestName = N'[RejTarget] empty cavity returns 0 rows', @Expected = N'0', @Actual = @Cnt;
GO

-- ---- cleanup ----
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-RTC-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-RTC-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-RTC-TOOL';
GO

EXEC test.EndTestFile;
GO
