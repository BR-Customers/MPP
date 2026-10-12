-- =============================================
-- File:         0028_PlantFloor_Assembly/102_RejectEvent_RecordByPartFifo.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-06
-- Description:  Workorder.RejectEvent_RecordByPartFifo + its read sibling
--               Lots.Lot_GetScrappablePartsByLocation (Scrap Entry popup,
--               Assembly + Machining terminals: scrap by PART, consumed FIFO).
--               Part A at MA1-COMPBR-MIN carries three Good LOTs whose identity
--               order is the REVERSE of their arrival order, plus a held LOT:
--                 A1 30 (arrives first)  A2 20  A3 5 (arrives last)  AHOLD 7
--               Part B carries one LOT whose PieceCount (10) and
--               InventoryAvailable (4) diverge.
--               Covers:
--                 - read: one row per part, Good LOTs only, lesser-of quantity
--                 - scrap inside the oldest LOT -> one reject row
--                 - scrap spanning two LOTs -> one reject row each, the drained
--                   LOT closed (+ LotStatusHistory), FIFO by arrival not identity
--                 - short -> refused, nothing recorded
--                 - exact drain -> every Good LOT closed, held LOT untouched
--                 - divergent LOT: capped at the lesser quantity, not closed
--                 - Quantity <= 0 and an additive operation -> refused
--               v1.1 (@LinesJson, several reasons in one entry):
--                 - two reasons laid along the FIFO run -> one reject row per
--                   (LOT, reason), the drained LOT closed once, the terminal
--                   stamped on every row
--                 - short on the TOTAL -> refused, nothing recorded
--                 - repeated reason / zero quantity / no lines / unknown or
--                   deprecated reason / unreadable JSON -> refused
--               EXEC args are pre-assigned @variables (no inline CAST).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/102_RejectEvent_RecordByPartFifo.sql';
GO

-- ---- cleanup (FK-safe) ----
DELETE FROM Workorder.RejectEvent    WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'SFT-%');
DELETE FROM Lots.LotStatusHistory    WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'SFT-%');
DELETE FROM Lots.LotMovement         WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'SFT-%');
DELETE FROM Lots.LotEventLog         WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'SFT-%');
DELETE FROM Lots.Lot                 WHERE LotName LIKE N'SFT-%';
DELETE FROM Quality.DefectCode       WHERE Code IN (N'TEST-DEF-SF', N'TEST-DEF-SF2', N'TEST-DEF-SFX');
GO

-- ---- fixture ----
DECLARE @Now  DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Hold BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');

INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt)
VALUES (N'TEST-DEF-SF', N'Scrap FIFO test defect', NULL, 0, @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-SF-A')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P-SF-A', N'Scrap FIFO part A', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-SF-B')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P-SF-B', N'Scrap FIFO part B', 1, @Now, 1);
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-SF-A');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-SF-B');

-- Insert in REVERSE arrival order so identity order != FIFO order.
--   A3: no inbound movement -> arrival falls back to CreatedAt (@Now + 20s) -> last
--   A2: inbound movement @Now + 10s -> middle
--   A1: inbound movement @Now -> first
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'SFT-A3',    @A, 1, @Good, 5,  5,  @Cell, 1, DATEADD(SECOND, 20, @Now));
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'SFT-A2',    @A, 1, @Good, 20, 20, @Cell, 1, DATEADD(SECOND, -5, @Now));
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'SFT-A1',    @A, 1, @Good, 30, 30, @Cell, 1, DATEADD(SECOND, -5, @Now));
-- held LOT: the OLDEST of all, so FIFO would take it first if it were eligible
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'SFT-AHOLD', @A, 1, @Hold, 7,  7,  @Cell, 1, DATEADD(SECOND, -60, @Now));
-- part B: PieceCount and InventoryAvailable diverge
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'SFT-B1',    @B, 1, @Good, 10, 4,  @Cell, 1, @Now);

INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES ((SELECT Id FROM Lots.Lot WHERE LotName = N'SFT-A1'), NULL, @Cell, 1, @Now);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES ((SELECT Id FROM Lots.Lot WHERE LotName = N'SFT-A2'), NULL, @Cell, 1, DATEADD(SECOND, 10, @Now));
GO

