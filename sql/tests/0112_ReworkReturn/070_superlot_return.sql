-- =============================================
-- File:        0112_ReworkReturn/070_superlot_return.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 5, Task 7 -- the super-lot side of return to vendor
--              (spec 5.4):
--                * a ReturnToSupplier result on a Received LOT member is APPLIED when
--                  it is recorded: Quality.ControlledRunResult_Record writes the
--                  Lots.VendorReturn row (pointing at the result) and takes the
--                  pieces off the LOT;
--                * it is refused on a Manufactured LOT member and on a container
--                  member, and when scrap + return exceed the LOT's pieces;
--                * ufn_ControlledRunMemberResults.AppliedReturnQty is added back in
--                  LeftOver, as AppliedScrapQty is;
--                * ListByRun: an applied return is IsApplied 1, CanVoid 0, and
--                  ControlledRunResult_Void refuses it;
--                * VendorReturn_Cancel voids the linked result in the same transaction;
--                * VendorReturn_Mark (LOT Detail) on a CURRENT member of an OPEN
--                  super-lot writes an applied ReturnToSupplier result; after the
--                  membership ended, or on a closed super-lot, it writes none
--                  (Review Focus 4).
--              LOTs named TEST-VR-S%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0112_ReworkReturn/070_superlot_return.sql';
GO
-- ---- teardown (FK-safe). VendorReturn points at ControlledRunResult, so it goes first. ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-VR-S%';
DECLARE @TdCon TABLE (Id BIGINT);
INSERT INTO @TdCon (Id) SELECT DISTINCT ContainerId FROM Lots.ContainerTray WHERE FinishedGoodLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.VendorReturn WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.ControlledRunResult;
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRunRelease;
DELETE FROM Quality.ControlledRunDeviation;
ALTER TABLE Quality.Signature DISABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.Signature;
ALTER TABLE Quality.Signature ENABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.ControlledRun;
DELETE FROM Lots.LotRework WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM @TdLot) OR ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO

DECLARE @App       BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Mk        BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials <> N'SYS' AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Def       BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @ItemId BIGINT, @Cell BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @Cell = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
ORDER BY eil.LocationId;
DECLARE @Cfg BIGINT = ISNULL((SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @ItemId), (SELECT TOP 1 Id FROM Parts.ContainerConfig));
DECLARE @n NVARCHAR(600);
DECLARE @e NVARCHAR(600);
DECLARE @m NVARCHAR(500);
DECLARE @L BIGINT;
DECLARE @j NVARCHAR(MAX);
DECLARE @Lc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @o  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s  TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @RL TABLE (ResultId BIGINT, MemberId BIGINT, DisplayName NVARCHAR(60), DispositionCode NVARCHAR(50), DispositionName NVARCHAR(100),
    Quantity INT, DefectCode NVARCHAR(50), DefectDescription NVARCHAR(500), Remarks NVARCHAR(500), RecordedByInitials NVARCHAR(20),
    RecordedAt DATETIME2(3), IsApplied BIT, IsVoided BIT, CanVoid BIT);
DECLARE @Rej0 INT = (SELECT COUNT(*) FROM Workorder.RejectEvent);

SET @n = CASE WHEN @App IS NOT NULL AND @Mk IS NOT NULL AND @ItemId IS NOT NULL AND @Cell IS NOT NULL
               AND @Cfg IS NOT NULL AND @Def IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[SlVR] fixture: users, item, location, container config, defect', @Expected = N'ok', @Actual = @n;

-- ---- LOTs ----
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 50, @AppUserId = @App, @LotName = N'TEST-VR-S1';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @S1 BIGINT = @L;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-VR-SM';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @SM BIGINT = @L;
UPDATE Lots.Lot SET LotOriginTypeId = @OriginMfg WHERE Id = @SM;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 30, @AppUserId = @App, @LotName = N'TEST-VR-S2';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @S2 BIGINT = @L;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-VR-S3';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @S3 BIGINT = @L;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 20, @AppUserId = @App, @LotName = N'TEST-VR-S4';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @S4 BIGINT = @L;
-- a completed container holding one Manufactured tray LOT (as 0109/130_results.sql)
DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CrtActive)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-VR-ST', @ItemId, @OriginMfg, 1, 6, 0, @Cell, @App, 0);
DECLARE @ST BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-VR-ST');
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@ItemId, @Cfg, @Cell, 2 /*Complete*/, SYSUTCDATETIME(), @App);
DECLARE @Con BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@Con, 1, @ST);

