SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/100_CounterAnchor.sql';
GO

-- =============================================
-- DIE CAST COUNTER ANCHOR (2026-09-10, migration 0074).
--
-- Both shot watermarks are MAX(ShotCounterReading) over a shift, and a reading
-- below the DIE watermark is rejected. A MAX cannot be lowered by appending,
-- so a press counter reset mid-shift -- or a wrong number entered earlier --
-- blocked the die for the rest of the shift with no way out.
--
-- Workorder.DieCastCounterAnchor is an operator declaration of the TRUE
-- reading, and it becomes a FLOOR under both watermarks:
--
--     MAX( anchor.DeclaredReading,
--          MAX(reading) over contributions recorded AFTER it,
--          0 )
--
-- What these tests are really defending:
--   * with no anchor, every number is byte-for-byte what it was before (1);
--   * the floor reaches cavities a contribution row can never speak for,
--     because DieCastContribution.LotId is NOT NULL (4);
--   * it is FORWARD-ONLY -- pieces and Tools.Tool.ShotCount already credited
--     are not touched, which is the property operators will most want to be
--     wrong about (8).
--
-- FIXTURES ARE SELF-CONTAINED (see 080/090 for why: sibling suites in this
-- folder abort on seed data a -SkipDemoSeed build does not have).
-- =============================================

-- ---- cleanup (reverse FK order) ----
DECLARE @Ca TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @Ca (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'CAN-%';

DELETE FROM Workorder.DieCastCounterAnchor WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Workorder.RejectEvent          WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Workorder.ProductionEvent      WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @Ca)
                                        OR DescendantLotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @Ca)
                                 OR ChildLotId  IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotLabel           WHERE LotId IN (SELECT Id FROM @Ca) OR ParentLotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.PauseEvent         WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @Ca);
DELETE FROM Tools.ToolCavity     WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DELETE FROM Tools.Tool WHERE Code = N'CAN-DIE';
DELETE FROM Oee.Shift WHERE Remarks = N'CAN-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'CAN-FIXTURE-SCHED';
GO

-- ---- fixture ----
-- Three cavities. A and B carry open baskets; C is Active but has NO basket at
-- all -- it is the cavity the anchor has to be able to reach and a
-- DieCastContribution row cannot (LotId is NOT NULL, migration 0045).
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @DieTypeId  BIGINT = (SELECT Id FROM Tools.ToolType             WHERE Code = N'Die');
DECLARE @ActiveTool BIGINT = (SELECT Id FROM Tools.ToolStatusCode       WHERE Code = N'Active');
DECLARE @ActiveCav  BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
DECLARE @CavItemId  BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);

-- ShotCount starts at 0 so test 8 can prove the anchor never moves it.
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, CreatedAt, CreatedByUserId)
VALUES (@DieTypeId, N'CAN-DIE', N'Counter anchor die', @ActiveTool, 0, @Now, 1);
DECLARE @ToolId BIGINT = SCOPE_IDENTITY();

INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, Description, ItemId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, 1, @ActiveCav, N'Intake 2-A',   @CavItemId, @Now, 1),
       (@ToolId, 2, @ActiveCav, N'Intake 2-B',   @CavItemId, @Now, 1),
       (@ToolId, 3, @ActiveCav, N'Exhaust 5 Ab', @CavItemId, @Now, 1);

DECLARE @PressA   BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ItemId   BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @OriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OpenId   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 1);
DECLARE @CavB BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 2);

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
                      InventoryAvailable, CurrentLocationId, ToolId, ToolCavityId, CreatedAt, CreatedByUserId)
VALUES (N'CAN-A1', @ItemId, @OriginId, @OpenId, 0, 3000, 0, @PressA, @ToolId, @CavA, @Now, 1),
       (N'CAN-B1', @ItemId, @OriginId, @OpenId, 0, 3000, 0, @PressA, @ToolId, @CavB, @Now, 1);

IF NOT EXISTS (SELECT 1 FROM Oee.ShiftSchedule WHERE Name = N'CAN-FIXTURE-SCHED')
    INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
    VALUES (N'CAN-FIXTURE-SCHED', '07:00:00', '15:00:00', 127, CAST(@Now AS DATE), 1);
