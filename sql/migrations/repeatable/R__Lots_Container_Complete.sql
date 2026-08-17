-- ============================================================
-- Repeatable:  R__Lots_Container_Complete.sql
-- Author:      Blue Ridge Automation
-- Version:     1.1
-- Description: Atomic container close (Arc 2 Phase 6; FDS-06-014/06-028/07-010a).
--              Validates the container is Open + full (accumulated tray parts >= target
--              TraysPerContainer*PartsPerTray), enforces the RequiresCompletionConfirm
--              terminal gate (OI-16), then INLINES the AIM-ID claim (FIFO from the
--              part-agnostic pool -- Migration 0052, AIM's nextserial.csv takes no part
--              parameter) + inserts the ShippingLabel + flips status to
--              Complete -- one transaction. On completion it also closes the container's
--              Good finished-good LOTs (tray = LOT) via Lots.Lot_CloseInline (FAT #21).
--
--              ORCHESTRATING proc: it is captured via INSERT-EXEC, so it does NOT EXEC
--              AimShipperIdPool_Claim (the inline claim mirrors that proc) and every
--              rejecting validation -- including the OI-33 empty-pool hard-fail -- runs
--              BEFORE BEGIN TRANSACTION (SELECT status + RETURN, container stays Open).
--              The only ROLLBACK is the CATCH (XACT_ABORT). The lost-race claim inside
--              the tran COMMITs the no-op (never ROLLBACKs) to avoid Msg 3915.
--              No OUTPUT params (FDS-11-011); single terminal SELECT
--              @Status,@Message,@ShippingLabelId,@AimShipperId. RAISERROR in the CATCH.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Container_Complete
    @ContainerId            BIGINT,
    @PlcCompletionConfirmed BIT    = 0,
    @OperatorConfirmed      BIT    = 0,
    @AppUserId              BIGINT = NULL,
    @TerminalLocationId     BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status         BIT           = 0;
    DECLARE @Message        NVARCHAR(500) = N'Unknown error';
    DECLARE @ShippingLabelId BIGINT       = NULL;
    DECLARE @AimShipperId    NVARCHAR(50) = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Container_Complete';
    DECLARE @Params   NVARCHAR(MAX) = (SELECT @ContainerId AS ContainerId, @OperatorConfirmed AS OperatorConfirmed,
        @PlcCompletionConfirmed AS PlcCompletionConfirmed, @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @StatusCode BIGINT, @ItemId BIGINT,
            @TraysPerContainer INT, @PartsPerTray INT, @Target INT, @Accum INT,
            @MustConfirm BIT, @RequiresConfirm NVARCHAR(50),
            @ClaimedPoolId BIGINT, @LabelTypeId BIGINT, @Activity NVARCHAR(500), @NewValue NVARCHAR(MAX);
    DECLARE @claimed TABLE (Id BIGINT, AimShipperId NVARCHAR(50));
    DECLARE @FgLotId BIGINT;

    BEGIN TRY
        -- ---- Tier 1 ----
        IF @ContainerId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ContainerId).';
            SELECT @Status AS Status, @Message AS Message, @ShippingLabelId AS ShippingLabelId, @AimShipperId AS AimShipperId;
            RETURN;
        END

        -- ---- Tier 2: container open + config + part number ----
        SELECT @StatusCode = ct.ContainerStatusCodeId, @ItemId = ct.ItemId,
               @TraysPerContainer = cc.TraysPerContainer, @PartsPerTray = cc.PartsPerTray
        FROM Lots.Container ct
        INNER JOIN Parts.ContainerConfig cc ON cc.Id = ct.ContainerConfigId
        WHERE ct.Id = @ContainerId;

        IF @StatusCode IS NULL
        BEGIN
            SET @Message = N'Container not found.';
            SELECT @Status AS Status, @Message AS Message, @ShippingLabelId AS ShippingLabelId, @AimShipperId AS AimShipperId;
            RETURN;
        END
        IF @StatusCode <> 1
        BEGIN
            SET @Message = N'Container is not open.';
            SELECT @Status AS Status, @Message AS Message, @ShippingLabelId AS ShippingLabelId, @AimShipperId AS AimShipperId;
            RETURN;
        END
        -- ---- OI-16 completion-confirm gate (per-terminal RequiresCompletionConfirm) ----
        SET @RequiresConfirm = (
            SELECT TOP 1 la.AttributeValue
            FROM Location.LocationAttribute la
            INNER JOIN Location.LocationAttributeDefinition lad ON lad.Id = la.LocationAttributeDefinitionId
            WHERE la.LocationId = @TerminalLocationId AND lad.AttributeName = N'RequiresCompletionConfirm');
        SET @MustConfirm = CASE WHEN LOWER(ISNULL(@RequiresConfirm, N'')) IN (N'true', N'1', N'yes') THEN 1 ELSE 0 END;
        IF @MustConfirm = 1 AND ISNULL(@OperatorConfirmed, 0) <> 1 AND ISNULL(@PlcCompletionConfirmed, 0) <> 1
        BEGIN
            SET @Message = N'Completion confirmation required at this terminal.';
            SELECT @Status AS Status, @Message AS Message, @ShippingLabelId AS ShippingLabelId, @AimShipperId AS AimShipperId;
            RETURN;
        END

        -- ---- full-container check ----
        SET @Accum = (SELECT SUM(PartsClosedCount) FROM Lots.ContainerTray WHERE ContainerId = @ContainerId AND ClosedAt IS NOT NULL);
        IF @TraysPerContainer IS NOT NULL AND @PartsPerTray IS NOT NULL
        BEGIN
            SET @Target = @TraysPerContainer * @PartsPerTray;
            IF ISNULL(@Accum, 0) < @Target
            BEGIN
                SET @Message = N'Container is not full (' + CAST(ISNULL(@Accum, 0) AS NVARCHAR(10)) + N' of ' + CAST(@Target AS NVARCHAR(10)) + N' parts).';
                SELECT @Status AS Status, @Message AS Message, @ShippingLabelId AS ShippingLabelId, @AimShipperId AS AimShipperId;
                RETURN;
            END
            -- Defense-in-depth: an OVER-target accumulation is a data-integrity error, not a
            -- pass. Historically only "< target" rejected, so an over-filled container (the
            -- container-24 incident: 20 parts / 5 trays against a 16-part / 4-tray config)
            -- shipped under one AIM id. Refuse it, leaving the container Open for remediation.
            IF ISNULL(@Accum, 0) > @Target
            BEGIN
                SET @Message = N'Container is over target (' + CAST(ISNULL(@Accum, 0) AS NVARCHAR(10)) + N' of ' + CAST(@Target AS NVARCHAR(10)) + N' parts) -- data integrity error; container left open.';
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container', @EntityId = @ContainerId,
                    @LogEventTypeCode = N'ContainerCompleted', @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @ShippingLabelId AS ShippingLabelId, @AimShipperId AS AimShipperId;
                RETURN;
            END
        END

        -- ---- OI-33 empty-pool hard-fail (BEFORE tran: container stays Open) ----
        IF NOT EXISTS (SELECT 1 FROM Lots.AimShipperIdPool WHERE ConsumedAt IS NULL)
        BEGIN
            SET @Message = N'AIM shipper ID pool is empty. Container left open.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container', @EntityId = @ContainerId,
                @LogEventTypeCode = N'ContainerCompleted', @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ShippingLabelId AS ShippingLabelId, @AimShipperId AS AimShipperId;
            RETURN;
        END

        SET @LabelTypeId = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');

        -- ---- Mutation (atomic): inline AIM claim -> ShippingLabel -> status flip ----
        BEGIN TRANSACTION;

        ;WITH c AS (
            SELECT TOP 1 Id, AimShipperId, ConsumedAt, ConsumedByContainerId, ConsumedByUserId
            FROM Lots.AimShipperIdPool WITH (ROWLOCK, UPDLOCK, READPAST)
            WHERE ConsumedAt IS NULL
            ORDER BY FetchedAt, Id)
        UPDATE c
            SET ConsumedAt = SYSUTCDATETIME(), ConsumedByContainerId = @ContainerId, ConsumedByUserId = @AppUserId
        OUTPUT inserted.Id, inserted.AimShipperId INTO @claimed (Id, AimShipperId);

        SELECT @ClaimedPoolId = Id, @AimShipperId = AimShipperId FROM @claimed;

        -- AIM post-back payload, frozen at completion. Written in the same transaction
        -- as the claim: a rolled-back container never leaves a row owed to AIM.
        DECLARE @PostQty  INT = (SELECT ISNULL(SUM(t.PartsClosedCount), 0)
                                 FROM Lots.ContainerTray t
                                 WHERE t.ContainerId = @ContainerId AND t.ClosedAt IS NOT NULL);
        DECLARE @PostLot  NVARCHAR(50) = (SELECT TOP 1 l.LotName
                                          FROM Lots.ContainerTray t
                                          INNER JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId
                                          WHERE t.ContainerId = @ContainerId
                                          ORDER BY t.TrayPosition);
        -- 2026-08-04: AIM customer part is derived from Item.PartNumber (dash-strip),
        -- not a stored per-item column (Migration 0054; Parts.ufn_AimCustomerPartNumber
        -- header has the evidence). PartNumber is NOT NULL, so this can never be NULL
        -- for a real item.
        DECLARE @PostPart NVARCHAR(50) = (SELECT Parts.ufn_AimCustomerPartNumber(i.PartNumber)
                                          FROM Lots.Container c
                                          INNER JOIN Parts.Item i ON i.Id = c.ItemId
                                          WHERE c.Id = @ContainerId);

        UPDATE Lots.AimShipperIdPool
           SET CustomerPartNumber = @PostPart,
               Quantity           = @PostQty,
               LotNumber          = @PostLot
         WHERE Id = @ClaimedPoolId;

        IF @ClaimedPoolId IS NULL
        BEGIN
            -- lost the race: no-op COMMIT (never ROLLBACK in an INSERT-EXEC-captured proc)
            COMMIT TRANSACTION;
            SET @Status = 0;
            SET @Message = N'AIM shipper ID pool is empty. Container left open.';
            SELECT @Status AS Status, @Message AS Message, @ShippingLabelId AS ShippingLabelId, @AimShipperId AS AimShipperId;
            RETURN;
        END

        -- Mark the container Complete FIRST so the label render resolves CompletedAt ({MfgDate}).
        UPDATE Lots.Container SET ContainerStatusCodeId = 2, CompletedAt = SYSUTCDATETIME() WHERE Id = @ContainerId;

        -- Brief D (LBL-050/060): render the shipping-label ZPL from the active Container
        -- LabelTemplate + tokens (deterministic; a missing template resolves to '') and
        -- persist it on the row so the async dispatcher + stranded-sweep re-send the exact
        -- bytes without re-rendering (survives a Gateway restart between complete and print).
        DECLARE @ShipZpl NVARCHAR(MAX) = Lots.ufn_ShippingLabelZpl(@ContainerId, @AimShipperId);

        INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintedByUserId, TerminalLocationId, ZplContent)
        VALUES (@ContainerId, @AimShipperId, @LabelTypeId, 1, @AppUserId, @TerminalLocationId, @ShipZpl);
        SET @ShippingLabelId = SCOPE_IDENTITY();

        -- FG close (FAT #21): close every linked finished-good LOT (tray = LOT) that is
        -- still Good, now that the container is Complete. Delegates the Good->Closed
        -- transition to the silent Lots.Lot_CloseInline helper (this proc is
        -- INSERT-EXEC-captured, so it cannot EXEC the status-row Lot_UpdateStatus).
        -- Trays with NULL FinishedGoodLotId (pre-0034 / ContainerTray_Close flows) have
        -- no LOT and are skipped by the join; Hold/Scrap FG LOTs are skipped by the
        -- helper's Good-only guard.
        DECLARE fg_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT l.Id
            FROM Lots.ContainerTray t
            INNER JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId
            WHERE t.ContainerId = @ContainerId
              AND t.FinishedGoodLotId IS NOT NULL
              AND l.LotStatusId = 1;   -- Good
        OPEN fg_cur;
        FETCH NEXT FROM fg_cur INTO @FgLotId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC Lots.Lot_CloseInline
                @LotId = @FgLotId,
                @Reason = N'Closed on container completion (finished-goods packed & shipping-ready).',
                @AppUserId = @AppUserId,
                @TerminalLocationId = @TerminalLocationId;
            FETCH NEXT FROM fg_cur INTO @FgLotId;
        END
        CLOSE fg_cur; DEALLOCATE fg_cur;

        SET @Activity = Audit.ufn_TruncateActivity(N'Container #' + CAST(@ContainerId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot()
            + N' AIM ' + @AimShipperId + N' ' + Audit.ufn_MidDot() + N' Completed');
        SET @NewValue = (SELECT @ContainerId AS ContainerId, @AimShipperId AS AimShipperId, @ShippingLabelId AS ShippingLabelId,
            @Accum AS AccumulatedParts FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'Container', @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerCompleted',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Container completed; AIM ' + @AimShipperId + N' claimed.';
        SELECT @Status AS Status, @Message AS Message, @ShippingLabelId AS ShippingLabelId, @AimShipperId AS AimShipperId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @ShippingLabelId = NULL;
        SET @AimShipperId = NULL;

        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container', @EntityId = @ContainerId,
                @LogEventTypeCode = N'ContainerCompleted', @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @ShippingLabelId AS ShippingLabelId, @AimShipperId AS AimShipperId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
