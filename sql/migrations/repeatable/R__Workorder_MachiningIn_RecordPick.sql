-- ============================================================
-- Repeatable:  R__Workorder_MachiningIn_RecordPick.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-06
-- Version:     1.0
-- Description: Arc 2 Phase 5 Machining IN, "unworked arrivals" model (2026-07-06,
--              supersedes MachiningIn_PickAndConsume). A LOT checked into a
--              machining LINE with no prior events at the line is picked to START
--              machining: the proc records ONE Workorder.ProductionEvent
--              (MachiningIn checkpoint) against the SAME LOT and stops. The LOT
--              keeps its identity, item, status, location and piece count -- there
--              is NO new machined LOT, NO ConsumptionEvent, NO genealogy, NO BOM
--              rename, and the source is NOT closed. Component consumption belongs
--              downstream (Assembly), not here.
--
--              The event's TerminalLocationId is REQUIRED and must sit at/under the
--              LINE: this is what Lots.Lot_GetWipQueueByLocation.HasLineEvent keys
--              on, so after this pick the LOT flips to HasLineEvent=1 at the line
--              and leaves the "unworked arrivals" queue (becomes the in-process LOT).
--
--              Flow (FDS-11-011 + Msg-3915): ALL rejecting validations run BEFORE
--              BEGIN TRANSACTION (each SELECTs the status row + RETURN, no open txn);
--              CATCH is the only ROLLBACK site. No OUTPUT params; @NewId slot returns
--              the ProductionEventId. RAISERROR (not THROW). Audit 'MachiningInPicked'
--              (Lot subject = the picked LOT) inside the txn.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.MachiningIn_RecordPick
    @LotId              BIGINT,
    @LineLocationId     BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT,
    @StorageLocationId  BIGINT = NULL   -- v2 (2026-07-23): Trim Storage to claim FROM; NULL => any trim store
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;   -- ProductionEventId

    DECLARE @ProcName NVARCHAR(200) = N'Workorder.MachiningIn_RecordPick';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @LineLocationId AS LineLocationId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LotName     NVARCHAR(50);
    DECLARE @FromLoc     BIGINT;
    DECLARE @ItemId      BIGINT;
    DECLARE @PieceCount  INT;
    DECLARE @StatusCode  NVARCHAR(20);
    DECLARE @StatusName  NVARCHAR(100);
    DECLARE @Blocks      BIT;

    DECLARE @MachiningInOtId BIGINT;   -- resolved route-aware once the LOT's item is known (step 3)

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @LotId IS NULL OR @LineLocationId IS NULL OR @AppUserId IS NULL OR @TerminalLocationId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, LineLocationId, AppUserId, TerminalLocationId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @LotId, @LogEventTypeCode = N'MachiningInPicked',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 2. LOT existence + B2 not-blocked guard (INLINE mirror of Lot_AssertNotBlocked) ----
        SELECT @LotName    = l.LotName,
               @FromLoc    = l.CurrentLocationId,
               @ItemId     = l.ItemId,
               @PieceCount = l.PieceCount,
               @StatusCode = sc.Code,
               @StatusName = sc.Name,
               @Blocks     = sc.BlocksProduction
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @LotId;

        IF @LotName IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode
                         + N') and cannot be picked; release the hold first.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 3. Resolve the MachiningIn OperationTemplate off THIS LOT's route.
        -- Route-aware: template codes are M-In-A etc., NOT the role code 'MachiningIn';
        -- resolve via the OperationType role on the item's latest non-deprecated route
        -- (mirrors parts/OperationTemplate_GetForRouteRole). ----
        SET @MachiningInOtId = (
            SELECT TOP 1 ot.Id
            FROM Parts.RouteTemplate rt
            INNER JOIN Parts.RouteStep rs         ON rs.RouteTemplateId = rt.Id
            INNER JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId AND ot.DeprecatedAt IS NULL
            INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
            WHERE rt.ItemId = @ItemId AND rt.DeprecatedAt IS NULL AND oty.Code = N'MachiningIn'
            ORDER BY rt.VersionNumber DESC, rs.SequenceNumber ASC);

        IF @MachiningInOtId IS NULL
        BEGIN
            SET @Message = N'This part''s route has no active Machining IN operation template.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 4. LOT must currently sit in TRIM STORAGE (v2, 2026-07-23). The line is
        -- assigned HERE: claiming moves the LOT Trim Storage -> line (step a below), which
        -- removes it from every OTHER line's storage-filtered queue. If it is no longer in
        -- Trim Storage it was already claimed by another line. Trim Storage = InventoryLocation
        -- (def 14) under a TRIM* area; restrict to @StorageLocationId when supplied. ----
        IF NOT EXISTS (
            SELECT 1 FROM Location.Location s
            WHERE s.Id = @FromLoc AND s.LocationTypeDefinitionId = 14 AND s.DeprecatedAt IS NULL
              AND ( (@StorageLocationId IS NOT NULL AND s.Id = @StorageLocationId)
                    OR (@StorageLocationId IS NULL
                        AND EXISTS (SELECT 1 FROM Location.Location a WHERE a.Id = s.ParentLocationId AND a.Code LIKE N'TRIM%')) ))
        BEGIN
            DECLARE @FromName NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @FromLoc);
            SET @Message = N'LOT is not in Trim Storage (currently at '
                         + ISNULL(@FromName, N'an unknown location') + N'); it may already be claimed by another line.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 4b. Item must be ELIGIBLE at this line (authoritative gate; mirrors the
        -- Trim-Storage queue read filter -- never trust the client). ----
        IF NOT EXISTS (
            SELECT 1 FROM Parts.v_EffectiveItemLocation
            WHERE ItemId = @ItemId
              AND LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@LineLocationId)))
        BEGIN
            SET @Message = N'This part is not eligible at this line.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 5. Terminal must sit at/under the LINE (so the event is attributable
        -- to the line and the LOT drops off the unworked-arrivals queue) ----
        IF NOT EXISTS (
            SELECT 1 FROM Location.ufn_AncestorLocationIds(@TerminalLocationId)
            WHERE LocationId = @LineLocationId)
        BEGIN
            SET @Message = N'Terminal is not part of this line.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- (claim) Conditional whole-LOT move Trim Storage -> line. FIRST write in the txn;
        -- the WHERE re-asserts the LOT is STILL at @FromLoc (Trim Storage). If a concurrent
        -- pick on another line already moved it, @@ROWCOUNT = 0 -> nothing was written, so
        -- COMMIT the no-op (never ROLLBACK in an INSERT-EXEC-captured proc; Msg 3915) and
        -- reject the race loser cleanly. This move is what removes the LOT from every other
        -- line's storage-filtered queue.
        UPDATE Lots.Lot
        SET CurrentLocationId = @LineLocationId, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        WHERE Id = @LotId AND CurrentLocationId = @FromLoc;

        IF @@ROWCOUNT = 0
        BEGIN
            COMMIT TRANSACTION;
            SET @Message = N'LOT was just claimed by another line.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@LotId, @FromLoc, @LineLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- (a) One MachiningIn checkpoint ProductionEvent against the SAME LOT.
        INSERT INTO Workorder.ProductionEvent (
            LotId, OperationTemplateId, WorkOrderOperationId, EventAt,
            ShotCount, ScrapCount, ScrapSourceId,
            WeightValue, WeightUomId, AppUserId, TerminalLocationId, Remarks
        )
        VALUES (
            @LotId, @MachiningInOtId, NULL, SYSUTCDATETIME(),
            NULL, NULL, NULL,
            NULL, NULL, @AppUserId, @TerminalLocationId, NULL
        );

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- (b) Audit 'MachiningInPicked' (Lot subject = the picked LOT).
        DECLARE @PartNumber NVARCHAR(50) = (SELECT PartNumber FROM Parts.Item WHERE Id = @ItemId);
        DECLARE @LineName   NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @LineLocationId);

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Machining IN ' + Audit.ufn_MidDot()
            + N' Started machining (' + ISNULL(@PartNumber, N'?') + N', '
            + CAST(@PieceCount AS NVARCHAR(20)) + N' pcs) at ' + ISNULL(@LineName, N'?');
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT pe.Id, pe.EventAt,
                   JSON_QUERY((SELECT l2.Id, l2.LotName AS Code, l2.LotName AS Name
                               FROM Lots.Lot l2 WHERE l2.Id = @LotId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                   JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name
                               FROM Location.Location loc WHERE loc.Id = @LineLocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Line,
                   JSON_QUERY((SELECT ot.Id, ot.Code, ot.Name
                               FROM Parts.OperationTemplate ot WHERE ot.Id = @MachiningInOtId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS OperationTemplate
            FROM Workorder.ProductionEvent pe WHERE pe.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @LineLocationId,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @LotId,
            @LogEventTypeCode   = N'MachiningInPicked',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Machining started for ' + @LotName + N'.';
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
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningInPicked',
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
