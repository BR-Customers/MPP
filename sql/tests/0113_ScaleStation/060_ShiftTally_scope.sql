-- =============================================
-- File:         0113_ScaleStation/060_ShiftTally_scope.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-16
-- Description:
--   Workorder.ScaleStation_GetShiftTally (v1.2, stored-procedure review) and the
--   index it seeks (migration 0124, IX_ContainerTray_ClosedAt). 050_PressLog.sql
--   pins the headline counts; this file pins WHICH trays and boxes are counted, so a
--   plan change cannot quietly change the answer:
--     - a tray counts by its own ClosedAt in [shift start, shift end) -- start
--       included, end excluded -- whatever its box's CompletedAt (an open box's
--       closed trays count; a tray closed now in a box completed long ago counts);
--     - only boxes whose StationLocationId is this terminal: another station's box
--       and a station-less box are never counted, even with trays in the window;
--     - BoxesCompleted counts by the box's CompletedAt in the same half-open window.
--   Passes on v1.1 (no index, no hint) and v1.2 for the behaviour tests.
--   Reuses 020's TST-SS-* fixture; adds its own shift schedule and removes it.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0113_ScaleStation/060_ShiftTally_scope.sql';
GO

-- ==== index (0124) ====
DECLARE @IxId INT = (SELECT index_id FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ContainerTray') AND name = N'IX_ContainerTray_ClosedAt');
DECLARE @S NVARCHAR(400);
SET @S = ISNULL((SELECT type_desc + N'/unique=' + CAST(is_unique AS NVARCHAR(1)) + N'/filtered=' + CAST(has_filter AS NVARCHAR(1))
                 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ContainerTray') AND index_id = @IxId), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0124] IX_ContainerTray_ClosedAt exists, NONCLUSTERED, not unique, not filtered',
    @Expected = N'NONCLUSTERED/unique=0/filtered=0', @Actual = @S;
SET @S = ISNULL((SELECT STRING_AGG(c.name + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END, N',') WITHIN GROUP (ORDER BY ic.key_ordinal)
                 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = OBJECT_ID(N'Lots.ContainerTray') AND ic.index_id = @IxId AND ic.is_included_column = 0), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0124] key is (ClosedAt), the tally''s range predicate', @Expected = N'ClosedAt', @Actual = @S;
SET @S = ISNULL((SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY c.name)
                 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = OBJECT_ID(N'Lots.ContainerTray') AND ic.index_id = @IxId AND ic.is_included_column = 1), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0124] INCLUDE exactly (ContainerId, PartsClosedCount): covers the tally''s tray branch',
    @Expected = N'ContainerId,PartsClosedCount', @Actual = @S;
SET @S = CAST((SELECT COUNT(*) FROM dbo.SchemaVersion WHERE MigrationId = N'0124_containertray_closedat_index') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0124] migration recorded in dbo.SchemaVersion exactly once', @Expected = N'1', @Actual = @S;
GO

CREATE TABLE #T (ShiftName NVARCHAR(100), ShiftStartEt DATETIME2(3), ShiftEndEt DATETIME2(3), TraysClosed INT, PartsPacked INT,
                 BoxesCompleted INT, Refused INT, RefusedUnder INT, RefusedOver INT, RefusedOther INT);
CREATE TABLE #HiddenSched (Id BIGINT);
GO

-- ---- fixture: clean the TST-SS line, one shift covering now ----
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DELETE FROM Audit.InterfaceLog WHERE LocationId = @Term;
DELETE sl FROM Lots.ShippingLabel sl JOIN Lots.Container c ON c.Id = sl.ContainerId WHERE c.CurrentLocationId = @Line;
DELETE tr FROM Lots.ContainerTray tr JOIN Lots.Container c ON c.Id = tr.ContainerId WHERE c.CurrentLocationId = @Line;
DELETE FROM Lots.Container WHERE CurrentLocationId = @Line;
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TST-SST shift');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TST-SST shift';

INSERT INTO #HiddenSched SELECT Id FROM Oee.ShiftSchedule WHERE DeprecatedAt IS NULL;
UPDATE Oee.ShiftSchedule SET DeprecatedAt = SYSUTCDATETIME() WHERE Id IN (SELECT Id FROM #HiddenSched);
DECLARE @NowLocal DATETIME2(3) = CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));
INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TST-SST shift', CAST(DATEADD(HOUR, -2, @NowLocal) AS TIME(0)), CAST(DATEADD(HOUR, 2, @NowLocal) AS TIME(0)), 127, '2026-01-01', 1);
GO

-- Read the window the proc itself uses, then place trays and boxes around its edges.
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DELETE FROM #T; INSERT INTO #T EXEC Workorder.ScaleStation_GetShiftTally @TerminalLocationId = @Term;
DECLARE @S NVARCHAR(200) = (SELECT CONCAT(ShiftName, N'|', TraysClosed, N'|', BoxesCompleted) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally scope] empty station in a covering shift: zeros', @Expected = N'TST-SST shift|0|0', @Actual = @S;

