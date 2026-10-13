-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_RemoveMember.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.1
-- Change Log:  2026-10-13 - 1.1 - The still-tagged message is right for a container
--                                 (released from the Sign-off tab, not LOT Detail).
-- Description: Removes ONE member from an OPEN super-lot: a correction to the list. A
--              reason is required.
--
--              D6: removing a member does NOT clear Lots.Lot.CrtActive. Releasing
--              material is a separate, deliberate act (LOT Detail / container
--              validation); otherwise 'remove from the super-lot' would be an unaudited
--              back door around release. When the unit is still tagged the success
--              message says so.
--
--              The membership row is ended (EndedAt + reason 'Removed'), never deleted,
--              which also frees the unit to join another super-lot (D4).
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-super-lot-design.md
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.ControlledRun_RemoveMember
    @MemberId           BIGINT,
    @Remarks            NVARCHAR(500),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.ControlledRun_RemoveMember';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @MemberId AS MemberId, @Remarks AS Remarks, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @RunId BIGINT, @RunNumber NVARCHAR(15), @StatusId BIGINT, @EndedAt DATETIME2(3),
            @DisplayName NVARCHAR(60), @StillTagged BIT, @Found BIT = 0, @IsContainer BIT = 0;
    SELECT @RunId = m.ControlledRunId, @EndedAt = m.EndedAt, @Found = 1
    FROM Quality.ControlledRunMember m WHERE m.Id = @MemberId;
    SELECT @RunNumber = RunNumber, @StatusId = ControlledRunStatusId FROM Quality.ControlledRun WHERE Id = @RunId;
    SELECT @DisplayName = ms.DisplayName, @StillTagged = ms.CrtActive,
           @IsContainer = CASE WHEN ms.ContainerId IS NOT NULL THEN 1 ELSE 0 END
    FROM Quality.ufn_ControlledRunMemberState(@RunId) ms WHERE ms.MemberId = @MemberId;
    SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');

    BEGIN TRY
        -- ---- 1. ----
        IF @MemberId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (MemberId, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @RunId, @LogEventTypeCode = N'ControlledRunMemberRemoved',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 2. ----
        IF @Found = 0
        BEGIN
            SET @Message = N'Member not found.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @RunId, @LogEventTypeCode = N'ControlledRunMemberRemoved',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 3. ----
        IF @EndedAt IS NOT NULL
        BEGIN
            SET @Message = N'Member is no longer in the super-lot.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @RunId, @LogEventTypeCode = N'ControlledRunMemberRemoved',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 4. ----
        IF @StatusId <> 1
        BEGIN
            SET @Message = N'Super-lot ' + @RunNumber + N' is not open.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @RunId, @LogEventTypeCode = N'ControlledRunMemberRemoved',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 5. ----
        IF @Remarks IS NULL
        BEGIN
            SET @Message = N'A reason is required to remove a member.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @RunId, @LogEventTypeCode = N'ControlledRunMemberRemoved',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        UPDATE Quality.ControlledRunMember
        SET EndedAt = SYSUTCDATETIME(), EndedByUserId = @AppUserId,
            ControlledRunMemberEndReasonId = 1 /* Removed */, EndRemarks = @Remarks
        WHERE Id = @MemberId AND EndedAt IS NULL;

        IF @@ROWCOUNT = 0
            RAISERROR(N'Member was removed by someone else.', 16, 1);

        -- D6: deliberately NO write to Lots.Lot here.

        DECLARE @ActivityRaw NVARCHAR(MAX) = @RunNumber + N' ' + Audit.ufn_MidDot() + N' Members ' + Audit.ufn_MidDot()
            + N' - ' + @DisplayName + N': ' + @Remarks;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT @DisplayName AS Member, @Remarks AS Remarks, @StillTagged AS StillCrtTagged,
                   JSON_QUERY((SELECT @RunId AS Id, @RunNumber AS Code, @RunNumber AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'ControlledRun',
            @EntityId           = @RunId,
            @LogEventTypeCode   = N'ControlledRunMemberRemoved',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        DECLARE @Tail NVARCHAR(200) = CASE
            WHEN @StillTagged = 1 AND @IsContainer = 1
                THEN N' It is still CRT-tagged and cannot ship; add it back and release it on the Sign-off tab if it should be released.'
            WHEN @StillTagged = 1
                THEN N' It is still CRT-tagged; clear it on LOT Detail if it should be released.'
            ELSE N'' END;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = @DisplayName + N' removed from super-lot ' + @RunNumber + N'.' + @Tail;
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
                    @EntityId = @RunId, @LogEventTypeCode = N'ControlledRunMemberRemoved',
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
