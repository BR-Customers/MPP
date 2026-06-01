-- =============================================
-- Procedure:   Oee.DowntimeReasonCode_Update
-- Author:      Blue Ridge Automation
-- Created:     2026-04-15
-- Version:     1.1
--
-- Description:
--   Updates an existing downtime reason code. Code is immutable
--   (deprecate + create new to change it). Updates Description,
--   AreaLocationId, DowntimeReasonTypeId, DowntimeSourceCodeId,
--   and IsExcused. Rejects if target row is deprecated.
--
-- Parameters (input):
--   @Id                   BIGINT        - Required.
--   @Description          NVARCHAR(500) - Required.
--   @AreaLocationId       BIGINT        - Required. Active Location.
--   @DowntimeReasonTypeId BIGINT NULL   - Optional.
--   @DowntimeSourceCodeId BIGINT NULL   - Optional.
--   @IsExcused            BIT           - Required.
--   @AppUserId            BIGINT        - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--
-- Dependencies:
--   Tables: Oee.DowntimeReasonCode, Location.Location,
--           Oee.DowntimeReasonType, Oee.DowntimeSourceCode
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-15 - 1.0 - Initial version
--   2026-05-29 - 1.1 - Audit-readability convention (Slice 8 Downtime+Defect
--                       codes): SUBJECT . ACTION field-diff Description +
--                       resolved-FK OldValue/NewValue JSON.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.DowntimeReasonCode_Update
    @Id                   BIGINT,
    @Description          NVARCHAR(500),
    @AreaLocationId       BIGINT,
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
                @AreaLocationId AS AreaLocationId,
                @DowntimeReasonTypeId AS DowntimeReasonTypeId,
                @DowntimeSourceCodeId AS DowntimeSourceCodeId,
                @IsExcused AS IsExcused
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
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
        DECLARE @OldTypeId       BIGINT;
        DECLARE @OldSourceId     BIGINT;
        DECLARE @OldIsExcused    BIT;
        DECLARE @DeprecatedAt    DATETIME2(3);
        DECLARE @RowExists       BIT = 0;

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

        -- ====================
        -- FK existence checks
        -- ====================
        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @AreaLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated AreaLocationId.';
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

        -- ====================
        -- Audit narrative + resolved JSON (built from PRE-mutation state)
        -- ====================
        DECLARE @NewDesc NVARCHAR(500) = LTRIM(RTRIM(@Description));

        -- Resolve old/new Area + ReasonType names for the field-diff prose
        DECLARE @OldAreaName NVARCHAR(200) =
            (SELECT Name FROM Location.Location WHERE Id = @OldAreaId);
        DECLARE @NewAreaName NVARCHAR(200) =
            (SELECT Name FROM Location.Location WHERE Id = @AreaLocationId);
        DECLARE @OldTypeName NVARCHAR(100) =
            (SELECT Name FROM Oee.DowntimeReasonType WHERE Id = @OldTypeId);
        DECLARE @NewTypeName NVARCHAR(100) =
            (SELECT Name FROM Oee.DowntimeReasonType WHERE Id = @DowntimeReasonTypeId);

        -- Compose field-diff list: "Field old->new" (strings quoted, NULL=null,
        -- booleans as words). STUFF strips the leading ", ".
        DECLARE @Arrow  NCHAR(1) = NCHAR(8594);
        DECLARE @Fields NVARCHAR(MAX) = STUFF(
            CONCAT(
                CASE WHEN @OldDesc <> @NewDesc
                     THEN N', Name "' + @OldDesc + N'" ' + @Arrow + N' "' + @NewDesc + N'"'
                     ELSE N'' END,
                CASE WHEN ISNULL(@OldAreaId, -1) <> ISNULL(@AreaLocationId, -1)
                     THEN N', Area "' + ISNULL(@OldAreaName, N'null') + N'" ' + @Arrow + N' "' + ISNULL(@NewAreaName, N'null') + N'"'
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

        -- OldValue: pre-mutation snapshot with resolved FK sub-objects
        DECLARE @OldValueResolved NVARCHAR(MAX) =
            (SELECT
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
            Description          = @NewDesc,
            AreaLocationId       = @AreaLocationId,
            DowntimeReasonTypeId = @DowntimeReasonTypeId,
            DowntimeSourceCodeId = @DowntimeSourceCodeId,
            IsExcused            = @IsExcused,
            UpdatedAt            = SYSUTCDATETIME(),
            UpdatedByUserId      = @AppUserId
        WHERE Id = @Id;

        -- NewValue: post-mutation snapshot with resolved FK sub-objects
        DECLARE @NewValueResolved NVARCHAR(MAX) =
            (SELECT
                 @NewDesc AS Description,
                 JSON_QUERY((SELECT l.Id, l.Code, l.Name
                             FROM Location.Location l WHERE l.Id = @AreaLocationId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))   AS Area,
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
