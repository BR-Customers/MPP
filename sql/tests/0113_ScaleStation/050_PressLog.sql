-- =============================================
-- File:         0113_ScaleStation/050_PressLog.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-19
-- Description:
--   Workorder.ScaleStation_GetPressLog, GetShiftTally, GetRecentBoxes: the
--   scale station screen's reads (spec section 7). The press log is
--   Audit.InterfaceLog (every press, refusals included) joined to production
--   records for a good close. Reuses 020's TST-SS-* fixture; adds a shift
--   schedule covering "now" and removes it at the end so no later file sees it.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0113_ScaleStation/050_PressLog.sql';
GO

CREATE TABLE #P (InterfaceLogId BIGINT, LoggedAtEt DATETIME2(3), Net DECIMAL(10,4), Uom NVARCHAR(10), Verdict NVARCHAR(20),
                 Low DECIMAL(10,4), High DECIMAL(10,4), ScaleVerdict NVARCHAR(20), FlagsAgree BIT, Outcome NVARCHAR(20),
                 Detail NVARCHAR(1000), Description NVARCHAR(1000), LotId BIGINT, LotName NVARCHAR(50),
                 ContainerId BIGINT, TrayPosition INT, TraysPerContainer INT, AimShipperId NVARCHAR(50), LabelStatus NVARCHAR(20));
CREATE TABLE #T (ShiftName NVARCHAR(100), ShiftStartEt DATETIME2(3), ShiftEndEt DATETIME2(3), TraysClosed INT, PartsPacked INT,
                 BoxesCompleted INT, Refused INT, RefusedUnder INT, RefusedOver INT, RefusedOther INT);
CREATE TABLE #B (ContainerId BIGINT, CompletedAtEt DATETIME2(3), Pieces INT, Trays INT, LotName NVARCHAR(50),
                 AimShipperId NVARCHAR(50), LabelStatus NVARCHAR(20));
GO

-- ---- fixture: clear the terminal's press rows, boxes; one completed box with a labelled tray ----
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DELETE FROM Audit.InterfaceLog WHERE LocationId = @Term;
DELETE sl FROM Lots.ShippingLabel sl JOIN Lots.Container c ON c.Id = sl.ContainerId WHERE c.CurrentLocationId = @Line;
DELETE tr FROM Lots.ContainerTray tr JOIN Lots.Container c ON c.Id = tr.ContainerId WHERE c.CurrentLocationId = @Line;
DELETE FROM Lots.Container WHERE CurrentLocationId = @Line;
DELETE FROM Lots.Lot WHERE CurrentLocationId = @Line;
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TST-SS shift');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TST-SS shift';

DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-A');
DECLARE @CfgA BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @A AND ClosureMethod = N'ByWeight' AND DeprecatedAt IS NULL);
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

-- Box 1: complete, labelled, its last tray made by a press (LOT TSS-FGLOT1).
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
VALUES (N'TSS-FGLOT1', @A, @Mfg, @Good, 10, 10, @Line, 1);
DECLARE @Lot1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId, CompletedAt)
VALUES (@A, @CfgA, @Line, 2, 1, @Term, DATEADD(MINUTE, -5, @Now));
DECLARE @C1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosureMethod, FinishedGoodLotId)
VALUES (@C1, 4, 10, DATEADD(MINUTE, -5, @Now), N'ByWeight', @Lot1),
       (@C1, 3, 10, DATEADD(MINUTE, -15, @Now), N'ByWeight', NULL),
       (@C1, 2, 10, DATEADD(MINUTE, -25, @Now), N'ByWeight', NULL),
       (@C1, 1, 10, DATEADD(HOUR, -10, @Now), N'ByWeight', NULL);   -- outside the shift window
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintAttempts, PrintedAt)
VALUES (@C1, N'TSS-AIM-1', 1, 1, 1, DATEADD(MINUTE, -5, @Now));

-- Box 2: complete, label print failed.
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId, CompletedAt)
VALUES (@A, @CfgA, @Line, 2, 1, @Term, DATEADD(MINUTE, -2, @Now));
DECLARE @C2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintAttempts, LastPrintErrorCondition)
VALUES (@C2, N'TSS-AIM-2', 1, 1, 1, N'DispatchFailed');

-- Box 3: still open -> never in recent boxes.
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId)
VALUES (@A, @CfgA, @Line, 1, 1, @Term);