-- =============================================
-- Test 1: read -- one row per part, Good LOTs only, lesser-of quantity
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
CREATE TABLE #P (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), QuantityAvailable INT, LotCount INT);
INSERT INTO #P EXEC Lots.Lot_GetScrappablePartsByLocation @LocationId = @Cell;

DECLARE @RowsA NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #P WHERE PartNumber = N'P-SF-A');
EXEC test.Assert_IsEqual @TestName = N'[SfRead] part A is ONE row', @Expected = N'1', @Actual = @RowsA;
DECLARE @QtyA NVARCHAR(10) = (SELECT CAST(QuantityAvailable AS NVARCHAR(10)) FROM #P WHERE PartNumber = N'P-SF-A');
EXEC test.Assert_IsEqual @TestName = N'[SfRead] part A total = 55 (held 7 not counted)', @Expected = N'55', @Actual = @QtyA;
DECLARE @CntA NVARCHAR(10) = (SELECT CAST(LotCount AS NVARCHAR(10)) FROM #P WHERE PartNumber = N'P-SF-A');
EXEC test.Assert_IsEqual @TestName = N'[SfRead] part A LotCount = 3', @Expected = N'3', @Actual = @CntA;
DECLARE @QtyB NVARCHAR(10) = (SELECT CAST(QuantityAvailable AS NVARCHAR(10)) FROM #P WHERE PartNumber = N'P-SF-B');
EXEC test.Assert_IsEqual @TestName = N'[SfRead] part B = 4 (lesser of PieceCount 10 / InventoryAvailable 4)', @Expected = N'4', @Actual = @QtyB;
DROP TABLE #P;
GO

-- =============================================
-- Test 2: scrap inside the oldest LOT -> one reject row, A1 30 -> 20
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-SF-A');
DECLARE @Def BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SF');
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @A, @LocationId = @Cell, @DefectCodeId = @Def, @Quantity = 10,
    @AppUserId = 1, @OperationTypeCode = N'AssemblyOut';

DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfOne] Status is 1', @Expected = N'1', @Actual = @S;
DECLARE @A1 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'SFT-A1');
EXEC test.Assert_IsEqual @TestName = N'[SfOne] oldest LOT A1 30 -> 20', @Expected = N'20', @Actual = @A1;
DECLARE @A1Inv NVARCHAR(10) = (SELECT CAST(InventoryAvailable AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'SFT-A1');
EXEC test.Assert_IsEqual @TestName = N'[SfOne] A1 InventoryAvailable 30 -> 20', @Expected = N'20', @Actual = @A1Inv;
DECLARE @A2 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'SFT-A2');
EXEC test.Assert_IsEqual @TestName = N'[SfOne] A2 untouched at 20', @Expected = N'20', @Actual = @A2;
DECLARE @Rows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent re
                              INNER JOIN Lots.Lot l ON l.Id = re.LotId WHERE l.LotName LIKE N'SFT-%');
EXEC test.Assert_IsEqual @TestName = N'[SfOne] exactly one reject row', @Expected = N'1', @Actual = @Rows;
DECLARE @Stamp NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent
                               WHERE Id = (SELECT NewId FROM #R) AND ItemId = @A);
EXEC test.Assert_IsEqual @TestName = N'[SfOne] NewId row carries the stamped ItemId', @Expected = N'1', @Actual = @Stamp;
DROP TABLE #R;
GO

-- =============================================
-- Test 3: scrap 25 spans two LOTs -> A1 drained (20) + closed, A2 takes 5
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-SF-A');
DECLARE @Def BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SF');
DECLARE @Term BIGINT = @Cell;
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @A, @LocationId = @Cell, @DefectCodeId = @Def, @Quantity = 25,
    @Remarks = N'span', @AppUserId = 1, @TerminalLocationId = @Term, @OperationTypeCode = N'AssemblyOut';

DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfSpan] Status is 1', @Expected = N'1', @Actual = @S;
DECLARE @A1St NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.LotName = N'SFT-A1');
EXEC test.Assert_IsEqual @TestName = N'[SfSpan] drained LOT A1 is Closed', @Expected = N'Closed', @Actual = @A1St;
DECLARE @A1 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'SFT-A1');
EXEC test.Assert_IsEqual @TestName = N'[SfSpan] A1 at 0', @Expected = N'0', @Actual = @A1;
DECLARE @A2 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'SFT-A2');
EXEC test.Assert_IsEqual @TestName = N'[SfSpan] next-oldest A2 20 -> 15 (arrival order, not identity)', @Expected = N'15', @Actual = @A2;
DECLARE @A3 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'SFT-A3');
EXEC test.Assert_IsEqual @TestName = N'[SfSpan] newest A3 untouched at 5', @Expected = N'5', @Actual = @A3;
DECLARE @Split NVARCHAR(50) = (SELECT STRING_AGG(l.LotName + N'=' + CAST(re.Quantity AS NVARCHAR(10)), N',') WITHIN GROUP (ORDER BY re.Id)
                               FROM Workorder.RejectEvent re INNER JOIN Lots.Lot l ON l.Id = re.LotId
                               WHERE re.Remarks = N'span');