DECLARE @SchedId BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'CAN-FIXTURE-SCHED');
-- CLOSED: UIX_Shift_SingleOpen makes a leaked open shift everyone else's
-- problem (Msg 2601 in every later suite that opens one).
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@SchedId, DATEADD(HOUR, -4, @Now), DATEADD(MINUTE, -5, @Now), N'CAN-FIXTURE');
GO

-- Poison the shift exactly the way the floor did it: someone typed 2124 when
-- they meant something else. Both open cavities settle at 2124 and the die
-- watermark goes with them.
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'CAN-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'CAN-A1');
DECLARE @LotB BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'CAN-B1');

DECLARE @Lines NVARCHAR(MAX) =
    N'[{"lotId":' + CAST(@LotA AS NVARCHAR(20)) + N',"pieceDelta":2124},'
    + N'{"lotId":' + CAST(@LotB AS NVARCHAR(20)) + N',"pieceDelta":2124}]';
DECLARE @W TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @Lines,
    @ShotLossJson = NULL, @AppUserId = 1, @TerminalLocationId = NULL,
    @CounterReading = 2124, @CellLocationId = @PressA;
DECLARE @ws NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @W);
EXEC test.Assert_IsEqual @TestName = N'[Fixture] shift poisoned at reading 2124',
    @Expected = N'1', @Actual = @ws;
GO

-- =============================================
-- Test 1: WITH NO ANCHOR, NOTHING CHANGED. The v2.0 functions must return
--         exactly what v1.0 returned, or every existing die-cast test is
--         passing for a new reason.
-- =============================================
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'CAN-FIXTURE' ORDER BY Id DESC);
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 1);
DECLARE @CavC BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 3);

DECLARE @v NVARCHAR(20) = CAST(Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Anchor] no anchor -> die watermark is the recorded MAX',
    @Expected = N'2124', @Actual = @v;
SET @v = CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Anchor] no anchor -> settled cavity watermark unchanged',
    @Expected = N'2124', @Actual = @v;
-- Cavity C never produced, so it is still credited from 0. This is the number
-- test 4 watches move.
SET @v = CAST(Workorder.ufn_CavityShotWatermark(@CavC, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Anchor] no anchor -> unsettled cavity still 0',
    @Expected = N'0', @Actual = @v;
GO

-- =============================================
-- Test 2: BEFORE the anchor, the honest reading is refused. This is the wall
--         the operator hit, asserted so that fixing it cannot go unnoticed.
-- =============================================
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'CAN-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'CAN-A1');

DECLARE @P TABLE (LotId BIGINT, LotName NVARCHAR(50), ToolCavityId BIGINT, CavityNumber INT,
                  CavityDescription NVARCHAR(500), ItemId BIGINT, PartNumber NVARCHAR(100),
                  PieceCount INT, MaxPieceCount INT, CreditedThrough INT, DieCreditedThrough INT,
                  NewShots INT, ProjectedPieceCount INT, BelowStandardAfter BIT,
                  ReadingState NVARCHAR(20), ToolId BIGINT);
INSERT INTO @P EXEC Workorder.DieCast_GetReleasePreview
    @LotId = @LotA, @ShiftId = @ShiftId, @CellLocationId = @PressA, @CounterReading = 12;

DECLARE @v NVARCHAR(20) = (SELECT ReadingState FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Anchor] reading 12 against watermark 2124 -> Behind',
    @Expected = N'Behind', @Actual = @v;
-- The dialog needs the die number to name it in the advisory, and after this
-- change to show it as plain context before anything is typed.
SET @v = (SELECT CAST(DieCreditedThrough AS NVARCHAR(20)) FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Anchor] preview carries the die watermark',
    @Expected = N'2124', @Actual = @v;
-- And it carries the die itself, so the dialog can anchor without a second
-- lookup (proc v1.1).
SET @v = (SELECT CASE WHEN ToolId = @ToolId THEN N'yes' ELSE N'no' END FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Anchor] preview carries ToolId', @Expected = N'yes', @Actual = @v;
GO

-- =============================================
-- Test 3: THE ANCHOR LOWERS THE DIE WATERMARK, and the same reading that was
--         refused is now usable. Nothing in the ledger was edited to do it.
-- =============================================
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'CAN-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'CAN-A1');
DECLARE @Wrong BIGINT = (SELECT Id FROM Workorder.DieCastCounterAnchorReason WHERE Code = N'WrongReadingEntered');
DECLARE @LedgerBefore INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution c
                             INNER JOIN Lots.Lot l ON l.Id = c.LotId WHERE l.ToolId = @ToolId);

