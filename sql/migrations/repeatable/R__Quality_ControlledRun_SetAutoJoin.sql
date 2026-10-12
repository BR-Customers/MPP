-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_SetAutoJoin.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.1
-- Description: Ends (@Enabled = 0) or resumes (@Enabled = 1) a super-lot's rolling
--              window -- whether new production of its part keeps being tagged and
--              added (D7, D9). Ending the window does NOT close the super-lot: 'stop
--              adding to it' and 'we are finished with it' are different moments.
--
--              Ending stamps AutoJoinEndedAt / AutoJoinEndedByUserId; resuming clears
--              them, and the window is then treated as continuous (anything tagged in
--              the gap joins on the next sync).
--
--              ORDER NOTE: when ending, a final ControlledRun_SyncInternal runs BEFORE
--              the transaction so nothing minted in the last minute is left out. It is
--              idempotent and self-contained; if the switch below then failed, the sync
--              having happened is still correct.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-super-lot-design.md
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.ControlledRun_SetAutoJoin
    @Id                 BIGINT,
    @Enabled            BIT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.ControlledRun_SetAutoJoin';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @Id AS Id, @Enabled AS Enabled, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @RunNumber NVARCHAR(15), @StatusId BIGINT, @ItemId BIGINT, @LocationId BIGINT, @Current BIT, @Conflict NVARCHAR(15);
    SELECT @RunNumber = RunNumber, @StatusId = ControlledRunStatusId, @ItemId = SelectionItemId, @LocationId = SelectionLocationId, @Current = AutoJoinEnabled
    FROM Quality.ControlledRun WHERE Id = @Id;

    BEGIN TRY
        -- ---- 1. ----
        IF @Id IS NULL OR @Enabled IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id, Enabled, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunWindowChanged',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 2. ----
        IF @RunNumber IS NULL
        BEGIN
            SET @Message = N'Super-lot not found.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunWindowChanged',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 3. ----
        IF @StatusId <> 1
        BEGIN
            SET @Message = N'Super-lot ' + @RunNumber + N' is not open.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunWindowChanged',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 4. ----
        IF @Enabled = 1 AND @ItemId IS NULL
        BEGIN
            SET @Message = N'Keep adding new production needs a part.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunWindowChanged',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 5. ----
        IF @Enabled = @Current
        BEGIN
            SET @Message = N'Automatic adding is already ' + CASE WHEN @Enabled = 1 THEN N'on.' ELSE N'off.' END;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunWindowChanged',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @Enabled = 1 SELECT @Conflict = RunNumber FROM Quality.ufn_ControlledRunWindowConflict(@ItemId, @LocationId, @Id);
        -- ---- 6. ----
        IF @Conflict IS NOT NULL
        BEGIN
            SET @Message = N'Super-lot ' + @Conflict + N' is already adding new production of this part here. End its window first.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunWindowChanged',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Final sync before the window shuts (see ORDER NOTE in the header).
        IF @Enabled = 0
            EXEC Quality.ControlledRun_SyncInternal @ControlledRunId = @Id, @AppUserId = @AppUserId;

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        UPDATE Quality.ControlledRun
        SET AutoJoinEnabled       = @Enabled,
            AutoJoinEndedAt       = CASE WHEN @Enabled = 0 THEN SYSUTCDATETIME() ELSE NULL END,
            AutoJoinEndedByUserId = CASE WHEN @Enabled = 0 THEN @AppUserId ELSE NULL END
        WHERE Id = @Id;

        DECLARE @Verb NVARCHAR(20) = CASE WHEN @Enabled = 1 THEN N'Resumed' ELSE N'Ended' END;
        DECLARE @ActivityRaw NVARCHAR(MAX) = @RunNumber + N' ' + Audit.ufn_MidDot() + N' Window ' + Audit.ufn_MidDot() + N' ' + @Verb;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
        DECLARE @OldValue NVARCHAR(MAX) = (SELECT @Current AS AutoJoinEnabled FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT @Enabled AS AutoJoinEnabled,
                   JSON_QUERY((SELECT @Id AS Id, @RunNumber AS Code, @RunNumber AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'ControlledRun',
            @EntityId           = @Id,
            @LogEventTypeCode   = N'ControlledRunWindowChanged',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        DECLARE @Tail NVARCHAR(100) = CASE WHEN @Enabled = 1 THEN N' is adding new production again.' ELSE N' has stopped adding new production.' END;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Super-lot ' + @RunNumber + @Tail;
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunWindowChanged',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
