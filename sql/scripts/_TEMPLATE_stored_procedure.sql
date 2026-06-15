-- ============================================================
-- STORED PROCEDURE TEMPLATE — MPP MES
-- ============================================================
--
-- Copy this file as a starting point for any new stored procedure.
-- The full template with detailed commentary is in:
--   MPP_MES_PHASED_PLAN_CONFIG_TOOL.md > "Stored Procedure Template and Conventions"
--
-- Key rules:
--   - NO OUTPUT parameters anywhere (FDS-11-011 / Ignition JDBC). The driver reads
--     an OUTPUT param as the first result set and silently drops later SELECTs.
--   - Mutation procs declare @Status (BIT), @Message (NVARCHAR(500)) and (Create/Add)
--     @NewId (BIGINT) as LOCAL variables, init'd to failure defaults. EVERY exit path
--     (each validation/business-rule RETURN, the success path, and the CATCH) ends with
--     a single status-row: SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId];
--     Drop @NewId from the SELECT for Update/Deprecate/Publish procs.
--   - Read procs take NO @Status/@Message and emit NO status row -- they SELECT their
--     rowset directly; an empty result set = not found.
--   - CATCH uses RAISERROR(@ErrMsg, @ErrSev, @ErrState) (NOT THROW), after emitting the
--     status-row SELECT on mutation procs.
--   - Three-tier error hierarchy: parameter validation, business rule, unexpected exception
--   - Success audit (Audit_LogConfigChange) INSIDE the transaction
--   - Failure audit (Audit_LogFailure) OUTSIDE the rolled-back transaction
--   - @AppUserId required on every mutating proc
--   - Code-string pattern for audit calls (N'Location', N'Created', N'Info')
--
-- Naming: Schema.Entity_Verb  (e.g., Location.Location_Create, Parts.Item_Update)
-- File:   R__Schema_Entity_Verb.sql  (e.g., R__Location_Location_Create.sql)
--
-- ============================================================


-- =============================================
-- FULL EXAMPLE: Location.Location_Create
-- =============================================