EXEC test.Assert_IsEqual @TestName = N'[SfSpan] one reject row per LOT, oldest first', @Expected = N'SFT-A1=20,SFT-A2=5', @Actual = @Split;
DECLARE @Hist NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusHistory h
                              INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName = N'SFT-A1');
EXEC test.Assert_IsEqual @TestName = N'[SfSpan] close wrote a LotStatusHistory row', @Expected = N'1', @Actual = @Hist;
DROP TABLE #R;
GO

-- =============================================
-- Test 4: short -> refused, nothing recorded (20 scrappable: A2 15 + A3 5)
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-SF-A');
DECLARE @Def BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SF');
DECLARE @Before NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent re
                                INNER JOIN Lots.Lot l ON l.Id = re.LotId WHERE l.LotName LIKE N'SFT-%');
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @A, @LocationId = @Cell, @DefectCodeId = @Def, @Quantity = 21,
    @AppUserId = 1, @OperationTypeCode = N'AssemblyOut';

DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfShort] Status is 0', @Expected = N'0', @Actual = @S;
DECLARE @MsgOk BIT = CASE WHEN (SELECT Message FROM #R) LIKE N'Only 20 of P-SF-A%1 short%' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[SfShort] message states available (20) and shortfall (1)', @Condition = @MsgOk;
DECLARE @After NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent re
                               INNER JOIN Lots.Lot l ON l.Id = re.LotId WHERE l.LotName LIKE N'SFT-%');
EXEC test.Assert_IsEqual @TestName = N'[SfShort] no reject row written', @Expected = @Before, @Actual = @After;
DECLARE @A2 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'SFT-A2');
EXEC test.Assert_IsEqual @TestName = N'[SfShort] A2 still 15', @Expected = N'15', @Actual = @A2;
DROP TABLE #R;
GO

-- =============================================
-- Test 5: exact drain (20) -> A2 + A3 closed; held LOT untouched
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-SF-A');
DECLARE @Def BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SF');
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @A, @LocationId = @Cell, @DefectCodeId = @Def, @Quantity = 20,
    @AppUserId = 1, @OperationTypeCode = N'AssemblyOut';

DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfDrain] Status is 1', @Expected = N'1', @Actual = @S;
DECLARE @Closed NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot l
                                INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                                WHERE l.LotName IN (N'SFT-A1', N'SFT-A2', N'SFT-A3') AND sc.Code = N'Closed' AND l.PieceCount = 0);
EXEC test.Assert_IsEqual @TestName = N'[SfDrain] all three Good LOTs closed at zero', @Expected = N'3', @Actual = @Closed;
DECLARE @HoldQty NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'SFT-AHOLD');
EXEC test.Assert_IsEqual @TestName = N'[SfDrain] held LOT untouched at 7', @Expected = N'7', @Actual = @HoldQty;
DECLARE @HoldSt NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.LotName = N'SFT-AHOLD');
EXEC test.Assert_IsEqual @TestName = N'[SfDrain] held LOT still Hold', @Expected = N'Hold', @Actual = @HoldSt;
DROP TABLE #R;

