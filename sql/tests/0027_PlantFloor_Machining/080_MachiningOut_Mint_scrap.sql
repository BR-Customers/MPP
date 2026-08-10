-- =============================================
-- File:         0027_PlantFloor_Machining/080_MachiningOut_Mint_scrap.sql
-- Description:  FAT-MACH-140 -- Machining OUT reject/defect capture. Ports the Trim
--               OUT multi-reason scrap feature onto Workorder.MachiningOut_Mint:
--               @ScrapLinesJson -> one Workorder.RejectEvent per defect line
--               (ProductionEventId NULL, LotId = @SourceLotId), the scanned casting
--               decremented by the scrap total IN ADDITION to the FIFO consumption.
--               Mirrors 0024_.../050_TrimOut_Record_validation.sql (scrap block).
--
--               Fixture: casting 12270-6NA -> SubAssembly 12270-6NA-M (BOM x1,
--               auto-created), line MA1-FP6NA-MOUT (an existing Machining-OUT
--               terminal; the 5G0-c/MA1-5GOF-MOUT fixture used by 070 was orphaned
--               when the location seed dropped MA1-5GOF-MOUT). MaxLotSize = 12, so
--               fixtures stay <= 12 pcs. Castings are pre-stamped past every route
--               step before MachiningOut so their next-pending step is MachiningOut
--               (required by the FIFO candidate-set eligibility, mirror of 070).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/080_MachiningOut_Mint_scrap.sql';
GO

-- =============================================
-- Test 1: multi-line scrap -> N RejectEvent rows (ProductionEventId NULL) on the
--   source casting; casting decremented by consumption AND scrap total.
--   casting 12, mint 5 (consumes 5), scrap 3+2=5 -> casting 12-5-5 = 2.
-- =============================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Casting BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA');
DECLARE @Machined BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Uom BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');
DECLARE @MoTpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
    WHERE oty.Code = N'MachiningOut' AND rk.Code = N'ConsumeMint' AND ot.DeprecatedAt IS NULL);

-- seed BOM 12270-6NA-M <- 12270-6NA x1 (idempotent; mirror 070)
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Machined AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DECLARE @bc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    DECLARE @bl TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    DECLARE @bp TABLE (Status BIT, Message NVARCHAR(500));
    INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId = @Machined, @AppUserId = @U;
    DECLARE @Bom BIGINT = (SELECT NewId FROM @bc);
    INSERT INTO @bl EXEC Parts.BomLine_Add @BomId = @Bom, @ChildItemId = @Casting, @QtyPer = 1, @UomId = @Uom, @AppUserId = @U;
    INSERT INTO @bp EXEC Parts.Bom_Publish @Id = @Bom, @AppUserId = @U;
END

-- isolate the queue: close any leftover open 12270-6NA castings at the line
UPDATE Lots.Lot SET LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed')
  WHERE ItemId=@Casting AND CurrentLocationId=@Line AND LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');

-- casting 12 pcs at the line, pre-stamped past every route step before MachiningOut
DECLARE @Cast BIGINT;
CREATE TABLE #C1 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C1 EXEC Lots.Lot_Create @ItemId = @Casting, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 12, @AppUserId = @U;
SELECT @Cast = NewId FROM #C1; DROP TABLE #C1;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Cast, rs.OperationTemplateId, SYSUTCDATETIME(), 12, @U
FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
WHERE rt.ItemId = @Casting AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND rs.OperationTemplateId <> @MoTpl;

DECLARE @D1 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @D2 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL AND Id <> @D1 ORDER BY Id);
DECLARE @Json NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@D1 AS NVARCHAR(20)) + N',"quantity":3},{"defectCodeId":' + CAST(@D2 AS NVARCHAR(20)) + N',"quantity":2}]';

DECLARE @m TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
INSERT INTO @m EXEC Workorder.MachiningOut_Mint @SourceLotId = @Cast, @OperationTemplateId = @MoTpl, @PieceCount = 5, @ScrapLinesJson = @Json, @AppUserId = @U, @TerminalLocationId = @Line;
DECLARE @mStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @m);
DECLARE @mMsg NVARCHAR(500) = (SELECT Message FROM @m);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] mint with scrap succeeds', @Expected = N'1', @Actual = @mStatus;

DECLARE @rej NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent WHERE LotId = @Cast);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] two RejectEvent rows written on the source casting', @Expected = N'2', @Actual = @rej;

DECLARE @rejPeNotNull NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent WHERE LotId = @Cast AND ProductionEventId IS NOT NULL);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] reject rows have NULL ProductionEventId', @Expected = N'0', @Actual = @rejPeNotNull;

DECLARE @castPc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Cast);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] casting decremented by consumption(5) + scrap(5): 12->2', @Expected = N'2', @Actual = @castPc;

DECLARE @mintPc NVARCHAR(10) = (SELECT CAST(l.PieceCount AS NVARCHAR(10)) FROM Lots.Lot l WHERE l.Id = (SELECT NewId FROM @m));
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] minted SubAssembly is 5 pcs', @Expected = N'5', @Actual = @mintPc;
GO

