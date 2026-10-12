-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_AddMembers.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.0
-- Description: Adds LOTs and/or containers to an OPEN super-lot (the scan-in path; join
--              method 'Manual'). @MembersJson = [{"lotId":n} | {"containerId":n}, ...].
--
--              Every unit is judged by Quality.ufn_ControlledRunResolveMembers; ONE
--              ineligible unit refuses the call and is named. A finished-good tray LOT
--              is folded to its container (D3), so scanning two trays of one container
--              adds the container once. Joining sets Lots.Lot.CrtActive (D5), in the
--              silent helper ControlledRun_ApplyMembersInternal.
--
--              The names for the audit line are read BEFORE the transaction: once a unit
--              has joined, the resolver reports it as 'already in'.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-super-lot-design.md
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.ControlledRun_AddMembers
    @Id                 BIGINT,
    @MembersJson        NVARCHAR(MAX),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.ControlledRun_AddMembers';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @Id AS Id, LEFT(@MembersJson, 2000) AS MembersJson, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @RunNumber NVARCHAR(15), @StatusId BIGINT, @MemberCount INT, @Bad NVARCHAR(400), @Names NVARCHAR(MAX);
    SELECT @RunNumber = RunNumber, @StatusId = ControlledRunStatusId FROM Quality.ControlledRun WHERE Id = @Id;

    BEGIN TRY
        -- ---- 1. ----
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunMemberAdded',
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
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunMemberAdded',
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
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunMemberAdded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @MemberCount = COUNT(*) FROM Quality.ufn_ControlledRunResolveMembers(@MembersJson);
        -- ---- 4. ----
        IF @MemberCount = 0
        BEGIN
            SET @Message = N'Nothing to add.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunMemberAdded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @Bad = STRING_AGG(x.Txt, N'; ')
        FROM (SELECT TOP 3 r.DisplayName + N' (' + r.IneligibleReason + N')' AS Txt
              FROM Quality.ufn_ControlledRunResolveMembers(@MembersJson) r
              WHERE r.IneligibleReason IS NOT NULL
              ORDER BY r.DisplayName) x;
        -- ---- 5. ----
        IF @Bad IS NOT NULL
        BEGIN
            SET @Message = N'Cannot add: ' + @Bad;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunMemberAdded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @Names = STRING_AGG(N'+ ' + r.DisplayName, N', ') WITHIN GROUP (ORDER BY r.DisplayName)
        FROM Quality.ufn_ControlledRunResolveMembers(@MembersJson) r;

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        DECLARE @Before INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE ControlledRunId = @Id);

        EXEC Quality.ControlledRun_ApplyMembersInternal
            @ControlledRunId = @Id, @MembersJson = @MembersJson, @JoinMethodCode = N'Manual',
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;

        DECLARE @Added INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE ControlledRunId = @Id) - @Before;

        DECLARE @ActivityRaw NVARCHAR(MAX) = @RunNumber + N' ' + Audit.ufn_MidDot() + N' Members ' + Audit.ufn_MidDot() + N' ' + @Names;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT @Added AS Added, @Names AS Members,
                   JSON_QUERY((SELECT @Id AS Id, @RunNumber AS Code, @RunNumber AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'ControlledRun',
            @EntityId           = @Id,
            @LogEventTypeCode   = N'ControlledRunMemberAdded',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = CAST(@Added AS NVARCHAR(10)) + N' added to super-lot ' + @RunNumber + N'.';
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
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunMemberAdded',
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