DECLARE @From DATETIME2(3) = (SELECT CAST(ShiftStartEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) FROM #T);
DECLARE @To   DATETIME2(3) = (SELECT CAST(ShiftEndEt   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) FROM #T);
DECLARE @Now  DATETIME2(3) = SYSUTCDATETIME();
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-A');
DECLARE @CfgA BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @A AND ClosureMethod = N'ByWeight' AND DeprecatedAt IS NULL);

-- Box 1 (this station): completed exactly at the window start; trays at start (in),
-- 1 ms before start (out).
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId, CompletedAt)
VALUES (@A, @CfgA, @Line, 2, 1, @Term, @From);
DECLARE @C1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosureMethod)
VALUES (@C1, 1, 1, DATEADD(MILLISECOND, -1, @From), N'ByWeight'),
       (@C1, 2, 2, @From, N'ByWeight');

-- Box 2 (this station): completed a year ago, but a tray closed into it now (counts
-- by the tray's own ClosedAt; the box does not count as completed this shift).
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId, CompletedAt)
VALUES (@A, @CfgA, @Line, 2, 1, @Term, DATEADD(DAY, -365, @Now));
DECLARE @C2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosureMethod)
VALUES (@C2, 1, 4, DATEADD(DAY, -365, @Now), N'ByWeight'),
       (@C2, 2, 8, DATEADD(MINUTE, -1, @Now), N'ByWeight');

-- Box 3 (this station): still open; its closed tray counts, an unclosed tray does not.
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId)
VALUES (@A, @CfgA, @Line, 1, 1, @Term);
DECLARE @C3 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosureMethod)
VALUES (@C3, 1, 16, DATEADD(MINUTE, -2, @Now), N'ByWeight'),
       (@C3, 2, 32, NULL, NULL);

-- Box 4 (this station): completed 1 ms before the window end (counts); its tray at
-- the window end exactly (does not).
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId, CompletedAt)
VALUES (@A, @CfgA, @Line, 2, 1, @Term, DATEADD(MILLISECOND, -1, @To));
DECLARE @C4 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosureMethod)
VALUES (@C4, 1, 64, @To, N'ByWeight');

-- Box 5 (this station): completed at the window end exactly -> not counted.
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId, CompletedAt)
VALUES (@A, @CfgA, @Line, 2, 1, @Term, @To);

-- Box 6 (ANOTHER station) and box 7 (no station): trays and completion in the
-- window, never counted here.
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId, CompletedAt)
VALUES (@A, @CfgA, @Line, 2, 1, @Line, DATEADD(MINUTE, -3, @Now));
DECLARE @C6 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId, CompletedAt)
VALUES (@A, @CfgA, @Line, 2, 1, NULL, DATEADD(MINUTE, -3, @Now));
DECLARE @C7 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosureMethod)
VALUES (@C6, 1, 128, DATEADD(MINUTE, -3, @Now), N'ByWeight'),
       (@C7, 1, 256, DATEADD(MINUTE, -3, @Now), N'ByWeight');

DELETE FROM #T; INSERT INTO #T EXEC Workorder.ScaleStation_GetShiftTally @TerminalLocationId = @Term;
SET @S = (SELECT CONCAT(TraysClosed, N'|', PartsPacked) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally scope] trays by own ClosedAt in [start, end): start in, end out, old box in, open box in, other / no station out',
    @Expected = N'3|26', @Actual = @S;
SET @S = (SELECT CAST(BoxesCompleted AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally scope] boxes by CompletedAt in [start, end) at this station only (start + end-1ms in; end, a year ago, open, other / no station out)',
    @Expected = N'2', @Actual = @S;

-- The other station sees only its own box.
DELETE FROM #T; INSERT INTO #T EXEC Workorder.ScaleStation_GetShiftTally @TerminalLocationId = @Line;
SET @S = (SELECT CONCAT(TraysClosed, N'|', PartsPacked, N'|', BoxesCompleted) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally scope] another station counts only its own box and tray', @Expected = N'1|128|1', @Actual = @S;
GO

-- ---- teardown ----
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DELETE tr FROM Lots.ContainerTray tr JOIN Lots.Container c ON c.Id = tr.ContainerId WHERE c.CurrentLocationId = @Line;
DELETE FROM Lots.Container WHERE CurrentLocationId = @Line;
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TST-SST shift');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TST-SST shift';
UPDATE Oee.ShiftSchedule SET DeprecatedAt = NULL WHERE Id IN (SELECT Id FROM #HiddenSched);
DROP TABLE #HiddenSched; DROP TABLE #T;
GO
EXEC test.EndTestFile;
GO
