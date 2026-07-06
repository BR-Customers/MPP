-- ============================================================
-- Repeatable:  R__Workorder_Assembly_CompleteTray.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Arc 2 machining/assembly flow reconciliation (Spec 2, Task A2).
--              Assembly-out orchestrator: on tray completion it MINTS a
--              finished-good LOT (tray = LOT), consumes BOM x PieceCount FIFO from
--              the component stock at the cell INTO that LOT, and attaches the tray
--              to the cell's open Container (auto-opening one if none is open). It
--              reports whether the container is now FULL via @ContainerFull; it does
--              NOT complete the container -- AIM shipper-id claim + ShippingLabel +
--              the OI-16 confirm gate stay with the existing Lots.Container_Complete
--              proc, which the assembly view calls as step 2 when @ContainerFull = 1
--              (delegation decision 2026-07-06; honors "pending AIM").
--
--              *** WHY EVERY SUB-MUTATION IS INLINED ***
--              This is a status-row proc captured via INSERT-EXEC, so it CANNOT EXEC
--              Lots.Lot_Create (mint), Lots.Container_Open, or
--              Workorder.ConsumptionEvent_RecordWithBomCheck -- each emits a status-row
--              SELECT that would pollute this proc's single result set, and nesting
--              INSERT-EXEC is illegal. So: the FG-LOT mint MIRRORS R__Lots_Lot_Create
--              (inline IdentifierSequence 'Lot' mint, LotStatusHistory Old=NULL/New='Good',
--              closure self-row Depth=0, first LotMovement From=NULL), the container
--              auto-open MIRRORS R__Lots_Container_Open, and each component consume
--              MIRRORS R__Workorder_ConsumptionEvent_RecordWithBomCheck (Consumption
--              edge RelationshipTypeId=3 + closure ancestors->FG LOT). Each inline
--              block is commented as a mirror of its source-of-truth proc.
--
--              ALL rejecting validations run BEFORE BEGIN TRANSACTION (SELECT the
--              status row + RETURN, no open txn) because a ROLLBACK inside an
--              INSERT-EXEC-captured proc throws Msg 3915 -- the CATCH (a doomed
--              XACT_ABORT exception) is the ONLY legal ROLLBACK site. The in-txn
--              "component drained mid-consume" RAISERROR is the authoritative stock
--              re-check; it routes to the CATCH -> clean Status 0.
--
--              B1 context params. No OUTPUT params (FDS-11-011); single terminal SELECT
--              Status, Message, FinishedGoodLotId, ContainerId, ContainerTrayId,
--              ContainerFull. RAISERROR (not THROW) in the CATCH.
-- ============================================================

