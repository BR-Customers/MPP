-- ============================================================
-- Repeatable:  R__Lots_ContainerRework_MovePieces.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: Moves loose pieces from a tray of one container under rework into
--              another container that is REFILL-READY (spec D1 / D2): consolidation,
--              and topping up from a finished container of new production. Moving a
--              whole tray is moving all its pieces.
--
--              GENEALOGY. Honda needs every part traceable, so a move is not a count
--              adjustment. It mints a NEW tray LOT in the receiving container for the
--              moved quantity and CONSUMES the donor tray LOT into it: one
--              Workorder.ConsumptionEvent, one Consumption genealogy edge
--              (RelationshipTypeId = 3) and the closure rows -- the same shape the
--              pass-through repack writes (R__Workorder_Assembly_CompleteTray.sql, of
--              which the LOT mint and the consume block here are INLINED MIRRORS). A
--              backward trace from the receiving container reaches the donor LOT and
--              everything behind it.
--
--              The new tray LOT is minted CLOSED (tray LOTs stay Closed in a rework,
--              spec D5), origin Manufactured, and INHERITS the donor LOT's Controlled Run
--              Tag: a tagged part does not become clean by changing boxes.
--
--              SERIALIZED part: one serial per call; the serial's ContainerSerial row
--              moves to the receiving container and its new tray, with a
--              ContainerSerialHistory row (mirror of Lots.SortCage_MigrateSerial).
--
--              The donor must itself be open for rework: any container that loses
--              pieces has had its serial voided. The receiver may not go over its target.
--
--              Returns Status, Message, NewId (the new ContainerTray in the receiver).
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-container-repack-design.md
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ContainerRework_MovePieces
    @FromContainerTrayId BIGINT,
    @ToContainerId       BIGINT,
    @Quantity            INT,
    @ContainerSerialId   BIGINT = NULL,
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.ContainerRework_MovePieces';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @FromContainerTrayId AS FromContainerTrayId, @ToContainerId AS ToContainerId, @Quantity AS Quantity, @ContainerSerialId AS ContainerSerialId, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER);
    DECLARE @Act NVARCHAR(500), @ActRaw NVARCHAR(MAX), @NewValue NVARCHAR(MAX);

    DECLARE @ContainerId BIGINT, @TrayLotId BIGINT, @TrayPieces INT, @TrayPos INT, @ConStatus NVARCHAR(50),
            @IsSerialized BIT, @ItemId BIGINT, @LotName NVARCHAR(50), @LotPieces INT, @LotCrt BIT,
            @SerialContainerId BIGINT, @SerialTrayId BIGINT, @SerialRemoved DATETIME2(3), @SerialNumber NVARCHAR(100);
    SELECT @ContainerId = t.ContainerId, @TrayLotId = t.FinishedGoodLotId, @TrayPieces = ISNULL(t.PartsClosedCount, 0),
           @TrayPos = t.TrayPosition, @ConStatus = cs.Code, @IsSerialized = ISNULL(cc.IsSerialized, 0), @ItemId = c.ItemId
    FROM Lots.ContainerTray t
    INNER JOIN Lots.Container c            ON c.Id = t.ContainerId
    INNER JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId
    LEFT JOIN Parts.ContainerConfig cc     ON cc.Id = c.ContainerConfigId
    WHERE t.Id = @FromContainerTrayId;
    SELECT @LotName = l.LotName, @LotPieces = l.PieceCount, @LotCrt = l.CrtActive FROM Lots.Lot l WHERE l.Id = @TrayLotId;
    SELECT @SerialContainerId = s.ContainerId, @SerialTrayId = s.ContainerTrayId, @SerialRemoved = s.RemovedAt,
           @SerialNumber = sp.SerialNumber
    FROM Lots.ContainerSerial s LEFT JOIN Lots.SerializedPart sp ON sp.Id = s.SerializedPartId
    WHERE s.Id = @ContainerSerialId;

    DECLARE @ToStatus NVARCHAR(50), @ToItemId BIGINT, @ToLocationId BIGINT, @ToTarget INT, @ToAccum INT,
            @ClosureMethod NVARCHAR(50), @ItemPart NVARCHAR(100);
    SELECT @ToStatus = cs.Code, @ToItemId = c.ItemId, @ToLocationId = c.CurrentLocationId,
           @ToTarget = cc.TraysPerContainer * cc.PartsPerTray
    FROM Lots.Container c
    INNER JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId
    LEFT JOIN Parts.ContainerConfig cc     ON cc.Id = c.ContainerConfigId
    WHERE c.Id = @ToContainerId;
    SET @ToAccum = ISNULL((SELECT SUM(t.PartsClosedCount) FROM Lots.ContainerTray t
                           WHERE t.ContainerId = @ToContainerId AND t.ClosedAt IS NOT NULL), 0);
    SET @ClosureMethod = (SELECT ClosureMethod FROM Lots.ContainerTray WHERE Id = @FromContainerTrayId);
    SET @ItemPart = (SELECT PartNumber FROM Parts.Item WHERE Id = @ItemId);

    BEGIN TRY
        -- ---- Validations: the FIRST rule that fails is the message. All of them
        --      run before BEGIN TRANSACTION (Msg 3915 rule). ----
        DECLARE @Reject NVARCHAR(500) = NULL;
        IF @FromContainerTrayId IS NULL OR @ToContainerId IS NULL OR @AppUserId IS NULL
            SET @Reject = N'Required parameter missing (FromContainerTrayId, ToContainerId, AppUserId).';
        IF @Reject IS NULL AND NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId AND DeprecatedAt IS NULL)
            SET @Reject = N'User not found.';
        IF @Reject IS NULL AND @ContainerId IS NULL
            SET @Reject = N'Tray not found.';
        IF @Reject IS NULL AND @TrayLotId IS NULL OR @LotName IS NULL
            SET @Reject = N'That tray has no LOT behind it and cannot be reworked here.';
        IF @Reject IS NULL AND @ConStatus NOT IN (N'ReworkProcessing', N'ReworkFilling')
            SET @Reject = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' is not open for rework.';
        IF @Reject IS NULL AND @Quantity IS NULL OR @Quantity <= 0
            SET @Reject = N'Quantity must be greater than zero.';
        IF @Reject IS NULL AND @IsSerialized = 1 AND @ContainerSerialId IS NULL
            SET @Reject = N'This part is serialized: pick the serial.';
        IF @Reject IS NULL AND @IsSerialized = 1 AND @Quantity <> 1
            SET @Reject = N'A serialized part is handled one serial at a time.';
        IF @Reject IS NULL AND @IsSerialized = 0 AND @ContainerSerialId IS NOT NULL
            SET @Reject = N'This part is not serialized: give a quantity, not a serial.';
        IF @Reject IS NULL AND @ContainerSerialId IS NOT NULL AND (@SerialContainerId IS NULL OR @SerialContainerId <> @ContainerId OR @SerialRemoved IS NOT NULL OR (@SerialTrayId IS NOT NULL AND @SerialTrayId <> @FromContainerTrayId))
            SET @Reject = N'That serial is not in this tray.';
        IF @Reject IS NULL AND @Quantity > LEAST(@LotPieces, @TrayPieces)
            SET @Reject = N'Tray ' + CAST(@TrayPos AS NVARCHAR(10)) + N' of container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' holds ' + CAST(LEAST(@LotPieces, @TrayPieces) AS NVARCHAR(10)) + N' pieces; ' + CAST(@Quantity AS NVARCHAR(10)) + N' is too many.';
        IF @Reject IS NULL AND @ToStatus IS NULL
            SET @Reject = N'Destination container not found.';
        IF @Reject IS NULL AND @ToContainerId = @ContainerId
            SET @Reject = N'Those pieces are already in that container.';
        IF @Reject IS NULL AND @ToStatus <> N'ReworkFilling'
            SET @Reject = N'Container ' + CAST(@ToContainerId AS NVARCHAR(20)) + N' is not refill-ready.';
        IF @Reject IS NULL AND @ToItemId <> @ItemId
            SET @Reject = N'Container ' + CAST(@ToContainerId AS NVARCHAR(20)) + N' holds a different part.';
        IF @Reject IS NULL AND @ToTarget IS NOT NULL AND @ToAccum + @Quantity > @ToTarget
            SET @Reject = N'Container ' + CAST(@ToContainerId AS NVARCHAR(20)) + N' has room for ' + CAST(@ToTarget - @ToAccum AS NVARCHAR(10)) + N' more pieces; ' + CAST(@Quantity AS NVARCHAR(10)) + N' is too many.';

        IF @Reject IS NOT NULL
        BEGIN
            SET @Message = @Reject;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerRework',
                    @EntityId = @ToContainerId, @LogEventTypeCode = N'ContainerPiecesMoved',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- ---- take the pieces off the CLOSED tray LOT and the tray, under a lock. The
        --      LOT is not reopened (spec D5); the container's rework status is the gate.
        --      The checks above read unlocked, so re-check here. ----
        DECLARE @NewLotPieces INT, @NewTrayPieces INT;
        UPDATE l
        SET @NewLotPieces = l.PieceCount - @Quantity, l.PieceCount = l.PieceCount - @Quantity,
            l.UpdatedAt = SYSUTCDATETIME(), l.UpdatedByUserId = @AppUserId
        FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK) WHERE l.Id = @TrayLotId;
        UPDATE t
        SET @NewTrayPieces = t.PartsClosedCount - @Quantity, t.PartsClosedCount = t.PartsClosedCount - @Quantity
        FROM Lots.ContainerTray t WITH (UPDLOCK, HOLDLOCK) WHERE t.Id = @FromContainerTrayId;
        IF @NewLotPieces < 0 OR @NewTrayPieces < 0
            RAISERROR(N'REWORK_RACE: the tray no longer holds that many pieces.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM Lots.Container WHERE Id = @ContainerId AND ContainerStatusCodeId IN (6, 7))
            RAISERROR(N'REWORK_RACE: the container is no longer open for rework.', 16, 1);

        -- the receiver: lock it and re-check status and room
        DECLARE @ToAccumNow INT;
        IF NOT EXISTS (SELECT 1 FROM Lots.Container WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ToContainerId AND ContainerStatusCodeId = 7)
            RAISERROR(N'REWORK_RACE: the destination is no longer refill-ready.', 16, 1);
        SET @ToAccumNow = ISNULL((SELECT SUM(t.PartsClosedCount) FROM Lots.ContainerTray t
                                  WHERE t.ContainerId = @ToContainerId AND t.ClosedAt IS NOT NULL), 0);
        IF @ToTarget IS NOT NULL AND @ToAccumNow + @Quantity > @ToTarget
            RAISERROR(N'REWORK_RACE: the destination no longer has room.', 16, 1);

        -- ---- mint the receiving tray LOT. INLINED MIRROR of the tray mint in
        --      Workorder.Assembly_CompleteTray (sequence 'Lot', logic of
        --      Lots.IdentifierSequence_Next), minted INSIDE the tran so a rollback
        --      un-burns the number. ----
        DECLARE @SeqLast BIGINT, @SeqEnd BIGINT, @SeqFormat NVARCHAR(50), @SeqPrefix NVARCHAR(50), @SeqPad INT,
                @MintedName NVARCHAR(50), @NewLotId BIGINT, @NewTrayPos INT;
        SELECT @SeqLast = s.LastValue + 1, @SeqEnd = s.EndingValue, @SeqFormat = s.FormatString
        FROM Lots.IdentifierSequence s WITH (ROWLOCK, UPDLOCK, HOLDLOCK)
        WHERE s.Code = N'Lot';
        IF @SeqLast IS NULL  RAISERROR(N'Identifier sequence ''Lot'' is not configured.', 16, 1);
        IF @SeqLast > @SeqEnd RAISERROR(N'Identifier sequence ''Lot'' is exhausted.', 16, 1);
        UPDATE Lots.IdentifierSequence SET LastValue = @SeqLast, UpdatedAt = SYSUTCDATETIME() WHERE Code = N'Lot';
        SET @SeqPrefix = CASE WHEN CHARINDEX(N'{', @SeqFormat) > 0
                              THEN LEFT(@SeqFormat, CHARINDEX(N'{', @SeqFormat) - 1) ELSE @SeqFormat END;
        SET @SeqPad = TRY_CAST(SUBSTRING(@SeqFormat,
                          CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) + 1,
                          CHARINDEX(N'}', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - 1) AS INT);
        SET @MintedName = CASE WHEN @SeqPad IS NULL OR @SeqPad < 1
            THEN @SeqPrefix + CAST(@SeqLast AS NVARCHAR(20))
            ELSE @SeqPrefix + RIGHT(REPLICATE(N'0', @SeqPad) + CAST(@SeqLast AS NVARCHAR(20)), @SeqPad) END;

        -- Origin Manufactured (1), status Closed (4), nothing available to consume.
        -- Manufactured matters: the pass-through repack consumes only RECEIVED-origin
        -- LOTs of the same Item, so this LOT can never be picked up as its stock.
        INSERT INTO Lots.Lot (
            LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            Weight, WeightUomId, ToolId, ToolCavityId, VendorLotNumber,
            MinSerialNumber, MaxSerialNumber, CurrentLocationId,
            TotalInProcess, InventoryAvailable,
            CreatedByUserId, CreatedAtTerminalId, CreatedAt, BomId, CrtActive)
        SELECT @MintedName, d.ItemId, 1, 4, @Quantity, d.MaxPieceCount,
               NULL, NULL, NULL, NULL, NULL,
               NULL, NULL, @ToLocationId,
               0, 0,
               @AppUserId, @TerminalLocationId, SYSUTCDATETIME(), d.BomId, d.CrtActive
        FROM Lots.Lot d WHERE d.Id = @TrayLotId;
        SET @NewLotId = CAST(SCOPE_IDENTITY() AS BIGINT);

        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@NewLotId, NULL, 4, N'Tray LOT minted closed by container repack.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@NewLotId, @NewLotId, 0);
        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@NewLotId, NULL, @ToLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        SET @NewTrayPos = ISNULL((SELECT MAX(TrayPosition) FROM Lots.ContainerTray WHERE ContainerId = @ToContainerId), 0) + 1;
        INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, FinishedGoodLotId, ClosedAt, ClosedByUserId, ClosureMethod)
        VALUES (@ToContainerId, @NewTrayPos, @Quantity, @NewLotId, SYSUTCDATETIME(), @AppUserId, @ClosureMethod);
        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- ---- the consumption: donor tray LOT -> new tray LOT, same Item. MIRROR of the
        --      consume block in Workorder.Assembly_CompleteTray. ----
        INSERT INTO Workorder.ConsumptionEvent
            (SourceLotId, ProducedLotId, ProducedContainerId, ConsumedItemId, ProducedItemId,
             PieceCount, LocationId, AppUserId, TerminalLocationId, TrayId, ProducedSerialNumber, ConsumedAt)
        VALUES (@TrayLotId, @NewLotId, @ToContainerId, @ItemId, @ItemId,
             @Quantity, @ToLocationId, @AppUserId, @TerminalLocationId, @NewId, @SerialNumber, SYSUTCDATETIME());
        INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId)
        VALUES (@TrayLotId, @NewLotId, 3, @Quantity, @AppUserId, @TerminalLocationId);
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
        SELECT c.AncestorLotId, @NewLotId, c.Depth + 1
        FROM Lots.LotGenealogyClosure c
        WHERE c.DescendantLotId = @TrayLotId
          AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure x
                          WHERE x.AncestorLotId = c.AncestorLotId AND x.DescendantLotId = @NewLotId);

        -- ---- a serialized part takes its serial with it. MIRROR of Lots.SortCage_MigrateSerial. ----
        IF @ContainerSerialId IS NOT NULL
        BEGIN
            INSERT INTO Lots.ContainerSerialHistory
                (ContainerSerialId, OldContainerId, NewContainerId, OldTrayPosition, NewTrayPosition, MigrationReasonCode, MigratedByUserId)
            SELECT s.Id, s.ContainerId, @ToContainerId, s.TrayPosition, NULL, N'SuperLotRepack', @AppUserId
            FROM Lots.ContainerSerial s WHERE s.Id = @ContainerSerialId;
            UPDATE Lots.ContainerSerial
            SET ContainerId = @ToContainerId, ContainerTrayId = @NewId, TrayPosition = NULL
            WHERE Id = @ContainerSerialId;
        END

        -- LOT birth audit, so the new LOT's own timeline starts with where it came from
        SET @ActRaw = @MintedName + N' ' + Audit.ufn_MidDot() + N' Lot ' + Audit.ufn_MidDot()
                    + N' Minted by container repack from ' + @LotName + N' (' + @ItemPart + N', ' + CAST(@Quantity AS NVARCHAR(20)) + N' pcs)';
        SET @Act = Audit.ufn_TruncateActivity(@ActRaw);
        SET @NewValue = (
            SELECT l.Id, l.LotName, l.PieceCount, l.CrtActive,
                   JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id = l.ItemId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                   JSON_QUERY((SELECT @TrayLotId AS Id, @LotName AS Code, @LotName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS SourceLot
            FROM Lots.Lot l WHERE l.Id = @NewLotId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @ToLocationId,
            @LogEntityTypeCode = N'Lot', @EntityId = @NewLotId, @LogEventTypeCode = N'LotCreated',
            @LogSeverityCode = N'Info', @Description = @Act, @OldValue = NULL, @NewValue = @NewValue;

        SET @ActRaw = N'Container ' + CAST(@ToContainerId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot() + N' Rework ' + Audit.ufn_MidDot()
                    + N' + ' + CAST(@Quantity AS NVARCHAR(20)) + N' pcs from container ' + CAST(@ContainerId AS NVARCHAR(20))
                    + N' tray ' + CAST(@TrayPos AS NVARCHAR(10)) + N' (' + @LotName + N' -> ' + @MintedName + N')'
                    + CASE WHEN @SerialNumber IS NOT NULL THEN N', serial ' + @SerialNumber ELSE N'' END;
        SET @Act = Audit.ufn_TruncateActivity(@ActRaw);
        SET @NewValue = (
            SELECT @Quantity AS Quantity, @ContainerId AS FromContainerId, @FromContainerTrayId AS FromContainerTrayId,
                   @ToContainerId AS ToContainerId, @NewId AS ToContainerTrayId, @SerialNumber AS SerialNumber,
                   JSON_QUERY((SELECT @TrayLotId AS Id, @LotName AS Code, @LotName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS FromLot,
                   JSON_QUERY((SELECT @NewLotId AS Id, @MintedName AS Code, @MintedName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ToLot
            FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @ToLocationId,
            @LogEntityTypeCode = N'Container', @EntityId = @ToContainerId, @LogEventTypeCode = N'ContainerPiecesMoved',
            @LogSeverityCode = N'Info', @Description = @Act, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = CAST(@Quantity AS NVARCHAR(10)) + N' moved into container ' + CAST(@ToContainerId AS NVARCHAR(20)) + N'; it now holds ' + CAST(@ToAccumNow + @Quantity AS NVARCHAR(10)) + CASE WHEN @ToTarget IS NOT NULL THEN N' of ' + CAST(@ToTarget AS NVARCHAR(10)) ELSE N'' END + N'.';
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

        -- EXPECTED: the pre-transaction checks read unlocked; something changed in between.
        -- Everything is rolled back; say so plainly and do not re-raise.
        DECLARE @Race BIT = CASE WHEN @ErrMsg LIKE N'REWORK_RACE%' THEN 1 ELSE 0 END;
        IF @Race = 1
            SET @Message = N'A container changed while you were saving. Nothing was moved - reload and try again.';

        BEGIN TRY
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerRework',
                    @EntityId = @ToContainerId, @LogEventTypeCode = N'ContainerPiecesMoved',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        IF @Race = 0
            RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
