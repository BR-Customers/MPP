-- =============================================
-- Procedure:   Parts.Item_SetPlcId
-- Description: Set the stable per-part PLC/vision recipe integer on an Item.
--   No uniqueness constraint - the assembly-out FIFO queue fixes the expected
--   part at run time (spec 2026-07-10 section 4.3).
-- Result set: Status BIT, Message NVARCHAR(500).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Item_SetPlcId
    @ItemId    BIGINT,
    @PlcId     INT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Parts.Item_SetPlcId';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @ItemId AS ItemId, @PlcId AS PlcId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ItemId IS NULL OR @PlcId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Item',
                @EntityId=@ItemId, @LogEventTypeCode=N'Updated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id=@ItemId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Item not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Item',
                @EntityId=@ItemId, @LogEventTypeCode=N'Updated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Item ' + CAST(@ItemId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot()
            + N' Set PlcId = ' + CAST(@PlcId AS NVARCHAR(10)));

        BEGIN TRANSACTION;
        UPDATE Parts.Item SET PlcId=@PlcId WHERE Id=@ItemId;

        EXEC Audit.Audit_LogConfigChange @AppUserId=@AppUserId, @LogEntityTypeCode=N'Item',
            @EntityId=@ItemId, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=NULL, @NewValue=@Params;
        COMMIT TRANSACTION;

        SET @Status=1; SET @Message=N'PLC ID set.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Item',
                @EntityId=@ItemId, @LogEventTypeCode=N'Updated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
