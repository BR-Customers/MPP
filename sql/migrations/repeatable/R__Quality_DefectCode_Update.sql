-- =============================================
-- Procedure:   Quality.DefectCode_Update
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.1
--
-- Description:
--   Updates an existing defect code. Cannot change Code (use
--   deprecate + create new instead). Updates Description,
--   AreaLocationId, and IsExcused.
--
-- Parameters (input):
--   @Id BIGINT - Required.
--   @Description NVARCHAR(500) - Required.
--   @AreaLocationId BIGINT - Required.
--   @IsExcused BIT - Required.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Dependencies:
--   Tables: Quality.DefectCode, Location.Location
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention (Slice 8 Downtime+Defect
--                       codes): SUBJECT . ACTION field-diff Description +
--                       resolved-FK OldValue/NewValue JSON.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.DefectCode_Update
    @Id             BIGINT,
    @Description    NVARCHAR(500),
    @AreaLocationId BIGINT,
    @IsExcused      BIT,
    @AppUserId      BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.DefectCode_Update';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id, @Description AS Description,
                @AreaLocationId AS AreaLocationId, @IsExcused AS IsExcused
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Id IS NULL OR @Description IS NULL OR LTRIM(RTRIM(@Description)) = N''
           OR @AreaLocationId IS NULL OR @IsExcused IS NULL OR @AppUserId IS NULL
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

        -- ====================
        -- Existence checks
        -- ====================
        DECLARE @Code            NVARCHAR(20);
        DECLARE @OldDesc         NVARCHAR(500);
        DECLARE @OldAreaId       BIGINT;
        DECLARE @OldIsExcused    BIT;
        DECLARE @DeprecatedAt    DATETIME2(3);
        DECLARE @RowExists       BIT = 0;

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

        -- ====================
        -- FK existence checks
        -- ====================
        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @AreaLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated AreaLocationId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Audit narrative + resolved JSON (built from PRE-mutation state)
        -- ====================
        DECLARE @NewDesc NVARCHAR(500) = LTRIM(RTRIM(@Description));

        DECLARE @OldAreaName NVARCHAR(200) =
            (SELECT Name FROM Location.Location WHERE Id = @OldAreaId);
        DECLARE @NewAreaName NVARCHAR(200) =
            (SELECT Name FROM Location.Location WHERE Id = @AreaLocationId);

        -- Compose field-diff list: "Field old->new". STUFF strips leading ", ".
        DECLARE @Arrow  NCHAR(1) = NCHAR(8594);
        DECLARE @Fields NVARCHAR(MAX) = STUFF(
            CONCAT(
                CASE WHEN ISNULL(@OldAreaId, -1) <> ISNULL(@AreaLocationId, -1)
                     THEN N', Area "' + ISNULL(@OldAreaName, N'null') + N'" ' + @Arrow + N' "' + ISNULL(@NewAreaName, N'null') + N'"'
                     ELSE N'' END,
                CASE WHEN @OldDesc <> @NewDesc
                     THEN N', Description "' + @OldDesc + N'" ' + @Arrow + N' "' + @NewDesc + N'"'
                     ELSE N'' END,
                CASE WHEN ISNULL(@OldIsExcused, 0) <> ISNULL(@IsExcused, 0)
                     THEN N', Excused ' + CASE WHEN @OldIsExcused = 1 THEN N'true' ELSE N'false' END + N' ' + @Arrow + N' ' + CASE WHEN @IsExcused = 1 THEN N'true' ELSE N'false' END
                     ELSE N'' END
            ),
            1, 2, N'');

        IF @Fields IS NULL OR @Fields = N'' SET @Fields = N'no changes';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Defect Code ' + @Code + N' ' + Audit.ufn_MidDot() + N' Updated ' + @Fields);

        -- OldValue: pre-mutation snapshot with resolved Area sub-object
        DECLARE @OldValueResolved NVARCHAR(MAX) =
            (SELECT
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
            Description    = @NewDesc,
            AreaLocationId = @AreaLocationId,
            IsExcused      = @IsExcused
        WHERE Id = @Id;

        -- NewValue: post-mutation snapshot with resolved Area sub-object
        DECLARE @NewValueResolved NVARCHAR(MAX) =
            (SELECT
                 @NewDesc AS Description,
                 JSON_QUERY((SELECT l.Id, l.Code, l.Name
                             FROM Location.Location l WHERE l.Id = @AreaLocationId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))   AS Area,
                 @IsExcused AS IsExcused
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'DefectCode',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValueResolved,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Defect code updated successfully.';
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
