-- =============================================
-- Procedure:   Location.Location_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     2.1
--
-- Description:
--   Creates a new Location row under the specified parent. Validates
--   LocationTypeDefinition and parent existence. Enforces Code uniqueness
--   among active (non-deprecated) rows. Auto-assigns SortOrder as next
--   sequential value among active siblings with same ParentLocationId.
--   Logs success to Audit.ConfigLog or failure to Audit.FailureLog.
--
-- Parameters (input):
--   @LocationTypeDefinitionId BIGINT      - FK to LocationTypeDefinition. Required.
--   @ParentLocationId BIGINT NULL         - FK to Location. NULL only for the Enterprise root.
--   @Name NVARCHAR(200)                   - Display name. Required.
--   @Code NVARCHAR(50)                    - Short identifier. Required. Must be unique among active rows.
--   @Description NVARCHAR(500) NULL       - Optional description.
--   @AppUserId BIGINT                     - User performing the action. Required for audit attribution.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationTypeDefinition
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Error Handling:
--   - Validation/business-rule failures: @Status=0, @Message set, Audit_LogFailure, RETURN.
--   - CATCH handler: rollback, @Status=0, @Message captured, Audit_LogFailure, RAISERROR.
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention (Slice 6 Plant Hierarchy):
--                       human-readable Description narrative + resolved-FK
--                       OldValue/NewValue JSON (Parent {Id,Code,Name},
--                       LocationTypeDefinition {Id,Name}).
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_Create
    @LocationTypeDefinitionId  BIGINT,
    @ParentLocationId          BIGINT         = NULL,
    @Name                      NVARCHAR(200),
    @Code                      NVARCHAR(50),
    @Description               NVARCHAR(500)  = NULL,
    @AppUserId                 BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Result variables (returned via SELECT instead of OUTPUT)
    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    -- Capture input for failure-log snapshots
    DECLARE @ProcName NVARCHAR(200) = N'Location.Location_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @LocationTypeDefinitionId AS LocationTypeDefinitionId,
                @ParentLocationId         AS ParentLocationId,
                @Name                     AS Name,
                @Code                     AS Code,
                @Description              AS Description
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @LocationTypeDefinitionId IS NULL OR @Name IS NULL OR @Code IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.LocationTypeDefinition
                       WHERE Id = @LocationTypeDefinitionId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated LocationTypeDefinitionId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @ParentLocationId IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM Location.Location WHERE Id = @ParentLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated ParentLocationId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Business rule checks
        -- ====================
        IF EXISTS (SELECT 1 FROM Location.Location WHERE Code = @Code AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'A location with this Code already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Auto-assign SortOrder: next sequential value among active siblings
        -- ====================
        DECLARE @NextSortOrder INT;

        IF @ParentLocationId IS NULL
        BEGIN
            SELECT @NextSortOrder = ISNULL(MAX(SortOrder), 0) + 1
            FROM Location.Location
            WHERE ParentLocationId IS NULL AND DeprecatedAt IS NULL;
        END
        ELSE
        BEGIN
            SELECT @NextSortOrder = ISNULL(MAX(SortOrder), 0) + 1
            FROM Location.Location
            WHERE ParentLocationId = @ParentLocationId AND DeprecatedAt IS NULL;
        END

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        INSERT INTO Location.Location
            (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, CreatedAt)
        VALUES
            (@LocationTypeDefinitionId, @ParentLocationId, @Name, @Code, @Description, @NextSortOrder, SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- ===== Audit narrative + resolved JSON =====

        -- Resolve subject names (tier-def + optional parent) for the narrative
        DECLARE @TierDefName NVARCHAR(100);
        SELECT @TierDefName = Name
        FROM Location.LocationTypeDefinition
        WHERE Id = @LocationTypeDefinitionId;

        DECLARE @ParentCode NVARCHAR(50), @ParentName NVARCHAR(200);
        IF @ParentLocationId IS NOT NULL
            SELECT @ParentCode = Code, @ParentName = Name
            FROM Location.Location
            WHERE Id = @ParentLocationId;

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            N'Location ' + @Code +
            N' ' + NCHAR(8212) + N' ' + @Name +
            N' (' + ISNULL(@TierDefName, N'?') + N')' +
            N' ' + Audit.ufn_MidDot() + N' Created' +
            CASE WHEN @ParentLocationId IS NOT NULL
                 THEN N' under ' + @ParentCode + N' ' + NCHAR(8212) + N' ' + @ParentName
                 ELSE N'' END;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- Resolved-FK NewValue snapshot (Parent + LocationTypeDefinition sub-objects)
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                l.Id,
                l.Code,
                l.Name,
                l.Description,
                l.SortOrder,
                JSON_QUERY((SELECT p.Id, p.Code, p.Name
                            FROM Location.Location p WHERE p.Id = l.ParentLocationId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                  AS Parent,
                JSON_QUERY((SELECT ltd.Id, ltd.Name
                            FROM Location.LocationTypeDefinition ltd WHERE ltd.Id = l.LocationTypeDefinitionId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                  AS LocationTypeDefinition
            FROM Location.Location l
            WHERE l.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- Success audit INSIDE the transaction — rolls back atomically with the data
        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Location',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = NULL,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Location created successfully.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        -- Capture error details BEFORE the nested TRY/CATCH clears the error context
        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId   = NULL;

        -- Failure log OUTSIDE the rolled-back transaction
        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow; don't mask the original exception
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
