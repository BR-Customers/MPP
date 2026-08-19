-- =============================================
-- File: 0062_Oee_ShiftAttribution/010_shiftid_for_instant.sql
-- Oee.ufn_ShiftIdForInstant -- THE attribution authority (spec sec 4.1).
--
-- Covers the resolver obligations from spec sec 8:
--   * an instant exactly on a boundary lands in exactly ONE shift (half-open);
--   * a 02:00 instant attributes to the PREVIOUS business date's third shift;
--   * an override wins over the plant-global window FOR THAT EQUIPMENT ONLY;
--   * a midnight-crossing shift extended past midnight still ends NEXT DAY.
--
-- TIME BASIS (OI-38). The probe instants below are UTC -- that is what
-- Oee.DowntimeEvent.StartedAt and Workorder.DieCastContribution.EventAt store.
-- The shift windows are LOCAL Eastern. Every probe is therefore written as a
-- LOCAL wall-clock literal converted with AT TIME ZONE, never as a hand-computed
-- UTC literal: hand-computing it is exactly the mistake that produced six
-- defects on 2026-08-19, and a literal would also silently rot across DST.
-- 2026-10-19 is a Monday in EDT (UTC-4), deliberately clear of both DST
-- transitions so the arithmetic is stable.
--
-- This file exercises the FUNCTION in isolation: override rows are INSERTed
-- directly rather than through Oee.ShiftOverride_Create, so a resolver failure
-- can never be masked by (or blamed on) the Create proc's validation or its
-- restamp. 020 and 030 drive the procs.
--
-- EXEC parameters are literals or @variables only (project convention), so
-- every asserted value is hoisted into a local first.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0062_Oee_ShiftAttribution/010_shiftid_for_instant.sql';
GO

-- ---- fixture ----------------------------------------------------------------
-- The 0059 / 0026 / 0046 suites leave several ACTIVE schedules behind, three of
-- which run 06:00-14:00 simultaneously. That is not a shape the real plant has,
-- and a resolver that must return AT MOST ONE row cannot give a meaningful
-- answer against it. Park every other schedule (soft-delete -- the resolver
-- skips DeprecatedAt) so this suite runs against one clean 3-shift tiling.
-- 0062 is the last suite, so nothing downstream is affected.
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

-- Runtime instances for 2026-10-19 only. ActualStart is LOCAL (OI-38) -- the
-- same basis Oee.Shift_Reconcile writes and Oee.Shift_GetAvailability reads.
-- 2026-10-21 is deliberately left WITHOUT instances so the "scheduled but never
-- instantiated" contract can be asserted.
DELETE FROM Oee.Shift WHERE ActualStart >= '2026-10-18' AND ActualStart < '2026-10-23';
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd)
SELECT Id, '2026-10-19 06:00:00', '2026-10-19 14:30:00' FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_First'
UNION ALL
SELECT Id, '2026-10-19 14:30:00', '2026-10-19 22:30:00' FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_Second'
UNION ALL
SELECT Id, '2026-10-19 22:30:00', '2026-10-20 06:00:00' FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_Third'
UNION ALL
SELECT Id, '2026-10-20 06:00:00', NULL                  FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_First';
GO

