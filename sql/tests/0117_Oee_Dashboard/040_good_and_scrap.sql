-- =============================================
-- File:         0117_Oee_Dashboard/040_good_and_scrap.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-29
-- Description:  Good and scrap per shift for the OEE dashboard (spec
--               docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--               sec 6.4):
--                 Oee.ufn_ShiftGood   die cast contributions, trim checkpoint
--                                     credit, Manufactured FG LOTs
--                 Oee.ufn_ShiftScrap  every reject in the shift with its charge
--                                     family, placement and found-downstream flag
--
--               Two shifts on Mon 2030-02-04: A 07:01-15:01 and B 15:01-23:01
--               (odd minutes so no other schedule's window starts later and wins
--               Oee.ufn_ShiftIdForInstant). Everything recorded at 09:00 local
--               belongs to A, 17:00 to B.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0117_Oee_Dashboard/040_good_and_scrap.sql';
GO

-- ---- cleanup (FK-safe) ----
DELETE FROM Workorder.RejectEvent         WHERE Remarks LIKE N'ZZ-DSH%';
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-DSH%');
DELETE FROM Workorder.ProductionEvent     WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-DSH%');
DELETE FROM Lots.Lot                      WHERE LotName LIKE N'ZZ-DSH%';
DELETE FROM Parts.Item                    WHERE PartNumber LIKE N'ZZ-DSH%';
DELETE FROM Quality.DefectCode            WHERE Code LIKE N'ZZ-DSH-%';
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_GS_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_GS_%';
GO

-- ---- fixture ----
EXEC test.OeeDashFixture_Build;
GO
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_GS_A', N'A 07:01-15:01', '07:01:00', '15:01:00', 127, '2020-01-01', 1),
       (N'TEST_GS_B', N'B 15:01-23:01', '15:01:00', '23:01:00', 127, '2020-01-01', 1);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
SELECT Id, CASE Name WHEN N'TEST_GS_A' THEN '2030-02-04T07:01:00' ELSE '2030-02-04T15:01:00' END,
           CASE Name WHEN N'TEST_GS_A' THEN '2030-02-04T15:01:00' ELSE '2030-02-04T23:01:00' END, N'TEST_GS'
FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_GS_%';

INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt, ChargeToPartyId, IsNonRejectScrap)
SELECT v.Code, N'DSH test defect', NULL, 0, SYSUTCDATETIME(), p.Id, v.NonReject
FROM (VALUES (N'ZZ-DSH-D-DC', N'DieCast', 0), (N'ZZ-DSH-D-DM', N'DieMaintenance', 0),
             (N'ZZ-DSH-D-TS', N'TrimShop', 0), (N'ZZ-DSH-D-MS', N'MachineShop', 0),
             (N'ZZ-DSH-D-NM', N'MppNonSpecific', 0), (N'ZZ-DSH-D-NS', N'SupplierNonSpecific', 0),
             (N'ZZ-DSH-D-NR', N'DieCast', 1)) v (Code, Party, NonReject)
INNER JOIN Quality.ChargeToParty p ON p.Code = v.Party;

INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
VALUES ((SELECT Id FROM Parts.ItemType WHERE Code = N'Component'),    N'ZZ-DSH-CAST', N'DSH casting', 1, SYSUTCDATETIME(), 1),
       ((SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood'), N'ZZ-DSH-FG',   N'DSH finished good', 1, SYSUTCDATETIME(), 1);
GO

DECLARE @Cast BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'ZZ-DSH-CAST');
DECLARE @Fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'ZZ-DSH-FG');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Rcv  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @M1   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M1');
DECLARE @TrT  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR-T1');
DECLARE @LT   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L-T1');
-- 09:00 and 17:00 LOCAL on 2030-02-04, as UTC.
DECLARE @AtA DATETIME2(3) = CAST(CAST('2030-02-04T09:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
DECLARE @AtB DATETIME2(3) = CAST(CAST('2030-02-04T17:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CreatedAtTerminalId)
VALUES (N'ZZ-DSH-DC1',  @Cast, @Mfg, @Good, 57, 57, @M1,  1, @AtA, @M1),
       (N'ZZ-DSH-TR1',  @Cast, @Mfg, @Good, 60, 60, @TrT, 1, @AtA, @M1),
       (N'ZZ-DSH-FGR',  @Fg,   @Rcv, @Good, 99, 99, @LT,  1, @AtA, @LT);

-- M&A (spec v0.3.1 6.4, D18, D21): good = MintedPieceCount on LOTs the mint
-- stamped with ShiftId. FG1 was minted 24 in A and has since dropped to 17
-- (scrap / a split); FG1-01 is its split child (Manufactured, unstamped);
-- FGB was minted 12 in B.
DECLARE @GsA BIGINT = (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_GS_A');
DECLARE @GsB BIGINT = (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_GS_B');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CreatedAtTerminalId, ShiftId, MintedPieceCount)
VALUES (N'ZZ-DSH-FG1',    @Fg, @Mfg, @Good, 17, 17, @LT, 1, @AtA, @LT, @GsA,  24),
       (N'ZZ-DSH-FG1-01', @Fg, @Mfg, @Good,  5,  5, @LT, 1, @AtA, @LT, NULL, NULL),
       (N'ZZ-DSH-FGB',    @Fg, @Mfg, @Good, 12, 12, @LT, 1, @AtB, @LT, @GsB,  12);
GO

DECLARE @A   BIGINT = (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_GS_A');
DECLARE @B   BIGINT = (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_GS_B');
DECLARE @M1  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M1');
DECLARE @TrT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR-T1');
DECLARE @Dc1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'ZZ-DSH-DC1');
DECLARE @Tr1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'ZZ-DSH-TR1');
DECLARE @Src BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftAttributionSource ORDER BY Id);
DECLARE @TrimOut BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE oty.Code = N'TrimOut' ORDER BY ot.Id);
DECLARE @AtA DATETIME2(3) = CAST(CAST('2030-02-04T09:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
DECLARE @AtB DATETIME2(3) = CAST(CAST('2030-02-04T17:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

-- Die cast: 40 + 10 in A, 7 in B.
INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId, ShiftAttributionSourceId)
VALUES (@Dc1, @A, 40, 1, @AtA, @M1, @Src),
       (@Dc1, @A, 10, 1, DATEADD(MINUTE, 30, @AtA), @M1, @Src),
       (@Dc1, @B,  7, 1, @AtB, @M1, @Src);

-- Trim checkpoints (cumulative ShotCount): 30 in A, 50 in B (credit 20),
-- 55 on a rework pass (ShiftId NULL -- not shift production).
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId, TerminalLocationId, ShiftId)
VALUES (@Tr1, @TrimOut, @AtA, 30, 1, @TrT, @A),
       (@Tr1, @TrimOut, @AtB, 50, 1, @TrT, @B),
       (@Tr1, @TrimOut, DATEADD(MINUTE, 30, @AtB), 55, 1, @TrT, NULL);
GO

DECLARE @A   BIGINT = (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_GS_A');
DECLARE @B   BIGINT = (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_GS_B');
DECLARE @M1  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M1');
DECLARE @M2  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M2');
DECLARE @TR  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR');
DECLARE @L   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L');
DECLARE @Sup BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-SUP-T1');
DECLARE @Cast BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'ZZ-DSH-CAST');
DECLARE @AtA DATETIME2(3) = CAST(CAST('2030-02-04T09:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
DECLARE @AtB DATETIME2(3) = CAST(CAST('2030-02-04T17:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

INSERT INTO Workorder.RejectEvent (DefectCodeId, Quantity, AppUserId, RecordedAt, ItemId, ShiftId, CellLocationId, Remarks)
SELECT dc.Id, v.Qty, 1, v.At, @Cast, v.ShiftId, v.Cell, v.Remarks
FROM (VALUES
    (N'ZZ-DSH-D-DC',  3, @AtA, @A,   @M1,  N'ZZ-DSH r-dc-at-press'),
    (N'ZZ-DSH-D-DC',  2, @AtA, @A,   @L,   N'ZZ-DSH r-dc-on-line'),
    (N'ZZ-DSH-D-DM',  1, @AtA, @A,   @M2,  N'ZZ-DSH r-dm-at-press'),
    (N'ZZ-DSH-D-NM',  4, @AtA, @A,   @L,   N'ZZ-DSH r-nm-on-line'),
    (N'ZZ-DSH-D-DC',  6, @AtA, NULL, NULL, N'ZZ-DSH r-dc-no-cell'),
    (N'ZZ-DSH-D-NS',  8, @AtA, NULL, NULL, N'ZZ-DSH r-ns-no-cell'),
    (N'ZZ-DSH-D-DC',  5, @AtA, @A,   @Sup, N'ZZ-DSH r-dc-outside-unit'),
    (N'ZZ-DSH-D-DC', 11, @AtA, NULL, @M1,  N'ZZ-DSH r-dc-null-shift'),
    (N'ZZ-DSH-D-NR', 13, @AtA, @A,   @M1,  N'ZZ-DSH r-nonreject'),
    (N'ZZ-DSH-D-TS', 17, @AtA, @A,   @TR,  N'ZZ-DSH r-ts-at-shop'),
    (N'ZZ-DSH-D-DC',  9, @AtB, @B,   @M1,  N'ZZ-DSH r-dc-shift-b')
) v (Code, Qty, At, ShiftId, Cell, Remarks)
INNER JOIN Quality.DefectCode dc ON dc.Code = v.Code;

-- The split child FG1-01 is scrapped 2 on the line in shift B.
INSERT INTO Workorder.RejectEvent (LotId, DefectCodeId, Quantity, AppUserId, RecordedAt, ItemId, ShiftId, CellLocationId, Remarks)
SELECT l.Id, dc.Id, 2, 1, @AtB, l.ItemId, @B, @L, N'ZZ-DSH r-ms-split-child'
FROM Lots.Lot l CROSS JOIN Quality.DefectCode dc
WHERE l.LotName = N'ZZ-DSH-FG1-01' AND dc.Code = N'ZZ-DSH-D-MS';
GO

-- =============================================
-- Test 1: good
-- =============================================
DECLARE @A  BIGINT = (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_GS_A');
DECLARE @B  BIGINT = (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_GS_B');
DECLARE @M1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M1');
DECLARE @TR BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR');
DECLARE @L  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L');
DECLARE @v NVARCHAR(20);

SET @v = (SELECT CAST(SUM(Good) AS NVARCHAR(20)) FROM Oee.ufn_ShiftGood(@A) WHERE UnitLocationId = @M1);
EXEC test.Assert_IsEqual @TestName = N'[Good] DC press sums PieceDelta for the shift only', @Expected = N'50', @Actual = @v;
SET @v = (SELECT AreaFamily FROM Oee.ufn_ShiftGood(@A) WHERE UnitLocationId = @M1);
EXEC test.Assert_IsEqual @TestName = N'[Good] DC press row is diecast', @Expected = N'diecast', @Actual = @v;

SET @v = (SELECT CAST(SUM(Good) AS NVARCHAR(20)) FROM Oee.ufn_ShiftGood(@A) WHERE UnitLocationId = @TR);
EXEC test.Assert_IsEqual @TestName = N'[Good] trim first checkpoint credits its count (30) to the shop', @Expected = N'30', @Actual = @v;
SET @v = (SELECT CAST(SUM(Good) AS NVARCHAR(20)) FROM Oee.ufn_ShiftGood(@B) WHERE UnitLocationId = @TR);
EXEC test.Assert_IsEqual @TestName = N'[Good] trim checkpoint credit = count minus previous checkpoint (50-30)', @Expected = N'20', @Actual = @v;
SET @v = (SELECT CAST(PlacementIsArea AS NVARCHAR(20)) FROM Oee.ufn_ShiftGood(@A) WHERE UnitLocationId = @TR);
EXEC test.Assert_IsEqual @TestName = N'[Good] trim good is booked on the shop (area placement)', @Expected = N'1', @Actual = @v;
-- The rework pass (55) is excluded: shift B shows only 20, checked above.

SET @v = (SELECT CAST(SUM(Good) AS NVARCHAR(20)) FROM Oee.ufn_ShiftGood(@A) WHERE UnitLocationId = @L);
EXEC test.Assert_IsEqual @TestName = N'[Good] M&A FG counted on the line; Received-origin FG excluded', @Expected = N'24', @Actual = @v;
SET @v = (SELECT CAST(SUM(Good) AS NVARCHAR(20)) FROM Oee.ufn_ShiftGood(@B) WHERE UnitLocationId = @L);
EXEC test.Assert_IsEqual @TestName = N'[Good] M&A FG goes to the shift its CreatedAt falls in', @Expected = N'12', @Actual = @v;
-- FG1: PieceCount 17 now, minted 24; its unstamped split child FG1-01 (5) adds nothing.
SET @v = (SELECT CAST(SUM(Good) AS NVARCHAR(20)) FROM Oee.ufn_ShiftGood(@A) WHERE UnitLocationId = @L);
EXEC test.Assert_IsEqual @TestName = N'[Good] M&A good = MintedPieceCount, not current PieceCount; ShiftId NULL child not counted', @Expected = N'24', @Actual = @v;
-- The split child scrapped 2 in B: good in B is still the 12 minted there, the 2 count once as scrap.
SET @v = (SELECT CAST(SUM(Good) AS NVARCHAR(20)) FROM Oee.ufn_ShiftGood(@B) WHERE UnitLocationId = @L)
       + N'/' + (SELECT CAST(SUM(Quantity) AS NVARCHAR(20)) FROM Oee.ufn_ShiftScrap(@B) WHERE UnitLocationId = @L);
EXEC test.Assert_IsEqual @TestName = N'[Good] split child then scrap -> good = minted, scrap 1x', @Expected = N'12/2', @Actual = @v;
GO

-- =============================================
-- Test 2: scrap
-- =============================================
DECLARE @A  BIGINT = (SELECT s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_GS_A');
DECLARE @M1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M1');
DECLARE @M2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M2');
DECLARE @TR BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR');
DECLARE @L  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L');
DECLARE @s TABLE (Remarks NVARCHAR(500), ChargeFamily NVARCHAR(10), UnitLocationId BIGINT, FoundFamily NVARCHAR(10),
                  Quantity BIGINT, IsNonReject BIT, IsFoundDownstream BIT);
INSERT INTO @s
SELECT re.Remarks, x.ChargeFamily, x.UnitLocationId, x.FoundFamily, x.Quantity, x.IsNonReject, x.IsFoundDownstream
FROM Oee.ufn_ShiftScrap(@A) x
INNER JOIN Workorder.RejectEvent re ON re.Id = x.RejectEventId
WHERE re.Remarks LIKE N'ZZ-DSH%';
DECLARE @v NVARCHAR(50), @e NVARCHAR(50);

SET @e = CAST(@M1 AS NVARCHAR(50)) + N'|0';
SET @v = (SELECT CAST(UnitLocationId AS NVARCHAR(50)) + N'|' + CAST(IsFoundDownstream AS NVARCHAR(1)) FROM @s WHERE Remarks = N'ZZ-DSH r-dc-at-press');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] DC defect at press -> on press', @Expected = @e, @Actual = @v;

SET @v = (SELECT ISNULL(CAST(UnitLocationId AS NVARCHAR(50)), N'<NULL>') + N'|' + ChargeFamily + N'|' + CAST(IsFoundDownstream AS NVARCHAR(1)) FROM @s WHERE Remarks = N'ZZ-DSH r-dc-on-line');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] DC defect found on M&A line -> no unit, diecast, found downstream', @Expected = N'<NULL>|diecast|1', @Actual = @v;

SET @e = CAST(@M2 AS NVARCHAR(50));
SET @v = (SELECT CAST(UnitLocationId AS NVARCHAR(50)) FROM @s WHERE Remarks = N'ZZ-DSH r-dm-at-press');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] DieMaintenance at press -> on press', @Expected = @e, @Actual = @v;

SET @e = CAST(@L AS NVARCHAR(50)) + N'|ma';
SET @v = (SELECT CAST(UnitLocationId AS NVARCHAR(50)) + N'|' + ChargeFamily FROM @s WHERE Remarks = N'ZZ-DSH r-nm-on-line');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] MppNonSpecific on line -> on line', @Expected = @e, @Actual = @v;

SET @v = (SELECT ISNULL(CAST(UnitLocationId AS NVARCHAR(50)), N'<NULL>') + N'|' + ChargeFamily + N'|' + CAST(IsFoundDownstream AS NVARCHAR(1)) FROM @s WHERE Remarks = N'ZZ-DSH r-dc-no-cell');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] no-cell DC reject -> diecast, found downstream, plant shift by RecordedAt', @Expected = N'<NULL>|diecast|1', @Actual = @v;

SET @v = (SELECT ISNULL(ChargeFamily, N'<NULL>') + N'|' + CAST(IsFoundDownstream AS NVARCHAR(1)) FROM @s WHERE Remarks = N'ZZ-DSH r-ns-no-cell');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] no-cell Non-Specific -> ChargeFamily NULL', @Expected = N'<NULL>|0', @Actual = @v;

SET @v = (SELECT ISNULL(CAST(UnitLocationId AS NVARCHAR(50)), N'<NULL>') + N'|' + ChargeFamily + N'|' + CAST(IsFoundDownstream AS NVARCHAR(1)) FROM @s WHERE Remarks = N'ZZ-DSH r-dc-outside-unit');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] cell outside any unit, DC-charged -> Die Cast area level', @Expected = N'<NULL>|diecast|1', @Actual = @v;

SET @e = CAST(@M1 AS NVARCHAR(50));
SET @v = (SELECT CAST(UnitLocationId AS NVARCHAR(50)) FROM @s WHERE Remarks = N'ZZ-DSH r-dc-null-shift');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] ShiftId NULL row placed by RecordedAt', @Expected = @e, @Actual = @v;

SET @v = (SELECT CAST(IsNonReject AS NVARCHAR(1)) FROM @s WHERE Remarks = N'ZZ-DSH r-nonreject');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] non-reject scrap flagged IsNonReject 1', @Expected = N'1', @Actual = @v;

SET @e = CAST(@TR AS NVARCHAR(50)) + N'|trim';
SET @v = (SELECT CAST(UnitLocationId AS NVARCHAR(50)) + N'|' + ChargeFamily FROM @s WHERE Remarks = N'ZZ-DSH r-ts-at-shop');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] trim scrap lands on the shop', @Expected = @e, @Actual = @v;

DECLARE @n INT = (SELECT COUNT(*) FROM @s WHERE Remarks = N'ZZ-DSH r-dc-shift-b');
EXEC test.Assert_RowCount @TestName = N'[Scrap] another shift''s reject is not in this shift', @ExpectedCount = 0, @ActualCount = @n;

SET @n = (SELECT COUNT(*) FROM @s);
EXEC test.Assert_RowCount @TestName = N'[Scrap] ten of the eleven fixture rejects are in shift A', @ExpectedCount = 10, @ActualCount = @n;
GO

-- ---- cleanup ----
DELETE FROM Workorder.RejectEvent         WHERE Remarks LIKE N'ZZ-DSH%';
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-DSH%');
DELETE FROM Workorder.ProductionEvent     WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-DSH%');
DELETE FROM Lots.Lot                      WHERE LotName LIKE N'ZZ-DSH%';
DELETE FROM Parts.Item                    WHERE PartNumber LIKE N'ZZ-DSH%';
DELETE FROM Quality.DefectCode            WHERE Code LIKE N'ZZ-DSH-%';
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_GS_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_GS_%';
EXEC test.OeeDashFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