-- =============================================
-- Procedure:   Location.Location_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     1.0
--
-- Description:
--   Creates a new Location row under the specified parent. Validates
--   LocationTypeDefinition and parent existence. Enforces Code uniqueness.
--   Logs success to Audit.ConfigLog or failure to Audit.FailureLog.
--
-- Parameters (input):
--   @LocationTypeDefinitionId INT      - FK to LocationTypeDefinition. Required.
--   @ParentLocationId INT NULL         - FK to Location. NULL only for the Enterprise root.
--   @Name NVARCHAR(200)                - Display name. Required.
--   @Code NVARCHAR(50)                 - Short identifier. Required. Must be unique among active rows.
--   @Description NVARCHAR(500) NULL    - Optional description.
--   @AppUserId INT                     - User performing the action. Required for audit attribution.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--   (No OUTPUT params -- values are returned via SELECT per FDS-11-011.)
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationTypeDefinition
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Error Handling:
--   - Validation/business-rule failures: @Status=0, @Message set, Audit_LogFailure,
--     status-row SELECT, RETURN.
--   - CATCH handler: rollback, @Status=0, @Message captured, Audit_LogFailure,
--     status-row SELECT, RAISERROR.
--
-- Audit narrative:
--   The deployed v2.x of this proc (R__Location_Location_Create.sql) emits a
--   human-readable Audit.ConfigLog.Description and resolved-FK OldValue/NewValue
--   JSON. See sql_best_practices_mes.md > Audit Log Description Convention. This
--   template keeps the example minimal -- the focus here is the OUTPUT contract +
--   error mechanics.
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version
--   2026-06-09 - 2.0 - Reconciled to FDS-11-011 status-row output (no OUTPUT params);
--                       RAISERROR not THROW; added read-proc note.
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_Create
    @LocationTypeDefinitionId BIGINT,
    @ParentLocationId          BIGINT            = NULL,
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location', @EntityId = NULL,
                @LogEventTypeCode = N'Created', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @ParentLocationId IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM Location.Location WHERE Id = @ParentLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated ParentLocationId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location', @EntityId = NULL,
                @LogEventTypeCode = N'Created', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location', @EntityId = NULL,
                @LogEventTypeCode = N'Created', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        INSERT INTO Location.Location
            (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, CreatedAt)
        VALUES
            (@LocationTypeDefinitionId, @ParentLocationId, @Name, @Code, @Description, SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- Success audit INSIDE the transaction — rolls back atomically with the data
        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Location',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = N'Location created.',
            @OldValue          = NULL,
            @NewValue          = @Params;

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
        -- Wrap in nested TRY/CATCH so a log-write failure doesn't mask the real error
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
            -- Swallow; we're already in a bad state and shouldn't mask the original exception
        END CATCH

        -- Emit the status row, then re-raise so Ignition logs it as a critical exception
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO


-- =============================================
-- READ PROCS (no status row)
-- =============================================
-- Read/List/Get procs take NO @Status / @Message params and emit NO status row.
-- They simply SELECT their rowset; an empty result set means "not found" (do not
-- invent a 404 status row). One result set per proc. Example:
--
--   CREATE OR ALTER PROCEDURE Location.Location_Get
--       @Id BIGINT
--   AS
--   BEGIN
--       SET NOCOUNT ON;
--       SELECT Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description
--       FROM Location.Location
--       WHERE Id = @Id AND DeprecatedAt IS NULL;
--   END;
--   GO


-- =============================================
-- BLANK SKELETON: Copy and fill in
-- =============================================
-- This skeleton is the Update-shaped variant (only @Status / @Message). For a
-- Create/Add proc, declare @NewId BIGINT = NULL too and add ", @NewId AS NewId" to
-- every status-row SELECT below.

/*
-- =============================================
-- Procedure:   [Schema].[Entity_Verb]
-- Author:      [Your Name]
-- Created:     YYYY-MM-DD
-- Version:     1.0
--
-- Description:
--   [What this proc does and why]
--
-- Parameters (input):
--   [List each param with type and purpose]
--   @AppUserId INT - User performing the action. Required for audit attribution.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR) [, NewId (BIGINT) for Create/Add].
--   Status=1 on success, 0 on failure. (No OUTPUT params -- per FDS-11-011.)
--
-- Dependencies:
--   Tables: [list]
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Error Handling:
--   - Validation/business-rule failures: @Status=0, @Message set, Audit_LogFailure,
--     status-row SELECT, RETURN.
--   - CATCH handler: rollback, @Status=0, @Message captured, Audit_LogFailure,
--     status-row SELECT, RAISERROR.
--
-- Change Log:
--   YYYY-MM-DD - 1.0 - Initial version
-- =============================================
CREATE OR ALTER PROCEDURE [Schema].[Entity_Verb]
    -- Input params (no OUTPUT params -- per FDS-11-011)
    @AppUserId      BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Result variables (returned via SELECT instead of OUTPUT)
    -- For Create/Add procs also: DECLARE @NewId BIGINT = NULL;
    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'[Schema].[Entity_Verb]';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT -- list input params here
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        -- IF ... BEGIN
        --     SET @Message = ...; EXEC Audit.Audit_LogFailure ...;
        --     SELECT @Status AS Status, @Message AS Message;  -- [, @NewId AS NewId] for Create/Add
        --     RETURN;
        -- END

        -- ====================
        -- Business rule checks
        -- ====================
        -- IF ... BEGIN
        --     SET @Message = ...; EXEC Audit.Audit_LogFailure ...;
        --     SELECT @Status AS Status, @Message AS Message;  -- [, @NewId AS NewId] for Create/Add
        --     RETURN;
        -- END

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        -- Your INSERT / UPDATE / DELETE here

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'[EntityType]',
            @EntityId          = NULL,  -- or @NewId
            @LogEventTypeCode  = N'Created',  -- or Updated, Deprecated
            @LogSeverityCode   = N'Info',
            @Description       = N'[description]',
            @OldValue          = NULL,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'[Success message].';
        SELECT @Status AS Status, @Message AS Message;  -- [, @NewId AS NewId] for Create/Add
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
                @LogEntityTypeCode   = N'[EntityType]',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow
        END CATCH

        SELECT @Status AS Status, @Message AS Message;  -- [, @NewId AS NewId] for Create/Add
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
*/
