-- =============================================
-- File: 0062_Oee_ShiftAttribution/020_contiguity_validation.sql
-- OI-4 contiguity validation in Oee.ShiftOverride_Create / _Update, via
-- Oee.ufn_ShiftOverrideConflicts.
--
-- Design D1 requires attribution to be TOTAL and UNAMBIGUOUS. Two things must
-- be rejected and one must NOT be:
--
--   REJECT  a window overlapping ANOTHER OVERRIDE on the same equipment/date --
--           two overridden windows claiming the same instant is the one case
--           Oee.ufn_ShiftIdForInstant's precedence rule cannot break.
--   REJECT  a window that opens a GAP -- instants covered by no shift at all.
--   ACCEPT  a window overlapping a plant-GLOBAL window. That is the ordinary
--           extension and D1's whole point; requiring the matching shortening
--           first would be a deadlock, because the pair can only be authored one
--           row at a time.
--
-- All times LOCAL Eastern (OI-38). Fixtures come from
-- 010_shiftid_for_instant.sql's TEST_AT_* tiling (First 06:00-14:30,
-- Second 14:30-22:30, Third 22:30-06:00); this file re-asserts them so it can
-- also be run on its own.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0062_Oee_ShiftAttribution/020_contiguity_validation.sql';
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
GO

-- =============================================
-- Test 1: EXTENDING over the plant-global next shift is ACCEPTED.
-- (The headline case. If this rejects, the feature is unusable.)
-- =============================================
DECLARE @EqA BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                       WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @First BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_First');

DECLARE @c1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c1 EXEC Oee.ShiftOverride_Create
    @LocationId = @EqA, @ShiftScheduleId = @First, @BusinessDate = '2026-10-19',
    @StartTime = '06:00:00', @EndTime = '16:00:00', @Reason = N'TEST_AT extend', @AppUserId = 1;

DECLARE @s1 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c1);
DECLARE @m1 NVARCHAR(500) = (SELECT Message FROM @c1);
EXEC test.Assert_IsEqual @TestName = N'[CT.extend] extending over the GLOBAL next shift is accepted',
     @Expected = N'1', @Actual = @s1;
EXEC test.Assert_IsEqual @TestName = N'[CT.extend] with the ordinary success message',
     @Expected = N'Shift override created.', @Actual = @m1;
GO

-- =============================================
-- Test 2: a SECOND override that still starts at the old boundary now OVERLAPS
-- the extended First -- two overridden windows claiming 14:30-16:00. Rejected.
-- =============================================
DECLARE @EqA2 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @Second2 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_Second');

DECLARE @c2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c2 EXEC Oee.ShiftOverride_Create
    @LocationId = @EqA2, @ShiftScheduleId = @Second2, @BusinessDate = '2026-10-19',
    @StartTime = '14:30:00', @EndTime = '22:30:00', @Reason = N'TEST_AT clash', @AppUserId = 1;

DECLARE @s2 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c2);
DECLARE @m2 NVARCHAR(500) = (SELECT Message FROM @c2);
EXEC test.Assert_IsEqual @TestName = N'[CT.overlap] an OVERRIDE overlapping another OVERRIDE is rejected',
     @Expected = N'0', @Actual = @s2;
EXEC test.Assert_Contains @TestName = N'[CT.overlap] message names the shift it collides with',
     @HaystackStr = @m2, @NeedleStr = N'TEST_AT_First';
GO

-- =============================================
-- Test 3: authored the OTHER way round -- Second starting where First now ends
-- -- is contiguous and ACCEPTED. This is the pair D1 describes.
-- =============================================
DECLARE @EqA3 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @Second3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_Second');

DECLARE @c3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c3 EXEC Oee.ShiftOverride_Create
    @LocationId = @EqA3, @ShiftScheduleId = @Second3, @BusinessDate = '2026-10-19',
    @StartTime = '16:00:00', @EndTime = '22:30:00', @Reason = N'TEST_AT matching start', @AppUserId = 1;

DECLARE @s3 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c3);
EXEC test.Assert_IsEqual @TestName = N'[CT.pair] Second starting where First now ends is accepted',
     @Expected = N'1', @Actual = @s3;
GO

-- =============================================
-- Test 4: an UPDATE that re-opens the overlap is rejected by the same rule.
-- First is stretched from 16:00 to 17:00 while the Second override starts 16:00.
-- =============================================
DECLARE @EqA4 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @First4 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_First');
DECLARE @Ov4 BIGINT = (SELECT Id FROM Oee.ShiftOverride
                       WHERE LocationId = @EqA4 AND ShiftScheduleId = @First4
                         AND BusinessDate = '2026-10-19' AND DeprecatedAt IS NULL);

DECLARE @c4 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @c4 EXEC Oee.ShiftOverride_Update
    @Id = @Ov4, @StartTime = '06:00:00', @EndTime = '17:00:00',
    @Reason = N'TEST_AT stretch further', @AppUserId = 1;

