-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_MarkPosted.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Human-confirmed resolution for a row stuck owed to AIM. If AIM
--              accepted a post but the reply was lost, retry gets the rejection
--              echo forever and AIM has no query endpoint to disambiguate - so a
--              supervisor confirms the label on AIM's Unshipped Labels report and
--              marks it posted here. Asserts something the MES cannot verify, so
--              it is audited as a human decision with the supervisor's note.
--              Rejects an already-posted row. No OUTPUT params; single terminal
--              SELECT. RAISERROR in the CATCH.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_MarkPosted
    @Id        BIGINT,
    @AppUserId BIGINT,
    @Note      NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status   BIT           = 0;
    DECLARE @Message  NVARCHAR(500) = N'Unknown error';
    DECLARE @Serial   NVARCHAR(50);
    DECLARE @Activity NVARCHAR(500);
    DECLARE @NewValue NVARCHAR(MAX);

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id, AppUserId).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @Serial = AimShipperId FROM Lots.AimShipperIdPool WHERE Id = @Id;

        IF @Serial IS NULL
        BEGIN
            SET @Message = N'AIM pool row not found.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM Lots.AimShipperIdPool WHERE Id = @Id AND PostedAt IS NOT NULL)
        BEGIN
            SET @Message = N'This shipper ID is already recorded as posted to AIM.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE Lots.AimShipperIdPool
           SET PostedAt      = SYSUTCDATETIME(),
               LastPostError = NULL
         WHERE Id = @Id;

        SET @Activity = Audit.ufn_TruncateActivity(
            N'AIM ' + @Serial + N' ' + Audit.ufn_MidDot()
            + N' Post-back ' + Audit.ufn_MidDot() + N' Marked Posted (manual): ' + ISNULL(@Note, N''));
        SET @NewValue = (SELECT @Id AS AimShipperIdPoolId, @Serial AS AimShipperId,
                                @Note AS Note
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'AimShipperIdPool',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @Description       = @Activity,
            @OldValue          = NULL,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Shipper ID ' + @Serial + N' marked posted to AIM.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(2000) = ERROR_MESSAGE();
        SET @Status  = 0;
        SET @Message = N'Failed to mark the shipper ID posted.';
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR (@ErrMsg, 16, 1);
    END CATCH
END;
GO
