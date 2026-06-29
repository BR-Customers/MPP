-- ============================================================
-- Repeatable:  R__Workorder_MachiningOut_AutoComplete.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-19
-- Version:     1.0
-- Description: Arc 2 Phase 5 Machining OUT - PLC-driven auto-complete on
--              NON-sublotting lines (RequiresSubLotSplit=0), FDS-06-008 +
--              FDS-05-009. The Gateway MachiningOpCompleteWatcher resolves the
--              active machined LOT at a Machining Cell on the PLC OperationComplete
--              edge and calls this proc. In one atomic transaction it:
--                * writes a closing MachiningOut Workorder.ProductionEvent
--                  checkpoint, then
--                * reads Location.Location.CoupledDownstreamCellLocationId (the
--                  typed self-FK added by migration 0019):
--                    - NON-NULL -> INLINE-move the LOT to the coupled Cell
--                      (LotMovement row + Lot.CurrentLocationId update); AutoMoved=1,
--                      ToLocationId=<coupled>; audit 'MachiningOutAutoMoved'.
--                    - NULL     -> ProductionEvent only; AutoMoved=0,
--                      ToLocationId=NULL; audit 'MachiningOutCompleted'. The LOT
--                      stays at the Cell for an operator-driven move (Phase 4
--                      Movement Scan).
--
--              *** WHY THE MOVE IS INLINED, NOT EXEC Lots.Lot_MoveTo ***
--              This proc returns its own status row and is captured by callers/
--              tests via INSERT-EXEC, so it cannot EXEC a sibling status-row proc
--              (the inner SELECT would pollute this proc's single result set, and
--              nesting INSERT-EXEC is illegal). The move is INLINED to mirror
--              Lots.Lot_MoveTo (LotMovement From/To row + Lot.CurrentLocationId
--              update). ALL rejecting validations run BEFORE BEGIN TRANSACTION
--              (each: SELECT status row + RETURN, no open txn); the CATCH (a doomed
--              XACT_ABORT exception) is the only legal ROLLBACK site (Msg 3915).
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params (FDS-11-011). Single terminal result row:
--              Status, Message, ProductionEventId, AutoMoved, ToLocationId.
--              RAISERROR (not THROW).
-- ============================================================

