-- ============================================================
-- Repeatable:  R__Lots_ContainerTray_Close.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Closes a tray within an open Container (Arc 2 Phase 6; FDS-06-014).
--              Validates @PartsCount against the ContainerConfig.PartsPerTray, derives the
--              ClosureMethod from the same ContainerConfig (NOT operator-entered) and returns the container's
--              accumulated parts across closed trays. On each tray close it also writes one
--              Workorder.ConsumptionEvent per BOM component (ProducedContainerId + TrayId),
--              FIFO-decrementing the source component LOTs at the cell (FDS-06-013) -- the
--              produced side is the container, no output LOT. One tray per (Container,TrayPosition)
--              -- a re-close rejects. Audits 'TrayClosed'. No OUTPUT params (FDS-11-011);
--              single terminal SELECT @Status,@Message,@NewId,@ContainerAccumulatedParts.
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

        -- ---- assembly consumption (FDS-06-013/014): resolve the container item's active
        --      published BOM + verify each component is available at the cell (per-tray need
        --      = PartsPerTray x QtyPer). The produced side of the consumption is the container. ----
        DECLARE @ItemId BIGINT, @CellId BIGINT;
        SELECT @ItemId = ItemId, @CellId = CurrentLocationId FROM Lots.Container WHERE Id = @ContainerId;
        DECLARE @BomId BIGINT = (SELECT TOP 1 Id FROM Parts.Bom
            WHERE ParentItemId = @ItemId AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL
            ORDER BY VersionNumber DESC);
        IF @BomId IS NULL
        BEGIN
            SET @Message = N'No active published BOM for the container item; cannot record assembly consumption.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Accum AS ContainerAccumulatedParts;
            RETURN;
        END
        DECLARE @ShortChild NVARCHAR(50) =
            (SELECT TOP 1 ci.PartNumber
             FROM Parts.BomLine bl
             INNER JOIN Parts.Item ci ON ci.Id = bl.ChildItemId
             OUTER APPLY (SELECT ISNULL(SUM(l.PieceCount), 0) AS Avail FROM Lots.Lot l
                          INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                          WHERE l.CurrentLocationId = @CellId AND l.ItemId = bl.ChildItemId AND sc.Code <> N'Closed') a
             WHERE bl.BomId = @BomId AND a.Avail < CAST(@PartsCount * bl.QtyPer AS INT));
        IF @ShortChild IS NOT NULL
        BEGIN
            SET @Message = N'Insufficient ' + @ShortChild + N' at this cell to fill the tray.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Accum AS ContainerAccumulatedParts;
            RETURN;
        END

        SET @Activity = Audit.ufn_TruncateActivity(N'Container #' + CAST(@ContainerId AS NVARCHAR(20)) + N' tray ' + CAST(@TrayPosition AS NVARCHAR(10))
            + N' ' + Audit.ufn_MidDot() + N' ' + @ClosureMethod + N' ' + Audit.ufn_MidDot() + N' Closed');

        -- ---- Mutation (atomic) ----
        BEGIN TRANSACTION;

        INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod)
        VALUES (@ContainerId, @TrayPosition, @PartsCount, SYSUTCDATETIME(), @AppUserId, @ClosureMethod);

        SET @NewId = SCOPE_IDENTITY();
        SET @Accum = (SELECT SUM(PartsClosedCount) FROM Lots.ContainerTray WHERE ContainerId = @ContainerId AND ClosedAt IS NOT NULL);

        -- ---- per-tray BOM consumption: one ConsumptionEvent per component, FIFO-decrementing
        --      source LOTs at the cell; produced side = the container (ProducedContainerId, TrayId). ----
        DECLARE @ClosedStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
        DECLARE @ChildItemId BIGINT, @ChildQtyPer DECIMAL(18,4), @NeedRemain INT, @SrcLotId BIGINT, @SrcAvail INT, @SrcStatus BIGINT, @Take INT;
        DECLARE bom_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT bl.ChildItemId, bl.QtyPer FROM Parts.BomLine bl WHERE bl.BomId = @BomId;
        OPEN bom_cur;
        FETCH NEXT FROM bom_cur INTO @ChildItemId, @ChildQtyPer;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @NeedRemain = CAST(@PartsCount * @ChildQtyPer AS INT);
            WHILE @NeedRemain > 0
            BEGIN
                SET @SrcLotId = NULL;
                SELECT TOP 1 @SrcLotId = l.Id, @SrcAvail = l.PieceCount, @SrcStatus = l.LotStatusId
                FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                WHERE l.CurrentLocationId = @CellId AND l.ItemId = @ChildItemId AND sc.Code <> N'Closed' AND l.PieceCount > 0
                ORDER BY l.CreatedAt, l.Id;
                IF @SrcLotId IS NULL BREAK;  -- defensive; the pre-txn availability check prevents this
                SET @Take = CASE WHEN @SrcAvail <= @NeedRemain THEN @SrcAvail ELSE @NeedRemain END;
                UPDATE Lots.Lot SET PieceCount = PieceCount - @Take WHERE Id = @SrcLotId;
                IF (@SrcAvail - @Take) = 0
                BEGIN
                    UPDATE Lots.Lot SET LotStatusId = @ClosedStatusId WHERE Id = @SrcLotId;
                    INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
                    VALUES (@SrcLotId, @SrcStatus, @ClosedStatusId, N'Closed by assembly consumption (all pieces consumed).', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
                END
                INSERT INTO Workorder.ConsumptionEvent
                    (SourceLotId, ProducedContainerId, ConsumedItemId, ProducedItemId, PieceCount, LocationId, AppUserId, TerminalLocationId, TrayId, ConsumedAt)
                VALUES (@SrcLotId, @ContainerId, @ChildItemId, @ItemId, @Take, @CellId, @AppUserId, @TerminalLocationId, @NewId, SYSUTCDATETIME());
                SET @NeedRemain = @NeedRemain - @Take;
            END
            FETCH NEXT FROM bom_cur INTO @ChildItemId, @ChildQtyPer;
        END
        CLOSE bom_cur; DEALLOCATE bom_cur;

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
