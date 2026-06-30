-- ============================================================
-- Repeatable:  R__Workorder_MachiningIn_PickAndConsume.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-19
-- Version:     1.0
-- Description: Arc 2 Phase 5 Machining IN (spec sec "Machining IN"; FDS-05-033,
--              OI-18). The FIFO-pick + BOM-driven part-identity rename: a WHOLE
--              cast/trim LOT sitting in a Machining Cell's FIFO queue (placed there
--              by Trim OUT, Phase 4) is picked, and in one atomic transaction the
--              proc:
--                * mints a NEW machined LOT under the machined Item (resolved by
--                  BOM lookup), Manufactured origin, NULL Tool/Cavity (B13),
--                * writes a Workorder.ConsumptionEvent (source consumed, full
--                  piece count -> produced) ,
--                * writes the Lots.LotGenealogy Consumption edge + B4 closure rows
--                  linking source -> machined,
--                * writes a checkpoint Workorder.ProductionEvent (MachiningIn),
--                  optionally with a QueueOverrideReason ProductionEventValue,
--                * Closes the source LOT (all pieces consumed).
--
--              *** WHY EVERY SUB-MUTATION IS INLINED, NOT EXEC'd ***
--              This proc returns its OWN status row (Status, Message, NewId=
--              machined LotId, + machined LotName / ConsumptionEventId /
--              ProductionEventId) and is captured by callers/tests via INSERT-EXEC.
--              It therefore CANNOT EXEC Lots.Lot_Create (mint),
--              Lots.LotGenealogy_RecordConsumption (edge+closure), or
--              Lots.Lot_UpdateStatus (source close) -- exactly the constraint
--              Lot_Split / Lot_Merge solved (see their headers):
--                1. Each of those procs ends with its own status-row SELECT, which
--                   would POLLUTE this proc's single result set (breaks the
--                   one-result-set JDBC rule + the test temp-table capture).
--                2. Capturing Lot_Create's @NewId would need INSERT-EXEC ... EXEC
--                   Lots.Lot_Create -- but THIS proc is itself invoked via
--                   INSERT-EXEC, and nesting INSERT-EXEC is illegal (Msg 8164).
--              So each side effect is INLINED to mirror the source-of-truth proc:
--                - mint mirrors Lots.Lot_Create (inline IdentifierSequence_Next so a
--                  rollback un-burns the counter; LotStatusHistory 'Good';
--                  LotGenealogyClosure self-row Depth=0; first LotMovement From=NULL),
--                - genealogy mirrors Lots.LotGenealogy_RecordConsumption (Consumption
--                  edge RelationshipTypeId=3 + ancestor depth+1 closure rows),
--                - source close mirrors Lots.Lot_UpdateStatus (UPDATE LotStatusId
--                  Closed + a LotStatusHistory Good->Closed row).
--              Each inline block is commented as a mirror of its source-of-truth proc.
--
--              ALL rejecting validations run BEFORE BEGIN TRANSACTION (each: SELECT
--              the status row + RETURN, no open txn) because a ROLLBACK inside an
--              INSERT-EXEC-captured proc throws Msg 3915 -- so the CATCH (a doomed
--              XACT_ABORT exception) is the ONLY legal ROLLBACK site. Mirrors
--              R__Lots_Lot_Split.sql structurally.
--
--              BOM rename resolution (FDS-05-033): the machined Item is the
--              ParentItemId of the single active published Parts.Bom whose ONLY
--              BomLine lists the source LOT's Item as ChildItemId at QtyPer=1.
--              Reject if no such BOM (no rename configured) or >1 (ambiguous).
--
--              Eligibility (OI-18, FDS-02-012): the source LOT's Item must be
--              eligible at @CellLocationId via Parts.v_EffectiveItemLocation -- the
--              BomDerived leg resolves the cast/trim child Item through the machined
--              parent Item's BOM, so eligibility holds exactly when the machined
--              Item is Direct-eligible at the Cell.
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params (FDS-11-011). Single terminal result row. Audit
--              'MachiningInPicked' (Lot subject = machined LOT) INSIDE the txn.
--              RAISERROR (not THROW).
-- ============================================================

