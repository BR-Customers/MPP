-- =============================================
-- File:         0022_PlantFloor_DieCast/050_Lot_GetShiftCavityTally.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-06
-- Description:  Tests for Lots.Lot_GetShiftCavityTally (die-cast right-rail
--               shift tally), incl. the v1.1 scrap-inclusive change (Jacques
--               2026-07-06): RejectEvent_Record decrements Lot.PieceCount, so
--               the tally adds rejected quantity back per lot.
--                 - one row per ACTIVE cavity (Closed excluded)
--                 - PieceSum = as-cast total (survives a reject decrement)
--                 - RejectSum = per-cavity scrapped quantity
--                 - ShiftShots = MAX(PieceSum) across cavities, same on every row
--               TEST-TLY-* fixture codes avoid the walkthrough's TEST-DC-*.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/050_Lot_GetShiftCavityTally.sql';
GO

-- ---- cleanup any prior fixtures (reverse FK order) ----
DELETE FROM Workorder.ProductionEventValue WHERE ProductionEventId IN (
    SELECT pe.Id FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'MESL%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-TLY-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-TLY-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-TLY-TOOL';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-TLY';
GO

-- ---- fixture: DefectCode + die cell + tool with cavities 1,2 Active / 3 Closed ----
DECLARE @DefAreaId BIGINT = (
    SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE l.DeprecatedAt IS NULL AND lt.Code = N'Area' ORDER BY l.Id);
INSERT INTO Quality.DefectCode (Code, Description, AreaLocationId, IsExcused, CreatedAt)
VALUES (N'TEST-DEF-TLY', N'Tally test defect', @DefAreaId, 0, SYSUTCDATETIME());

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
VALUES (@ToolTypeId, N'TEST-TLY-TOOL', N'Tally test die', @ToolStatusActive, SYSUTCDATETIME(), 1);
DECLARE @ToolId BIGINT = SCOPE_IDENTITY();

DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
DECLARE @CavClosed BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Closed');
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, 1, @CavActive, SYSUTCDATETIME(), 1);
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, 2, @CavActive, SYSUTCDATETIME(), 1);
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, 3, @CavClosed, SYSUTCDATETIME(), 1);

INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@ToolId, @DieCellId, SYSUTCDATETIME(), 1);
GO

-- ---- fixture: 2 lots on cavity 1 (10 + 8 pc), 1 lot on cavity 2 (5 pc), reject 3 from the 10-pc lot ----
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-TLY-TOOL');
DECLARE @Cav1 BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 1);
DECLARE @Cav2 BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 2);
DECLARE @DieCellId BIGINT = (SELECT CellLocationId FROM Tools.ToolAssignment WHERE ToolId = @ToolId AND ReleasedAt IS NULL);
DECLARE @DieItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @DieCellId AND Source = N'Direct');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

DECLARE @LotA1 BIGINT;
CREATE TABLE #L1 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #L1 EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 10, @ToolId = @ToolId, @ToolCavityId = @Cav1, @AppUserId = 1;
SELECT @LotA1 = NewId FROM #L1; DROP TABLE #L1;

CREATE TABLE #L2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #L2 EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 8, @ToolId = @ToolId, @ToolCavityId = @Cav1, @AppUserId = 1;
DROP TABLE #L2;

CREATE TABLE #L3 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #L3 EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 5, @ToolId = @ToolId, @ToolCavityId = @Cav2, @AppUserId = 1;
DROP TABLE #L3;

DECLARE @DefId BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-TLY');
DECLARE @RS BIT;
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.RejectEvent_Record @LotId = @LotA1, @DefectCodeId = @DefId, @Quantity = 3, @AppUserId = 1;
SELECT @RS = Status FROM #R; DROP TABLE #R;
DECLARE @RSStr NVARCHAR(10) = CAST(@RS AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Tally] fixture reject accepted (control)', @Expected = N'1', @Actual = @RSStr;
GO

-- =============================================
-- Assertions on the tally
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-TLY-TOOL');
CREATE TABLE #T (ToolCavityId BIGINT, CavityNumber INT, CavityLabel NVARCHAR(60), PieceSum INT, RejectSum INT, ShiftShots INT);
INSERT INTO #T EXEC Lots.Lot_GetShiftCavityTally @ToolId = @ToolId;

DECLARE @RowCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally] one row per ACTIVE cavity (Closed excluded)', @Expected = N'2', @Actual = @RowCnt;

DECLARE @P1 NVARCHAR(10) = (SELECT CAST(PieceSum AS NVARCHAR(10)) FROM #T WHERE CavityNumber = 1);
EXEC test.Assert_IsEqual @TestName = N'[Tally] cavity 1 PieceSum is as-cast 18 (reject added back)', @Expected = N'18', @Actual = @P1;

DECLARE @R1 NVARCHAR(10) = (SELECT CAST(RejectSum AS NVARCHAR(10)) FROM #T WHERE CavityNumber = 1);
EXEC test.Assert_IsEqual @TestName = N'[Tally] cavity 1 RejectSum is 3', @Expected = N'3', @Actual = @R1;

DECLARE @P2 NVARCHAR(10) = (SELECT CAST(PieceSum AS NVARCHAR(10)) FROM #T WHERE CavityNumber = 2);
EXEC test.Assert_IsEqual @TestName = N'[Tally] cavity 2 PieceSum is 5', @Expected = N'5', @Actual = @P2;

DECLARE @R2 NVARCHAR(10) = (SELECT CAST(RejectSum AS NVARCHAR(10)) FROM #T WHERE CavityNumber = 2);
EXEC test.Assert_IsEqual @TestName = N'[Tally] cavity 2 RejectSum is 0', @Expected = N'0', @Actual = @R2;

DECLARE @ShotsDistinct NVARCHAR(10) = (SELECT CAST(COUNT(DISTINCT ShiftShots) AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally] ShiftShots identical on every row', @Expected = N'1', @Actual = @ShotsDistinct;

DECLARE @Shots NVARCHAR(10) = (SELECT TOP 1 CAST(ShiftShots AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally] ShiftShots is the busiest cavity as-cast total (18)', @Expected = N'18', @Actual = @Shots;
DROP TABLE #T;
GO

-- ---- cleanup ----
DELETE FROM Workorder.ProductionEventValue WHERE ProductionEventId IN (
    SELECT pe.Id FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'MESL%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-TLY-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-TLY-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-TLY-TOOL';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-TLY';
GO

EXEC test.EndTestFile;
GO
