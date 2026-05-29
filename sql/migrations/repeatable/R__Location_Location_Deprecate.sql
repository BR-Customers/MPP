-- =============================================
-- Procedure:   Location.Location_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     2.1
--
-- Description:
--   Soft-deletes a Location by setting DeprecatedAt. Validates that the
--   target exists, is not already deprecated, and has no active child
--   locations. After deprecating, compacts sibling SortOrder gaps using
--   ROW_NUMBER() to maintain contiguous ordering.
--
-- Parameters (input):
--   @Id BIGINT        - PK of the Location to deprecate. Required.
--   @AppUserId BIGINT - User performing the action. Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Dependencies:
--   Tables: Location.Location
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
--                       OldValue/NewValue JSON. New = NULL on deprecate.
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Result variables (returned via SELECT instead of OUTPUT)
    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    -- Capture input for failure-log snapshots
    DECLARE @ProcName NVARCHAR(200) = N'Location.Location_Deprecate';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Target must exist
        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @Id)
        BEGIN
            SET @Message = N'Location not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Target must not already be deprecated
        IF EXISTS (SELECT 1 FROM Location.Location WHERE Id = @Id AND DeprecatedAt IS NOT NULL)
        BEGIN
            SET @Message = N'Location is already deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Business rule checks
        -- ====================

        -- Cannot deprecate if active child locations exist
        IF EXISTS (SELECT 1 FROM Location.Location
                   WHERE ParentLocationId = @Id AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Cannot deprecate: active child locations exist.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Deprecated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- TODO: check Lots.Lot.CurrentLocationId when Lots schema exists

        -- ====================
        -- Capture old values for audit (BEFORE the mutation)
        -- ====================
        DECLARE @ParentId BIGINT, @LocCode NVARCHAR(50), @LocName NVARCHAR(200);
        SELECT @ParentId = ParentLocationId,
               @LocCode  = Code,
               @LocName  = Name
        FROM Location.Location
        WHERE Id = @Id;

        -- Resolved-FK OldValue snapshot (pre-deprecate state)
        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT
                l.Name,
                l.Code,
                l.Description,
                l.SortOrder,
                JSON_QUERY((SELECT p.Id, p.Code, p.Name
                            FROM Location.Location p WHERE p.Id = l.ParentLocationId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                  AS Parent,
                JSON_QUERY((SELECT ltd.Id, ltd.Name
                            FROM Location.LocationTypeDefinition ltd WHERE ltd.Id = l.LocationTypeDefinitionId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                  AS LocationTypeDefinition
            FROM Location.Location l
            WHERE l.Id = @Id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            N'Location ' + @LocCode + N' ' + NCHAR(8212) + N' ' + @LocName +
            N' ' + Audit.ufn_MidDot() + N' Deprecated';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        UPDATE Location.Location
        SET DeprecatedAt = SYSUTCDATETIME()
        WHERE Id = @Id;

        -- Compact sibling SortOrder gaps using ROW_NUMBER()
        -- Handle NULL parent case for root-level siblings
        IF @ParentId IS NULL
        BEGIN
            ;WITH Renumbered AS (
                SELECT Id, ROW_NUMBER() OVER (ORDER BY SortOrder) AS NewSort
                FROM Location.Location
                WHERE ParentLocationId IS NULL
                  AND DeprecatedAt IS NULL
            )
            UPDATE loc SET loc.SortOrder = r.NewSort
            FROM Location.Location loc
            INNER JOIN Renumbered r ON r.Id = loc.Id;
        END
        ELSE
        BEGIN
            ;WITH Renumbered AS (
                SELECT Id, ROW_NUMBER() OVER (ORDER BY SortOrder) AS NewSort
                FROM Location.Location
                WHERE ParentLocationId = @ParentId
                  AND DeprecatedAt IS NULL
            )
            UPDATE loc SET loc.SortOrder = r.NewSort
            FROM Location.Location loc
            INNER JOIN Renumbered r ON r.Id = loc.Id;
        END

        -- Success audit INSIDE the transaction.
        -- NewValue is NULL on deprecate per audit-readability convention
        -- (the entity ceases to be active; Old holds the final snapshot).
        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Location',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = NULL;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Location deprecated successfully.';
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

        -- Failure log OUTSIDE the rolled-back transaction
        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
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
