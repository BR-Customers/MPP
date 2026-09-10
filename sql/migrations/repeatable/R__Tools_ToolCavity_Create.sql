-- =============================================
-- Procedure:   Tools.ToolCavity_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-22
-- Version:     1.1
--
-- Description:
--   Registers a cavity on a Tool. Only valid for Tools whose ToolType
--   has HasCavities = 1. Cavity identity is a PER-PART lowercase
--   alphabetic code (a, b, c ...), unique among active rows within
--   (ToolId, ItemId, CavityCode). This proc always creates an UNMAPPED
--   cavity (ItemId NULL), so it checks its collision inside the NULL
--   part group -- exactly the slice of UQ_ToolCavity_ActiveToolItemCode
--   the inserted row occupies. Use Tools.ToolCavity_SaveAll to create a
--   cavity already mapped to a part.
--   New cavities default to status = Active.
--
-- Change Log:
--   2026-04-22 - 1.0 - Initial.
--   2026-09-10 - 1.1 - @CavityNumber INT becomes @CavityCode NVARCHAR(4)
--                      (migration 0076). Normalized to lowercase and
--                      trimmed before validation; the '>= 1' range check
--                      becomes a 1-4 letters (a-z) format check. The
--                      collision pre-check is scoped to the ItemId-NULL
--                      group because that is the group this proc writes
--                      into; a family die may legitimately carry a cavity
--                      'a' on every part it casts.
-- =============================================
CREATE OR ALTER PROCEDURE Tools.ToolCavity_Create
    @ToolId       BIGINT,
    @CavityCode   NVARCHAR(4),
    @Description  NVARCHAR(500) = NULL,
    @AppUserId    BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Tools.ToolCavity_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ToolId AS ToolId, @CavityCode AS CavityCode,
                @Description AS Description
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- Codes are stored lowercase. Normalize before validating so 'A ' and
    -- 'a' are the same cavity rather than a format rejection.
    SET @CavityCode = LOWER(LTRIM(RTRIM(@CavityCode)));

    BEGIN TRY
        IF @ToolId IS NULL OR @CavityCode IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolCavity',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @CavityCode IS NULL OR @CavityCode = N''
           OR LEN(@CavityCode) > 4
           OR @CavityCode LIKE N'%[^a-z]%'
        BEGIN
            SET @Message = N'Cavity code must be 1-4 letters (a-z).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolCavity',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        DECLARE @HasCavities BIT;
        SELECT @HasCavities = tt.HasCavities
        FROM Tools.Tool t
        INNER JOIN Tools.ToolType tt ON tt.Id = t.ToolTypeId
        WHERE t.Id = @ToolId AND t.DeprecatedAt IS NULL;

        IF @HasCavities IS NULL
        BEGIN
            SET @Message = N'Tool not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolCavity',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @HasCavities = 0
        BEGIN
            SET @Message = N'This Tool''s type does not support cavities.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolCavity',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Mirrors UQ_ToolCavity_ActiveToolItemCode for the row this proc is
        -- about to write: ItemId is always NULL here, so the collision can
        -- only be with another unmapped cavity of the same tool.
        IF EXISTS (SELECT 1 FROM Tools.ToolCavity
                   WHERE ToolId = @ToolId AND ItemId IS NULL
                     AND CavityCode = @CavityCode
                     AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'An active cavity with this code already exists on the Tool.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolCavity',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        DECLARE @ActiveStatusId BIGINT;
        SELECT @ActiveStatusId = Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active';

        BEGIN TRANSACTION;

        INSERT INTO Tools.ToolCavity
            (ToolId, CavityCode, StatusCodeId, Description, CreatedAt, CreatedByUserId)
        VALUES
            (@ToolId, @CavityCode, @ActiveStatusId, @Description, SYSUTCDATETIME(), @AppUserId);

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'ToolCavity',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = N'ToolCavity created.',
            @OldValue          = NULL,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'ToolCavity created successfully.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId   = NULL;

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolCavity',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
