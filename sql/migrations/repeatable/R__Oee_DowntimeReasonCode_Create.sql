-- =============================================
-- Procedure:   Oee.DowntimeReasonCode_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-15
-- Version:     1.1
--
-- Description:
--   Creates a new downtime reason code. Code must be globally
--   unique (never reused, even among deprecated rows).
--   AreaLocationId is required and must reference an active Location.
--   DowntimeReasonTypeId and DowntimeSourceCodeId are optional
--   (see migration 0009: CSV may have missing values; UI flags
--   for engineering backfill).
--
-- Parameters (input):
--   @Code                 NVARCHAR(20)  - Required. Unique.
--   @Description          NVARCHAR(500) - Required.
--   @AreaLocationId       BIGINT        - Required. Active Location.
--   @DowntimeReasonTypeId BIGINT NULL   - Optional FK → Oee.DowntimeReasonType.
--   @DowntimeSourceCodeId BIGINT NULL   - Optional FK → Oee.DowntimeSourceCode.
--   @IsExcused            BIT           - Defaults to 0.
--   @AppUserId            BIGINT        - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--
-- Dependencies:
--   Tables: Oee.DowntimeReasonCode, Location.Location,
--           Oee.DowntimeReasonType, Oee.DowntimeSourceCode
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-15 - 1.0 - Initial version
--   2026-05-29 - 1.1 - Audit-readability convention (Slice 8 Downtime+Defect
--                       codes): SUBJECT . ACTION narrative Description +
--                       resolved-FK OldValue/NewValue JSON.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.DowntimeReasonCode_Create
    @Code                 NVARCHAR(20),
    @Description          NVARCHAR(500),
    @AreaLocationId       BIGINT,
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
                @AreaLocationId AS AreaLocationId,
                @DowntimeReasonTypeId AS DowntimeReasonTypeId,
                @DowntimeSourceCodeId AS DowntimeSourceCodeId,
                @IsExcused AS IsExcused
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Code IS NULL OR LTRIM(RTRIM(@Code)) = N''
           OR @Description IS NULL OR LTRIM(RTRIM(@Description)) = N''
           OR @AreaLocationId IS NULL OR @AppUserId IS NULL
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

        -- ====================
        -- FK existence checks
        -- ====================
        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @AreaLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated AreaLocationId.';
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

        -- ====================
        -- Business rule: unique code (global, incl. deprecated)
        -- ====================
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

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        INSERT INTO Oee.DowntimeReasonCode
            (Code, Description, AreaLocationId, DowntimeReasonTypeId, DowntimeSourceCodeId,
             IsExcused, CreatedAt, CreatedByUserId)
        VALUES
            (LTRIM(RTRIM(@Code)), LTRIM(RTRIM(@Description)), @AreaLocationId,
             @DowntimeReasonTypeId, @DowntimeSourceCodeId,
             ISNULL(@IsExcused, 0), SYSUTCDATETIME(), @AppUserId);

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- ===== Audit narrative + resolved JSON =====

        -- Resolve the Area name for the subject parenthetical
        DECLARE @AreaName NVARCHAR(200) =
            (SELECT Name FROM Location.Location WHERE Id = @AreaLocationId);

        DECLARE @Subject NVARCHAR(600) =
            N'Downtime Code ' + LTRIM(RTRIM(@Code)) + N' ' + NCHAR(8212) + N' ' + LTRIM(RTRIM(@Description))
            + CASE WHEN @AreaName IS NOT NULL
                   THEN N' (' + @AreaName
                        + CASE WHEN ISNULL(@IsExcused, 0) = 1 THEN N', Excused' ELSE N'' END
                        + N')'
                   ELSE N'' END;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Subject + N' ' + Audit.ufn_MidDot() + N' Created');

        -- NewValue: created snapshot with resolved FK sub-objects
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                drc.Code,
                drc.Description,
                JSON_QUERY((SELECT l.Id, l.Code, l.Name
                            FROM Location.Location l WHERE l.Id = drc.AreaLocationId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS Area,
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
