-- =============================================
-- Procedure:   Location.LocationTypeDefinition_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-05-13
-- Version:     1.1
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
--   2026-05-29 - 1.1 - Audit-readability convention (Slice 7 LocationTypeEditor):
--                       SUBJECT . Deprecated (cascade: N attributes deprecated)
--                       Description; OldValue carries resolved tier FK -> {Id, Name}
--                       and the deprecated snapshot, NewValue = NULL.
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

    -- Audit narrative (convention SUBJECT . ACTION) ----------------------
    DECLARE @DefName  NVARCHAR(200);
    DECLARE @TierId   BIGINT;
    DECLARE @Subject  NVARCHAR(400);
    DECLARE @Activity NVARCHAR(500);

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
        -- Audit narrative + resolved JSON (built from PRE-mutation state)
        -- ====================
        SELECT @DefName = Name, @TierId = LocationTypeId
        FROM Location.LocationTypeDefinition WHERE Id = @Id;

        -- Active children that will cascade. Computed pre-mutation: the cascade
        -- UPDATE below deprecates exactly this set.
        SELECT @ChildCount = COUNT(*)
        FROM Location.LocationAttributeDefinition
        WHERE LocationTypeDefinitionId = @Id AND DeprecatedAt IS NULL;

        -- Subject conveys the category; tier omitted from prose per convention.
        SET @Subject = N'Location Type Definition "' + @DefName + N'"';

        -- ACTION: Deprecated (cascade: N attributes deprecated). Omit the
        -- cascade clause when no active children.
        SET @Activity = Audit.ufn_TruncateActivity(
            @Subject + N' ' + Audit.ufn_MidDot() + N' Deprecated' +
            CASE WHEN @ChildCount > 0
                 THEN N' (cascade: ' + CAST(@ChildCount AS NVARCHAR(10))
                      + N' attribute' + CASE WHEN @ChildCount = 1 THEN N'' ELSE N's' END
                      + N' deprecated)'
                 ELSE N'' END);

        -- OldValue: the snapshot being deprecated, with resolved tier FK.
        -- NewValue = NULL (deprecation has no meaningful post-state diff).
        SET @OldValue = (
            SELECT
                JSON_QUERY((SELECT lt.Id, lt.Name
                            FROM Location.LocationType lt WHERE lt.Id = @TierId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS LocationType,
                JSON_QUERY((SELECT Id, Code, Name, Icon, [Description]
                            FROM Location.LocationTypeDefinition WHERE Id = @Id
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Definition,
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

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'LocationTypeDef',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = NULL;

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
