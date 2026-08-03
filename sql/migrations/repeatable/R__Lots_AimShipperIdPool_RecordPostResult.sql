-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_RecordPostResult.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Records the outcome of one AIM postserial.csv attempt. Success
--              stamps PostedAt (the row leaves the unposted index); failure
--              increments PostAttempts and stores the reply text. Always bumps
--              LastPostAttemptAt. No OUTPUT params; single terminal SELECT.
--              RAISERROR in the CATCH.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_RecordPostResult
    @Id      BIGINT,
    @Success BIT,
    @Error   NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    BEGIN TRY
        IF @Id IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Lots.AimShipperIdPool WHERE Id = @Id)
        BEGIN
            SET @Message = N'AIM pool row not found.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        UPDATE Lots.AimShipperIdPool
           SET PostedAt          = CASE WHEN @Success = 1 THEN SYSUTCDATETIME() ELSE PostedAt END,
               PostAttempts      = PostAttempts + 1,
               LastPostAttemptAt = SYSUTCDATETIME(),
               LastPostError     = CASE WHEN @Success = 1 THEN NULL ELSE @Error END
         WHERE Id = @Id;

        SET @Status  = 1;
        SET @Message = CASE WHEN @Success = 1
                            THEN N'AIM post recorded as successful.'
                            ELSE N'AIM post failure recorded.' END;
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg NVARCHAR(2000) = ERROR_MESSAGE();
        SET @Status  = 0;
        SET @Message = N'Failed to record AIM post result.';
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR (@ErrMsg, 16, 1);
    END CATCH
END;
GO
