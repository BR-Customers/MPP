-- =============================================
-- Procedure:   Location.Location_Update
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     2.0
--
-- Description:
--   Updates mutable fields on an existing Location: Name, Code, Description.
--   Does NOT change SortOrder, ParentLocationId, or LocationTypeDefinitionId
--   (those are immutable after creation, per FDS-02-002a).
--
--   ParentLocationId immutability is a track-and-trace requirement, not a
--   convenience. Every event-table row (LotMovement, ConsumptionEvent,
--   RejectEvent, DowntimeEvent, HoldEvent, OperationLog) records the
--   LocationId active at event time and resolves the tier hierarchy
--   (Cell -> WorkCenter -> Area) by joining to the live Location row.
--   Reparenting would silently rewrite every historical Honda-genealogy
--   and area-aggregation report that walks that hierarchy. The standard
--   workaround for physical equipment relocations is Deprecate + Create
--   New under the new parent -- historical events stay bound to the old
--   Id and resolve correctly; live work uses the new Id. See FDS-02-002a.
--
--   SortOrder is mutated by Location.Location_MoveUp / _MoveDown only,
--   and only within the same ParentLocationId.
--
--   Captures old/new values as JSON for audit diff. Validates Code
--   uniqueness if changed.
--
-- Parameters (input):
--   @Id BIGINT                        - PK of the Location to update. Required.
--   @Name NVARCHAR(200)               - New display name. Required.
--   @Code NVARCHAR(50)                - New short identifier. Required. Must be unique among active rows.
--   @Description NVARCHAR(500) NULL   - New description (NULL to clear).
--   @AppUserId BIGINT                 - User performing the action. Required for audit.
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
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_Update
    @Id          BIGINT,
    @Name        NVARCHAR(200),
    @Code        NVARCHAR(50),
    @Description NVARCHAR(500)  = NULL,
    @AppUserId   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Result variables (returned via SELECT instead of OUTPUT)
    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    -- Capture input for failure-log snapshots
    DECLARE @ProcName NVARCHAR(200) = N'Location.Location_Update';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id          AS Id,
                @Name        AS Name,
                @Code        AS Code,
                @Description AS Description
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Id IS NULL OR @Name IS NULL OR @Code IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Target must exist and not be deprecated
        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @Id AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Location not found or is deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Business rule checks
        -- ====================

        -- Code uniqueness: reject if another active location has the same Code
        IF EXISTS (SELECT 1 FROM Location.Location
                   WHERE Code = @Code AND DeprecatedAt IS NULL AND Id <> @Id)
        BEGIN
            SET @Message = N'A location with this Code already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Capture old values for audit diff
        -- ====================
        DECLARE @OldValue NVARCHAR(MAX);
        SELECT @OldValue =
            (SELECT Name,
                    Code,
                    Description
             FROM Location.Location
             WHERE Id = @Id
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        DECLARE @NewValue NVARCHAR(MAX) =
            (SELECT @Name        AS Name,
                    @Code        AS Code,
                    @Description AS Description
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        UPDATE Location.Location
        SET Name        = @Name,
            Code        = @Code,
            Description = @Description
        WHERE Id = @Id;

        -- Success audit INSIDE the transaction
        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Location',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = N'Location updated.',
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Location updated successfully.';
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
                @LogEventTypeCode    = N'Updated',
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
