-- =============================================
-- File:         0022_PlantFloor_DieCast/060_Lot_ScrapSummary_History.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-06
-- Description:  Tests for the LOT Detail scrap surfacing (Jacques 2026-07-06):
--                 - Lots.Lot_GetScrapSummary: RejectedTotal (SUM RejectEvent.Quantity)
--                   + CounterScrap (MAX ProductionEvent.ScrapCount, cumulative)
--                   + TotalScrap (sum of both); zeros for a clean lot.
--                 - Lot_GetAttributeHistory v1.2: 'Reject' + 'Production' streams
--                   appear in the unified timeline.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/060_Lot_ScrapSummary_History.sql';
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
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SCR';
GO

-- ---- fixture: defect code + a Received lot at an eligible cell ----
DECLARE @DefAreaId BIGINT = (
    SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE l.DeprecatedAt IS NULL AND lt.Code = N'Area' ORDER BY l.Id);
INSERT INTO Quality.DefectCode (Code, Description, AreaLocationId, IsExcused, CreatedAt)
VALUES (N'TEST-DEF-SCR', N'Scrap summary test defect', @DefAreaId, 0, SYSUTCDATETIME());

DECLARE @LocA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

DECLARE @L BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA, @PieceCount = 20, @AppUserId = 1;
SELECT @L = NewId FROM #C; DROP TABLE #C;

-- ---- clean-lot summary is all zeros ----
CREATE TABLE #S0 (RejectedTotal INT, CounterScrap INT, TotalScrap INT);
INSERT INTO #S0 EXEC Lots.Lot_GetScrapSummary @LotId = @L;
DECLARE @T0 NVARCHAR(10) = (SELECT CAST(TotalScrap AS NVARCHAR(10)) FROM #S0);
DROP TABLE #S0;
EXEC test.Assert_IsEqual @TestName = N'[Scrap] clean lot TotalScrap is 0', @Expected = N'0', @Actual = @T0;

-- ---- record a checkpoint (cumulative scrap 2) + a reject (3) ----
DECLARE @DcOt BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot');
CREATE TABLE #P (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #P EXEC Workorder.ProductionEvent_Record @LotId = @L, @OperationTemplateId = @DcOt, @ShotCount = 10, @ScrapCount = 2, @AppUserId = 1;
DROP TABLE #P;

DECLARE @DefId BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SCR');
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.RejectEvent_Record @LotId = @L, @DefectCodeId = @DefId, @Quantity = 3, @AppUserId = 1;
DROP TABLE #R;

-- ---- summary reflects both channels ----
CREATE TABLE #S (RejectedTotal INT, CounterScrap INT, TotalScrap INT);
INSERT INTO #S EXEC Lots.Lot_GetScrapSummary @LotId = @L;
DECLARE @Rj NVARCHAR(10) = (SELECT CAST(RejectedTotal AS NVARCHAR(10)) FROM #S);
DECLARE @Cs NVARCHAR(10) = (SELECT CAST(CounterScrap AS NVARCHAR(10)) FROM #S);
DECLARE @Ts NVARCHAR(10) = (SELECT CAST(TotalScrap AS NVARCHAR(10)) FROM #S);
DROP TABLE #S;
EXEC test.Assert_IsEqual @TestName = N'[Scrap] RejectedTotal is 3', @Expected = N'3', @Actual = @Rj;
EXEC test.Assert_IsEqual @TestName = N'[Scrap] CounterScrap is 2 (cumulative max)', @Expected = N'2', @Actual = @Cs;
EXEC test.Assert_IsEqual @TestName = N'[Scrap] TotalScrap is 5', @Expected = N'5', @Actual = @Ts;

-- ---- history v1.2 carries Production + Reject streams ----
CREATE TABLE #H (EventAt DATETIME2(3), EventKind NVARCHAR(20), Detail NVARCHAR(500), ByUserId BIGINT, ByUserName NVARCHAR(200));
INSERT INTO #H EXEC Lots.Lot_GetAttributeHistory @LotId = @L;
DECLARE @Prod NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #H WHERE EventKind = N'Production');
DECLARE @Rej NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #H WHERE EventKind = N'Reject');
DECLARE @RejDetailOk NVARCHAR(10) = (SELECT CASE WHEN COUNT(*) = 1 THEN N'1' ELSE N'0' END FROM #H
    WHERE EventKind = N'Reject' AND Detail LIKE N'Rejected 3 pc%TEST-DEF-SCR%');
DROP TABLE #H;
EXEC test.Assert_IsEqual @TestName = N'[Scrap] history has 1 Production row', @Expected = N'1', @Actual = @Prod;
EXEC test.Assert_IsEqual @TestName = N'[Scrap] history has 1 Reject row', @Expected = N'1', @Actual = @Rej;
EXEC test.Assert_IsEqual @TestName = N'[Scrap] Reject detail carries qty + defect code', @Expected = N'1', @Actual = @RejDetailOk;
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
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SCR';
GO

EXEC test.EndTestFile;
GO
