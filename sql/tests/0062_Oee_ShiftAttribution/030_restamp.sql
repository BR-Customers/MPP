-- =============================================
-- File: 0062_Oee_ShiftAttribution/030_restamp.sql
-- Oee.ShiftOverride_Restamp / Oee.ShiftOverride_Apply -- the retroactive
-- re-attribution (spec sec 4.3, design D3).
--
-- This is the load-bearing half of the feature. An override is almost always
-- authored AFTER the shift ran long, so without the restamp the 15:00 basket
-- stays stamped Second forever and creating the override changes nothing.
--
-- Covers the remaining spec sec 8 obligations:
--   * extending First to 16:00 for ONE press moves a 15:00 event from Second to
--     First FOR THAT PRESS ONLY -- a sibling press is untouched;
--   * the restamp writes EXACTLY ONE audit row, reporting the correct count;
--   * re-applying is idempotent;
--   * deprecating the override RESTORES the original attribution.
-- Plus the OI-2 consequence: a Workorder.DieCastContribution row moves via its
-- stamped CellLocationId, and one with CellLocationId NULL is EXCLUDED rather
-- than guessed at (spec sec 5).
--
-- All event instants are UTC (that is what the columns store); all shift windows
-- are LOCAL Eastern (OI-38). Every probe is written as a local wall-clock
-- literal converted with AT TIME ZONE, never as a hand-computed UTC literal.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0062_Oee_ShiftAttribution/030_restamp.sql';
GO

-- ---- fixture ----
UPDATE Oee.ShiftSchedule
SET    DeprecatedAt = SYSUTCDATETIME()
WHERE  DeprecatedAt IS NULL AND Name NOT LIKE N'TEST_AT_%';

IF NOT EXISTS (SELECT 1 FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_First')
    INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
    VALUES (N'TEST_AT_First',  N'First 06:00-14:30',  '06:00:00', '14:30:00', 127, '2020-01-01', 1),
           (N'TEST_AT_Second', N'Second 14:30-22:30', '14:30:00', '22:30:00', 127, '2020-01-01', 1),
           (N'TEST_AT_Third',  N'Third 22:30-06:00',  '22:30:00', '06:00:00', 127, '2020-01-01', 1);

UPDATE Oee.ShiftSchedule SET DeprecatedAt = NULL WHERE Name LIKE N'TEST_AT_%';
DELETE FROM Oee.ShiftOverride WHERE BusinessDate BETWEEN '2026-10-16' AND '2026-10-23';

-- Own rows only, in FK order.
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'TEST_AT_%';
DELETE FROM Workorder.DieCastContribution
WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST_AT_%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'TEST_AT_%';

IF NOT EXISTS (SELECT 1 FROM Oee.Shift sh INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
               WHERE ss.Name = N'TEST_AT_First' AND CAST(sh.ActualStart AS DATE) = '2026-10-19')
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd)
    SELECT Id, '2026-10-19 06:00:00', '2026-10-19 14:30:00' FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_First'
    UNION ALL
    SELECT Id, '2026-10-19 14:30:00', '2026-10-19 22:30:00' FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_Second'
    UNION ALL
    SELECT Id, '2026-10-19 22:30:00', '2026-10-20 06:00:00' FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_Third';
GO

-- A basket to hang the die-cast contribution rows on. Minimal, direct insert --
-- Lots.DieCastLot_Open would drag in tool/cavity fixtures this file has no
-- opinion about.
DECLARE @EqA BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                       WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CrtActive, TotalInProcess, InventoryAvailable,
                      CreatedByUserId, CreatedAt)
SELECT N'TEST_AT_LOT1',
       (SELECT TOP 1 Id FROM Parts.Item ORDER BY Id),
       (SELECT Id FROM Lots.LotOriginType  WHERE Code = N'Manufactured'),
       (SELECT Id FROM Lots.LotStatusCode  WHERE Code = N'Good'),
       10, @EqA, 0, 0, 10, 1, SYSUTCDATETIME();
GO

-- Two downtime events and two contribution rows, ALL at 15:00 local on
-- 2026-10-19 and ALL stamped against SECOND -- which is the correct answer
-- until an override says otherwise.
DECLARE @EqA BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                       WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @EqB BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                       WHERE DefinitionCode = N'DieCastMachine' AND LocationId <> @EqA ORDER BY LocationId);
DECLARE @SecondShift BIGINT = (SELECT sh.Id FROM Oee.Shift sh
                               INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
                               WHERE ss.Name = N'TEST_AT_Second' AND CAST(sh.ActualStart AS DATE) = '2026-10-19');
