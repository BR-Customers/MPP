-- ============================================================
-- Repeatable:  R__Lots_Lot_Update.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: Full LOT header update with field-level audit (Phase 2 Task 1 /
--              G1). Mutable header fields: PieceCount, Weight, WeightUomId,
--              VendorLotNumber.
--
--              *** PARTIAL-UPDATE NULL SEMANTICS ***
--              A NULL incoming parameter means "leave this field UNCHANGED",
--              NOT "set this field to NULL". This proc has no way to set a
--              field to NULL; that is intentional for Phase 2 (none of the four
--              header fields is cleared via this surface). Each non-NULL param
--              is applied only when it DIFFERS from the current value.
--
--              Flow: validate LOT exists -> Lot_AssertNotBlocked (B2: even a
--              correction on a held LOT is rejected; release the hold first) ->
--              optimistic-lock check (LENIENT, exactly like Lot_UpdateStatus:
--              the check runs only when @RowVersion IS NOT NULL; reject on
--              mismatch) -> compute the changed-field set -> if nothing changed,
--              clean no-op (Status=1, "no changes") -> BEGIN TRAN -> for each
--              changed field, write a Lots.LotAttributeChange row -> single
--              UPDATE applying only the changed columns -> if PieceCount
--              changed, maintain the B5 materialized InventoryAvailable (Phase 2
--              simplification: equals the new PieceCount; the full event-driven
--              formula is Phase 3) -> Audit_LogOperation 'LotUpdated' with a
--              field-diff Description and resolved Old/New JSON -> COMMIT.
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params (FDS-11-011); every exit path ends
--              SELECT @Status, @Message (no @NewId for an Update). RAISERROR
--              (not THROW) in the nested CATCH with failure logging OUTSIDE the
--              rolled-back transaction.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_Update
    @LotId              BIGINT,
    @PieceCount         INT           = NULL,
    @Weight             DECIMAL(12,4) = NULL,
    @WeightUomId        BIGINT        = NULL,
    @VendorLotNumber    NVARCHAR(100) = NULL,
    @RowVersion         BINARY(8)     = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Lot_Update';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @PieceCount AS PieceCount, @Weight AS Weight,
               @WeightUomId AS WeightUomId, @VendorLotNumber AS VendorLotNumber,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LotName        NVARCHAR(50);
    DECLARE @CurRowVer      BINARY(8);
    DECLARE @CurPieceCount  INT;
    DECLARE @CurWeight      DECIMAL(12,4);
    DECLARE @CurWeightUomId BIGINT;
    DECLARE @CurVendorLot   NVARCHAR(100);
    DECLARE @StatusCode     NVARCHAR(20);
    DECLARE @StatusName     NVARCHAR(100);
    DECLARE @Blocks         BIT;

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @LotId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 2. LOT exists (read the current header into locals) ----
        SELECT @LotName        = l.LotName,
               @CurRowVer      = l.RowVersion,
               @CurPieceCount  = l.PieceCount,
               @CurWeight      = l.Weight,
               @CurWeightUomId = l.WeightUomId,
               @CurVendorLot   = l.VendorLotNumber,
               @StatusCode     = sc.Code,
               @StatusName     = sc.Name,
               @Blocks         = sc.BlocksProduction
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @LotId;

        IF @LotName IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 3. B2 not-blocked guard (inline; mirrors Lots.Lot_AssertNotBlocked).
        -- This proc is itself invoked via INSERT-EXEC by callers/tests, and
        -- nesting INSERT-EXEC of the guard is illegal, so the block check is
        -- evaluated inline. Lot_AssertNotBlocked remains the standalone guard
        -- for the Ignition layer / other callers per the B2 contract. ----
        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode + N') and is blocked; release the hold first.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 4. Optimistic-lock check (LENIENT: only when @RowVersion supplied) ----
        IF @RowVersion IS NOT NULL AND @RowVersion <> @CurRowVer
        BEGIN
            SET @Message = N'LOT was modified by another user (stale RowVersion). Reload and retry.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 5. Compute the changed-field set (NULL param = leave unchanged) ----
        -- A field changes only when the param is non-NULL AND differs from current.
        -- NULLIF-style comparisons are guarded so a NULL current value still
        -- registers a change against a non-NULL incoming value.
        -- INT (not BIT) flags so they can be summed for the change count.
        DECLARE @ChgPieceCount INT = CASE WHEN @PieceCount IS NOT NULL AND @PieceCount <> @CurPieceCount THEN 1 ELSE 0 END;
        DECLARE @ChgWeight     INT = CASE WHEN @Weight     IS NOT NULL AND (@CurWeight IS NULL OR @Weight <> @CurWeight) THEN 1 ELSE 0 END;
        DECLARE @ChgWeightUom  INT = CASE WHEN @WeightUomId IS NOT NULL AND (@CurWeightUomId IS NULL OR @WeightUomId <> @CurWeightUomId) THEN 1 ELSE 0 END;
        DECLARE @ChgVendorLot  INT = CASE WHEN @VendorLotNumber IS NOT NULL AND (@CurVendorLot IS NULL OR @VendorLotNumber <> @CurVendorLot) THEN 1 ELSE 0 END;

        DECLARE @ChangeCount INT = @ChgPieceCount + @ChgWeight + @ChgWeightUom + @ChgVendorLot;

        -- ---- 6. Clean no-op when nothing differs ----
        IF @ChangeCount = 0
        BEGIN
            SET @Status  = 1;
            SET @Message = N'No changes to apply.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Resolve WeightUomId to a readable Uom.Code for the Description prose
        -- (raw FK ids belong in the JSON, not the human-readable diff). Only runs
        -- when WeightUom actually changed, so the subselects are cheap.
        DECLARE @CurWeightUomCode NVARCHAR(50) = (SELECT Code FROM Parts.Uom WHERE Id = @CurWeightUomId);
        DECLARE @NewWeightUomCode NVARCHAR(50) = (SELECT Code FROM Parts.Uom WHERE Id = @WeightUomId);

        -- Build the field-diff Description (changed fields only).
        DECLARE @Diff NVARCHAR(MAX) = N'';
        IF @ChgPieceCount = 1
            SET @Diff = @Diff + N'PieceCount ' + CAST(@CurPieceCount AS NVARCHAR(20)) + NCHAR(8594) + CAST(@PieceCount AS NVARCHAR(20)) + N'; ';
        IF @ChgWeight = 1
            SET @Diff = @Diff + N'Weight ' + ISNULL(CAST(@CurWeight AS NVARCHAR(40)), N'(null)') + NCHAR(8594) + CAST(@Weight AS NVARCHAR(40)) + N'; ';
        IF @ChgWeightUom = 1
            SET @Diff = @Diff + N'WeightUom ' + ISNULL(@CurWeightUomCode, N'(null)') + NCHAR(8594) + ISNULL(@NewWeightUomCode, N'(null)') + N'; ';
        IF @ChgVendorLot = 1
            SET @Diff = @Diff + N'VendorLot ' + ISNULL(@CurVendorLot, N'(null)') + NCHAR(8594) + @VendorLotNumber + N'; ';

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Update ' + Audit.ufn_MidDot() + N' ' + @Diff;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        IF @ChgPieceCount = 1
            INSERT INTO Lots.LotAttributeChange (LotId, AttributeName, OldValue, NewValue, ChangedByUserId, TerminalLocationId, ChangedAt)
            VALUES (@LotId, N'PieceCount', CAST(@CurPieceCount AS NVARCHAR(500)), CAST(@PieceCount AS NVARCHAR(500)), @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        IF @ChgWeight = 1
            INSERT INTO Lots.LotAttributeChange (LotId, AttributeName, OldValue, NewValue, ChangedByUserId, TerminalLocationId, ChangedAt)
            VALUES (@LotId, N'Weight', CAST(@CurWeight AS NVARCHAR(500)), CAST(@Weight AS NVARCHAR(500)), @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        IF @ChgWeightUom = 1
            INSERT INTO Lots.LotAttributeChange (LotId, AttributeName, OldValue, NewValue, ChangedByUserId, TerminalLocationId, ChangedAt)
            VALUES (@LotId, N'WeightUomId', CAST(@CurWeightUomId AS NVARCHAR(500)), CAST(@WeightUomId AS NVARCHAR(500)), @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        IF @ChgVendorLot = 1
            INSERT INTO Lots.LotAttributeChange (LotId, AttributeName, OldValue, NewValue, ChangedByUserId, TerminalLocationId, ChangedAt)
            VALUES (@LotId, N'VendorLotNumber', @CurVendorLot, @VendorLotNumber, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- Single UPDATE: apply each column only when it changed; B5 column tracks
        -- the new PieceCount when that changed (Phase 2 simplification).
        UPDATE Lots.Lot
        SET PieceCount         = CASE WHEN @ChgPieceCount = 1 THEN @PieceCount      ELSE PieceCount      END,
            InventoryAvailable = CASE WHEN @ChgPieceCount = 1 THEN @PieceCount      ELSE InventoryAvailable END,
            Weight             = CASE WHEN @ChgWeight     = 1 THEN @Weight          ELSE Weight          END,
            WeightUomId        = CASE WHEN @ChgWeightUom  = 1 THEN @WeightUomId     ELSE WeightUomId     END,
            VendorLotNumber    = CASE WHEN @ChgVendorLot  = 1 THEN @VendorLotNumber ELSE VendorLotNumber END,
            UpdatedAt          = SYSUTCDATETIME(),
            UpdatedByUserId    = @AppUserId
        WHERE Id = @LotId;

        -- ----- Audit (resolved-FK JSON: before vs after) -----
        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT @CurPieceCount AS PieceCount, @CurWeight AS Weight,
                   JSON_QUERY((SELECT u.Id, u.Code, u.Name
                               FROM Parts.Uom u WHERE u.Id = @CurWeightUomId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS WeightUomId,
                   @CurVendorLot AS VendorLotNumber
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT l.PieceCount, l.Weight,
                   JSON_QUERY((SELECT u.Id, u.Code, u.Name
                               FROM Parts.Uom u WHERE u.Id = l.WeightUomId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS WeightUomId,
                   l.VendorLotNumber
            FROM Lots.Lot l WHERE l.Id = @LotId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @LotId,
            @LogEventTypeCode   = N'LotUpdated',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT ' + @LotName + N' updated (' + CAST(@ChangeCount AS NVARCHAR(10)) + N' field(s)).';
        SELECT @Status AS Status, @Message AS Message;
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
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
