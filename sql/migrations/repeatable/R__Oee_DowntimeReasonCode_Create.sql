-- =============================================
-- Procedure:   Oee.DowntimeReasonCode_Create
-- Version:     2.0
-- Change Log:
--   2026-08-05 - 2.0 - Scope by Parts.OperationCategory (nullable = plant-wide)
--                       instead of AreaLocationId. Audit JSON carries a Category
--                       sub-object; NULL renders "Plant-wide". ReasonType/SourceCode
--                       dimensions unchanged.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.DowntimeReasonCode_Create
    @Code                 NVARCHAR(20),
    @Description          NVARCHAR(500),
    @OperationCategoryId  BIGINT = NULL,
    @DowntimeReasonTypeId BIGINT = NULL,
    @DowntimeSourceCodeId BIGINT = NULL,
    @IsExcused            BIT    = 0,
    @AppUserId            BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeReasonCode_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Code AS Code, @Description AS Description,
                @OperationCategoryId AS OperationCategoryId,
                @DowntimeReasonTypeId AS DowntimeReasonTypeId,
                @DowntimeSourceCodeId AS DowntimeSourceCodeId,
                @IsExcused AS IsExcused
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- Required params (OperationCategoryId is OPTIONAL: NULL = plant-wide)
        IF @Code IS NULL OR LTRIM(RTRIM(@Code)) = N''
           OR @Description IS NULL OR LTRIM(RTRIM(@Description)) = N''
           OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- FK checks (category only when supplied)
        IF @OperationCategoryId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Parts.OperationCategory WHERE Id = @OperationCategoryId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated OperationCategoryId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @DowntimeReasonTypeId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonType WHERE Id = @DowntimeReasonTypeId)
        BEGIN
            SET @Message = N'Invalid DowntimeReasonTypeId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @DowntimeSourceCodeId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Oee.DowntimeSourceCode WHERE Id = @DowntimeSourceCodeId)
        BEGIN
            SET @Message = N'Invalid DowntimeSourceCodeId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode WHERE Code = LTRIM(RTRIM(@Code)))
        BEGIN
            SET @Message = N'A downtime reason code with this Code already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        BEGIN TRANSACTION;

        INSERT INTO Oee.DowntimeReasonCode
            (Code, Description, OperationCategoryId, DowntimeReasonTypeId, DowntimeSourceCodeId,
             IsExcused, CreatedAt, CreatedByUserId)
        VALUES
            (LTRIM(RTRIM(@Code)), LTRIM(RTRIM(@Description)), @OperationCategoryId,
             @DowntimeReasonTypeId, @DowntimeSourceCodeId,
             ISNULL(@IsExcused, 0), SYSUTCDATETIME(), @AppUserId);

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        DECLARE @CatName NVARCHAR(100) =
            ISNULL((SELECT Name FROM Parts.OperationCategory WHERE Id = @OperationCategoryId), N'Plant-wide');

        DECLARE @Subject NVARCHAR(600) =
            N'Downtime Code ' + LTRIM(RTRIM(@Code)) + N' ' + NCHAR(8212) + N' ' + LTRIM(RTRIM(@Description))
            + N' (' + @CatName
            + CASE WHEN ISNULL(@IsExcused, 0) = 1 THEN N', Excused' ELSE N'' END
            + N')';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Subject + N' ' + Audit.ufn_MidDot() + N' Created');

        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                drc.Code,
                drc.Description,
                JSON_QUERY((SELECT oc.Id, oc.Code, oc.Name
                            FROM Parts.OperationCategory oc WHERE oc.Id = drc.OperationCategoryId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS Category,
                JSON_QUERY((SELECT drt.Id, drt.Code, drt.Name
                            FROM Oee.DowntimeReasonType drt WHERE drt.Id = drc.DowntimeReasonTypeId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS ReasonType,
                drc.DowntimeSourceCodeId,
                drc.IsExcused
            FROM Oee.DowntimeReasonCode drc
            WHERE drc.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'DowntimeReasonCode',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = NULL,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Downtime reason code created successfully.';
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
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'DowntimeReasonCode',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
