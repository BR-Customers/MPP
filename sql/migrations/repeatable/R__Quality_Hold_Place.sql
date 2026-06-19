-- ============================================================
-- Repeatable:  R__Quality_Hold_Place.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Places a hold on a single LOT or a single Container (Arc 2 Phase 7;
--              FDS-08-007a). Exactly one of @LotId / @ContainerId. B3: rejects if an
--              open hold already exists for the target (clean pre-check before the
--              filtered-unique). For a LOT, transitions LotStatusId -> Hold (2,
--              BlocksProduction=1) + LotStatusHistory; for a Container, sets status ->
--              Hold (4). Audits 'HoldPlaced' (entity HoldEvent). The Hold Management
--              view loops this for multi-select; AIM PlaceOnHold for shipped containers
--              is a Gateway-async step (A6). No OUTPUT params (FDS-11-011); single
--              terminal SELECT @Status,@Message,@NewId. RAISERROR in the CATCH.
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.Hold_Place
    @LotId              BIGINT = NULL,
    @ContainerId        BIGINT = NULL,
    @HoldTypeCodeId     BIGINT,
    @Reason             NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Quality.Hold_Place';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @LotId AS LotId, @ContainerId AS ContainerId,
        @HoldTypeCodeId AS HoldTypeCodeId, @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @CurrentLotStatus BIGINT, @Subject NVARCHAR(100), @Activity NVARCHAR(500), @NewValue NVARCHAR(MAX);

    BEGIN TRY
        -- ---- Tier 1: exactly one target + required params ----
        IF @HoldTypeCodeId IS NULL OR @AppUserId IS NULL
            OR (@LotId IS NULL AND @ContainerId IS NULL)
            OR (@LotId IS NOT NULL AND @ContainerId IS NOT NULL)
        BEGIN
            SET @Message = N'Provide exactly one of LotId/ContainerId plus HoldTypeCodeId + AppUserId.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- Tier 2: referential validation ----
        IF NOT EXISTS (SELECT 1 FROM Quality.HoldTypeCode WHERE Id = @HoldTypeCodeId)
        BEGIN
            SET @Message = N'Hold type code not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @LotId IS NOT NULL
        BEGIN
            SELECT @CurrentLotStatus = LotStatusId FROM Lots.Lot WHERE Id = @LotId;
            IF @CurrentLotStatus IS NULL
            BEGIN
                SET @Message = N'LOT not found.';
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END
            IF EXISTS (SELECT 1 FROM Quality.HoldEvent WHERE LotId = @LotId AND ReleasedAt IS NULL)
            BEGIN
                SET @Message = N'An open hold already exists on this LOT.';
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'HoldEvent', @EntityId = @LotId,
                    @LogEventTypeCode = N'HoldPlaced', @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END
            SET @Subject = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM Lots.Container WHERE Id = @ContainerId)
            BEGIN
                SET @Message = N'Container not found.';
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END
            IF EXISTS (SELECT 1 FROM Quality.HoldEvent WHERE ContainerId = @ContainerId AND ReleasedAt IS NULL)
            BEGIN
                SET @Message = N'An open hold already exists on this container.';
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'HoldEvent', @EntityId = @ContainerId,
                    @LogEventTypeCode = N'HoldPlaced', @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END
            SET @Subject = N'Container #' + CAST(@ContainerId AS NVARCHAR(20));
        END

        SET @Activity = Audit.ufn_TruncateActivity(@Subject + N' ' + Audit.ufn_MidDot() + N' Hold ' + Audit.ufn_MidDot() + N' Placed');
        SET @NewValue = (SELECT @LotId AS LotId, @ContainerId AS ContainerId,
            JSON_QUERY((SELECT h.Id, h.Code FROM Quality.HoldTypeCode h WHERE h.Id = @HoldTypeCodeId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS HoldType,
            @Reason AS Reason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ---- Mutation (atomic) ----
        BEGIN TRANSACTION;

        INSERT INTO Quality.HoldEvent (LotId, ContainerId, HoldTypeCodeId, Reason, PlacedByUserId, PlacedAt)
        VALUES (@LotId, @ContainerId, @HoldTypeCodeId, @Reason, @AppUserId, SYSUTCDATETIME());
        SET @NewId = SCOPE_IDENTITY();

        IF @LotId IS NOT NULL
        BEGIN
            UPDATE Lots.Lot SET LotStatusId = 2 WHERE Id = @LotId;  -- 2 = Hold (BlocksProduction=1)
            INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
            VALUES (@LotId, @CurrentLotStatus, 2, @Reason, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        END
        ELSE
        BEGIN
            UPDATE Lots.Container SET ContainerStatusCodeId = 4 WHERE Id = @ContainerId;  -- 4 = Hold
        END

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'HoldEvent', @EntityId = @NewId, @LogEventTypeCode = N'HoldPlaced',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Hold placed.';
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
