-- ============================================================
-- Repeatable:  R__Parts_Item_SetAimCustomerPartNumber.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Sets (or clears, with NULL) Parts.Item.AimCustomerPartNumber from
--              the Item Master Identity field. Mirrors Item_SetPlcId's structure:
--              validation before BEGIN TRANSACTION, Audit_LogFailure on every
--              rejecting path, @@TRANCOUNT rollback check, nested TRY/CATCH
--              around the CATCH-block failure log, RAISERROR (not THROW). NULL is
--              legal - not every item ships to Honda. No OUTPUT params; a single
--              terminal SELECT per FDS-11-011. Old/New values are captured as
--              resolved JSON (not just the new value, unlike SetPlcId) per the
--              Audit Log Description Convention.
-- ============================================================
CREATE OR ALTER PROCEDURE Parts.Item_SetAimCustomerPartNumber
    @ItemId    BIGINT,
    @Value     NVARCHAR(50),
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status   BIT           = 0;
    DECLARE @Message  NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Parts.Item_SetAimCustomerPartNumber';
    DECLARE @Params   NVARCHAR(MAX) = (SELECT @ItemId AS ItemId, @Value AS AimCustomerPartNumber
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @PartNo NVARCHAR(50);
    DECLARE @Old    NVARCHAR(50);

    BEGIN TRY
        IF @ItemId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ItemId, AppUserId).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item', @EntityId = @ItemId,
                @LogEventTypeCode = N'Updated', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @PartNo = PartNumber, @Old = AimCustomerPartNumber
        FROM Parts.Item
        WHERE Id = @ItemId AND DeprecatedAt IS NULL;

        IF @PartNo IS NULL
        BEGIN
            SET @Message = N'Item not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item', @EntityId = @ItemId,
                @LogEventTypeCode = N'Updated', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @PartNo + N' ' + Audit.ufn_MidDot() + N' AIM ' + Audit.ufn_MidDot()
            + N' Customer part ' + CASE WHEN @Value IS NULL THEN N'cleared' ELSE N'set' END);
        DECLARE @OldValue NVARCHAR(MAX) = (SELECT @ItemId AS ItemId, @Old AS AimCustomerPartNumber
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = @Params;

        BEGIN TRANSACTION;

        UPDATE Parts.Item
           SET AimCustomerPartNumber = @Value,
               UpdatedAt             = SYSUTCDATETIME(),
               UpdatedByUserId       = @AppUserId
         WHERE Id = @ItemId;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Item',
            @EntityId          = @ItemId,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'AIM customer part number updated.';
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
                @LogEntityTypeCode   = N'Item',
                @EntityId            = @ItemId,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow; we're already in a bad state and shouldn't mask the original exception
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