-- ---- super-lot 1: S1, SM, the container, S2, S3. super-lot 2: S4 ----
SET @j = (SELECT * FROM (VALUES (@S1, CAST(NULL AS BIGINT)), (@SM, NULL), (NULL, @Con), (@S2, NULL), (@S3, NULL)) v(lotId, containerId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'return test', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run BIGINT = (SELECT NewId FROM @o); DELETE FROM @o;
SET @j = (SELECT @S4 AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'return test 2', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run2 BIGINT = (SELECT NewId FROM @o); DELETE FROM @o;
DECLARE @Mem1 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @S1 AND EndedAt IS NULL);
DECLARE @MemM BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @SM AND EndedAt IS NULL);
DECLARE @MemC BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ContainerId = @Con AND EndedAt IS NULL);
DECLARE @Mem2 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @S2 AND EndedAt IS NULL);
DECLARE @Mem3 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @S3 AND EndedAt IS NULL);
DECLARE @Mem4 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @S4 AND EndedAt IS NULL);
SET @n = CASE WHEN @Run IS NOT NULL AND @Run2 IS NOT NULL AND @Mem1 IS NOT NULL AND @MemM IS NOT NULL AND @MemC IS NOT NULL
               AND @Mem2 IS NOT NULL AND @Mem3 IS NOT NULL AND @Mem4 IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[SlVR] fixture: two super-lots opened with their members', @Expected = N'ok', @Actual = @n;

-- ===== 1. Return 10 + Accepted 40 on the Received member, one submit =====
SET @j = (SELECT * FROM (VALUES (@Mem1, N'ReturnToSupplier', 10, N'wrong alloy'),
                                (@Mem1, N'Accepted',         40, CAST(NULL AS NVARCHAR(50)))) v(memberId, dispositionCode, quantity, remarks) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(1)), @m = Message FROM @o; DELETE FROM @o;
EXEC test.Assert_IsEqual @TestName = N'[SlVR] Record Return + Accepted: status 1', @Expected = N'1', @Actual = @n;
EXEC test.Assert_Contains @TestName = N'[SlVR] Record message names the returned pieces', @HaystackStr = @m, @NeedleStr = N'10 marked for return';
DECLARE @RetRes BIGINT = (SELECT rr.Id FROM Quality.ControlledRunResult rr JOIN Quality.DispositionCode dc ON dc.Id = rr.DispositionCodeId
                          WHERE rr.ControlledRunMemberId = @Mem1 AND dc.Code = N'ReturnToSupplier');
DECLARE @AccRes BIGINT = (SELECT rr.Id FROM Quality.ControlledRunResult rr JOIN Quality.DispositionCode dc ON dc.Id = rr.DispositionCodeId
                          WHERE rr.ControlledRunMemberId = @Mem1 AND dc.Code = N'Accepted');
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(SUM(CASE WHEN vr.ControlledRunResultId = @RetRes THEN 1 ELSE 0 END) AS NVARCHAR(5))
               + N'|' + CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @S1) AS NVARCHAR(5))
          FROM Lots.VendorReturn vr WHERE vr.LotId = @S1);
EXEC test.Assert_IsEqual @TestName = N'[SlVR] Return 10 on Received member: one VendorReturn with ControlledRunResultId, PieceCount 40', @Expected = N'1|1|40', @Actual = @n;
SET @n = (SELECT CAST(vr.Quantity AS NVARCHAR(5)) + N'|' + CAST(vr.PieceCountTaken AS NVARCHAR(5)) + N'|' + CAST(vr.InventoryTaken AS NVARCHAR(5))
               + N'|' + ISNULL(vr.Remarks, N'<NULL>') + N'|' + CAST(l.InventoryAvailable AS NVARCHAR(5))
          FROM Lots.VendorReturn vr JOIN Lots.Lot l ON l.Id = vr.LotId WHERE vr.LotId = @S1);
EXEC test.Assert_IsEqual @TestName = N'[SlVR] the return row records what was taken; InventoryAvailable 40', @Expected = N'10|10|10|wrong alloy|40', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent) - @Rej0 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[SlVR] a return is not scrap: no RejectEvent written', @Expected = N'0', @Actual = @n;
SET @n = (SELECT TOP 1 Description FROM Lots.LotEventLog WHERE LotId = @S1
          AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'VendorReturnMarked') ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[SlVR] VendorReturnMarked audit row on the LOT names the super-lot', @HaystackStr = @n, @NeedleStr = N'super-lot CR';

-- ===== 2. left-over =====
SET @n = (SELECT CAST(ReturnQty AS NVARCHAR(5)) + N'|' + CAST(AppliedReturnQty AS NVARCHAR(5)) + N'|' + CAST(LeftOver AS NVARCHAR(5))
          FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @Mem1);