DECLARE @s4 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c4);
DECLARE @m4 NVARCHAR(500) = (SELECT Message FROM @c4);
EXEC test.Assert_IsEqual @TestName = N'[CT.update] an UPDATE that re-opens the overlap is rejected',
     @Expected = N'0', @Actual = @s4;
EXEC test.Assert_Contains @TestName = N'[CT.update] message names the colliding override',
     @HaystackStr = @m4, @NeedleStr = N'TEST_AT_Second';

-- ... and the stored window is unchanged: a rejected update must not have written.
DECLARE @stillEnd NVARCHAR(8) = (SELECT CONVERT(NVARCHAR(8), EndTime, 108) FROM Oee.ShiftOverride WHERE Id = @Ov4);
EXEC test.Assert_IsEqual @TestName = N'[CT.update] the rejected update wrote nothing',
     @Expected = N'16:00:00', @Actual = @stillEnd;
GO

-- =============================================
-- Test 5: a SHORTENING that opens a GAP is rejected. On a clean press, pulling
-- First back to 13:00 leaves 13:00-14:30 attributable to no shift at all.
-- =============================================
DECLARE @EqB5 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine'
                          AND LocationId <> (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                                             WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId)
                        ORDER BY LocationId);
DECLARE @First5 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_First');

DECLARE @c5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c5 EXEC Oee.ShiftOverride_Create
    @LocationId = @EqB5, @ShiftScheduleId = @First5, @BusinessDate = '2026-10-19',
    @StartTime = '06:00:00', @EndTime = '13:00:00', @Reason = N'TEST_AT short', @AppUserId = 1;

DECLARE @s5 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c5);
DECLARE @m5 NVARCHAR(500) = (SELECT Message FROM @c5);
EXEC test.Assert_IsEqual @TestName = N'[CT.gap] a shortening that uncovers part of the day is rejected',
     @Expected = N'0', @Actual = @s5;
EXEC test.Assert_Contains @TestName = N'[CT.gap] message reports the uncovered minutes',
     @HaystackStr = @m5, @NeedleStr = N'90 minute';
GO

-- =============================================
-- Test 6: the SAME shortening becomes legal once the neighbour has been pulled
-- back to meet it -- the operator has a way out, the rule is not a dead end.
-- =============================================
DECLARE @EqB6 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine'
                          AND LocationId <> (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                                             WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId)
                        ORDER BY LocationId);
DECLARE @First6  BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_First');
DECLARE @Second6 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_Second');

DECLARE @c6a TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c6a EXEC Oee.ShiftOverride_Create
    @LocationId = @EqB6, @ShiftScheduleId = @Second6, @BusinessDate = '2026-10-19',
    @StartTime = '13:00:00', @EndTime = '22:30:00', @Reason = N'TEST_AT early start', @AppUserId = 1;
DECLARE @s6a NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c6a);
EXEC test.Assert_IsEqual @TestName = N'[CT.recover] pulling Second EARLIER over the global First is accepted',
     @Expected = N'1', @Actual = @s6a;

DECLARE @c6b TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @c6b EXEC Oee.ShiftOverride_Create
    @LocationId = @EqB6, @ShiftScheduleId = @First6, @BusinessDate = '2026-10-19',
    @StartTime = '06:00:00', @EndTime = '13:00:00', @Reason = N'TEST_AT short', @AppUserId = 1;
DECLARE @s6b NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c6b);
EXEC test.Assert_IsEqual @TestName = N'[CT.recover] and NOW the shortening is contiguous, so accepted',
     @Expected = N'1', @Actual = @s6b;
GO

-- =============================================
-- Test 7: DEPRECATE is never contiguity-validated -- reverting to the
-- plant-global window is the baseline and cannot introduce a new hole.
-- =============================================
DECLARE @EqB7 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine'
                          AND LocationId <> (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                                             WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId)
                        ORDER BY LocationId);
DECLARE @Second7 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_Second');
DECLARE @Ov7 BIGINT = (SELECT Id FROM Oee.ShiftOverride
                       WHERE LocationId = @EqB7 AND ShiftScheduleId = @Second7
                         AND BusinessDate = '2026-10-19' AND DeprecatedAt IS NULL);

DECLARE @c7 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @c7 EXEC Oee.ShiftOverride_Deprecate @Id = @Ov7, @AppUserId = 1;
DECLARE @s7 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @c7);
EXEC test.Assert_IsEqual @TestName = N'[CT.deprecate] deprecating is not contiguity-gated',
     @Expected = N'1', @Actual = @s7;
GO

-- ---- teardown ----
DELETE FROM Oee.ShiftOverride WHERE BusinessDate BETWEEN '2026-10-16' AND '2026-10-23';
GO

EXEC test.EndTestFile;
GO
