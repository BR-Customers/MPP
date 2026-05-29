-- =============================================
-- Procedure:   Quality.DefectCode_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.1
--
-- Description:
--   Soft-deletes a defect code by setting DeprecatedAt. The
--   code remains in history and continues to fulfill FK
--   constraints from production records. Rejects if already
--   deprecated.
--
-- Parameters (input):
--   @Id BIGINT        - Required.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Dependencies:
--   Tables: Quality.DefectCode
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention (Slice 8 Downtime+Defect
--                       codes): SUBJECT . ACTION narrative Description +
--                       resolved-FK OldValue/NewValue JSON.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.DefectCode_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.DefectCode_Deprecate';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Existence checks
        -- ====================
        DECLARE @Code         NVARCHAR(20);
        DECLARE @OldDesc      NVARCHAR(500);
        DECLARE @OldAreaId    BIGINT;
        DECLARE @OldIsExcused BIT;
        DECLARE @DeprecatedAt DATETIME2(3);
        DECLARE @RowExists    BIT = 0;

        SELECT @Code         = Code,
               @OldDesc      = Description,
               @OldAreaId    = AreaLocationId,
               @OldIsExcused = IsExcused,
               @DeprecatedAt = DeprecatedAt,
               @RowExists    = 1
        FROM Quality.DefectCode WHERE Id = @Id;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'Defect code not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @DeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Defect code is already deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Audit narrative + resolved JSON (built from PRE-mutation state)
        -- ====================
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Defect Code ' + @Code + N' ' + Audit.ufn_MidDot() + N' Deprecated');

        -- OldValue: pre-mutation snapshot with resolved Area sub-object;
        -- NewValue is NULL for a Deprecate.
        DECLARE @OldValueResolved NVARCHAR(MAX) =
            (SELECT
                 @Code AS Code,
                 @OldDesc AS Description,
                 JSON_QUERY((SELECT l.Id, l.Code, l.Name
                             FROM Location.Location l WHERE l.Id = @OldAreaId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))   AS Area,
                 @OldIsExcused AS IsExcused
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        UPDATE Quality.DefectCode SET
            DeprecatedAt = SYSUTCDATETIME()
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'DefectCode',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Warning',
            @Description       = @Activity,
            @OldValue          = @OldValueResolved,
            @NewValue          = NULL;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Defect code "' + @Code + N'" deprecated successfully.';
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
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'DefectCode',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;

        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
