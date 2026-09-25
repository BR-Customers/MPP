-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_Save.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.4
-- Description: Reconciles ONE past shift x press x die against its press sheet
--              (spec docs/superpowers/specs/2026-09-21-diecast-shift-
--              reconciliation-design.md sec 5.2, amendments sec 14): adds the
--              production that is missing, re-files entries that went to the
--              wrong shift, and closes numeric gaps in EITHER direction.
--
--              THE CALLER SENDS WHAT IS ACTUAL, NEVER A DELTA. This proc reads
--              what is on record, works out every gap itself, and writes only
--              the difference -- so re-running the same reconciliation is a
--              no-op, and a partly-applied screen state cannot double-count.
--
--              Order inside the transaction is load-bearing (sec 3.5): moves
--              first, because the watermark and every "recorded" figure are
--              per shift; then new LOTs, credits, scrap, the reading, the
--              release of new LOTs, and last the count corrections.
--
--              The count rule (sec 3.3): an Open LOT is credited; a released
--              LOT that nothing downstream has counted is credited AND
--              corrected; a LOT trim has counted keeps its count and still
--              gets its production recorded. Lots.ufn_DieCastLotCountLock
--              decides which, from what is stored.
--
--              THE LOCK OUTRANKS THE STATUS (1.2, code review 2026-09-24).
--              ApplyToLot used to read status 'Open' alone, but the count lock
--              turns on four independent conditions and one of them is not
--              status-derived: a LOT that appears as a genealogy parent is
--              locked whatever its status. An Open LOT already consumed into
--              another was therefore locked AND had its count rewritten -- the
--              one shape the rule forbids. ApplyToLot is now
--              "new, OR Open and the count lock says not locked", so the lock
--              is the single authority over every count. The production record
--              is unaffected: loop (c) credits EVERY planned row with a
--              non-zero gap and only passes @ApplyToLot = 0, which is
--              DieCastCredit_Write's "record it, leave the count".
--
--              The reading is declared by an ANCHOR written here (A3), which
--              floors both watermarks and works for a decrease as well as an
--              increase. Reconciliation credit rows therefore carry no reading.
--
--              VALIDATION ORDER. The reject lines are validated BEFORE the
--              totals arithmetic, because the no-good total they sum to is an
--              INPUT to that arithmetic (actual total good = good shots x
--              active cavities - no-good). Validating totals first would
--              answer a mistyped reject line with a totals message the team
--              lead cannot act on -- it would name a sum, not the line that
--              is wrong.
--
--              THE MOVES ARE VERIFIED, NOT ASSUMED (1.1, code review
--              2026-09-24, approved departure from the plan's SQL).
--              Workorder.DieCastEntry_Restamp is a worker and so emits no result
--              set: a @MovesJson payload that resolved to zero rows inside it
--              used to be indistinguishable from an empty one, and this proc
--              reported success either way. After the EXEC we now confirm that
--              EVERY element we sent is on its target shift and RAISERROR into
--              our own CATCH if any is not -- so the whole reconciliation rolls
--              back rather than silently losing a team lead's decision. "On its
--              target shift", not "moved": a row already there is the intended
--              idempotent skip (sec 3.5) and still passes.
--
--              FDS-11-011 + Msg-3915: no OUTPUT params, ONE result set, all
--              rejecting validations BEFORE BEGIN TRANSACTION, CATCH the only
--              ROLLBACK site, RAISERROR not THROW. Every write goes through a
--              worker (sec 5.1) so the live screens and this proc write the
--              same rows.
--
-- Parameters (input):
--   @ShiftId            BIGINT        - the CLOSED shift being reconciled.
--   @CellLocationId     BIGINT        - the press.
--   @ToolId             BIGINT        - the die.
--   @ReasonId           BIGINT        - Workorder.DieCastReconciliationReason.
--   @Note               NVARCHAR(500) - required when the reason says so.
--   @ActualJson         NVARCHAR(MAX) - {"totalShots":N,"goodShots":N,"warmUpShots":N}
--   @MovesJson          NVARCHAR(MAX) - [{"entityType":"Contribution"|"Reject",
--                                         "entityId":N,"toShiftId":N}]
--   @LotsJson           NVARCHAR(MAX) - [{"lotId":N|null,"ltt":"...",
--                                         "toolCavityId":N,"quantity":N}]
--                                       quantity is the ACTUAL for that LOT in
--                                       this shift, never a delta.
--   @RejectsJson        NVARCHAR(MAX) - [{"defectCodeId":N,"itemId":N|null,
--                                         "quantity":N,"approvedByUserId":N}]
--                                       itemId null means "All".
--   @LoadedStamp        NVARCHAR(100) - Workorder.ufn_DieCastShiftStamp as the
--                                       screen read it (sec 8).
--   @AppUserId          BIGINT        - the team lead (caller supplies it).
--   @TerminalLocationId BIGINT        - where it was entered.
--
-- Result set (exactly one row, every exit path):
--   Status BIT, Message NVARCHAR(500), NewId BIGINT (the reconciliation id).
--
-- Error Handling:
--   Three-tier. Validation -> clean Status = 0 row with a FailureLog entry.
--   Unexpected -> CATCH rolls back, logs, returns Status = 0, RAISERRORs.
--
-- Change Log:
--   2026-09-22 - 1.0 - Initial version (die cast shift reconciliation, sec 5.2).
--   2026-09-24 - 1.1 - Verify the restamp payload landed (code review; approved
--                      departure from the plan's SQL). See header "THE MOVES ARE
--                      VERIFIED, NOT ASSUMED" and R__Workorder_DieCastEntry_
--                      Restamp.sql 1.1.
--   2026-09-24 - 1.2 - ApplyToLot now defers to the count lock, not to status
--                      'Open' alone (code review). See header "THE LOCK
--                      OUTRANKS THE STATUS". Also dropped a dead disjunct from
--                      the no-active-cavities gate: a reject line with no
--                      actual figure is already refused above it.
--   2026-09-25 - 1.3 - Lots.DieCastLot_Mint 1.1 owns its audit-note separator,
--                      so the mint call now passes the bare note (@NoteText).
--                      ReleaseMove and DieCastCredit_Write keep @Suffix.
--   2026-09-25 - 1.4 - A reject line's approvedByUserId must now be an ACTIVE
--                      Location.AppUser, not merely one on file. The check was
--                      already here and already pre-transaction; it asked
--                      existence only, so this proc accepted a deprecated
--                      approver that Workorder.DieCastShiftOutput_Record 3.2
--                      refuses -- three procs feed the same column through
--                      Workorder.DieCastScrap_Write and they disagreed on what
--                      a valid approver is. Amended in place (no second check),
--                      with path 1's message verbatim. Optional stays optional.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_Save
    @ShiftId            BIGINT,
    @CellLocationId     BIGINT,
    @ToolId             BIGINT,
    @ReasonId           BIGINT,
    @Note               NVARCHAR(500)  = NULL,
    @ActualJson         NVARCHAR(MAX)  = NULL,
    @MovesJson          NVARCHAR(MAX)  = NULL,
    @LotsJson           NVARCHAR(MAX)  = NULL,
    @RejectsJson        NVARCHAR(MAX)  = NULL,
    @LoadedStamp        NVARCHAR(100),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.DieCastShiftReconciliation_Save';
    DECLARE @Params NVARCHAR(MAX) = (
        SELECT @ShiftId AS ShiftId, @CellLocationId AS CellLocationId, @ToolId AS ToolId,
               @ReasonId AS ReasonId, LEFT(@ActualJson, 500) AS ActualJson, LEFT(@MovesJson, 1000) AS MovesJson,
               LEFT(@LotsJson, 2000) AS LotsJson, LEFT(@RejectsJson, 1000) AS RejectsJson, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @Bad NVARCHAR(400);

    BEGIN TRY
        -- ---- 1. shape ----
        IF @ShiftId IS NULL OR @CellLocationId IS NULL OR @ToolId IS NULL OR @ReasonId IS NULL
           OR @LoadedStamp IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message = N'Required parameter missing.'; GOTO Fail; END
        IF (@ActualJson  IS NOT NULL AND ISJSON(@ActualJson)  <> 1)
        OR (@MovesJson   IS NOT NULL AND ISJSON(@MovesJson)   <> 1)
        OR (@LotsJson    IS NOT NULL AND ISJSON(@LotsJson)    <> 1)
        OR (@RejectsJson IS NOT NULL AND ISJSON(@RejectsJson) <> 1)
        BEGIN SET @Message = N'One of the JSON inputs is not valid JSON.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN SET @Message = N'AppUser not found.'; GOTO Fail; END

        -- ---- 2. the shift, the press, the die ----
        DECLARE @StartEt DATETIME2(3), @EndEt DATETIME2(3), @ShiftLabel NVARCHAR(120);
        SELECT @StartEt = s.ActualStart, @EndEt = s.ActualEnd,
               @ShiftLabel = CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name
        FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
        WHERE s.Id = @ShiftId;
        IF @StartEt IS NULL BEGIN SET @Message = N'Shift not found.'; GOTO Fail; END
        IF @EndEt IS NULL
        BEGIN SET @Message = N'This shift is still open. The live die cast screen records the current shift.'; GOTO Fail; END

        DECLARE @PressCode NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = @CellLocationId);
        IF @PressCode IS NULL BEGIN SET @Message = N'Press not found.'; GOTO Fail; END
        DECLARE @Asset NVARCHAR(50), @DieName NVARCHAR(200);
        SELECT @Asset = Code, @DieName = Name FROM Tools.Tool WHERE Id = @ToolId;
        IF @Asset IS NULL BEGIN SET @Message = N'Die not found.'; GOTO Fail; END

        -- Oee.Shift is Eastern wall clock (OI-38); everything compared with it here is UTC.
        DECLARE @StartUtc DATETIME2(3) = CAST(@StartEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
        DECLARE @EndUtc   DATETIME2(3) = CAST(@EndEt   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
        -- one second INSIDE the shift, so every time-based resolver puts these rows in it (A1).
        -- Shift windows are half-open [start, end): a row stamped exactly at @EndUtc
        -- resolves into the NEXT shift.
        DECLARE @EventAt  DATETIME2(3) = DATEADD(SECOND, -1, @EndUtc);

        IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment
                       WHERE ToolId = @ToolId AND CellLocationId = @CellLocationId
                         AND AssignedAt < @EndUtc AND ISNULL(ReleasedAt, '9999-12-31') > @StartUtc)
        BEGIN
            SET @Message = @DieName + N' (Asset # ' + @Asset + N') was not mounted on ' + @PressCode
                         + N' during ' + @ShiftLabel + N'.';
            GOTO Fail;
        END

        -- ---- 3. reason ----
        DECLARE @ReasonName NVARCHAR(100), @RequiresNote BIT;
        SELECT @ReasonName = Name, @RequiresNote = RequiresNote
        FROM Workorder.DieCastReconciliationReason WHERE Id = @ReasonId;
        IF @ReasonName IS NULL BEGIN SET @Message = N'Reconciliation reason not found.'; GOTO Fail; END
        IF @RequiresNote = 1 AND LEN(LTRIM(RTRIM(ISNULL(@Note, N'')))) = 0
        BEGIN SET @Message = N'This reason needs a note saying what happened.'; GOTO Fail; END

        -- ---- 4. stale guard (sec 8) ----
        IF Workorder.ufn_DieCastShiftStamp(@ShiftId, @CellLocationId, @ToolId) <> @LoadedStamp
        BEGIN SET @Message = N'This shift changed since you opened it. Reload it and check again.'; GOTO Fail; END

        -- ---- 5. parse ----
        DECLARE @Total INT, @Good INT, @Warm INT;
        IF @ActualJson IS NOT NULL
            SELECT @Total = j.totalShots, @Good = j.goodShots, @Warm = j.warmUpShots
            FROM OPENJSON(@ActualJson) WITH (totalShots INT N'$.totalShots', goodShots INT N'$.goodShots',
                                             warmUpShots INT N'$.warmUpShots') j;
        DECLARE @HasActual BIT = CASE WHEN @Total IS NOT NULL OR @Good IS NOT NULL OR @Warm IS NOT NULL THEN 1 ELSE 0 END;

        DECLARE @Moves TABLE (EntityType NVARCHAR(20), EntityId BIGINT, ToShiftId BIGINT);
        IF @MovesJson IS NOT NULL
            INSERT INTO @Moves (EntityType, EntityId, ToShiftId)
            SELECT j.entityType, j.entityId, j.toShiftId
            FROM OPENJSON(@MovesJson) WITH (entityType NVARCHAR(20) N'$.entityType', entityId BIGINT N'$.entityId',
                                            toShiftId BIGINT N'$.toShiftId') j;

        DECLARE @Lots TABLE (Seq INT IDENTITY(1,1), LotId BIGINT NULL, Ltt NVARCHAR(50) NULL,
                             ToolCavityId BIGINT NULL, Qty INT NULL);
        IF @LotsJson IS NOT NULL
            INSERT INTO @Lots (LotId, Ltt, ToolCavityId, Qty)
            SELECT j.lotId, LTRIM(RTRIM(j.ltt)), j.toolCavityId, j.quantity
            FROM OPENJSON(@LotsJson) WITH (lotId BIGINT N'$.lotId', ltt NVARCHAR(50) N'$.ltt',
                                           toolCavityId BIGINT N'$.toolCavityId', quantity INT N'$.quantity') j;

        DECLARE @Rej TABLE (DefectCodeId BIGINT, ItemId BIGINT NULL, Qty INT, ApprovedByUserId BIGINT NULL);
        IF @RejectsJson IS NOT NULL
            INSERT INTO @Rej (DefectCodeId, ItemId, Qty, ApprovedByUserId)
            SELECT j.defectCodeId, j.itemId, j.quantity, j.approvedByUserId
            FROM OPENJSON(@RejectsJson) WITH (defectCodeId BIGINT N'$.defectCodeId', itemId BIGINT N'$.itemId',
                                              quantity INT N'$.quantity', approvedByUserId BIGINT N'$.approvedByUserId') j;

        -- ---- 6. moves ----
        IF EXISTS (SELECT 1 FROM @Moves WHERE EntityType NOT IN (N'Contribution', N'Reject') OR EntityId IS NULL OR ToShiftId IS NULL)
        BEGIN SET @Message = N'A move must name a contribution or reject row and a target shift.'; GOTO Fail; END

        IF EXISTS (SELECT 1 FROM @Moves m WHERE m.EntityType = N'Contribution' AND NOT EXISTS (
                        SELECT 1 FROM Workorder.DieCastContribution c INNER JOIN Lots.Lot l ON l.Id = c.LotId
                        WHERE c.Id = m.EntityId AND c.ShiftId = @ShiftId
                          AND c.CellLocationId = @CellLocationId AND l.ToolId = @ToolId))
           OR EXISTS (SELECT 1 FROM @Moves m WHERE m.EntityType = N'Reject' AND NOT EXISTS (
                        SELECT 1 FROM Workorder.RejectEvent r
                        WHERE r.Id = m.EntityId AND r.ShiftId = @ShiftId
                          AND r.CellLocationId = @CellLocationId AND r.ToolId = @ToolId))
        BEGIN SET @Message = N'A row being moved is not recorded against this shift, press and die. Reload and try again.'; GOTO Fail; END

        IF EXISTS (SELECT 1 FROM @Moves m
                   WHERE NOT EXISTS (SELECT 1 FROM Oee.ufn_ShiftNeighbours(@ShiftId, 2) n WHERE n.ShiftId = m.ToShiftId))
        BEGIN SET @Message = N'An entry can only move to a closed shift within two shifts of ' + @ShiftLabel + N'.'; GOTO Fail; END

        DECLARE @MovedC TABLE (Id BIGINT PRIMARY KEY);
        INSERT INTO @MovedC (Id) SELECT DISTINCT EntityId FROM @Moves WHERE EntityType = N'Contribution';
        DECLARE @MovedR TABLE (Id BIGINT PRIMARY KEY);
        INSERT INTO @MovedR (Id) SELECT DISTINCT EntityId FROM @Moves WHERE EntityType = N'Reject';

        -- ---- 7. the LOTs ----
        UPDATE lt SET lt.LotId = l.Id
        FROM @Lots lt INNER JOIN Lots.Lot l ON l.LotName = lt.Ltt
        WHERE lt.LotId IS NULL;

        IF EXISTS (SELECT 1 FROM @Lots WHERE Qty IS NULL OR Qty < 0)
        BEGIN SET @Message = N'Every LOT needs an actual quantity of zero or more.'; GOTO Fail; END

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(l.LotName, N', ')
        FROM @Lots lt INNER JOIN Lots.Lot l ON l.Id = lt.LotId
        WHERE ISNULL(l.ToolId, -1) <> @ToolId;
        IF @Bad IS NOT NULL
        BEGIN SET @Message = N'Not a LOT from ' + @DieName + N' (Asset # ' + @Asset + N'): ' + @Bad + N'.'; GOTO Fail; END

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(ISNULL(lt.Ltt, N'(blank)'), N', ')
        FROM @Lots lt WHERE lt.LotId IS NULL AND (lt.Ltt IS NULL OR Lots.ufn_IsValidExternalLtt(lt.Ltt) = 0);
        IF @Bad IS NOT NULL
        BEGIN SET @Message = N'Not a valid LTT (8 or 9 digits): ' + @Bad + N'.'; GOTO Fail; END

        IF EXISTS (SELECT 1 FROM @Lots GROUP BY ISNULL(CAST(LotId AS NVARCHAR(50)), Ltt) HAVING COUNT(*) > 1)
        BEGIN SET @Message = N'The same LTT is in the list twice.'; GOTO Fail; END

        UPDATE lt SET lt.ToolCavityId = l.ToolCavityId
        FROM @Lots lt INNER JOIN Lots.Lot l ON l.Id = lt.LotId;

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(lt.Ltt, N', ')
        FROM @Lots lt LEFT JOIN Tools.ToolCavity tc ON tc.Id = lt.ToolCavityId
        WHERE lt.LotId IS NULL AND (tc.Id IS NULL OR tc.ToolId <> @ToolId OR tc.DeprecatedAt IS NOT NULL);
        IF @Bad IS NOT NULL
        BEGIN SET @Message = N'Choose a cavity on this die for: ' + @Bad + N'.'; GOTO Fail; END

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(lt.Ltt, N', ')
        FROM @Lots lt INNER JOIN Tools.ToolCavity tc ON tc.Id = lt.ToolCavityId
        WHERE lt.LotId IS NULL AND tc.ItemId IS NULL;
        IF @Bad IS NOT NULL
        BEGIN
            SET @Message = N'That cavity has no part configured, so no LOT can be created for: ' + @Bad
                         + N'. Map the cavity to its part on the Tools screen first.';
            GOTO Fail;
        END

        IF EXISTS (SELECT 1 FROM @Lots WHERE LotId IS NULL AND Qty = 0)
        BEGIN SET @Message = N'A new LOT needs a quantity above zero.'; GOTO Fail; END

        -- what this shift has on record AFTER the moves
        DECLARE @Rec TABLE (LotId BIGINT PRIMARY KEY, Recorded INT);
        INSERT INTO @Rec (LotId, Recorded)
        SELECT c.LotId, SUM(c.PieceDelta)
        FROM Workorder.DieCastContribution c
        INNER JOIN Lots.Lot l ON l.Id = c.LotId
        WHERE c.ShiftId = @ShiftId AND c.CellLocationId = @CellLocationId AND l.ToolId = @ToolId
          AND c.Id NOT IN (SELECT Id FROM @MovedC)
        GROUP BY c.LotId;

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(l.LotName, N', ')
        FROM @Rec r INNER JOIN Lots.Lot l ON l.Id = r.LotId
        WHERE r.Recorded <> 0 AND NOT EXISTS (SELECT 1 FROM @Lots lt WHERE lt.LotId = r.LotId);
        IF @Bad IS NOT NULL
        BEGIN
            SET @Message = N'These LOTs have production on record for this shift but no actual figure: ' + @Bad
                         + N'. Enter the actual, or move the entry they came from.';
            GOTO Fail;
        END

        -- ---- 8. the reject lines, per active cavity (A7) ----
        -- Before the totals arithmetic: their sum IS an input to it (see header).
        DECLARE @ActiveCav TABLE (ToolCavityId BIGINT PRIMARY KEY, ItemId BIGINT NULL);
        INSERT INTO @ActiveCav (ToolCavityId, ItemId)
        SELECT tc.Id, tc.ItemId FROM Tools.ToolCavity tc
        INNER JOIN Tools.ToolCavityStatusCode cs ON cs.Id = tc.StatusCodeId
        WHERE tc.ToolId = @ToolId AND tc.DeprecatedAt IS NULL AND cs.Code = N'Active';
        DECLARE @Cavities INT = (SELECT COUNT(*) FROM @ActiveCav);

        IF @HasActual = 0 AND (EXISTS (SELECT 1 FROM @Lots) OR EXISTS (SELECT 1 FROM @Rej))
        BEGIN SET @Message = N'Enter the actual total shots, good shots and warm-up shots.'; GOTO Fail; END

        -- @HasActual = 1 covers every input that needs a cavity: a reject line
        -- without an actual figure was already refused by the gate above.
        IF @Cavities = 0 AND @HasActual = 1
        BEGIN SET @Message = N'This die has no active cavities, so there is nothing to reconcile against.'; GOTO Fail; END

        DECLARE @WarmCodeId BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999');
        IF EXISTS (SELECT 1 FROM @Rej WHERE DefectCodeId = @WarmCodeId)
        BEGIN SET @Message = N'Warm-up is entered as warm-up shots, not as a reject line.'; GOTO Fail; END
        IF EXISTS (SELECT 1 FROM @Rej r WHERE r.Qty IS NULL OR r.Qty < 0
                   OR NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc WHERE dc.Id = r.DefectCodeId AND dc.DeprecatedAt IS NULL))
        BEGIN SET @Message = N'A reject line has an unknown reason or a missing amount.'; GOTO Fail; END
        -- 1.4: the approver must be ACTIVE, not merely on file. This check used
        -- to ask existence only, so a deprecated user was accepted here and
        -- refused by Workorder.DieCastShiftOutput_Record 3.2 -- one column,
        -- Workorder.RejectEvent.ApprovedByUserId, written through the same
        -- worker (Workorder.DieCastScrap_Write) under two different rules.
        -- 'Active' is DeprecatedAt IS NULL, the definition
        -- Location.AppUser_GetActiveByPin / _GetActiveByInitials use, and the
        -- message is now word-for-word the one that path already returns so an
        -- approver the team lead cannot use reads the same wherever they hit
        -- it. Still OPTIONAL and still pre-transaction (Msg-3915 rule): a
        -- reject line that omits approvedByUserId, or passes null, is
        -- untouched -- only a SUPPLIED id is tested.
        IF EXISTS (SELECT 1 FROM @Rej r WHERE r.ApprovedByUserId IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM Location.AppUser u
                                   WHERE u.Id = r.ApprovedByUserId AND u.DeprecatedAt IS NULL))
        BEGIN SET @Message = N'A scrap line''s approver is not an active user; pick the approver again.'; GOTO Fail; END

        DECLARE @RejSpan TABLE (DefectCodeId BIGINT, ItemId BIGINT NULL, Qty INT, ApprovedByUserId BIGINT NULL, Span INT);
        INSERT INTO @RejSpan (DefectCodeId, ItemId, Qty, ApprovedByUserId, Span)
        SELECT r.DefectCodeId, r.ItemId, r.Qty, r.ApprovedByUserId,
               (SELECT COUNT(*) FROM @ActiveCav ac WHERE r.ItemId IS NULL OR ac.ItemId = r.ItemId)
        FROM @Rej r;
        IF EXISTS (SELECT 1 FROM @RejSpan WHERE Span = 0)
        BEGIN SET @Message = N'A reject line names a part that no active cavity on this die makes.'; GOTO Fail; END
        IF EXISTS (SELECT 1 FROM @RejSpan WHERE Qty % Span <> 0)
        BEGIN
            SELECT TOP 1 @Message = CAST(Qty AS NVARCHAR(10)) + N' does not divide evenly across '
                                  + CAST(Span AS NVARCHAR(10)) + N' cavities. Enter it against each part instead.'
            FROM @RejSpan WHERE Qty % Span <> 0;
            GOTO Fail;
        END

        DECLARE @RejTarget TABLE (DefectCodeId BIGINT, ToolCavityId BIGINT, Qty INT, ApprovedByUserId BIGINT NULL,
                                  PRIMARY KEY (DefectCodeId, ToolCavityId));
        INSERT INTO @RejTarget (DefectCodeId, ToolCavityId, Qty, ApprovedByUserId)
        SELECT rs.DefectCodeId, ac.ToolCavityId, SUM(rs.Qty / rs.Span), MAX(rs.ApprovedByUserId)
        FROM @RejSpan rs
        INNER JOIN @ActiveCav ac ON rs.ItemId IS NULL OR ac.ItemId = rs.ItemId
        GROUP BY rs.DefectCodeId, ac.ToolCavityId;

        -- ---- 9. the actual totals must add up (sec 7.4) ----
        DECLARE @NoGood INT = ISNULL((SELECT SUM(Qty) FROM @Rej), 0);
        DECLARE @LotSum INT = ISNULL((SELECT SUM(Qty) FROM @Lots), 0);
        DECLARE @TotalGood INT = NULL;
        IF @HasActual = 1
        BEGIN
            IF @Total IS NULL OR @Good IS NULL OR @Warm IS NULL OR @Total < 0 OR @Good < 0 OR @Warm < 0
            BEGIN SET @Message = N'Enter the actual total shots, good shots and warm-up shots.'; GOTO Fail; END
            IF @Total <> @Good + @Warm
            BEGIN
                SET @Message = N'Total shots ' + CAST(@Total AS NVARCHAR(10)) + N' should equal good shots '
                             + CAST(@Good AS NVARCHAR(10)) + N' + warm-up ' + CAST(@Warm AS NVARCHAR(10))
                             + N' = ' + CAST(@Good + @Warm AS NVARCHAR(10)) + N'. One of them has a typo.';
                GOTO Fail;
            END
            SET @TotalGood = @Good * @Cavities - @NoGood;
            IF @LotSum <> @TotalGood
            BEGIN
                SET @Message = N'LOT list totals ' + CAST(@LotSum AS NVARCHAR(10)) + N'; actual total good is '
                             + CAST(@TotalGood AS NVARCHAR(10)) + N' (' + CAST(@Good AS NVARCHAR(10)) + N' good shots x '
                             + CAST(@Cavities AS NVARCHAR(10)) + N' - ' + CAST(@NoGood AS NVARCHAR(10))
                             + N' no-good). One of them has a typo.';
                GOTO Fail;
            END
            SET @Bad = NULL;
            SELECT @Bad = STRING_AGG(ISNULL(l.LotName, lt.Ltt), N', ')
            FROM @Lots lt LEFT JOIN Lots.Lot l ON l.Id = lt.LotId
            WHERE lt.Qty > @Good;
            IF @Bad IS NOT NULL
            BEGIN
                SET @Message = N'More pieces than the shift''s ' + CAST(@Good AS NVARCHAR(10))
                             + N' good shots made: ' + @Bad + N'. Check the figure.';
                GOTO Fail;
            END
        END

        -- ---- 10. scrap and warm-up gaps: actual minus recorded, per cavity ----
        DECLARE @Scrap TABLE (ToolCavityId BIGINT, DefectCodeId BIGINT, Qty INT, ApprovedByUserId BIGINT NULL);
        IF @HasActual = 1
        BEGIN
            ;WITH rec AS (
                SELECT r.DefectCodeId, r.ToolCavityId, SUM(r.Quantity) AS Qty
                FROM Workorder.RejectEvent r
                WHERE r.ShiftId = @ShiftId AND r.CellLocationId = @CellLocationId AND r.ToolId = @ToolId
                  AND r.DefectCodeId <> @WarmCodeId
                  AND r.Id NOT IN (SELECT Id FROM @MovedR)
                  AND r.ToolCavityId IN (SELECT ToolCavityId FROM @ActiveCav)
                GROUP BY r.DefectCodeId, r.ToolCavityId)
            INSERT INTO @Scrap (ToolCavityId, DefectCodeId, Qty, ApprovedByUserId)
            SELECT COALESCE(t.ToolCavityId, rec.ToolCavityId), COALESCE(t.DefectCodeId, rec.DefectCodeId),
                   ISNULL(t.Qty, 0) - ISNULL(rec.Qty, 0), t.ApprovedByUserId
            FROM @RejTarget t
            FULL JOIN rec ON rec.DefectCodeId = t.DefectCodeId AND rec.ToolCavityId = t.ToolCavityId
            WHERE ISNULL(t.Qty, 0) <> ISNULL(rec.Qty, 0);

            ;WITH recw AS (
                SELECT r.ToolCavityId, SUM(r.Quantity) AS Qty
                FROM Workorder.RejectEvent r
                WHERE r.ShiftId = @ShiftId AND r.CellLocationId = @CellLocationId AND r.ToolId = @ToolId
                  AND r.DefectCodeId = @WarmCodeId
                  AND r.Id NOT IN (SELECT Id FROM @MovedR)
                GROUP BY r.ToolCavityId)
            INSERT INTO @Scrap (ToolCavityId, DefectCodeId, Qty, ApprovedByUserId)
            SELECT ac.ToolCavityId, @WarmCodeId, @Warm - ISNULL(recw.Qty, 0), NULL
            FROM @ActiveCav ac
            LEFT JOIN recw ON recw.ToolCavityId = ac.ToolCavityId
            WHERE @Warm <> ISNULL(recw.Qty, 0);
        END

        -- ---- 11. the LOT plan: the gap, and what it does to each count (sec 3.3) ----
        DECLARE @Plan TABLE (Seq INT IDENTITY(1,1), LotId BIGINT NULL, Ltt NVARCHAR(50), ToolCavityId BIGINT,
                             ItemId BIGINT NULL, IsNew BIT, Gap INT, IsLocked BIT, PieceCount INT, InvAvail INT,
                             ApplyToLot BIT, CorrectCount BIT);
        INSERT INTO @Plan (LotId, Ltt, ToolCavityId, ItemId, IsNew, Gap, IsLocked, PieceCount, InvAvail, ApplyToLot, CorrectCount)
        SELECT lt.LotId, COALESCE(l.LotName, lt.Ltt), lt.ToolCavityId, COALESCE(l.ItemId, tc.ItemId),
               CASE WHEN lt.LotId IS NULL THEN 1 ELSE 0 END,
               lt.Qty - ISNULL(r.Recorded, 0),
               ISNULL(lk.IsLocked, 0), ISNULL(l.PieceCount, 0), ISNULL(l.InventoryAvailable, 0),
               -- the count lock is the authority, not the status: an Open LOT
               -- consumed into another is locked too (see header, 1.2).
               CASE WHEN lt.LotId IS NULL OR (sc.Code = N'Open' AND ISNULL(lk.IsLocked, 0) = 0) THEN 1 ELSE 0 END,
               CASE WHEN sc.Code = N'Good' AND ISNULL(lk.IsLocked, 0) = 0 THEN 1 ELSE 0 END
        FROM @Lots lt
        LEFT JOIN Lots.Lot l ON l.Id = lt.LotId
        LEFT JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        LEFT JOIN Tools.ToolCavity tc ON tc.Id = lt.ToolCavityId
        LEFT JOIN @Rec r ON r.LotId = lt.LotId
        OUTER APPLY Lots.ufn_DieCastLotCountLock(lt.LotId) lk;

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(Ltt, N', ') FROM @Plan
        WHERE Gap < 0 AND (ApplyToLot = 1 OR CorrectCount = 1) AND (PieceCount + Gap < 0 OR InvAvail + Gap < 0);
        IF @Bad IS NOT NULL
        BEGIN SET @Message = N'Taking these LOTs down that far would go below what has already been used from them: ' + @Bad + N'.'; GOTO Fail; END

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(Ltt, N', ') FROM @Plan WHERE CorrectCount = 1 AND Gap <> 0 AND PieceCount + Gap <= 0;
        IF @Bad IS NOT NULL
        BEGIN SET @Message = N'A released LOT cannot be corrected to zero: ' + @Bad + N'. Scrap or void it from LOT Detail.'; GOTO Fail; END

        DECLARE @StorageId BIGINT = (SELECT TOP 1 Id FROM Location.Location
                                     WHERE Code = N'WHSE' AND DeprecatedAt IS NULL ORDER BY Id);
        IF @StorageId IS NULL AND EXISTS (SELECT 1 FROM @Plan WHERE IsNew = 1)
        BEGIN SET @Message = N'No storage/warehouse location configured for release.'; GOTO Fail; END

        DECLARE @DieWmBefore INT = Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @CellLocationId);
        IF NOT EXISTS (SELECT 1 FROM @Moves)
           AND NOT EXISTS (SELECT 1 FROM @Plan WHERE Gap <> 0 OR IsNew = 1)
           AND NOT EXISTS (SELECT 1 FROM @Scrap)
           AND (@Total IS NULL OR @Total = @DieWmBefore)
        BEGIN SET @Message = N'Nothing to save: the record already matches actual.'; GOTO Fail; END

        DECLARE @ShotBefore INT = (SELECT ShotCount FROM Tools.Tool WHERE Id = @ToolId);
        DECLARE @AnchorReasonId BIGINT = (SELECT Id FROM Workorder.DieCastCounterAnchorReason WHERE Code = N'ShiftReconciliation');

        -- ===================== mutation =====================
        BEGIN TRANSACTION;

        INSERT INTO Workorder.DieCastShiftReconciliation
            (ShiftId, CellLocationId, ToolId, ReasonId, Note, ActualTotalShots, ActualGoodShots, ActualWarmUpShots,
             DieShotCountBefore, DieShotCountAfter, AppUserId, TerminalLocationId)
        VALUES (@ShiftId, @CellLocationId, @ToolId, @ReasonId, NULLIF(LTRIM(RTRIM(@Note)), N''),
                @Total, @Good, @Warm, @ShotBefore, @ShotBefore, @AppUserId, @TerminalLocationId);
        SET @NewId = SCOPE_IDENTITY();

        -- Two forms of the same note. Lots.DieCastLot_Mint v1.1 owns its own
        -- separator, so it takes the BARE note; Lots.DieCastLot_ReleaseMove and
        -- Workorder.DieCastCredit_Write still expect the caller's leading space.
        DECLARE @NoteText NVARCHAR(100) = N'(shift reconciliation #' + CAST(@NewId AS NVARCHAR(20)) + N')';
        DECLARE @Suffix   NVARCHAR(100) = N' ' + @NoteText;

        -- (a) moves first: every "recorded" figure above was computed without them
        IF EXISTS (SELECT 1 FROM @Moves)
        BEGIN
            DECLARE @MovesOut NVARCHAR(MAX) = (SELECT EntityType AS entityType, EntityId AS entityId,
                                                      ToShiftId AS toShiftId FROM @Moves FOR JSON PATH);
            EXEC Workorder.DieCastEntry_Restamp @ReconciliationId = @NewId, @MovesJson = @MovesOut,
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;

            -- VERIFY THE PAYLOAD LANDED (code review 2026-09-24, approved
            -- departure from the plan's SQL). The worker emits no result set, so
            -- a five-element payload that resolved to zero rows in there is
            -- indistinguishable from an empty one -- this Save would report
            -- success and the team lead's decision would vanish with nobody
            -- watching, which is the exact failure the feature exists to
            -- prevent. So check every element we sent ourselves.
            --
            -- "Landed" deliberately means the row is ON its target shift, not
            -- that it moved: a row already there is the intended idempotent
            -- skip and must keep passing. What this catches is a row the worker
            -- dropped -- and, in particular, a payload naming one row twice with
            -- two different targets, where the worker's dedup can only honour
            -- one of them.
            DECLARE @NotLanded INT = (
                SELECT COUNT(*) FROM @Moves m
                WHERE NOT EXISTS (SELECT 1 FROM Workorder.DieCastContribution c
                                  WHERE m.EntityType = N'Contribution'
                                    AND c.Id = m.EntityId AND c.ShiftId = m.ToShiftId)
                  AND NOT EXISTS (SELECT 1 FROM Workorder.RejectEvent r
                                  WHERE m.EntityType = N'Reject'
                                    AND r.Id = m.EntityId AND r.ShiftId = m.ToShiftId));
            IF @NotLanded > 0
                RAISERROR(N'%d of the entries being moved did not end up on the shift they were sent to. Nothing was saved.',
                          16, 1, @NotLanded);
        END

        -- (b) new LOTs, minted at the press with the shift's business date
        DECLARE @Seq INT = 0, @PLotId BIGINT, @PLtt NVARCHAR(50), @PCav BIGINT, @PItem BIGINT,
                @PGap INT, @PApply BIT, @PCount INT, @NewCount INT;
        DECLARE @CastDate DATE = CAST(@StartEt AS DATE);
        WHILE 1 = 1
        BEGIN
            SELECT TOP 1 @Seq = Seq, @PLtt = Ltt, @PCav = ToolCavityId, @PItem = ItemId
            FROM @Plan WHERE IsNew = 1 AND Seq > @Seq ORDER BY Seq;
            IF @@ROWCOUNT = 0 BREAK;
            EXEC Lots.DieCastLot_Mint @LotName = @PLtt, @ItemId = @PItem, @ToolId = @ToolId, @ToolCavityId = @PCav,
                @CurrentLocationId = @CellLocationId, @ProducedAtLocationId = @CellLocationId, @CastDate = @CastDate,
                @AuditNote = @NoteText, @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
            UPDATE @Plan SET LotId = (SELECT Id FROM Lots.Lot WHERE LotName = @PLtt) WHERE Seq = @Seq;
        END

        -- (c) credits: the gap only, stamped one second inside the shift
        SET @Seq = 0;
        WHILE 1 = 1
        BEGIN
            SELECT TOP 1 @Seq = Seq, @PLotId = LotId, @PGap = Gap, @PApply = ApplyToLot
            FROM @Plan WHERE Gap <> 0 AND Seq > @Seq ORDER BY Seq;
            IF @@ROWCOUNT = 0 BREAK;
            EXEC Workorder.DieCastCredit_Write @LotId = @PLotId, @ShiftId = @ShiftId, @PieceDelta = @PGap,
                @CounterReading = NULL, @CellLocationId = @CellLocationId, @ApplyToLot = @PApply,
                @ReconciliationId = @NewId, @EventAt = @EventAt, @AuditLocationId = @CellLocationId,
                @AuditSuffix = @Suffix, @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        END

        -- (d) scrap and warm-up gaps, per cavity
        IF EXISTS (SELECT 1 FROM @Scrap)
        BEGIN
            DECLARE @ScrapOut NVARCHAR(MAX) = (
                SELECT c.ToolCavityId AS toolCavityId,
                       JSON_QUERY((SELECT s.DefectCodeId AS defectCodeId, s.Qty AS quantity,
                                          s.ApprovedByUserId AS approvedByUserId
                                   FROM @Scrap s WHERE s.ToolCavityId = c.ToolCavityId FOR JSON PATH)) AS scrapLines
                FROM (SELECT DISTINCT ToolCavityId FROM @Scrap) c
                FOR JSON PATH);
            DECLARE @RecRemark NVARCHAR(200) = N'Die-cast shift reconciliation';
            EXEC Workorder.DieCastScrap_Write @ToolId = @ToolId, @ShiftId = @ShiftId, @CellLocationId = @CellLocationId,
                @LinesJson = @ScrapOut, @Remarks = @RecRemark, @NoLotRemarks = @RecRemark,
                @ReconciliationId = @NewId, @RecordedAt = @EventAt,
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        END

        -- (e) the reading, declared as an anchor, and die life with it (A3)
        DECLARE @DieWm INT = Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @CellLocationId);
        IF @Total IS NOT NULL AND @Total <> @DieWm
        BEGIN
            DECLARE @AnchorNote NVARCHAR(500) = N'Shift reconciliation #' + CAST(@NewId AS NVARCHAR(20))
                                              + N': ' + @ReasonName;
            INSERT INTO Workorder.DieCastCounterAnchor
                (ToolId, ShiftId, CellLocationId, DeclaredReading, ReasonId, Note, AppUserId, TerminalLocationId, EventAt, ReconciliationId)
            VALUES (@ToolId, @ShiftId, @CellLocationId, @Total, @AnchorReasonId, @AnchorNote,
                    @AppUserId, @TerminalLocationId, SYSUTCDATETIME(), @NewId);

            DECLARE @ShotDelta INT = @Total - @DieWm;
            UPDATE Tools.Tool WITH (UPDLOCK, HOLDLOCK)
            SET ShotCount = ShotCount + @ShotDelta, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
            WHERE Id = @ToolId;
            IF (SELECT ShotCount FROM Tools.Tool WHERE Id = @ToolId) < 0
                RAISERROR(N'That would take this die''s lifetime shot count below zero. Check the actual total shots.', 16, 1);
        END

        -- (f) new LOTs leave the press, exactly as a live release does (D4)
        SET @Seq = 0;
        WHILE 1 = 1
        BEGIN
            SELECT TOP 1 @Seq = Seq, @PLotId = LotId FROM @Plan WHERE IsNew = 1 AND Seq > @Seq ORDER BY Seq;
            IF @@ROWCOUNT = 0 BREAK;
            EXEC Lots.DieCastLot_ReleaseMove @LotId = @PLotId, @StorageLocationId = @StorageId,
                @AuditNote = @Suffix, @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        END

        -- (g) released LOTs nothing downstream has counted: correct the count
        DECLARE @CountReason NVARCHAR(500) = N'Shift reconciliation #' + CAST(@NewId AS NVARCHAR(20)) + N': ' + @ReasonName;
        SET @Seq = 0;
        WHILE 1 = 1
        BEGIN
            SELECT TOP 1 @Seq = Seq, @PLotId = LotId, @PGap = Gap, @PCount = PieceCount
            FROM @Plan WHERE CorrectCount = 1 AND Gap <> 0 AND Seq > @Seq ORDER BY Seq;
            IF @@ROWCOUNT = 0 BREAK;
            SET @NewCount = @PCount + @PGap;
            EXEC Lots.Lot_ApplyPieceCountCorrection @LotId = @PLotId, @NewPieceCount = @NewCount,
                @Reason = @CountReason, @ExpectedPieceCount = @PCount,
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        END

        -- (h) close the header and audit the reconciliation
        DECLARE @ShotAfter INT = (SELECT ShotCount FROM Tools.Tool WHERE Id = @ToolId);
        UPDATE Workorder.DieCastShiftReconciliation SET DieShotCountAfter = @ShotAfter WHERE Id = @NewId;

        DECLARE @Added INT = ISNULL((SELECT SUM(Gap) FROM @Plan WHERE Gap > 0), 0);
        DECLARE @Removed INT = ISNULL((SELECT -SUM(Gap) FROM @Plan WHERE Gap < 0), 0);
        DECLARE @NewLots INT = (SELECT COUNT(*) FROM @Plan WHERE IsNew = 1);
        DECLARE @MovedRows INT = (SELECT COUNT(*) FROM @Moves);
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @PressCode + N' ' + Audit.ufn_MidDot() + N' Die Cast ' + Audit.ufn_MidDot() + N' ' + @ShiftLabel
            + N' reconciled: +' + CAST(@Added AS NVARCHAR(10)) + N' good'
            + CASE WHEN @Removed > 0  THEN N', -' + CAST(@Removed AS NVARCHAR(10)) + N' good' ELSE N'' END
            + CASE WHEN @NewLots > 0  THEN N', ' + CAST(@NewLots AS NVARCHAR(10)) + N' new LOTs' ELSE N'' END
            + CASE WHEN @MovedRows > 0 THEN N', ' + CAST(@MovedRows AS NVARCHAR(10)) + N' rows moved' ELSE N'' END;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT h.Id,
                   JSON_QUERY((SELECT s.Id, @ShiftLabel AS Code, @ShiftLabel AS Name FROM Oee.Shift s
                               WHERE s.Id = h.ShiftId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ShiftId,
                   JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc
                               WHERE loc.Id = h.CellLocationId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS CellLocationId,
                   JSON_QUERY((SELECT t.Id, t.Code, t.Name FROM Tools.Tool t
                               WHERE t.Id = h.ToolId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ToolId,
                   JSON_QUERY((SELECT rr.Id, rr.Code, rr.Name FROM Workorder.DieCastReconciliationReason rr
                               WHERE rr.Id = h.ReasonId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ReasonId,
                   h.Note, h.ActualTotalShots, h.ActualGoodShots, h.ActualWarmUpShots,
                   h.DieShotCountBefore, h.DieShotCountAfter,
                   @Added AS PiecesAdded, @Removed AS PiecesRemoved, @NewLots AS NewLots, @MovedRows AS RowsMoved
            FROM Workorder.DieCastShiftReconciliation h WHERE h.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId,
            @LocationId = @CellLocationId, @LogEntityTypeCode = N'DieCastShiftReconciliation', @EntityId = @NewId,
            @LogEventTypeCode = N'DieCastShiftReconciled', @LogSeverityCode = N'Warning',
            @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = @ShiftLabel + N' reconciled.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(), @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        SET @Status = 0; SET @NewId = NULL;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'DieCastShiftReconciliation',
                @EntityId = NULL, @LogEventTypeCode = N'DieCastShiftReconciled', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
        RETURN;
    END CATCH
Fail:
    -- Audit.FailureLog.AppUserId is NOT NULL/FK: the required-parameter branch
    -- above can reach here with @AppUserId itself NULL -- guard the audit call
    -- so that case returns cleanly instead of throwing.
    IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'DieCastShiftReconciliation',
            @EntityId = NULL, @LogEventTypeCode = N'DieCastShiftReconciled', @FailureReason = @Message,
            @ProcedureName = @ProcName, @AttemptedParameters = @Params;
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
END;
GO
