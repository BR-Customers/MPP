-- ============================================================
-- Repeatable:  R__Quality_Hold_Release.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Releases a single open hold (Arc 2 Phase 7). Validates the HoldEvent is
--              open; sets ReleasedByUserId/ReleasedAt/ReleaseRemarks; restores the
--              entity status -- a LOT goes back to the prior status recorded on the
--              Hold transition (LotStatusHistory OldStatusId, default Good=1); a
--              Container returns to Complete (2). Audits 'HoldReleased'. AIM
--              ReleaseFromHold for shipped containers is a Gateway-async step (A6).
--              No OUTPUT params (FDS-11-011); single terminal SELECT @Status,@Message.
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.Hold_Release
    @HoldEventId        BIGINT,
    @ReleaseRemarks     NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @LotId BIGINT, @ContainerId BIGINT, @ReleasedAt DATETIME2(3), @PriorStatus BIGINT,
            @Subject NVARCHAR(100), @Activity NVARCHAR(500);

    BEGIN TRY
        IF @HoldEventId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (HoldEventId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @LotId = LotId, @ContainerId = ContainerId, @ReleasedAt = ReleasedAt
        FROM Quality.HoldEvent WHERE Id = @HoldEventId;

        IF @LotId IS NULL AND @ContainerId IS NULL AND @ReleasedAt IS NULL
        BEGIN
            -- both NULL only happens when the row doesn't exist (CK guarantees one set)
            IF NOT EXISTS (SELECT 1 FROM Quality.HoldEvent WHERE Id = @HoldEventId)
            BEGIN
                SET @Message = N'Hold event not found.';
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END
        END
        IF @ReleasedAt IS NOT NULL
        BEGIN
            SET @Message = N'Hold is already released.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SET @Subject = CASE WHEN @LotId IS NOT NULL
            THEN ISNULL((SELECT LotName FROM Lots.Lot WHERE Id = @LotId), N'LOT')
            ELSE N'Container #' + CAST(@ContainerId AS NVARCHAR(20)) END;
        SET @Activity = Audit.ufn_TruncateActivity(@Subject + N' ' + Audit.ufn_MidDot() + N' Hold ' + Audit.ufn_MidDot() + N' Released');

        -- ---- Mutation (atomic) ----
        BEGIN TRANSACTION;

        UPDATE Quality.HoldEvent
        SET ReleasedByUserId = @AppUserId, ReleasedAt = SYSUTCDATETIME(), ReleaseRemarks = @ReleaseRemarks
        WHERE Id = @HoldEventId;

        IF @LotId IS NOT NULL
        BEGIN
            SELECT TOP 1 @PriorStatus = OldStatusId FROM Lots.LotStatusHistory
            WHERE LotId = @LotId AND NewStatusId = 2 ORDER BY ChangedAt DESC, Id DESC;
            IF @PriorStatus IS NULL SET @PriorStatus = 1;  -- default Good
            UPDATE Lots.Lot SET LotStatusId = @PriorStatus WHERE Id = @LotId;
            INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
            VALUES (@LotId, 2, @PriorStatus, @ReleaseRemarks, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        END
        ELSE
        BEGIN
            -- P7-7: restore the container's pre-hold status (captured on the HoldEvent at
            -- place time) instead of forcing Complete -- so a shipped->hold->release
            -- container returns to Shipped, not a re-shippable Complete. Falls back to
            -- Complete (2) for pre-0031 holds that have no captured prior status.
            SELECT @PriorStatus = PriorContainerStatusCodeId FROM Quality.HoldEvent WHERE Id = @HoldEventId;
            UPDATE Lots.Container SET ContainerStatusCodeId = COALESCE(@PriorStatus, 2) WHERE Id = @ContainerId;
        END

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'HoldEvent', @EntityId = @HoldEventId, @LogEventTypeCode = N'HoldReleased',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = NULL;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Hold released.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
