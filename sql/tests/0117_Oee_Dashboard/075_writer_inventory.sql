-- =============================================
-- File:         0117_Oee_Dashboard/075_writer_inventory.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-30
-- Description:  The writer inventory (OEE dashboard spec v0.3.2 sec 6.8) as a
--               test. A late edit reaches Oee.ShiftSummary only if it changes
--               a fingerprint, so this pins, column by column, that every
--               value an inventory writer can change AND the calculation reads
--               moves the fingerprint -- and that undoing it restores the
--               fingerprint (it is deterministic, not noise).
--                 per-shift  Oee.ufn_ShiftInputFingerprint:
--                   DowntimeEvent, RejectEvent, DieCastContribution, trim
--                   ProductionEvent, Lots.Lot mint stamp, Oee.Shift,
--                   ShiftOverride, ToolAssignment
--                 config     Oee.ufn_ShiftSummaryConfigFingerprint:
--                   DowntimeReasonCode, DefectCode, Location
--               Oee.ShiftSchedule is deliberately absent (2026-11-03): a
--               schedule edit is a line in the sand and changes no recorded
--               shift (0117/085_schedule_history.sql).
--               Column-level rather than proc-level: four inventory writers
--               (DowntimeEvent_UpdateReason / _UpdateTimes / _Void,
--               ShiftOverride_Restamp) have no fixture anywhere, and the rest
--               live in fifteen suites. A writer reaches the summary exactly
--               when it writes one of these columns; a writer added next year
--               is covered the same way. The last block checks every
--               inventory proc still exists, so a rename shows here.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0117_Oee_Dashboard/075_writer_inventory.sql';
GO

-- ---- fixture: shift W (and W2 to move rows into), one row in every input ----
EXEC test.OeeDashFixture_Build;
GO
DELETE FROM Workorder.RejectEvent WHERE Remarks = N'ZZ-WI';
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-WI%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-WI%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'ZZ-WI%';
DELETE FROM Oee.DowntimeEvent WHERE Remarks = N'ZZ-WI';
DELETE FROM Oee.ShiftOverride WHERE Reason = N'ZZ-WI';
DELETE FROM Oee.Shift WHERE Remarks LIKE N'TEST_WI_%';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_WI_Day';
DELETE FROM Parts.Item WHERE PartNumber = N'ZZ-WI-FG';
DELETE FROM Quality.DefectCode WHERE Code LIKE N'ZZ-WI-%';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-WI-DIE');
DELETE FROM Tools.Tool WHERE Code = N'ZZ-WI-DIE';

INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_WI_Day', N'WI 07:01-15:01', '07:01:00', '15:01:00', 127, '2020-01-01', 1);
DECLARE @Sched BIGINT = SCOPE_IDENTITY();
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2030-06-03T07:01:00', '2030-06-03T15:01:00', N'TEST_WI_W'),
       (@Sched, '2030-06-04T07:01:00', '2030-06-04T15:01:00', N'TEST_WI_W2');

INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt, ChargeToPartyId, IsNonRejectScrap)
SELECT v.Code, N'WI defect', NULL, 0, SYSUTCDATETIME(), p.Id, 0
FROM (VALUES (N'ZZ-WI-D1'), (N'ZZ-WI-D2')) v (Code) CROSS JOIN Quality.ChargeToParty p WHERE p.Code = N'DieCast';
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
VALUES ((SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood'), N'ZZ-WI-FG', N'WI part', 1, SYSUTCDATETIME(), 1);
INSERT INTO Tools.Tool (Code, Name, ToolTypeId, StatusCodeId, CreatedByUserId)
VALUES (N'ZZ-WI-DIE', N'WI die', (SELECT TOP 1 Id FROM Tools.ToolType ORDER BY Id), (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), 1);
GO

DECLARE @W   BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_WI_W');
DECLARE @M1  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M1');
DECLARE @LT  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L-T1');
DECLARE @TrT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR-T1');
DECLARE @Fg  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'ZZ-WI-FG');
DECLARE @D1  BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'ZZ-WI-D1');
DECLARE @Op  BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @Src BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftAttributionSource ORDER BY Id);
DECLARE @TrimOut BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE oty.Code = N'TrimOut' ORDER BY ot.Id);
DECLARE @At DATETIME2(3) = CAST(CAST('2030-06-03T09:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CreatedAtTerminalId, ShiftId, MintedPieceCount)
VALUES (N'ZZ-WI-L1', @Fg, (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured'),
        (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good'), 24, 24, @LT, 1, @At, @LT, @W, 24);
DECLARE @Lot BIGINT = SCOPE_IDENTITY();

INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks, IsApproximate, DurationMinutes)
VALUES (@M1, NULL, @W, @At, DATEADD(MINUTE, 30, @At), @Op, N'ZZ-WI', 1, 30);
INSERT INTO Workorder.RejectEvent (LotId, DefectCodeId, Quantity, AppUserId, RecordedAt, ItemId, ShiftId, CellLocationId, Remarks)
VALUES (@Lot, @D1, 3, 1, @At, @Fg, @W, @M1, N'ZZ-WI');
INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId, ShiftAttributionSourceId)
VALUES (@Lot, @W, 40, 1, @At, @M1, @Src);
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId, TerminalLocationId, ShiftId)
VALUES (@Lot, @TrimOut, @At, 30, 1, @TrT, @W);
GO

-- ---- the checks: each row = one change and its undo, run with sp_executesql ----
IF OBJECT_ID(N'tempdb..#Chk') IS NOT NULL DROP TABLE #Chk;
CREATE TABLE #Chk (N INT IDENTITY(1,1) PRIMARY KEY, Fp NVARCHAR(10), Name NVARCHAR(200), DoSql NVARCHAR(MAX), UndoSql NVARCHAR(MAX));
INSERT INTO #Chk (Fp, Name, DoSql, UndoSql) VALUES
-- DowntimeEvent: _Start/_End/_RecordApproximate/_RecordHistorical/_UpdateReason/_UpdateTimes/_Void, EndOfShiftEntry_Submit, DowntimeReasonCode_Assign, ShiftOverride_Restamp
 (N'shift', N'DowntimeEvent new entry (Start / Record*)',            N'INSERT INTO Oee.DowntimeEvent (LocationId, ShiftId, StartedAt, DowntimeSourceCodeId, Remarks) SELECT LocationId, ShiftId, StartedAt, DowntimeSourceCodeId, N''ZZ-WI-X'' FROM Oee.DowntimeEvent WHERE Remarks = N''ZZ-WI''', N'DELETE FROM Oee.DowntimeEvent WHERE Remarks = N''ZZ-WI-X'''),
 (N'shift', N'DowntimeEvent reason (UpdateReason / Assign)',         N'UPDATE Oee.DowntimeEvent SET DowntimeReasonCodeId = (SELECT TOP 1 Id FROM Oee.DowntimeReasonCode ORDER BY Id) WHERE Remarks = N''ZZ-WI''', N'UPDATE Oee.DowntimeEvent SET DowntimeReasonCodeId = NULL WHERE Remarks = N''ZZ-WI'''),
 (N'shift', N'DowntimeEvent duration (RecordApproximate / Submit)',   N'UPDATE Oee.DowntimeEvent SET DurationMinutes = 45 WHERE Remarks = N''ZZ-WI''', N'UPDATE Oee.DowntimeEvent SET DurationMinutes = 30 WHERE Remarks = N''ZZ-WI'''),
 (N'shift', N'DowntimeEvent approximate flag',                        N'UPDATE Oee.DowntimeEvent SET IsApproximate = 0 WHERE Remarks = N''ZZ-WI''', N'UPDATE Oee.DowntimeEvent SET IsApproximate = 1 WHERE Remarks = N''ZZ-WI'''),
 (N'shift', N'DowntimeEvent start time (UpdateTimes)',                N'UPDATE Oee.DowntimeEvent SET StartedAt = DATEADD(MINUTE, -5, StartedAt) WHERE Remarks = N''ZZ-WI''', N'UPDATE Oee.DowntimeEvent SET StartedAt = DATEADD(MINUTE, 5, StartedAt) WHERE Remarks = N''ZZ-WI'''),
 (N'shift', N'DowntimeEvent end time (End / UpdateTimes)',            N'UPDATE Oee.DowntimeEvent SET EndedAt = DATEADD(MINUTE, 5, EndedAt) WHERE Remarks = N''ZZ-WI''', N'UPDATE Oee.DowntimeEvent SET EndedAt = DATEADD(MINUTE, -5, EndedAt) WHERE Remarks = N''ZZ-WI'''),
 (N'shift', N'DowntimeEvent voided (Void)',                           N'UPDATE Oee.DowntimeEvent SET VoidedAt = SYSUTCDATETIME() WHERE Remarks = N''ZZ-WI''', N'UPDATE Oee.DowntimeEvent SET VoidedAt = NULL WHERE Remarks = N''ZZ-WI'''),
 (N'shift', N'DowntimeEvent location',                                N'UPDATE Oee.DowntimeEvent SET LocationId = (SELECT Id FROM Location.Location WHERE Code = N''ZZ-DSH-DC-M2'') WHERE Remarks = N''ZZ-WI''', N'UPDATE Oee.DowntimeEvent SET LocationId = (SELECT Id FROM Location.Location WHERE Code = N''ZZ-DSH-DC-M1'') WHERE Remarks = N''ZZ-WI'''),
 (N'shift', N'DowntimeEvent moved to another shift (Restamp)',        N'UPDATE Oee.DowntimeEvent SET ShiftId = (SELECT Id FROM Oee.Shift WHERE Remarks = N''TEST_WI_W2'') WHERE Remarks = N''ZZ-WI''', N'UPDATE Oee.DowntimeEvent SET ShiftId = (SELECT Id FROM Oee.Shift WHERE Remarks = N''TEST_WI_W'') WHERE Remarks = N''ZZ-WI'''),
-- RejectEvent: RejectEvent_Record / _RecordByPartFifo, DieCastScrap_Write, TrimOut_Record, TrimPartial_Record, MachiningOut_Mint, ContainerRework_Scrap, ControlledRunResult_Record, DieCastEntry_Restamp
 (N'shift', N'RejectEvent new row (every scrap writer)',              N'INSERT INTO Workorder.RejectEvent (LotId, DefectCodeId, Quantity, AppUserId, RecordedAt, ItemId, ShiftId, CellLocationId, Remarks) SELECT LotId, DefectCodeId, 1, 1, RecordedAt, ItemId, ShiftId, CellLocationId, N''ZZ-WI-X'' FROM Workorder.RejectEvent WHERE Remarks = N''ZZ-WI''', N'DELETE FROM Workorder.RejectEvent WHERE Remarks = N''ZZ-WI-X'''),
 (N'shift', N'RejectEvent quantity',                                  N'UPDATE Workorder.RejectEvent SET Quantity = 4 WHERE Remarks = N''ZZ-WI''', N'UPDATE Workorder.RejectEvent SET Quantity = 3 WHERE Remarks = N''ZZ-WI'''),
 (N'shift', N'RejectEvent defect code',                               N'UPDATE Workorder.RejectEvent SET DefectCodeId = (SELECT Id FROM Quality.DefectCode WHERE Code = N''ZZ-WI-D2'') WHERE Remarks = N''ZZ-WI''', N'UPDATE Workorder.RejectEvent SET DefectCodeId = (SELECT Id FROM Quality.DefectCode WHERE Code = N''ZZ-WI-D1'') WHERE Remarks = N''ZZ-WI'''),
 (N'shift', N'RejectEvent cell',                                      N'UPDATE Workorder.RejectEvent SET CellLocationId = (SELECT Id FROM Location.Location WHERE Code = N''ZZ-DSH-DC-M2'') WHERE Remarks = N''ZZ-WI''', N'UPDATE Workorder.RejectEvent SET CellLocationId = (SELECT Id FROM Location.Location WHERE Code = N''ZZ-DSH-DC-M1'') WHERE Remarks = N''ZZ-WI'''),
 (N'shift', N'RejectEvent moved to another shift (DieCastEntry_Restamp)', N'UPDATE Workorder.RejectEvent SET ShiftId = (SELECT Id FROM Oee.Shift WHERE Remarks = N''TEST_WI_W2'') WHERE Remarks = N''ZZ-WI''', N'UPDATE Workorder.RejectEvent SET ShiftId = (SELECT Id FROM Oee.Shift WHERE Remarks = N''TEST_WI_W'') WHERE Remarks = N''ZZ-WI'''),
-- DieCastContribution: DieCastCredit_Write, DieCastEntry_Restamp, ShiftOverride_Restamp
 (N'shift', N'DieCastContribution new credit (DieCastCredit_Write)',  N'INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId, ShiftAttributionSourceId) SELECT LotId, ShiftId, 1, 1, EventAt, CellLocationId, ShiftAttributionSourceId FROM Workorder.DieCastContribution WHERE PieceDelta = 40 AND LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N''ZZ-WI-L1'')', N'DELETE FROM Workorder.DieCastContribution WHERE PieceDelta = 1 AND LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N''ZZ-WI-L1'')'),
 (N'shift', N'DieCastContribution piece delta',                       N'UPDATE Workorder.DieCastContribution SET PieceDelta = 41 WHERE LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N''ZZ-WI-L1'')', N'UPDATE Workorder.DieCastContribution SET PieceDelta = 40 WHERE LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N''ZZ-WI-L1'')'),
 (N'shift', N'DieCastContribution moved to another shift (Restamp)',  N'UPDATE Workorder.DieCastContribution SET ShiftId = (SELECT Id FROM Oee.Shift WHERE Remarks = N''TEST_WI_W2'') WHERE LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N''ZZ-WI-L1'')', N'UPDATE Workorder.DieCastContribution SET ShiftId = (SELECT Id FROM Oee.Shift WHERE Remarks = N''TEST_WI_W'') WHERE LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N''ZZ-WI-L1'')'),
-- trim checkpoints: TrimOut_Record, TrimPartial_Record
 (N'shift', N'Trim checkpoint count (TrimPartial_Record)',            N'UPDATE Workorder.ProductionEvent SET ShotCount = 31 WHERE LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N''ZZ-WI-L1'')', N'UPDATE Workorder.ProductionEvent SET ShotCount = 30 WHERE LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N''ZZ-WI-L1'')'),
 (N'shift', N'Trim checkpoint added on the same LOT (TrimOut_Record)', N'INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId, TerminalLocationId, ShiftId) SELECT LotId, OperationTemplateId, DATEADD(MINUTE, 1, EventAt), 35, 1, TerminalLocationId, NULL FROM Workorder.ProductionEvent WHERE ShotCount = 30 AND LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N''ZZ-WI-L1'')', N'DELETE FROM Workorder.ProductionEvent WHERE ShotCount = 35 AND LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N''ZZ-WI-L1'')'),
-- minted LOTs: Assembly_CompleteTray, MachiningOut_Mint, Lot_BackfillMintStamp
 (N'shift', N'Lot minted quantity',                                    N'UPDATE Lots.Lot SET MintedPieceCount = 25 WHERE LotName = N''ZZ-WI-L1''', N'UPDATE Lots.Lot SET MintedPieceCount = 24 WHERE LotName = N''ZZ-WI-L1'''),
 (N'shift', N'Lot shift stamp removed',                                N'UPDATE Lots.Lot SET ShiftId = NULL WHERE LotName = N''ZZ-WI-L1''', N'UPDATE Lots.Lot SET ShiftId = (SELECT Id FROM Oee.Shift WHERE Remarks = N''TEST_WI_W'') WHERE LotName = N''ZZ-WI-L1'''),
-- Oee.Shift: Shift_End / Shift_Reconcile
 (N'shift', N'Shift end moved (Shift_End / Reconcile)',                N'UPDATE Oee.Shift SET ActualEnd = DATEADD(MINUTE, 10, ActualEnd) WHERE Remarks = N''TEST_WI_W''', N'UPDATE Oee.Shift SET ActualEnd = DATEADD(MINUTE, -10, ActualEnd) WHERE Remarks = N''TEST_WI_W'''),
-- ShiftOverride_Create / _Update / _Deprecate
 (N'shift', N'ShiftOverride created for the shift''s day',            N'INSERT INTO Oee.ShiftOverride (LocationId, ShiftScheduleId, BusinessDate, StartTime, EndTime, Reason, CreatedByUserId) SELECT (SELECT Id FROM Location.Location WHERE Code = N''ZZ-DSH-DC-M1''), ShiftScheduleId, CAST(ActualStart AS DATE), ''07:01'', ''16:01'', N''ZZ-WI'', 1 FROM Oee.Shift WHERE Remarks = N''TEST_WI_W''', N'DELETE FROM Oee.ShiftOverride WHERE Reason = N''ZZ-WI'''),
-- ToolAssignment_Assign / _Release
 (N'shift', N'ToolAssignment overlapping the shift (Assign)',          N'INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, ReleasedAt, AssignedByUserId) SELECT t.Id, (SELECT Id FROM Location.Location WHERE Code = N''ZZ-DSH-DC-M1''), ''2030-06-03T12:00:00'', ''2030-06-03T13:00:00'', 1 FROM Tools.Tool t WHERE t.Code = N''ZZ-WI-DIE''', N'DELETE FROM Tools.ToolAssignment WHERE AssignedAt = ''2030-06-03T12:00:00'' AND ReleasedAt = ''2030-06-03T13:00:00'''),
-- configuration
 (N'config', N'DowntimeReasonCode IsExcused (DowntimeReasonCode_Update)', N'UPDATE Oee.DowntimeReasonCode SET IsExcused = 1 - IsExcused WHERE Id = (SELECT TOP 1 Id FROM Oee.DowntimeReasonCode ORDER BY Id)', N'UPDATE Oee.DowntimeReasonCode SET IsExcused = 1 - IsExcused WHERE Id = (SELECT TOP 1 Id FROM Oee.DowntimeReasonCode ORDER BY Id)'),
 (N'config', N'DefectCode charge party (DefectCode_Update)',           N'UPDATE Quality.DefectCode SET ChargeToPartyId = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N''TrimShop'') WHERE Code = N''ZZ-WI-D1''', N'UPDATE Quality.DefectCode SET ChargeToPartyId = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N''DieCast'') WHERE Code = N''ZZ-WI-D1'''),
 (N'config', N'DefectCode non-reject flag (DefectCode_Update)',        N'UPDATE Quality.DefectCode SET IsNonRejectScrap = 1 WHERE Code = N''ZZ-WI-D1''', N'UPDATE Quality.DefectCode SET IsNonRejectScrap = 0 WHERE Code = N''ZZ-WI-D1'''),
 (N'config', N'Location OEE flag (Location_Update / SaveAll)',         N'UPDATE Location.Location SET IsOeeEnabled = 0 WHERE Code = N''ZZ-DSH-DC-M2''', N'UPDATE Location.Location SET IsOeeEnabled = 1 WHERE Code = N''ZZ-DSH-DC-M2'''),
 (N'config', N'Location parent (Location_Update / MoveUp/Down)',       N'UPDATE Location.Location SET ParentLocationId = (SELECT Id FROM Location.Location WHERE Code = N''ZZ-DSH-TR'') WHERE Code = N''ZZ-DSH-DC-M2''', N'UPDATE Location.Location SET ParentLocationId = (SELECT Id FROM Location.Location WHERE Code = N''ZZ-DSH-DC'') WHERE Code = N''ZZ-DSH-DC-M2'''),
 (N'config', N'Location deprecated (Location_Deprecate)',              N'UPDATE Location.Location SET DeprecatedAt = ''2030-01-01'' WHERE Code = N''ZZ-DSH-DC-M2''', N'UPDATE Location.Location SET DeprecatedAt = NULL WHERE Code = N''ZZ-DSH-DC-M2''');
GO

DECLARE @W BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'TEST_WI_W');
DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM #Chk);
DECLARE @Kind NVARCHAR(10), @Name NVARCHAR(200), @Do NVARCHAR(MAX), @Undo NVARCHAR(MAX);
DECLARE @f0 VARBINARY(32), @f1 VARBINARY(32), @f2 VARBINARY(32), @c BIT, @t NVARCHAR(400);
WHILE @i <= @n
BEGIN
    SELECT @Kind = Fp, @Name = Name, @Do = DoSql, @Undo = UndoSql FROM #Chk WHERE N = @i;
    SET @f0 = CASE WHEN @Kind = N'config' THEN (SELECT Fingerprint FROM Oee.ufn_ShiftSummaryConfigFingerprint())
                   ELSE (SELECT Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@W)) END;
    EXEC sys.sp_executesql @Do;
    SET @f1 = CASE WHEN @Kind = N'config' THEN (SELECT Fingerprint FROM Oee.ufn_ShiftSummaryConfigFingerprint())
                   ELSE (SELECT Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@W)) END;
    EXEC sys.sp_executesql @Undo;
    SET @f2 = CASE WHEN @Kind = N'config' THEN (SELECT Fingerprint FROM Oee.ufn_ShiftSummaryConfigFingerprint())
                   ELSE (SELECT Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@W)) END;

    SET @c = CASE WHEN @f1 <> @f0 THEN 1 ELSE 0 END;
    SET @t = N'[Inventory] ' + @Name + N' -> fingerprint changes';
    EXEC test.Assert_IsTrue @TestName = @t, @Condition = @c;
    SET @c = CASE WHEN @f2 = @f0 THEN 1 ELSE 0 END;
    SET @t = N'[Inventory] ' + @Name + N' undone -> fingerprint restored';
    EXEC test.Assert_IsTrue @TestName = @t, @Condition = @c;
    SET @i += 1;