-- Press rows, oldest first.
DECLARE @L NVARCHAR(10) = N'Inbound';
EXEC Audit.Audit_LogInterfaceCall @SystemName = N'PLC:TSS', @Direction = @L, @LogEventTypeCode = N'PlcHandshake',
    @Description = N'Tray not closed', @RequestPayload = N'{"v":1,"net":15.3,"uom":"lb","verdict":"Under","low":17.75,"high":18.75,"scaleVerdict":"Under","agree":true}',
    @ErrorCondition = N'HandshakeFailed', @ErrorDescription = N'Tray is UNDER weight', @IsHighFidelity = 1,
    @LocationId = @Term, @ItemId = @A;
EXEC Audit.Audit_LogInterfaceCall @SystemName = N'PLC:TSS', @Direction = @L, @LogEventTypeCode = N'PlcHandshake',
    @Description = N'Scale flags warning', @RequestPayload = N'{"v":1,"net":18.3,"uom":"lb","verdict":"Ok","scaleVerdict":"Under","agree":false}',
    @ErrorCondition = N'ScaleFlagsMismatch', @ErrorDescription = N'differs', @IsHighFidelity = 1,
    @LocationId = @Term, @ItemId = @A;
EXEC Audit.Audit_LogInterfaceCall @SystemName = N'PLC:TSS', @Direction = @L, @LogEventTypeCode = N'PlcHandshake',
    @Description = N'ByWeight tray close', @RequestPayload = N'{"v":1,"net":18.3,"uom":"lb","verdict":"Ok","low":17.75,"high":18.75,"scaleVerdict":"Under","agree":false}',
    @IsHighFidelity = 1, @LocationId = @Term, @ItemId = @A, @LotId = @Lot1;
EXEC Audit.Audit_LogInterfaceCall @SystemName = N'PLC:TSS', @Direction = @L, @LogEventTypeCode = N'PlcHandshake',
    @Description = N'Tray not closed', @RequestPayload = N'{"v":1,"net":20.1,"uom":"lb","verdict":"Over","low":17.75,"high":18.75}',
    @ErrorCondition = N'HandshakeFailed', @IsHighFidelity = 1, @LocationId = @Term, @ItemId = @A;
EXEC Audit.Audit_LogInterfaceCall @SystemName = N'PLC:TSS', @Direction = @L, @LogEventTypeCode = N'PlcHandshake',
    @Description = N'Scale is in the wrong units', @RequestPayload = N'{"v":1,"net":8.3,"uom":"kg"}',
    @ErrorCondition = N'HandshakeFailed', @IsHighFidelity = 1, @LocationId = @Term;
-- Noise that must never appear: pre-0113 text row, a Zebra row at the terminal, non-JSON.
EXEC Audit.Audit_LogInterfaceCall @SystemName = N'PLC:TSS', @Direction = @L, @LogEventTypeCode = N'PlcHandshake',
    @Description = N'old', @RequestPayload = N'net=49.8 uom=lb verdict=Ok', @IsHighFidelity = 1, @LocationId = @Term;
EXEC Audit.Audit_LogInterfaceCall @SystemName = N'Zebra', @Direction = N'Outbound', @LogEventTypeCode = N'LabelDispatched',
    @Description = N'label', @RequestPayload = N'{"v":1,"net":1}', @IsHighFidelity = 1, @LocationId = @Term;
EXEC Audit.Audit_LogInterfaceCall @SystemName = N'PLC:TSS', @Direction = @L, @LogEventTypeCode = N'PlcHandshake',
    @Description = N'json, no v', @RequestPayload = N'{"net":2}', @IsHighFidelity = 1, @LocationId = @Term;

-- A shift covering now (local Eastern), all days.
DECLARE @NowLocal DATETIME2(3) = CAST(@Now AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));
INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TST-SS shift', CAST(DATEADD(HOUR, -2, @NowLocal) AS TIME(0)), CAST(DATEADD(HOUR, 2, @NowLocal) AS TIME(0)), 127, '2026-01-01', 1);
DECLARE @Sched BIGINT = SCOPE_IDENTITY();
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES (@Sched, DATEADD(HOUR, -2, @Now));
GO

