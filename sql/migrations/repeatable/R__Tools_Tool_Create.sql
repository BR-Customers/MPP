-- =============================================
-- Procedure:   Tools.Tool_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-22
-- Version:     1.1  (2026-09-10 -- operator-facing 'Code' reads 'Asset Number')
--
-- Description:
--   Creates a new Tool row. Validates ToolTypeId + StatusCodeId FKs,
--   enforces Code uniqueness, enforces the Die-only constraint on
--   DieRankId (can only be non-NULL when the ToolType.Code = 'Die').
--   Sets CreatedByUserId = @AppUserId.
--
-- Parameters (input):
--   @ToolTypeId BIGINT           - FK → Tools.ToolType. Required.
--   @Code NVARCHAR(50)           - Required. Unique across all Tools.
--   @Name NVARCHAR(100)          - Required.
--   @Description NVARCHAR(500)   - Optional.
--   @DieRankId BIGINT            - FK → Tools.DieRank. Nullable; must be
--                                  NULL for non-Die types.
--   @StatusCodeId BIGINT         - FK → Tools.ToolStatusCode. Required.
--   @AppUserId BIGINT            - Required.
--
-- Result set:
--   Single row: Status, Message, NewId.
--
-- Dependencies:
--   Tables: Tools.Tool, Tools.ToolType, Tools.ToolStatusCode, Tools.DieRank
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
-- =============================================
CREATE OR ALTER PROCEDURE Tools.Tool_Create
    @ToolTypeId   BIGINT,
    @Code         NVARCHAR(50),
    @Name         NVARCHAR(100),
    @Description  NVARCHAR(500) = NULL,
    @DieRankId    BIGINT        = NULL,
    @StatusCodeId BIGINT,
    @AppUserId    BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Tools.Tool_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ToolTypeId   AS ToolTypeId,
                @Code         AS Code,
                @Name         AS Name,
                @Description  AS Description,
                @DieRankId    AS DieRankId,
                @StatusCodeId AS StatusCodeId
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ToolTypeId IS NULL OR @Code IS NULL OR @Name IS NULL
           OR @StatusCodeId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        DECLARE @ToolTypeCode   NVARCHAR(50);
        SELECT @ToolTypeCode = Code
        FROM Tools.ToolType
        WHERE Id = @ToolTypeId AND DeprecatedAt IS NULL;

        IF @ToolTypeCode IS NULL
        BEGIN
            SET @Message = N'Invalid or deprecated ToolTypeId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Tools.ToolStatusCode WHERE Id = @StatusCodeId)
        BEGIN
            SET @Message = N'Invalid StatusCodeId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- DieRankId only valid for Die-type Tools
        IF @DieRankId IS NOT NULL
        BEGIN
            IF @ToolTypeCode <> N'Die'
            BEGIN
                SET @Message = N'DieRankId is only valid for Die-type Tools.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                    @EntityId = NULL, @LogEventTypeCode = N'Created',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END

            IF NOT EXISTS (SELECT 1 FROM Tools.DieRank
                           WHERE Id = @DieRankId AND DeprecatedAt IS NULL)
            BEGIN
                SET @Message = N'Invalid or deprecated DieRankId.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                    @EntityId = NULL, @LogEventTypeCode = N'Created',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END
        END

        -- Code unique across ALL Tools (deprecated included — UQ constraint is total)
        IF EXISTS (SELECT 1 FROM Tools.Tool WHERE Code = @Code)
        BEGIN
            SET @Message = N'A Tool with this Asset Number already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        BEGIN TRANSACTION;

        INSERT INTO Tools.Tool
            (ToolTypeId, Code, Name, Description, DieRankId, StatusCodeId,
             CreatedAt, CreatedByUserId)
        VALUES
            (@ToolTypeId, @Code, @Name, @Description, @DieRankId, @StatusCodeId,
             SYSUTCDATETIME(), @AppUserId);

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Tool',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = N'Tool created.',
            @OldValue          = NULL,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Tool created successfully.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId   = NULL;

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
