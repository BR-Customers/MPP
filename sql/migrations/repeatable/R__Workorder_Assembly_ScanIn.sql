-- ============================================================
-- Repeatable:  R__Workorder_Assembly_ScanIn.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-20
-- Description: Assembly IN (Arc 2 Phase 6; FDS-06-008 uncoupled path). Moves a machined
--              component LOT into an Assembly Cell's FIFO queue so it can be consumed at
--              the fill (FDS-06-013). Unlike Machining IN, there is NO rename -- the LOT
--              keeps its identity; this is a plain LotMovement into the cell. Validates the
--              LOT's Item is a component (BomLine.ChildItemId) of an active published BOM
--              whose parent Item is produced at this Cell (Parts.ItemLocation,
--              IsConsumptionPoint = 0); a non-component LOT rejects. No OUTPUT params
--              (FDS-11-011); single terminal SELECT @Status,@Message,@NewId. Move inlined
--              (not EXEC Lot_MoveTo) per the INSERT-EXEC status-row rule; CATCH is the only
--              ROLLBACK site. Reuses the 'LotMoved' audit event.
--
-- Change Log:
--   2026-08-20 - Part-scoped CRT (design D5): added the Lots.ufn_CrtBlocksMoveTo
--                guard. This proc inlines its own move, so it never inherited
--                Lot_MoveTo's guard; an Assembly IN scan of a CRT LOT used to
--                succeed silently.
-- ============================================================

CREATE OR ALTER PROCEDURE Workorder.Assembly_ScanIn
    @LotId              BIGINT = NULL,
    @LotName            NVARCHAR(50) = NULL,
    @CellLocationId     BIGINT = NULL,
    @AppUserId          BIGINT = NULL,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @FromLocationId BIGINT, @StatusCode NVARCHAR(20), @Blocks BIT, @ItemId BIGINT;

    BEGIN TRY
        -- ---- Tier 1 ----
        IF (@LotId IS NULL AND @LotName IS NULL) OR @CellLocationId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId or LotName, CellLocationId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        -- resolve a scanned LTT (LotName) to its LotId when only the name was given
        IF @LotId IS NULL
            SET @LotId = (SELECT Id FROM Lots.Lot WHERE LotName = @LotName);

        -- ---- Tier 2: LOT exists + not blocked ----
        SELECT @FromLocationId = l.CurrentLocationId, @StatusCode = sc.Code, @Blocks = sc.BlocksProduction,
               @ItemId = l.ItemId, @LotName = l.LotName
        FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @LotId;

        IF @ItemId IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT ' + @LotName + N' is ' + @StatusCode + N' and cannot be scanned in.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @CellLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Assembly cell not found or deprecated.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- BOM-component validation: the LOT's Item must be a component of an assembly
        --      Item produced at this Cell (published BOM parent eligible here, IsConsumptionPoint=0) ----
        IF NOT EXISTS (
            SELECT 1
            FROM Parts.Bom b
            INNER JOIN Parts.BomLine bl ON bl.BomId = b.Id
            INNER JOIN Parts.ItemLocation il ON il.ItemId = b.ParentItemId
                 AND il.LocationId = @CellLocationId AND il.DeprecatedAt IS NULL AND il.IsConsumptionPoint = 0
            WHERE b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL AND bl.ChildItemId = @ItemId)
        BEGIN
            SET @Message = N'LOT ' + @LotName + N' is not a configured component for any assembly produced at this cell.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @FromLocationId = @CellLocationId
        BEGIN
            SET @Message = N'LOT ' + @LotName + N' is already at this cell (no-op).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- D5 (part-scoped CRT): a CRT LOT cannot move to a PRODUCTION destination,
        -- and an Assembly IN scan is exactly that. This proc INLINES its move rather
        -- than EXEC-ing Lots.Lot_MoveTo (the INSERT-EXEC status-row rule forbids
        -- EXEC-ing a sibling status-row proc), so it does not inherit Lot_MoveTo's
        -- guard and has to carry its own. Without it containment still holds -- the
        -- tray propagates and Lots.Container_Ship refuses -- but the operator gets no
        -- signal until Shipping refuses the container hours later.
        --
        -- Placement mirrors Lots.Lot_MoveTo: LAST of the rejecting validations (the
        -- blocked-status and BOM-component guards keep precedence) but still BEFORE
        -- BEGIN TRANSACTION, because a ROLLBACK inside a proc invoked via INSERT-EXEC
        -- throws Msg 3915. Wording is Lot_MoveTo's verbatim: the literal 'marked CRT'
        -- is what BlueRidge.Common.Ui._CRT_REFUSAL_MARKERS keys on to raise the
        -- blocking popup instead of a dismissable toast. ----
        IF (SELECT Blocked FROM Lots.ufn_CrtBlocksMoveTo(@LotId, @CellLocationId)) = 1
        BEGIN
            SET @Message = N'LOT ' + ISNULL(@LotName, N'?')
                         + N' is marked CRT and cannot be moved to a production location until Quality clears it.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- Mutation (atomic) — inline move (mirror Lots.Lot_MoveTo), no rename ----
        BEGIN TRANSACTION;

        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@LotId, @FromLocationId, @CellLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        SET @NewId = SCOPE_IDENTITY();

        UPDATE Lots.Lot SET CurrentLocationId = @CellLocationId WHERE Id = @LotId;

        DECLARE @ToName NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @CellLocationId);
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'LOT ' + @LotName + N' ' + Audit.ufn_MidDot() + N' Assembly IN ' + Audit.ufn_MidDot() + N' ' + ISNULL(@ToName, N'?'));
        DECLARE @NewValue NVARCHAR(MAX) = (SELECT JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name
            FROM Location.Location loc WHERE loc.Id = @CellLocationId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ToLocation
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @CellLocationId,
            @LogEntityTypeCode = N'Lot', @EntityId = @LotId, @LogEventTypeCode = N'LotMoved',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT scanned into assembly cell.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId = NULL;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
