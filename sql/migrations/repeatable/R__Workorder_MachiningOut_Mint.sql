-- ============================================================
-- Repeatable:  R__Workorder_MachiningOut_Mint.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0 (2026-07-07)
-- Description: Machining OUT consume-mint (terminal-mint spec §3.4/§3.6/§3.8/§3.10).
--              Mints a SubAssembly LOT of @PieceCount at the source's line, consuming
--              @PieceCount x BOM.QtyPer from the casting (@SourceLotId), writing a
--              Consumption genealogy edge (RelationshipTypeId=3) + closure, a
--              Workorder.ConsumptionEvent, and a MachiningOut ProductionEvent on the
--              casting. The casting decrements and Closes only when fully consumed
--              (flexible operator qty; input size irrelevant). Produced part is derived
--              (published BOM whose child = casting item AND parent direct-eligible at
--              the line); @ProducedItemId overrides. No destination (line-resident).
--
--              INSERT-EXEC safe (status-row proc, captured via INSERT-EXEC): all
--              rejecting validations run BEFORE BEGIN TRANSACTION; sub-mutations are
--              INLINED (mint mirrors R__Lots_Lot_Create; consume mirrors
--              R__Workorder_Assembly_CompleteTray B4); the CATCH is the only ROLLBACK
--              site. No OUTPUT params (FDS-11-011). RAISERROR (not THROW) in CATCH.
--              Replaces R__Workorder_MachiningOut_RecordSplit (Split-genealogy split of
--              an externally-minted machined LOT) with a real consume-mint.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.MachiningOut_Mint
    @SourceLotId         BIGINT,
    @OperationTemplateId BIGINT,
    @PieceCount          INT,
    @ProducedItemId      BIGINT = NULL,
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.MachiningOut_Mint';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @SourceLotId AS SourceLotId, @OperationTemplateId AS OperationTemplateId,
        @PieceCount AS PieceCount, @ProducedItemId AS ProducedItemId, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @GoodStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');
    DECLARE @ClosedStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed');
    DECLARE @ManufacturedOriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code=N'Manufactured');
    DECLARE @SrcItem BIGINT, @SrcAvail INT, @SrcPc INT, @SrcStatus BIGINT, @SrcLoc BIGINT, @SrcName NVARCHAR(50), @Blocks BIT, @SrcStatusCode NVARCHAR(20);
    DECLARE @BomId BIGINT, @QtyPer DECIMAL(18,4), @Consumed INT, @CandCount INT;
    DECLARE @MintedName NVARCHAR(50), @NextOrd INT;
    DECLARE @ProducedPn NVARCHAR(50), @CellCode NVARCHAR(50), @Activity NVARCHAR(500), @NewValue NVARCHAR(MAX);

    BEGIN TRY
        -- ===== Pre-transaction validations (no open txn) =====
        IF @SourceLotId IS NULL OR @OperationTemplateId IS NULL OR @PieceCount IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message=N'Required parameter missing.';
            IF @AppUserId IS NOT NULL EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            GOTO Reply; END
        IF @PieceCount <= 0 BEGIN SET @Message=N'PieceCount must be positive.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        -- OperationTemplate exists + is a ConsumeMint role (this proc executes consume-mints only).
        IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate ot JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId
                       JOIN Parts.OperationRoleKind rk ON rk.Id=oty.OperationRoleKindId
                       WHERE ot.Id=@OperationTemplateId AND ot.DeprecatedAt IS NULL AND rk.Code=N'ConsumeMint')
        BEGIN SET @Message=N'OperationTemplate not found, deprecated, or not a consume-mint role.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        -- Source LOT read + not-blocked/open guard.
        SELECT @SrcItem=l.ItemId, @SrcAvail=l.InventoryAvailable, @SrcPc=l.PieceCount, @SrcStatus=l.LotStatusId,
               @SrcLoc=l.CurrentLocationId, @SrcName=l.LotName, @Blocks=sc.BlocksProduction, @SrcStatusCode=sc.Code
        FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@SourceLotId;
        IF @SrcItem IS NULL BEGIN SET @Message=N'Source LOT not found.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        IF @Blocks=1 OR @SrcStatusCode=N'Closed' BEGIN SET @Message=N'Source LOT is '+@SrcStatusCode+N' and cannot be consumed.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        -- Derive/validate the produced part: published BOM whose child = source item AND parent direct-eligible at the line.
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
        -- Resolve produced part's active BOM + the QtyPer of the source component.
        SET @BomId = (SELECT TOP 1 Id FROM Parts.Bom WHERE ParentItemId=@ProducedItemId AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL ORDER BY VersionNumber DESC);
        SET @QtyPer = (SELECT QtyPer FROM Parts.BomLine WHERE BomId=@BomId AND ChildItemId=@SrcItem);
        IF @BomId IS NULL OR @QtyPer IS NULL BEGIN SET @Message=N'Produced part has no active BOM consuming this component.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        SET @Consumed = CAST(@QtyPer * @PieceCount AS INT);
        IF @Consumed > @SrcAvail BEGIN SET @Message=N'Requested mint consumes '+CAST(@Consumed AS NVARCHAR(20))+N' but only '+CAST(@SrcAvail AS NVARCHAR(20))+N' available on the source LOT.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        SET @ProducedPn = (SELECT PartNumber FROM Parts.Item WHERE Id=@ProducedItemId);
        SET @CellCode   = (SELECT Code FROM Location.Location WHERE Id=@SrcLoc);

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;
        -- B1. Derive the SubAssembly LOT name as a '-NN' sublot of the source casting
        -- (legacy convention: <sourceLTT>-01, -02, ...). Serialize concurrent mints of
        -- THIS casting by re-reading the source row under UPDLOCK,HOLDLOCK before
        -- probing the ordinal (mirrors Lots.Lot_Split's suffix allocation). The 'Lot'
        -- counter is NOT advanced -- machined identity is parent-derived, not minted.
        DECLARE @Ignore BIGINT;
        SELECT @Ignore = l.Id
        FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK)
        WHERE l.Id = @SourceLotId;

        SET @NextOrd = ISNULL((
            SELECT MAX(TRY_CAST(RIGHT(LotName, 2) AS INT))
            FROM Lots.Lot
            WHERE LotName LIKE @SrcName + N'-[0-9][0-9]'
        ), 0) + 1;

        IF @NextOrd > 99
            RAISERROR(N'Casting already has 99 machined sublots.', 16, 1);

        SET @MintedName = @SrcName + N'-' + RIGHT(N'0' + CAST(@NextOrd AS NVARCHAR(2)), 2);
        INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            Weight, WeightUomId, ToolId, ToolCavityId, CavityNumber, VendorLotNumber, MinSerialNumber, MaxSerialNumber,
            CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId, CreatedAtTerminalId, CreatedAt)
        VALUES (@MintedName, @ProducedItemId, @ManufacturedOriginId, @GoodStatusId, @PieceCount, (SELECT MaxLotSize FROM Parts.Item WHERE Id=@ProducedItemId),
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
            @SrcLoc, 0, @PieceCount, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        SET @NewId = SCOPE_IDENTITY();
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@NewId, NULL, @GoodStatusId, N'SubAssembly LOT minted at Machining OUT.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@NewId, @NewId, 0);
        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@NewId, NULL, @SrcLoc, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        -- B2. MachiningOut ProductionEvent on the casting (checkpoint; ShotCount = pieces produced this mint).
        INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, WorkOrderOperationId, EventAt, ShotCount, ScrapCount, ScrapSourceId, WeightValue, WeightUomId, AppUserId, TerminalLocationId, Remarks)
        VALUES (@SourceLotId, @OperationTemplateId, NULL, SYSUTCDATETIME(), @PieceCount, NULL, NULL, NULL, NULL, @AppUserId, @TerminalLocationId, NULL);
        -- B3. Consume @Consumed from the casting; close at zero.
        UPDATE Lots.Lot SET PieceCount=PieceCount-@Consumed, InventoryAvailable=InventoryAvailable-@Consumed, UpdatedAt=SYSUTCDATETIME(), UpdatedByUserId=@AppUserId WHERE Id=@SourceLotId;
        IF (@SrcPc - @Consumed) = 0
        BEGIN
            UPDATE Lots.Lot SET LotStatusId=@ClosedStatusId WHERE Id=@SourceLotId;
            INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
            VALUES (@SourceLotId, @SrcStatus, @ClosedStatusId, N'Closed by Machining OUT mint (all pieces consumed).', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        END
        -- B4. ConsumptionEvent + Consumption genealogy edge (RelationshipTypeId=3) + closure ancestors -> minted LOT.
        INSERT INTO Workorder.ConsumptionEvent (SourceLotId, ProducedLotId, ProducedContainerId, ConsumedItemId, ProducedItemId, PieceCount, LocationId, AppUserId, TerminalLocationId, TrayId, ConsumedAt)
        VALUES (@SourceLotId, @NewId, NULL, @SrcItem, @ProducedItemId, @Consumed, @SrcLoc, @AppUserId, @TerminalLocationId, NULL, SYSUTCDATETIME());
        INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId)
        VALUES (@SourceLotId, @NewId, 3, @Consumed, @AppUserId, @TerminalLocationId);
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
        SELECT c.AncestorLotId, @NewId, c.Depth+1 FROM Lots.LotGenealogyClosure c
        WHERE c.DescendantLotId=@SourceLotId
          AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure x WHERE x.AncestorLotId=c.AncestorLotId AND x.DescendantLotId=@NewId);
        -- B5. Audit (subject = casting; minted machined LOT in NewValue).
        SET @Activity = Audit.ufn_TruncateActivity(@SrcName+N' '+Audit.ufn_MidDot()+N' Machining OUT '+Audit.ufn_MidDot()
            +N' Minted '+@ProducedPn+N' LOT '+@MintedName+N' ('+CAST(@PieceCount AS NVARCHAR(10))+N' pcs, consumed '+CAST(@Consumed AS NVARCHAR(10))+N')');
        SET @NewValue = (SELECT @NewId AS MintedLotId, @MintedName AS MintedLotName, @PieceCount AS MintedPieceCount, @Consumed AS ConsumedPieceCount,
            JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id=@ProducedItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ProducedItem
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@SrcLoc,
            @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @LogSeverityCode=N'Info',
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
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RAISERROR(@ErrMsg,@ErrSev,@ErrState); RETURN;
    END CATCH
Reply:
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
END;
GO