DECLARE @A TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @A EXEC Workorder.DieCastCounterAnchor_Record
    @ToolId = @ToolId, @ShiftId = @ShiftId, @DeclaredReading = 10, @ReasonId = @Wrong,
    @AppUserId = 1, @Note = N'2124 was the basket total, not the counter',
    @CellLocationId = @PressA, @TerminalLocationId = NULL;

DECLARE @v NVARCHAR(20) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @A);
EXEC test.Assert_IsEqual @TestName = N'[Anchor] declaring a LOWER reading is accepted',
    @Expected = N'1', @Actual = @v;
SET @v = CAST(Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Anchor] die watermark drops to the declared reading',
    @Expected = N'10', @Actual = @v;

-- Append-only: the contribution ledger is untouched.
DECLARE @LedgerAfter INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution c
                            INNER JOIN Lots.Lot l ON l.Id = c.LotId WHERE l.ToolId = @ToolId);
DECLARE @LedgerBeforeS NVARCHAR(20) = CAST(@LedgerBefore AS NVARCHAR(20));
DECLARE @LedgerAfterS  NVARCHAR(20) = CAST(@LedgerAfter  AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Anchor] the contribution ledger is not edited',
    @Expected = @LedgerBeforeS, @Actual = @LedgerAfterS;

DECLARE @P TABLE (LotId BIGINT, LotName NVARCHAR(50), ToolCavityId BIGINT, CavityNumber INT,
                  CavityDescription NVARCHAR(500), ItemId BIGINT, PartNumber NVARCHAR(100),
                  PieceCount INT, MaxPieceCount INT, CreditedThrough INT, DieCreditedThrough INT,
                  NewShots INT, ProjectedPieceCount INT, BelowStandardAfter BIT,
                  ReadingState NVARCHAR(20), ToolId BIGINT);
INSERT INTO @P EXEC Workorder.DieCast_GetReleasePreview
    @LotId = @LotA, @ShiftId = @ShiftId, @CellLocationId = @PressA, @CounterReading = 12;
SET @v = (SELECT ReadingState FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Anchor] the refused reading is now Ok',
    @Expected = N'Ok', @Actual = @v;
-- Cavity A was settled at 2124 and is floored down to 10, so 12 credits 2.
SET @v = (SELECT CAST(NewShots AS NVARCHAR(20)) FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Anchor] reading 12 - floored cavity 10 = 2 new shots',
    @Expected = N'2', @Actual = @v;
GO

-- =============================================
-- Test 4: THE FLOOR REACHES A CAVITY WITH NO BASKET. Cavity C has never had a
--         LOT, so no DieCastContribution row could ever speak for it -- this
--         is the whole reason the anchor is its own table.
-- =============================================
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'CAN-FIXTURE' ORDER BY Id DESC);
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 1);
DECLARE @CavC BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 3);

DECLARE @v NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Anchor] a settled cavity is floored DOWN to the anchor',
    @Expected = N'10', @Actual = @v;
-- Floored UP. Without this, the next basket opened on C would be credited the
-- whole reading and invent 10 shots of production out of nothing.
SET @v = CAST(Workorder.ufn_CavityShotWatermark(@CavC, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Anchor] a cavity with NO basket is floored UP to the anchor',
    @Expected = N'10', @Actual = @v;
GO

-- =============================================
-- Test 5: COUNTER RESET is DeclaredReading 0, and it needs no special case.
--         Every cavity goes back to crediting from 0, which is exactly the
--         start-of-shift state.
-- =============================================
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'CAN-FIXTURE' ORDER BY Id DESC);
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 1);
DECLARE @CavC BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 3);
DECLARE @Reset BIGINT = (SELECT Id FROM Workorder.DieCastCounterAnchorReason WHERE Code = N'CounterReset');

DECLARE @A TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @A EXEC Workorder.DieCastCounterAnchor_Record
    @ToolId = @ToolId, @ShiftId = @ShiftId, @DeclaredReading = 0, @ReasonId = @Reset,
    @AppUserId = 1, @Note = NULL, @CellLocationId = @PressA, @TerminalLocationId = NULL;

