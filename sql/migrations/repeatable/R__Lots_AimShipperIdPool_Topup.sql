-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_Topup.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Inserts a fetched Honda AIM shipper ID into the pool (Arc 2 Phase 6;
--              normally called by the Phase 7 Gateway topup loop after an AIM
--              GetNextNumber HTTP call, but the pool can also be dev-seeded). Migration
--              0049: the pool is part-agnostic -- AIM's nextserial.csv accepts no part
--              parameter, serials are unique per company code only. Idempotent
--              on AimShipperId (UNIQUE) -- a duplicate is a no-op success so concurrent
--              topups don't double-insert. No OUTPUT params (FDS-11-011); single terminal
--              SELECT @Status,@Message,@NewId. RAISERROR in the CATCH.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_Topup
    @AimShipperId          NVARCHAR(50),
    @FetchedInterfaceLogId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    BEGIN TRY
        IF @AimShipperId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (AimShipperId).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM Lots.AimShipperIdPool WHERE AimShipperId = @AimShipperId)
        BEGIN
            SET @Message = N'That AIM shipper ID is already in the pool.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        BEGIN TRANSACTION;
        INSERT INTO Lots.AimShipperIdPool (AimShipperId, FetchedAt, FetchedInterfaceLogId)
        VALUES (@AimShipperId, SYSUTCDATETIME(), @FetchedInterfaceLogId);
        SET @NewId = SCOPE_IDENTITY();
        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'AIM shipper ID added to pool.';
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
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