DECLARE @SrcId BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @LotId BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TEST_AT_LOT1');
DECLARE @At15  DATETIME2(3) = CAST(CAST('2026-10-19 15:00:00' AS DATETIME2(3))
                                   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
DECLARE @At1530 DATETIME2(3) = CAST(CAST('2026-10-19 15:30:00' AS DATETIME2(3))
                                   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES (@EqA, NULL, @SecondShift, @At15, @At1530, @SrcId, N'TEST_AT_pressA'),
       (@EqB, NULL, @SecondShift, @At15, @At1530, @SrcId, N'TEST_AT_pressB');

INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId)
VALUES (@LotId, @SecondShift, 5, 1, @At15, @EqA),   -- press stamped -> restampable
       (@LotId, @SecondShift, 3, 1, @At15, NULL);   -- press unknown  -> excluded, never guessed
GO

-- =============================================
-- Test 1: CREATE the override. Extending First to 16:00 on press A must move
-- press A's 15:00 rows from Second to First -- and touch nothing on press B.
-- =============================================
DECLARE @EqA1 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @First1 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_First');

DECLARE @c1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c1 EXEC Oee.ShiftOverride_Create
    @LocationId = @EqA1, @ShiftScheduleId = @First1, @BusinessDate = '2026-10-19',
    @StartTime = '06:00:00', @EndTime = '16:00:00', @Reason = N'TEST_AT ran long', @AppUserId = 1;
DECLARE @s1 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c1);
EXEC test.Assert_IsEqual @TestName = N'[RS.create] override created',
     @Expected = N'1', @Actual = @s1;

DECLARE @nameA NVARCHAR(100) = (
    SELECT ss.Name FROM Oee.DowntimeEvent de
    INNER JOIN Oee.Shift sh ON sh.Id = de.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
    WHERE de.Remarks = N'TEST_AT_pressA');
DECLARE @nameB NVARCHAR(100) = (
    SELECT ss.Name FROM Oee.DowntimeEvent de
    INNER JOIN Oee.Shift sh ON sh.Id = de.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
    WHERE de.Remarks = N'TEST_AT_pressB');

EXEC test.Assert_IsEqual @TestName = N'[RS.create] the 15:00 downtime on the EXTENDED press moved to First',
     @Expected = N'TEST_AT_First', @Actual = @nameA;
EXEC test.Assert_IsEqual @TestName = N'[RS.create] the SIBLING press is untouched -- still Second',
     @Expected = N'TEST_AT_Second', @Actual = @nameB;

DECLARE @nameC NVARCHAR(100) = (
    SELECT ss.Name FROM Workorder.DieCastContribution dc
    INNER JOIN Oee.Shift sh ON sh.Id = dc.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
    WHERE dc.PieceDelta = 5 AND dc.CellLocationId = @EqA1);
DECLARE @nameN NVARCHAR(100) = (
    SELECT ss.Name FROM Workorder.DieCastContribution dc
    INNER JOIN Oee.Shift sh ON sh.Id = dc.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
    WHERE dc.PieceDelta = 3 AND dc.CellLocationId IS NULL);

EXEC test.Assert_IsEqual @TestName = N'[RS.create] the die-cast contribution moved via its stamped press',
     @Expected = N'TEST_AT_First', @Actual = @nameC;
EXEC test.Assert_IsEqual @TestName = N'[RS.create] a contribution with NO press stays put -- never guessed',
     @Expected = N'TEST_AT_Second', @Actual = @nameN;
GO

-- =============================================
-- Test 2: EXACTLY ONE audit row, reporting the correct moved count and the
-- shift pair it moved between.
-- =============================================
DECLARE @EqA2 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @First2 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_First');
DECLARE @Ov2 BIGINT = (SELECT Id FROM Oee.ShiftOverride
                       WHERE LocationId = @EqA2 AND ShiftScheduleId = @First2
                         AND BusinessDate = '2026-10-19' AND DeprecatedAt IS NULL);

DECLARE @auditCount NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
    INNER JOIN Audit.LogEventType  ev ON ev.Id = cl.LogEventTypeId
    WHERE cl.EntityId = @Ov2 AND et.Code = N'ShiftOverride'
      AND ev.Code = N'ShiftAttributionRestamped');
EXEC test.Assert_IsEqual @TestName = N'[RS.audit] the restamp wrote EXACTLY ONE audit row',
     @Expected = N'1', @Actual = @auditCount;

DECLARE @desc NVARCHAR(1000) = (
    SELECT TOP 1 cl.Description
    FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
    INNER JOIN Audit.LogEventType  ev ON ev.Id = cl.LogEventTypeId
    WHERE cl.EntityId = @Ov2 AND et.Code = N'ShiftOverride'
      AND ev.Code = N'ShiftAttributionRestamped'
    ORDER BY cl.Id DESC);
EXEC test.Assert_Contains @TestName = N'[RS.audit] reporting the correct moved count',
     @HaystackStr = @desc, @NeedleStr = N'Reattributed 2 events';
