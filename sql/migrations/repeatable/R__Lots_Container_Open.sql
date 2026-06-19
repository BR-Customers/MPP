-- ============================================================
-- Repeatable:  R__Lots_Container_Open.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Opens a new packaging Container at a Cell (Arc 2 Phase 6 assembly).
--              Status defaults to Open (ContainerStatusCode Id 1). Audits
--              'ContainerOpened' to Audit.OperationLog with resolved-FK NewValue.
--              No OUTPUT params (FDS-11-011); single terminal SELECT
--              @Status,@Message,@NewId. RAISERROR (not THROW) in the CATCH.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Container_Open
    @ItemId             BIGINT,
    @ContainerConfigId  BIGINT,
    @CellLocationId     BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Container_Open';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ItemId AS ItemId, @ContainerConfigId AS ContainerConfigId,
               @CellLocationId AS CellLocationId, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LocCode NVARCHAR(50);
    DECLARE @Activity NVARCHAR(500);
    DECLARE @NewValue NVARCHAR(MAX);

    BEGIN TRY
        -- ---- Tier 1: required-parameter validation ----
        IF @ItemId IS NULL OR @ContainerConfigId IS NULL OR @CellLocationId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ItemId, ContainerConfigId, CellLocationId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container', @EntityId = NULL,
                    @LogEventTypeCode = N'ContainerOpened', @FailureReason = @Message,
                    @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- Tier 2: referential validation ----
        IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = @ItemId)
        BEGIN
            SET @Message = N'Item not found.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container', @EntityId = NULL,
                @LogEventTypeCode = N'ContainerOpened', @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE Id = @ContainerConfigId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Container config not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container', @EntityId = NULL,
                @LogEventTypeCode = N'ContainerOpened', @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        SELECT @LocCode = Code FROM Location.Location WHERE Id = @CellLocationId AND DeprecatedAt IS NULL;
        IF @LocCode IS NULL
        BEGIN
            SET @Message = N'Cell location not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container', @EntityId = NULL,
                @LogEventTypeCode = N'ContainerOpened', @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- Audit narrative + resolved-FK NewValue (pre-mutation) ----
        SET @Activity = Audit.ufn_TruncateActivity(@LocCode + N' ' + Audit.ufn_MidDot() + N' Container ' + Audit.ufn_MidDot() + N' Opened');
        SET @NewValue = (
            SELECT JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id = @ItemId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                   JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = @CellLocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location,
                   @ContainerConfigId AS ContainerConfigId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ---- Mutation (atomic) ----
        BEGIN TRANSACTION;

        INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, OpenedAt, CreatedByUserId)
        VALUES (@ItemId, @ContainerConfigId, @CellLocationId, 1, SYSUTCDATETIME(), @AppUserId);

        SET @NewId = SCOPE_IDENTITY();

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @CellLocationId,
            @LogEntityTypeCode = N'Container', @EntityId = @NewId, @LogEventTypeCode = N'ContainerOpened',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Container opened.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();

        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId = NULL;

        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container', @EntityId = NULL,
                @LogEventTypeCode = N'ContainerOpened', @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
