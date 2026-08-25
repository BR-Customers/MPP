-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftOutput_Record.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-19
-- Version:     1.4
-- Change:      v1.4 -- shift-override ATTRIBUTION (OI-2 / spec sec 5): every
--              Workorder.DieCastContribution row now carries CellLocationId --
--              the PRESS -- taken from @CellLocationId, else from the die's
--              currently-mounted Tools.ToolAssignment. Freezes the press against
--              later die moves so Oee.ShiftOverride_Restamp keys on a plain
--              equality instead of re-deriving assignment history.
-- Change:      v1.3 -- FAT #19: new @CellLocationId BIGINT param (the die-cast
--              MACHINE/cell location selected in the entry header). Threaded
--              into the 'DieCastPieceContributed' audit op as @LocationId
--              (was hard-coded NULL) so the event log captures WHICH machine
--              the parts were added at, not just the terminal. Default NULL =
--              backward-compatible; the standalone shot-loss path (no
--              per-cavity lines) emits no DieCastPieceContributed op so is
--              unaffected.
-- Change:      v1.2 -- FAT #26/#27: new @GrossShots INT param; when > 0,
--              increments Tools.Tool.ShotCount for @ToolId in the same txn
--              (materialized die shot counter). Negative gross rejected
--              pre-transaction. NULL/0 = no-op (the shot-loss path never bumps).
-- Change:      v1.1 -- pre-transaction defect-code validation: every
--              scrapLines[].defectCodeId (across all lines) and every
--              shotLoss[].defectCodeId must exist and be active in
--              Quality.DefectCode, else GOTO Fail with a clean Status=0
--              instead of an in-transaction FK RAISERROR (mirrors
--              RejectEvent_Record's DeprecatedAt check).
-- Description: Die-Cast Per-Cavity Lifecycle plan, Task 4 / Phase 2. The
--              shift-output recording WRITE proc: fans the operator-confirmed
--              per-cavity-lot split (Workorder.DieCast_GetShiftOutputBreakdown,
--              Task 3, is the read-side proposal this confirms/adjusts) into
--              open accumulator baskets --
--                * per line: a Workorder.DieCastContribution ledger row +
--                  Lot.PieceCount/InventoryAvailable += net good (@pieceDelta)
--                  + a routed 'Lot'/'DieCastPieceContributed' audit op
--                * per line's scrapLines[]: additive Workorder.RejectEvent rows
--                  (record-only -- die-cast scrap never entered the basket, so
--                  it must NOT decrement PieceCount/InventoryAvailable and must
--                  NOT close the LOT; mirrors R__Workorder_RejectEvent_Record.sql's
--                  @Additive=1 branch, inlined here rather than EXEC'd per the
--                  INSERT-EXEC / single-result-set rule)
--                * @ShotLossJson: an additive RejectEvent fanned across EVERY
--                  currently-Open lot on this tool (a shot-level defect --
--                  e.g. a short shot on the whole cycle -- hits every cavity,
--                  not just one lot's line)
--
--              FDS-11-011 + Msg-3915 rules: ALL rejecting validations
--              (required params, JSON well-formed, AppUser exists, every
--              submitted lot is an Open basket on this tool, no negative
--              pieceDelta) run BEFORE BEGIN TRANSACTION -- this proc is
--              captured via INSERT-EXEC by callers/tests, so a ROLLBACK in an
--              open caller txn throws Msg 3915; CATCH is the only legal
--              ROLLBACK site. All sub-mutations (contribution insert, LOT
--              increment, additive reject inserts) are INLINED rather than
--              EXEC'd against sibling status-row procs. Row-locked
--              UPDLOCK/HOLDLOCK increment per LOT (mirrors Lot_Split /
--              RejectEvent_Record's PieceCount-mutation locking). Single
--              terminal row: Status, Message, NewId (always NULL -- this proc
--              fans out to N lots, there is no single "the" new id).
--
--              Deviation from the Task 4 brief: the brief's Fail: label
--              unconditionally calls Audit.Audit_LogFailure with
--              @AppUserId = @AppUserId, but Audit.FailureLog.AppUserId is
--              NOT NULL/FK -- the very first validation branch (required-
--              parameter check) can be reached with @AppUserId itself NULL,
--              which would throw inside the audit call instead of returning
--              the clean Status=0 row. Lot_Create and Lots.DieCastLot_Open
--              (Task 2) hit and fixed this identical case; mirrored here by
--              guarding the Fail: audit call with an EXISTS check on
--              Location.AppUser. NOTE (2026-08-18): the guard was originally
--              IF @AppUserId IS NOT NULL, which only covers a NULL actor. A
--              non-NULL but NON-EXISTENT id -- exactly what the 'AppUser not
--              found' validation detects, e.g. a session cached against a
--              different database -- passed that guard and violated the FK
--              inside the logger, turning a clean rejection into an unhandled
--              JDBC exception on the operator's screen. Hardened to EXISTS.
--              The brief's RejectEvent INSERT column list (ProductionEventId,
--              LotId, DefectCodeId, Quantity, ChargeToArea, Remarks,
--              AppUserId, RecordedAt) was verified against
--              R__Workorder_RejectEvent_Record.sql / the 0020 table DDL and is
--              correct as written -- no column fix was needed. Otherwise
--              verbatim from the brief.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftOutput_Record
    @ShiftId BIGINT, @ToolId BIGINT, @LinesJson NVARCHAR(MAX),
    @ShotLossJson NVARCHAR(MAX) = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL,
    @GrossShots INT = NULL,
    @CellLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.DieCastShiftOutput_Record';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @ShiftId AS ShiftId, @ToolId AS ToolId, LEFT(@LinesJson,2000) AS LinesJson, @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ShiftId IS NULL OR @ToolId IS NULL OR @LinesJson IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message=N'Required parameter missing.'; GOTO Fail; END
        IF ISJSON(@LinesJson) <> 1 OR (@ShotLossJson IS NOT NULL AND ISJSON(@ShotLossJson) <> 1)
        BEGIN SET @Message=N'LinesJson/ShotLossJson not valid JSON.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id=@AppUserId) BEGIN SET @Message=N'AppUser not found.'; GOTO Fail; END
        IF @GrossShots IS NOT NULL AND @GrossShots < 0 BEGIN SET @Message=N'GrossShots cannot be negative.'; GOTO Fail; END

        DECLARE @Lines TABLE (LotId BIGINT, PieceDelta INT, ScrapLines NVARCHAR(MAX));
        INSERT INTO @Lines (LotId, PieceDelta, ScrapLines)
        SELECT j.lotId, j.pieceDelta, j.scrapLines
        FROM OPENJSON(@LinesJson) WITH (lotId BIGINT N'$.lotId', pieceDelta INT N'$.pieceDelta', scrapLines NVARCHAR(MAX) N'$.scrapLines' AS JSON) j;

        -- every line lot must be Open and on this tool
        IF EXISTS (SELECT 1 FROM @Lines ln LEFT JOIN Lots.Lot l ON l.Id=ln.LotId
                   LEFT JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId
                   WHERE l.Id IS NULL OR sc.Code <> N'Open' OR l.ToolId <> @ToolId)
        BEGIN SET @Message=N'A submitted lot is not an open basket on this tool.'; GOTO Fail; END
        IF EXISTS (SELECT 1 FROM @Lines WHERE PieceDelta < 0) BEGIN SET @Message=N'pieceDelta cannot be negative.'; GOTO Fail; END

        -- every scrap/shot-loss defectCodeId must exist and be active -- rejects
        -- gracefully here instead of hitting the FK constraint mid-transaction
        -- (mirrors R__Workorder_RejectEvent_Record.sql's DeprecatedAt check)
        IF EXISTS (
            SELECT 1 FROM @Lines ln
            CROSS APPLY OPENJSON(ln.ScrapLines) WITH (defectCodeId BIGINT N'$.defectCodeId') s
            WHERE ln.ScrapLines IS NOT NULL AND ISJSON(ln.ScrapLines) = 1
              AND NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc WHERE dc.Id = s.defectCodeId AND dc.DeprecatedAt IS NULL)
        )
        OR (@ShotLossJson IS NOT NULL AND ISJSON(@ShotLossJson) = 1 AND EXISTS (
            SELECT 1 FROM OPENJSON(@ShotLossJson) WITH (defectCodeId BIGINT N'$.defectCodeId') sl
            WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc WHERE dc.Id = sl.defectCodeId AND dc.DeprecatedAt IS NULL)
        ))
        BEGIN SET @Message=N'One or more scrap/shot-loss defect codes are invalid or deprecated.'; GOTO Fail; END

        -- v1.4 (shift-override attribution, OI-2 / spec sec 5): the PRESS this
        -- output was produced on is stamped onto every DieCastContribution row.
        -- Attribution overrides are keyed to the press (design D5), and deriving
        -- it later through Tools.ToolAssignment history means moving the die
        -- months from now would silently re-attribute settled production. The
        -- screen supplies @CellLocationId (FAT #19); when an older caller does
        -- not, fall back to the die's CURRENTLY-MOUNTED cell -- correct by
        -- construction here, because output can only be recorded on the press
        -- the die is on right now. Still NULLable: a die with no active
        -- assignment leaves it NULL and that row is excluded from
        -- equipment-scoped restamps rather than guessed at.
        DECLARE @ResolvedCellLocationId BIGINT = @CellLocationId;
        IF @ResolvedCellLocationId IS NULL
            SELECT TOP 1 @ResolvedCellLocationId = a.CellLocationId
            FROM Tools.ToolAssignment a
            WHERE a.ToolId = @ToolId AND a.ReleasedAt IS NULL
            ORDER BY a.AssignedAt DESC, a.Id DESC;

        -- ===== mutation =====
        BEGIN TRANSACTION;
        DECLARE @LotId BIGINT, @Delta INT, @Scrap NVARCHAR(MAX);
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT LotId, PieceDelta, ScrapLines FROM @Lines;
        OPEN cur; FETCH NEXT FROM cur INTO @LotId, @Delta, @Scrap;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @Delta > 0
            BEGIN
                INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, TerminalLocationId, EventAt, CellLocationId)
                VALUES (@LotId, @ShiftId, @Delta, @AppUserId, @TerminalLocationId, SYSUTCDATETIME(), @ResolvedCellLocationId);
                UPDATE Lots.Lot WITH (UPDLOCK, HOLDLOCK)
                SET PieceCount = PieceCount + @Delta, InventoryAvailable = InventoryAvailable + @Delta,
                    UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
                WHERE Id = @LotId;
                DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id=@LotId);
                DECLARE @Act NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
                    + N' Die Cast ' + Audit.ufn_MidDot() + N' Added ' + CAST(@Delta AS NVARCHAR(10)) + N' pc');
                EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@CellLocationId,
                    @LogEntityTypeCode=N'Lot', @EntityId=@LotId, @LogEventTypeCode=N'DieCastPieceContributed',
                    @LogSeverityCode=N'Info', @Description=@Act, @OldValue=NULL, @NewValue=NULL;
            END
            -- inlined ADDITIVE scrap rows (mirror RejectEvent_Record @Additive=1: record only, no decrement, no close)
            IF @Scrap IS NOT NULL AND ISJSON(@Scrap) = 1
                INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, RecordedAt)
                SELECT NULL, @LotId, s.defectCodeId, s.quantity, NULL, N'Die-cast per-cavity scrap', @AppUserId, SYSUTCDATETIME()
                FROM OPENJSON(@Scrap) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') s;
            FETCH NEXT FROM cur INTO @LotId, @Delta, @Scrap;
        END
        CLOSE cur; DEALLOCATE cur;

        -- shot-loss fan-out: an additive reject on EVERY active cavity's open lot for this tool
        IF @ShotLossJson IS NOT NULL AND ISJSON(@ShotLossJson) = 1
            INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, RecordedAt)
            SELECT NULL, l.Id, sl.defectCodeId, sl.quantity, NULL, N'Die-cast shot loss (all cavities)', @AppUserId, SYSUTCDATETIME()
            FROM OPENJSON(@ShotLossJson) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') sl
            CROSS JOIN Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId
            WHERE l.ToolId=@ToolId AND sc.Code=N'Open';

        -- FAT #26/#27: materialized die shot counter. The operator's gross shot
        -- count for this die/shift is the authoritative cycle count; bump it in
        -- the same txn (B5 materialized-quantity pattern, row-locked). NULL/0 =
        -- no-op, so the standalone shot-loss path never double-counts.
        IF @GrossShots > 0
            UPDATE Tools.Tool WITH (UPDLOCK, HOLDLOCK)
            SET ShotCount = ShotCount + @GrossShots,
                UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
            WHERE Id = @ToolId;

        COMMIT TRANSACTION;
        SET @Status=1; SET @Message=N'Shift output recorded.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
            @LogEventTypeCode=N'DieCastPieceContributed', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RAISERROR(@ErrMsg,@ErrSev,@ErrState); RETURN;
    END CATCH
Fail:
    -- Audit.FailureLog.AppUserId is NOT NULL/FK: the required-parameter branch
    -- above can reach here with @AppUserId itself NULL -- guard the audit call
    -- so that case returns cleanly instead of throwing (mirrors Lot_Create /
    -- Lots.DieCastLot_Open's identical guard).
    IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
            @LogEventTypeCode=N'DieCastPieceContributed', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
END;
GO