EXEC test.Assert_Contains @TestName = N'[RS.audit] naming the shift pair it moved between',
     @HaystackStr = @desc, @NeedleStr = N'from TEST_AT_Second to TEST_AT_First';

-- The convention's middle dot, and the equipment as SUBJECT.
DECLARE @locCode NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = @EqA2);
EXEC test.Assert_Contains @TestName = N'[RS.audit] subject is the equipment code',
     @HaystackStr = @desc, @NeedleStr = @locCode;
DECLARE @dot NVARCHAR(1) = Audit.ufn_MidDot();
EXEC test.Assert_Contains @TestName = N'[RS.audit] uses the middle-dot separator convention',
     @HaystackStr = @desc, @NeedleStr = @dot;

-- The counts survive in NewValue as structured data, not only in the prose.
DECLARE @moved NVARCHAR(10) = (
    SELECT TOP 1 CAST(JSON_VALUE(cl.NewValue, N'$.MovedTotal') AS NVARCHAR(10))
    FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
    INNER JOIN Audit.LogEventType  ev ON ev.Id = cl.LogEventTypeId
    WHERE cl.EntityId = @Ov2 AND et.Code = N'ShiftOverride'
      AND ev.Code = N'ShiftAttributionRestamped'
    ORDER BY cl.Id DESC);
EXEC test.Assert_IsEqual @TestName = N'[RS.audit] NewValue carries the machine-readable count',
     @Expected = N'2', @Actual = @moved;
GO

-- =============================================
-- Test 3: IDEMPOTENT. Re-applying moves nothing -- the data is unchanged and the
-- new audit row reports 0.
-- =============================================
DECLARE @EqA3 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @First3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_First');
DECLARE @Ov3 BIGINT = (SELECT Id FROM Oee.ShiftOverride
                       WHERE LocationId = @EqA3 AND ShiftScheduleId = @First3
                         AND BusinessDate = '2026-10-19' AND DeprecatedAt IS NULL);

DECLARE @a3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @a3 EXEC Oee.ShiftOverride_Apply @ShiftOverrideId = @Ov3, @AppUserId = 1;
DECLARE @s3 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @a3);
DECLARE @m3 NVARCHAR(500) = (SELECT Message FROM @a3);

EXEC test.Assert_IsEqual @TestName = N'[RS.idempotent] re-applying succeeds',
     @Expected = N'1', @Actual = @s3;
EXEC test.Assert_Contains @TestName = N'[RS.idempotent] and reports that nothing moved',
     @HaystackStr = @m3, @NeedleStr = N'Reattributed 0 events';

DECLARE @nameA3 NVARCHAR(100) = (
    SELECT ss.Name FROM Oee.DowntimeEvent de
    INNER JOIN Oee.Shift sh ON sh.Id = de.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
    WHERE de.Remarks = N'TEST_AT_pressA');
EXEC test.Assert_IsEqual @TestName = N'[RS.idempotent] attribution unchanged after a second apply',
     @Expected = N'TEST_AT_First', @Actual = @nameA3;
GO

-- =============================================
-- Test 4: DEPRECATE RESTORES. Removing the override reverts press A to the
-- plant-global window and moves the same rows back to Second.
-- =============================================
DECLARE @EqA4 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @First4 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_First');
DECLARE @Ov4 BIGINT = (SELECT Id FROM Oee.ShiftOverride
                       WHERE LocationId = @EqA4 AND ShiftScheduleId = @First4
                         AND BusinessDate = '2026-10-19' AND DeprecatedAt IS NULL);

DECLARE @d4 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @d4 EXEC Oee.ShiftOverride_Deprecate @Id = @Ov4, @AppUserId = 1;
DECLARE @s4 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @d4);
EXEC test.Assert_IsEqual @TestName = N'[RS.deprecate] override deprecated',
     @Expected = N'1', @Actual = @s4;

DECLARE @nameA4 NVARCHAR(100) = (
    SELECT ss.Name FROM Oee.DowntimeEvent de
    INNER JOIN Oee.Shift sh ON sh.Id = de.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
    WHERE de.Remarks = N'TEST_AT_pressA');
DECLARE @nameC4 NVARCHAR(100) = (
    SELECT ss.Name FROM Workorder.DieCastContribution dc
    INNER JOIN Oee.Shift sh ON sh.Id = dc.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
    WHERE dc.PieceDelta = 5 AND dc.CellLocationId = @EqA4);
DECLARE @nameB4 NVARCHAR(100) = (
    SELECT ss.Name FROM Oee.DowntimeEvent de
    INNER JOIN Oee.Shift sh ON sh.Id = de.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
    WHERE de.Remarks = N'TEST_AT_pressB');