DECLARE @v NVARCHAR(20) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @A);
EXEC test.Assert_IsEqual @TestName = N'[Anchor] a counter reset is accepted', @Expected = N'1', @Actual = @v;
SET @v = CAST(Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Anchor] reset -> die watermark 0', @Expected = N'0', @Actual = @v;
SET @v = CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Anchor] reset -> settled cavity credits from 0 again',
    @Expected = N'0', @Actual = @v;
SET @v = CAST(Workorder.ufn_CavityShotWatermark(@CavC, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Anchor] reset -> empty cavity credits from 0',
    @Expected = N'0', @Actual = @v;

-- Only the LATEST anchor counts. The reading-10 anchor from test 3 is history.
DECLARE @n INT = (SELECT COUNT(*) FROM Workorder.DieCastCounterAnchor WHERE ToolId = @ToolId);
DECLARE @nS NVARCHAR(20) = CAST(@n AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Anchor] superseding appends, it does not replace',
    @Expected = N'2', @Actual = @nS;
GO

-- =============================================
-- Test 6: A CONTRIBUTION RECORDED AFTER AN ANCHOR SUPERSEDES IT. The chain
--         resumes normally -- the anchor is a floor, not a ceiling and not a
--         permanent override.
-- =============================================
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'CAN-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'CAN-A1');
DECLARE @LotB BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'CAN-B1');

DECLARE @Lines NVARCHAR(MAX) =
    N'[{"lotId":' + CAST(@LotA AS NVARCHAR(20)) + N',"pieceDelta":300},'
    + N'{"lotId":' + CAST(@LotB AS NVARCHAR(20)) + N',"pieceDelta":300}]';
DECLARE @W TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @Lines,
    @ShotLossJson = NULL, @AppUserId = 1, @TerminalLocationId = NULL,
    @CounterReading = 300, @CellLocationId = @PressA;

DECLARE @v NVARCHAR(20) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @W);
EXEC test.Assert_IsEqual @TestName = N'[Anchor] entry above the anchor is accepted',
    @Expected = N'1', @Actual = @v;
SET @v = CAST(Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Anchor] the chain resumes from the new entry',
    @Expected = N'300', @Actual = @v;
GO

-- =============================================
-- Test 7: THE CONTEXT READ. This is the number the operator could never see
--         until they had already collided with it.
-- =============================================
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'CAN-FIXTURE' ORDER BY Id DESC);

DECLARE @C TABLE (ToolId BIGINT, ShiftId BIGINT, CellLocationId BIGINT, DieCreditedThrough INT,
                  SourceKind NVARCHAR(10), RecordedAt DATETIME2(3), RecordedBy NVARCHAR(10),
                  ReasonName NVARCHAR(100), Note NVARCHAR(500), HasAnchor BIT);
INSERT INTO @C EXEC Workorder.DieCast_GetCounterContext
    @ToolId = @ToolId, @ShiftId = @ShiftId, @CellLocationId = @PressA;

DECLARE @v NVARCHAR(20) = (SELECT CAST(DieCreditedThrough AS NVARCHAR(20)) FROM @C);
EXEC test.Assert_IsEqual @TestName = N'[Context] rolling total matches the watermark',
    @Expected = N'300', @Actual = @v;
-- The entry after the anchor is what the number now IS, so it is what the
-- screen should name -- not the superseded anchor.
SET @v = (SELECT SourceKind FROM @C);
EXEC test.Assert_IsEqual @TestName = N'[Context] an entry above the anchor names itself',
    @Expected = N'Entry', @Actual = @v;
SET @v = (SELECT CAST(HasAnchor AS NVARCHAR(10)) FROM @C);
EXEC test.Assert_IsEqual @TestName = N'[Context] but HasAnchor still tells the screen one exists',
    @Expected = N'1', @Actual = @v;
SET @v = (SELECT CASE WHEN RecordedAt IS NULL THEN N'null' ELSE N'set' END FROM @C);
EXEC test.Assert_IsEqual @TestName = N'[Context] RecordedAt is populated', @Expected = N'set', @Actual = @v;

-- ALWAYS one row: a tool with nothing recorded must come back as a zero, not
-- as an empty set, or the bound nested paths on both screens go Quality-Bad.
DELETE FROM @C;
INSERT INTO @C EXEC Workorder.DieCast_GetCounterContext
    @ToolId = @ToolId, @ShiftId = 0, @CellLocationId = @PressA;
DECLARE @rows INT = (SELECT COUNT(*) FROM @C);
DECLARE @rowsS NVARCHAR(20) = CAST(@rows AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Context] unknown shift still returns exactly one row',
    @Expected = N'1', @Actual = @rowsS;
