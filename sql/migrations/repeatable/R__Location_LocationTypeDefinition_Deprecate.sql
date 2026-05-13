-- =============================================
-- Procedure:   Location.LocationTypeDefinition_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-05-13
-- Version:     1.0
--
-- Description:
--   Soft-deletes a LocationTypeDefinition by setting DeprecatedAt,
--   and cascades the soft-delete to every active child
--   LocationAttributeDefinition.
--
--   FK guard: rejects if any active Location.Location row points at
--   this definition. Real plant locations cannot be left dangling
--   on a deprecated type.
--
--   Idempotent: re-deprecating an already-deprecated row returns
--   Status=1 with Message='Already deprecated.'. Matches the
--   no-op-success pattern used by Location.Location_MoveUp at the
--   top boundary so callers don't have to special-case this state.
--
-- Parameters (input):
--   @Id BIGINT        - PK of the LocationTypeDefinition. Required.
--   @AppUserId BIGINT - User performing the action. Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success (including idempotent no-op), 0 on failure.
--
-- Dependencies:
--   Tables: Location.LocationTypeDefinition, Location.LocationAttributeDefinition,
--           Location.Location
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Error Handling:
--   - Validation / business-rule failures: @Status=0, @Message set,
--     Audit_LogFailure, RETURN. No transaction in flight.
--   - CATCH handler: rollback, @Status=0, @Message captured from
--     ERROR_MESSAGE(), Audit_LogFailure (nested try/catch), RAISERROR.
--
-- Change Log:
--   2026-05-13 - 1.0 - Initial version
-- =============================================
CREATE OR ALTER PROCEDURE Location.LocationTypeDefinition_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Location.LocationTypeDefinition_Deprecate';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LocationCount    INT;
    DECLARE @LocationCountStr NVARCHAR(20);
    DECLARE @ChildCount       INT;
    DECLARE @ChildCountStr    NVARCHAR(10);
    DECLARE @OldValue         NVARCHAR(MAX);
    DECLARE @NewValue         NVARCHAR(MAX);

    BEGIN TRY
        -- ====================
        -- Tier 1: Parameter validation
        -- ====================
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'LocationTypeDef',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Target must exist
        IF NOT EXISTS (SELECT 1 FROM Location.LocationTypeDefinition WHERE Id = @Id)
        BEGIN
            SET @Message = N'LocationTypeDefinition not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'LocationTypeDef',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Idempotent no-op: already deprecated -> Status=1
        IF EXISTS (SELECT 1 FROM Location.LocationTypeDefinition
                   WHERE Id = @Id AND DeprecatedAt IS NOT NULL)
        BEGIN
            SET @Status  = 1;
            SET @Message = N'Already deprecated.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Tier 2: Business-rule check — FK guard against active Locations
        -- ====================
        SELECT @LocationCount = COUNT(*)
        FROM Location.Location
        WHERE LocationTypeDefinitionId = @Id
          AND DeprecatedAt IS NULL;

        IF @LocationCount > 0
        BEGIN
            SET @LocationCountStr = CAST(@LocationCount AS NVARCHAR(20));
            SET @Message = N'Cannot deprecate: ' + @LocationCountStr + N' active Location(s) still use this type.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'LocationTypeDef',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Capture pre-mutation state for audit
        -- ====================
        SET @OldValue = (
            SELECT
                (SELECT Id, LocationTypeId, Code, Name, Icon, Description, DeprecatedAt
                 FROM Location.LocationTypeDefinition WHERE Id = @Id
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS Definition,
                JSON_QUERY((
                    SELECT Id, AttributeName, SortOrder
                    FROM Location.LocationAttributeDefinition
                    WHERE LocationTypeDefinitionId = @Id AND DeprecatedAt IS NULL
                    ORDER BY SortOrder
                    FOR JSON PATH
                )) AS ActiveChildren
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- ====================
        -- Mutation (atomic): deprecate parent + cascade to active children
        -- ====================
        BEGIN TRANSACTION;

        UPDATE Location.LocationTypeDefinition
        SET DeprecatedAt = SYSUTCDATETIME()
        WHERE Id = @Id;

        UPDATE Location.LocationAttributeDefinition
        SET DeprecatedAt = SYSUTCDATETIME()
        WHERE LocationTypeDefinitionId = @Id
          AND DeprecatedAt IS NULL;

        SET @ChildCount = @@ROWCOUNT;

        SET @NewValue = (
            SELECT
                (SELECT Id, DeprecatedAt
                 FROM Location.LocationTypeDefinition WHERE Id = @Id
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS Definition,
                @ChildCount AS ChildrenCascaded
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'LocationTypeDef',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Info',
            @Description       = N'LocationTypeDefinition deprecated (cascade to children).',
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @ChildCountStr = CAST(@ChildCount AS NVARCHAR(10));
        SET @Message = N'Deprecated; ' + @ChildCountStr + N' child attribute(s) cascaded.';
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
                @LogEntityTypeCode   = N'LocationTypeDef',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow; don't mask the original exception
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