EXEC test.Assert_IsEqual @TestName = N'[RS.deprecate] the downtime event is back on Second',
     @Expected = N'TEST_AT_Second', @Actual = @nameA4;
EXEC test.Assert_IsEqual @TestName = N'[RS.deprecate] the contribution is back on Second',
     @Expected = N'TEST_AT_Second', @Actual = @nameC4;
EXEC test.Assert_IsEqual @TestName = N'[RS.deprecate] the sibling press was never involved',
     @Expected = N'TEST_AT_Second', @Actual = @nameB4;

DECLARE @descD NVARCHAR(1000) = (
    SELECT TOP 1 cl.Description
    FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
    INNER JOIN Audit.LogEventType  ev ON ev.Id = cl.LogEventTypeId
    WHERE cl.EntityId = @Ov4 AND et.Code = N'ShiftOverride'
      AND ev.Code = N'ShiftAttributionRestamped'
    ORDER BY cl.Id DESC);
EXEC test.Assert_Contains @TestName = N'[RS.deprecate] audited as a move BACK to Second',
     @HaystackStr = @descD, @NeedleStr = N'from TEST_AT_First to TEST_AT_Second';
GO

-- =============================================
-- Test 5: DowntimeEvent_Start stamps through the resolver, not through
-- "whichever shift is open plant-wide" (spec sec 4.2). No Oee.Shift row is open
-- at all here -- the old lookup would have stamped NULL; the resolver still
-- finds the shift whose window covers now.
-- Uses a THIRD press so nothing above is disturbed.
-- =============================================
DECLARE @EqC BIGINT = (SELECT LocationId FROM (
        SELECT LocationId, ROW_NUMBER() OVER (ORDER BY LocationId) AS rn
        FROM Oee.ufn_ResolveOeeEquipment() WHERE DefinitionCode = N'DieCastMachine') x
    WHERE x.rn = 3);

-- A shift instance covering NOW, closed (ActualEnd set) so the plant-open-shift
-- lookup this proc used to do would find nothing.
DECLARE @NowLocal DATETIME2(3) = CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC'
                                      AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));
DECLARE @Today DATE = CAST(@NowLocal AS DATE);
DECLARE @NowSchedId BIGINT = (SELECT r.ShiftScheduleId
                              FROM Oee.ufn_ShiftIdForInstant(@EqC, SYSUTCDATETIME()) r);

DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'TEST_AT_%' AND LocationId = @EqC;

IF @NowSchedId IS NOT NULL
BEGIN
    DECLARE @Start DATETIME2(3) = (SELECT r.StartLocal FROM Oee.ufn_ShiftIdForInstant(@EqC, SYSUTCDATETIME()) r);
    DECLARE @End   DATETIME2(3) = (SELECT r.EndLocal   FROM Oee.ufn_ShiftIdForInstant(@EqC, SYSUTCDATETIME()) r);
    IF NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE ShiftScheduleId = @NowSchedId AND CAST(ActualStart AS DATE) = CAST(@Start AS DATE))
        INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@NowSchedId, @Start, @End);

    DECLARE @expectShift NVARCHAR(20) = (SELECT CAST(r.ShiftId AS NVARCHAR(20))
                                         FROM Oee.ufn_ShiftIdForInstant(@EqC, SYSUTCDATETIME()) r);

    DECLARE @st5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO @st5 EXEC Oee.DowntimeEvent_Start
        @LocationId = @EqC, @DowntimeSourceCodeId = NULL, @DowntimeReasonCodeId = NULL,
        @ShotCount = NULL, @AppUserId = 1, @TerminalLocationId = NULL;

    DECLARE @s5 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @st5);
    DECLARE @newEv BIGINT = (SELECT NewId FROM @st5);
    DECLARE @gotShift NVARCHAR(20) = (SELECT CAST(ShiftId AS NVARCHAR(20)) FROM Oee.DowntimeEvent WHERE Id = @newEv);

    EXEC test.Assert_IsEqual @TestName = N'[RS.start] DowntimeEvent_Start succeeded',
         @Expected = N'1', @Actual = @s5;
    EXEC test.Assert_IsEqual @TestName = N'[RS.start] stamped the RESOLVER''s shift, not the open-shift lookup',
         @Expected = @expectShift, @Actual = @gotShift;

    -- Close it so the one-open-event-per-location invariant is left clean.
    UPDATE Oee.DowntimeEvent SET EndedAt = SYSUTCDATETIME(), Remarks = N'TEST_AT_start' WHERE Id = @newEv;
END
GO

-- ---- teardown ----
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'TEST_AT_%';
DELETE FROM Workorder.DieCastContribution
WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST_AT_%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'TEST_AT_%';
DELETE FROM Oee.ShiftOverride WHERE BusinessDate BETWEEN '2026-10-16' AND '2026-10-23';
GO

EXEC test.EndTestFile;
GO
