-- ============================================================
-- Repeatable:  R__Lots_Lot_Split.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-07
-- Version:     1.0
--
-- SCOPE (terminal-mint, 2026-07-07): EXCEPTION-ONLY. The standard Machining &
-- Assembly flow uses consume-MINTS (Workorder.MachiningOut_Mint /
-- Workorder.Assembly_CompleteTray, Consumption genealogy RelationshipTypeId=3),
-- NOT Split. Lot_Split remains for same-part-number divisions with NO identity
-- change (quality dispositions, holds, logistics). No standard M&A proc calls it.
--
-- Description: Splits a parent LOT into N sublot children (Phase 2 Task 2 / G2;
--              spec section 4.2 + 2.2). Each child is a parent-derived sublot
--              named '<ParentLotName>-NN' (zero-padded D2 ordinal), inheriting
--              the parent's ItemId with Tool/Cavity NULL (sublots are Machining
--              LOTs per FDS-05-023). Maintains the B4 closure table
--              transactionally beside the append-only Lots.LotGenealogy edge.
--
--              *** WHY CHILDREN ARE INLINE-CREATED, NOT EXEC Lots.Lot_Create ***
--              This proc returns its OWN multi-row result set (Option A:
--              one row per minted child, Status/Message repeated) and is itself
--              captured by callers/tests via INSERT-EXEC. Reusing Lot_Create is
--              impossible here for two compounding reasons:
--                1. Lot_Create ends with a status-row SELECT. If called from
--                   inside Lot_Split that SELECT would POLLUTE Lot_Split's own
--                   result set (multiple result sets / wrong column shape break
--                   the one-result-set JDBC rule + the test's temp-table capture).
--                2. Capturing Lot_Create's @NewId would require
--                   INSERT-EXEC ... EXEC Lots.Lot_Create -- but Lot_Split is
--                   ITSELF invoked via INSERT-EXEC, and nesting INSERT-EXEC is
--                   illegal in SQL Server.
--              So each child LOT is INSERTed inline with the SAME side effects
--              Lot_Create produces (LotStatusHistory 'Good' row, LotGenealogyClosure
--              self-row Depth=0, first LotMovement From=NULL), mirroring its INSERT
--              column list so split children are indistinguishable from
--              normally-created LOTs -- with ONE deliberate exception: MaxPieceCount
--              is set NULL for sublots (Machining LOTs, FDS-05-023; MaxLotSize is a
--              Lot_Create origin-creation constraint only). The child LotName is the parent-derived
--              suffix (NOT minted from IdentifierSequence_Next -- B6 is not
--              consulted for split children per spec section 2.2), so no sequence
--              counter is burned.
--
--              For the SAME reasons the parent PieceCount reduction and the
--              residual-0 auto-Close are INLINED here rather than delegated to
--              EXEC Lots.Lot_UpdateAttribute / EXEC Lots.Lot_UpdateStatus: those
--              procs emit status-row SELECTs that would corrupt this proc's output.
--              The inline mutations mirror what those procs do internally
--              (LotAttributeChange row + B5 InventoryAvailable maintenance for the
--              reduction; LotStatusHistory row for the Close).
--
--              Flow: validate params -> parse @ChildrenJson -> validate >=1 child
--              + all pieceCount>0 -> BEGIN TRAN -> read parent WITH
--              (UPDLOCK,HOLDLOCK) [serializes concurrent splits of THIS parent so
--              suffix allocation cannot collide] -> inline B2 not-blocked guard ->
--              SUM(children) <= parent.PieceCount -> compute next '-NN' ordinal
--              (MAX existing direct-child suffix + 1); reject if it would exceed
--              99 -> WHILE over the materialized children: build <parent>-NN name,
--              inline-INSERT the child + side effects, insert the LotGenealogy
--              Split edge + the depth+1 closure rows -> reduce parent PieceCount
--              (inline UPDATE + LotAttributeChange) -> if residual 0, inline-Close
--              (UPDATE LotStatusId + LotStatusHistory) -> Audit_LogOperation
--              'LotSplit' -> COMMIT -> SELECT the @Children rows (Option A).
--
--              Return shape (Option A): a SINGLE result set, one row per minted
--              child, columns Status, Message, ChildLotId, ChildLotName,
--              PieceCount; Status/Message repeat on every row (the success status).
--              On ANY validation/error exit BEFORE children are minted, a SINGLE
--              row is returned with the error Status/Message and NULL child
--              columns. The CATCH ROLLBACKs, emits the single-row error shape,
--              then RAISERROR (not THROW). Success audit is INSIDE the txn; the
--              multi-row result SELECT happens AFTER commit.
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params (FDS-11-011).
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_Split
    @ParentLotId        BIGINT,
    @ChildrenJson       NVARCHAR(MAX),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Lot_Split';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ParentLotId AS ParentLotId, @ChildrenJson AS ChildrenJson,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- Children staging: parsed input (ordinal-numbered) + minted-child output.
    DECLARE @Input TABLE (Ord INT IDENTITY(1,1), PieceCount INT, CurrentLocationId BIGINT);
    DECLARE @Children TABLE (Seq INT IDENTITY(1,1), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);

    DECLARE @ParentName   NVARCHAR(50);
    DECLARE @ParentItem   BIGINT;
    DECLARE @ParentOrigin BIGINT;
    DECLARE @ParentPc     INT;
    DECLARE @ParentStatus BIGINT;
    DECLARE @StatusCode   NVARCHAR(20);
    DECLARE @StatusName   NVARCHAR(100);
    DECLARE @Blocks       BIT;

    DECLARE @GoodStatusId   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @ClosedStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @ParentLotId IS NULL OR @ChildrenJson IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ParentLotId, ChildrenJson, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @ParentLotId, @LogEventTypeCode = N'LotSplit',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        -- ---- 2. Parse @ChildrenJson ----
        BEGIN TRY
            INSERT INTO @Input (PieceCount, CurrentLocationId)
            SELECT j.pieceCount, j.currentLocationId
            FROM OPENJSON(@ChildrenJson)
                 WITH (pieceCount INT N'$.pieceCount', currentLocationId BIGINT N'$.currentLocationId') j;
        END TRY
        BEGIN CATCH
            SET @Message = N'ChildrenJson is not valid JSON.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'LotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END CATCH

        DECLARE @ChildCount INT = (SELECT COUNT(*) FROM @Input);

        -- ---- 3. >=1 child ----
        IF @ChildCount < 1
        BEGIN
            SET @Message = N'At least one child specification is required.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'LotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        -- ---- 4. All child pieceCounts > 0 and locations supplied ----
        IF EXISTS (SELECT 1 FROM @Input WHERE PieceCount IS NULL OR PieceCount <= 0)
        BEGIN
            SET @Message = N'Every child pieceCount must be a positive integer.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'LotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM @Input WHERE CurrentLocationId IS NULL)
        BEGIN
            SET @Message = N'Every child requires a currentLocationId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'LotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        DECLARE @SumChildren INT = (SELECT SUM(PieceCount) FROM @Input);

        -- ---- 5..8. Parent read + ALL business validations BEFORE opening the
        -- transaction. *** WHY PRE-TRANSACTION ***: this proc is invoked via
        -- INSERT-EXEC, and SQL Server forbids ROLLBACK inside an INSERT-EXEC
        -- context (Msg 3915). So every validation that can REJECT must run before
        -- BEGIN TRANSACTION -- a rejection then just SELECTs the single error row
        -- and RETURNs with no open transaction (exactly as Lot_Create does). Only
        -- the CATCH block (a genuine exception path, where XACT_ABORT has already
        -- doomed the txn) issues ROLLBACK. The transaction below is opened only
        -- once the work is guaranteed to proceed; the authoritative re-read under
        -- UPDLOCK,HOLDLOCK inside it provides the serialization + race guard. ----
        SELECT @ParentName   = l.LotName,
               @ParentItem   = l.ItemId,
               @ParentOrigin = l.LotOriginTypeId,
               @ParentPc     = l.PieceCount,
               @ParentStatus = l.LotStatusId,
               @StatusCode   = sc.Code,
               @StatusName   = sc.Name,
               @Blocks       = sc.BlocksProduction
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @ParentLotId;

        -- ---- 5. Parent exists ----
        IF @ParentName IS NULL
        BEGIN
            SET @Message = N'Parent LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'LotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        -- ---- 6. B2 not-blocked guard (inline; mirrors Lots.Lot_AssertNotBlocked).
        -- Inlined rather than EXEC'd because Lot_AssertNotBlocked emits a result
        -- set and this proc is itself captured via INSERT-EXEC. ----
        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode + N') and cannot be split; release the hold first.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'LotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        -- ---- 7. SUM(children) <= parent.PieceCount ----
        IF @SumChildren > @ParentPc
        BEGIN
            SET @Message = N'Sum of child pieces (' + CAST(@SumChildren AS NVARCHAR(20))
                         + N') exceeds parent PieceCount (' + CAST(@ParentPc AS NVARCHAR(20)) + N').';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'LotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        -- ---- 8. Next '-NN' suffix ordinal (parent-derived; MAX existing + 1) ----
        -- Probe direct children of THIS parent whose name matches '<parent>-NN'.
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
                @EntityId = @ParentLotId, @LogEventTypeCode = N'LotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message,
                   CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
                   CAST(NULL AS INT) AS PieceCount;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- Re-read the parent under UPDLOCK,HOLDLOCK. This serializes concurrent
        -- splits of THIS parent so the '-NN' suffix allocation cannot collide (a
        -- second splitter blocks here until this txn commits/rolls back). Re-read
        -- the authoritative PieceCount/Status + re-probe the ordinal under the lock
        -- and re-validate; a mismatch versus the pre-check means a concurrent
        -- mutation slipped in between -- a genuine race, raised to the CATCH (which
        -- is the only place a ROLLBACK is legal under INSERT-EXEC, and only fires
        -- on an exception where XACT_ABORT has already doomed the txn).
        SELECT @ParentPc     = l.PieceCount,
               @ParentStatus = l.LotStatusId,
               @StatusCode   = sc.Code,
               @Blocks       = sc.BlocksProduction
        FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @ParentLotId;

        SET @NextOrd = ISNULL((
            SELECT MAX(TRY_CAST(RIGHT(LotName, 2) AS INT))
            FROM Lots.Lot
            WHERE ParentLotId = @ParentLotId
              AND LotName LIKE @ParentName + N'-[0-9][0-9]'
        ), 0) + 1;

        IF @StatusCode IS NULL OR @Blocks = 1 OR @StatusCode = N'Closed'
            OR @SumChildren > @ParentPc OR @NextOrd + @ChildCount - 1 > 99
            RAISERROR(N'Parent LOT changed during split (concurrent mutation); retry.', 16, 1);

        -- ---- 9. Mint each child (numbered WHILE loop; no cursor) ----
        DECLARE @i INT = 1;
        DECLARE @ChildPc INT, @ChildLoc BIGINT, @ChildName NVARCHAR(50), @ChildId BIGINT;

        WHILE @i <= @ChildCount
        BEGIN
            SELECT @ChildPc = PieceCount, @ChildLoc = CurrentLocationId
            FROM @Input WHERE Ord = @i;

            SET @ChildName = @ParentName + N'-' + RIGHT(N'0' + CAST(@NextOrd AS NVARCHAR(2)), 2);

            -- Inline child LOT INSERT -- mirrors Lots.Lot_Create's column list.
            -- Sublots are Machining LOTs: ToolId/ToolCavityId NULL (FDS-05-023).
            -- Origin inherits the parent's so the child's provenance matches.
            INSERT INTO Lots.Lot (
                LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
                Weight, WeightUomId, ToolId, ToolCavityId, VendorLotNumber,
                MinSerialNumber, MaxSerialNumber, ParentLotId, CurrentLocationId,
                TotalInProcess, InventoryAvailable,
                CreatedByUserId, CreatedAtTerminalId, CreatedAt
            )
            VALUES (
                @ChildName, @ParentItem, @ParentOrigin, @GoodStatusId, @ChildPc,
                NULL,   -- MaxPieceCount intentionally NULL for sublots (Machining LOTs, FDS-05-023); MaxLotSize is a Lot_Create origin-creation constraint only.
                NULL, NULL, NULL, NULL, NULL,
                NULL, NULL, @ParentLotId, @ChildLoc,
                0, @ChildPc,                              -- B5 materialized: TotalInProcess / InventoryAvailable
                @AppUserId, @TerminalLocationId, SYSUTCDATETIME()
            );

            SET @ChildId = SCOPE_IDENTITY();

            -- Side effect 1: initial status-history row (Old=NULL, New='Good').
            INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
            VALUES (@ChildId, NULL, @GoodStatusId, N'Sublot created by split.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

            -- Side effect 2: genealogy closure self-row (Depth=0).
            INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
            VALUES (@ChildId, @ChildId, 0);

            -- Side effect 3: first-placement movement row (From=NULL).
            INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
            VALUES (@ChildId, NULL, @ChildLoc, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

            -- Genealogy edge: Split (RelationshipTypeId=1), child's share as PieceCount.
            INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId)
            VALUES (@ParentLotId, @ChildId, 1, @ChildPc, @AppUserId, @TerminalLocationId);

            -- Closure (B4): every ancestor of the parent (incl. parent's self-row)
            -- becomes an ancestor of the child at depth+1.
            INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
            SELECT c.AncestorLotId, @ChildId, c.Depth + 1
            FROM Lots.LotGenealogyClosure c
            WHERE c.DescendantLotId = @ParentLotId;

            INSERT INTO @Children (ChildLotId, ChildLotName, PieceCount)
            VALUES (@ChildId, @ChildName, @ChildPc);

            SET @NextOrd = @NextOrd + 1;
            SET @i = @i + 1;
        END

        -- ---- 10. Reduce parent PieceCount (inline; mirrors Lot_UpdateAttribute) ----
        DECLARE @Residual INT = @ParentPc - @SumChildren;
        DECLARE @ParentClosed BIT = 0;   -- read later in the audit JSON; declared here (T-SQL has no block scope) for clarity.

        INSERT INTO Lots.LotAttributeChange (LotId, AttributeName, OldValue, NewValue, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@ParentLotId, N'PieceCount', CAST(@ParentPc AS NVARCHAR(500)), CAST(@Residual AS NVARCHAR(500)), @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        UPDATE Lots.Lot
        SET PieceCount         = @Residual,
            InventoryAvailable = @Residual,   -- B5 (Phase 2 simplification; no consumption yet)
            UpdatedAt          = SYSUTCDATETIME(),
            UpdatedByUserId    = @AppUserId
        WHERE Id = @ParentLotId;

        -- ---- 11. Auto-Close the parent at residual 0 (inline; mirrors Lot_UpdateStatus) ----
        IF @Residual = 0
        BEGIN
            UPDATE Lots.Lot
            SET LotStatusId     = @ClosedStatusId,
                UpdatedAt       = SYSUTCDATETIME(),
                UpdatedByUserId = @AppUserId
            WHERE Id = @ParentLotId;

            INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
            VALUES (@ParentLotId, @ParentStatus, @ClosedStatusId, N'Closed by split (all pieces allocated to sublots).', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

            SET @ParentClosed = 1;
        END

        -- ---- 12. Audit (resolved-FK JSON + readable Description) ----
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @ParentName + N' ' + Audit.ufn_MidDot() + N' Split ' + Audit.ufn_MidDot()
            + N' ' + CAST(@ChildCount AS NVARCHAR(10)) + N' sublot(s), '
            + CAST(@SumChildren AS NVARCHAR(20)) + N' pcs; residual '
            + CAST(@Residual AS NVARCHAR(20))
            + CASE WHEN @ParentClosed = 1 THEN N' (parent Closed)' ELSE N'' END;
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
                   JSON_QUERY((SELECT ch.ChildLotId AS Id, ch.ChildLotName AS LotName, ch.PieceCount
                               FROM @Children ch ORDER BY ch.Seq
                               FOR JSON PATH)) AS Children
            FROM Lots.Lot l WHERE l.Id = @ParentLotId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @ParentLotId,
            @LogEventTypeCode   = N'LotSplit',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT ' + @ParentName + N' split into ' + CAST(@ChildCount AS NVARCHAR(10)) + N' sublot(s).';

        -- ---- Return (Option A): one row per minted child, Status/Message repeated ----
        SELECT @Status AS Status, @Message AS Message,
               c.ChildLotId, c.ChildLotName, c.PieceCount
        FROM @Children c
        ORDER BY c.Seq;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'LotSplit',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message,
               CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName,
               CAST(NULL AS INT) AS PieceCount;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
