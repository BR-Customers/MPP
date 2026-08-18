-- ============================================================
-- Repeatable:  R__Location_Terminal_SetCrtEnabled.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-14
-- Version:     1.0
-- Description: Sets the Controlled Run Tag capability on an assembly-out terminal
--              (Location.LocationAttribute 'CrtEnabled', '0'/'1'). Modelled on
--              Location.Terminal_SetClosureMethod. The AD elevation is the UI's
--              FDS-04-007 concern; this proc takes @AppUserId as attribution.
--
--              All rejects run BEFORE BEGIN TRANSACTION (INSERT-EXEC / Msg 3915).
--
--              Audit.Audit_LogConfigChange (verified against
--              R__Location_LocationAttribute_Set.sql, which audits the same
--              Location.LocationAttribute table) is used rather than
--              Audit.Audit_LogOperation (the closure-method reference proc's
--              choice) -- @LogEntityTypeCode = N'Location' and
--              @LogEventTypeCode = N'Updated' are both seeded codes
--              (0001_bootstrap_schemas_audit_identity.sql).
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Terminal_SetCrtEnabled
    @TerminalLocationId BIGINT,
    @Enabled            BIT,
    @AppUserId          BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Location.Terminal_SetCrtEnabled';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @TerminalLocationId AS TerminalLocationId, @Enabled AS Enabled, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @AttrDefId BIGINT, @ExistingId BIGINT, @OldValue NVARCHAR(255), @TermCode NVARCHAR(50);
    DECLARE @NewValue NVARCHAR(20) = CASE WHEN @Enabled = 1 THEN N'1' ELSE N'0' END;

    BEGIN TRY
        IF @TerminalLocationId IS NULL OR @Enabled IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (TerminalLocationId, Enabled, AppUserId).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @TermCode = Code FROM Location.Location
        WHERE Id = @TerminalLocationId AND LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL;
        IF @TermCode IS NULL
        BEGIN
            SET @Message = N'Terminal not found (or not a Terminal location).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT TOP 1 @AttrDefId = Id FROM Location.LocationAttributeDefinition
        WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'CrtEnabled' AND DeprecatedAt IS NULL
        ORDER BY Id;
        IF @AttrDefId IS NULL
        BEGIN
            SET @Message = N'CrtEnabled attribute definition missing (migration 0058 not applied).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @ExistingId = Id, @OldValue = AttributeValue FROM Location.LocationAttribute
        WHERE LocationId = @TerminalLocationId AND LocationAttributeDefinitionId = @AttrDefId;

        BEGIN TRANSACTION;

        IF @ExistingId IS NULL
            INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
            VALUES (@TerminalLocationId, @AttrDefId, @NewValue, SYSUTCDATETIME());
        ELSE
            UPDATE Location.LocationAttribute
            SET AttributeValue = @NewValue, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
            WHERE Id = @ExistingId;

        DECLARE @Descr NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @TermCode + N' ' + Audit.ufn_MidDot() + N' Controlled Run Tag ' + Audit.ufn_MidDot() + N' '
            + CASE WHEN @Enabled = 1 THEN N'Enabled' ELSE N'Disabled' END);
        DECLARE @OldJson NVARCHAR(MAX) = (SELECT ISNULL(@OldValue, N'0') AS CrtEnabled FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewJson NVARCHAR(MAX) = (SELECT @NewValue AS CrtEnabled FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location', @EntityId = @TerminalLocationId,
            @LogEventTypeCode = N'Updated', @LogSeverityCode = N'Info',
            @Description = @Descr, @OldValue = @OldJson, @NewValue = @NewJson;

        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = N'Controlled Run Tag ' + CASE WHEN @Enabled = 1 THEN N'enabled.' ELSE N'disabled.' END;
        SELECT @Status AS Status, @Message AS Message;
        RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'Updated', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
