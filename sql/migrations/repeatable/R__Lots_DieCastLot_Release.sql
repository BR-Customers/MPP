-- ============================================================
-- Repeatable:  R__Lots_DieCastLot_Release.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-29
-- Version:     1.1
-- Change:      v1.1 -- pre-transaction defect-code validation: every
--              @ScrapLinesJson[].defectCodeId must exist and be active in
--              Quality.DefectCode, else GOTO Fail with a clean Status=0
--              instead of an in-transaction FK RAISERROR (mirrors
--              RejectEvent_Record's DeprecatedAt check; parity with
--              R__Workorder_DieCastShiftOutput_Record.sql's identical fix).
-- Description: Die-Cast Per-Cavity Lifecycle (plan docs/superpowers/plans/
--              2026-07-28-diecast-per-cavity-lifecycle.md), Task 6 / Phase 3.
--              Closes an open accumulator basket: Open -> Good, moved from its
--              cell to storage (well-known 'WHSE' Location code, resolved when
--              @StorageLocationId is not supplied), carrying an OPTIONAL final
--              good-piece delta (@FinalPieceDelta) + an optional additive scrap
--              batch (@ScrapLinesJson) for the last bit of production that
--              hadn't yet been through Workorder.DieCastShiftOutput_Record.
--
--              Validations (all pre-transaction, FDS-11-011 no-OUTPUT / single
--              terminal result row):
--                required params -> AppUser exists -> LOT exists and is status
--                'Open' -> resolve @StorageLocationId (well-known 'WHSE' when
--                NULL, hard reject if still unresolved; reject if a supplied
--                @StorageLocationId does not exist) -> @ScrapLinesJson well-
--                formed JSON when supplied -> @FinalPieceDelta must not be
--                negative (mirrors DieCastShiftOutput_Record's own guard +
--                DieCastContribution's CHECK (PieceDelta >= 0); the mutation
--                below only applies the delta when > 0, so a negative value
--                must reject rather than silently no-op) -> projected
--                PieceCount (current + ISNULL(@FinalPieceDelta,0)) must be
--                > 0, else reject (an empty basket is Void's job, not
--                Release's).
--
--              Mutation (inlined per the Msg-3915 / INSERT-EXEC rule -- this
--              proc returns a status row and is itself captured via
--              INSERT-EXEC by tests/callers, so it cannot EXEC a sibling
--              status-row proc):
--                * @FinalPieceDelta > 0 -> a Workorder.DieCastContribution
--                  ledger row + row-locked Lot.PieceCount/InventoryAvailable +=
--                  (mirrors R__Workorder_DieCastShiftOutput_Record.sql's
--                  contribution block verbatim).
--                * @ScrapLinesJson present -> additive Workorder.RejectEvent
--                  rows (record-only: no PieceCount decrement, mirrors that
--                  same proc's additive-scrap block verbatim).
--                * Lots.LotStatusHistory Open -> Good; Lots.Lot LotStatusId ->
--                  Good, CurrentLocationId -> storage; Lots.LotMovement
--                  (cell -> storage); Audit.Audit_LogOperation
--                  'DieCastLotReleased' (entity 'Lot').
--
--              @NewId is always NULL -- Release closes an EXISTING lot, it
--              never mints one.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.DieCastLot_Release
    @LotId BIGINT, @StorageLocationId BIGINT = NULL, @FinalPieceDelta INT = NULL,
    @ScrapLinesJson NVARCHAR(MAX) = NULL, @ShiftId BIGINT = NULL,
    @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Lots.DieCastLot_Release';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @LotId AS LotId, @StorageLocationId AS StorageLocationId,
        @FinalPieceDelta AS FinalPieceDelta, @ShiftId AS ShiftId, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @OpenStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
    DECLARE @GoodStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @ResolvedStorageLocationId BIGINT;

    BEGIN TRY
        -- ---- validations (all pre-transaction) ----
        IF @LotId IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message = N'Required parameter missing.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN SET @Message = N'AppUser not found.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                       WHERE l.Id = @LotId AND sc.Code = N'Open')
        BEGIN SET @Message = N'LOT not found or not an open basket.'; GOTO Fail; END

        -- resolve storage location (well-known 'WHSE' when not supplied)
        SET @ResolvedStorageLocationId = @StorageLocationId;
        IF @ResolvedStorageLocationId IS NULL
            SET @ResolvedStorageLocationId = (SELECT TOP 1 Id FROM Location.Location
                WHERE Code = N'WHSE' AND DeprecatedAt IS NULL ORDER BY Id);
        IF @ResolvedStorageLocationId IS NULL
        BEGIN SET @Message = N'No storage/warehouse location configured for release.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @ResolvedStorageLocationId)
        BEGIN SET @Message = N'Storage location not found.'; GOTO Fail; END

        IF @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) <> 1
        BEGIN SET @Message = N'ScrapLinesJson is not valid JSON.'; GOTO Fail; END

        -- every scrap defectCodeId must exist and be active -- rejects gracefully
        -- here instead of hitting the FK constraint mid-transaction (mirrors
        -- R__Workorder_RejectEvent_Record.sql's DeprecatedAt check)
        IF @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) = 1 AND EXISTS (
            SELECT 1 FROM OPENJSON(@ScrapLinesJson) WITH (defectCodeId BIGINT N'$.defectCodeId') s
            WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc WHERE dc.Id = s.defectCodeId AND dc.DeprecatedAt IS NULL)
        )
        BEGIN SET @Message = N'One or more scrap defect codes are invalid or deprecated.'; GOTO Fail; END

        -- mirrors DieCastShiftOutput_Record's negative-delta guard + DieCastContribution's
        -- CHECK (PieceDelta >= 0): a negative @FinalPieceDelta must reject, not silently
        -- no-op (the mutation below only applies the delta when > 0).
        IF @FinalPieceDelta IS NOT NULL AND @FinalPieceDelta < 0
        BEGIN SET @Message = N'FinalPieceDelta cannot be negative.'; GOTO Fail; END

        -- an empty basket is Void's job, not Release's
        DECLARE @ProjectedPieceCount INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId) + ISNULL(@FinalPieceDelta, 0);
        IF @ProjectedPieceCount <= 0
        BEGIN SET @Message = N'Cannot release an empty basket; void it instead.'; GOTO Fail; END

        DECLARE @FromLocationId BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotId);
        DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);

        -- ===== mutation =====
        BEGIN TRANSACTION;

        -- final good-piece delta (inline, mirrors DieCastShiftOutput_Record's contribution block)
        IF @FinalPieceDelta IS NOT NULL AND @FinalPieceDelta > 0
        BEGIN
            INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, TerminalLocationId, EventAt)
            VALUES (@LotId, @ShiftId, @FinalPieceDelta, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
            UPDATE Lots.Lot WITH (UPDLOCK, HOLDLOCK)
            SET PieceCount = PieceCount + @FinalPieceDelta, InventoryAvailable = InventoryAvailable + @FinalPieceDelta,
                UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
            WHERE Id = @LotId;
            DECLARE @ContribAct NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
                + N' Die Cast ' + Audit.ufn_MidDot() + N' Added ' + CAST(@FinalPieceDelta AS NVARCHAR(10)) + N' pc (final)');
            EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=NULL,
                @LogEntityTypeCode=N'Lot', @EntityId=@LotId, @LogEventTypeCode=N'DieCastPieceContributed',
                @LogSeverityCode=N'Info', @Description=@ContribAct, @OldValue=NULL, @NewValue=NULL;
        END

        -- additive final scrap (inline, mirrors DieCastShiftOutput_Record's additive-reject block:
        -- record only, no PieceCount decrement)
        IF @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) = 1
            INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, RecordedAt)
            SELECT NULL, @LotId, s.defectCodeId, s.quantity, NULL, N'Die-cast final release scrap', @AppUserId, SYSUTCDATETIME()
            FROM OPENJSON(@ScrapLinesJson) WITH (defectCodeId BIGINT '$.defectCodeId', quantity INT '$.quantity') s;

        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@LotId, @OpenStatusId, @GoodStatusId, N'Die-cast basket released to storage.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        UPDATE Lots.Lot
        SET LotStatusId = @GoodStatusId, CurrentLocationId = @ResolvedStorageLocationId,
            UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        WHERE Id = @LotId;

        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@LotId, @FromLocationId, @ResolvedStorageLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
            + N' Die Cast ' + Audit.ufn_MidDot() + N' Released to storage');
        EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@ResolvedStorageLocationId,
            @LogEntityTypeCode=N'Lot', @EntityId=@LotId, @LogEventTypeCode=N'DieCastLotReleased',
            @LogSeverityCode=N'Info', @Description=@Activity, @OldValue=NULL, @NewValue=NULL;

        COMMIT TRANSACTION;

        SET @Status = 1; SET @Message = N'Basket released (' + @LotName + N').';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @NewId=NULL; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        IF @AppUserId IS NOT NULL
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@LotId,
            @LogEventTypeCode=N'DieCastLotReleased', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RAISERROR(@ErrMsg,@ErrSev,@ErrState); RETURN;
    END CATCH
Fail:
    -- Audit.FailureLog.AppUserId is NOT NULL/FK: the required-parameter branch
    -- above can reach here with @AppUserId itself NULL -- guard the audit call
    -- so that case returns cleanly instead of throwing (mirrors Lot_Create /
    -- Lots.DieCastLot_Open's identical guard).
    IF @AppUserId IS NOT NULL
        EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@LotId,
            @LogEventTypeCode=N'DieCastLotReleased', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
END;
GO