END
GO

-- ---- every inventory proc still exists (a rename must show here) ----
DECLARE @Missing NVARCHAR(MAX) = (
    SELECT STRING_AGG(p.Name, N', ')
    FROM (VALUES
        (N'Oee.DowntimeEvent_Start'), (N'Oee.DowntimeEvent_End'), (N'Oee.DowntimeEvent_RecordApproximate'),
        (N'Oee.DowntimeEvent_RecordHistorical'), (N'Oee.DowntimeEvent_UpdateReason'), (N'Oee.DowntimeEvent_UpdateTimes'),
        (N'Oee.DowntimeEvent_Void'), (N'Oee.EndOfShiftEntry_Submit'), (N'Oee.DowntimeReasonCode_Assign'),
        (N'Oee.ShiftOverride_Restamp'),
        (N'Workorder.RejectEvent_Record'), (N'Workorder.RejectEvent_RecordByPartFifo'), (N'Workorder.DieCastScrap_Write'),
        (N'Workorder.TrimOut_Record'), (N'Workorder.TrimPartial_Record'), (N'Workorder.MachiningOut_Mint'),
        (N'Lots.ContainerRework_Scrap'), (N'Quality.ControlledRunResult_Record'), (N'Workorder.DieCastEntry_Restamp'),
        (N'Workorder.DieCastCredit_Write'), (N'Workorder.Assembly_CompleteTray'), (N'Lots.Lot_BackfillMintStamp'),
        (N'Oee.Shift_End'), (N'Oee.Shift_Reconcile'),
        (N'Oee.ShiftOverride_Create'), (N'Oee.ShiftOverride_Update'), (N'Oee.ShiftOverride_Deprecate'),
        (N'Tools.ToolAssignment_Assign'), (N'Tools.ToolAssignment_Release'),
        (N'Oee.DowntimeReasonCode_Update'), (N'Quality.DefectCode_Update'), (N'Location.Location_Update')) p (Name)
    WHERE OBJECT_ID(p.Name, N'P') IS NULL);
DECLARE @c BIT = CASE WHEN @Missing IS NULL THEN 1 ELSE 0 END;
DECLARE @d NVARCHAR(1000) = N'Missing: ' + ISNULL(@Missing, N'');
EXEC test.Assert_IsTrue @TestName = N'[Inventory] every inventory proc exists', @Condition = @c, @Detail = @d;
GO

-- ---- cleanup ----
DROP TABLE #Chk;
DELETE FROM Workorder.RejectEvent WHERE Remarks LIKE N'ZZ-WI%';
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-WI%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-WI%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'ZZ-WI%';
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'ZZ-WI%';
DELETE FROM Oee.ShiftOverride WHERE Reason = N'ZZ-WI';
DELETE FROM Oee.Shift WHERE Remarks LIKE N'TEST_WI_%';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_WI_Day';
DELETE FROM Parts.Item WHERE PartNumber = N'ZZ-WI-FG';
DELETE FROM Quality.DefectCode WHERE Code LIKE N'ZZ-WI-%';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'ZZ-WI-DIE');
DELETE FROM Tools.Tool WHERE Code = N'ZZ-WI-DIE';
EXEC test.OeeDashFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
