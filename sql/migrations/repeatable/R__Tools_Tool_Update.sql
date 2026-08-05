-- =============================================
-- Procedure:   Tools.Tool_Update
-- Author:      Blue Ridge Automation
-- Created:     2026-04-22
-- Version:     1.0
--
-- Description:
--   Updates mutable fields on a Tool: Name, Description, DieRankId.
--   Enforces the Die-only constraint on DieRankId (rejected when the
--   Tool's ToolType is not Die). Does NOT change ToolTypeId (immutable
--   after creation), Code (immutable), or StatusCodeId (use
--   Tool_UpdateStatus instead).
--
-- Parameters (input):
--   @Id BIGINT                  - PK. Required.
--   @Name NVARCHAR(100)         - Required.
--   @Description NVARCHAR(500)  - Optional.
--   @DieRankId BIGINT           - Nullable; must be NULL for non-Die.
--   @AppUserId BIGINT           - Required.
--
-- Result set:
--   Single row: Status, Message.
--
-- Dependencies:
--   Tables: Tools.Tool, Tools.ToolType, Tools.DieRank
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
-- =============================================
CREATE OR ALTER PROCEDURE Tools.Tool_Update
    @Id          BIGINT,
    @Name        NVARCHAR(100),
    @Description NVARCHAR(500) = NULL,
    @DieRankId   BIGINT        = NULL,
    @ShotLimit   INT           = NULL,
    @AppUserId   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Tools.Tool_Update';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id          AS Id,
                @Name        AS Name,
                @Description AS Description,
                @DieRankId   AS DieRankId,
                @ShotLimit   AS ShotLimit
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @Id IS NULL OR @Name IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @ToolTypeCode NVARCHAR(50), @OldName NVARCHAR(100),
                @OldDescription NVARCHAR(500), @OldDieRankId BIGINT, @OldShotLimit INT;

        SELECT @ToolTypeCode   = tt.Code,
               @OldName        = t.Name,
               @OldDescription = t.Description,
               @OldDieRankId   = t.DieRankId,
               @OldShotLimit   = t.ShotLimit
        FROM Tools.Tool t
        INNER JOIN Tools.ToolType tt ON tt.Id = t.ToolTypeId
        WHERE t.Id = @Id AND t.DeprecatedAt IS NULL;

        IF @ToolTypeCode IS NULL
        BEGIN
            SET @Message = N'Tool not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ShotLimit IS NOT NULL AND @ToolTypeCode <> N'Die'
        BEGIN
            SET @Message = N'ShotLimit is only valid for Die-type Tools.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @DieRankId IS NOT NULL
        BEGIN
            IF @ToolTypeCode <> N'Die'
            BEGIN
                SET @Message = N'DieRankId is only valid for Die-type Tools.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                    @EntityId = @Id, @LogEventTypeCode = N'Updated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END

            IF NOT EXISTS (SELECT 1 FROM Tools.DieRank
                           WHERE Id = @DieRankId AND DeprecatedAt IS NULL)
            BEGIN
                SET @Message = N'Invalid or deprecated DieRankId.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                    @EntityId = @Id, @LogEventTypeCode = N'Updated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END
        END

        DECLARE @OldValue NVARCHAR(MAX) =
            (SELECT @OldName AS Name, @OldDescription AS Description,
                    @OldDieRankId AS DieRankId, @OldShotLimit AS ShotLimit
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        UPDATE Tools.Tool
        SET Name            = @Name,
            Description     = @Description,
            DieRankId       = @DieRankId,
            ShotLimit       = @ShotLimit,
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Tool',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = N'Tool updated.',
            @OldValue          = @OldValue,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Tool updated successfully.';
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
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
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