-- part A no longer offered; a further scrap is refused (only the held LOT remains)
CREATE TABLE #P (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), QuantityAvailable INT, LotCount INT);
INSERT INTO #P EXEC Lots.Lot_GetScrappablePartsByLocation @LocationId = @Cell;
DECLARE @Gone NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #P WHERE PartNumber = N'P-SF-A');
EXEC test.Assert_IsEqual @TestName = N'[SfDrain] part A no longer listed', @Expected = N'0', @Actual = @Gone;
DROP TABLE #P;

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @A, @LocationId = @Cell, @DefectCodeId = @Def, @Quantity = 1,
    @AppUserId = 1, @OperationTypeCode = N'AssemblyOut';
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R2);
EXEC test.Assert_IsEqual @TestName = N'[SfDrain] scrap against held-only stock refused', @Expected = N'0', @Actual = @S2;
DROP TABLE #R2;
GO

-- =============================================
-- Test 6: divergent LOT -- capped at the lesser quantity, not closed
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-SF-B');
DECLARE @Def BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SF');
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @B, @LocationId = @Cell, @DefectCodeId = @Def, @Quantity = 5,
    @AppUserId = 1, @OperationTypeCode = N'MachiningIn';
DECLARE @S5 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfDiverge] 5 refused (only 4 available)', @Expected = N'0', @Actual = @S5;
DELETE FROM #R;

INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @B, @LocationId = @Cell, @DefectCodeId = @Def, @Quantity = 4,
    @AppUserId = 1, @OperationTypeCode = N'MachiningIn';
DECLARE @S4 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfDiverge] 4 accepted', @Expected = N'1', @Actual = @S4;
DECLARE @Shape NVARCHAR(50) = (SELECT CAST(l.PieceCount AS NVARCHAR(10)) + N'/' + CAST(l.InventoryAvailable AS NVARCHAR(10)) + N'/' + sc.Code
                               FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.LotName = N'SFT-B1');
EXEC test.Assert_IsEqual @TestName = N'[SfDiverge] B1 = 6 pieces / 0 available / still Good', @Expected = N'6/0/Good', @Actual = @Shape;
DROP TABLE #R;
GO

-- =============================================
-- Test 7: guards -- Quantity <= 0, additive operation
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-SF-B');
DECLARE @Def BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SF');
DECLARE @AddOp NVARCHAR(20) = (SELECT TOP 1 Code FROM Parts.OperationType WHERE ScrapIsAdditive = 1 ORDER BY Id);
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @B, @LocationId = @Cell, @DefectCodeId = @Def, @Quantity = 0,
    @AppUserId = 1, @OperationTypeCode = N'AssemblyOut';
DECLARE @SZ NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfGuard] Quantity 0 refused', @Expected = N'0', @Actual = @SZ;
DELETE FROM #R;

INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @B, @LocationId = @Cell, @DefectCodeId = @Def, @Quantity = 1,
    @AppUserId = 1, @OperationTypeCode = @AddOp;
DECLARE @SA NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfGuard] additive operation refused', @Expected = N'0', @Actual = @SA;
DROP TABLE #R;
GO

-- =============================================
-- Test 8: several reasons in one entry (@LinesJson) -- 6 of DEF then 7 of DEF2
--         along M1 (10, older) and M2 (10): M1 = 6 DEF + 4 DEF2 (closed),
--         M2 = 3 DEF2. One transaction, terminal stamped on every row.
-- =============================================
DECLARE @Now  DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-SF-A');
INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt)
VALUES (N'TEST-DEF-SF2', N'Scrap FIFO test defect 2', NULL, 0, @Now);
INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt, DeprecatedAt)
VALUES (N'TEST-DEF-SFX', N'Scrap FIFO deprecated defect', NULL, 0, @Now, @Now);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'SFT-M2', @A, 1, @Good, 10, 10, @Cell, 1, DATEADD(SECOND, 40, @Now));
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'SFT-M1', @A, 1, @Good, 10, 10, @Cell, 1, DATEADD(SECOND, 30, @Now));
GO

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-SF-A');
DECLARE @Def  BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SF');
DECLARE @Def2 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SF2');
DECLARE @Term BIGINT = @Cell;
DECLARE @Lines NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Def AS NVARCHAR(20)) + N',"quantity":6},{"defectCodeId":'
                             + CAST(@Def2 AS NVARCHAR(20)) + N',"quantity":7}]';
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @A, @LocationId = @Cell, @Remarks = N'multi', @AppUserId = 1,
    @TerminalLocationId = @Term, @OperationTypeCode = N'MachiningOut', @LinesJson = @Lines;

DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfMulti] Status is 1', @Expected = N'1', @Actual = @S;
DECLARE @Split NVARCHAR(200) = (SELECT STRING_AGG(l.LotName + N'=' + CAST(re.Quantity AS NVARCHAR(10)) + N'/' + dc.Code, N',') WITHIN GROUP (ORDER BY re.Id)
                                FROM Workorder.RejectEvent re
                                INNER JOIN Lots.Lot l ON l.Id = re.LotId
                                INNER JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId
                                WHERE re.Remarks = N'multi');
EXEC test.Assert_IsEqual @TestName = N'[SfMulti] one reject row per (LOT, reason), FIFO then entry order',
    @Expected = N'SFT-M1=6/TEST-DEF-SF,SFT-M1=4/TEST-DEF-SF2,SFT-M2=3/TEST-DEF-SF2', @Actual = @Split;
DECLARE @M1 NVARCHAR(50) = (SELECT CAST(l.PieceCount AS NVARCHAR(10)) + N'/' + CAST(l.InventoryAvailable AS NVARCHAR(10)) + N'/' + sc.Code
                            FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.LotName = N'SFT-M1');
EXEC test.Assert_IsEqual @TestName = N'[SfMulti] M1 drained across two reasons and closed', @Expected = N'0/0/Closed', @Actual = @M1;
DECLARE @M2 NVARCHAR(50) = (SELECT CAST(l.PieceCount AS NVARCHAR(10)) + N'/' + CAST(l.InventoryAvailable AS NVARCHAR(10)) + N'/' + sc.Code
                            FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.LotName = N'SFT-M2');
EXEC test.Assert_IsEqual @TestName = N'[SfMulti] M2 10 -> 7, still Good', @Expected = N'7/7/Good', @Actual = @M2;
DECLARE @Hist NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusHistory h
                              INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName = N'SFT-M1');
EXEC test.Assert_IsEqual @TestName = N'[SfMulti] M1 closed exactly once', @Expected = N'1', @Actual = @Hist;
DECLARE @Stamped NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent
                                 WHERE Remarks = N'multi' AND TerminalLocationId = @Term AND ItemId = @A);
EXEC test.Assert_IsEqual @TestName = N'[SfMulti] terminal + part stamped on all three rows', @Expected = N'3', @Actual = @Stamped;
DECLARE @MsgOk BIT = CASE WHEN (SELECT Message FROM #R) LIKE N'Scrap recorded: 13 pcs of P-SF-A across 2 reasons from 2 LOTs (1 closed at zero).' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[SfMulti] message states total, reasons and LOTs', @Condition = @MsgOk;
DECLARE @First NVARCHAR(50) = (SELECT l.LotName + N'/' + dc.Code FROM Workorder.RejectEvent re
                               INNER JOIN Lots.Lot l ON l.Id = re.LotId
                               INNER JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId
                               WHERE re.Id = (SELECT NewId FROM #R));
EXEC test.Assert_IsEqual @TestName = N'[SfMulti] NewId is the first row written', @Expected = N'SFT-M1/TEST-DEF-SF', @Actual = @First;
DROP TABLE #R;
GO

-- =============================================
-- Test 9: short on the TOTAL -> refused whole (7 on hand; 5 + 3 asked)
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-SF-A');
DECLARE @Def  BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SF');
DECLARE @Def2 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SF2');
DECLARE @Lines NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Def AS NVARCHAR(20)) + N',"quantity":5},{"defectCodeId":'
                             + CAST(@Def2 AS NVARCHAR(20)) + N',"quantity":3}]';
DECLARE @Before NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent re
                                INNER JOIN Lots.Lot l ON l.Id = re.LotId WHERE l.LotName LIKE N'SFT-%');
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @A, @LocationId = @Cell, @AppUserId = 1, @OperationTypeCode = N'MachiningOut', @LinesJson = @Lines;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfMultiShort] Status is 0', @Expected = N'0', @Actual = @S;
DECLARE @MsgOk BIT = CASE WHEN (SELECT Message FROM #R) LIKE N'Only 7 of P-SF-A%1 short%' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[SfMultiShort] shortfall judged on the total (8 asked, 7 on hand)', @Condition = @MsgOk;
DECLARE @After NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent re
                               INNER JOIN Lots.Lot l ON l.Id = re.LotId WHERE l.LotName LIKE N'SFT-%');