EXEC test.Assert_IsEqual @TestName = N'[SlVR] LeftOver after Return 10 + Accepted 40 = 0', @Expected = N'10|10|0', @Actual = @n;
SET @n = (SELECT name FROM sys.dm_exec_describe_first_result_set(N'SELECT * FROM Quality.ufn_ControlledRunMemberResults(1)', NULL, 0)
          WHERE column_ordinal = (SELECT MAX(column_ordinal) FROM sys.dm_exec_describe_first_result_set(N'SELECT * FROM Quality.ufn_ControlledRunMemberResults(1)', NULL, 0)));
EXEC test.Assert_IsEqual @TestName = N'[SlVR] AppliedReturnQty is the last column of ufn_ControlledRunMemberResults', @Expected = N'AppliedReturnQty', @Actual = @n;

-- ===== 3. refusals =====
SET @j = (SELECT @MemM AS memberId, N'ReturnToSupplier' AS dispositionCode, 5 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o; DELETE FROM @o;
EXEC test.Assert_IsEqual @TestName = N'[SlVR] Return on Manufactured member refused',
    @Expected = N'0|LOT TEST-VR-SM was made at MPP; only purchased or received material can be returned to a vendor.', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Quality.ControlledRunResult WHERE ControlledRunMemberId = @MemM) AS NVARCHAR(5)) + N'|'
       + CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @SM) AS NVARCHAR(5)) + N'|'
       + CAST((SELECT COUNT(*) FROM Lots.VendorReturn WHERE LotId = @SM) AS NVARCHAR(5));
EXEC test.Assert_IsEqual @TestName = N'[SlVR] the refused Manufactured return wrote nothing', @Expected = N'0|20|0', @Actual = @n;

SET @j = (SELECT @MemC AS memberId, N'ReturnToSupplier' AS dispositionCode, 1 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o; DELETE FROM @o;
SET @e = N'0|Container ' + CAST(@Con AS NVARCHAR(20)) + N': a container cannot be returned to a vendor.';
EXEC test.Assert_IsEqual @TestName = N'[SlVR] Return on container member refused', @Expected = @e, @Actual = @n;

SET @j = (SELECT * FROM (VALUES (@Mem2, N'Scrap', 5, @Def), (@Mem2, N'ReturnToSupplier', 26, CAST(NULL AS BIGINT))) v(memberId, dispositionCode, quantity, defectCodeId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o; DELETE FROM @o;
EXEC test.Assert_IsEqual @TestName = N'[SlVR] scrap + return above the LOT''s pieces refused',
    @Expected = N'0|TEST-VR-S2: scrap and return of 31 is more than the 30 pieces it holds.', @Actual = @n;
SET @j = (SELECT @Mem2 AS memberId, N'ReturnToSupplier' AS dispositionCode, 31 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o; DELETE FROM @o;
EXEC test.Assert_IsEqual @TestName = N'[SlVR] return alone above the LOT''s pieces refused',
    @Expected = N'0|TEST-VR-S2: return of 31 is more than the 30 pieces it holds.', @Actual = @n;
SET @n = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @S2) AS NVARCHAR(5)) + N'|'
       + CAST((SELECT COUNT(*) FROM Quality.ControlledRunResult WHERE ControlledRunMemberId = @Mem2) AS NVARCHAR(5));
EXEC test.Assert_IsEqual @TestName = N'[SlVR] the refused over-total wrote nothing', @Expected = N'30|0', @Actual = @n;

-- ===== 4. an applied return cannot be voided =====
INSERT INTO @RL EXEC Quality.ControlledRunResult_ListByRun @Id = @Run;
SET @n = (SELECT CAST(IsApplied AS NVARCHAR(1)) + N'|' + CAST(CanVoid AS NVARCHAR(1)) FROM @RL WHERE ResultId = @RetRes);
EXEC test.Assert_IsEqual @TestName = N'[SlVR] applied return: IsApplied 1, CanVoid 0', @Expected = N'1|0', @Actual = @n;
SET @n = (SELECT CAST(IsApplied AS NVARCHAR(1)) + N'|' + CAST(CanVoid AS NVARCHAR(1)) FROM @RL WHERE ResultId = @AccRes);
EXEC test.Assert_IsEqual @TestName = N'[SlVR] the Accepted entry beside it: IsApplied 0, CanVoid 1', @Expected = N'0|1', @Actual = @n;
DELETE FROM @RL;

INSERT INTO @s EXEC Quality.ControlledRunResult_Void @ResultId = @RetRes, @Remarks = N'wrong', @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s; DELETE FROM @s;
EXEC test.Assert_IsEqual @TestName = N'[SlVR] Void of the applied return result refused',
    @Expected = N'0|These pieces were marked for return to the vendor from TEST-VR-S1. Cancel the return instead.', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Quality.ControlledRunResult WHERE Id = @RetRes AND VoidedAt IS NULL) AS NVARCHAR(5));
