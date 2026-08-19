-- ============================================================
-- Repeatable:  R__Lots_Container_ValidateCrt.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-18
-- Version:     1.1
-- Description: A second person has validated a container that completed under a
--              Controlled Run Tag. Clears the CRT flag on the container's
--              finished-good LOT(s), which releases the container's AIM Shipper ID
--              back to the normal post path (AimShipperIdPool_ListUnposted stops
--              excluding it). The POST itself is the Python caller's next step
--              (BlueRidge.Lots.Container.validateCrt calls AimPost.postOne after
--              this proc returns Status 1).
--
--              Clears EVERY tray LOT of the container, not one: a container carries one
--              FG LOT per tray (Lots.ContainerTray.FinishedGoodLotId is 1:1 with the
--              tray, UQ_ContainerTray_FinishedGoodLot), and the serial stays held while
--              ANY of them is CrtActive.
--
--              INSERT-EXEC: this proc returns a status row and is captured by
--              callers, so it must NOT EXEC Lots.Lot_ClearCrt - a nested status-row
--              proc would pollute the single result set and nesting INSERT-EXEC is
--              illegal. The flag clear below MIRRORS Lots.Lot_ClearCrt (same
--              CrtActive/UpdatedAt/UpdatedByUserId shape); keep them in step. Because
--              the proc cannot EXEC the sibling, the per-LOT 'Lot'/'CrtCleared' audit
--              row Lot_ClearCrt normally writes (B7-routed to the 20-yr
--              Lots.LotEventLog, Honda traceability) is emitted INLINE here too, once
--              per LOT actually cleared, using the OUTPUT clause below to know exactly
--              which LOTs the UPDATE touched (never re-derive from the join, which
--              could drift). The container-level 'Container'/'Updated' summary row is
--              KEPT alongside the per-LOT rows - Container_Complete uses the same
--              both-levels pattern (per-LOT via Lot_CloseInline + a container summary).
--
--              All rejects run BEFORE BEGIN TRANSACTION (Msg 3915) and are audited via
--              Audit.Audit_LogFailure, mirroring Lot_ClearCrt. "Pending validation" is
--              the same test as Container_ListPendingValidation / AimShipperIdPool_
--              ListUnposted: the container is COMPLETED (CompletedAt IS NOT NULL - a
--              container still mid-fill is never "pending validation", it is just not
--              done yet) AND any of its tray LOTs is still CrtActive. An unknown
--              container and a container with nothing left to clear both reject the
--              same way (no distinct message needed beyond "not pending validation").
--
--              Race guard: the pre-transaction pending check is advisory only (no lock
--              held across the gap). The UPDATE's own OUTPUT/@@ROWCOUNT is the actual
--              guard - MPP_MES_Test runs READ_COMMITTED with RCSI off, so a second
--              concurrent call can read "pending" and then match zero rows once the
--              first call's row locks release. A zero-row UPDATE COMMITs the (empty)
--              transaction - never ROLLBACK in an INSERT-EXEC-captured proc (Msg 3915)
--              - writes no audit row, and returns Status 0 "already validated".
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Container_ValidateCrt
    @ContainerId        BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Lots.Container_ValidateCrt';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ContainerId AS ContainerId, @AppUserId AS AppUserId,
               @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ContainerId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ContainerId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container',
                    @EntityId = @ContainerId, @LogEventTypeCode = N'Updated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Lots.Container WHERE Id = @ContainerId)
        BEGIN
            SET @Message = N'Container not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container',
                @EntityId = @ContainerId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        -- Pending = COMPLETED (mirrors Container_ListPendingValidation's CompletedAt
        -- gate - a container still mid-fill is not "pending validation") AND at least
        -- one tray LOT still CrtActive.
        IF NOT EXISTS (
            SELECT 1
            FROM Lots.Container c
            JOIN Lots.ContainerTray ct ON ct.ContainerId = c.Id
            JOIN Lots.Lot fgl ON fgl.Id = ct.FinishedGoodLotId
            WHERE c.Id = @ContainerId AND c.CompletedAt IS NOT NULL AND fgl.CrtActive = 1)
        BEGIN
            SET @Message = N'Container is not pending validation.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container',
                @EntityId = @ContainerId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        BEGIN TRANSACTION;

        -- MIRRORS Lots.Lot_ClearCrt (see header): clear the tag + attribution
        -- on every tray LOT of this container in one set-based UPDATE. OUTPUT
        -- captures exactly which LOTs were actually touched, both for the
        -- @@ROWCOUNT race guard and for the per-LOT audit loop below - never
        -- re-derive the affected set from the join, which could drift from
        -- what the UPDATE actually changed.
        DECLARE @ClearedLots TABLE (LotId BIGINT);

        UPDATE fgl
        SET fgl.CrtActive       = 0,
            fgl.UpdatedAt       = SYSUTCDATETIME(),
            fgl.UpdatedByUserId = @AppUserId
        OUTPUT inserted.Id INTO @ClearedLots (LotId)
        FROM Lots.Lot fgl
        JOIN Lots.ContainerTray ct ON ct.FinishedGoodLotId = fgl.Id
        WHERE ct.ContainerId = @ContainerId AND fgl.CrtActive = 1;

        IF @@ROWCOUNT = 0
        BEGIN
            -- Lost the race: another caller cleared every tray LOT between the
            -- pending check above and this UPDATE. Empty transaction, no audit,
            -- no ROLLBACK (INSERT-EXEC-captured proc - Msg 3915).
            COMMIT TRANSACTION;
            SET @Status = 0;
            SET @Message = N'Container was already validated.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Per-LOT audit (Finding: the per-LOT CRT clear must reach the LOT's own
        -- genealogy trail for Honda traceability). Mirrors Lot_ClearCrt's
        -- Audit_LogOperation call shape exactly (entity 'Lot' / event 'CrtCleared',
        -- same description + OldValue/NewValue JSON), once per LOT actually cleared.
        DECLARE @LotId   BIGINT;
        DECLARE @LotName NVARCHAR(50);
        DECLARE @LotActivityRaw NVARCHAR(MAX);
        DECLARE @LotActivity    NVARCHAR(500);
        DECLARE @LotOldValue    NVARCHAR(MAX);
        DECLARE @LotNewValue    NVARCHAR(MAX);

        DECLARE cleared_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT LotId FROM @ClearedLots;
        OPEN cleared_cur;
        FETCH NEXT FROM cleared_cur INTO @LotId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @LotName = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);

            SET @LotActivityRaw =
                @LotName + N' ' + Audit.ufn_MidDot() + N' CRT ' + Audit.ufn_MidDot() + N' Cleared';
            SET @LotActivity = Audit.ufn_TruncateActivity(@LotActivityRaw);

            SET @LotOldValue = (SELECT CAST(1 AS BIT) AS CrtActive FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            SET @LotNewValue = (
                SELECT
                    CAST(0 AS BIT) AS CrtActive,
                    JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                                FROM Lots.Lot l WHERE l.Id = @LotId
                                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC Audit.Audit_LogOperation
                @AppUserId          = @AppUserId,
                @TerminalLocationId = @TerminalLocationId,
                @LocationId         = NULL,
                @LogEntityTypeCode  = N'Lot',
                @EntityId           = @LotId,
                @LogEventTypeCode   = N'CrtCleared',
                @LogSeverityCode    = N'Info',
                @Description        = @LotActivity,
                @OldValue           = @LotOldValue,
                @NewValue           = @LotNewValue;

            FETCH NEXT FROM cleared_cur INTO @LotId;
        END
        CLOSE cleared_cur; DEALLOCATE cleared_cur;

        -- Container-level summary row, kept alongside the per-LOT rows above
        -- (Container_Complete uses this same both-levels pattern).
        DECLARE @Descr NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot()
            + N' Controlled Run Tag ' + Audit.ufn_MidDot() + N' Validated');

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'Container', @EntityId = @ContainerId,
            @LogEventTypeCode = N'Updated', @LogSeverityCode = N'Info',
            @Description = @Descr, @OldValue = NULL, @NewValue = NULL;

        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = N'Container validated.';
        SELECT @Status AS Status, @Message AS Message;
        RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container',
                @EntityId = @ContainerId, @LogEventTypeCode = N'Updated', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