CREATE OR ALTER PROCEDURE Workorder.MachiningIn_PickAndConsume
    @SourceLotId         BIGINT,
    @CellLocationId      BIGINT,
    @QueueOverrideReason NVARCHAR(500) = NULL,
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    -- Output slots (returned via SELECT, not OUTPUT params).
    DECLARE @NewMachinedLotId   BIGINT       = NULL;
    DECLARE @NewMachinedLotName NVARCHAR(50) = NULL;
    DECLARE @ConsumptionEventId BIGINT       = NULL;
    DECLARE @ProductionEventId  BIGINT       = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Workorder.MachiningIn_PickAndConsume';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @SourceLotId AS SourceLotId, @CellLocationId AS CellLocationId,
               @QueueOverrideReason AS QueueOverrideReason,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- Source LOT attributes (read once pre-txn for validation).
    DECLARE @SourceName   NVARCHAR(50);
    DECLARE @SourceItem   BIGINT;
    DECLARE @SourcePc     INT;
    DECLARE @StatusCode   NVARCHAR(20);
    DECLARE @StatusName   NVARCHAR(100);
    DECLARE @Blocks       BIT;

    -- Resolved machined Item + BOM.
    DECLARE @MachinedItem BIGINT;
    DECLARE @BomId        BIGINT;
    DECLARE @MatchCount   INT;

    DECLARE @GoodStatusId      BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @ClosedStatusId    BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
    DECLARE @ManufacturedOrigin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
    DECLARE @MachiningInOtId   BIGINT = (SELECT TOP 1 Id FROM Parts.OperationTemplate WHERE Code = N'MachiningIn' AND DeprecatedAt IS NULL ORDER BY VersionNumber DESC);

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @SourceLotId IS NULL OR @CellLocationId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (SourceLotId, CellLocationId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @SourceLotId, @LogEventTypeCode = N'MachiningInPicked',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewMachinedLotId AS NewId,
                   @NewMachinedLotName AS NewMachinedLotName, @ConsumptionEventId AS ConsumptionEventId,
                   @ProductionEventId AS ProductionEventId;
            RETURN;
        END

        -- ---- 2. MachiningIn OperationTemplate must be configured ----
        IF @MachiningInOtId IS NULL
        BEGIN
            SET @Message = N'MachiningIn OperationTemplate is not configured.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @SourceLotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewMachinedLotId AS NewId,
                   @NewMachinedLotName AS NewMachinedLotName, @ConsumptionEventId AS ConsumptionEventId,
                   @ProductionEventId AS ProductionEventId;
            RETURN;
        END

        -- ---- 3. Cell exists ----
        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @CellLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Cell location not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @SourceLotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewMachinedLotId AS NewId,
                   @NewMachinedLotName AS NewMachinedLotName, @ConsumptionEventId AS ConsumptionEventId,
                   @ProductionEventId AS ProductionEventId;
            RETURN;
        END

        -- ---- 4. Source LOT existence + B2 not-blocked guard (INLINE mirror of
        -- Lots.Lot_AssertNotBlocked; inlined because that proc emits a result set
        -- and this proc is itself captured via INSERT-EXEC). ----
        SELECT @SourceName = l.LotName,
               @SourceItem = l.ItemId,
               @SourcePc   = l.PieceCount,
               @StatusCode = sc.Code,
               @StatusName = sc.Name,
               @Blocks     = sc.BlocksProduction
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @SourceLotId;

        IF @SourceName IS NULL
        BEGIN
            SET @Message = N'Source LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @SourceLotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewMachinedLotId AS NewId,
                   @NewMachinedLotName AS NewMachinedLotName, @ConsumptionEventId AS ConsumptionEventId,
                   @ProductionEventId AS ProductionEventId;
            RETURN;
        END

        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode
                         + N') and cannot be picked; release the hold first.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @SourceLotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewMachinedLotId AS NewId,
                   @NewMachinedLotName AS NewMachinedLotName, @ConsumptionEventId AS ConsumptionEventId,
                   @ProductionEventId AS ProductionEventId;
            RETURN;
        END

        -- ---- 5. BOM-driven rename resolution (FDS-05-033) ----
        -- The machined Item is the ParentItemId of the single active published BOM
        -- whose ONLY BomLine lists the source Item as the child at QtyPer=1.
        DECLARE @Matches TABLE (BomId BIGINT, ParentItemId BIGINT);
        INSERT INTO @Matches (BomId, ParentItemId)
        SELECT b.Id, b.ParentItemId
        FROM Parts.Bom b
        INNER JOIN Parts.BomLine bl ON bl.BomId = b.Id
        WHERE b.PublishedAt IS NOT NULL
          AND b.DeprecatedAt IS NULL
          AND bl.ChildItemId = @SourceItem
          AND bl.QtyPer = 1.0
          -- single-line BOM: the source Item is the ONLY child line on this BOM.
          AND NOT EXISTS (SELECT 1 FROM Parts.BomLine x WHERE x.BomId = b.Id AND x.ChildItemId <> @SourceItem);

        SET @MatchCount = (SELECT COUNT(*) FROM @Matches);

        IF @MatchCount = 0
        BEGIN
            SET @Message = N'No active BOM renames ' + @SourceName + N' (Item ' + CAST(@SourceItem AS NVARCHAR(20)) + N') at this cell.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @SourceLotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewMachinedLotId AS NewId,
                   @NewMachinedLotName AS NewMachinedLotName, @ConsumptionEventId AS ConsumptionEventId,
                   @ProductionEventId AS ProductionEventId;
            RETURN;
        END

        IF @MatchCount > 1
        BEGIN
            SET @Message = N'Ambiguous BOM rename for Item ' + CAST(@SourceItem AS NVARCHAR(20)) + N' (' + CAST(@MatchCount AS NVARCHAR(10)) + N' matching BOMs).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @SourceLotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewMachinedLotId AS NewId,
                   @NewMachinedLotName AS NewMachinedLotName, @ConsumptionEventId AS ConsumptionEventId,
                   @ProductionEventId AS ProductionEventId;
            RETURN;
        END

        SELECT @BomId = BomId, @MachinedItem = ParentItemId FROM @Matches;

        -- ---- 6. Eligibility (OI-18 / FDS-02-012 / FDS-03-014 hierarchy cascade): the
        -- SOURCE Item must resolve at the Cell OR any ancestor tier (Cell -> WorkCenter
        -- -> Area -> Site) via v_EffectiveItemLocation (BomDerived leg = the machined Item
        -- is Direct-eligible here, so the cast/trim child line is BomDerived-eligible). ----
        IF NOT EXISTS (
            SELECT 1 FROM Parts.v_EffectiveItemLocation
            WHERE ItemId = @SourceItem
              AND LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@CellLocationId)))
        BEGIN
            SET @Message = N'Item is not eligible at the specified location.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @SourceLotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewMachinedLotId AS NewId,
                   @NewMachinedLotName AS NewMachinedLotName, @ConsumptionEventId AS ConsumptionEventId,
                   @ProductionEventId AS ProductionEventId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- ---- 7. Inline-mint the machined LotName (mirror of Lots.IdentifierSequence_Next,
        -- as Lot_Create does inline). Minted INSIDE the txn so a rollback un-burns
        -- the counter (B6). Inlined (not EXEC'd) for the INSERT-EXEC nesting reason. ----
        DECLARE @SeqLast   BIGINT,
                @SeqEnd    BIGINT,
                @SeqFormat NVARCHAR(50),
                @SeqPrefix NVARCHAR(50),
                @SeqPad    INT;

        SELECT @SeqLast   = s.LastValue + 1,
               @SeqEnd    = s.EndingValue,
               @SeqFormat = s.FormatString
        FROM Lots.IdentifierSequence s WITH (ROWLOCK, UPDLOCK, HOLDLOCK)
        WHERE s.Code = N'Lot';

        IF @SeqLast IS NULL
            RAISERROR(N'Identifier sequence ''Lot'' is not configured.', 16, 1);
        IF @SeqLast > @SeqEnd
            RAISERROR(N'Identifier sequence ''Lot'' is exhausted.', 16, 1);

        UPDATE Lots.IdentifierSequence
        SET LastValue = @SeqLast, UpdatedAt = SYSUTCDATETIME()
        WHERE Code = N'Lot';

        SET @SeqPrefix = CASE WHEN CHARINDEX(N'{', @SeqFormat) > 0
                              THEN LEFT(@SeqFormat, CHARINDEX(N'{', @SeqFormat) - 1)
                              ELSE @SeqFormat END;
        SET @SeqPad = TRY_CAST(
            SUBSTRING(@SeqFormat,
                      CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) + 1,
                      CHARINDEX(N'}', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - 1)
            AS INT);
        SET @NewMachinedLotName = CASE WHEN @SeqPad IS NULL OR @SeqPad < 1
            THEN @SeqPrefix + CAST(@SeqLast AS NVARCHAR(20))
            ELSE @SeqPrefix + RIGHT(REPLICATE(N'0', @SeqPad) + CAST(@SeqLast AS NVARCHAR(20)), @SeqPad) END;

        -- ---- 8. Inline-INSERT the machined LOT (mirror of Lots.Lot_Create's column
        -- list). Machined Item, Manufactured origin, NULL Tool/Cavity (B13);
        -- piece count = source piece count (1-line BOM @ QtyPer 1). ----
        INSERT INTO Lots.Lot (
            LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            Weight, WeightUomId, ToolId, ToolCavityId, VendorLotNumber,
            MinSerialNumber, MaxSerialNumber, CurrentLocationId,
            TotalInProcess, InventoryAvailable,
            CreatedByUserId, CreatedAtTerminalId, CreatedAt
        )
        VALUES (
            @NewMachinedLotName, @MachinedItem, @ManufacturedOrigin, @GoodStatusId, @SourcePc, NULL,
            NULL, NULL, NULL, NULL, NULL,
            NULL, NULL, @CellLocationId,
            0, @SourcePc,                              -- B5 materialized: TotalInProcess / InventoryAvailable
            @AppUserId, @TerminalLocationId, SYSUTCDATETIME()
        );

        SET @NewMachinedLotId = SCOPE_IDENTITY();

        -- Side effect 1: initial status-history row (Old=NULL, New='Good').
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@NewMachinedLotId, NULL, @GoodStatusId, N'Machined LOT created by Machining IN pick.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- Side effect 2: genealogy closure self-row (Depth=0).
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
        VALUES (@NewMachinedLotId, @NewMachinedLotId, 0);

        -- Side effect 3: first-placement movement row (From=NULL).
        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@NewMachinedLotId, NULL, @CellLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- ---- 9. Workorder.ConsumptionEvent: source consumed (full piece count)
        -- into the machined LOT. ----
        INSERT INTO Workorder.ConsumptionEvent (
            WorkOrderOperationId, SourceLotId, ProducedLotId, ProducedContainerId,
            ConsumedItemId, ProducedItemId, PieceCount, LocationId,
            AppUserId, TerminalLocationId, TrayId, ProducedSerialNumber, ConsumedAt
        )
        VALUES (
            NULL, @SourceLotId, @NewMachinedLotId, NULL,
            @SourceItem, @MachinedItem, @SourcePc, @CellLocationId,
            @AppUserId, @TerminalLocationId, NULL, NULL, SYSUTCDATETIME()
        );

        SET @ConsumptionEventId = SCOPE_IDENTITY();

        -- ---- 10. Genealogy Consumption edge + B4 closure (INLINE mirror of
        -- Lots.LotGenealogy_RecordConsumption). Edge: Consumption
        -- (RelationshipTypeId=3), full source piece count. ----
        INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId)
        VALUES (@SourceLotId, @NewMachinedLotId, 3, @SourcePc, @AppUserId, @TerminalLocationId);

        -- Closure: every ancestor of the source (incl. the source self-row) becomes
        -- an ancestor of the machined LOT at depth+1. NOT EXISTS guards a PK
        -- collision against the machined self-row written above.
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
        SELECT c.AncestorLotId, @NewMachinedLotId, c.Depth + 1
        FROM Lots.LotGenealogyClosure c
        WHERE c.DescendantLotId = @SourceLotId
          AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure x
                          WHERE x.AncestorLotId = c.AncestorLotId AND x.DescendantLotId = @NewMachinedLotId);

        -- ---- 11. Checkpoint Workorder.ProductionEvent (MachiningIn) for the new
        -- machined LOT. Cumulative ShotCount = produced piece count. ----
        INSERT INTO Workorder.ProductionEvent (
            LotId, OperationTemplateId, WorkOrderOperationId, EventAt,
            ShotCount, ScrapCount, ScrapSourceId,
            WeightValue, WeightUomId, AppUserId, TerminalLocationId, Remarks
        )
        VALUES (
            @NewMachinedLotId, @MachiningInOtId, NULL, SYSUTCDATETIME(),
            @SourcePc, NULL, NULL,
            NULL, NULL, @AppUserId, @TerminalLocationId, NULL
        );

        SET @ProductionEventId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- Optional queue-override reason captured as a ProductionEventValue (FIFO
        -- override audit). Bound by the 'QueueOverrideReason' DataCollectionField if
        -- configured; silently skipped when that field is not seeded.
        IF @QueueOverrideReason IS NOT NULL AND LTRIM(RTRIM(@QueueOverrideReason)) <> N''
        BEGIN
            DECLARE @QorFieldId BIGINT = (SELECT TOP 1 Id FROM Parts.DataCollectionField WHERE Code = N'QueueOverrideReason' AND DeprecatedAt IS NULL);
            IF @QorFieldId IS NOT NULL
                INSERT INTO Workorder.ProductionEventValue (ProductionEventId, DataCollectionFieldId, Value, NumericValue, UomId, CreatedAt)
                VALUES (@ProductionEventId, @QorFieldId, LEFT(LTRIM(RTRIM(@QueueOverrideReason)), 255), NULL, NULL, SYSUTCDATETIME());
        END

        -- ---- 12. Close the source LOT (INLINE mirror of Lots.Lot_UpdateStatus:
        -- UPDATE LotStatusId Closed + a LotStatusHistory Good->Closed row). All
        -- pieces consumed into the machined LOT. ----
        DECLARE @SourceStatusId BIGINT = (SELECT LotStatusId FROM Lots.Lot WHERE Id = @SourceLotId);
        UPDATE Lots.Lot
        SET LotStatusId     = @ClosedStatusId,
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @SourceLotId;

        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@SourceLotId, @SourceStatusId, @ClosedStatusId, N'Closed by Machining IN (all pieces consumed into the machined LOT).', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- ---- 13. Audit (resolved-FK JSON + readable Description) ----
        DECLARE @SourcePart   NVARCHAR(50) = (SELECT PartNumber FROM Parts.Item WHERE Id = @SourceItem);
        DECLARE @MachinedPart NVARCHAR(50) = (SELECT PartNumber FROM Parts.Item WHERE Id = @MachinedItem);

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @NewMachinedLotName + N' ' + Audit.ufn_MidDot() + N' Machining IN ' + Audit.ufn_MidDot()
            + N' Picked ' + @SourceName + N' (' + ISNULL(@SourcePart, N'?') + N') -> '
            + ISNULL(@MachinedPart, N'?') + N', ' + CAST(@SourcePc AS NVARCHAR(20)) + N' pcs';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT s.Id, s.LotName, s.PieceCount,
                   JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name
                               FROM Parts.Item i WHERE i.Id = s.ItemId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                   JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name
                               FROM Lots.LotStatusCode sc WHERE sc.Id = s.LotStatusId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
            FROM Lots.Lot s WHERE s.Id = @SourceLotId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT m.Id, m.LotName, m.PieceCount,
                   JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name
                               FROM Parts.Item i WHERE i.Id = m.ItemId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                   JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name
                               FROM Location.Location loc WHERE loc.Id = m.CurrentLocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location,
                   JSON_QUERY((SELECT b.Id, b.VersionNumber FROM Parts.Bom b WHERE b.Id = @BomId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Bom
            FROM Lots.Lot m WHERE m.Id = @NewMachinedLotId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @CellLocationId,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @NewMachinedLotId,
            @LogEventTypeCode   = N'MachiningInPicked',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Picked ' + @SourceName + N'; machined LOT ' + @NewMachinedLotName + N' created.';
        SELECT @Status AS Status, @Message AS Message, @NewMachinedLotId AS NewId,
               @NewMachinedLotName AS NewMachinedLotName, @ConsumptionEventId AS ConsumptionEventId,
               @ProductionEventId AS ProductionEventId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status              = 0;
        SET @NewMachinedLotId    = NULL;
        SET @NewMachinedLotName  = NULL;
        SET @ConsumptionEventId  = NULL;
        SET @ProductionEventId   = NULL;
        SET @Message             = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @SourceLotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewMachinedLotId AS NewId,
               @NewMachinedLotName AS NewMachinedLotName, @ConsumptionEventId AS ConsumptionEventId,
               @ProductionEventId AS ProductionEventId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