EXEC test.Assert_IsEqual @TestName = N'[SlVR] the refused void left the result live', @Expected = N'1', @Actual = @n;

-- ===== 5. cancelling the return voids its result, same transaction =====
DECLARE @VR1 BIGINT = (SELECT Id FROM Lots.VendorReturn WHERE LotId = @S1);
INSERT INTO @s EXEC Lots.VendorReturn_Cancel @VendorReturnId = @VR1, @CancelRemarks = N'counted wrong', @AppUserId = @Mk;
SELECT @n = CAST(Status AS NVARCHAR(1)) FROM @s; DELETE FROM @s;
EXEC test.Assert_IsEqual @TestName = N'[SlVR] cancel of the super-lot return: status 1', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(CASE WHEN VoidedAt IS NOT NULL THEN 1 ELSE 0 END AS NVARCHAR(1)) + N'|' + ISNULL(VoidRemarks, N'<NULL>')
               + N'|' + CAST(CASE WHEN VoidedByUserId = @Mk THEN 1 ELSE 0 END AS NVARCHAR(1))
          FROM Quality.ControlledRunResult WHERE Id = @RetRes);
EXEC test.Assert_IsEqual @TestName = N'[SlVR] cancel the return voids its result in the same transaction', @Expected = N'1|counted wrong|1', @Actual = @n;
SET @n = (SELECT CAST(PieceCount AS NVARCHAR(5)) + N'|' + CAST(InventoryAvailable AS NVARCHAR(5)) FROM Lots.Lot WHERE Id = @S1);
EXEC test.Assert_IsEqual @TestName = N'[SlVR] cancel restored the LOT to 50', @Expected = N'50|50', @Actual = @n;
SET @n = (SELECT CAST(ReturnQty AS NVARCHAR(5)) + N'|' + CAST(AppliedReturnQty AS NVARCHAR(5)) + N'|' + CAST(LeftOver AS NVARCHAR(5))
          FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @Mem1);
EXEC test.Assert_IsEqual @TestName = N'[SlVR] after cancel the return no longer counts: left-over 50 - 40 = 10', @Expected = N'0|0|10', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Audit.OperationLog ol JOIN Audit.LogEventType t ON t.Id = ol.LogEventTypeId
               WHERE t.Code = N'ControlledRunResultVoided' AND ol.EntityId = @Run) AS NVARCHAR(5));
EXEC test.Assert_IsEqual @TestName = N'[SlVR] the void is audited on the super-lot', @Expected = N'1', @Actual = @n;

-- ===== 6. VendorReturn_Mark (LOT Detail) on a current member of an open super-lot =====
DECLARE @Vr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @S2, @Quantity = 5, @Remarks = N'cracked flange', @AppUserId = @Mk;
SELECT @n = CAST(Status AS NVARCHAR(1)), @L = NewId FROM @Vr; DELETE FROM @Vr;
DECLARE @VR2 BIGINT = @L;
EXEC test.Assert_IsEqual @TestName = N'[SlVR] Mark on a current member: status 1', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + MAX(dc.Code) + N'|' + CAST(MAX(rr.Quantity) AS NVARCHAR(5)) + N'|' + ISNULL(MAX(rr.Remarks), N'<NULL>')
               + N'|' + CAST(MAX(CASE WHEN rr.RecordedByUserId = @Mk THEN 1 ELSE 0 END) AS NVARCHAR(1))
               + N'|' + CAST(MAX(CASE WHEN vr.ControlledRunResultId = rr.Id THEN 1 ELSE 0 END) AS NVARCHAR(1))
          FROM Quality.ControlledRunResult rr
          JOIN Quality.DispositionCode dc ON dc.Id = rr.DispositionCodeId
          CROSS JOIN Lots.VendorReturn vr
          WHERE rr.ControlledRunMemberId = @Mem2 AND vr.Id = @VR2);
EXEC test.Assert_IsEqual @TestName = N'[SlVR] VendorReturn_Mark on a current member writes an applied ReturnToSupplier result',
    @Expected = N'1|ReturnToSupplier|5|cracked flange|1|1', @Actual = @n;
