-- ============================================================
-- Repeatable:  R__Workorder_MachiningOut_RecordSplit.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-19
-- Version:     1.0
-- Description: Arc 2 Phase 5 Machining OUT - operator-driven sub-LOT split on
--              SUBLOTTING lines (RequiresSubLotSplit=1), FDS-05-009. The operator
--              completes machining and confirms an N-way split of the machined LOT
--              into N sub-LOTs, each routed to its own destination. In one atomic
--              transaction the proc:
--                * writes a closing MachiningOut Workorder.ProductionEvent
--                  checkpoint for the parent,
--                * for EACH child: mints a sub-LOT (parent-derived '<parent>-NN'
--                  name, inheriting the parent's MACHINED Item - the rename already
--                  happened at Machining IN, FDS-05-033 - NULL Tool/Cavity per B13),
--                  writes the Lots.LotGenealogy Split edge + B4 closure rows, and
--                  INLINE-moves the child to its destinationLocationId,
--                * Closes the parent (all pieces allocated to sub-LOTs).
--              Returns a multi-row result: header columns (Status, Message,
--              ProductionEventId) REPEATED on every row, plus per-child
--              (ChildLotId, ChildLotName, DestinationLocationId, PieceCount).
--
--              *** WHY EVERY SUB-MUTATION IS INLINED (the canonical N-child split) ***
--              This is the same constraint Lot_Split solved (see
--              R__Lots_Lot_Split.sql header): this proc returns its OWN multi-row
--              result set and is captured via INSERT-EXEC, so it CANNOT EXEC
--              Lots.Lot_Split (mint+edge+closure), Lots.Lot_MoveTo (per-child move),
--              or Lots.Lot_UpdateStatus (parent close) -- each emits a status-row
--              SELECT that would pollute this result set, and nesting INSERT-EXEC is
--              illegal. So child creation MIRRORS Lot_Split's inlined child INSERT
--              (LotStatusHistory 'Good' / LotGenealogyClosure self-row Depth=0 /
--              first LotMovement From=NULL / Split edge RelationshipTypeId=1 /
--              ancestor depth+1 closure), the per-child move MIRRORS Lots.Lot_MoveTo,
--              and the parent close MIRRORS Lots.Lot_UpdateStatus. The child LotName
--              is the parent-derived '-NN' suffix (NOT minted from
--              IdentifierSequence_Next, per spec sec 2.2; B6 not consulted).
--
--              ALL rejecting validations run BEFORE BEGIN TRANSACTION (each: SELECT
--              the single error row [NULL child cols] + RETURN, no open txn) because
--              a ROLLBACK inside an INSERT-EXEC-captured proc throws Msg 3915 -- the
--              CATCH (a doomed XACT_ABORT exception) is the ONLY legal ROLLBACK site.
--
--              Validation: parent exists + open + not-blocked; OPENJSON parse;
--              >=1 child; every pieceCount>0; every destination valid + non-deprecated;
--              SUM(pieceCount) == parent.PieceCount (a full allocation -> parent
--              Closed; this is a SPLIT-AND-CLOSE, not the partial Lot_Split).
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params (FDS-11-011). Audit 'MachiningOutSubLotSplit' (Lot subject =
--              parent) INSIDE the txn. RAISERROR (not THROW).
-- ============================================================

