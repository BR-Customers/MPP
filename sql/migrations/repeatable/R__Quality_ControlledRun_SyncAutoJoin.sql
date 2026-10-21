-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_SyncAutoJoin.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.0
-- Description: Records super-lot membership for material that is ALREADY CRT-tagged:
--              new production the mint resolver tagged while the window was open
--              (Lots.ufn_CrtForMint arm 4, D7) and CRT descendants of current members
--              (D8). @Id NULL = every open super-lot (the gateway timer's call).
--
--              The work is in the silent helper Quality.ControlledRun_SyncInternal,
--              which owns its own transaction; this wrapper only loops and reports the
--              count. Idempotent. The CRT block never waits on this -- the tag was set
--              in the mint transaction; only the member list lags.
--
--              No audit row from the wrapper: each LOT's tag already has its own
--              CrtActivated row, and a 'found nothing' row every minute would bury
--              the log.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-super-lot-design.md
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.ControlledRun_SyncAutoJoin
    @Id        BIGINT = NULL,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.ControlledRun_SyncAutoJoin';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @Id AS Id, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ---- 1. ----
        IF @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunMemberAdded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 2. ----
        IF @Id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Quality.ControlledRun WHERE Id = @Id)
        BEGIN
            SET @Message = N'Super-lot not found.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunMemberAdded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @Before INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember);
        DECLARE @RunId BIGINT;

        DECLARE run_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT Id FROM Quality.ControlledRun
            WHERE ControlledRunStatusId = 1 AND (@Id IS NULL OR Id = @Id)
            ORDER BY Id;
        OPEN run_cur;
        FETCH NEXT FROM run_cur INTO @RunId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC Quality.ControlledRun_SyncInternal @ControlledRunId = @RunId, @AppUserId = @AppUserId;
            FETCH NEXT FROM run_cur INTO @RunId;
        END
        CLOSE run_cur;
        DEALLOCATE run_cur;

        DECLARE @Added INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember) - @Before;

        SET @Status  = 1;
        SET @Message = CAST(@Added AS NVARCHAR(10)) + N' added.';
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
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunMemberAdded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