INSERT INTO @RL EXEC Quality.ControlledRunResult_ListByRun @Id = @Run;
SET @n = (SELECT CAST(IsApplied AS NVARCHAR(1)) + N'|' + CAST(CanVoid AS NVARCHAR(1)) FROM @RL WHERE MemberId = @Mem2);
DELETE FROM @RL;
EXEC test.Assert_IsEqual @TestName = N'[SlVR] the auto-written result is applied and cannot be voided', @Expected = N'1|0', @Actual = @n;
SET @n = (SELECT CAST(AppliedReturnQty AS NVARCHAR(5)) + N'|' + CAST(LeftOver AS NVARCHAR(5))
          FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @Mem2);
EXEC test.Assert_IsEqual @TestName = N'[SlVR] left-over stays explained: 25 pieces + 5 applied - 5 accounted = 25', @Expected = N'5|25', @Actual = @n;

-- ===== 7. no result once the membership ended / the super-lot is closed (Review Focus 4) =====
INSERT INTO @s EXEC Quality.ControlledRun_RemoveMember @MemberId = @Mem3, @Remarks = N'not part of it', @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(1)) FROM @s; DELETE FROM @s;
EXEC test.Assert_IsEqual @TestName = N'[SlVR] fixture: S3 removed from the super-lot', @Expected = N'1', @Actual = @n;
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @S3, @Quantity = 4, @AppUserId = @Mk;
SELECT @n = CAST(Status AS NVARCHAR(1)), @L = NewId FROM @Vr; DELETE FROM @Vr;
SET @n = @n + N'|' + CAST((SELECT COUNT(*) FROM Quality.ControlledRunResult WHERE ControlledRunMemberId = @Mem3) AS NVARCHAR(5))
       + N'|' + ISNULL(CAST((SELECT ControlledRunResultId FROM Lots.VendorReturn WHERE Id = @L) AS NVARCHAR(20)), N'<NULL>')
       + N'|' + CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @S3) AS NVARCHAR(5));
EXEC test.Assert_IsEqual @TestName = N'[SlVR] VendorReturn_Mark after membership ended writes no result', @Expected = N'1|0|<NULL>|16', @Actual = @n;

-- super-lot 2 reads Closed while S4's membership row is still un-ended: the open-run
-- predicate alone must keep the result out.
UPDATE Quality.ControlledRun SET ControlledRunStatusId = 2 WHERE Id = @Run2;
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @S4, @Quantity = 4, @AppUserId = @Mk;
SELECT @n = CAST(Status AS NVARCHAR(1)), @L = NewId FROM @Vr; DELETE FROM @Vr;
SET @n = @n + N'|' + CAST((SELECT COUNT(*) FROM Quality.ControlledRunResult WHERE ControlledRunMemberId = @Mem4) AS NVARCHAR(5))
       + N'|' + ISNULL(CAST((SELECT ControlledRunResultId FROM Lots.VendorReturn WHERE Id = @L) AS NVARCHAR(20)), N'<NULL>')
       + N'|' + CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @S4) AS NVARCHAR(5));
EXEC test.Assert_IsEqual @TestName = N'[SlVR] VendorReturn_Mark on a closed super-lot writes no result', @Expected = N'1|0|<NULL>|16', @Actual = @n;

-- ===== 8. Cancel's locked status re-check (Task 6 review minor) =====
-- S3's return is open; the LOT is then Closed. This pins the refusal (pre-lock guard).
-- The same status predicate now also sits on the locked UPDATE as the concurrency
-- backstop; a single-session test cannot race it.
DECLARE @VR3 BIGINT = (SELECT Id FROM Lots.VendorReturn WHERE LotId = @S3);
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed') WHERE Id = @S3;
INSERT INTO @s EXEC Lots.VendorReturn_Cancel @VendorReturnId = @VR3, @CancelRemarks = N'no', @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(1)) FROM @s; DELETE FROM @s;
SET @n = @n + N'|' + CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @S3) AS NVARCHAR(5));
EXEC test.Assert_IsEqual @TestName = N'[SlVR] cancel on a Closed LOT refused, nothing restored', @Expected = N'0|16', @Actual = @n;
GO

-- ---- teardown ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-VR-S%';
DECLARE @TdCon TABLE (Id BIGINT);
INSERT INTO @TdCon (Id) SELECT DISTINCT ContainerId FROM Lots.ContainerTray WHERE FinishedGoodLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.VendorReturn WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.ControlledRunResult;
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRunRelease;
DELETE FROM Quality.ControlledRunDeviation;
ALTER TABLE Quality.Signature DISABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.Signature;
ALTER TABLE Quality.Signature ENABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.ControlledRun;
DELETE FROM Lots.LotRework WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM @TdLot) OR ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO

EXEC test.EndTestFile;
GO
