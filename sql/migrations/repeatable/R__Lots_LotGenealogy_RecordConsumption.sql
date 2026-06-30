-- ============================================================
-- Repeatable:  R__Lots_LotGenealogy_RecordConsumption.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: Records a single Consumption genealogy edge -- a source LOT is
--              consumed (in whole or in part) into a produced LOT -- and maintains
--              the B4 closure table transactionally beside the append-only
--              Lots.LotGenealogy edge. Narrow internal proc, called later by the
--              Phase 5 Machining IN + Phase 6 Assembly station flows (Phase 2 Task
--              4 / G2; spec section 4.2).
--
--              *** WHY @ProducedLotId IS REQUIRED (NOT NULL) ***
--              Lots.LotGenealogy.ChildLotId is NOT NULL, so a consumption edge
--              MUST point at a produced LOT. Container-only / serial-only
--              consumption (a source consumed at an assembly station that produces
--              an as-yet-unminted container or serialized part rather than a LOT)
--              is therefore OUT OF SCOPE for this proc: it is recorded by the
--              Phase 6 ConsumptionEvent table, not the LotGenealogy edge table.
--              The @ProducedContainerId / @ProducedSerialNumber params stay in the
--              signature for forward-compat with that Phase 6 path but are CURRENTLY
--              INFORMATIONAL ONLY -- this proc neither persists nor validates them.
--              A NULL @ProducedLotId is rejected with a clear message.
--
--              *** EntityId SUBJECT CHOICE ***
--              The audit row uses @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId.
--              The SOURCE is chosen as the audit subject because the consumed LOT is
--              the one whose inventory/state the operator action draws down; the
--              produced LOT is captured in the New JSON (Produced sub-object) so the
--              edge is fully reconstructable from either end.
--
--              Flow: validate required params (@SourceLotId, @ConsumedPieceCount,
--              @AppUserId) -> @SourceLotId exists -> @ConsumedPieceCount > 0 ->
--              @ProducedLotId IS NOT NULL and exists -> inline B2 not-blocked guard
--              on the SOURCE (reject if source status BlocksProduction=1 or Closed;
--              mirrors Lots.Lot_AssertNotBlocked, inlined because this proc is
--              itself captured via INSERT-EXEC by callers/tests and the guard proc
--              emits a result set) -> BEGIN TRAN -> INSERT the LotGenealogy
--              Consumption edge (RelationshipTypeId=3), capture @NewId =
--              SCOPE_IDENTITY() -> single-edge closure insert (every ancestor of the
--              source becomes an ancestor of the produced LOT at depth+1, with a NOT
--              EXISTS guard against PK collision because -- unlike split, where the
--              child is brand-new -- the produced LOT PRE-EXISTS and may already
--              carry some of these ancestors) -> Audit_LogOperation 'LotConsumed'
--              -> COMMIT -> SELECT @Status, @Message, @NewId (the new edge Id).
--
--              All REJECT paths run BEFORE BEGIN TRANSACTION and just SELECT the
--              status row (NULL NewId) + RETURN with no open transaction, so the
--              CATCH is the ONLY ROLLBACK site (ROLLBACK inside an INSERT-EXEC
--              context is illegal -- Msg 3915 -- so a validation reject must never
--              open a transaction). The CATCH ROLLBACKs, logs the failure in a
--              nested TRY/CATCH, emits the error status row, then RAISERROR (not
--              THROW).
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params (FDS-11-011).
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.LotGenealogy_RecordConsumption
    @SourceLotId           BIGINT,
    @ConsumedPieceCount    INT,
    @ProducedLotId         BIGINT        = NULL,
    @ProducedContainerId   BIGINT        = NULL,   -- forward-compat (Phase 6); informational only
    @ProducedSerialNumber  NVARCHAR(100) = NULL,   -- forward-compat (Phase 6); informational only
    @AppUserId             BIGINT,
    @TerminalLocationId    BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.LotGenealogy_RecordConsumption';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @SourceLotId AS SourceLotId, @ConsumedPieceCount AS ConsumedPieceCount,
               @ProducedLotId AS ProducedLotId, @ProducedContainerId AS ProducedContainerId,
               @ProducedSerialNumber AS ProducedSerialNumber,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @SourceName   NVARCHAR(50);
    DECLARE @StatusCode   NVARCHAR(20);
    DECLARE @StatusName   NVARCHAR(100);
    DECLARE @Blocks       BIT;
    DECLARE @ProducedName NVARCHAR(50);

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @SourceLotId IS NULL OR @ConsumedPieceCount IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (SourceLotId, ConsumedPieceCount, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @SourceLotId, @LogEventTypeCode = N'LotConsumed',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 2. Consumed piece count must be positive ----
        IF @ConsumedPieceCount <= 0
        BEGIN
            SET @Message = N'ConsumedPieceCount must be a positive integer.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @SourceLotId, @LogEventTypeCode = N'LotConsumed',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 3. Produced LOT required (ChildLotId is NOT NULL; see header) ----
        IF @ProducedLotId IS NULL
        BEGIN
            SET @Message = N'ProducedLotId is required. Container/serial-only consumption is recorded by the Phase 6 ConsumptionEvent table, not LotGenealogy.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @SourceLotId, @LogEventTypeCode = N'LotConsumed',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 4. Source LOT exists (read status for the B2 guard) ----
        SELECT @SourceName = l.LotName,
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
                @EntityId = @SourceLotId, @LogEventTypeCode = N'LotConsumed',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 5. Produced LOT exists ----
        SET @ProducedName = (SELECT LotName FROM Lots.Lot WHERE Id = @ProducedLotId);
        IF @ProducedName IS NULL
        BEGIN
            SET @Message = N'Produced LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @SourceLotId, @LogEventTypeCode = N'LotConsumed',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 6. B2 not-blocked guard on the SOURCE (inline; mirrors
        -- Lots.Lot_AssertNotBlocked). Inlined rather than EXEC'd because
        -- Lot_AssertNotBlocked emits a result set and this proc is itself
        -- captured via INSERT-EXEC. ----
        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'Source LOT is ' + @StatusName + N' (status ' + @StatusCode
                         + N') and cannot be consumed; release the hold first.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @SourceLotId, @LogEventTypeCode = N'LotConsumed',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- Genealogy edge: Consumption (RelationshipTypeId=3), consumed share as PieceCount.
        INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId)
        VALUES (@SourceLotId, @ProducedLotId, 3, @ConsumedPieceCount, @AppUserId, @TerminalLocationId);

        SET @NewId = SCOPE_IDENTITY();

        -- Closure (B4): every ancestor of the source (incl. the source's own
        -- self-row) becomes an ancestor of the produced LOT at depth+1. The NOT
        -- EXISTS guard avoids a PK collision when the produced LOT already carries
        -- one of these ancestors (the produced LOT pre-exists and may have its own
        -- closure history, unlike a brand-new split child). On a duplicate
        -- (ancestor, produced) the existing row's depth wins -- acceptable for
        -- consumption per the spec.
        -- NOTE: the kept Depth reflects the order edges were recorded, not the shortest path.
        -- The closure table is authoritative for REACHABILITY (does ancestor A reach descendant D?),
        -- not for exact level. A future read proc that filters WHERE Depth = N must not assume the
        -- stored Depth is the minimum across all paths.
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
        SELECT c.AncestorLotId, @ProducedLotId, c.Depth + 1
        FROM Lots.LotGenealogyClosure c
        WHERE c.DescendantLotId = @SourceLotId
          AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure x
                          WHERE x.AncestorLotId = c.AncestorLotId AND x.DescendantLotId = @ProducedLotId);

        -- ---- Audit (resolved-FK JSON + readable Description) ----
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @SourceName + N' ' + Audit.ufn_MidDot() + N' Consumed ' + Audit.ufn_MidDot()
            + N' ' + CAST(@ConsumedPieceCount AS NVARCHAR(20)) + N' pcs into ' + @ProducedName;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT @ConsumedPieceCount AS ConsumedPieceCount,
                   JSON_QUERY((SELECT s.Id, s.LotName FROM Lots.Lot s WHERE s.Id = @SourceLotId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Source,
                   JSON_QUERY((SELECT p.Id, p.LotName FROM Lots.Lot p WHERE p.Id = @ProducedLotId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Produced,
                   JSON_QUERY((SELECT rt.Id, rt.Code, rt.Name FROM Lots.GenealogyRelationshipType rt WHERE rt.Id = 3
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS RelationshipType
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @SourceLotId,
            @LogEventTypeCode   = N'LotConsumed',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT ' + @SourceName + N' consumed (' + CAST(@ConsumedPieceCount AS NVARCHAR(20))
                     + N' pcs) into ' + @ProducedName + N'.';
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
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @SourceLotId, @LogEventTypeCode = N'LotConsumed',
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
