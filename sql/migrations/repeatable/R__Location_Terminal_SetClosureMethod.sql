-- =============================================
-- Procedure: Location.Terminal_SetClosureMethod
-- Author:    Blue Ridge Automation
-- Created:   2026-07-17
-- Version:   1.0
--
-- Description:
--   Elevated shop-floor CHANGEOVER: sets an assembly-out terminal's active
--   closure mode (CurrentClosureMethod LocationAttribute). The new mode must be
--   within the terminal's capability set (ByCount always; ByWeight/ByVision only
--   if a capable PLC device is bound). If a container is OPEN at the terminal's
--   zone cell, it is FROZEN (Quality.HoldEvent 'Changeover' + status Hold(4)) so
--   a half-filled container never continues under a different method.
--
--   *** WHY THE FREEZE IS INLINED ***
--   This is a status-row proc captured via INSERT-EXEC by the entity-script
--   caller, so it CANNOT EXEC Quality.Hold_Place (a sibling status-row proc --
--   its SELECT would pollute this proc's single result set, and nested
--   INSERT-EXEC is illegal). The freeze MIRRORS the container branch of
--   R__Quality_Hold_Place (HoldEvent insert with PriorContainerStatusCodeId +
--   Container status -> 4). Audit writers (Audit_Log*) emit no result set, so
--   they are EXEC'd normally. ALL rejecting validations run BEFORE
--   BEGIN TRANSACTION (SELECT status + RETURN, no open txn); the CATCH is the
--   only legal ROLLBACK site.
--
--   No OUTPUT params (FDS-11-011). Single terminal SELECT Status, Message.
--
-- Parameters:
--   @TerminalLocationId BIGINT       - the Terminal Location.Id (LTD 7).
--   @NewMethod          NVARCHAR(20) - ByCount / ByWeight / ByVision.
--   @AppUserId          BIGINT       - elevated (supervisor) user id.
-- =============================================
CREATE OR ALTER PROCEDURE Location.Terminal_SetClosureMethod
    @TerminalLocationId BIGINT,
    @NewMethod          NVARCHAR(20),
    @AppUserId          BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Location.Terminal_SetClosureMethod';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @TerminalLocationId AS TerminalLocationId, @NewMethod AS NewMethod, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @AttrDefId  BIGINT, @ExistingId BIGINT, @OldMethod NVARCHAR(255);
    DECLARE @TermCode   NVARCHAR(50), @CellId BIGINT;
    DECLARE @OpenContainerId BIGINT, @PriorConStatus BIGINT;
    DECLARE @ChangeoverHoldId BIGINT;
    DECLARE @Activity NVARCHAR(500), @OldValue NVARCHAR(MAX), @NewValue NVARCHAR(MAX);

    BEGIN TRY
        -- ================= Pre-transaction validations (no open txn) =================

        IF @TerminalLocationId IS NULL OR @NewMethod IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (TerminalLocationId, NewMethod, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ClosureModeChanged',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Method must be a known closure code.
        IF NOT EXISTS (SELECT 1 FROM Parts.ClosureMethodCode WHERE Code = @NewMethod AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid closure method code.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ClosureModeChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Terminal must exist (active, LTD 7).
        SELECT @TermCode = Code, @CellId = ParentLocationId
        FROM Location.Location
        WHERE Id = @TerminalLocationId AND LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL;

        IF @TermCode IS NULL
        BEGIN
            SET @Message = N'Terminal not found or not a terminal.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ClosureModeChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Capability: ByCount is always allowed; other methods need a capable device.
        IF @NewMethod <> N'ByCount' AND NOT EXISTS (
            SELECT 1 FROM Location.TerminalPlcDevice tpd
            INNER JOIN Location.PlcDeviceType pdt ON pdt.Id = tpd.PlcDeviceTypeId
            WHERE tpd.TerminalLocationId = @TerminalLocationId
              AND tpd.DeprecatedAt IS NULL
              AND pdt.ClosureMethodCode = @NewMethod)
        BEGIN
            SET @Message = N'This terminal cannot run ' + @NewMethod + N' (no capable device).';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ClosureModeChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Resolve the CurrentClosureMethod attribute definition (LTD 7).
        SET @AttrDefId = (SELECT Id FROM Location.LocationAttributeDefinition
            WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'CurrentClosureMethod' AND DeprecatedAt IS NULL);
        IF @AttrDefId IS NULL
        BEGIN
            SET @Message = N'CurrentClosureMethod attribute is not provisioned.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ClosureModeChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Capture existing value + any open container at the terminal's zone cell.
        SELECT @ExistingId = Id, @OldMethod = AttributeValue
        FROM Location.LocationAttribute
        WHERE LocationId = @TerminalLocationId AND LocationAttributeDefinitionId = @AttrDefId;

        SELECT TOP 1 @OpenContainerId = Id, @PriorConStatus = ContainerStatusCodeId
        FROM Lots.Container
        WHERE CurrentLocationId = @CellId AND ContainerStatusCodeId = 1   -- 1 = Open
        ORDER BY OpenedAt, Id;

        -- Already in this mode + no open container -> nothing to do (idempotent success).
        SET @ChangeoverHoldId = (SELECT Id FROM Quality.HoldTypeCode WHERE Code = N'Changeover');

        SET @OldValue = (SELECT @OldMethod AS CurrentClosureMethod FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @NewValue = (SELECT @NewMethod AS CurrentClosureMethod,
                                @OpenContainerId AS FrozenContainerId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Activity = Audit.ufn_TruncateActivity(@TermCode + N' ' + Audit.ufn_MidDot()
            + N' Closure Mode ' + Audit.ufn_MidDot() + N' Changed '
            + ISNULL(@OldMethod, N'(none)') + N' ' + NCHAR(8594) + N' ' + @NewMethod
            + CASE WHEN @OpenContainerId IS NOT NULL THEN N' (froze open container #' + CAST(@OpenContainerId AS NVARCHAR(20)) + N')' ELSE N'' END);

        -- ================= Mutation (atomic) =================
        BEGIN TRANSACTION;

        -- Upsert CurrentClosureMethod (mirror Location.LocationAttribute_Set).
        IF @ExistingId IS NOT NULL
            UPDATE Location.LocationAttribute
            SET AttributeValue = @NewMethod, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
            WHERE Id = @ExistingId;
        ELSE
            INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
            VALUES (@TerminalLocationId, @AttrDefId, @NewMethod, SYSUTCDATETIME());

        -- Freeze an open container at the cell (mirror Quality.Hold_Place container branch).
        IF @OpenContainerId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Quality.HoldEvent WHERE ContainerId = @OpenContainerId AND ReleasedAt IS NULL)
        BEGIN
            INSERT INTO Quality.HoldEvent (LotId, ContainerId, HoldTypeCodeId, Reason, PlacedByUserId, PlacedAt, PriorContainerStatusCodeId)
            VALUES (NULL, @OpenContainerId, @ChangeoverHoldId, N'Frozen by closure-mode changeover.', @AppUserId, SYSUTCDATETIME(), @PriorConStatus);
            DECLARE @FreezeHoldEventId BIGINT = SCOPE_IDENTITY();
            UPDATE Lots.Container SET ContainerStatusCodeId = 4 WHERE Id = @OpenContainerId;  -- 4 = Hold

            DECLARE @FreezeActivity NVARCHAR(500) = Audit.ufn_TruncateActivity(
                N'Container #' + CAST(@OpenContainerId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot()
                + N' Hold ' + Audit.ufn_MidDot() + N' Placed (changeover freeze)');
            EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @CellId,
                @LogEntityTypeCode = N'HoldEvent', @EntityId = @FreezeHoldEventId, @LogEventTypeCode = N'HoldPlaced',
                @LogSeverityCode = N'Info', @Description = @FreezeActivity, @OldValue = NULL, @NewValue = NULL;
        END

        -- Audit the mode change (entity = the terminal Location).
        EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @TerminalLocationId,
            @LogEntityTypeCode = N'Location', @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ClosureModeChanged',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = @OldValue, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Closure mode set to ' + @NewMethod + N'.'
                     + CASE WHEN @OpenContainerId IS NOT NULL THEN N' Open container frozen.' ELSE N'' END;
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ClosureModeChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
