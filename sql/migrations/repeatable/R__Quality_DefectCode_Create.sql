-- =============================================
-- Procedure:   Quality.DefectCode_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.0
--
-- Description:
--   Creates a new defect code. Code must be unique. Scoped by
--   Parts.OperationCategory (nullable = plant-wide, applies everywhere).
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--
-- Dependencies:
--   Tables: Quality.DefectCode, Parts.OperationCategory
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention (Slice 8 Downtime+Defect
--                       codes): SUBJECT . ACTION narrative Description +
--                       resolved-FK OldValue/NewValue JSON.
--   2026-08-04 - 3.0 - Scope by Parts.OperationCategory (nullable = plant-wide)
--                       instead of AreaLocationId. Audit JSON carries a Category
--                       sub-object; NULL renders as "Plant-wide".
-- =============================================
CREATE OR ALTER PROCEDURE Quality.DefectCode_Create
    @Code                NVARCHAR(20),
    @Description         NVARCHAR(500),
    @OperationCategoryId BIGINT          = NULL,
    @IsExcused           BIT             = 0,
    @AppUserId           BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Quality.DefectCode_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Code AS Code, @Description AS Description,
                @OperationCategoryId AS OperationCategoryId, @IsExcused AS IsExcused
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- Required params (OperationCategoryId is OPTIONAL: NULL = plant-wide)
        IF @Code IS NULL OR LTRIM(RTRIM(@Code)) = N''
           OR @Description IS NULL OR LTRIM(RTRIM(@Description)) = N''
           OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- FK check only when a category is supplied
        IF @OperationCategoryId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Parts.OperationCategory
                           WHERE Id = @OperationCategoryId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated OperationCategoryId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM Quality.DefectCode WHERE Code = LTRIM(RTRIM(@Code)))
        BEGIN
            SET @Message = N'A defect code with this Code already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        BEGIN TRANSACTION;

        INSERT INTO Quality.DefectCode
            (Code, Description, OperationCategoryId, IsExcused, CreatedAt)
        VALUES
            (LTRIM(RTRIM(@Code)), LTRIM(RTRIM(@Description)), @OperationCategoryId, ISNULL(@IsExcused, 0), SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        DECLARE @CatName NVARCHAR(100) =
            ISNULL((SELECT Name FROM Parts.OperationCategory WHERE Id = @OperationCategoryId), N'Plant-wide');

        DECLARE @Subject NVARCHAR(600) =
            N'Defect Code ' + LTRIM(RTRIM(@Code)) + N' ' + NCHAR(8212) + N' ' + LTRIM(RTRIM(@Description))
            + N' (' + @CatName + N')';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Subject + N' ' + Audit.ufn_MidDot() + N' Created');

        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                dc.Code,
                dc.Description,
                JSON_QUERY((SELECT oc.Id, oc.Code, oc.Name
                            FROM Parts.OperationCategory oc WHERE oc.Id = dc.OperationCategoryId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS Category,
                dc.IsExcused
            FROM Quality.DefectCode dc
            WHERE dc.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'DefectCode',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description        = @Activity,
            @OldValue          = NULL,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Defect code created successfully.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0; SET @NewId = NULL;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