CREATE OR ALTER PROCEDURE Workorder.MachiningOut_RecordSplit
    @ParentLotId         BIGINT,
    @OperationTemplateId BIGINT,
    @SplitChildrenJson   NVARCHAR(MAX),
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProductionEventId BIGINT = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Workorder.MachiningOut_RecordSplit';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ParentLotId AS ParentLotId, @OperationTemplateId AS OperationTemplateId,
               @SplitChildrenJson AS SplitChildrenJson,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- Parsed children (ordinal-numbered) + minted-child output.
    DECLARE @Input    TABLE (Ord INT IDENTITY(1,1), PieceCount INT, DestinationLocationId BIGINT);
    DECLARE @Children TABLE (Seq INT IDENTITY(1,1), ChildLotId BIGINT, ChildLotName NVARCHAR(50), DestinationLocationId BIGINT, PieceCount INT);

    DECLARE @ParentName   NVARCHAR(50);
    DECLARE @ParentItem   BIGINT;
    DECLARE @ParentOrigin BIGINT;
    DECLARE @ParentPc     INT;
    DECLARE @ParentStatus BIGINT;
    DECLARE @StatusCode   NVARCHAR(20);
    DECLARE @StatusName   NVARCHAR(100);
    DECLARE @Blocks       BIT;
    DECLARE @ParentLoc    BIGINT;

    DECLARE @GoodStatusId   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @ClosedStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @ParentLotId IS NULL OR @OperationTemplateId IS NULL OR @SplitChildrenJson IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ParentLotId, OperationTemplateId, SplitChildrenJson, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @ParentLotId, @LogEventTypeCode = N'MachiningOutSubLotSplit',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS BIGINT) AS DestinationLocationId, CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        -- ---- 2. OperationTemplate resolution ----
        IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = @OperationTemplateId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'OperationTemplate not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'MachiningOutSubLotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS BIGINT) AS DestinationLocationId, CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        -- ---- 3. Parse @SplitChildrenJson ----
        BEGIN TRY
            INSERT INTO @Input (PieceCount, DestinationLocationId)
            SELECT j.pieceCount, j.destinationLocationId
            FROM OPENJSON(@SplitChildrenJson)
                 WITH (pieceCount INT N'$.pieceCount', destinationLocationId BIGINT N'$.destinationLocationId') j;
        END TRY
        BEGIN CATCH
            SET @Message = N'SplitChildrenJson is not valid JSON.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'MachiningOutSubLotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS BIGINT) AS DestinationLocationId, CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END CATCH

        DECLARE @ChildCount INT = (SELECT COUNT(*) FROM @Input);

        -- ---- 4. >=1 child ----
        IF @ChildCount < 1
        BEGIN
            SET @Message = N'At least one split child is required.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'MachiningOutSubLotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS BIGINT) AS DestinationLocationId, CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        -- ---- 5. Every pieceCount > 0 ----
        IF EXISTS (SELECT 1 FROM @Input WHERE PieceCount IS NULL OR PieceCount <= 0)
        BEGIN
            SET @Message = N'Every child pieceCount must be a positive integer.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'MachiningOutSubLotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS BIGINT) AS DestinationLocationId, CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        -- ---- 6. Every destination supplied + valid (non-deprecated) ----
        IF EXISTS (SELECT 1 FROM @Input WHERE DestinationLocationId IS NULL)
        BEGIN
            SET @Message = N'Every child requires a destinationLocationId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'MachiningOutSubLotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS BIGINT) AS DestinationLocationId, CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        IF EXISTS (
            SELECT 1 FROM @Input i
            WHERE NOT EXISTS (SELECT 1 FROM Location.Location loc
                              WHERE loc.Id = i.DestinationLocationId AND loc.DeprecatedAt IS NULL))
        BEGIN
            SET @Message = N'One or more destination locations were not found or are deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'MachiningOutSubLotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS BIGINT) AS DestinationLocationId, CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        DECLARE @SumChildren INT = (SELECT SUM(PieceCount) FROM @Input);

        -- ---- 7. Parent read + B2 not-blocked guard (INLINE mirror of
        -- Lots.Lot_AssertNotBlocked). ----
        SELECT @ParentName   = l.LotName,
               @ParentItem   = l.ItemId,
               @ParentOrigin = l.LotOriginTypeId,
               @ParentPc     = l.PieceCount,
               @ParentStatus = l.LotStatusId,
               @ParentLoc    = l.CurrentLocationId,
               @StatusCode   = sc.Code,
               @StatusName   = sc.Name,
               @Blocks       = sc.BlocksProduction
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @ParentLotId;

        IF @ParentName IS NULL
        BEGIN
            SET @Message = N'Parent LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'MachiningOutSubLotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS BIGINT) AS DestinationLocationId, CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode
                         + N') and cannot be split; release the hold first.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'MachiningOutSubLotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS BIGINT) AS DestinationLocationId, CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        -- ---- 8. SUM(children) == parent.PieceCount (full allocation -> parent Closed) ----
        IF @SumChildren <> @ParentPc
        BEGIN
            SET @Message = N'Split children (' + CAST(@SumChildren AS NVARCHAR(20))
                         + N') must equal parent piece count (' + CAST(@ParentPc AS NVARCHAR(20)) + N').';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'MachiningOutSubLotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS BIGINT) AS DestinationLocationId, CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        -- ---- 9. Next '-NN' suffix ordinal (parent-derived; MAX existing + 1) ----
        DECLARE @NextOrd INT = ISNULL((
            SELECT MAX(TRY_CAST(RIGHT(LotName, 2) AS INT))
            FROM Lots.Lot
            WHERE ParentLotId = @ParentLotId
              AND LotName LIKE @ParentName + N'-[0-9][0-9]'
        ), 0) + 1;

        IF @NextOrd + @ChildCount - 1 > 99
        BEGIN
            SET @Message = N'Split would exceed 99 sublots per parent (next ordinal '
                         + CAST(@NextOrd AS NVARCHAR(10)) + N', '
                         + CAST(@ChildCount AS NVARCHAR(10)) + N' requested).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'MachiningOutSubLotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS BIGINT) AS DestinationLocationId, CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- ---- 10. Closing MachiningOut ProductionEvent for the parent. ----
        INSERT INTO Workorder.ProductionEvent (
            LotId, OperationTemplateId, WorkOrderOperationId, EventAt,
            ShotCount, ScrapCount, ScrapSourceId,
            WeightValue, WeightUomId, AppUserId, TerminalLocationId, Remarks
        )
        VALUES (
            @ParentLotId, @OperationTemplateId, NULL, SYSUTCDATETIME(),
            @ParentPc, NULL, NULL,
            NULL, NULL, @AppUserId, @TerminalLocationId, NULL
        );

        SET @ProductionEventId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- ---- 11. Mint each child (numbered WHILE loop; mirrors Lot_Split's inline
        -- child creation) + INLINE per-child move (mirrors Lots.Lot_MoveTo). ----
        DECLARE @i INT = 1;
        DECLARE @ChildPc INT, @ChildDest BIGINT, @ChildName NVARCHAR(50), @ChildId BIGINT;

        WHILE @i <= @ChildCount
        BEGIN
            SELECT @ChildPc = PieceCount, @ChildDest = DestinationLocationId
            FROM @Input WHERE Ord = @i;

            SET @ChildName = @ParentName + N'-' + RIGHT(N'0' + CAST(@NextOrd AS NVARCHAR(2)), 2);

            -- Inline child LOT INSERT -- mirrors Lots.Lot_Create's column list.
            -- Inherits the parent's MACHINED Item (rename already happened at
            -- Machining IN); sub-LOTs are Machining LOTs: Tool/Cavity NULL (B13).
            -- The child is BORN at its destination (CurrentLocationId = dest), so
            -- the first LotMovement is From=NULL -> dest (no separate move row).
            INSERT INTO Lots.Lot (
                LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
                Weight, WeightUomId, ToolId, ToolCavityId, VendorLotNumber,
                MinSerialNumber, MaxSerialNumber, ParentLotId, CurrentLocationId,
                TotalInProcess, InventoryAvailable,
                CreatedByUserId, CreatedAtTerminalId, CreatedAt
            )
            VALUES (
                @ChildName, @ParentItem, @ParentOrigin, @GoodStatusId, @ChildPc, NULL,
                NULL, NULL, NULL, NULL, NULL,
                NULL, NULL, @ParentLotId, @ChildDest,
                0, @ChildPc,                              -- B5 materialized
                @AppUserId, @TerminalLocationId, SYSUTCDATETIME()
            );

            SET @ChildId = SCOPE_IDENTITY();

            -- Side effect 1: initial status-history row (Old=NULL, New='Good').
            INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
            VALUES (@ChildId, NULL, @GoodStatusId, N'Sub-LOT created by Machining OUT split.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

            -- Side effect 2: genealogy closure self-row (Depth=0).
            INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
            VALUES (@ChildId, @ChildId, 0);

            -- Side effect 3: first-placement movement row, born at the destination
            -- (From=NULL -> dest). This is the INLINE Lot_MoveTo equivalent: the
            -- child lands at its destination in a single placement.
            INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
            VALUES (@ChildId, NULL, @ChildDest, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

            -- Genealogy edge: Split (RelationshipTypeId=1), child's share as PieceCount.
            INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId)
            VALUES (@ParentLotId, @ChildId, 1, @ChildPc, @AppUserId, @TerminalLocationId);

            -- Closure (B4): every ancestor of the parent (incl. parent self-row)
            -- becomes an ancestor of the child at depth+1.
            INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
            SELECT c.AncestorLotId, @ChildId, c.Depth + 1
            FROM Lots.LotGenealogyClosure c
            WHERE c.DescendantLotId = @ParentLotId;

            INSERT INTO @Children (ChildLotId, ChildLotName, DestinationLocationId, PieceCount)
            VALUES (@ChildId, @ChildName, @ChildDest, @ChildPc);

            SET @NextOrd = @NextOrd + 1;
            SET @i = @i + 1;
        END

        -- ---- 12. Close the parent (INLINE mirror of Lots.Lot_UpdateStatus). All
        -- pieces allocated to sub-LOTs; reduce residual to 0 + Close. ----
        INSERT INTO Lots.LotAttributeChange (LotId, AttributeName, OldValue, NewValue, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@ParentLotId, N'PieceCount', CAST(@ParentPc AS NVARCHAR(500)), N'0', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        UPDATE Lots.Lot
        SET PieceCount         = 0,
            InventoryAvailable = 0,
            LotStatusId        = @ClosedStatusId,
            UpdatedAt          = SYSUTCDATETIME(),
            UpdatedByUserId    = @AppUserId
        WHERE Id = @ParentLotId;

        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@ParentLotId, @ParentStatus, @ClosedStatusId, N'Closed by Machining OUT split (all pieces allocated to sub-LOTs).', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- ---- 13. Audit (resolved-FK JSON + readable Description) ----
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @ParentName + N' ' + Audit.ufn_MidDot() + N' Machining OUT ' + Audit.ufn_MidDot()
            + N' Split into ' + CAST(@ChildCount AS NVARCHAR(10)) + N' sub-LOT(s), '
            + CAST(@SumChildren AS NVARCHAR(20)) + N' pcs (parent Closed)';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT @ParentPc AS PieceCount,
                   JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @ParentStatus
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT l.PieceCount,
                   JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = l.LotStatusId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status,
                   JSON_QUERY((SELECT ch.ChildLotId AS Id, ch.ChildLotName AS LotName, ch.PieceCount,
                                      ch.DestinationLocationId AS DestinationId
                               FROM @Children ch ORDER BY ch.Seq
                               FOR JSON PATH)) AS Children
            FROM Lots.Lot l WHERE l.Id = @ParentLotId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @ParentLoc,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @ParentLotId,
            @LogEventTypeCode   = N'MachiningOutSubLotSplit',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT ' + @ParentName + N' split into ' + CAST(@ChildCount AS NVARCHAR(10)) + N' sub-LOT(s) at Machining OUT.';

        -- ---- Return (Option A): one row per minted child, header cols repeated ----
        SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
               c.ChildLotId, c.ChildLotName, c.DestinationLocationId, c.PieceCount
        FROM @Children c
        ORDER BY c.Seq;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status            = 0;
        SET @ProductionEventId = NULL;
        SET @Message           = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'MachiningOutSubLotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
               CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
               CAST(NULL AS BIGINT) AS DestinationLocationId, CAST(NULL AS INT) AS PieceCount;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
