-- =============================================
-- File: 0059_Oee_ShiftOverride/010_shiftoverride_crud.sql
-- Oee.ShiftOverride_Create / _Update / _Deprecate / _Get / _List / _ListEquipment.
-- Status-row contract (FDS-11-011): every proc captured via INSERT-EXEC into a
-- table variable matching its SELECT shape; assertions run against that.
-- NOTE: EXEC parameters are literals or @variables only -- never an inline
-- subquery/CAST/CASE (project convention), so every asserted value is hoisted
-- into a local first.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0059_Oee_ShiftOverride/010_shiftoverride_crud.sql';
GO

-- ---- fixture: two schedules (one same-day, one midnight-crossing) ----
DELETE FROM Oee.ShiftOverride
WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_SO_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_SO_%';

INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_SO_First', N'First 06-14 Mon-Fri', '06:00:00', '14:00:00', 31, '2020-01-01', 1),
       (N'TEST_SO_Third', N'Third 22-06 Mon-Fri', '22:00:00', '06:00:00', 31, '2020-01-01', 1);
GO

-- =============================================
-- Test 1: create a valid extension override on a die cast press.
-- =============================================
DECLARE @Sched BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SO_First');
DECLARE @Equip BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                         WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);

DECLARE @c1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c1 EXEC Oee.ShiftOverride_Create
    @LocationId = @Equip, @ShiftScheduleId = @Sched, @BusinessDate = '2026-09-14',
    @StartTime = '06:00:00', @EndTime = '16:00:00', @Reason = N'Overtime run', @AppUserId = 1;

DECLARE @s1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c1);
DECLARE @m1 NVARCHAR(500) = (SELECT Message FROM @c1);
DECLARE @n1 NVARCHAR(20) = (SELECT CAST(NewId AS NVARCHAR(20)) FROM @c1);
EXEC test.Assert_IsEqual @TestName = N'[SO.create] valid override succeeds',
     @Expected = N'1', @Actual = @s1;
EXEC test.Assert_IsNotNull @TestName = N'[SO.create] returns a NewId', @Value = @n1;
GO

-- =============================================
-- Test 2: duplicate (same equipment + shift + date) is REJECTED, not an exception.
-- =============================================
DECLARE @Sched2 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SO_First');
DECLARE @Equip2 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @c2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c2 EXEC Oee.ShiftOverride_Create
    @LocationId = @Equip2, @ShiftScheduleId = @Sched2, @BusinessDate = '2026-09-14',
    @StartTime = '06:00:00', @EndTime = '18:00:00', @AppUserId = 1;

DECLARE @s2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c2);
DECLARE @m2 NVARCHAR(500) = (SELECT Message FROM @c2);
DECLARE @n2 NVARCHAR(20) = (SELECT CAST(NewId AS NVARCHAR(20)) FROM @c2);
EXEC test.Assert_IsEqual @TestName = N'[SO.create] duplicate rejected with Status=0',
     @Expected = N'0', @Actual = @s2;
EXEC test.Assert_Contains @TestName = N'[SO.create] duplicate message names the conflict',
     @HaystackStr = @m2, @NeedleStr = N'already exists';
EXEC test.Assert_IsNull @TestName = N'[SO.create] duplicate returns NULL NewId', @Value = @n2;
GO

-- =============================================
-- Test 3: zero-length window (EndTime = StartTime) is rejected.
-- =============================================
DECLARE @Sched3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SO_First');
DECLARE @Equip3 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @c3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c3 EXEC Oee.ShiftOverride_Create
    @LocationId = @Equip3, @ShiftScheduleId = @Sched3, @BusinessDate = '2026-09-15',
    @StartTime = '06:00:00', @EndTime = '06:00:00', @AppUserId = 1;

DECLARE @s3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c3);
EXEC test.Assert_IsEqual @TestName = N'[SO.create] EndTime = StartTime rejected',
     @Expected = N'0', @Actual = @s3;
GO

-- =============================================
-- Test 4: a TERMINAL is not OEE equipment -- rejected even though
-- ufn_ResolveDowntimeScope resolves some terminals to themselves.
-- =============================================
DECLARE @Sched4 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SO_First');
DECLARE @Term BIGINT = (
    SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    WHERE ltd.Code = N'Terminal' AND l.DeprecatedAt IS NULL
      AND Oee.ufn_ResolveDowntimeScope(l.Id) = l.Id
    ORDER BY l.Id);

IF @Term IS NULL
BEGIN
    EXEC test.Assert_IsTrue @TestName = N'[SO.create] SKIPPED - no self-scoping Terminal in fixture',
         @Condition = 1;
