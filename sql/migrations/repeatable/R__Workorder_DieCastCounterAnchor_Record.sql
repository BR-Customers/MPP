-- ============================================================
-- Repeatable:  R__Workorder_DieCastCounterAnchor_Record.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-10
-- Version:     1.0
-- Description: Die-cast COUNTER ANCHOR, write side (spec 2026-09-10;
--              migration 0074). Records an operator's declaration of the TRUE
--              press-counter reading for a die on a press in a shift.
--
--              WHY THIS EXISTS. Both shot watermarks are MAX(reading) over the
--              shift, and a reading below the DIE watermark is rejected at
--              three places (Lots.DieCastLot_Release,
--              Workorder.DieCastShiftOutput_Record, and the Release dialog's
--              button). Correct for a typo; a dead end for the two cases the
--              floor actually hits -- the counter was reset mid-shift, or a
--              wrong number was entered earlier and has blocked the die for
--              the rest of the shift. A MAX cannot be lowered by appending, so
--              until this proc there was no way out that did not involve
--              editing an append-only ledger.
--
--              WHAT IT DOES NOT DO, DELIBERATELY. Forward-only. It sets where
--              crediting RESUMES from and nothing else:
--                * pieces already credited to baskets by a superseded reading
--                  stay on those baskets;
--                * Tools.Tool.ShotCount keeps whatever those readings added.
--              Both are recorded facts and this proc does not rewrite recorded
--              facts. The operator-facing dialog states this in as many words
--              -- if it ever stops saying so, operators will assume the
--              baskets were fixed too.
--
--              WHY NOT A CONTRIBUTION ROW. Workorder.DieCastContribution.LotId
--              is NOT NULL (0045), so a contribution can only speak for a
--              cavity that has an open basket. The anchor has to reach EVERY
--              cavity on the die -- including Closed, Scrapped, and simply
--              empty ones -- because the next basket opened on any of them
--              inherits the cavity watermark. Hence its own table, floored
--              into both ufn_*ShotWatermark functions.
--
--              NO MONOTONIC GUARD. Declaring a LOWER reading is the entire
--              point; @DeclaredReading is bounded only by >= 0. The reason
--              code and note are the record of why, and the audit row is the
--              record of who.
--
--              AUTHORIZATION. Any signed-in operator, with a reason. They are
--              the only person who can see the press counter, and blocking on
--              a supervisor strands a night shift at a wall. The reason is
--              mandatory and 'Other' additionally requires a note.
--
--              FDS-11-011: no OUTPUT params; @Status/@Message/@NewId are
--              locals and every exit path ends with the one status row.
--              All rejecting validations run BEFORE BEGIN TRANSACTION so a
--              caller capturing this via INSERT-EXEC never meets Msg 3915.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastCounterAnchor_Record
    @ToolId             BIGINT,
    @ShiftId            BIGINT,
    @DeclaredReading    INT,
    @ReasonId           BIGINT,
    @AppUserId          BIGINT,
    @Note               NVARCHAR(500) = NULL,
    @CellLocationId     BIGINT        = NULL,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.DieCastCounterAnchor_Record';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @ToolId AS ToolId, @ShiftId AS ShiftId,
        @DeclaredReading AS DeclaredReading, @ReasonId AS ReasonId, @AppUserId AS AppUserId,
        @CellLocationId AS CellLocationId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ---------- validation (all pre-transaction) ----------
        IF @ToolId IS NULL OR @ShiftId IS NULL OR @DeclaredReading IS NULL
           OR @ReasonId IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message=N'Required parameter missing.'; GOTO Fail; END

        IF @DeclaredReading < 0
        BEGIN SET @Message=N'Counter reading cannot be negative.'; GOTO Fail; END

        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id=@AppUserId)
        BEGIN SET @Message=N'AppUser not found.'; GOTO Fail; END

        IF NOT EXISTS (SELECT 1 FROM Tools.Tool WHERE Id=@ToolId)
        BEGIN SET @Message=N'Tool not found.'; GOTO Fail; END

        IF NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE Id=@ShiftId)
        BEGIN SET @Message=N'Shift not found.'; GOTO Fail; END

        DECLARE @ReasonCode NVARCHAR(30) = (SELECT Code FROM Workorder.DieCastCounterAnchorReason WHERE Id=@ReasonId);
        IF @ReasonCode IS NULL
        BEGIN SET @Message=N'Reason not found.'; GOTO Fail; END

        SET @Note = NULLIF(LTRIM(RTRIM(ISNULL(@Note, N''))), N'');
        IF @ReasonCode = N'Other' AND @Note IS NULL
        BEGIN SET @Message=N'A note is required when the reason is Other.'; GOTO Fail; END

        IF @CellLocationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id=@CellLocationId)
        BEGIN SET @Message=N'Cell location not found.'; GOTO Fail; END

        -- The press. Resolved exactly the way Lots.DieCastLot_Release and
        -- Workorder.DieCast_GetReleasePreview resolve it, or the anchor would
        -- land in a different counter space than the watermarks it must floor.
        DECLARE @ResolvedCellLocationId BIGINT = @CellLocationId;
        IF @ResolvedCellLocationId IS NULL
            SELECT TOP 1 @ResolvedCellLocationId = a.CellLocationId
            FROM Tools.ToolAssignment a
            WHERE a.ToolId = @ToolId AND a.ReleasedAt IS NULL
            ORDER BY a.AssignedAt DESC, a.Id DESC;

        -- What the declaration supersedes -- captured before the write so the
        -- audit row can say what actually changed.
        DECLARE @PriorWatermark INT =
            Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @ResolvedCellLocationId);

        -- ---------- write ----------
        BEGIN TRANSACTION;

        INSERT INTO Workorder.DieCastCounterAnchor
            (ToolId, ShiftId, CellLocationId, DeclaredReading, ReasonId, Note,
             AppUserId, TerminalLocationId, EventAt)
        VALUES
            (@ToolId, @ShiftId, @ResolvedCellLocationId, @DeclaredReading, @ReasonId, @Note,
             @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        SET @NewId = SCOPE_IDENTITY();

        DECLARE @ToolCode NVARCHAR(50) = (SELECT Code FROM Tools.Tool WHERE Id=@ToolId);
        DECLARE @ReasonName NVARCHAR(100) = (SELECT Name FROM Workorder.DieCastCounterAnchorReason WHERE Id=@ReasonId);

        DECLARE @Act NVARCHAR(500) = Audit.ufn_TruncateActivity(
              ISNULL(@ToolCode, N'Die') + N' ' + Audit.ufn_MidDot()
            + N' Die Cast Counter ' + Audit.ufn_MidDot()
            + N' Anchored at ' + CAST(@DeclaredReading AS NVARCHAR(20))
            + N' (was ' + CAST(@PriorWatermark AS NVARCHAR(20)) + N')'
            + N' ' + Audit.ufn_MidDot() + N' ' + ISNULL(@ReasonName, N'')
            + ISNULL(N' ' + Audit.ufn_MidDot() + N' ' + @Note, N''));

        DECLARE @Old NVARCHAR(MAX) = (SELECT @PriorWatermark AS CreditedThrough FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @New NVARCHAR(MAX) = (
            SELECT @DeclaredReading AS CreditedThrough,
                   @ReasonId        AS 'Reason.Id',
                   @ReasonCode      AS 'Reason.Code',
                   @ReasonName      AS 'Reason.Name',
                   @Note            AS Note
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId,
            @LocationId=@ResolvedCellLocationId,
            @LogEntityTypeCode=N'Tool', @EntityId=@ToolId,
            @LogEventTypeCode=N'DieCastCounterAnchored',
            @LogSeverityCode=N'Warning', @Description=@Act, @OldValue=@Old, @NewValue=@New;

        COMMIT TRANSACTION;

        SET @Status=1;
        SET @Message=N'Counter re-anchored at ' + CAST(@DeclaredReading AS NVARCHAR(20))
                   + N'. Crediting resumes from there; pieces already on baskets are unchanged.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Tool', @EntityId=@ToolId,
            @LogEventTypeCode=N'DieCastCounterAnchored', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RAISERROR(@ErrMsg,@ErrSev,@ErrState); RETURN;
    END CATCH
Fail:
    -- Audit.FailureLog.AppUserId is NOT NULL/FK: the required-parameter branch
    -- can reach here with @AppUserId itself NULL -- guard the audit call so
    -- that case returns cleanly instead of throwing (mirrors
    -- Workorder.DieCastShiftOutput_Record's identical guard).
    IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Tool', @EntityId=@ToolId,
            @LogEventTypeCode=N'DieCastCounterAnchored', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
END;
GO