SET @v = (SELECT SourceKind FROM @C);
EXEC test.Assert_IsEqual @TestName = N'[Context] ...as SourceKind None', @Expected = N'None', @Actual = @v;
SET @v = (SELECT CAST(DieCreditedThrough AS NVARCHAR(20)) FROM @C);
EXEC test.Assert_IsEqual @TestName = N'[Context] ...with a zero total', @Expected = N'0', @Actual = @v;
GO

-- =============================================
-- Test 8: FORWARD-ONLY. The property operators will most want to be wrong
--         about: an anchor moves NOTHING that was already recorded.
-- =============================================
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'CAN-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'CAN-A1');
DECLARE @Wrong BIGINT = (SELECT Id FROM Workorder.DieCastCounterAnchorReason WHERE Code = N'WrongReadingEntered');

DECLARE @PiecesBefore INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotA);
DECLARE @ShotsBefore  INT = (SELECT ShotCount  FROM Tools.Tool WHERE Id = @ToolId);

DECLARE @A TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @A EXEC Workorder.DieCastCounterAnchor_Record
    @ToolId = @ToolId, @ShiftId = @ShiftId, @DeclaredReading = 5, @ReasonId = @Wrong,
    @AppUserId = 1, @Note = NULL, @CellLocationId = @PressA, @TerminalLocationId = NULL;

DECLARE @PiecesAfter INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotA);
DECLARE @ShotsAfter  INT = (SELECT ShotCount  FROM Tools.Tool WHERE Id = @ToolId);
DECLARE @PiecesBeforeS NVARCHAR(20) = CAST(@PiecesBefore AS NVARCHAR(20));
DECLARE @PiecesAfterS  NVARCHAR(20) = CAST(@PiecesAfter  AS NVARCHAR(20));
DECLARE @ShotsBeforeS  NVARCHAR(20) = CAST(@ShotsBefore  AS NVARCHAR(20));
DECLARE @ShotsAfterS   NVARCHAR(20) = CAST(@ShotsAfter   AS NVARCHAR(20));

EXEC test.Assert_IsEqual @TestName = N'[Anchor] pieces already on the basket are unchanged',
    @Expected = @PiecesBeforeS, @Actual = @PiecesAfterS;
EXEC test.Assert_IsEqual @TestName = N'[Anchor] Tools.Tool.ShotCount is unchanged',
    @Expected = @ShotsBeforeS, @Actual = @ShotsAfterS;

-- The status message is the operator's only confirmation of that, so it is
-- worth asserting that it says so.
DECLARE @msg NVARCHAR(500) = (SELECT Message FROM @A);
DECLARE @says NVARCHAR(10) = CASE WHEN @msg LIKE N'%pieces already on baskets are unchanged%'
                                  THEN N'yes' ELSE N'no' END;
EXEC test.Assert_IsEqual @TestName = N'[Anchor] the reply says pieces are NOT reversed',
    @Expected = N'yes', @Actual = @says;
GO

-- =============================================
-- Test 9: REJECTIONS. Each returns a status row and writes nothing -- no
--         ROLLBACK inside an INSERT-EXEC (Msg 3915), because every one of
--         these runs before BEGIN TRANSACTION.
-- =============================================
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'CAN-FIXTURE' ORDER BY Id DESC);
DECLARE @Other BIGINT = (SELECT Id FROM Workorder.DieCastCounterAnchorReason WHERE Code = N'Other');
DECLARE @Reset BIGINT = (SELECT Id FROM Workorder.DieCastCounterAnchorReason WHERE Code = N'CounterReset');
DECLARE @Before INT = (SELECT COUNT(*) FROM Workorder.DieCastCounterAnchor WHERE ToolId = @ToolId);

DECLARE @A TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @v NVARCHAR(10);

-- 'Other' with no note: the reason code would otherwise record nothing at all.
INSERT INTO @A EXEC Workorder.DieCastCounterAnchor_Record
    @ToolId = @ToolId, @ShiftId = @ShiftId, @DeclaredReading = 50, @ReasonId = @Other,
    @AppUserId = 1, @Note = N'   ', @CellLocationId = @PressA;
