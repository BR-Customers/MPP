-- =============================================
-- Procedure:   Quality.DefectCode_Update
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.0
--
-- Description:
--   Updates an existing defect code. Cannot change Code (use
--   deprecate + create new instead). Updates Description,
--   OperationCategoryId (nullable = plant-wide), and IsExcused.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--
-- Dependencies:
--   Tables: Quality.DefectCode, Parts.OperationCategory
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention (Slice 8 Downtime+Defect
--                       codes): SUBJECT . ACTION field-diff Description +
--                       resolved-FK OldValue/NewValue JSON.
--   2026-08-04 - 3.0 - Scope by Parts.OperationCategory (nullable = plant-wide).
--                       Field-diff + resolved JSON use Category, not Area.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.DefectCode_Update
    @Id                  BIGINT,
    @Description         NVARCHAR(500),
    @OperationCategoryId BIGINT          = NULL,
    @IsExcused           BIT,
    @AppUserId           BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.DefectCode_Update';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id, @Description AS Description,
                @OperationCategoryId AS OperationCategoryId, @IsExcused AS IsExcused
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @Id IS NULL OR @Description IS NULL OR LTRIM(RTRIM(@Description)) = N''
           OR @IsExcused IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @Code         NVARCHAR(20);
        DECLARE @OldDesc      NVARCHAR(500);
        DECLARE @OldCatId     BIGINT;
        DECLARE @OldIsExcused BIT;
        DECLARE @DeprecatedAt DATETIME2(3);
        DECLARE @RowExists    BIT = 0;

        SELECT @Code = Code, @OldDesc = Description, @OldCatId = OperationCategoryId,
               @OldIsExcused = IsExcused, @DeprecatedAt = DeprecatedAt, @RowExists = 1
        FROM Quality.DefectCode WHERE Id = @Id;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'Defect code not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @DeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot update a deprecated defect code.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @OperationCategoryId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Parts.OperationCategory
                           WHERE Id = @OperationCategoryId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated OperationCategoryId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @NewDesc NVARCHAR(500) = LTRIM(RTRIM(@Description));
        DECLARE @OldCatName NVARCHAR(100) = ISNULL((SELECT Name FROM Parts.OperationCategory WHERE Id = @OldCatId), N'Plant-wide');
        DECLARE @NewCatName NVARCHAR(100) = ISNULL((SELECT Name FROM Parts.OperationCategory WHERE Id = @OperationCategoryId), N'Plant-wide');

        DECLARE @Arrow NCHAR(1) = NCHAR(8594);
        DECLARE @Fields NVARCHAR(MAX) = STUFF(
            CONCAT(
                CASE WHEN ISNULL(@OldCatId, -1) <> ISNULL(@OperationCategoryId, -1)
                     THEN N', Category "' + @OldCatName + N'" ' + @Arrow + N' "' + @NewCatName + N'"'
                     ELSE N'' END,
                CASE WHEN @OldDesc <> @NewDesc
                     THEN N', Description "' + @OldDesc + N'" ' + @Arrow + N' "' + @NewDesc + N'"'
                     ELSE N'' END,
                CASE WHEN ISNULL(@OldIsExcused, 0) <> ISNULL(@IsExcused, 0)
                     THEN N', Excused ' + CASE WHEN @OldIsExcused = 1 THEN N'true' ELSE N'false' END + N' ' + @Arrow + N' ' + CASE WHEN @IsExcused = 1 THEN N'true' ELSE N'false' END
                     ELSE N'' END
            ), 1, 2, N'');
        IF @Fields IS NULL OR @Fields = N'' SET @Fields = N'no changes';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Defect Code ' + @Code + N' ' + Audit.ufn_MidDot() + N' Updated ' + @Fields);

        DECLARE @OldValueResolved NVARCHAR(MAX) =
            (SELECT @OldDesc AS Description,
                 JSON_QUERY((SELECT oc.Id, oc.Code, oc.Name
                             FROM Parts.OperationCategory oc WHERE oc.Id = @OldCatId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))   AS Category,
                 @OldIsExcused AS IsExcused
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        UPDATE Quality.DefectCode SET
            Description         = @NewDesc,
            OperationCategoryId = @OperationCategoryId,
            IsExcused           = @IsExcused
        WHERE Id = @Id;

        DECLARE @NewValueResolved NVARCHAR(MAX) =
            (SELECT @NewDesc AS Description,
                 JSON_QUERY((SELECT oc.Id, oc.Code, oc.Name
                             FROM Parts.OperationCategory oc WHERE oc.Id = @OperationCategoryId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))   AS Category,
                 @IsExcused AS IsExcused
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'DefectCode',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description        = @Activity,
            @OldValue          = @OldValueResolved,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Defect code updated successfully.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