CREATE OR ALTER PROCEDURE Workorder.MachiningOut_AutoComplete
    @LotId              BIGINT,
    @CellLocationId     BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProductionEventId BIGINT = NULL;
    DECLARE @AutoMoved         BIT    = 0;
    DECLARE @ToLocationId      BIGINT = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Workorder.MachiningOut_AutoComplete';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @CellLocationId AS CellLocationId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LotName      NVARCHAR(50);
    DECLARE @CurrentLoc   BIGINT;
    DECLARE @StatusCode   NVARCHAR(20);
    DECLARE @StatusName   NVARCHAR(100);
    DECLARE @Blocks       BIT;
    DECLARE @Coupled      BIGINT;

    DECLARE @MachiningOutOtId BIGINT = (SELECT TOP 1 Id FROM Parts.OperationTemplate WHERE Code = N'MachiningOut' AND DeprecatedAt IS NULL ORDER BY VersionNumber DESC);

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @LotId IS NULL OR @CellLocationId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, CellLocationId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                    @EntityId = @LotId, @LogEventTypeCode = N'MachiningOutCompleted',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   @AutoMoved AS AutoMoved, @ToLocationId AS ToLocationId;
            RETURN;
        END

        -- ---- 2. MachiningOut OperationTemplate must be configured ----
        IF @MachiningOutOtId IS NULL
        BEGIN
            SET @Message = N'MachiningOut OperationTemplate is not configured.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningOutCompleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   @AutoMoved AS AutoMoved, @ToLocationId AS ToLocationId;
            RETURN;
        END

        -- ---- 3. LOT existence + at @CellLocationId + B2 not-blocked guard (INLINE
        -- mirror of Lots.Lot_AssertNotBlocked). ----
        SELECT @LotName    = l.LotName,
               @CurrentLoc = l.CurrentLocationId,
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningOutCompleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   @AutoMoved AS AutoMoved, @ToLocationId AS ToLocationId;
            RETURN;
        END

        IF @CurrentLoc <> @CellLocationId
        BEGIN
            SET @Message = N'LOT is not at the specified Machining Cell.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningOutCompleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   @AutoMoved AS AutoMoved, @ToLocationId AS ToLocationId;
            RETURN;
        END

        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode
                         + N') and cannot record Machining OUT; release the hold first.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningOutCompleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
                   @AutoMoved AS AutoMoved, @ToLocationId AS ToLocationId;
            RETURN;
        END

        -- Read the coupled downstream Cell (typed self-FK from migration 0019).
        SET @Coupled = (SELECT CoupledDownstreamCellLocationId FROM Location.Location WHERE Id = @CellLocationId);

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- ---- 4. Closing MachiningOut checkpoint (mirror of ProductionEvent_Record). ----
        INSERT INTO Workorder.ProductionEvent (
            LotId, OperationTemplateId, WorkOrderOperationId, EventAt,
            ShotCount, ScrapCount, ScrapSourceId,
            WeightValue, WeightUomId, AppUserId, TerminalLocationId, Remarks
        )
        VALUES (
            @LotId, @MachiningOutOtId, NULL, SYSUTCDATETIME(),
            NULL, NULL, NULL,
            NULL, NULL, @AppUserId, @TerminalLocationId, NULL
        );

        SET @ProductionEventId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- ---- 5. Coupled auto-move (INLINE mirror of Lots.Lot_MoveTo) or no-op. ----
        IF @Coupled IS NOT NULL
        BEGIN
            UPDATE Lots.Lot
            SET CurrentLocationId = @Coupled,
                UpdatedAt         = SYSUTCDATETIME(),
                UpdatedByUserId   = @AppUserId
            WHERE Id = @LotId;

            INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
            VALUES (@LotId, @CellLocationId, @Coupled, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

            SET @AutoMoved    = 1;
            SET @ToLocationId = @Coupled;
        END

        -- ---- 6. Audit (MachiningOutAutoMoved when coupled, else MachiningOutCompleted). ----
        DECLARE @ToName NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @ToLocationId);
        DECLARE @EventCode NVARCHAR(40) = CASE WHEN @AutoMoved = 1 THEN N'MachiningOutAutoMoved' ELSE N'MachiningOutCompleted' END;

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Machining OUT ' + Audit.ufn_MidDot() + N' '
            + CASE WHEN @AutoMoved = 1 THEN N'Auto-moved to ' + ISNULL(@ToName, N'?') + N' (coupled)' ELSE N'Completed (uncoupled; awaiting operator move)' END;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT pe.Id, pe.EventAt,
                   JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                               FROM Lots.Lot l WHERE l.Id = pe.LotId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                   JSON_QUERY((SELECT ot.Id, ot.Code, ot.Name
                               FROM Parts.OperationTemplate ot WHERE ot.Id = pe.OperationTemplateId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS OperationTemplate,
                   JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name
                               FROM Location.Location loc WHERE loc.Id = @ToLocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS AutoMovedTo
            FROM Workorder.ProductionEvent pe WHERE pe.Id = @ProductionEventId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @CellLocationId,
            @LogEntityTypeCode  = N'ProductionEvent',
            @EntityId           = @ProductionEventId,
            @LogEventTypeCode   = @EventCode,
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = CASE WHEN @AutoMoved = 1
                            THEN N'Machining OUT completed; LOT auto-moved to ' + ISNULL(@ToName, N'the coupled Cell') + N'.'
                            ELSE N'Machining OUT completed; LOT stays at the Cell (uncoupled).' END;
        SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
               @AutoMoved AS AutoMoved, @ToLocationId AS ToLocationId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status            = 0;
        SET @ProductionEventId = NULL;
        SET @AutoMoved         = 0;
        SET @ToLocationId      = NULL;
        SET @Message           = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningOutCompleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @ProductionEventId AS ProductionEventId,
               @AutoMoved AS AutoMoved, @ToLocationId AS ToLocationId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