CREATE OR ALTER PROCEDURE Workorder.Assembly_CompleteTray
    @FinishedGoodItemId BIGINT,
    @PieceCount         INT,
    @CellLocationId     BIGINT,
    @ClosureMethod      NVARCHAR(20) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status          BIT           = 0;
    DECLARE @Message         NVARCHAR(500) = N'Unknown error';
    DECLARE @FinishedGoodLotId BIGINT      = NULL;
    DECLARE @ContainerId     BIGINT        = NULL;
    DECLARE @ContainerTrayId BIGINT        = NULL;
    DECLARE @ContainerFull   BIT           = 0;

    DECLARE @ProcName NVARCHAR(200) = N'Workorder.Assembly_CompleteTray';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @FinishedGoodItemId AS FinishedGoodItemId, @PieceCount AS PieceCount,
               @CellLocationId AS CellLocationId, @ClosureMethod AS ClosureMethod,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- resolved code-table ids (literals-or-variables only in EXEC; no inline CAST)
    DECLARE @GoodStatusId         BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @ClosedStatusId       BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
    DECLARE @ManufacturedOriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

    DECLARE @ContainerConfigId BIGINT, @PartsPerTray INT, @TraysPerContainer INT, @MaxLotSize INT;
    DECLARE @BomId BIGINT, @CellCode NVARCHAR(50), @PartNumber NVARCHAR(50);
    DECLARE @Accum INT, @Target INT, @TrayPosition INT;
    DECLARE @OpenedContainer BIT = 0;

    -- FG-LOT mint locals (mirror R__Lots_Lot_Create)
    DECLARE @MintedName NVARCHAR(50),
            @SeqLast BIGINT, @SeqEnd BIGINT, @SeqFormat NVARCHAR(50), @SeqPrefix NVARCHAR(50), @SeqPad INT;

    -- BOM consume locals
    DECLARE @ChildItemId BIGINT, @ChildQtyPer DECIMAL(18,4), @NeedRemain INT,
            @SrcLotId BIGINT, @SrcAvail INT, @SrcPieceCount INT, @SrcStatus BIGINT, @Take INT;

    DECLARE @Activity NVARCHAR(500), @NewValue NVARCHAR(MAX);

    BEGIN TRY
        -- ================= Pre-transaction validations (no open txn) =================

        -- ---- 1. Required parameters ----
        IF @FinishedGoodItemId IS NULL OR @PieceCount IS NULL OR @CellLocationId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (FinishedGoodItemId, PieceCount, CellLocationId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerTray',
                    @EntityId = NULL, @LogEventTypeCode = N'TrayClosed', @FailureReason = @Message,
                    @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            GOTO Reply;
        END

        -- ---- 2. PieceCount sanity ----
        IF @PieceCount <= 0
        BEGIN
            SET @Message = N'PieceCount must be a positive integer.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerTray',
                @EntityId = NULL, @LogEventTypeCode = N'TrayClosed', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            GOTO Reply;
        END

        -- ---- 3. FG Item eligible at the cell (mirror Lot_Create eligibility cascade) ----
        IF NOT EXISTS (
            SELECT 1 FROM Parts.v_EffectiveItemLocation
            WHERE ItemId = @FinishedGoodItemId
              AND LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@CellLocationId)))
        BEGIN
            SET @Message = N'Finished-good Item is not eligible at this cell.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerTray',
                @EntityId = NULL, @LogEventTypeCode = N'TrayClosed', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            GOTO Reply;
        END

        -- ---- 4. Active ContainerConfig for the FG Item (tray/container sizing) ----
        SELECT TOP 1 @ContainerConfigId = cc.Id, @PartsPerTray = cc.PartsPerTray,
               @TraysPerContainer = cc.TraysPerContainer,
               @ClosureMethod = COALESCE(cc.ClosureMethod, @ClosureMethod, N'ByCount')
        FROM Parts.ContainerConfig cc
        WHERE cc.ItemId = @FinishedGoodItemId AND cc.DeprecatedAt IS NULL
        ORDER BY cc.Id DESC;

        IF @ContainerConfigId IS NULL
        BEGIN
            SET @Message = N'No container configuration for the finished-good Item.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerTray',
                @EntityId = NULL, @LogEventTypeCode = N'TrayClosed', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            GOTO Reply;
        END

        IF @ClosureMethod NOT IN (N'ByCount', N'ByWeight', N'ByVision')
        BEGIN
            SET @Message = N'Configured ClosureMethod (' + ISNULL(@ClosureMethod, N'(none)') + N') is invalid for this container.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerTray',
                @EntityId = NULL, @LogEventTypeCode = N'TrayClosed', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            GOTO Reply;
        END

        -- ---- 5. Tray parts count must match the configured PartsPerTray (tray = LOT) ----
        IF @PartsPerTray IS NOT NULL AND @PieceCount <> @PartsPerTray
        BEGIN
            SET @Message = N'Tray parts count (' + CAST(@PieceCount AS NVARCHAR(10))
                         + N') does not match configured PartsPerTray (' + CAST(@PartsPerTray AS NVARCHAR(10)) + N').';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerTray',
                @EntityId = NULL, @LogEventTypeCode = N'TrayClosed', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            GOTO Reply;
        END

        -- ---- 6. Active BOM must exist ----
        SET @BomId = (SELECT TOP 1 Id FROM Parts.Bom
            WHERE ParentItemId = @FinishedGoodItemId AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL
            ORDER BY VersionNumber DESC);
        IF @BomId IS NULL
        BEGIN
            SET @Message = N'No active BOM for the finished-good Item.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerTray',
                @EntityId = NULL, @LogEventTypeCode = N'TrayClosed', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            GOTO Reply;
        END

        -- ---- 7. Pre-check FIFO stock sufficiency for every BOM line (advisory; the
        --      in-txn drained-mid-consume RAISERROR is authoritative) ----
        IF EXISTS (
            SELECT 1 FROM Parts.BomLine bl
            OUTER APPLY (
                SELECT ISNULL(SUM(l.InventoryAvailable), 0) AS Avail FROM Lots.Lot l
                INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                WHERE l.ItemId = bl.ChildItemId AND l.CurrentLocationId = @CellLocationId AND sc.Code <> N'Closed'
            ) s
            WHERE bl.BomId = @BomId AND s.Avail < CAST(bl.QtyPer * @PieceCount AS INT))
        BEGIN
            SET @Message = N'Insufficient component stock at the line for one or more BOM lines.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerTray',
                @EntityId = NULL, @LogEventTypeCode = N'TrayClosed', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            GOTO Reply;
        END

        SET @MaxLotSize  = (SELECT MaxLotSize FROM Parts.Item WHERE Id = @FinishedGoodItemId);
        SET @PartNumber  = (SELECT PartNumber FROM Parts.Item WHERE Id = @FinishedGoodItemId);
        SET @CellCode    = (SELECT Code FROM Location.Location WHERE Id = @CellLocationId);

        -- ================= Mutation (atomic) =================
        BEGIN TRANSACTION;

        -- ---- B1. Mint the finished-good LOT (mirror R__Lots_Lot_Create) ----
        -- Inline IdentifierSequence 'Lot' mint INSIDE the tran (rollback un-burns the
        -- counter, the point of B6); logic mirrors Lots.IdentifierSequence_Next.
        SELECT @SeqLast = s.LastValue + 1, @SeqEnd = s.EndingValue, @SeqFormat = s.FormatString
        FROM Lots.IdentifierSequence s WITH (ROWLOCK, UPDLOCK, HOLDLOCK)
        WHERE s.Code = N'Lot';
        IF @SeqLast IS NULL  RAISERROR(N'Identifier sequence ''Lot'' is not configured.', 16, 1);
        IF @SeqLast > @SeqEnd RAISERROR(N'Identifier sequence ''Lot'' is exhausted.', 16, 1);
        UPDATE Lots.IdentifierSequence SET LastValue = @SeqLast, UpdatedAt = SYSUTCDATETIME() WHERE Code = N'Lot';
        SET @SeqPrefix = CASE WHEN CHARINDEX(N'{', @SeqFormat) > 0
                              THEN LEFT(@SeqFormat, CHARINDEX(N'{', @SeqFormat) - 1) ELSE @SeqFormat END;
        SET @SeqPad = TRY_CAST(SUBSTRING(@SeqFormat,
                          CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) + 1,
                          CHARINDEX(N'}', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - 1) AS INT);
        SET @MintedName = CASE WHEN @SeqPad IS NULL OR @SeqPad < 1
            THEN @SeqPrefix + CAST(@SeqLast AS NVARCHAR(20))
            ELSE @SeqPrefix + RIGHT(REPLICATE(N'0', @SeqPad) + CAST(@SeqLast AS NVARCHAR(20)), @SeqPad) END;

        -- FG assembly LOT: origin Manufactured, at the cell, Tool/Cavity NULL (not
        -- die-cast; no ToolAssignment at an assembly cell), B5 materialized 0/@PieceCount.
        INSERT INTO Lots.Lot (
            LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            Weight, WeightUomId, ToolId, ToolCavityId, CavityNumber, VendorLotNumber,
            MinSerialNumber, MaxSerialNumber, CurrentLocationId,
            TotalInProcess, InventoryAvailable,
            CreatedByUserId, CreatedAtTerminalId, CreatedAt)
        VALUES (
            @MintedName, @FinishedGoodItemId, @ManufacturedOriginId, @GoodStatusId, @PieceCount, @MaxLotSize,
            NULL, NULL, NULL, NULL, NULL, NULL,
            NULL, NULL, @CellLocationId,
            0, @PieceCount,
            @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        SET @FinishedGoodLotId = SCOPE_IDENTITY();

        -- side effects mirror Lot_Create: status-history / closure self-row / first placement
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@FinishedGoodLotId, NULL, @GoodStatusId, N'Finished-good LOT minted by assembly tray completion.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
        VALUES (@FinishedGoodLotId, @FinishedGoodLotId, 0);
        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@FinishedGoodLotId, NULL, @CellLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- FG-LOT birth audit (mirror Lot_Create's LotCreated so the LOT history timeline has it)
        SET @NewValue = (SELECT l.Id, l.LotName, l.PieceCount,
                JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id = l.ItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = l.CurrentLocationId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location
            FROM Lots.Lot l WHERE l.Id = @FinishedGoodLotId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Activity = Audit.ufn_TruncateActivity(@MintedName + N' ' + Audit.ufn_MidDot() + N' Lot ' + Audit.ufn_MidDot()
            + N' Minted at ' + ISNULL(@CellCode, N'?') + N' by assembly (' + @PartNumber + N', ' + CAST(@PieceCount AS NVARCHAR(20)) + N' pcs)');
        EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @CellLocationId,
            @LogEntityTypeCode = N'Lot', @EntityId = @FinishedGoodLotId, @LogEventTypeCode = N'LotCreated',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        -- ---- B2. Container: find the cell's open container for this Item, else
        --      auto-open one (mirror R__Lots_Container_Open) ----
        SELECT TOP 1 @ContainerId = Id FROM Lots.Container
        WHERE CurrentLocationId = @CellLocationId AND ItemId = @FinishedGoodItemId AND ContainerStatusCodeId = 1
        ORDER BY OpenedAt, Id;

        IF @ContainerId IS NULL
        BEGIN
            INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, OpenedAt, CreatedByUserId)
            VALUES (@FinishedGoodItemId, @ContainerConfigId, @CellLocationId, 1, SYSUTCDATETIME(), @AppUserId);
            SET @ContainerId = SCOPE_IDENTITY();
            SET @OpenedContainer = 1;

            SET @Activity = Audit.ufn_TruncateActivity(ISNULL(@CellCode, N'?') + N' ' + Audit.ufn_MidDot() + N' Container ' + Audit.ufn_MidDot() + N' Opened');
            SET @NewValue = (SELECT JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id = @FinishedGoodItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                    @ContainerConfigId AS ContainerConfigId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @CellLocationId,
                @LogEntityTypeCode = N'Container', @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerOpened',
                @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;
        END

        -- ---- B3. Insert the tray (tray = LOT; FinishedGoodLotId links the two 1:1) ----
        SET @TrayPosition = ISNULL((SELECT MAX(TrayPosition) FROM Lots.ContainerTray WHERE ContainerId = @ContainerId), 0) + 1;
        INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, FinishedGoodLotId, ClosedAt, ClosedByUserId, ClosureMethod)
        VALUES (@ContainerId, @TrayPosition, @PieceCount, @FinishedGoodLotId, SYSUTCDATETIME(), @AppUserId, @ClosureMethod);
        SET @ContainerTrayId = SCOPE_IDENTITY();

        -- ---- B4. Consume each BOM line FIFO into the FG LOT (mirror
        --      R__Workorder_ConsumptionEvent_RecordWithBomCheck: ConsumptionEvent +
        --      Consumption genealogy edge RelationshipTypeId=3 + closure) ----
        DECLARE bom_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT bl.ChildItemId, bl.QtyPer FROM Parts.BomLine bl WHERE bl.BomId = @BomId;
        OPEN bom_cur;
        FETCH NEXT FROM bom_cur INTO @ChildItemId, @ChildQtyPer;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @NeedRemain = CAST(@ChildQtyPer * @PieceCount AS INT);
            WHILE @NeedRemain > 0
            BEGIN
                SET @SrcLotId = NULL;
                SELECT TOP 1 @SrcLotId = l.Id, @SrcAvail = l.InventoryAvailable,
                       @SrcPieceCount = l.PieceCount, @SrcStatus = l.LotStatusId
                FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                WHERE l.ItemId = @ChildItemId AND l.CurrentLocationId = @CellLocationId
                      AND sc.Code <> N'Closed' AND l.InventoryAvailable > 0
                ORDER BY l.CreatedAt, l.Id;              -- FIFO
                IF @SrcLotId IS NULL
                    RAISERROR(N'Component stock drained mid-consume.', 16, 1);   -- -> CATCH -> ROLLBACK

                SET @Take = CASE WHEN @SrcAvail <= @NeedRemain THEN @SrcAvail ELSE @NeedRemain END;
                UPDATE Lots.Lot
                SET PieceCount = PieceCount - @Take, InventoryAvailable = InventoryAvailable - @Take
                WHERE Id = @SrcLotId;
                IF (@SrcPieceCount - @Take) = 0
                BEGIN
                    UPDATE Lots.Lot SET LotStatusId = @ClosedStatusId WHERE Id = @SrcLotId;
                    INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
                    VALUES (@SrcLotId, @SrcStatus, @ClosedStatusId, N'Closed by assembly consumption (all pieces consumed).', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
                END

                -- ConsumptionEvent: produced side = the FG LOT (ProducedLotId) with the
                -- container/tray carried for packaging traceability.
                INSERT INTO Workorder.ConsumptionEvent
                    (SourceLotId, ProducedLotId, ProducedContainerId, ConsumedItemId, ProducedItemId,
                     PieceCount, LocationId, AppUserId, TerminalLocationId, TrayId, ConsumedAt)
                VALUES (@SrcLotId, @FinishedGoodLotId, @ContainerId, @ChildItemId, @FinishedGoodItemId,
                     @Take, @CellLocationId, @AppUserId, @TerminalLocationId, @ContainerTrayId, SYSUTCDATETIME());

                -- Consumption genealogy edge (RelationshipTypeId=3) + closure ancestors -> FG LOT.
                INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId)
                VALUES (@SrcLotId, @FinishedGoodLotId, 3, @Take, @AppUserId, @TerminalLocationId);
                INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
                SELECT c.AncestorLotId, @FinishedGoodLotId, c.Depth + 1
                FROM Lots.LotGenealogyClosure c
                WHERE c.DescendantLotId = @SrcLotId
                  AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure x
                                  WHERE x.AncestorLotId = c.AncestorLotId AND x.DescendantLotId = @FinishedGoodLotId);

                SET @NeedRemain = @NeedRemain - @Take;
            END
            FETCH NEXT FROM bom_cur INTO @ChildItemId, @ChildQtyPer;
        END
        CLOSE bom_cur; DEALLOCATE bom_cur;

        -- ---- B5. Container-full flag (delegation: DO NOT complete the container here;
        --      the view calls Lots.Container_Complete when @ContainerFull = 1) ----
        SET @Accum  = (SELECT SUM(PartsClosedCount) FROM Lots.ContainerTray WHERE ContainerId = @ContainerId AND ClosedAt IS NOT NULL);
        SET @Target = CASE WHEN @TraysPerContainer IS NOT NULL AND @PartsPerTray IS NOT NULL
                           THEN @TraysPerContainer * @PartsPerTray ELSE NULL END;
        SET @ContainerFull = CASE WHEN @Target IS NOT NULL AND ISNULL(@Accum, 0) >= @Target THEN 1 ELSE 0 END;

        -- ---- B6. Tray-completion audit (ContainerTray / TrayClosed) ----
        SET @Activity = Audit.ufn_TruncateActivity(N'Container #' + CAST(@ContainerId AS NVARCHAR(20)) + N' tray ' + CAST(@TrayPosition AS NVARCHAR(10))
            + N' ' + Audit.ufn_MidDot() + N' Assembly ' + Audit.ufn_MidDot() + N' Completed as FG LOT ' + @MintedName + N' (' + CAST(@PieceCount AS NVARCHAR(10)) + N' pcs)');
        SET @NewValue = (SELECT @ContainerId AS ContainerId, @TrayPosition AS TrayPosition, @PieceCount AS PartsClosedCount,
                @ClosureMethod AS ClosureMethod,
                JSON_QUERY((SELECT fl.Id, fl.LotName FROM Lots.Lot fl WHERE fl.Id = @FinishedGoodLotId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS FinishedGoodLot,
                @Accum AS ContainerAccumulatedParts, @ContainerFull AS ContainerFull
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @CellLocationId,
            @LogEntityTypeCode = N'ContainerTray', @EntityId = @ContainerTrayId, @LogEventTypeCode = N'TrayClosed',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Tray completed; finished-good LOT ' + @MintedName + N' minted.'
                     + CASE WHEN @ContainerFull = 1 THEN N' Container is full.' ELSE N'' END;
        GOTO Reply;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();

        SET @Status          = 0;
        SET @FinishedGoodLotId = NULL;
        SET @ContainerId     = NULL;
        SET @ContainerTrayId = NULL;
        SET @ContainerFull   = 0;
        SET @Message         = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerTray',
                @EntityId = NULL, @LogEventTypeCode = N'TrayClosed', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @FinishedGoodLotId AS FinishedGoodLotId,
               @ContainerId AS ContainerId, @ContainerTrayId AS ContainerTrayId, @ContainerFull AS ContainerFull;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
        RETURN;
    END CATCH

Reply:
    SELECT @Status AS Status, @Message AS Message, @FinishedGoodLotId AS FinishedGoodLotId,
           @ContainerId AS ContainerId, @ContainerTrayId AS ContainerTrayId, @ContainerFull AS ContainerFull;
END;
GO
