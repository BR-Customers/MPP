-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_Claim.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Atomically claims the oldest un-consumed AIM shipper ID for a part
--              number (FIFO by FetchedAt; Arc 2 Phase 6 / UJ-04). OI-33 default:
--              HARD-FAIL on an empty pool (Status 0) -- Container_Complete rolls back
--              its close on this. Standalone proc for direct/test use; Container_Complete
--              INLINES the same claim logic (FDS-11-011: it is captured via INSERT-EXEC
--              and cannot EXEC a sibling status-row proc). The empty/lost-race paths
--              never ROLLBACK (Msg 3915 hazard) -- the empty pre-check returns with no
--              open tran, and a lost-race no-op UPDATE COMMITs unchanged. Audits
--              'AimShipperIdClaimed'. No OUTPUT params; single terminal SELECT
--              @Status,@Message,@AimShipperId. RAISERROR in the CATCH.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_Claim
    @PartNumber  NVARCHAR(50),
    @ContainerId BIGINT,
    @AppUserId   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status       BIT           = 0;
    DECLARE @Message      NVARCHAR(500) = N'Unknown error';
    DECLARE @AimShipperId NVARCHAR(50)  = NULL;
    DECLARE @ClaimedId    BIGINT        = NULL;
    DECLARE @Activity     NVARCHAR(500);
    DECLARE @claimed TABLE (Id BIGINT, AimShipperId NVARCHAR(50));

    BEGIN TRY
        IF @PartNumber IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (PartNumber).';
            SELECT @Status AS Status, @Message AS Message, @AimShipperId AS AimShipperId;
            RETURN;
        END

        -- OI-33 hard-fail: empty pool -> reject BEFORE opening a tran (no ROLLBACK hazard).
        IF NOT EXISTS (SELECT 1 FROM Lots.AimShipperIdPool WHERE PartNumber = @PartNumber AND ConsumedAt IS NULL)
        BEGIN
            SET @Message = N'AIM shipper ID pool is empty for part ' + @PartNumber + N'.';
            SELECT @Status AS Status, @Message AS Message, @AimShipperId AS AimShipperId;
            RETURN;
        END

        BEGIN TRANSACTION;

        -- atomic FIFO claim of the oldest un-consumed ID; READPAST lets concurrent
        -- claimers skip each other's locked rows.
        ;WITH c AS (
            SELECT TOP 1 Id, AimShipperId, ConsumedAt, ConsumedByContainerId, ConsumedByUserId
            FROM Lots.AimShipperIdPool WITH (ROWLOCK, UPDLOCK, READPAST)
            WHERE PartNumber = @PartNumber AND ConsumedAt IS NULL
            ORDER BY FetchedAt, Id)
        UPDATE c
            SET ConsumedAt = SYSUTCDATETIME(), ConsumedByContainerId = @ContainerId, ConsumedByUserId = @AppUserId
        OUTPUT inserted.Id, inserted.AimShipperId INTO @claimed (Id, AimShipperId);

        SELECT @ClaimedId = Id, @AimShipperId = AimShipperId FROM @claimed;

        IF @ClaimedId IS NULL
        BEGIN
            -- lost the race (all claimed between pre-check and update): no-op COMMIT (NOT ROLLBACK).
            COMMIT TRANSACTION;
            SET @Status = 0;
            SET @Message = N'AIM shipper ID pool is empty for part ' + @PartNumber + N'.';
            SELECT @Status AS Status, @Message AS Message, @AimShipperId AS AimShipperId;
            RETURN;
        END

        SET @Activity = Audit.ufn_TruncateActivity(@AimShipperId + N' ' + Audit.ufn_MidDot() + N' AIM ID ' + Audit.ufn_MidDot() + N' Claimed');
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = NULL, @LocationId = NULL,
            @LogEntityTypeCode = N'AimShipperIdPool', @EntityId = @ClaimedId, @LogEventTypeCode = N'AimShipperIdClaimed',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = NULL;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'AIM shipper ID ' + @AimShipperId + N' claimed.';
        SELECT @Status AS Status, @Message AS Message, @AimShipperId AS AimShipperId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @AimShipperId = NULL;
        SELECT @Status AS Status, @Message AS Message, @AimShipperId AS AimShipperId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