END
ELSE
BEGIN
    DECLARE @c4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO @c4 EXEC Oee.ShiftOverride_Create
        @LocationId = @Term, @ShiftScheduleId = @Sched4, @BusinessDate = '2026-09-16',
        @StartTime = '06:00:00', @EndTime = '16:00:00', @AppUserId = 1;
    DECLARE @s4 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c4);
    DECLARE @m4 NVARCHAR(500) = (SELECT Message FROM @c4);
    EXEC test.Assert_IsEqual @TestName = N'[SO.create] terminal rejected as non-equipment',
         @Expected = N'0', @Actual = @s4;
    EXEC test.Assert_Contains @TestName = N'[SO.create] terminal message explains equipment rule',
         @HaystackStr = @m4, @NeedleStr = N'not OEE equipment';
END
GO

-- =============================================
-- Test 5: unknown schedule / unknown location rejected (not exceptions).
-- =============================================
DECLARE @Equip5 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @c5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c5 EXEC Oee.ShiftOverride_Create
    @LocationId = @Equip5, @ShiftScheduleId = 99999999, @BusinessDate = '2026-09-17',
    @StartTime = '06:00:00', @EndTime = '16:00:00', @AppUserId = 1;
DECLARE @s5 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c5);
EXEC test.Assert_IsEqual @TestName = N'[SO.create] unknown schedule rejected',
     @Expected = N'0', @Actual = @s5;

DECLARE @Sched5 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SO_First');
DECLARE @c5b TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c5b EXEC Oee.ShiftOverride_Create
    @LocationId = 99999999, @ShiftScheduleId = @Sched5, @BusinessDate = '2026-09-17',
    @StartTime = '06:00:00', @EndTime = '16:00:00', @AppUserId = 1;
DECLARE @s5b NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c5b);
EXEC test.Assert_IsEqual @TestName = N'[SO.create] unknown location rejected',
     @Expected = N'0', @Actual = @s5b;
GO

-- =============================================
-- Test 6: Update edits the window; Get reflects it.
-- =============================================
DECLARE @Sched6 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SO_First');
DECLARE @Id6 BIGINT = (SELECT Id FROM Oee.ShiftOverride
                       WHERE ShiftScheduleId = @Sched6 AND BusinessDate = '2026-09-14' AND DeprecatedAt IS NULL);

DECLARE @u6 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @u6 EXEC Oee.ShiftOverride_Update
    @Id = @Id6, @StartTime = '06:00:00', @EndTime = '17:30:00', @Reason = N'Extended again', @AppUserId = 1;
DECLARE @s6 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @u6);
DECLARE @m6 NVARCHAR(500) = (SELECT Message FROM @u6);
EXEC test.Assert_IsEqual @TestName = N'[SO.update] succeeds',
     @Expected = N'1', @Actual = @s6;

DECLARE @g6 TABLE (Id BIGINT, LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), ScheduleStartTime TIME(0), ScheduleEndTime TIME(0),
    BusinessDate DATE, StartTime TIME(0), EndTime TIME(0), Reason NVARCHAR(500), IsDeprecated BIT,
    CreatedAtEt DATETIME2(3), CreatedByInitials NVARCHAR(10), UpdatedAtEt DATETIME2(3), DeprecatedAtEt DATETIME2(3));
INSERT INTO @g6 EXEC Oee.ShiftOverride_Get @Id = @Id6;

DECLARE @g6End NVARCHAR(10) = (SELECT CONVERT(NVARCHAR(8), EndTime, 108) FROM @g6);
DECLARE @g6Base NVARCHAR(10) = (SELECT CONVERT(NVARCHAR(8), ScheduleEndTime, 108) FROM @g6);
DECLARE @g6Upd NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), UpdatedAtEt, 121) FROM @g6);
EXEC test.Assert_IsEqual @TestName = N'[SO.get] returns the updated EndTime',
     @Expected = N'17:30:00', @Actual = @g6End;
EXEC test.Assert_IsEqual @TestName = N'[SO.get] carries the schedule baseline EndTime',
     @Expected = N'14:00:00', @Actual = @g6Base;
EXEC test.Assert_IsNotNull @TestName = N'[SO.get] UpdatedAtEt populated after update', @Value = @g6Upd;
GO

-- =============================================
-- Test 7: List reports the wall-clock delta against the schedule baseline.
--   TEST_SO_First is 06:00-14:00 (480 min); the override is 06:00-17:30
--   (690 min) -> DeltaMinutes = 210.
-- =============================================
DECLARE @Sched7 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SO_First');
DECLARE @l7 TABLE (Id BIGINT, LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), ScheduleStartTime TIME(0), ScheduleEndTime TIME(0),
    BusinessDate DATE, StartTime TIME(0), EndTime TIME(0), StartLocal DATETIME2(3), EndLocal DATETIME2(3),
    DurationMinutes INT, DeltaMinutes INT, Reason NVARCHAR(500), IsDeprecated BIT, CreatedByInitials NVARCHAR(10));
