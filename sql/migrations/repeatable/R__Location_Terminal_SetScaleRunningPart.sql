-- =============================================
-- Procedure: Location.Terminal_SetScaleRunningPart
-- Author:    Blue Ridge Automation
-- Created:   2026-10-19
-- Version:   1.0
--
-- Description:
--   Sets or clears a By Weight scale station's running-part OVERRIDE (the
--   ScaleRunningItemId terminal attribute, migration 0113). With no override
--   the station runs the eligible part closest to ready
--   (Workorder.ScaleStation_GetRunningPart). Spec 2026-10-19 scale station,
--   section 6.
--
--   Any PIN-signed-in operator may set it; the audit row is the control
--   (Jacques, 2026-10-19). It lasts until someone changes or clears it.
--
--   Refuses:
--     - a part that is not eligible at the terminal's line right now
--       (Workorder.ufn_ScaleStationEligibleParts -- the same rule the scale
--       close uses);
--     - while the station has an open By Weight box of ANOTHER part (finish
--       or close that box first -- a box is never split across parts);
--     - a no-op (the override already names this part, or is already clear).
--
--   Status-row mutation (FDS-11-011): every rejecting validation runs BEFORE
--   BEGIN TRANSACTION and SELECTs Status, Message + RETURNs; the CATCH is the
--   only ROLLBACK site. Audited to Audit.OperationLog (shop-floor action, the
--   Terminal_SetClosureMethod precedent) as ScaleRunningPartChanged.
--
-- Parameters:
--   @TerminalLocationId BIGINT - Terminal (LTD 7). Required.
--   @ItemId             BIGINT - finished good to run; NULL clears the override.
--   @AppUserId          BIGINT - the signed-in operator. Required.
--
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Location.Terminal_SetScaleRunningPart
    @TerminalLocationId BIGINT,
    @ItemId             BIGINT = NULL,
    @AppUserId          BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Location.Terminal_SetScaleRunningPart';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @TerminalLocationId AS TerminalLocationId, @ItemId AS ItemId, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @AttrDefId BIGINT, @ExistingId BIGINT, @OldItemId BIGINT;
    DECLARE @TermCode NVARCHAR(50), @LineId BIGINT;
    DECLARE @OpenItemId BIGINT, @OpenContainerId BIGINT;
    DECLARE @OldPn NVARCHAR(50), @NewPn NVARCHAR(50);
    DECLARE @Activity NVARCHAR(500), @OldValue NVARCHAR(MAX), @NewValue NVARCHAR(MAX);

    BEGIN TRY
        -- ================= Pre-transaction validations (no open txn) =================
        IF @TerminalLocationId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (TerminalLocationId, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ScaleRunningPartChanged',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @TermCode = Code, @LineId = ParentLocationId
        FROM Location.Location
        WHERE Id = @TerminalLocationId AND LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL;

        IF @TermCode IS NULL OR @LineId IS NULL
        BEGIN
            SET @Message = N'Terminal not found or not a terminal on a line.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ScaleRunningPartChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SET @AttrDefId = (SELECT Id FROM Location.LocationAttributeDefinition
            WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'ScaleRunningItemId' AND DeprecatedAt IS NULL);
        IF @AttrDefId IS NULL
        BEGIN
            SET @Message = N'ScaleRunningItemId attribute is not provisioned (migration 0113).';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ScaleRunningPartChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @ExistingId = Id, @OldItemId = TRY_CAST(NULLIF(LTRIM(RTRIM(AttributeValue)), N'') AS BIGINT)
        FROM Location.LocationAttribute
        WHERE LocationId = @TerminalLocationId AND LocationAttributeDefinitionId = @AttrDefId;

        IF (@ItemId IS NULL AND @OldItemId IS NULL) OR @ItemId = @OldItemId
        BEGIN
            SET @Message = CASE WHEN @ItemId IS NULL THEN N'No override is set; already running the default part.'
                                ELSE N'This part is already the running part.' END;
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ScaleRunningPartChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ItemId IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM Workorder.ufn_ScaleStationEligibleParts(@TerminalLocationId) WHERE ItemId = @ItemId)
        BEGIN
            SET @Message = N'That part cannot run here now: it needs a By Weight pack-out, a cast part and at least 60% of its other parts at the line for one tray.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ScaleRunningPartChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT TOP 1 @OpenContainerId = c.Id, @OpenItemId = c.ItemId
        FROM Lots.Container c
        JOIN Parts.ContainerConfig cc ON cc.Id = c.ContainerConfigId AND cc.ClosureMethod = N'ByWeight'
        WHERE c.StationLocationId = @TerminalLocationId AND c.ContainerStatusCodeId = 1
        ORDER BY c.OpenedAt, c.Id;

        IF @OpenContainerId IS NOT NULL AND (@ItemId IS NULL OR @OpenItemId <> @ItemId)
        BEGIN
            SET @Message = N'Box #' + CAST(@OpenContainerId AS NVARCHAR(20))
                         + N' of another part is still open at this station. Finish or close it first.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ScaleRunningPartChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SET @OldPn = (SELECT PartNumber FROM Parts.Item WHERE Id = @OldItemId);
        SET @NewPn = (SELECT PartNumber FROM Parts.Item WHERE Id = @ItemId);
        SET @OldValue = (SELECT JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description FROM Parts.Item i WHERE i.Id = @OldItemId
                                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ItemId
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @NewValue = (SELECT JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description FROM Parts.Item i WHERE i.Id = @ItemId
                                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ItemId
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Activity = Audit.ufn_TruncateActivity(@TermCode + N' ' + Audit.ufn_MidDot()
            + N' Scale running part ' + Audit.ufn_MidDot() + N' '
            + ISNULL(@OldPn, N'Default') + N' -> ' + ISNULL(@NewPn, N'Default'));

        -- ================= Mutation (atomic) =================
        BEGIN TRANSACTION;

        IF @ExistingId IS NOT NULL
            UPDATE Location.LocationAttribute
            SET AttributeValue = ISNULL(CAST(@ItemId AS NVARCHAR(20)), N''),
                UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
            WHERE Id = @ExistingId;
        ELSE
            INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt, UpdatedAt, UpdatedByUserId)
            VALUES (@TerminalLocationId, @AttrDefId, CAST(@ItemId AS NVARCHAR(20)), SYSUTCDATETIME(), SYSUTCDATETIME(), @AppUserId);

        EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @TerminalLocationId,
            @LogEntityTypeCode = N'Location', @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ScaleRunningPartChanged',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = @OldValue, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = CASE WHEN @ItemId IS NULL THEN N'Override cleared; running the default part.'
                            ELSE N'Running part set to ' + @NewPn + N'.' END;
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
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ScaleRunningPartChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
