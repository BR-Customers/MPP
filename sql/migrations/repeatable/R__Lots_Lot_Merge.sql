-- ============================================================
-- Repeatable:  R__Lots_Lot_Merge.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: Merges N (>=2) Good source LOTs of the SAME Item into a single
--              fresh primary output LOT (Phase 2 Task 3 / G2; spec section 4.2).
--              The output is a NEW primary LOT (fresh MESL name from
--              Lots.IdentifierSequence_Next -- NOT a sublot), with NULL Tool/Cavity
--              (blended origin; Tool-specific trace is reconstructed via the
--              genealogy walk per FDS-05-030). Each source contributes a Merge edge
--              (Lots.LotGenealogy RelationshipTypeId=2) and is Closed. Maintains the
--              B4 closure table transactionally with ancestor-dedup: shared ancestors
--              across the sources collapse to ONE (ancestor, output) row at MIN(depth)+1.
--
--              *** WHY OUTPUT + SOURCE-CLOSE ARE INLINED, NOT EXEC'd ***
--              This proc returns a single status row (SELECT @Status, @Message,
--              @NewId) and is itself captured by callers/tests via INSERT-EXEC.
--              It therefore CANNOT delegate to EXEC Lots.Lot_Create (for the output)
--              or EXEC Lots.Lot_UpdateStatus (to Close each source) -- exactly the
--              same constraint Lot_Split solved (see R__Lots_Lot_Split.sql header):
--                1. Those procs each end with a status-row SELECT. Called from inside
--                   Lot_Merge, those SELECTs would POLLUTE Lot_Merge's own single
--                   result set (multiple/odd-shaped result sets break the one-result-
--                   set JDBC rule + the test's temp-table capture).
--                2. Capturing Lot_Create's @NewId would need INSERT-EXEC ... EXEC
--                   Lots.Lot_Create -- but Lot_Merge is ITSELF invoked via
--                   INSERT-EXEC, and nesting INSERT-EXEC is illegal in SQL Server.
--              So the output LOT is INSERTed inline with the SAME side effects
--              Lot_Create produces (fresh MESL mint via the IdentifierSequence_Next
--              logic inlined inside this txn so a rollback un-burns the counter;
--              LotStatusHistory 'Good' row; LotGenealogyClosure self-row Depth=0;
--              first LotMovement From=NULL), and each source Close is INLINED
--              (UPDATE Lots.Lot SET LotStatusId=Closed + a LotStatusHistory row),
--              mirroring what Lot_UpdateStatus does internally. The blended origin
--              uses 'Manufactured' (a sensible primary-LOT origin) with Tool/Cavity
--              NULL.
--
--              Flow: validate params -> parse @SourceLotIdsJson -> validate
--              >=2 distinct sources / each exists / each not-blocked (inline B2
--              guard) / all same ItemId = @OutputItemId / all Good -> die-rank
--              compat check (only when sources differ in ToolId): for each differing
--              pair consult Tools.DieRankCompatibility (CanMix=1 compatible; CanMix=0
--              OR no-row = incompatible); any incompatible pair AND
--              @SupervisorOverride=0 -> reject; @SupervisorOverride=1 bypasses the
--              rank check entirely -> BEGIN TRAN -> inline-mint + INSERT the output
--              LOT (+ 3 side effects) -> per source: insert the Merge edge + inline-
--              Close -> closure ancestor-dedup INSERT -> Audit_LogOperation
--              'LotMerged' -> COMMIT -> SELECT @Status, @Message, @NewId.
--
--              Validations run BEFORE BEGIN TRANSACTION: this proc is invoked via
--              INSERT-EXEC, and SQL Server forbids ROLLBACK inside an INSERT-EXEC
--              context (Msg 3915). Every rejection SELECTs the single error row
--              (NewId NULL) and RETURNs with no open transaction. Only the CATCH
--              (a genuine exception where XACT_ABORT has doomed the txn) ROLLBACKs.
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params (FDS-11-011). Single terminal result row: Status, Message, NewId.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_Merge
    @SourceLotIdsJson   NVARCHAR(MAX),
    @OutputItemId       BIGINT,
    @OutputLocationId   BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL,
    @SupervisorOverride BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Lot_Merge';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @SourceLotIdsJson AS SourceLotIdsJson, @OutputItemId AS OutputItemId,
               @OutputLocationId AS OutputLocationId, @AppUserId AS AppUserId,
               @TerminalLocationId AS TerminalLocationId, @SupervisorOverride AS SupervisorOverride
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- Parsed sources (distinct) + their resolved attributes.
    DECLARE @Sources TABLE (LotId BIGINT PRIMARY KEY);

    DECLARE @GoodStatusId   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @ClosedStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
    DECLARE @MergeRelId     BIGINT = (SELECT Id FROM Lots.GenealogyRelationshipType WHERE Code = N'Merge');
    DECLARE @ManufacturedOriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @SourceLotIdsJson IS NULL OR @OutputItemId IS NULL OR @OutputLocationId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (SourceLotIdsJson, OutputItemId, OutputLocationId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotMerged',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, CAST(NULL AS BIGINT) AS NewId;
            RETURN;
        END

        -- ---- 2. Parse @SourceLotIdsJson ([id, id, ...]) -- DISTINCT sources ----
        BEGIN TRY
            INSERT INTO @Sources (LotId)
            SELECT DISTINCT TRY_CAST(j.value AS BIGINT)
            FROM OPENJSON(@SourceLotIdsJson) j
            WHERE TRY_CAST(j.value AS BIGINT) IS NOT NULL;
        END TRY
        BEGIN CATCH
            SET @Message = N'SourceLotIdsJson is not a valid JSON array of LOT ids.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotMerged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, CAST(NULL AS BIGINT) AS NewId;
            RETURN;
        END CATCH

        DECLARE @SrcCount INT = (SELECT COUNT(*) FROM @Sources);

        -- ---- 3. >=2 distinct sources ----
        IF @SrcCount < 2
        BEGIN
            SET @Message = N'At least two distinct source LOTs are required to merge.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotMerged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, CAST(NULL AS BIGINT) AS NewId;
            RETURN;
        END

        -- ---- 4. Every source exists ----
        DECLARE @Missing INT = (SELECT COUNT(*) FROM @Sources s
                                WHERE NOT EXISTS (SELECT 1 FROM Lots.Lot l WHERE l.Id = s.LotId));
        IF @Missing > 0
        BEGIN
            SET @Message = N'One or more source LOTs do not exist.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotMerged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, CAST(NULL AS BIGINT) AS NewId;
            RETURN;
        END

        -- ---- 5. FK resolution: OutputItem + OutputLocation + AppUser ----
        IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = @OutputItemId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Output Item not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotMerged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, CAST(NULL AS BIGINT) AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @OutputLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Output location not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotMerged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, CAST(NULL AS BIGINT) AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'AppUser not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotMerged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, CAST(NULL AS BIGINT) AS NewId;
            RETURN;
        END

        -- ---- 6. All sources same ItemId AND equal to @OutputItemId ----
        IF EXISTS (SELECT 1 FROM @Sources s INNER JOIN Lots.Lot l ON l.Id = s.LotId
                   WHERE l.ItemId <> @OutputItemId)
        BEGIN
            SET @Message = N'All source LOTs must share the same Item, equal to the output Item.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotMerged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, CAST(NULL AS BIGINT) AS NewId;
            RETURN;
        END

        -- ---- 7. Every source currently Good (and thus not blocked / not Closed). ----
        -- The B2 not-blocked guard is subsumed here: any non-Good status (Hold,
        -- Scrap, Closed) is rejected. The message names the offending status for
        -- a clean operator-facing reason.
        DECLARE @BadStatus NVARCHAR(20) = (
            SELECT TOP 1 sc.Code
            FROM @Sources s
            INNER JOIN Lots.Lot l ON l.Id = s.LotId
            INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
            WHERE sc.Code <> N'Good');
        IF @BadStatus IS NOT NULL
        BEGIN
            SET @Message = N'All source LOTs must be in Good status; a source is ' + @BadStatus + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotMerged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, CAST(NULL AS BIGINT) AS NewId;
            RETURN;
        END

        -- ---- 8. Die-rank compatibility (only when sources differ in ToolId) ----
        -- The rule keys off each source LOT's ToolId -> Tools.Tool.DieRankId.
        -- Build the set of DISTINCT die ranks across the sources (NULL rank --
        -- a LOT with no ToolId, or a Tool with no DieRankId -- is excluded from the
        -- pairing; the rank gate concerns Tool-bearing differing ranks only).
        -- For EACH distinct unordered rank pair, look up Tools.DieRankCompatibility
        -- canonically (RankAId <= RankBId): CanMix=1 is compatible; CanMix=0 OR
        -- no row is INCOMPATIBLE. If any pair is incompatible and there is no
        -- supervisor override, reject. @SupervisorOverride=1 skips this entirely.
        IF @SupervisorOverride = 0
        BEGIN
            -- Distinct non-NULL ranks present across the source LOTs' tools.
            DECLARE @Ranks TABLE (RankId BIGINT PRIMARY KEY);
            INSERT INTO @Ranks (RankId)
            SELECT DISTINCT t.DieRankId
            FROM @Sources s
            INNER JOIN Lots.Lot l   ON l.Id = s.LotId
            INNER JOIN Tools.Tool t ON t.Id = l.ToolId
            WHERE t.DieRankId IS NOT NULL;

            -- Only a rank check when there are 2+ distinct ranks to reconcile.
            IF (SELECT COUNT(*) FROM @Ranks) >= 2
            BEGIN
                -- An incompatible pair exists if SOME unordered distinct pair (a<b)
                -- has no compat row OR a CanMix=0 row. We test by counting pairs that
                -- are NOT proven compatible.
                DECLARE @IncompatPairs INT = (
                    SELECT COUNT(*)
                    FROM @Ranks ra
                    CROSS JOIN @Ranks rb
                    WHERE ra.RankId < rb.RankId
                      AND NOT EXISTS (
                          SELECT 1 FROM Tools.DieRankCompatibility drc
                          WHERE drc.RankAId = ra.RankId AND drc.RankBId = rb.RankId
                            AND drc.CanMix = 1));

                IF @IncompatPairs > 0
                BEGIN
                    SET @Message = N'Sources span incompatible die ranks; merge requires a supervisor override (die-rank matrix has no CanMix=1 entry for one or more pairs).';
                    EXEC Audit.Audit_LogFailure
                        @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                        @EntityId = NULL, @LogEventTypeCode = N'LotMerged',
                        @FailureReason = @Message, @ProcedureName = @ProcName,
                        @AttemptedParameters = @Params;
                    SELECT @Status AS Status, @Message AS Message, CAST(NULL AS BIGINT) AS NewId;
                    RETURN;
                END
            END
        END

        -- Output PieceCount = SUM of source PieceCounts (computed pre-tran; values
        -- are stable because sources are Good and serialized below via the inline
        -- Close. A concurrent mutation of a source between here and the txn is a
        -- genuine race surfaced through the CATCH.)
        DECLARE @OutPc INT = (SELECT SUM(l.PieceCount) FROM @Sources s INNER JOIN Lots.Lot l ON l.Id = s.LotId);

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- ---- 9. Inline-mint the output LotName (mirrors IdentifierSequence_Next).
        -- Minted INSIDE the txn so a rollback un-burns the counter (B6). Inlined
        -- (not EXEC'd) for the INSERT-EXEC nesting reason in the header. ----
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
        DECLARE @OutputName NVARCHAR(50) = CASE WHEN @SeqPad IS NULL OR @SeqPad < 1
            THEN @SeqPrefix + CAST(@SeqLast AS NVARCHAR(20))
            ELSE @SeqPrefix + RIGHT(REPLICATE(N'0', @SeqPad) + CAST(@SeqLast AS NVARCHAR(20)), @SeqPad) END;

        -- ---- 10. Inline-INSERT the output LOT -- mirrors Lots.Lot_Create's column
        -- list. Blended origin = 'Manufactured', Tool/Cavity NULL (FDS-05-030). ----
        INSERT INTO Lots.Lot (
            LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            Weight, WeightUomId, ToolId, ToolCavityId, VendorLotNumber,
            MinSerialNumber, MaxSerialNumber, CurrentLocationId,
            TotalInProcess, InventoryAvailable,
            CreatedByUserId, CreatedAtTerminalId, CreatedAt
        )
        VALUES (
            @OutputName, @OutputItemId, @ManufacturedOriginId, @GoodStatusId, @OutPc, NULL,
            NULL, NULL, NULL, NULL, NULL,
            NULL, NULL, @OutputLocationId,
            0, @OutPc,                                -- B5 materialized: TotalInProcess / InventoryAvailable
            @AppUserId, @TerminalLocationId, SYSUTCDATETIME()
        );

        SET @NewId = SCOPE_IDENTITY();

        -- Side effect 1: initial status-history row (Old=NULL, New='Good').
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@NewId, NULL, @GoodStatusId, N'Merged output LOT created.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- Side effect 2: genealogy closure self-row (Depth=0).
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
        VALUES (@NewId, @NewId, 0);

        -- Side effect 3: first-placement movement row (From=NULL).
        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@NewId, NULL, @OutputLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- ---- 11. Per source: Merge edge + inline-Close ----
        -- Merge edges: one per source (Parent=source, Child=output, Rel=Merge,
        -- PieceCount=source pc).
        INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId)
        SELECT s.LotId, @NewId, @MergeRelId, l.PieceCount, @AppUserId, @TerminalLocationId
        FROM @Sources s INNER JOIN Lots.Lot l ON l.Id = s.LotId;

        -- Inline-Close each source (mirrors Lot_UpdateStatus: UPDATE LotStatusId +
        -- a LotStatusHistory Old=Good->Closed row).
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        SELECT s.LotId, @GoodStatusId, @ClosedStatusId, N'Closed by merge (pieces folded into merged output).', @AppUserId, @TerminalLocationId, SYSUTCDATETIME()
        FROM @Sources s;

        UPDATE l
        SET l.LotStatusId    = @ClosedStatusId,
            l.UpdatedAt      = SYSUTCDATETIME(),
            l.UpdatedByUserId = @AppUserId
        FROM Lots.Lot l INNER JOIN @Sources s ON s.LotId = l.Id;

        -- ---- 12. Closure (B4) ancestor-dedup ----
        -- Every ancestor of EVERY source becomes an ancestor of the output at
        -- MIN(depth)+1. Shared ancestors across sources collapse to one row (the
        -- GROUP BY + MIN). The NOT EXISTS guards against colliding with the output
        -- self-row (O,O,0) already written above (defensive; a source is never the
        -- output).
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
        SELECT c.AncestorLotId, @NewId, MIN(c.Depth) + 1
        FROM Lots.LotGenealogyClosure c
        WHERE c.DescendantLotId IN (SELECT LotId FROM @Sources)
          AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure x
                          WHERE x.AncestorLotId = c.AncestorLotId AND x.DescendantLotId = @NewId)
        GROUP BY c.AncestorLotId;

        -- ---- 13. Audit (resolved-FK JSON + readable Description) ----
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @OutputName + N' ' + Audit.ufn_MidDot() + N' Merge ' + Audit.ufn_MidDot()
            + N' from ' + CAST(@SrcCount AS NVARCHAR(10)) + N' source LOT(s), '
            + CAST(@OutPc AS NVARCHAR(20)) + N' pcs'
            + CASE WHEN @SupervisorOverride = 1 THEN N' (supervisor override)' ELSE N'' END;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((
                SELECT l.Id, l.LotName, l.PieceCount
                FROM @Sources s INNER JOIN Lots.Lot l ON l.Id = s.LotId
                ORDER BY l.Id
                FOR JSON PATH)) AS Sources
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT l.Id, l.LotName, l.PieceCount,
                   JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name
                               FROM Parts.Item i WHERE i.Id = l.ItemId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                   JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name
                               FROM Location.Location loc WHERE loc.Id = l.CurrentLocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location,
                   JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name
                               FROM Lots.LotStatusCode sc WHERE sc.Id = l.LotStatusId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
            FROM Lots.Lot l WHERE l.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @OutputLocationId,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @NewId,
            @LogEventTypeCode   = N'LotMerged',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT ' + @OutputName + N' created by merging ' + CAST(@SrcCount AS NVARCHAR(10)) + N' source LOT(s).';
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
                @EntityId = NULL, @LogEventTypeCode = N'LotMerged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, CAST(NULL AS BIGINT) AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
