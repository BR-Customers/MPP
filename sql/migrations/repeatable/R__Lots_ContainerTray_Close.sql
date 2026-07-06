-- ============================================================
-- Repeatable:  R__Lots_ContainerTray_Close.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Closes a tray within an open Container (Arc 2 Phase 6; FDS-06-014).
--              Validates @PartsCount against the ContainerConfig.PartsPerTray, derives the
--              ClosureMethod from the same ContainerConfig (NOT operator-entered) and returns the container's
--              accumulated parts across closed trays. One tray per (Container,TrayPosition)
--              -- a re-close rejects. Audits 'TrayClosed'. No OUTPUT params (FDS-11-011);
--              single terminal SELECT @Status,@Message,@NewId,@ContainerAccumulatedParts.
--
--              *** NO BOM CONSUMPTION (Spec 2, Task A3, 2026-07-06) ***
--              This proc is now a thin tray-insert / accumulation helper. Component
--              consumption for non-serialized assembly moved to
--              Workorder.Assembly_CompleteTray (which mints the finished-good LOT and
--              consumes BOM x PieceCount FIFO INTO that LOT). ContainerTray_Close is
--              retained for the container-completion / shipping test flows that fill a
--              container without minting a LOT; it no longer writes ConsumptionEvents nor
--              checks component availability (Assembly_CompleteTray owns that).
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.ContainerTray_Close
    @ContainerId        BIGINT,
    @TrayPosition       INT,
    @PartsCount         INT,
    @ClosureMethod      NVARCHAR(20) = NULL,
    @AppUserId          BIGINT = NULL,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status   BIT           = 0;
    DECLARE @Message  NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId    BIGINT        = NULL;
    DECLARE @Accum    INT           = NULL;

    DECLARE @PartsPerTray INT;
    DECLARE @StatusCode   BIGINT;
    DECLARE @Activity     NVARCHAR(500);

    BEGIN TRY
        -- ---- Tier 1 ----
        IF @ContainerId IS NULL OR @TrayPosition IS NULL OR @PartsCount IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ContainerId, TrayPosition, PartsCount).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Accum AS ContainerAccumulatedParts;
            RETURN;
        END

        -- ---- Tier 2: container open + config (ClosureMethod is determined by the part's
        --      ContainerConfig -- the operator does not select it) ----
        SELECT @StatusCode = ct.ContainerStatusCodeId, @PartsPerTray = cc.PartsPerTray,
               @ClosureMethod = COALESCE(cc.ClosureMethod, @ClosureMethod, N'ByCount')
        FROM Lots.Container ct
        INNER JOIN Parts.ContainerConfig cc ON cc.Id = ct.ContainerConfigId
        WHERE ct.Id = @ContainerId;

        IF @StatusCode IS NULL
        BEGIN
            SET @Message = N'Container not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Accum AS ContainerAccumulatedParts;
            RETURN;
        END
        IF @StatusCode <> 1  -- 1 = Open
        BEGIN
            SET @Message = N'Container is not open.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Accum AS ContainerAccumulatedParts;
            RETURN;
        END

        IF @ClosureMethod NOT IN (N'ByCount', N'ByWeight', N'ByVision')
        BEGIN
            SET @Message = N'Configured ClosureMethod (' + ISNULL(@ClosureMethod, N'(none)') + N') is invalid for this container.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Accum AS ContainerAccumulatedParts;
            RETURN;
        END

        -- ---- count must match the configured tray size ----
        IF @PartsPerTray IS NOT NULL AND @PartsCount <> @PartsPerTray
        BEGIN
            SET @Message = N'Tray parts count (' + CAST(@PartsCount AS NVARCHAR(10)) + N') does not match configured PartsPerTray (' + CAST(@PartsPerTray AS NVARCHAR(10)) + N').';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Accum AS ContainerAccumulatedParts;
            RETURN;
        END

        -- ---- one tray per position ----
        IF EXISTS (SELECT 1 FROM Lots.ContainerTray WHERE ContainerId = @ContainerId AND TrayPosition = @TrayPosition)
        BEGIN
            SET @Message = N'Tray position ' + CAST(@TrayPosition AS NVARCHAR(10)) + N' is already closed for this container.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Accum AS ContainerAccumulatedParts;
            RETURN;
        END

        -- (Component consumption + availability check removed in A3 -- see header.
        --  Assembly_CompleteTray owns FIFO consumption into the minted finished-good LOT.)

        SET @Activity = Audit.ufn_TruncateActivity(N'Container #' + CAST(@ContainerId AS NVARCHAR(20)) + N' tray ' + CAST(@TrayPosition AS NVARCHAR(10))
            + N' ' + Audit.ufn_MidDot() + N' ' + @ClosureMethod + N' ' + Audit.ufn_MidDot() + N' Closed');

        -- ---- Mutation (atomic) ----
        BEGIN TRANSACTION;

        INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod)
        VALUES (@ContainerId, @TrayPosition, @PartsCount, SYSUTCDATETIME(), @AppUserId, @ClosureMethod);

        SET @NewId = SCOPE_IDENTITY();
        SET @Accum = (SELECT SUM(PartsClosedCount) FROM Lots.ContainerTray WHERE ContainerId = @ContainerId AND ClosedAt IS NOT NULL);

        DECLARE @NewValue NVARCHAR(MAX) = (SELECT @ContainerId AS ContainerId, @TrayPosition AS TrayPosition,
            @PartsCount AS PartsClosedCount, @ClosureMethod AS ClosureMethod, @Accum AS ContainerAccumulatedParts
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'ContainerTray', @EntityId = @NewId, @LogEventTypeCode = N'TrayClosed',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Tray closed.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Accum AS ContainerAccumulatedParts;
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
        SET @Accum = NULL;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Accum AS ContainerAccumulatedParts;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
