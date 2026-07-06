-- ============================================================
-- Repeatable:  R__Workorder_TrimOut_Record.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-06
-- Version:     1.1
-- Description: Arc 2 Phase 4 (spec sec 4.3). The Trim OUT 1:1 WHOLE-LOT move
--              (FDS-06-006): writes a closing Workorder.ProductionEvent checkpoint
--              for the LOT, then moves the WHOLE LOT to @DestinationCellLocationId,
--              depositing it into that Machining line's FIFO queue (read by Phase 5
--              via Lots.Lot_GetWipQueueByLocation). The parent LOT STAYS WHOLE AND
--              OPEN -- no split, no children, no LotGenealogy/closure rows (the
--              sub-LOT split machinery is Phase 5 Machining OUT). The LOT retains
--              its cast/trim ItemId until the Machining IN rename (Phase 5).
--
--              NO MaxParts at TrimOut (Confirm B): the destination is a FIFO-queue
--              deposit, not a lineside cap. Validates destination ELIGIBILITY only.
--
--              D1 cumulative-monotonic guard mirrored from ProductionEvent_Record
--              (new counters must be >= the LOT's prior cumulative).
--
--              v1.1 (2026-07-06, Jacques meeting): two data-integrity guards.
--              (1) @SourceLocationId (required) - the Trim zone the terminal is
--                  recording from. The LOT's CurrentLocationId must sit at/under
--                  it (ufn_AncestorLocationIds walk). After a successful OUT the
--                  LOT sits at the Machining destination, so a second OUT of the
--                  same LOT rejects here (double-checkout block).
--              (2) @ShotCount / @ScrapCount, when supplied, cannot exceed the
--                  LOT's PieceCount (counts validated against what the LOT
--                  actually contains).
--
--              Flow (FDS-11-011 + Msg-3915): ALL rejecting validations run BEFORE
--              BEGIN TRANSACTION (captured via INSERT-EXEC by callers/tests). The
--              not-blocked guard, the closing checkpoint insert, and the move are
--              INLINED (mirrors of Lot_AssertNotBlocked / ProductionEvent_Record /
--              Lot_MoveTo) rather than EXEC'd. CATCH is the only ROLLBACK site.
--              No OUTPUT params; @ProductionEventId returned in the NewId slot.
--              RAISERROR (not THROW). Audit 'TrimOutRecorded' (ProductionEvent
--              entity -> Audit.OperationLog).
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.TrimOut_Record
    @ParentLotId               BIGINT,
    @OperationTemplateId       BIGINT,
    @ShotCount                 INT    = NULL,
    @ScrapCount                INT    = NULL,
    @DestinationCellLocationId BIGINT,
    @SourceLocationId          BIGINT,
    @AppUserId                 BIGINT,
    @TerminalLocationId        BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;   -- ProductionEventId

    DECLARE @ProcName NVARCHAR(200) = N'Workorder.TrimOut_Record';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ParentLotId AS ParentLotId, @OperationTemplateId AS OperationTemplateId,
               @ShotCount AS ShotCount, @ScrapCount AS ScrapCount,
               @DestinationCellLocationId AS DestinationCellLocationId,
               @SourceLocationId AS SourceLocationId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @FromLocationId BIGINT;
    DECLARE @ItemId         BIGINT;
    DECLARE @LotPieceCount  INT;
    DECLARE @StatusCode     NVARCHAR(20);
    DECLARE @StatusName     NVARCHAR(100);
    DECLARE @Blocks         BIT;

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @ParentLotId IS NULL OR @OperationTemplateId IS NULL
           OR @DestinationCellLocationId IS NULL OR @SourceLocationId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ParentLotId, OperationTemplateId, DestinationCellLocationId, SourceLocationId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                    @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 2. OperationTemplate resolution ----
        IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = @OperationTemplateId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'OperationTemplate not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 3. LOT existence + B2 not-blocked guard (INLINED mirror of Lot_AssertNotBlocked) ----
        SELECT @FromLocationId = l.CurrentLocationId,
               @ItemId         = l.ItemId,
               @LotPieceCount  = l.PieceCount,
               @StatusCode     = sc.Code,
               @StatusName     = sc.Name,
               @Blocks         = sc.BlocksProduction
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @ParentLotId;

        IF @StatusCode IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode + N') and cannot record Trim OUT.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 3b. Source-location guard (double-checkout block, 2026-07-06) ----
        -- The LOT must currently sit at/under the Trim zone recording the OUT
        -- (ufn_AncestorLocationIds includes self). After a successful OUT the
        -- LOT's CurrentLocationId is the Machining destination, so a second OUT
        -- of the same LOT rejects here.
        IF NOT EXISTS (
            SELECT 1 FROM Location.ufn_AncestorLocationIds(@FromLocationId)
            WHERE LocationId = @SourceLocationId)
        BEGIN
            DECLARE @CurrLocName NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @FromLocationId);
            SET @Message = N'LOT is not at this Trim station (currently at '
                         + ISNULL(@CurrLocName, N'an unknown location')
                         + N'); it may already be checked out.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 4. Destination existence ----
        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @DestinationCellLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Destination location not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 5. Destination eligibility (FDS-02-012 / FDS-03-014 hierarchy cascade). NO MaxParts (Confirm B). ----
        -- Eligible at the destination Cell OR any ancestor tier (Cell -> WorkCenter
        -- -> Area -> Site), consistent with Item_ListEligibleForLocation + the
        -- Lot_Create / Lot_MoveToValidated gates.
        IF NOT EXISTS (
            SELECT 1 FROM Parts.v_EffectiveItemLocation
            WHERE ItemId = @ItemId
              AND LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@DestinationCellLocationId)))
        BEGIN
            SET @Message = N'Item is not eligible at the destination location.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 6. Counter sanity (non-negative when supplied) ----
        IF (@ShotCount IS NOT NULL AND @ShotCount < 0)
           OR (@ScrapCount IS NOT NULL AND @ScrapCount < 0)
        BEGIN
            SET @Message = N'ShotCount / ScrapCount cannot be negative.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 6b. Counts cannot exceed the LOT's piece count (2026-07-06) ----
        IF @LotPieceCount IS NOT NULL AND @ShotCount IS NOT NULL AND @ShotCount > @LotPieceCount
        BEGIN
            SET @Message = N'ShotCount ' + CAST(@ShotCount AS NVARCHAR(20))
                         + N' exceeds the LOT piece count ' + CAST(@LotPieceCount AS NVARCHAR(20)) + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @LotPieceCount IS NOT NULL AND @ScrapCount IS NOT NULL AND @ScrapCount > @LotPieceCount
        BEGIN
            SET @Message = N'ScrapCount ' + CAST(@ScrapCount AS NVARCHAR(20))
                         + N' exceeds the LOT piece count ' + CAST(@LotPieceCount AS NVARCHAR(20)) + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 7. D1 cumulative-monotonic guard (mirror of ProductionEvent_Record) ----
        DECLARE @PrevShot INT, @PrevScrap INT;
        SELECT TOP 1 @PrevShot = pe.ShotCount, @PrevScrap = pe.ScrapCount
        FROM Workorder.ProductionEvent pe
        WHERE pe.LotId = @ParentLotId
        ORDER BY pe.EventAt DESC, pe.Id DESC;

        IF @PrevShot IS NOT NULL AND @ShotCount IS NOT NULL AND @ShotCount < @PrevShot
        BEGIN
            SET @Message = N'ShotCount ' + CAST(@ShotCount AS NVARCHAR(20))
                         + N' is less than the prior cumulative ShotCount '
                         + CAST(@PrevShot AS NVARCHAR(20)) + N' (cumulative counter cannot decrease).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @PrevScrap IS NOT NULL AND @ScrapCount IS NOT NULL AND @ScrapCount < @PrevScrap
        BEGIN
            SET @Message = N'ScrapCount ' + CAST(@ScrapCount AS NVARCHAR(20))
                         + N' is less than the prior cumulative ScrapCount '
                         + CAST(@PrevScrap AS NVARCHAR(20)) + N' (cumulative counter cannot decrease).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        DECLARE @LotName NVARCHAR(50)  = (SELECT LotName FROM Lots.Lot WHERE Id = @ParentLotId);
        DECLARE @ToName  NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @DestinationCellLocationId);

        BEGIN TRANSACTION;

        -- (a) INLINED closing checkpoint (mirror of Workorder.ProductionEvent_Record).
        INSERT INTO Workorder.ProductionEvent (
            LotId, OperationTemplateId, WorkOrderOperationId, EventAt,
            ShotCount, ScrapCount, ScrapSourceId,
            WeightValue, WeightUomId, AppUserId, TerminalLocationId, Remarks
        )
        VALUES (
            @ParentLotId, @OperationTemplateId, NULL, SYSUTCDATETIME(),
            @ShotCount, @ScrapCount, NULL,
            NULL, NULL, @AppUserId, @TerminalLocationId, NULL
        );

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- (b) INLINED whole-LOT move (mirror of Lots.Lot_MoveTo). No split, no children.
        UPDATE Lots.Lot
        SET CurrentLocationId = @DestinationCellLocationId,
            UpdatedAt         = SYSUTCDATETIME(),
            UpdatedByUserId   = @AppUserId
        WHERE Id = @ParentLotId;

        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@ParentLotId, @FromLocationId, @DestinationCellLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- (c) Audit 'TrimOutRecorded' (ProductionEvent entity -> OperationLog).
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Trim ' + Audit.ufn_MidDot()
            + N' OUT to ' + @ToName
            + N' (Shots=' + ISNULL(CAST(@ShotCount AS NVARCHAR(20)), N'-')
            + N', Scrap=' + ISNULL(CAST(@ScrapCount AS NVARCHAR(20)), N'-') + N')';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT
                pe.Id, pe.ShotCount, pe.ScrapCount,
                JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                            FROM Lots.Lot l WHERE l.Id = pe.LotId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name
                            FROM Location.Location loc WHERE loc.Id = @DestinationCellLocationId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Destination,
                JSON_QUERY((SELECT ot.Id, ot.Code, ot.Name
                            FROM Parts.OperationTemplate ot WHERE ot.Id = pe.OperationTemplateId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS OperationTemplate
            FROM Workorder.ProductionEvent pe WHERE pe.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @DestinationCellLocationId,
            @LogEntityTypeCode  = N'ProductionEvent',
            @EntityId           = @NewId,
            @LogEventTypeCode   = N'TrimOutRecorded',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Trim OUT recorded; LOT moved to ' + @ToName + N'.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @ParentLotId, @LogEventTypeCode = N'TrimOutRecorded',
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
