-- =============================================
-- Procedure:   Oee.DowntimeReasonCode_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-04-15
-- Version:     1.1
--
-- Description:
--   Soft-deletes a downtime reason code by setting DeprecatedAt.
--   Rejects if already deprecated or if referenced by any active
--   Oee.DowntimeEvent row (checked only if that table exists).
--
-- Parameters (input):
--   @Id BIGINT        - Required.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--
-- Dependencies:
--   Tables: Oee.DowntimeReasonCode, Oee.DowntimeEvent (conditional)
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-15 - 1.0 - Initial version
--   2026-05-29 - 1.1 - Audit-readability convention (Slice 8 Downtime+Defect
--                       codes): SUBJECT . ACTION narrative Description +
--                       resolved-FK OldValue/NewValue JSON.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.DowntimeReasonCode_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeReasonCode_Deprecate';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
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
        DECLARE @OldTypeId    BIGINT;
        DECLARE @OldSourceId  BIGINT;
        DECLARE @OldIsExcused BIT;
        DECLARE @DeprecatedAt DATETIME2(3);
        DECLARE @RowExists    BIT = 0;

        SELECT @Code         = Code,
               @OldDesc      = Description,
               @OldAreaId    = AreaLocationId,
               @OldTypeId    = DowntimeReasonTypeId,
               @OldSourceId  = DowntimeSourceCodeId,
               @OldIsExcused = IsExcused,
               @DeprecatedAt = DeprecatedAt,
               @RowExists    = 1
        FROM Oee.DowntimeReasonCode WHERE Id = @Id;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'Downtime reason code not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @DeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Downtime reason code is already deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Dependency check: DowntimeEvent (guarded — table may not yet exist)
        -- ====================
        IF EXISTS (
            SELECT 1 FROM sys.tables t
            INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE s.name = N'Oee' AND t.name = N'DowntimeEvent'
        )
        BEGIN
            DECLARE @DepCount INT = 0;
            DECLARE @Sql NVARCHAR(MAX) =
                N'SELECT @C = COUNT(*) FROM Oee.DowntimeEvent WHERE DowntimeReasonCodeId = @Id;';
            EXEC sp_executesql @Sql,
                N'@Id BIGINT, @C INT OUTPUT',
                @Id = @Id, @C = @DepCount OUTPUT;

            IF @DepCount > 0
            BEGIN
                SET @Message = N'Cannot deprecate: referenced by ' + CAST(@DepCount AS NVARCHAR(20))
                             + N' active DowntimeEvent row(s).';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                    @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END
        END

        -- ====================
        -- Audit narrative + resolved JSON (built from PRE-mutation state)
        -- ====================
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Downtime Code ' + @Code + N' ' + Audit.ufn_MidDot() + N' Deprecated');

        -- OldValue: pre-mutation snapshot with resolved FK sub-objects;
        -- NewValue is NULL for a Deprecate.
        DECLARE @OldValueResolved NVARCHAR(MAX) =
            (SELECT
                 @Code AS Code,
                 @OldDesc AS Description,
                 JSON_QUERY((SELECT l.Id, l.Code, l.Name
                             FROM Location.Location l WHERE l.Id = @OldAreaId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))   AS Area,
                 JSON_QUERY((SELECT drt.Id, drt.Code, drt.Name
                             FROM Oee.DowntimeReasonType drt WHERE drt.Id = @OldTypeId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))   AS ReasonType,
                 @OldSourceId AS DowntimeSourceCodeId,
                 @OldIsExcused AS IsExcused
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        UPDATE Oee.DowntimeReasonCode SET
            DeprecatedAt    = SYSUTCDATETIME(),
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'DowntimeReasonCode',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Warning',
            @Description       = @Activity,
            @OldValue          = @OldValueResolved,
            @NewValue          = NULL;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Downtime reason code "' + @Code + N'" deprecated successfully.';
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
                @LogEntityTypeCode   = N'DowntimeReasonCode',
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