EXEC test.Assert_IsEqual @TestName = N'[SfMultiShort] nothing recorded, not even the reason that fit', @Expected = @Before, @Actual = @After;
DECLARE @M2 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'SFT-M2');
EXEC test.Assert_IsEqual @TestName = N'[SfMultiShort] M2 still 7', @Expected = N'7', @Actual = @M2;
DROP TABLE #R;
GO

-- =============================================
-- Test 10: @LinesJson guards -- each refused, nothing recorded
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-SF-A');
DECLARE @Def  NVARCHAR(20) = (SELECT CAST(Id AS NVARCHAR(20)) FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SF');
DECLARE @DefX NVARCHAR(20) = (SELECT CAST(Id AS NVARCHAR(20)) FROM Quality.DefectCode WHERE Code = N'TEST-DEF-SFX');
DECLARE @Before NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent re
                                INNER JOIN Lots.Lot l ON l.Id = re.LotId WHERE l.LotName LIKE N'SFT-%');
DECLARE @Lines NVARCHAR(MAX), @S NVARCHAR(10);
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);

SET @Lines = N'[{"defectCodeId":' + @Def + N',"quantity":1},{"defectCodeId":' + @Def + N',"quantity":2}]';
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @A, @LocationId = @Cell, @AppUserId = 1, @OperationTypeCode = N'MachiningOut', @LinesJson = @Lines;
SET @S = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfMultiGuard] repeated reason refused', @Expected = N'0', @Actual = @S;
DELETE FROM #R;

SET @Lines = N'[{"defectCodeId":' + @Def + N',"quantity":0}]';
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @A, @LocationId = @Cell, @AppUserId = 1, @OperationTypeCode = N'MachiningOut', @LinesJson = @Lines;
SET @S = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfMultiGuard] zero-quantity line refused', @Expected = N'0', @Actual = @S;
DELETE FROM #R;

SET @Lines = N'[]';
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @A, @LocationId = @Cell, @AppUserId = 1, @OperationTypeCode = N'MachiningOut', @LinesJson = @Lines;
SET @S = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfMultiGuard] no lines refused', @Expected = N'0', @Actual = @S;
DELETE FROM #R;

SET @Lines = N'[{"defectCodeId":' + @DefX + N',"quantity":1}]';
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @A, @LocationId = @Cell, @AppUserId = 1, @OperationTypeCode = N'MachiningOut', @LinesJson = @Lines;
SET @S = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfMultiGuard] deprecated reason refused', @Expected = N'0', @Actual = @S;
DELETE FROM #R;

SET @Lines = N'not json';
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @A, @LocationId = @Cell, @AppUserId = 1, @OperationTypeCode = N'MachiningOut', @LinesJson = @Lines;
SET @S = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfMultiGuard] unreadable JSON refused', @Expected = N'0', @Actual = @S;
DELETE FROM #R;

SET @Lines = N'[7, "x"]';
INSERT INTO #R EXEC Workorder.RejectEvent_RecordByPartFifo
    @ItemId = @A, @LocationId = @Cell, @AppUserId = 1, @OperationTypeCode = N'MachiningOut', @LinesJson = @Lines;
SET @S = (SELECT CAST(Status AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SfMultiGuard] lines that are not objects refused', @Expected = N'0', @Actual = @S;
DROP TABLE #R;

DECLARE @After NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent re
                               INNER JOIN Lots.Lot l ON l.Id = re.LotId WHERE l.LotName LIKE N'SFT-%');
EXEC test.Assert_IsEqual @TestName = N'[SfMultiGuard] no reject row written by any refusal', @Expected = @Before, @Actual = @After;
GO

-- ---- cleanup ----
DELETE FROM Workorder.RejectEvent    WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'SFT-%');
DELETE FROM Lots.LotStatusHistory    WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'SFT-%');
DELETE FROM Lots.LotMovement         WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'SFT-%');
DELETE FROM Lots.LotEventLog         WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'SFT-%');
DELETE FROM Lots.Lot                 WHERE LotName LIKE N'SFT-%';
DELETE FROM Quality.DefectCode       WHERE Code IN (N'TEST-DEF-SF', N'TEST-DEF-SF2', N'TEST-DEF-SFX');
GO

EXEC test.EndTestFile;
GO
