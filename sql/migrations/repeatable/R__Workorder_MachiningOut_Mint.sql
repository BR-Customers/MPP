-- ============================================================
-- Repeatable:  R__Workorder_MachiningOut_Mint.sql
-- Author:      Blue Ridge Automation
-- Version:     2.1 (2026-07-21) - FIFO candidate set matches Lots.Lot_GetWipQueueByLocation.
-- Description: Machining OUT consume-mint. @SourceLotId is the FIFO HANDLE (its cell +
--              casting part). Consumes strict oldest-first (arrival order) across ALL
--              open same-part castings at that cell, rolling into the next as each
--              empties; each draw is bounded by the casting's lock-fresh
--              InventoryAvailable so NO casting can go negative. Mints ONE SubAssembly
--              LOT named <oldest-casting-LTT>-NN, with one ConsumptionEvent + Consumption
--              genealogy edge + closure PER source casting (multi-parent traceability).
--              Shortfall: @AllowPartial=0 -> reject + Available=max producible;
--              @AllowPartial=1 -> mint floor(totalAvail/QtyPer). INSERT-EXEC safe:
--              rejects before BEGIN TRAN; RAISERROR (not THROW) in CATCH. Result:
--              Status, Message, NewId, Available.
--              v2.1: the FIFO candidate set (@TotalAvail select AND the @Queue
--              INSERT...SELECT) now requires Good/non-blocking status (LotStatusId =
--              @GoodStatusId, matching the walk's own guard) AND that the casting's
--              next PENDING route step (mirrors the NextStep CTE in
--              R__Lots_Lot_GetWipQueueByLocation.sql) is THIS MachiningOut ConsumeMint
--              step -- i.e. the exact set Lots.Lot_GetWipQueueByLocation would surface
--              for this cell/role. Prevents consuming a same-part casting that is still
--              pending an earlier Advance checkpoint (e.g. MachiningIn) or is on Hold.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.MachiningOut_Mint
    @SourceLotId         BIGINT,
    @OperationTemplateId BIGINT,
    @PieceCount          INT,
    @ProducedItemId      BIGINT = NULL,
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT = NULL,
    @AllowPartial        BIT    = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL, @Available INT = 0;
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.MachiningOut_Mint';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @SourceLotId AS SourceLotId, @OperationTemplateId AS OperationTemplateId,
        @PieceCount AS PieceCount, @ProducedItemId AS ProducedItemId, @AppUserId AS AppUserId,
        @TerminalLocationId AS TerminalLocationId, @AllowPartial AS AllowPartial FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @GoodStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');
    DECLARE @ClosedStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed');
    DECLARE @ManufacturedOriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code=N'Manufactured');
    DECLARE @SrcItem BIGINT, @SrcLoc BIGINT, @Blocks BIT, @SrcStatusCode NVARCHAR(20);
    DECLARE @BomId BIGINT, @QtyPer DECIMAL(18,4), @Consumed INT, @CandCount INT, @TotalAvail INT;
    DECLARE @MintedName NVARCHAR(50), @OldestName NVARCHAR(50), @NextOrd INT, @ProducedPn NVARCHAR(50);
    DECLARE @Activity NVARCHAR(500), @NewValue NVARCHAR(MAX);

    BEGIN TRY
        -- ===== Pre-transaction validations =====
        IF @SourceLotId IS NULL OR @OperationTemplateId IS NULL OR @PieceCount IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message=N'Required parameter missing.';
            IF @AppUserId IS NOT NULL EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            GOTO Reply; END
        IF @PieceCount <= 0 BEGIN SET @Message=N'PieceCount must be positive.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate ot JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId
                       JOIN Parts.OperationRoleKind rk ON rk.Id=oty.OperationRoleKindId
                       WHERE ot.Id=@OperationTemplateId AND ot.DeprecatedAt IS NULL AND rk.Code=N'ConsumeMint')
        BEGIN SET @Message=N'OperationTemplate not found, deprecated, or not a consume-mint role.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        -- OperationType role code of @OperationTemplateId (e.g. 'MachiningOut'), derived once,
        -- used to gate the FIFO candidate set to LOTs whose next-pending route step is THIS role.
        DECLARE @OpTypeCode NVARCHAR(20) = (SELECT oty.Code FROM Parts.OperationTemplate ot
            JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId WHERE ot.Id=@OperationTemplateId);
        -- Source LOT = FIFO handle (cell + part); must be open/not-blocked.
        SELECT @SrcItem=l.ItemId, @SrcLoc=l.CurrentLocationId, @Blocks=sc.BlocksProduction, @SrcStatusCode=sc.Code
        FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@SourceLotId;
        IF @SrcItem IS NULL BEGIN SET @Message=N'Source LOT not found.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        IF @Blocks=1 OR @SrcStatusCode=N'Closed' BEGIN SET @Message=N'Source LOT is '+@SrcStatusCode+N' and cannot be consumed.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        -- Derive produced part (published BOM whose child = @SrcItem, parent line-eligible).
        IF @ProducedItemId IS NULL
        BEGIN
            SELECT @CandCount = COUNT(DISTINCT b.ParentItemId)
            FROM Parts.Bom b JOIN Parts.BomLine bl ON bl.BomId=b.Id AND bl.ChildItemId=@SrcItem
            WHERE b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL
              AND EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation eil WHERE eil.ItemId=b.ParentItemId
                          AND eil.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@SrcLoc)));
            IF @CandCount = 0 BEGIN SET @Message=N'No producible part at this line consumes this component.';
                EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
            IF @CandCount > 1 BEGIN SET @Message=N'Multiple producible parts consume this component; specify ProducedItemId.';
                EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
            SELECT @ProducedItemId = MIN(b.ParentItemId)
            FROM Parts.Bom b JOIN Parts.BomLine bl ON bl.BomId=b.Id AND bl.ChildItemId=@SrcItem
            WHERE b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL
              AND EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation eil WHERE eil.ItemId=b.ParentItemId
                          AND eil.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@SrcLoc)));
        END
        SET @BomId = (SELECT TOP 1 Id FROM Parts.Bom WHERE ParentItemId=@ProducedItemId AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL ORDER BY VersionNumber DESC);
        SET @QtyPer = (SELECT QtyPer FROM Parts.BomLine WHERE BomId=@BomId AND ChildItemId=@SrcItem);
        IF @BomId IS NULL OR @QtyPer IS NULL OR @QtyPer <= 0 BEGIN SET @Message=N'Produced part has no active BOM consuming this component.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        SET @Consumed = CAST(@QtyPer * @PieceCount AS INT);

        -- FIFO source total: Good/non-blocking, same part, same cell, AND next-pending route
        -- step is THIS MachiningOut ConsumeMint step (mirrors NextStep CTE in
        -- R__Lots_Lot_GetWipQueueByLocation.sql) -- i.e. exactly the set the terminal's
        -- WIP queue would display. @Available = max producible sub-assemblies.
        ;WITH NextStep AS (
            SELECT l.Id AS LotId, rs.SequenceNumber, oty2.Code AS OpCode,
                   ROW_NUMBER() OVER (PARTITION BY l.Id ORDER BY rs.SequenceNumber ASC) AS rn
            FROM Lots.Lot l
            INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
            INNER JOIN Parts.RouteTemplate rt ON rt.ItemId = l.ItemId
                 AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
            INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
            INNER JOIN Parts.OperationTemplate ot2 ON ot2.Id = rs.OperationTemplateId
            INNER JOIN Parts.OperationType oty2 ON oty2.Id = ot2.OperationTypeId
            INNER JOIN Parts.OperationRoleKind rk ON rk.Id = oty2.OperationRoleKindId
            WHERE l.ItemId = @SrcItem AND l.CurrentLocationId = @SrcLoc
              AND ( rk.Code = N'ConsumeMint'
                    OR (rk.Code = N'Advance' AND NOT EXISTS (
                           SELECT 1 FROM Workorder.ProductionEvent pe
                           WHERE pe.LotId = l.Id AND pe.OperationTemplateId = rs.OperationTemplateId)) )
        )
        SELECT @TotalAvail = ISNULL(SUM(l.InventoryAvailable),0)
        FROM Lots.Lot l
        WHERE l.ItemId=@SrcItem AND l.CurrentLocationId=@SrcLoc AND l.LotStatusId=@GoodStatusId AND l.InventoryAvailable > 0
          AND EXISTS (SELECT 1 FROM NextStep ns WHERE ns.LotId=l.Id AND ns.rn=1 AND ns.OpCode=@OpTypeCode);
        SET @Available = CAST(FLOOR(@TotalAvail / @QtyPer) AS INT);

        IF @TotalAvail < @Consumed
        BEGIN
            IF @AllowPartial = 0
            BEGIN SET @Message=N'Only '+CAST(@Available AS NVARCHAR(10))+N' available in the FIFO queue (requested '+CAST(@PieceCount AS NVARCHAR(10))+N').';
                EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
            SET @PieceCount = @Available;
            IF @PieceCount <= 0 BEGIN SET @Message=N'No castings available to consume.';
                EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
            SET @Consumed = CAST(@QtyPer * @PieceCount AS INT);
        END
        SET @ProducedPn = (SELECT PartNumber FROM Parts.Item WHERE Id=@ProducedItemId);

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;
        -- Ordered FIFO list of candidate castings (arrival-first, matches Lot_GetWipQueueByLocation).
        -- Same predicate as @TotalAvail above: Good/non-blocking status AND next-pending
        -- route step is THIS MachiningOut ConsumeMint step.
        DECLARE @Queue TABLE (Ord INT IDENTITY(1,1), LotId BIGINT);
        ;WITH NextStep AS (
            SELECT l.Id AS LotId, rs.SequenceNumber, oty2.Code AS OpCode,
                   ROW_NUMBER() OVER (PARTITION BY l.Id ORDER BY rs.SequenceNumber ASC) AS rn
            FROM Lots.Lot l
            INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
            INNER JOIN Parts.RouteTemplate rt ON rt.ItemId = l.ItemId
                 AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
            INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
            INNER JOIN Parts.OperationTemplate ot2 ON ot2.Id = rs.OperationTemplateId
            INNER JOIN Parts.OperationType oty2 ON oty2.Id = ot2.OperationTypeId
            INNER JOIN Parts.OperationRoleKind rk ON rk.Id = oty2.OperationRoleKindId
            WHERE l.ItemId = @SrcItem AND l.CurrentLocationId = @SrcLoc
              AND ( rk.Code = N'ConsumeMint'
                    OR (rk.Code = N'Advance' AND NOT EXISTS (
                           SELECT 1 FROM Workorder.ProductionEvent pe
                           WHERE pe.LotId = l.Id AND pe.OperationTemplateId = rs.OperationTemplateId)) )
        )
        INSERT INTO @Queue (LotId)
        SELECT l.Id
        FROM Lots.Lot l
        LEFT JOIN (SELECT LotId, MAX(MovedAt) AS LastMovementAt FROM Lots.LotMovement GROUP BY LotId) lm ON lm.LotId=l.Id
        WHERE l.ItemId=@SrcItem AND l.CurrentLocationId=@SrcLoc AND l.LotStatusId=@GoodStatusId AND l.InventoryAvailable > 0
          AND EXISTS (SELECT 1 FROM NextStep ns WHERE ns.LotId=l.Id AND ns.rn=1 AND ns.OpCode=@OpTypeCode)
        ORDER BY lm.LastMovementAt ASC, l.Id ASC;

        SET @OldestName = (SELECT LotName FROM Lots.Lot WHERE Id = (SELECT LotId FROM @Queue WHERE Ord=1));
        SET @NextOrd = ISNULL((SELECT MAX(TRY_CAST(RIGHT(LotName,2) AS INT)) FROM Lots.Lot WHERE LotName LIKE @OldestName + N'-[0-9][0-9]'),0)+1;
        IF @NextOrd > 99 RAISERROR(N'Casting already has 99 machined sublots.',16,1);
        SET @MintedName = @OldestName + N'-' + RIGHT(N'0'+CAST(@NextOrd AS NVARCHAR(2)),2);

        INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            Weight, WeightUomId, ToolId, ToolCavityId, CavityNumber, VendorLotNumber, MinSerialNumber, MaxSerialNumber,
            CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId, CreatedAtTerminalId, CreatedAt)
        VALUES (@MintedName, @ProducedItemId, @ManufacturedOriginId, @GoodStatusId, @PieceCount, (SELECT MaxLotSize FROM Parts.Item WHERE Id=@ProducedItemId),
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, @SrcLoc, 0, @PieceCount, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        SET @NewId = SCOPE_IDENTITY();
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@NewId, NULL, @GoodStatusId, N'SubAssembly LOT minted at Machining OUT (FIFO).', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@NewId, @NewId, 0);
        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@NewId, NULL, @SrcLoc, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- FIFO walk: consume oldest-first, bounded per casting by lock-fresh availability.
        DECLARE @Need INT = @Consumed, @i INT = 1, @n INT = (SELECT ISNULL(MAX(Ord),0) FROM @Queue);
        DECLARE @cLot BIGINT, @cAvail INT, @cPc INT, @cStatus BIGINT, @take INT;
        WHILE @i <= @n AND @Need > 0
        BEGIN
            SELECT @cLot = LotId FROM @Queue WHERE Ord=@i;
            SELECT @cAvail=l.InventoryAvailable, @cPc=l.PieceCount, @cStatus=l.LotStatusId
            FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK) WHERE l.Id=@cLot;
            IF @cStatus <> @GoodStatusId OR @cAvail <= 0 BEGIN SET @i=@i+1; CONTINUE; END
            SET @take = CASE WHEN @Need < @cAvail THEN @Need ELSE @cAvail END;
            UPDATE Lots.Lot SET PieceCount=PieceCount-@take, InventoryAvailable=InventoryAvailable-@take, UpdatedAt=SYSUTCDATETIME(), UpdatedByUserId=@AppUserId WHERE Id=@cLot;
            IF (@cPc - @take) = 0
            BEGIN
                UPDATE Lots.Lot SET LotStatusId=@ClosedStatusId WHERE Id=@cLot;
                INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
                VALUES (@cLot, @GoodStatusId, @ClosedStatusId, N'Closed by Machining OUT mint (fully consumed).', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
            END
            INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, WorkOrderOperationId, EventAt, ShotCount, ScrapCount, ScrapSourceId, WeightValue, WeightUomId, AppUserId, TerminalLocationId, Remarks)
            VALUES (@cLot, @OperationTemplateId, NULL, SYSUTCDATETIME(), @take, NULL, NULL, NULL, NULL, @AppUserId, @TerminalLocationId, NULL);
            INSERT INTO Workorder.ConsumptionEvent (SourceLotId, ProducedLotId, ProducedContainerId, ConsumedItemId, ProducedItemId, PieceCount, LocationId, AppUserId, TerminalLocationId, TrayId, ConsumedAt)
            VALUES (@cLot, @NewId, NULL, @SrcItem, @ProducedItemId, @take, @SrcLoc, @AppUserId, @TerminalLocationId, NULL, SYSUTCDATETIME());
            INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId)
            VALUES (@cLot, @NewId, 3, @take, @AppUserId, @TerminalLocationId);
            INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
            SELECT c.AncestorLotId, @NewId, c.Depth+1 FROM Lots.LotGenealogyClosure c
            WHERE c.DescendantLotId=@cLot AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure x WHERE x.AncestorLotId=c.AncestorLotId AND x.DescendantLotId=@NewId);
            SET @Need = @Need - @take;
            SET @i = @i + 1;
        END
        IF @Need > 0 RAISERROR(N'FIFO queue was consumed by a concurrent mint mid-operation; reload and retry.',16,1);

        -- Audit (subject = minted LOT; source castings summarized).
        SET @Activity = Audit.ufn_TruncateActivity(@MintedName+N' '+Audit.ufn_MidDot()+N' Machining OUT '+Audit.ufn_MidDot()
            +N' Minted '+@ProducedPn+N' ('+CAST(@PieceCount AS NVARCHAR(10))+N' pcs, consumed '+CAST(@Consumed AS NVARCHAR(10))+N' from '+CAST(@n AS NVARCHAR(10))+N' casting(s))');
        SET @NewValue = (SELECT @NewId AS MintedLotId, @MintedName AS MintedLotName, @PieceCount AS MintedPieceCount, @Consumed AS ConsumedPieceCount,
            JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id=@ProducedItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ProducedItem
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@SrcLoc,
            @LogEntityTypeCode=N'Lot', @EntityId=@NewId, @LogEventTypeCode=N'MachiningOutCompleted', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=NULL, @NewValue=@NewValue;
        COMMIT TRANSACTION;
        SET @Status=1; SET @Message=N'Minted '+@ProducedPn+N' LOT '+@MintedName+N' ('+CAST(@PieceCount AS NVARCHAR(10))+N' pcs).';
        GOTO Reply;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @NewId=NULL; SET @Message=N'Unexpected error: '+LEFT(@ErrMsg,400);
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Available AS Available; RAISERROR(@ErrMsg,@ErrSev,@ErrState); RETURN;
    END CATCH
Reply:
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Available AS Available;
END;
GO
