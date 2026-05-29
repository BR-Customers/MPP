-- =============================================
-- Procedure:   Location.Location_MoveDown
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     2.1
--
-- Description:
--   Moves a Location down in the sort order by swapping SortOrder with
--   the nearest active sibling below (higher SortOrder) within the same
--   parent. No-op (Status=1) if already at the bottom position.
--   Handles NULL ParentLocationId (root-level siblings).
--
-- Parameters (input):
--   @Id BIGINT        - PK of the Location to move. Required.
--   @AppUserId BIGINT - User performing the action. Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success (including no-op), 0 on failure.
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
--                       "Reordered from #old to #new" Description narrative +
--                       resolved-FK OldValue/NewValue JSON (differ in SortOrder).
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_MoveDown
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
    DECLARE @ProcName NVARCHAR(200) = N'Location.Location_MoveDown';
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
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Get current row's SortOrder and parent
        DECLARE @CurrentSort INT, @ParentId BIGINT;
        SELECT @CurrentSort = SortOrder,
               @ParentId    = ParentLocationId
        FROM Location.Location
        WHERE Id = @Id AND DeprecatedAt IS NULL;

        IF @CurrentSort IS NULL
        BEGIN
            SET @Message = N'Location not found or deprecated.';
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

        -- Find nearest active sibling BELOW (higher SortOrder)
        DECLARE @SwapId BIGINT, @SwapSort INT;

        IF @ParentId IS NULL
            SELECT TOP 1 @SwapId = Id, @SwapSort = SortOrder
            FROM Location.Location
            WHERE ParentLocationId IS NULL
              AND DeprecatedAt IS NULL
              AND SortOrder > @CurrentSort
            ORDER BY SortOrder ASC;
        ELSE
            SELECT TOP 1 @SwapId = Id, @SwapSort = SortOrder
            FROM Location.Location
            WHERE ParentLocationId = @ParentId
              AND DeprecatedAt IS NULL
              AND SortOrder > @CurrentSort
            ORDER BY SortOrder ASC;

        -- Already last — no-op, success
        IF @SwapId IS NULL
        BEGIN
            SET @Status  = 1;
            SET @Message = N'Already at the bottom position.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Audit narrative + resolved JSON (captured BEFORE the swap)
        -- ====================
        DECLARE @LocCode NVARCHAR(50);
        SELECT @LocCode = Code FROM Location.Location WHERE Id = @Id;

        DECLARE @ParentCode NVARCHAR(50);
        IF @ParentId IS NOT NULL
            SELECT @ParentCode = Code FROM Location.Location WHERE Id = @ParentId;

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            N'Location ' + @LocCode +
            N' ' + Audit.ufn_MidDot() +
            N' Reordered from #' + CAST(@CurrentSort AS NVARCHAR(10)) +
            N' to #' + CAST(@SwapSort AS NVARCHAR(10)) +
            CASE WHEN @ParentId IS NOT NULL THEN N' within ' + @ParentCode ELSE N'' END;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- Resolved-FK snapshots differ only in SortOrder
        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT
                l.Id, l.Code, l.Name,
                @CurrentSort AS SortOrder,
                JSON_QUERY((SELECT p.Id, p.Code, p.Name
                            FROM Location.Location p WHERE p.Id = l.ParentLocationId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                  AS Parent,
                JSON_QUERY((SELECT ltd.Id, ltd.Name
                            FROM Location.LocationTypeDefinition ltd WHERE ltd.Id = l.LocationTypeDefinitionId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                  AS LocationTypeDefinition
            FROM Location.Location l WHERE l.Id = @Id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT
                l.Id, l.Code, l.Name,
                @SwapSort AS SortOrder,
                JSON_QUERY((SELECT p.Id, p.Code, p.Name
                            FROM Location.Location p WHERE p.Id = l.ParentLocationId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                  AS Parent,
                JSON_QUERY((SELECT ltd.Id, ltd.Name
                            FROM Location.LocationTypeDefinition ltd WHERE ltd.Id = l.LocationTypeDefinitionId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                  AS LocationTypeDefinition
            FROM Location.Location l WHERE l.Id = @Id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        UPDATE Location.Location SET SortOrder = @SwapSort WHERE Id = @Id;
        UPDATE Location.Location SET SortOrder = @CurrentSort WHERE Id = @SwapId;

        -- Success audit INSIDE the transaction
        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Location',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Moved down successfully.';
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