INSERT INTO @l7 EXEC Oee.ShiftOverride_List @FromDate = '2026-09-14', @ToDate = '2026-09-14';

DECLARE @dur7 NVARCHAR(10) = (SELECT CAST(DurationMinutes AS NVARCHAR(10)) FROM @l7 WHERE ShiftScheduleId = @Sched7);
DECLARE @dlt7 NVARCHAR(10) = (SELECT CAST(DeltaMinutes AS NVARCHAR(10)) FROM @l7 WHERE ShiftScheduleId = @Sched7);
EXEC test.Assert_IsEqual @TestName = N'[SO.list] planned duration 690 min',
     @Expected = N'690', @Actual = @dur7;
EXEC test.Assert_IsEqual @TestName = N'[SO.list] delta vs schedule is +210 min',
     @Expected = N'210', @Actual = @dlt7;
GO

-- =============================================
-- Test 8: Deprecate; the row leaves the default list but survives with
-- @IncludeDeprecated = 1, and re-deprecating is a rejection, not an exception.
-- =============================================
DECLARE @Sched8 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_SO_First');
DECLARE @Id8 BIGINT = (SELECT Id FROM Oee.ShiftOverride
                       WHERE ShiftScheduleId = @Sched8 AND BusinessDate = '2026-09-14' AND DeprecatedAt IS NULL);

DECLARE @d8 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @d8 EXEC Oee.ShiftOverride_Deprecate @Id = @Id8, @AppUserId = 1;
DECLARE @s8 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @d8);
EXEC test.Assert_IsEqual @TestName = N'[SO.deprecate] succeeds', @Expected = N'1', @Actual = @s8;

DECLARE @l8 TABLE (Id BIGINT, LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), ScheduleStartTime TIME(0), ScheduleEndTime TIME(0),
    BusinessDate DATE, StartTime TIME(0), EndTime TIME(0), StartLocal DATETIME2(3), EndLocal DATETIME2(3),
    DurationMinutes INT, DeltaMinutes INT, Reason NVARCHAR(500), IsDeprecated BIT, CreatedByInitials NVARCHAR(10));
INSERT INTO @l8 EXEC Oee.ShiftOverride_List @FromDate = '2026-09-14', @ToDate = '2026-09-14';
DECLARE @cnt8 INT = (SELECT COUNT(*) FROM @l8);
EXEC test.Assert_RowCount @TestName = N'[SO.deprecate] hidden from the default list',
     @ExpectedCount = 0, @ActualCount = @cnt8;

DECLARE @l8b TABLE (Id BIGINT, LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), ScheduleStartTime TIME(0), ScheduleEndTime TIME(0),
    BusinessDate DATE, StartTime TIME(0), EndTime TIME(0), StartLocal DATETIME2(3), EndLocal DATETIME2(3),
    DurationMinutes INT, DeltaMinutes INT, Reason NVARCHAR(500), IsDeprecated BIT, CreatedByInitials NVARCHAR(10));
INSERT INTO @l8b EXEC Oee.ShiftOverride_List @FromDate = '2026-09-14', @ToDate = '2026-09-14', @IncludeDeprecated = 1;
DECLARE @cnt8b INT = (SELECT COUNT(*) FROM @l8b);
EXEC test.Assert_RowCount @TestName = N'[SO.deprecate] still visible with IncludeDeprecated',
     @ExpectedCount = 1, @ActualCount = @cnt8b;

-- Deprecated rows keep reporting their own delta (the List proc expands the
-- window inline rather than through the resolver, which ignores deprecated rows).
DECLARE @dlt8 NVARCHAR(10) = (SELECT CAST(DeltaMinutes AS NVARCHAR(10)) FROM @l8b);
EXEC test.Assert_IsEqual @TestName = N'[SO.deprecate] deprecated row still reports its delta',
     @Expected = N'210', @Actual = @dlt8;

DECLARE @d8b TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @d8b EXEC Oee.ShiftOverride_Deprecate @Id = @Id8, @AppUserId = 1;
DECLARE @s8b NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @d8b);
EXEC test.Assert_IsEqual @TestName = N'[SO.deprecate] re-deprecate rejected, not thrown',
     @Expected = N'0', @Actual = @s8b;

-- The unique index is filtered on DeprecatedAt IS NULL, so the same key may be
-- re-created after a deprecate.
DECLARE @Equip8 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                          WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @c8 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c8 EXEC Oee.ShiftOverride_Create
    @LocationId = @Equip8, @ShiftScheduleId = @Sched8, @BusinessDate = '2026-09-14',
    @StartTime = '06:00:00', @EndTime = '15:00:00', @AppUserId = 1;
