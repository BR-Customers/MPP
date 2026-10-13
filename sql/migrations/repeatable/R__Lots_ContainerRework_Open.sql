-- ============================================================
-- Repeatable:  R__Lots_ContainerRework_Open.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: Opens a COMPLETED, unshipped container for rework (super-lot piece 4):
--              Complete -> ReworkProcessing. From this moment the container is not
--              shippable by status as well as by tag, and its parts can be scrapped
--              or moved by the other Lots.ContainerRework_* procs.
--
--              Any Complete container may be opened, super-lot member or not: a clean
--              finished container is a legal DONOR for topping another one up (spec D2).
--              A container on a real hold (status Hold) is refused -- release the hold
--              first; a hold and a rework are separate things.
--
--              In one transaction:
--                * a Lots.ContainerRework row records what the container was (when it
--                  completed, its serial and label, its piece count);
--                * every live shipping label of the container is voided (INLINED MIRROR
--                  of Lots.ShippingLabel_Void, source of truth R__Lots_ShippingLabel_
--                  Void.sql) -- the paper label is still on the box; a person removes it;
--                * the container's live AIM pool row is marked VoidedAt, POSTED OR NOT.
--                  Nothing is sent to AIM (spec D3). An unposted voided serial must
--                  never be posted: AimShipperIdPool_ListUnposted skips voided rows;
--                * CompletedAt is cleared (Lots.Container_Complete sets it again), which
--                  also takes the container out of Container_ListPendingValidation /
--                  Container_ValidateCrt: a container under rework is not validated one
--                  at a time.
--
--              The tray LOTs are NOT reopened (spec D5): they stay Closed and keep their
--              CRT tag.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting validation
--              runs before BEGIN TRANSACTION; CATCH is the only ROLLBACK site.
--              Returns Status, Message, NewId (the ContainerRework row).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ContainerRework_Open
    @ContainerId        BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.ContainerRework_Open';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ContainerId AS ContainerId, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @StatusCode NVARCHAR(50), @CompletedAt DATETIME2(3), @Pieces INT, @Serial NVARCHAR(50), @LabelId BIGINT;
    SELECT @StatusCode = cs.Code, @CompletedAt = c.CompletedAt
    FROM Lots.Container c INNER JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId
    WHERE c.Id = @ContainerId;
    SET @Pieces = ISNULL((SELECT SUM(t.PartsClosedCount) FROM Lots.ContainerTray t
                          WHERE t.ContainerId = @ContainerId AND t.ClosedAt IS NOT NULL), 0);
    SELECT TOP 1 @Serial = p.AimShipperId FROM Lots.AimShipperIdPool p
    WHERE p.ConsumedByContainerId = @ContainerId AND p.VoidedAt IS NULL ORDER BY p.ConsumedAt DESC, p.Id DESC;
    SELECT TOP 1 @LabelId = sl.Id FROM Lots.ShippingLabel sl
    WHERE sl.ContainerId = @ContainerId AND sl.IsVoid = 0 ORDER BY sl.Id DESC;

    BEGIN TRY
        DECLARE @Reject NVARCHAR(500) = NULL;
        IF @ContainerId IS NULL OR @AppUserId IS NULL
            SET @Reject = N'Required parameter missing (ContainerId, AppUserId).';
        IF @Reject IS NULL AND NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId AND DeprecatedAt IS NULL)
            SET @Reject = N'User not found.';
        IF @Reject IS NULL AND @StatusCode IS NULL
            SET @Reject = N'Container not found.';
        IF @Reject IS NULL AND @StatusCode = N'Hold'
            SET @Reject = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' is on hold. Release the hold before reworking it.';
        IF @Reject IS NULL AND @StatusCode IN (N'ReworkProcessing', N'ReworkFilling')
            SET @Reject = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' is already open for rework.';
        IF @Reject IS NULL AND @StatusCode <> N'Complete'
            SET @Reject = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' is ' + @StatusCode + N'. Only a completed, unshipped container can be opened for rework.';

        IF @Reject IS NOT NULL
        BEGIN
            SET @Message = @Reject;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerRework',
                    @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerReworkOpened',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        UPDATE Lots.Container
        SET ContainerStatusCodeId = 6 /* ReworkProcessing */, CompletedAt = NULL
        WHERE Id = @ContainerId AND ContainerStatusCodeId = 2 /* Complete */;
        IF @@ROWCOUNT = 0
            RAISERROR(N'Container was changed by someone else.', 16, 1);

        INSERT INTO Lots.ContainerRework
            (ContainerId, OpenedByUserId, OpenedAtTerminalId, OriginalCompletedAt, OriginalAimShipperId,
             OriginalShippingLabelId, OriginalPieceCount)
        VALUES (@ContainerId, @AppUserId, @TerminalLocationId, @CompletedAt, @Serial, @LabelId, @Pieces);
        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- ---- labels: INLINED MIRROR of Lots.ShippingLabel_Void, one audit row each ----
        DECLARE @Voided TABLE (Id BIGINT NOT NULL);
        UPDATE Lots.ShippingLabel
        SET IsVoid = 1, VoidedAt = SYSUTCDATETIME(), VoidedByUserId = @AppUserId
        OUTPUT inserted.Id INTO @Voided (Id)
        WHERE ContainerId = @ContainerId AND IsVoid = 0;

        DECLARE @Lbl BIGINT, @Act NVARCHAR(500), @ActRaw NVARCHAR(MAX);
        DECLARE lbl_cur CURSOR LOCAL FAST_FORWARD FOR SELECT Id FROM @Voided ORDER BY Id;
        OPEN lbl_cur;
        FETCH NEXT FROM lbl_cur INTO @Lbl;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ActRaw = N'Label #' + CAST(@Lbl AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot() + N' Voided (container '
                        + CAST(@ContainerId AS NVARCHAR(20)) + N' opened for rework)';
            SET @Act = Audit.ufn_TruncateActivity(@ActRaw);
            EXEC Audit.Audit_LogOperation
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
                @LogEntityTypeCode = N'ShippingLabel', @EntityId = @Lbl, @LogEventTypeCode = N'ShippingLabelVoided',
                @LogSeverityCode = N'Info', @Description = @Act, @OldValue = NULL, @NewValue = NULL;
            FETCH NEXT FROM lbl_cur INTO @Lbl;
        END
        CLOSE lbl_cur; DEALLOCATE lbl_cur;

        -- ---- the serial: voided on our side only (spec D3) ----
        UPDATE Lots.AimShipperIdPool
        SET VoidedAt = SYSUTCDATETIME(), VoidedByUserId = @AppUserId, VoidReason = N'Container opened for rework'
        WHERE ConsumedByContainerId = @ContainerId AND VoidedAt IS NULL;

        SET @ActRaw = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot() + N' Rework '
                    + Audit.ufn_MidDot() + N' Opened' + CASE WHEN @Serial IS NOT NULL THEN N'; serial ' + @Serial + N' voided' ELSE N'' END;
        SET @Act = Audit.ufn_TruncateActivity(@ActRaw);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT @NewId AS ContainerReworkId, @ContainerId AS ContainerId, N'ReworkProcessing' AS Status,
                   @Serial AS VoidedAimShipperId, @LabelId AS VoidedShippingLabelId, @Pieces AS PieceCount
            FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'ContainerRework', @EntityId = @NewId, @LogEventTypeCode = N'ContainerReworkOpened',
            @LogSeverityCode = N'Info', @Description = @Act, @OldValue = N'{"Status":"Complete"}', @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' opened for rework.'
                     + CASE WHEN @Serial IS NOT NULL THEN N' Serial ' + @Serial + N' is voided; remove the old label.' ELSE N'' END;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @NewId   = NULL;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerRework',
                    @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerReworkOpened',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