-- ==== press log ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DELETE FROM #P; INSERT INTO #P EXEC Workorder.ScaleStation_GetPressLog @TerminalLocationId = @Term, @Top = 20;
DECLARE @Seq NVARCHAR(200) = (SELECT STRING_AGG(CONCAT(Outcome, N':', ISNULL(Verdict, N'-')), N',') WITHIN GROUP (ORDER BY InterfaceLogId DESC) FROM #P);
EXEC test.Assert_IsEqual @TestName = N'[PressLog] skips non-JSON, Zebra and flags-warning rows; newest first',
    @Expected = N'Refused:-,Refused:Over,Closed:Ok,Refused:Under', @Actual = @Seq;
DECLARE @Close NVARCHAR(200) = (SELECT CONCAT(LotName, N'|', TrayPosition, N'/', TraysPerContainer, N'|', AimShipperId, N'|', LabelStatus, N'|', ScaleVerdict, N'|', FlagsAgree)
                                FROM #P WHERE Outcome = N'Closed');
EXEC test.Assert_IsEqual @TestName = N'[PressLog] close row joins LOT, tray, box, AIM, label status',
    @Expected = N'TSS-FGLOT1|4/4|TSS-AIM-1|Sent|Under|0', @Actual = @Close;
DECLARE @Ref NVARCHAR(200) = (SELECT CONCAT(Detail, N'|', ISNULL(CAST(LotId AS NVARCHAR(20)), N'nolot'), N'|', Net, N'|', Low) FROM #P WHERE Verdict = N'Under');
EXEC test.Assert_IsEqual @TestName = N'[PressLog] refusal row has Detail and no LOT',
    @Expected = N'Tray is UNDER weight|nolot|15.3000|17.7500', @Actual = @Ref;
DECLARE @Et NVARCHAR(10) = (SELECT CASE WHEN COUNT(*) > 0 AND SUM(CASE WHEN p.LoggedAtEt = CAST(il.LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) THEN 0 ELSE 1 END) = 0
                                        THEN N'et' ELSE N'utc' END
                            FROM #P p JOIN Audit.InterfaceLog il ON il.Id = p.InterfaceLogId);
EXEC test.Assert_IsEqual @TestName = N'[PressLog] LoggedAtEt is Eastern', @Expected = N'et', @Actual = @Et;
DELETE FROM #P; INSERT INTO #P EXEC Workorder.ScaleStation_GetPressLog @TerminalLocationId = @Term, @Top = 2;
DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #P);
EXEC test.Assert_IsEqual @TestName = N'[PressLog] @Top honoured', @Expected = N'2', @Actual = @N;
GO

-- ==== shift tally ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DELETE FROM #T; INSERT INTO #T EXEC Workorder.ScaleStation_GetShiftTally @TerminalLocationId = @Term;
DECLARE @S NVARCHAR(200) = (SELECT CONCAT(ShiftName, N'|', TraysClosed, N'|', PartsPacked, N'|', BoxesCompleted, N'|', Refused, N'|', RefusedUnder, N'|', RefusedOver, N'|', RefusedOther) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally] counts trays/parts/boxes/refused under+over+other in the window; outside excluded',
    @Expected = N'TST-SS shift|3|30|2|3|1|1|1', @Actual = @S;
GO

-- ==== recent boxes ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DELETE FROM #B; INSERT INTO #B EXEC Workorder.ScaleStation_GetRecentBoxes @TerminalLocationId = @Term, @Top = 5;
DECLARE @S NVARCHAR(300) = (SELECT STRING_AGG(CONCAT(AimShipperId, N':', LabelStatus, N':', Pieces, N':', Trays, N':', ISNULL(LotName, N'-')), N',')
                            WITHIN GROUP (ORDER BY CompletedAtEt DESC) FROM #B);
EXEC test.Assert_IsEqual @TestName = N'[Boxes] completed boxes newest first with label status; open box not listed',
    @Expected = N'TSS-AIM-2:Failed:0:0:-,TSS-AIM-1:Sent:40:4:TSS-FGLOT1', @Actual = @S;
GO

-- ==== no covering shift -> zeros ====
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TST-SS shift');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TST-SS shift';
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DELETE FROM #T; INSERT INTO #T EXEC Workorder.ScaleStation_GetShiftTally @TerminalLocationId = @Term;
DECLARE @S NVARCHAR(200) = (SELECT CONCAT(COUNT(*), N'|', MAX(TraysClosed), N'|', MAX(Refused)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally] no covering shift returns one row of zeros', @Expected = N'1|0|0', @Actual = @S;
GO

DROP TABLE #P; DROP TABLE #T; DROP TABLE #B;
GO
EXEC test.EndTestFile;
GO
