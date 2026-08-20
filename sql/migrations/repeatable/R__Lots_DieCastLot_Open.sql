-- ============================================================
-- Repeatable:  R__Lots_DieCastLot_Open.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-20
-- Version:     1.1
-- Description: Die-Cast Per-Cavity Lifecycle (plan docs/superpowers/plans/
--              2026-07-28-diecast-per-cavity-lifecycle.md), Task 2 / Phase 1.
--              Mints ONE accumulator LOT per (Tool, ToolCavity) in status
--              'Open' (Task 1), PieceCount 0 -- the LOT that the shift-output
--              recording flow (Phase 2) will subsequently top up and, on
--              Release (Phase 3), promote to 'Good' at storage. Modeled on
--              R__Lots_Lot_Create.sql's mint mechanics (status-history row,
--              genealogy-closure self-row, first-placement movement row,
--              Audit_LogOperation) but scoped to the die-cast-open validations
--              only (no eligibility/PieceCount/PLC checks -- those don't apply
--              to an empty basket).
--
--              Validations (all pre-transaction, FDS-11-011 no-OUTPUT / single
--              terminal result row):
--                required params -> Item exists/not deprecated -> Location
--                exists -> AppUser exists -> an active Tools.ToolAssignment
--                mounts @ToolId on @CurrentLocationId -> @ToolCavityId belongs
--                to @ToolId and is Active -> @LotName is a valid 8- or 9-digit
--                external LTT (Lots.ufn_IsValidExternalLtt) and not already in
--                use -> the Item has a published route with a DieCast step ->
--                one-open-basket-per-(Tool,ToolCavity) guard.
--
--              Deviation from the task-2 brief (verbatim proc otherwise):
--              the brief's Fail: label unconditionally calls
--              Audit.Audit_LogFailure with @AppUserId = @AppUserId, but
--              Audit.FailureLog.AppUserId is NOT NULL/FK -- the very first
--              validation branch (required-parameter check) can be reached
--              with @AppUserId itself NULL, which would throw inside the
--              audit call. Lot_Create hit and fixed this exact case (see its
--              "FailureLog.AppUserId is NOT NULL + FK; only attribute the
--              failure when we have a user" comment); mirrored here by
--              guarding the Fail: audit call with IF @AppUserId IS NOT NULL.
--
-- Change Log:
--   2026-07-28 - 1.0 - Initial version (die-cast per-cavity lifecycle, Task 2).
--   2026-08-20 - 1.1 - Part-scoped CRT: resolve Lots.ufn_CrtForMint at the mint
--                      and stamp Lots.Lot.CrtActive. This IS the die-cast ORIGIN
--                      mint; the CRT design named Lot_Create for "die cast, incl.
--                      bulk open", which is stale -- Lot_Create is the receiving
--                      path -- so a CrtEnabled casting was minting clean baskets.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.DieCastLot_Open
    @ItemId BIGINT, @CurrentLocationId BIGINT, @ToolId BIGINT, @ToolCavityId BIGINT,
    @LotName NVARCHAR(50), @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Lots.DieCastLot_Open';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @ItemId AS ItemId, @CurrentLocationId AS CurrentLocationId,
        @ToolId AS ToolId, @ToolCavityId AS ToolCavityId, @LotName AS LotName, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @OpenStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
    DECLARE @ManufacturedOriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
    DECLARE @MaxLotSize INT, @CellCode NVARCHAR(50);

    BEGIN TRY
        -- ---- validations (all pre-transaction) ----
        IF @ItemId IS NULL OR @CurrentLocationId IS NULL OR @ToolId IS NULL OR @ToolCavityId IS NULL
           OR @LotName IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message = N'Required parameter missing.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = @ItemId AND DeprecatedAt IS NULL)
        BEGIN SET @Message = N'Item not found or deprecated.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @CurrentLocationId)
        BEGIN SET @Message = N'Location not found.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN SET @Message = N'AppUser not found.'; GOTO Fail; END
        -- die-cast gate: active ToolAssignment for @ToolId on the cell
        IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment WHERE ToolId = @ToolId AND CellLocationId = @CurrentLocationId AND ReleasedAt IS NULL)
        BEGIN SET @Message = N'No active die mounted for this tool at this cell.'; GOTO Fail; END
        -- cavity belongs to the tool and is Active
        IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity tc INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
                       WHERE tc.Id = @ToolCavityId AND tc.ToolId = @ToolId AND sc.Code = N'Active')
        BEGIN SET @Message = N'Cavity is not an active cavity of this tool.'; GOTO Fail; END
        -- LTT format + uniqueness
        IF Lots.ufn_IsValidExternalLtt(@LotName) = 0
        BEGIN SET @Message = N'LTT ' + @LotName + N' is not a valid external LTT (8 or 9 digits).'; GOTO Fail; END
        IF EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName = @LotName)
        BEGIN SET @Message = N'LTT ' + @LotName + N' is already in use.'; GOTO Fail; END
        -- route has a DieCast (OriginMint) step
        IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt
            INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
            INNER JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
            INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
            WHERE rt.ItemId = @ItemId AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
              AND oty.Code = N'DieCast')
        BEGIN SET @Message = N'This part has no published route with a Die Cast step.'; GOTO Fail; END
        -- one-open-per-(tool,cavity)
        IF EXISTS (SELECT 1 FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                   WHERE l.ToolId = @ToolId AND l.ToolCavityId = @ToolCavityId AND sc.Code = N'Open')
        BEGIN SET @Message = N'An open basket already exists for this cavity; release it before opening another.'; GOTO Fail; END

        SET @MaxLotSize = (SELECT MaxLotSize FROM Parts.Item WHERE Id = @ItemId);
        SET @CellCode   = (SELECT Code FROM Location.Location WHERE Id = @CurrentLocationId);

        -- D1/D2: CRT at mint. This is the die-cast ORIGIN mint -- the press terminal
        -- drives THIS proc (DieCastBody -> openDieCast / submitBulkOpen -> named query
        -- lots/DieCastLot_Open), not Lots.Lot_Create, which is the receiving path. A
        -- casting part flagged Parts.Item.CrtEnabled is the feature's headline case, so
        -- the resolver has to run here or the tag never starts at the press. Resolved
        -- in ONE place (Lots.ufn_CrtForMint): the part flag OR the minting terminal's
        -- CrtEnabled attribute. A basket open consumes no LOTs, so the propagation arm
        -- is passed NULL. Mint-time only (D3) -- nothing re-derives this later.
        DECLARE @CrtActive BIT =
            (SELECT CrtActive FROM Lots.ufn_CrtForMint(@ItemId, @TerminalLocationId, NULL));

        -- ===== mutation =====
        BEGIN TRANSACTION;
        INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            ToolId, ToolCavityId, CurrentLocationId, TotalInProcess, InventoryAvailable,
            CreatedByUserId, CreatedAtTerminalId, CreatedAt, CrtActive)
        VALUES (@LotName, @ItemId, @ManufacturedOriginId, @OpenStatusId, 0, @MaxLotSize,
            @ToolId, @ToolCavityId, @CurrentLocationId, 0, 0, @AppUserId, @TerminalLocationId, SYSUTCDATETIME(), @CrtActive);
        SET @NewId = SCOPE_IDENTITY();
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@NewId, NULL, @OpenStatusId, N'Die-cast basket opened.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@NewId, @NewId, 0);
        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@NewId, NULL, @CurrentLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
            + N' Die Cast ' + Audit.ufn_MidDot() + N' Basket opened at ' + ISNULL(@CellCode, N'?'));
        DECLARE @NewValue NVARCHAR(MAX) = (SELECT l.Id, l.LotName,
            JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id = l.ItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
            JSON_QUERY((SELECT tc.Id, tc.CavityNumber AS Code, tc.CavityNumber AS Name FROM Tools.ToolCavity tc WHERE tc.Id = l.ToolCavityId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Cavity
            FROM Lots.Lot l WHERE l.Id = @NewId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@CurrentLocationId,
            @LogEntityTypeCode=N'Lot', @EntityId=@NewId, @LogEventTypeCode=N'DieCastLotOpened',
            @LogSeverityCode=N'Info', @Description=@Activity, @OldValue=NULL, @NewValue=@NewValue;
        COMMIT TRANSACTION;

        SET @Status = 1; SET @Message = N'Basket opened (' + @LotName + N').';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @NewId=NULL; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        IF @AppUserId IS NOT NULL
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
            @LogEventTypeCode=N'DieCastLotOpened', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RAISERROR(@ErrMsg,@ErrSev,@ErrState); RETURN;
    END CATCH
Fail:
    -- Audit.FailureLog.AppUserId is NOT NULL/FK: the required-parameter branch
    -- above can reach here with @AppUserId itself NULL (no actor to attribute
    -- the failure to) -- guard the audit call so that case returns cleanly
    -- instead of throwing (mirrors Lot_Create's identical guard).
    IF @AppUserId IS NOT NULL
        EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
            @LogEventTypeCode=N'DieCastLotOpened', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
END;
GO