-- =============================================
-- Test 2: empty/absent @ScrapLinesJson -> mint succeeds, zero rejects, casting
--   decremented ONLY by consumption (regression: scrap-free path unchanged).
--   casting 12, mint 5, no scrap -> casting 7, 0 rejects.
-- =============================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Casting BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MoTpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
    WHERE oty.Code = N'MachiningOut' AND rk.Code = N'ConsumeMint' AND ot.DeprecatedAt IS NULL);
UPDATE Lots.Lot SET LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed')
  WHERE ItemId=@Casting AND CurrentLocationId=@Line AND LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');
DECLARE @Cast2 BIGINT;
CREATE TABLE #C2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C2 EXEC Lots.Lot_Create @ItemId = @Casting, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 12, @AppUserId = @U;
SELECT @Cast2 = NewId FROM #C2; DROP TABLE #C2;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Cast2, rs.OperationTemplateId, SYSUTCDATETIME(), 12, @U
FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
WHERE rt.ItemId = @Casting AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND rs.OperationTemplateId <> @MoTpl;

DECLARE @rejBefore INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @Cast2);
DECLARE @m2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
INSERT INTO @m2 EXEC Workorder.MachiningOut_Mint @SourceLotId = @Cast2, @OperationTemplateId = @MoTpl, @PieceCount = 5, @AppUserId = @U, @TerminalLocationId = @Line;
DECLARE @m2Status NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @m2);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] scrap-free mint succeeds', @Expected = N'1', @Actual = @m2Status;
DECLARE @rejNew NVARCHAR(10) = (SELECT CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @Cast2) - @rejBefore AS NVARCHAR(10)));
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] scrap-free writes zero rejects', @Expected = N'0', @Actual = @rejNew;
DECLARE @cast2Pc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Cast2);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] scrap-free casting decremented only by consumption: 12->7', @Expected = N'7', @Actual = @cast2Pc;
GO

-- =============================================
-- Test 3: invalid/deprecated defectCodeId -> Status 0, nothing written, no decrement.
-- =============================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Casting BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MoTpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
    WHERE oty.Code = N'MachiningOut' AND rk.Code = N'ConsumeMint' AND ot.DeprecatedAt IS NULL);
UPDATE Lots.Lot SET LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed')
  WHERE ItemId=@Casting AND CurrentLocationId=@Line AND LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');
DECLARE @Cast3 BIGINT;
CREATE TABLE #C3 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C3 EXEC Lots.Lot_Create @ItemId = @Casting, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 12, @AppUserId = @U;
SELECT @Cast3 = NewId FROM #C3; DROP TABLE #C3;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Cast3, rs.OperationTemplateId, SYSUTCDATETIME(), 12, @U
FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
WHERE rt.ItemId = @Casting AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND rs.OperationTemplateId <> @MoTpl;
DECLARE @BadJson NVARCHAR(MAX) = N'[{"defectCodeId":99999999,"quantity":2}]';
DECLARE @m3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
INSERT INTO @m3 EXEC Workorder.MachiningOut_Mint @SourceLotId = @Cast3, @OperationTemplateId = @MoTpl, @PieceCount = 5, @ScrapLinesJson = @BadJson, @AppUserId = @U, @TerminalLocationId = @Line;
DECLARE @m3Status NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @m3);
DECLARE @m3Msg NVARCHAR(500) = (SELECT Message FROM @m3);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] invalid defect code rejected (Status 0)', @Expected = N'0', @Actual = @m3Status;
EXEC test.Assert_Contains @TestName = N'[MoScrap] invalid-defect message', @HaystackStr = @m3Msg, @NeedleStr = N'invalid or deprecated';
DECLARE @cast3Pc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Cast3);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] invalid defect leaves casting unchanged (12)', @Expected = N'12', @Actual = @cast3Pc;
DECLARE @rej3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent WHERE LotId = @Cast3);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] invalid defect writes zero rejects', @Expected = N'0', @Actual = @rej3;
GO

-- =============================================
-- Test 4: non-positive quantity (0 and -1) and malformed JSON -> Status 0, no decrement.
-- =============================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Casting BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MoTpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
    WHERE oty.Code = N'MachiningOut' AND rk.Code = N'ConsumeMint' AND ot.DeprecatedAt IS NULL);
UPDATE Lots.Lot SET LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed')
  WHERE ItemId=@Casting AND CurrentLocationId=@Line AND LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');
DECLARE @Cast4 BIGINT;
CREATE TABLE #C4 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C4 EXEC Lots.Lot_Create @ItemId = @Casting, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 12, @AppUserId = @U;
SELECT @Cast4 = NewId FROM #C4; DROP TABLE #C4;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Cast4, rs.OperationTemplateId, SYSUTCDATETIME(), 12, @U
FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
WHERE rt.ItemId = @Casting AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND rs.OperationTemplateId <> @MoTpl;
DECLARE @D4 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);