SET @v = (SELECT CAST(Status AS NVARCHAR(10)) FROM @A);
EXEC test.Assert_IsEqual @TestName = N'[Anchor] reason Other with a blank note rejects',
    @Expected = N'0', @Actual = @v;

DELETE FROM @A;
INSERT INTO @A EXEC Workorder.DieCastCounterAnchor_Record
    @ToolId = @ToolId, @ShiftId = @ShiftId, @DeclaredReading = -1, @ReasonId = @Reset,
    @AppUserId = 1, @CellLocationId = @PressA;
SET @v = (SELECT CAST(Status AS NVARCHAR(10)) FROM @A);
EXEC test.Assert_IsEqual @TestName = N'[Anchor] a negative reading rejects', @Expected = N'0', @Actual = @v;

DELETE FROM @A;
INSERT INTO @A EXEC Workorder.DieCastCounterAnchor_Record
    @ToolId = @ToolId, @ShiftId = @ShiftId, @DeclaredReading = 50, @ReasonId = 0,
    @AppUserId = 1, @CellLocationId = @PressA;
SET @v = (SELECT CAST(Status AS NVARCHAR(10)) FROM @A);
EXEC test.Assert_IsEqual @TestName = N'[Anchor] an unknown reason rejects', @Expected = N'0', @Actual = @v;

DELETE FROM @A;
INSERT INTO @A EXEC Workorder.DieCastCounterAnchor_Record
    @ToolId = @ToolId, @ShiftId = @ShiftId, @DeclaredReading = 50, @ReasonId = @Reset,
    @AppUserId = NULL, @CellLocationId = @PressA;
SET @v = (SELECT CAST(Status AS NVARCHAR(10)) FROM @A);
EXEC test.Assert_IsEqual @TestName = N'[Anchor] a missing operator rejects', @Expected = N'0', @Actual = @v;

DECLARE @After INT = (SELECT COUNT(*) FROM Workorder.DieCastCounterAnchor WHERE ToolId = @ToolId);
DECLARE @BeforeS NVARCHAR(20) = CAST(@Before AS NVARCHAR(20));
DECLARE @AfterS  NVARCHAR(20) = CAST(@After  AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Anchor] no rejection wrote an anchor',
    @Expected = @BeforeS, @Actual = @AfterS;
GO

-- =============================================
-- Test 10: THE REASON LIST the dialog binds its dropdown to.
-- =============================================
DECLARE @R TABLE (Id BIGINT, Code NVARCHAR(30), Name NVARCHAR(100),
                  Description NVARCHAR(500), RequiresNote BIT);
INSERT INTO @R EXEC Workorder.DieCastCounterAnchorReason_List;

DECLARE @n INT = (SELECT COUNT(*) FROM @R);
DECLARE @nS NVARCHAR(20) = CAST(@n AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Reasons] four reasons seeded', @Expected = N'4', @Actual = @nS;
DECLARE @v NVARCHAR(30) = (SELECT TOP 1 Code FROM @R ORDER BY Id);
EXEC test.Assert_IsEqual @TestName = N'[Reasons] the counter reset sorts first',
    @Expected = N'CounterReset', @Actual = @v;
SET @v = (SELECT CAST(RequiresNote AS NVARCHAR(10)) FROM @R WHERE Code = N'Other');
EXEC test.Assert_IsEqual @TestName = N'[Reasons] Other requires a note', @Expected = N'1', @Actual = @v;
SET @v = (SELECT CAST(SUM(CAST(RequiresNote AS INT)) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Reasons] ...and it is the only one',
    @Expected = N'1', @Actual = @v;
GO

-- ---- teardown (reverse FK order; mirrors the cleanup block) ----
DECLARE @Ca TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @Ca (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'CAN-%';

DELETE FROM Workorder.DieCastCounterAnchor WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Workorder.RejectEvent          WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Workorder.ProductionEvent      WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @Ca)
                                        OR DescendantLotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @Ca)
                                 OR ChildLotId  IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotLabel           WHERE LotId IN (SELECT Id FROM @Ca) OR ParentLotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.PauseEvent         WHERE LotId IN (SELECT Id FROM @Ca);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @Ca);
DELETE FROM Tools.ToolCavity     WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'CAN-DIE');
DELETE FROM Tools.Tool WHERE Code = N'CAN-DIE';
DELETE FROM Oee.Shift WHERE Remarks = N'CAN-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'CAN-FIXTURE-SCHED';
GO

EXEC test.EndTestFile;
GO
