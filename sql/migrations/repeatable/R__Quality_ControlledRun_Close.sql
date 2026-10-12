-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_Close.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.0
-- Description: Closes a super-lot: the statement that every member has been dealt with.
--              In this piece of the feature, members are released ONE AT A TIME through
--              the existing paths (Lots.Lot_ClearCrt on LOT Detail, Lots.Container_
--              ValidateCrt per container); a later piece replaces this with a signed
--              bulk release. So a close is refused while:
--                * the window is still open (End window first -- D9), or
--                * any member is still CRT-tagged (D10). The message says how many.
--
--              ORDER NOTE -- the one place here where a mutation runs before the
--              validations finish: a final ControlledRun_SyncInternal runs after the
--              window check and BEFORE the outstanding-tag count, so material tagged in
--              the window but not yet listed is counted. It is idempotent and
--              self-contained; if the close is then refused, the sync having happened
--              is still correct.
--
--              Closing ends every open membership (reason RunClosed), which is what
--              frees those units to join a later super-lot (D4). It never touches
--              Lots.Lot.CrtActive.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-super-lot-design.md
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.ControlledRun_Close
    @Id                 BIGINT,
    @Remarks            NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.ControlledRun_Close';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @Id AS Id, @Remarks AS Remarks, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @RunNumber NVARCHAR(15), @StatusId BIGINT, @AutoJoin BIT, @Total INT, @Outstanding INT;
    SELECT @RunNumber = RunNumber, @StatusId = ControlledRunStatusId, @AutoJoin = AutoJoinEnabled
    FROM Quality.ControlledRun WHERE Id = @Id;
    SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');

    BEGIN TRY
        -- ---- 1. ----
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunClosed',
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
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunClosed',
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
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunClosed',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 4. ----
        IF @AutoJoin = 1
        BEGIN
            SET @Message = N'End the window before closing.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunClosed',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Final sync (see ORDER NOTE in the header), then count what is outstanding.
        EXEC Quality.ControlledRun_SyncInternal @ControlledRunId = @Id, @AppUserId = @AppUserId;

        SELECT @Total = COUNT(*), @Outstanding = ISNULL(SUM(CASE WHEN ms.CrtActive = 1 THEN 1 ELSE 0 END), 0)
        FROM Quality.ufn_ControlledRunMemberState(@Id) ms
        WHERE ms.EndedAt IS NULL;

        -- ---- 5. ----
        IF @Outstanding > 0
        BEGIN
            SET @Message = CAST(@Outstanding AS NVARCHAR(10)) + N' of ' + CAST(@Total AS NVARCHAR(10)) + N' members are still CRT-tagged.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunClosed',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        UPDATE Quality.ControlledRun
        SET ControlledRunStatusId = 2 /* Closed */, ClosedByUserId = @AppUserId, ClosedAt = SYSUTCDATETIME(),
            CloseRemarks = @Remarks
        WHERE Id = @Id AND ControlledRunStatusId = 1;

        IF @@ROWCOUNT = 0
            RAISERROR(N'Super-lot was closed by someone else.', 16, 1);

        UPDATE Quality.ControlledRunMember
        SET EndedAt = SYSUTCDATETIME(), EndedByUserId = @AppUserId, ControlledRunMemberEndReasonId = 2 /* RunClosed */
        WHERE ControlledRunId = @Id AND EndedAt IS NULL;

        DECLARE @ActivityRaw NVARCHAR(MAX) = @RunNumber + N' ' + Audit.ufn_MidDot() + N' Closed'
            + CASE WHEN @Remarks IS NOT NULL THEN N': ' + @Remarks ELSE N'' END;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT N'Closed' AS Status, @Total AS MemberCount, @Remarks AS CloseRemarks,
                   JSON_QUERY((SELECT @Id AS Id, @RunNumber AS Code, @RunNumber AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'ControlledRun',
            @EntityId           = @Id,
            @LogEventTypeCode   = N'ControlledRunClosed',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = N'{"Status":"Open"}',
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Super-lot ' + @RunNumber + N' closed.';
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
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunClosed',
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