-- zero qty
DECLARE @ZeroJson NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@D4 AS NVARCHAR(20)) + N',"quantity":0}]';
DECLARE @m4a TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
INSERT INTO @m4a EXEC Workorder.MachiningOut_Mint @SourceLotId = @Cast4, @OperationTemplateId = @MoTpl, @PieceCount = 5, @ScrapLinesJson = @ZeroJson, @AppUserId = @U, @TerminalLocationId = @Line;
DECLARE @m4aStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @m4a);
DECLARE @m4aMsg NVARCHAR(500) = (SELECT Message FROM @m4a);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] zero quantity rejected', @Expected = N'0', @Actual = @m4aStatus;
EXEC test.Assert_Contains @TestName = N'[MoScrap] positive-quantity message', @HaystackStr = @m4aMsg, @NeedleStr = N'quantity must be positive';

-- negative qty
DECLARE @NegJson NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@D4 AS NVARCHAR(20)) + N',"quantity":-1}]';
DECLARE @m4b TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
INSERT INTO @m4b EXEC Workorder.MachiningOut_Mint @SourceLotId = @Cast4, @OperationTemplateId = @MoTpl, @PieceCount = 5, @ScrapLinesJson = @NegJson, @AppUserId = @U, @TerminalLocationId = @Line;
DECLARE @m4bStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @m4b);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] negative quantity rejected', @Expected = N'0', @Actual = @m4bStatus;

-- malformed json
DECLARE @m4c TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
INSERT INTO @m4c EXEC Workorder.MachiningOut_Mint @SourceLotId = @Cast4, @OperationTemplateId = @MoTpl, @PieceCount = 5, @ScrapLinesJson = N'not valid json', @AppUserId = @U, @TerminalLocationId = @Line;
DECLARE @m4cStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @m4c);
DECLARE @m4cMsg NVARCHAR(500) = (SELECT Message FROM @m4c);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] malformed JSON rejected', @Expected = N'0', @Actual = @m4cStatus;
EXEC test.Assert_Contains @TestName = N'[MoScrap] malformed-json message', @HaystackStr = @m4cMsg, @NeedleStr = N'not valid JSON';

DECLARE @cast4Pc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Cast4);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] rejected scrap leaves casting unchanged (12)', @Expected = N'12', @Actual = @cast4Pc;
GO

-- =============================================
-- Test 5: source-covers-scrap guard -- scrap total exceeding the scanned casting's
--   MIN(InvAvail,PieceCount) rejects (Status 0), nothing written.
--   casting 5, scrap 6 -> reject.
-- =============================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Casting BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MoTpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
    WHERE oty.Code = N'MachiningOut' AND rk.Code = N'ConsumeMint' AND ot.DeprecatedAt IS NULL);
UPDATE Lots.Lot SET LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed')
  WHERE ItemId=@Casting AND CurrentLocationId=@Line AND LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');
DECLARE @Cast5 BIGINT;
CREATE TABLE #C5 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C5 EXEC Lots.Lot_Create @ItemId = @Casting, @LotOriginTypeId = @Origin, @CurrentLocationId = @Line, @PieceCount = 5, @AppUserId = @U;
SELECT @Cast5 = NewId FROM #C5; DROP TABLE #C5;
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Cast5, rs.OperationTemplateId, SYSUTCDATETIME(), 5, @U
FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
WHERE rt.ItemId = @Casting AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND rs.OperationTemplateId <> @MoTpl;
DECLARE @D5 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @OverJson NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@D5 AS NVARCHAR(20)) + N',"quantity":6}]';
DECLARE @m5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
INSERT INTO @m5 EXEC Workorder.MachiningOut_Mint @SourceLotId = @Cast5, @OperationTemplateId = @MoTpl, @PieceCount = 1, @ScrapLinesJson = @OverJson, @AppUserId = @U, @TerminalLocationId = @Line;
DECLARE @m5Status NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @m5);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] scrap exceeding source casting rejected', @Expected = N'0', @Actual = @m5Status;
DECLARE @cast5Pc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Cast5);
EXEC test.Assert_IsEqual @TestName = N'[MoScrap] over-scrap leaves casting unchanged (5)', @Expected = N'5', @Actual = @cast5Pc;
GO

-- ---- teardown (FK-safe): all LOTs of the fixture items 12270-6NA / 12270-6NA-M ----
DECLARE @Cast BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA');
DECLARE @Mach BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @Lots TABLE (Id BIGINT);
INSERT INTO @Lots SELECT Id FROM Lots.Lot WHERE ItemId IN (@Cast, @Mach);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Workorder.ConsumptionEvent WHERE SourceLotId IN (SELECT Id FROM @Lots) OR ProducedLotId IN (SELECT Id FROM @Lots);
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @Lots) OR ChildLotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @Lots) OR DescendantLotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @Lots);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @Lots);
-- BOM 12270-6NA-M <- 12270-6NA is auto-created by this test's fixture; leave it in place.
GO

EXEC test.EndTestFile;
GO