-- =============================================
-- Test 1: plain hit. 07:00 local on a press with no override -> First.
-- =============================================
DECLARE @EqA BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                       WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @p1 DATETIME2(3) = CAST(CAST('2026-10-19 07:00:00' AS DATETIME2(3))
                                AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

DECLARE @n1 NVARCHAR(100), @bd1 NVARCHAR(10), @ov1 NVARCHAR(1);
SELECT @n1 = r.ScheduleName,
       @bd1 = CONVERT(NVARCHAR(10), r.BusinessDate, 23),
       @ov1 = CAST(r.IsOverridden AS NVARCHAR(1))
FROM Oee.ufn_ShiftIdForInstant(@EqA, @p1) r;

EXEC test.Assert_IsEqual @TestName = N'[ID.plain] 07:00 local -> First',
     @Expected = N'TEST_AT_First', @Actual = @n1;
EXEC test.Assert_IsEqual @TestName = N'[ID.plain] business date is the same day',
     @Expected = N'2026-10-19', @Actual = @bd1;
EXEC test.Assert_IsEqual @TestName = N'[ID.plain] not overridden',
     @Expected = N'0', @Actual = @ov1;

-- The mapped Oee.Shift row is the runtime instance for that (schedule, date).
DECLARE @gotShift NVARCHAR(20), @wantShift NVARCHAR(20);
SELECT @gotShift = CAST(r.ShiftId AS NVARCHAR(20)) FROM Oee.ufn_ShiftIdForInstant(@EqA, @p1) r;
SELECT @wantShift = CAST(sh.Id AS NVARCHAR(20))
FROM Oee.Shift sh INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
WHERE ss.Name = N'TEST_AT_First' AND CAST(sh.ActualStart AS DATE) = '2026-10-19';
EXEC test.Assert_IsEqual @TestName = N'[ID.plain] maps to the EXISTING Oee.Shift instance',
     @Expected = @wantShift, @Actual = @gotShift;
GO

-- =============================================
-- Test 2: HALF-OPEN BOUNDS. 14:30:00 exactly is Second, not First, and exactly
-- one row comes back -- back-to-back shifts must never both match.
-- =============================================
DECLARE @EqA2 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @pOn  DATETIME2(3) = CAST(CAST('2026-10-19 14:30:00' AS DATETIME2(3))
                                  AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
DECLARE @pJust DATETIME2(3) = CAST(CAST('2026-10-19 14:29:59' AS DATETIME2(3))
                                  AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

DECLARE @nOn NVARCHAR(100) = (SELECT r.ScheduleName FROM Oee.ufn_ShiftIdForInstant(@EqA2, @pOn) r);
DECLARE @nJust NVARCHAR(100) = (SELECT r.ScheduleName FROM Oee.ufn_ShiftIdForInstant(@EqA2, @pJust) r);
DECLARE @cntOn NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_ShiftIdForInstant(@EqA2, @pOn));

EXEC test.Assert_IsEqual @TestName = N'[ID.boundary] instant ON the boundary belongs to the LATER shift',
     @Expected = N'TEST_AT_Second', @Actual = @nOn;
EXEC test.Assert_IsEqual @TestName = N'[ID.boundary] one second earlier is still the EARLIER shift',
     @Expected = N'TEST_AT_First', @Actual = @nJust;
EXEC test.Assert_IsEqual @TestName = N'[ID.boundary] a boundary instant matches EXACTLY ONE shift',
     @Expected = N'1', @Actual = @cntOn;
GO

-- =============================================
-- Test 3: (-1, 0) BUSINESS-DATE SPINE. 02:00 local on the 20th belongs to the
-- 19th's THIRD shift, which started 22:30 the night before.
-- =============================================
DECLARE @EqA3 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @p2am DATETIME2(3) = CAST(CAST('2026-10-20 02:00:00' AS DATETIME2(3))
                                  AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

DECLARE @n3 NVARCHAR(100), @bd3 NVARCHAR(10);
SELECT @n3 = r.ScheduleName, @bd3 = CONVERT(NVARCHAR(10), r.BusinessDate, 23)
FROM Oee.ufn_ShiftIdForInstant(@EqA3, @p2am) r;

EXEC test.Assert_IsEqual @TestName = N'[ID.spine] 02:00 -> the third shift',
     @Expected = N'TEST_AT_Third', @Actual = @n3;
EXEC test.Assert_IsEqual @TestName = N'[ID.spine] 02:00 -> the PREVIOUS business date',
     @Expected = N'2026-10-19', @Actual = @bd3;
GO

-- =============================================
-- Test 4: no shift running is a REAL answer -- zero rows, not an error.
-- 2019 predates every schedule's EffectiveFrom.
-- =============================================
DECLARE @EqA4 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @pOld DATETIME2(3) = CAST(CAST('2019-06-03 07:00:00' AS DATETIME2(3))
                                  AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
DECLARE @cntOld NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_ShiftIdForInstant(@EqA4, @pOld));
EXEC test.Assert_IsEqual @TestName = N'[ID.none] no shift covers the instant -> ZERO rows',
     @Expected = N'0', @Actual = @cntOld;
GO

-- =============================================
-- Test 5: scheduled but NEVER INSTANTIATED. 2026-10-21 has no Oee.Shift rows,
-- so the resolver returns the covering SCHEDULE with ShiftId NULL -- which is a
-- different answer from "no shift runs" (test 4) and must stay distinguishable.
-- =============================================
DECLARE @EqA5 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @pNoInst DATETIME2(3) = CAST(CAST('2026-10-21 07:00:00' AS DATETIME2(3))
                                     AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
DECLARE @cnt5 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_ShiftIdForInstant(@EqA5, @pNoInst));
DECLARE @sid5 NVARCHAR(20) = (SELECT CAST(r.ShiftId AS NVARCHAR(20)) FROM Oee.ufn_ShiftIdForInstant(@EqA5, @pNoInst) r);
DECLARE @nm5  NVARCHAR(100) = (SELECT r.ScheduleName FROM Oee.ufn_ShiftIdForInstant(@EqA5, @pNoInst) r);

EXEC test.Assert_IsEqual @TestName = N'[ID.noinstance] still returns ONE row',
     @Expected = N'1', @Actual = @cnt5;
EXEC test.Assert_IsEqual @TestName = N'[ID.noinstance] naming the covering schedule',
     @Expected = N'TEST_AT_First', @Actual = @nm5;
EXEC test.Assert_IsNull @TestName = N'[ID.noinstance] with ShiftId NULL (never instantiated)', @Value = @sid5;
GO

-- =============================================
-- Test 6: OVERRIDE PRECEDENCE (design D1) -- the headline requirement.
-- First is extended to 16:00 on ONE press. A 15:00 instant, which the
-- plant-global Second also covers, attributes to FIRST for that press and to
-- SECOND for its neighbour.
-- Inserted directly: this test is about the resolver, not the Create proc.
-- =============================================
DECLARE @EqA6 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @EqB6 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' AND LocationId <> @EqA6 ORDER BY LocationId);
DECLARE @First6 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_First');

INSERT INTO Oee.ShiftOverride (LocationId, ShiftScheduleId, BusinessDate, StartTime, EndTime, Reason, CreatedByUserId)
VALUES (@EqA6, @First6, '2026-10-19', '06:00:00', '16:00:00', N'TEST_AT extend', 1);

DECLARE @p3pm DATETIME2(3) = CAST(CAST('2026-10-19 15:00:00' AS DATETIME2(3))
                                  AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

DECLARE @nA6 NVARCHAR(100), @ovA6 NVARCHAR(1), @cntA6 NVARCHAR(10);
SELECT @nA6 = r.ScheduleName, @ovA6 = CAST(r.IsOverridden AS NVARCHAR(1))
FROM Oee.ufn_ShiftIdForInstant(@EqA6, @p3pm) r;
SET @cntA6 = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_ShiftIdForInstant(@EqA6, @p3pm));

DECLARE @nB6 NVARCHAR(100) = (SELECT r.ScheduleName FROM Oee.ufn_ShiftIdForInstant(@EqB6, @p3pm) r);

EXEC test.Assert_IsEqual @TestName = N'[ID.override] 15:00 on the EXTENDED press -> First',
     @Expected = N'TEST_AT_First', @Actual = @nA6;
EXEC test.Assert_IsEqual @TestName = N'[ID.override] reported as overridden',
     @Expected = N'1', @Actual = @ovA6;
EXEC test.Assert_IsEqual @TestName = N'[ID.override] still EXACTLY ONE row despite two covering windows',
     @Expected = N'1', @Actual = @cntA6;
EXEC test.Assert_IsEqual @TestName = N'[ID.override] the SIBLING press is untouched -> Second',
     @Expected = N'TEST_AT_Second', @Actual = @nB6;
GO

-- =============================================
-- Test 7: MIDNIGHT CROSSING, EXTENDED. Third (22:30-06:00) stretched to 08:00
-- on ONE press must still END NEXT DAY, and must win at 07:00 on the 20th over
-- the global First that also covers it.
-- =============================================
DECLARE @EqA7 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' ORDER BY LocationId);
DECLARE @EqB7 BIGINT = (SELECT TOP 1 LocationId FROM Oee.ufn_ResolveOeeEquipment()
                        WHERE DefinitionCode = N'DieCastMachine' AND LocationId <> @EqA7 ORDER BY LocationId);
DECLARE @Third7 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_AT_Third');

INSERT INTO Oee.ShiftOverride (LocationId, ShiftScheduleId, BusinessDate, StartTime, EndTime, Reason, CreatedByUserId)
VALUES (@EqA7, @Third7, '2026-10-19', '22:30:00', '08:00:00', N'TEST_AT night run-on', 1);

DECLARE @p7am DATETIME2(3) = CAST(CAST('2026-10-20 07:00:00' AS DATETIME2(3))
                                  AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

DECLARE @nA7 NVARCHAR(100), @bdA7 NVARCHAR(10), @endA7 NVARCHAR(30);
SELECT @nA7   = r.ScheduleName,
       @bdA7  = CONVERT(NVARCHAR(10), r.BusinessDate, 23),
       @endA7 = CONVERT(NVARCHAR(30), r.EndLocal, 121)
FROM Oee.ufn_ShiftIdForInstant(@EqA7, @p7am) r;

DECLARE @nB7 NVARCHAR(100) = (SELECT r.ScheduleName FROM Oee.ufn_ShiftIdForInstant(@EqB7, @p7am) r);

EXEC test.Assert_IsEqual @TestName = N'[ID.midnight] 07:00 next morning on the extended press -> Third',
     @Expected = N'TEST_AT_Third', @Actual = @nA7;
EXEC test.Assert_IsEqual @TestName = N'[ID.midnight] anchored on the PREVIOUS business date',
     @Expected = N'2026-10-19', @Actual = @bdA7;
EXEC test.Assert_IsEqual @TestName = N'[ID.midnight] window still ENDS NEXT DAY, not same-day',
     @Expected = N'2026-10-20 08:00:00.000', @Actual = @endA7;
EXEC test.Assert_IsEqual @TestName = N'[ID.midnight] the sibling press has already rolled to First',
     @Expected = N'TEST_AT_First', @Actual = @nB7;
GO

-- ---- teardown: leave no overrides behind for 020 / 030 ----
DELETE FROM Oee.ShiftOverride WHERE BusinessDate BETWEEN '2026-10-16' AND '2026-10-23';
GO

EXEC test.EndTestFile;
GO
