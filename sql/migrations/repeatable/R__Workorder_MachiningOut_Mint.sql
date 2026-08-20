-- ============================================================
-- Repeatable:  R__Workorder_MachiningOut_Mint.sql
-- Author:      Blue Ridge Automation
-- Version:     2.5 (2026-08-20, part-scoped CRT enforcement) - D4: the scanned casting
--              (@SourceLotId, the FIFO handle the operator actually presented) is
--              refused when it is CRT (Lots.ufn_CrtBlocksAdvance). The guard sits
--              immediately after the B2 blocked-status rejection -- so Hold/Scrap/
--              Closed keeps precedence -- and before BEGIN TRANSACTION (Msg 3915).
--              NOTE the deliberate scope: the guard covers the SCANNED handle only,
--              not the rest of the FIFO queue the walk may roll into. A CRT casting
--              deeper in the queue is still consumed, and that is exactly the
--              containment escape the post-consume CRT re-resolve below exists to
--              close (it taints the minted sub-assembly instead of blocking). See
--              sql/tests/0063_Crt_PartScoped/050_mint_procs.sql section C, which
--              asserts that behaviour.
-- Version:     2.4 (2026-08-20, part-scoped CRT) - the minted SubAssembly LOT is now
--              stamped with Lots.Lot.CrtActive, resolved in ONE place
--              (Lots.ufn_CrtForMint: part flag OR terminal switch OR any consumed input
--              LOT already CRT). The mint-site call answers the part-flag and terminal
--              arms only and passes NULL for propagation -- @SourceLotId is just the
--              scanned FIFO HANDLE, is absent from the @Queue predicate, and may even
--              be Closed by inline scrap, so seeding from it could stamp a false
--              positive. A post-consume "CRT re-resolve" after the FIFO walk is the
--              single source of propagation truth: it resolves over the Consumption
--              genealogy edges (RelationshipTypeId = 3) the walk actually wrote and
--              raises the stamp 0 -> 1 only. A CRT casting anywhere in the walk --
--              not just the scanned one -- therefore taints the sub-assembly.
-- Version:     2.3 (2026-08-07, FAT-MACH-140) - defect/reject capture. New optional
--              @ScrapLinesJson ([{"defectCodeId","quantity"}, ...]) writes one
--              Workorder.RejectEvent per line (ProductionEventId NULL, LotId =
--              @SourceLotId), and decrements the scanned casting by the scrap total
--              IN ADDITION to the FIFO consumption (mirror of TrimOut_Record's inline
--              scrap). Pre-txn: valid JSON, every qty>0, every DefectCode active, and
--              the source casting's MIN(InvAvail,PieceCount) covers the scrap. The
--              mint availability is computed NET of scrap (@NetAvail = @TotalAvail -
--              @ScrapTotal when @SourceLotId is in the FIFO eligible set) so consumed
--              + scrap can never over-draw; the scrap decrement is applied in-txn
--              BEFORE the FIFO walk, which reads lock-fresh MIN(InvAvail,PieceCount).
-- Version:     2.2 (2026-07-21) - bound each draw by MIN(InventoryAvailable, PieceCount).
-- Description: Machining OUT consume-mint. @SourceLotId is the FIFO HANDLE (its cell +
--              casting part). Consumes strict oldest-first (arrival order) across ALL
--              open same-part castings at that cell, rolling into the next as each
--              empties; each draw is bounded by the casting's lock-fresh
--              MIN(InventoryAvailable, PieceCount) so NO casting can go negative even
--              when upstream data left InventoryAvailable > PieceCount. Mints ONE SubAssembly
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
    @AllowPartial        BIT    = 0,
    @ScrapLinesJson      NVARCHAR(MAX) = NULL   -- [{"defectCodeId":<bigint>,"quantity":<int>}, ...]
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL, @Available INT = 0;
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.MachiningOut_Mint';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @SourceLotId AS SourceLotId, @OperationTemplateId AS OperationTemplateId,
        @PieceCount AS PieceCount, @ProducedItemId AS ProducedItemId, @AppUserId AS AppUserId,
        @TerminalLocationId AS TerminalLocationId, @AllowPartial AS AllowPartial,
        LEFT(@ScrapLinesJson, 2000) AS ScrapLinesJson FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @GoodStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');
    DECLARE @ClosedStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed');
    DECLARE @ManufacturedOriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code=N'Manufactured');
    DECLARE @SrcItem BIGINT, @SrcLoc BIGINT, @Blocks BIT, @SrcStatusCode NVARCHAR(20), @SrcLotName NVARCHAR(50);
    DECLARE @SrcPieceCount INT, @SrcInvAvail INT;
    DECLARE @BomId BIGINT, @QtyPer DECIMAL(18,4), @Consumed INT, @CandCount INT, @TotalAvail INT;
    DECLARE @ScrapTotal INT = 0, @SrcEligible BIT = 0, @NetAvail INT;
    DECLARE @MintedName NVARCHAR(50), @OldestName NVARCHAR(50), @NextOrd INT, @ProducedPn NVARCHAR(50);
    DECLARE @Activity NVARCHAR(500), @NewValue NVARCHAR(MAX);
    DECLARE @Scrap TABLE (DefectCodeId BIGINT, Quantity INT);

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
        SELECT @SrcItem=l.ItemId, @SrcLoc=l.CurrentLocationId, @Blocks=sc.BlocksProduction, @SrcStatusCode=sc.Code,
               @SrcPieceCount=l.PieceCount, @SrcInvAvail=l.InventoryAvailable, @SrcLotName=l.LotName
        FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@SourceLotId;
        IF @SrcItem IS NULL BEGIN SET @Message=N'Source LOT not found.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        IF @Blocks=1 OR @SrcStatusCode=N'Closed' BEGIN SET @Message=N'Source LOT is '+@SrcStatusCode+N' and cannot be consumed.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END

        -- D4 (part-scoped CRT): the scanned casting cannot be consumed into a
        -- sub-assembly while it is CRT. AFTER the blocked-status guard above (so
        -- Hold/Scrap/Closed keeps precedence) and before BEGIN TRANSACTION -- a
        -- ROLLBACK in an INSERT-EXEC-captured proc throws Msg 3915. Scope note: this
        -- covers @SourceLotId, the handle the operator scanned, NOT the whole FIFO
        -- queue; see the version header.
        IF (SELECT Blocked FROM Lots.ufn_CrtBlocksAdvance(@SourceLotId)) = 1
        BEGIN SET @Message=N'LOT '+ISNULL(@SrcLotName,N'?')+N' is marked CRT and cannot be used until Quality clears it.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END

        -- ---- Scrap lines (pre-txn): parse + validate (mirror TrimOut_Record). One
        --      RejectEvent per line is fanned out in-txn against @SourceLotId, which is
        --      ALSO decremented by the scrap total (FAT-MACH-140). ----
        IF @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) <> 1
        BEGIN SET @Message=N'ScrapLinesJson is not valid JSON.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        IF @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) = 1
            INSERT INTO @Scrap (DefectCodeId, Quantity)
            SELECT j.defectCodeId, j.quantity
            FROM OPENJSON(@ScrapLinesJson) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') j;
        SET @ScrapTotal = ISNULL((SELECT SUM(Quantity) FROM @Scrap), 0);
        IF EXISTS (SELECT 1 FROM @Scrap WHERE Quantity IS NULL OR Quantity <= 0)
        BEGIN SET @Message=N'Each scrap line quantity must be positive.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        IF EXISTS (SELECT 1 FROM @Scrap s WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc WHERE dc.Id=s.DefectCodeId AND dc.DeprecatedAt IS NULL))
        BEGIN SET @Message=N'One or more scrap defect codes are invalid or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        -- source casting must hold enough to cover the scrap alone (never drive it negative)
        IF @ScrapTotal > 0 AND (CASE WHEN @SrcInvAvail < @SrcPieceCount THEN @SrcInvAvail ELSE @SrcPieceCount END) < @ScrapTotal
        BEGIN SET @Message=N'Scrap total '+CAST(@ScrapTotal AS NVARCHAR(10))+N' exceeds the source casting available quantity.';
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
        -- v2.2: consumable per casting = MIN(InventoryAvailable, PieceCount). Upstream
        -- data can leave InvAvail > PieceCount (Trim scrap historically decremented
        -- PieceCount but not InvAvail); bounding by the MIN keeps every casting >= 0.
        SELECT @TotalAvail = ISNULL(SUM(CASE WHEN l.InventoryAvailable < l.PieceCount THEN l.InventoryAvailable ELSE l.PieceCount END),0)
        FROM Lots.Lot l
        WHERE l.ItemId=@SrcItem AND l.CurrentLocationId=@SrcLoc AND l.LotStatusId=@GoodStatusId AND l.InventoryAvailable > 0 AND l.PieceCount > 0
          AND EXISTS (SELECT 1 FROM NextStep ns WHERE ns.LotId=l.Id AND ns.rn=1 AND ns.OpCode=@OpTypeCode);
        -- Scrap decrements @SourceLotId (FAT-MACH-140). If @SourceLotId is itself in the
        -- FIFO eligible set, that scrap reduces the mintable pool -- so the availability
        -- the mint sees is NET of scrap. @SrcEligible mirrors the @TotalAvail predicate
        -- restricted to @SourceLotId; the source-covers-scrap guard above already ensures
        -- its eligible contribution (MIN(InvAvail,PieceCount)) >= @ScrapTotal.
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
            WHERE l.Id = @SourceLotId
              AND ( rk.Code = N'ConsumeMint'
                    OR (rk.Code = N'Advance' AND NOT EXISTS (
                           SELECT 1 FROM Workorder.ProductionEvent pe
                           WHERE pe.LotId = l.Id AND pe.OperationTemplateId = rs.OperationTemplateId)) )
        )
        SELECT @SrcEligible = CASE WHEN EXISTS (
            SELECT 1 FROM Lots.Lot l
            WHERE l.Id=@SourceLotId AND l.LotStatusId=@GoodStatusId AND l.InventoryAvailable > 0 AND l.PieceCount > 0
              AND EXISTS (SELECT 1 FROM NextStep ns WHERE ns.LotId=l.Id AND ns.rn=1 AND ns.OpCode=@OpTypeCode)
        ) THEN 1 ELSE 0 END;

        SET @NetAvail = @TotalAvail - (CASE WHEN @SrcEligible = 1 THEN @ScrapTotal ELSE 0 END);
        IF @NetAvail < 0 SET @NetAvail = 0;
        SET @Available = CAST(FLOOR(@NetAvail / @QtyPer) AS INT);

        IF @NetAvail < @Consumed
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

        -- Scrap (FAT-MACH-140): decrement the scanned casting by the scrap total and
        -- fan out one RejectEvent per line (ProductionEventId NULL, charged to
        -- @SourceLotId) BEFORE the FIFO walk, so the lock-fresh walk sees post-scrap
        -- counts and can never over-draw. Mirror of TrimOut_Record's inline scrap write.
        IF @ScrapTotal > 0
        BEGIN
            UPDATE Lots.Lot
            SET PieceCount = PieceCount - @ScrapTotal,
                InventoryAvailable = InventoryAvailable - @ScrapTotal,
                UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
            WHERE Id = @SourceLotId;

            IF (SELECT PieceCount FROM Lots.Lot WHERE Id = @SourceLotId) = 0
            BEGIN
                UPDATE Lots.Lot SET LotStatusId = @ClosedStatusId WHERE Id = @SourceLotId;
                INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
                VALUES (@SourceLotId, @GoodStatusId, @ClosedStatusId, N'Closed by Machining OUT scrap (fully scrapped).', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
            END

            INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, RecordedAt)
            SELECT NULL, @SourceLotId, s.DefectCodeId, s.Quantity, NULL, N'Machining OUT scrap', @AppUserId, SYSUTCDATETIME()
            FROM @Scrap s;
        END

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
        WHERE l.ItemId=@SrcItem AND l.CurrentLocationId=@SrcLoc AND l.LotStatusId=@GoodStatusId AND l.InventoryAvailable > 0 AND l.PieceCount > 0
          AND EXISTS (SELECT 1 FROM NextStep ns WHERE ns.LotId=l.Id AND ns.rn=1 AND ns.OpCode=@OpTypeCode)
        ORDER BY lm.LastMovementAt ASC, l.Id ASC;

        SET @OldestName = (SELECT LotName FROM Lots.Lot WHERE Id = (SELECT LotId FROM @Queue WHERE Ord=1));
        SET @NextOrd = ISNULL((SELECT MAX(TRY_CAST(RIGHT(LotName,2) AS INT)) FROM Lots.Lot WHERE LotName LIKE @OldestName + N'-[0-9][0-9]'),0)+1;
        IF @NextOrd > 99 RAISERROR(N'Casting already has 99 machined sublots.',16,1);
        SET @MintedName = @OldestName + N'-' + RIGHT(N'0'+CAST(@NextOrd AS NVARCHAR(2)),2);

        -- D1/D2: CRT at mint, resolved in ONE place (Lots.ufn_CrtForMint). Only the
        -- part-flag and terminal arms can be answered HERE, so the propagation arm is
        -- passed NULL: @SourceLotId is merely the scanned FIFO HANDLE and is NOT
        -- necessarily consumed at all (it is absent from the @Queue predicate below,
        -- and if inline scrap fully drained it, it is already Closed and excluded from
        -- the queue outright) -- seeding from it could stamp a false positive that the
        -- 0 -> 1-only re-resolve can never take back. The "CRT re-resolve" block after
        -- the walk is therefore the SINGLE source of propagation truth in this proc,
        -- resolving over the Consumption edges that ARE the actual consumed set.
        -- Same shape as Assembly_CompleteTray's mint site + step B4b.
        DECLARE @CrtActive BIT =
            (SELECT CrtActive FROM Lots.ufn_CrtForMint(@ProducedItemId, @TerminalLocationId,
                                                       NULL));

        INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            Weight, WeightUomId, ToolId, ToolCavityId, CavityNumber, VendorLotNumber, MinSerialNumber, MaxSerialNumber,
            CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId, CreatedAtTerminalId, CreatedAt, BomId, CrtActive)
        VALUES (@MintedName, @ProducedItemId, @ManufacturedOriginId, @GoodStatusId, @PieceCount, (SELECT MaxLotSize FROM Parts.Item WHERE Id=@ProducedItemId),
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, @SrcLoc, 0, @PieceCount, @AppUserId, @TerminalLocationId, SYSUTCDATETIME(), @BomId, @CrtActive);
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
            IF @cPc < @cAvail SET @cAvail = @cPc;  -- v2.2: bound the draw by MIN(InvAvail,PieceCount); a diverged casting (InvAvail>PieceCount) can never go negative
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

        -- CRT re-resolve (D2). The stamp above only saw the FIFO HANDLE, but the walk
        -- rolls into as many castings as it needs -- a CRT casting further down the
        -- queue would otherwise mint a CLEAN sub-assembly, which is exactly the
        -- containment escape D2 exists to prevent. The Consumption genealogy edges
        -- written by the walk (RelationshipTypeId = 3) ARE the actual consumed set, so
        -- re-resolve over them -- the type filter is explicit so a future Split/Rework
        -- edge on a freshly minted LOT cannot silently widen propagation.
        -- Only ever raises 0 -> 1 (ufn_CrtForMint is a pure OR of the same three arms).
        IF @CrtActive = 0
        BEGIN
            DECLARE @ConsumedLotIdsCsv NVARCHAR(MAX) = (
                SELECT STRING_AGG(CAST(g.ParentLotId AS NVARCHAR(20)), N',')
                FROM Lots.LotGenealogy g
                WHERE g.ChildLotId = @NewId AND g.RelationshipTypeId = 3);
            SET @CrtActive = (SELECT CrtActive FROM Lots.ufn_CrtForMint(@ProducedItemId,
                @TerminalLocationId, @ConsumedLotIdsCsv));
            IF @CrtActive = 1
                UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @NewId;
        END

        -- Audit (subject = minted LOT; source castings summarized).
        SET @Activity = Audit.ufn_TruncateActivity(@MintedName+N' '+Audit.ufn_MidDot()+N' Machining OUT '+Audit.ufn_MidDot()
            +N' Minted '+@ProducedPn+N' ('+CAST(@PieceCount AS NVARCHAR(10))+N' pcs, consumed '+CAST(@Consumed AS NVARCHAR(10))+N' from '+CAST(@n AS NVARCHAR(10))+N' casting(s)'
            + CASE WHEN @ScrapTotal > 0
                   THEN N', scrapped '+CAST(@ScrapTotal AS NVARCHAR(10))+N' ('+CAST((SELECT COUNT(*) FROM @Scrap) AS NVARCHAR(10))+N' reason'
                        + CASE WHEN (SELECT COUNT(*) FROM @Scrap) = 1 THEN N'' ELSE N's' END + N')'
                   ELSE N'' END
            + N')');
        SET @NewValue = (SELECT @NewId AS MintedLotId, @MintedName AS MintedLotName, @PieceCount AS MintedPieceCount, @Consumed AS ConsumedPieceCount, @ScrapTotal AS ScrapPieceCount,
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
