-- =============================================
-- Procedure:   Oee.DowntimeReasonCode_Update
-- Version:     2.0
-- Change Log:
--   2026-08-05 - 2.0 - Scope by Parts.OperationCategory (nullable = plant-wide).
--                       Field-diff + resolved JSON use Category, not Area.
--                       ReasonType/SourceCode dimensions unchanged.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.DowntimeReasonCode_Update
    @Id                   BIGINT,
    @Description          NVARCHAR(500),
    @OperationCategoryId  BIGINT = NULL,
    @DowntimeReasonTypeId BIGINT = NULL,
    @DowntimeSourceCodeId BIGINT = NULL,
    @IsExcused            BIT,
    @AppUserId            BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeReasonCode_Update';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id, @Description AS Description,
                @OperationCategoryId AS OperationCategoryId,
                @DowntimeReasonTypeId AS DowntimeReasonTypeId,
                @DowntimeSourceCodeId AS DowntimeSourceCodeId,
                @IsExcused AS IsExcused
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @Id IS NULL OR @Description IS NULL OR LTRIM(RTRIM(@Description)) = N''
           OR @IsExcused IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @Code            NVARCHAR(20);
        DECLARE @OldDesc         NVARCHAR(500);
        DECLARE @OldCatId        BIGINT;
        DECLARE @OldTypeId       BIGINT;
        DECLARE @OldSourceId     BIGINT;
        DECLARE @OldIsExcused    BIT;
        DECLARE @DeprecatedAt    DATETIME2(3);
        DECLARE @RowExists       BIT = 0;

        SELECT @Code         = Code,
               @OldDesc      = Description,
               @OldCatId     = OperationCategoryId,
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
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @DeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot update a deprecated downtime reason code.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @OperationCategoryId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Parts.OperationCategory WHERE Id = @OperationCategoryId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated OperationCategoryId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @DowntimeReasonTypeId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonType WHERE Id = @DowntimeReasonTypeId)
        BEGIN
            SET @Message = N'Invalid DowntimeReasonTypeId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @DowntimeSourceCodeId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Oee.DowntimeSourceCode WHERE Id = @DowntimeSourceCodeId)
        BEGIN
            SET @Message = N'Invalid DowntimeSourceCodeId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @NewDesc NVARCHAR(500) = LTRIM(RTRIM(@Description));

        DECLARE @OldCatName NVARCHAR(100) = ISNULL((SELECT Name FROM Parts.OperationCategory WHERE Id = @OldCatId), N'Plant-wide');
        DECLARE @NewCatName NVARCHAR(100) = ISNULL((SELECT Name FROM Parts.OperationCategory WHERE Id = @OperationCategoryId), N'Plant-wide');
        DECLARE @OldTypeName NVARCHAR(100) = (SELECT Name FROM Oee.DowntimeReasonType WHERE Id = @OldTypeId);
        DECLARE @NewTypeName NVARCHAR(100) = (SELECT Name FROM Oee.DowntimeReasonType WHERE Id = @DowntimeReasonTypeId);

        DECLARE @Arrow  NCHAR(1) = NCHAR(8594);
        DECLARE @Fields NVARCHAR(MAX) = STUFF(
            CONCAT(
                CASE WHEN @OldDesc <> @NewDesc
                     THEN N', Name "' + @OldDesc + N'" ' + @Arrow + N' "' + @NewDesc + N'"'
                     ELSE N'' END,
                CASE WHEN ISNULL(@OldCatId, -1) <> ISNULL(@OperationCategoryId, -1)
                     THEN N', Category "' + @OldCatName + N'" ' + @Arrow + N' "' + @NewCatName + N'"'
                     ELSE N'' END,
                CASE WHEN ISNULL(@OldTypeId, -1) <> ISNULL(@DowntimeReasonTypeId, -1)
                     THEN N', ReasonType "' + ISNULL(@OldTypeName, N'null') + N'" ' + @Arrow + N' "' + ISNULL(@NewTypeName, N'null') + N'"'
                     ELSE N'' END,
                CASE WHEN ISNULL(@OldSourceId, -1) <> ISNULL(@DowntimeSourceCodeId, -1)
                     THEN N', SourceCode ' + ISNULL(CAST(@OldSourceId AS NVARCHAR(20)), N'null') + N' ' + @Arrow + N' ' + ISNULL(CAST(@DowntimeSourceCodeId AS NVARCHAR(20)), N'null')
                     ELSE N'' END,
                CASE WHEN ISNULL(@OldIsExcused, 0) <> ISNULL(@IsExcused, 0)
                     THEN N', Excused ' + CASE WHEN @OldIsExcused = 1 THEN N'true' ELSE N'false' END + N' ' + @Arrow + N' ' + CASE WHEN @IsExcused = 1 THEN N'true' ELSE N'false' END
                     ELSE N'' END
            ),
            1, 2, N'');

        IF @Fields IS NULL OR @Fields = N'' SET @Fields = N'no changes';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Downtime Code ' + @Code + N' ' + Audit.ufn_MidDot() + N' Updated ' + @Fields);

        DECLARE @OldValueResolved NVARCHAR(MAX) =
            (SELECT
                 @OldDesc AS Description,
                 JSON_QUERY((SELECT oc.Id, oc.Code, oc.Name
                             FROM Parts.OperationCategory oc WHERE oc.Id = @OldCatId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))   AS Category,
                 JSON_QUERY((SELECT drt.Id, drt.Code, drt.Name
                             FROM Oee.DowntimeReasonType drt WHERE drt.Id = @OldTypeId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))   AS ReasonType,
                 @OldSourceId AS DowntimeSourceCodeId,
                 @OldIsExcused AS IsExcused
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        UPDATE Oee.DowntimeReasonCode SET
            Description          = @NewDesc,
            OperationCategoryId  = @OperationCategoryId,
            DowntimeReasonTypeId = @DowntimeReasonTypeId,
            DowntimeSourceCodeId = @DowntimeSourceCodeId,
            IsExcused            = @IsExcused,
            UpdatedAt            = SYSUTCDATETIME(),
            UpdatedByUserId      = @AppUserId
        WHERE Id = @Id;

        DECLARE @NewValueResolved NVARCHAR(MAX) =
            (SELECT
                 @NewDesc AS Description,
                 JSON_QUERY((SELECT oc.Id, oc.Code, oc.Name
                             FROM Parts.OperationCategory oc WHERE oc.Id = @OperationCategoryId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))   AS Category,
                 JSON_QUERY((SELECT drt.Id, drt.Code, drt.Name
                             FROM Oee.DowntimeReasonType drt WHERE drt.Id = @DowntimeReasonTypeId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))   AS ReasonType,
                 @DowntimeSourceCodeId AS DowntimeSourceCodeId,
                 @IsExcused AS IsExcused
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'DowntimeReasonCode',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValueResolved,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Downtime reason code updated successfully.';
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
                @LogEventTypeCode    = N'Updated',
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
