-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_Cancel.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.1
-- Description: Cancels a super-lot that should not have been opened. A reason is
--              required. Ends every open membership (reason RunCancelled) and switches
--              the window off, so the mint resolver stops tagging the part at once.
--
--              It does NOT clear Lots.Lot.CrtActive on the members: cancelling the
--              grouping is not a release of the material. The success message says
--              how many members are still tagged so they can be cleared deliberately.
--
--              Why the window is forced off: a Cancelled row keeps its AutoJoinEnabled
--              value otherwise, and although the resolver also filters on status, a
--              status reset by hand would silently resume tagging.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-super-lot-design.md
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.ControlledRun_Cancel
    @Id                 BIGINT,
    @Remarks            NVARCHAR(500),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.ControlledRun_Cancel';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @Id AS Id, @Remarks AS Remarks, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @RunNumber NVARCHAR(15), @StatusId BIGINT, @Total INT, @StillTagged INT;
    SELECT @RunNumber = RunNumber, @StatusId = ControlledRunStatusId FROM Quality.ControlledRun WHERE Id = @Id;
    SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');

    BEGIN TRY
        -- ---- 1. ----
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunCancelled',
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
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunCancelled',
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
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunCancelled',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 4. ----
        IF @Remarks IS NULL
        BEGIN
            SET @Message = N'A reason is required to cancel a super-lot.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunCancelled',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Final sync BEFORE counting (as ControlledRun_Close does): material the mint resolver
        -- tagged for this window but that no sync has listed yet must be IN the count below.
        -- That count is the only pointer to it once the super-lot is gone. Idempotent and
        -- self-contained; if the cancel then failed, the sync having happened is still correct.
        EXEC Quality.ControlledRun_SyncInternal @ControlledRunId = @Id, @AppUserId = @AppUserId;

        SELECT @Total = COUNT(*), @StillTagged = ISNULL(SUM(CASE WHEN ms.CrtActive = 1 THEN 1 ELSE 0 END), 0)
        FROM Quality.ufn_ControlledRunMemberState(@Id) ms
        WHERE ms.EndedAt IS NULL;

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        UPDATE Quality.ControlledRun
        SET ControlledRunStatusId = 3 /* Cancelled */, ClosedByUserId = @AppUserId, ClosedAt = SYSUTCDATETIME(),
            CloseRemarks = @Remarks,
            AutoJoinEnabled = 0,
            AutoJoinEndedAt = CASE WHEN AutoJoinEnabled = 1 THEN SYSUTCDATETIME() ELSE AutoJoinEndedAt END,
            AutoJoinEndedByUserId = CASE WHEN AutoJoinEnabled = 1 THEN @AppUserId ELSE AutoJoinEndedByUserId END
        WHERE Id = @Id AND ControlledRunStatusId = 1;

        IF @@ROWCOUNT = 0
            RAISERROR(N'Super-lot was changed by someone else.', 16, 1);

        UPDATE Quality.ControlledRunMember
        SET EndedAt = SYSUTCDATETIME(), EndedByUserId = @AppUserId, ControlledRunMemberEndReasonId = 3 /* RunCancelled */
        WHERE ControlledRunId = @Id AND EndedAt IS NULL;

        -- Deliberately NO write to Lots.Lot: cancelling the grouping is not a release.

        DECLARE @ActivityRaw NVARCHAR(MAX) = @RunNumber + N' ' + Audit.ufn_MidDot() + N' Cancelled: ' + @Remarks;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT N'Cancelled' AS Status, @Total AS MemberCount, @StillTagged AS StillCrtTagged, @Remarks AS Remarks,
                   JSON_QUERY((SELECT @Id AS Id, @RunNumber AS Code, @RunNumber AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'ControlledRun',
            @EntityId           = @Id,
            @LogEventTypeCode   = N'ControlledRunCancelled',
            @LogSeverityCode    = N'Warning',
            @Description        = @Activity,
            @OldValue           = N'{"Status":"Open"}',
            @NewValue           = @NewValue;

        DECLARE @Tail NVARCHAR(200) = CASE WHEN @StillTagged > 0
            THEN N' ' + CAST(@StillTagged AS NVARCHAR(10)) + N' members are still CRT-tagged and must be cleared individually.' ELSE N'' END;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Super-lot ' + @RunNumber + N' cancelled.' + @Tail;
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
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunCancelled',
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
