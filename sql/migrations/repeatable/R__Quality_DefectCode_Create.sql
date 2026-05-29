-- =============================================
-- Procedure:   Quality.DefectCode_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.1
--
-- Description:
--   Creates a new defect code. Code must be unique.
--   AreaLocationId must reference an active Location (typically
--   an Area in the ISA-95 hierarchy).
--
-- Parameters (input):
--   @Code NVARCHAR(20) - Required. Unique.
--   @Description NVARCHAR(500) - Required.
--   @AreaLocationId BIGINT - Required. Area responsible for this defect.
--   @IsExcused BIT - Defaults to 0. Affects OEE quality calc.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--
-- Dependencies:
--   Tables: Quality.DefectCode, Location.Location
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention (Slice 8 Downtime+Defect
--                       codes): SUBJECT . ACTION narrative Description +
--                       resolved-FK OldValue/NewValue JSON.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.DefectCode_Create
    @Code            NVARCHAR(20),
    @Description     NVARCHAR(500),
    @AreaLocationId  BIGINT,
    @IsExcused       BIT             = 0,
    @AppUserId       BIGINT
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
                @AreaLocationId AS AreaLocationId, @IsExcused AS IsExcused
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Business rule: unique code
        -- ====================
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

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        INSERT INTO Quality.DefectCode
            (Code, Description, AreaLocationId, IsExcused, CreatedAt)
        VALUES
            (LTRIM(RTRIM(@Code)), LTRIM(RTRIM(@Description)), @AreaLocationId, ISNULL(@IsExcused, 0), SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- ===== Audit narrative + resolved JSON =====

        DECLARE @AreaName NVARCHAR(200) =
            (SELECT Name FROM Location.Location WHERE Id = @AreaLocationId);

        DECLARE @Subject NVARCHAR(600) =
            N'Defect Code ' + LTRIM(RTRIM(@Code)) + N' ' + NCHAR(8212) + N' ' + LTRIM(RTRIM(@Description))
            + CASE WHEN @AreaName IS NOT NULL THEN N' (' + @AreaName + N')' ELSE N'' END;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Subject + N' ' + Audit.ufn_MidDot() + N' Created');

        -- NewValue: created snapshot with resolved Area sub-object
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                dc.Code,
                dc.Description,
                JSON_QUERY((SELECT l.Id, l.Code, l.Name
                            FROM Location.Location l WHERE l.Id = dc.AreaLocationId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS Area,
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
            @Description       = @Activity,
            @OldValue          = NULL,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Defect code created successfully.';
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
                @LogEntityTypeCode   = N'DefectCode',
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