DECLARE @s8c NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c8);
DECLARE @m8c NVARCHAR(500) = (SELECT Message FROM @c8);
EXEC test.Assert_IsEqual @TestName = N'[SO.deprecate] key reusable after deprecate',
     @Expected = N'1', @Actual = @s8c;
GO

-- =============================================
-- Test 9: the equipment picker and the Create validation agree, and the picker
-- excludes devices/stores.
-- =============================================
DECLARE @e9 TABLE (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), TierCode NVARCHAR(20),
    DefinitionCode NVARCHAR(50), ParentName NVARCHAR(200), DisplayLabel NVARCHAR(500));
INSERT INTO @e9 EXEC Oee.ShiftOverride_ListEquipment;

DECLARE @hasPress BIT = CASE WHEN EXISTS (SELECT 1 FROM @e9 WHERE DefinitionCode = N'DieCastMachine') THEN 1 ELSE 0 END;
DECLARE @hasLine  BIT = CASE WHEN EXISTS (SELECT 1 FROM @e9 WHERE DefinitionCode = N'ProductionLine') THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[SO.equip] picker returns die cast presses', @Condition = @hasPress;
EXEC test.Assert_IsTrue @TestName = N'[SO.equip] picker returns production lines', @Condition = @hasLine;

DECLARE @devCnt INT = (SELECT COUNT(*) FROM @e9 WHERE DefinitionCode IN (N'Terminal', N'Printer'));
EXEC test.Assert_RowCount @TestName = N'[SO.equip] picker excludes terminals and printers',
     @ExpectedCount = 0, @ActualCount = @devCnt;

DECLARE @tierCnt INT = (SELECT COUNT(*) FROM @e9 WHERE TierCode NOT IN (N'WorkCenter', N'Cell'));
EXEC test.Assert_RowCount @TestName = N'[SO.equip] picker excludes Area / Site / Enterprise tiers',
     @ExpectedCount = 0, @ActualCount = @tierCnt;

DECLARE @e9s TABLE (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), TierCode NVARCHAR(20),
    DefinitionCode NVARCHAR(50), ParentName NVARCHAR(200), DisplayLabel NVARCHAR(500));
INSERT INTO @e9s EXEC Oee.ShiftOverride_ListEquipment @SearchText = N'DC1-M0';
DECLARE @allCnt INT = (SELECT COUNT(*) FROM @e9);
DECLARE @subCnt INT = (SELECT COUNT(*) FROM @e9s);
DECLARE @narrows BIT = CASE WHEN @subCnt > 0 AND @subCnt < @allCnt THEN 1 ELSE 0 END;
DECLARE @narrowDetail NVARCHAR(200) = N'all=' + CAST(@allCnt AS NVARCHAR(10)) + N' filtered=' + CAST(@subCnt AS NVARCHAR(10));
EXEC test.Assert_IsTrue @TestName = N'[SO.equip] search narrows the picker',
     @Condition = @narrows, @Detail = @narrowDetail;
GO

-- =============================================
-- Test 10: audit trail -- Created / Updated / Deprecated all landed on the
-- ShiftOverride entity with the "<SUBJECT> . <CATEGORY> . <ACTION>" shape.
-- =============================================
DECLARE @auditCnt INT = (
    SELECT COUNT(*) FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
    WHERE et.Code = N'ShiftOverride');
DECLARE @auditOk BIT = CASE WHEN @auditCnt >= 3 THEN 1 ELSE 0 END;
DECLARE @auditDetail NVARCHAR(200) = N'ConfigLog rows for ShiftOverride = ' + CAST(@auditCnt AS NVARCHAR(10));
EXEC test.Assert_IsTrue @TestName = N'[SO.audit] ShiftOverride config-log rows written',
     @Condition = @auditOk, @Detail = @auditDetail;

DECLARE @desc NVARCHAR(500) = (
    SELECT TOP 1 cl.Description FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
    INNER JOIN Audit.LogEventType  ev ON ev.Id = cl.LogEventTypeId
    WHERE et.Code = N'ShiftOverride' AND ev.Code = N'Created'
    ORDER BY cl.Id DESC);
DECLARE @midDot NVARCHAR(10) = Audit.ufn_MidDot();
EXEC test.Assert_Contains @TestName = N'[SO.audit] Description carries the Shift Override category',
     @HaystackStr = @desc, @NeedleStr = N'Shift Override';
EXEC test.Assert_Contains @TestName = N'[SO.audit] Description uses the mid-dot separator',
     @HaystackStr = @desc, @NeedleStr = @midDot;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
