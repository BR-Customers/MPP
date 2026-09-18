-- ============================================================
-- Repeatable:  R__Lots_Lot_Create.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-18
-- Version:     1.7
-- Description: Creates a LOT (status 'Good'). Phase 1 Task B core skeleton
--              (plan section "Lot core skeleton" steps 1-12; aligned to DM v1.9q +
--              FDS-05-034/-035).
--
--              v1.7 (2026-09-18, Jacques): the step-6b consumption-point cap
--              counts only USABLE stock. A LOT whose status blocks production
--              (Hold, Scrap) is not accessible, so it no longer uses up the
--              line's Max. Releasing a hold is not a check-in and is never
--              capped, so a release may leave the line over Max; further
--              check-ins are then refused until usage brings the usable
--              quantity back under Max. Matches the Line Inventory sidebar's
--              Available (Lot_GetLineInventorySummary v1.1). Step 6 (Item.MaxParts)
--              is unchanged.
--
--              v1.6 (2026-09-14, migration 0082): @ProducedAtLocationId -- the
--              die cast machine the cutover operator read off the paper tag.
--              Defaults NULL so every existing caller is unaffected. Validated
--              BEFORE BEGIN TRANSACTION as an active DieCastMachine location;
--              deliberately NOT re-checked against Parts.ItemLocation, because
--              the picker falls back to every machine for a part with no
--              machine-tier row. Written to the column and echoed into the
--              LotCreated NewValue JSON as a resolved-name ProducedAt object.
--
--              v1.5 (2026-09-13, migration 0081): the item-eligibility gate
--              is SKIPPED when the destination is a STOCK location
--              (LocationTypeDefinition.IsStockLocation = 1: InventoryLocation,
--              SupportArea, InspectionStation, InspectionLine). Eligibility
--              means "may this part be WORKED here" and storage carries no
--              eligibility rows, so every part was ineligible at the warehouse.
--              Production destinations are unaffected and still reject.
--
--              v1.1 (2026-08-20): step 6b -- consumption-point quantity cap.
--              Parts.ItemLocation.MaxQuantity (where IsConsumptionPoint=1) now caps
--              the RECEIVED-origin running on-hand total at a location, same shape
--              as the existing Item.MaxParts check (6) but scoped to configured
--              consumption points only; no configured row = unrestricted. Nearest
--              ancestor tier wins when more than one ItemLocation row applies.
--
--              v1.4 (2026-09-12): Parts.Item.MaxLotSize is now INFORMATIONAL.
--              It describes the expected basket size, not a physical limit, and a
--              basket that exceeds it is real stock someone is holding -- not an
--              error. The create succeeds and returns a note in @Message.
--              Item.MaxParts and ItemLocation.MaxQuantity still REJECT: those cap
--              what may accumulate at a location, which is a real constraint.
--
--              v1.3 (2026-09-12, migration 0080): @EntryRouteSequence + @CastDate
--              for the inventory cutover scan. Both default NULL, so every
--              existing caller is unaffected. @EntryRouteSequence must name a
--              real step on the item's active route (else the LOT would be
--              invisible at every terminal); @CastDate may not be in the future.
--              Both checks run BEFORE BEGIN TRANSACTION. A duplicate @LotName was
--              already rejected in 2b.
--
--              Flow: validate params/FKs -> validate business rules
--              (eligibility via Parts.v_EffectiveItemLocation Direct U
--              BomDerived; PieceCount vs Parts.Item.MaxLotSize is advisory only; die-cast
--              Tool/Cavity per FDS-05-034) -> BEGIN TRAN -> mint LotName via
--              Lots.IdentifierSequence_Next @Code='Lot' INSIDE the tran (so a
--              rolled-back create does not burn a counter, the point of B6) ->
--              INSERT Lot (Good, Tool/Cavity, materialized B5 cols 0/@PieceCount)
--              -> INSERT LotStatusHistory (Old=NULL, New='Good') -> INSERT
--              LotGenealogyClosure self-row (Depth=0) -> INSERT LotMovement
--              first placement (From=NULL) -> Audit_LogOperation (Lot/LotCreated)
--              -> COMMIT -> SELECT @Status, @Message, @NewId, @MintedLotName.
--
--              On any validation fail: NO tran opens, Audit_LogFailure with the
--              attempted params, early SELECT-return. CATCH: ROLLBACK, nested
--              TRY/CATCH failure log, RAISERROR (not THROW).
--
--              B1: @AppUserId + @TerminalLocationId context params.
--              No OUTPUT params (FDS-11-011). Single terminal result row:
--              Status, Message, NewId, MintedLotName.
--
--              v1.2 (2026-09-10, cavity alpha code / 0076): the D2 free-text
--              manual-cavity fallback is RETIRED. @CavityNote is gone and
--              @ToolCavityId is now unconditionally required for a die-cast
--              -origin LOT. The escape hatch existed because cavities were not
--              always configured; they are now, with parts mapped, and a LOT
--              whose cavity is untyped free text cannot be rolled up per part.
--              The legacy Lots.Lot.CavityNumber column it wrote to was dropped
--              by 0076, so the INSERT no longer names it. The audit prose reads
--              the cavity's per-part Tools.ToolCavity.CavityCode.
--
--              Die-cast determination (FDS-05-034): origin 'Manufactured' AND
--              an active Tools.ToolAssignment (ReleasedAt IS NULL) exists for
--              the Cell -> Tool/Cavity REQUIRED and validated. Other origins
--              (Received, intermediate, etc.) pass NULL Tool/Cavity.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_Create
    @ItemId             BIGINT,
    @LotOriginTypeId    BIGINT,
    @CurrentLocationId  BIGINT,
    @PieceCount         INT,
    @Weight             DECIMAL(12,4) = NULL,
    @WeightUomId        BIGINT        = NULL,
    @ToolId             BIGINT        = NULL,
    @ToolCavityId       BIGINT        = NULL,
    @VendorLotNumber    NVARCHAR(100) = NULL,
    @MinSerialNumber    INT           = NULL,
    @MaxSerialNumber    INT           = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL,
    @LotName            NVARCHAR(50)  = NULL,   -- D4: caller-supplied identity (pre-printed LTT); NULL = mint server-side (today's behavior)
    @DepositToStorage   BIT           = 0,      -- die-cast: after birth at the machine, auto-move to the Warehouse (storage). OFF by default -> other origins (receiving, etc.) unaffected.
    @EntryRouteSequence INT           = NULL,  -- cutover: route step at which this LOT joined its route. NULL = the route start (every normal mint).
    @CastDate           DATE          = NULL,  -- cutover: date read off the physical LTT. Drives FIFO for migrated stock. NULL for a normal mint.
    @ProducedAtLocationId BIGINT      = NULL   -- cutover: the die cast machine off the tag (0082). NULL for every normal mint.
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status        BIT           = 0;
    DECLARE @Message       NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId         BIGINT        = NULL;
    DECLARE @MintedLotName NVARCHAR(50)  = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Lot_Create';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ItemId AS ItemId, @LotOriginTypeId AS LotOriginTypeId,
               @CurrentLocationId AS CurrentLocationId, @PieceCount AS PieceCount,
               @ToolId AS ToolId, @ToolCavityId AS ToolCavityId,
               @VendorLotNumber AS VendorLotNumber, @AppUserId AS AppUserId,
               @TerminalLocationId AS TerminalLocationId,
               @EntryRouteSequence AS EntryRouteSequence, @CastDate AS CastDate,
               @ProducedAtLocationId AS ProducedAtLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @GoodStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @ManufacturedOriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @ItemId IS NULL OR @LotOriginTypeId IS NULL OR @CurrentLocationId IS NULL
           OR @PieceCount IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ItemId, LotOriginTypeId, CurrentLocationId, PieceCount, AppUserId).';
            -- FailureLog.AppUserId is NOT NULL + FK; only attribute the failure
            -- when the actor EXISTS -- a non-NULL but unknown id (stale session)
            -- would otherwise violate the FK inside the logger itself.
            -- when we have a user. A NULL @AppUserId rejection cannot be logged
            -- (no actor) - return cleanly without a FailureLog row.
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

        -- ---- 2. FK resolution ----
        IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = @ItemId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Item not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Lots.LotOriginType WHERE Id = @LotOriginTypeId)
        BEGIN
            SET @Message = N'LotOriginType not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @CurrentLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Current location not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'AppUser not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

        -- Die-cast-origin determination (needed by the LTT rule below AND the
        -- Tool/Cavity rule later): Manufactured origin AND an active ToolAssignment
        -- on the cell.
        DECLARE @CellHasActiveTool BIT =
            CASE WHEN @LotOriginTypeId = @ManufacturedOriginId
                   AND EXISTS (SELECT 1 FROM Tools.ToolAssignment
                               WHERE CellLocationId = @CurrentLocationId AND ReleasedAt IS NULL)
                 THEN 1 ELSE 0 END;

        -- ---- 2b. D4: @LotName (caller-supplied identity) validation ----
        -- NULL = mint server-side (the inline IdentifierSequence block below, today's
        -- behavior). Supplied = use it verbatim; do NOT advance the 'Lot' counter (the
        -- pre-printed LTT carries its own identity; burning a counter would desync).
        --
        -- Die-cast births carry the operator-scanned external LTT (bulk pre-printed by
        -- the external scheduler). It is REQUIRED and format-validated for die-cast
        -- origin; other origins keep the optional/unvalidated behavior.
        IF @CellHasActiveTool = 1 AND @LotName IS NULL
        BEGIN
            SET @Message = N'Die-cast LOT requires a scanned LTT.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

        IF @LotName IS NOT NULL
        BEGIN
            SET @LotName = LTRIM(RTRIM(@LotName));
            IF @LotName = N''
            BEGIN
                SET @Message = N'LotName cannot be blank.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                RETURN;
            END
            -- Die-cast LTT must match the external format (8 or 9 numeric digits; checksum
            -- stub). MPP's pre-printed stock is 8 digits (backlog 5.1, 2026-08-19); 9 stays
            -- legal for the LTTs already minted in Dev/Test. Single source of the rule:
            -- Lots.ufn_IsValidExternalLtt.
            IF @CellHasActiveTool = 1 AND Lots.ufn_IsValidExternalLtt(@LotName) = 0
            BEGIN
                SET @Message = N'LTT must be 8 or 9 digits.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                RETURN;
            END
            -- Friendly uniqueness pre-check (UQ_Lot_LotName is the concurrency backstop:
            -- a race that slips past surfaces as 2627/2601 in the CATCH = Status 0 row).
            IF EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName = @LotName)
            BEGIN
                SET @Message = N'LOT name ''' + @LotName + N''' already exists.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                RETURN;
            END
        END

        -- ---- 3. PieceCount sanity ----
        IF @PieceCount <= 0
        BEGIN
            SET @Message = N'PieceCount must be greater than zero.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

        -- ---- 3b. MaxLotSize: INFORMATIONAL, not a rejection (2026-09-12) ----
        -- Parts.Item.MaxLotSize describes the expected basket size; it is not a
        -- physical limit and a LOT that exceeds it is a real basket someone is
        -- holding, not an error. Rejecting the create turned a data-quality
        -- signal into a hard stop on the floor -- and would have blocked
        -- inventory cutover outright, where real castings run into the
        -- thousands against seed caps in the tens. The create now succeeds and
        -- carries a note back in @Message so the operator still sees it.
        --
        -- Deliberately NOT relaxed alongside it: Item.MaxParts and the
        -- consumption-point ItemLocation.MaxQuantity (6 / 6b below). Those cap
        -- how much may ACCUMULATE at a location, which is a genuine physical
        -- constraint, and they still reject.
        DECLARE @Advisory   NVARCHAR(300) = N'';
        DECLARE @MaxLotSize INT = (SELECT MaxLotSize FROM Parts.Item WHERE Id = @ItemId);
        IF @MaxLotSize IS NOT NULL AND @PieceCount > @MaxLotSize
            SET @Advisory = N' Note: piece count ' + CAST(@PieceCount AS NVARCHAR(20))
                          + N' is above the configured max lot size of '
                          + CAST(@MaxLotSize AS NVARCHAR(20)) + N'.';

        -- ---- 4. Eligibility (Direct U BomDerived, FDS-03-014 hierarchy cascade) ----
        -- Eligible if configured at the Cell OR any ancestor tier (Cell -> WorkCenter
        -- -> Area -> Site). Must match the dropdown (Item_ListEligibleForLocation) so
        -- a picked Item is never rejected here.
        --
        -- ...but NOT at a STOCK location. Eligibility answers "may this part be
        -- WORKED here", which is meaningless for storage: the warehouse and the
        -- trim stores carry no eligibility rows at all, and neither does the
        -- Site tier, so every part reads as ineligible at WHSE. Die cast already
        -- had to dodge that -- @DepositToStorage is explicitly
        -- non-eligibility-gated, "warehouse is storage, not a production
        -- location" -- which is this rule stated once, locally, for one caller.
        -- Needed by the inventory cutover scan, which counts stock in where it
        -- physically sits (warehouse / trim floor / trim stores / M&A lines).
        --
        -- Location.LocationTypeDefinition.IsStockLocation (migration 0081) is 1
        -- for InventoryLocation / SupportArea / InspectionStation /
        -- InspectionLine and 0 for everything else.
        --
        -- NOT IsProductionDestination (0064), which looks like the same question
        -- and is not: that column is DEFAULT 0 with only seven definitions set
        -- to 1, so "non-production" also covers Organization, Facility, Printer,
        -- Scale and Terminal -- gating on it would permit a LOT at the ENTERPRISE
        -- ROOT. Caught by 0020_PlantFloor_Foundation/040_Lot_Create.sql
        -- [LcIneligible], which picks the lowest-Id ineligible location (MPP-ENT).
        -- Lots.Lot_MoveTo legitimately uses that flag because its question is
        -- "may a CRT LOT move to quarantine".
        --
        -- Defaults to 0 (gate ENFORCED) when the definition cannot be resolved,
        -- so an unclassified or missing location fails closed exactly as before.
        DECLARE @DestIsStockLocation BIT = ISNULL((
            SELECT ltd.IsStockLocation
            FROM Location.Location l
            JOIN Location.LocationTypeDefinition ltd
              ON ltd.Id = l.LocationTypeDefinitionId
            WHERE l.Id = @CurrentLocationId), 0);

        IF @DestIsStockLocation = 0
           AND NOT EXISTS (
            SELECT 1 FROM Parts.v_EffectiveItemLocation
            WHERE ItemId = @ItemId
              AND LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@CurrentLocationId))
        )
        BEGIN
            SET @Message = N'Item is not eligible at the specified location.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

        -- ---- 5. Die-cast Tool/Cavity (FDS-05-034) ----
        -- Die-cast-origin = Manufactured origin AND an active ToolAssignment on
        -- the Cell. In that case Tool + Cavity are required and validated.
        -- (@CellHasActiveTool is declared earlier, right after FK resolution, so
        -- the LTT rule above can also use it.)
        IF @CellHasActiveTool = 1
        BEGIN
            -- Tool is always required for a die-cast LOT (FDS-05-034).
            IF @ToolId IS NULL
            BEGIN
                SET @Message = N'Die-cast-origin LOT requires Tool (FDS-05-034).';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                RETURN;
            END

            -- Tool must be currently mounted (active assignment) on this Cell.
            IF NOT EXISTS (
                SELECT 1 FROM Tools.ToolAssignment
                WHERE ToolId = @ToolId AND CellLocationId = @CurrentLocationId AND ReleasedAt IS NULL
            )
            BEGIN
                SET @Message = N'Tool is not mounted on the specified Cell.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                RETURN;
            END

            -- Cavity is unconditionally required (0076). The D2 free-text
            -- escape hatch is retired: it existed because cavities were not
            -- always configured, and a LOT whose cavity is untyped free text
            -- cannot be rolled up per part -- which is what per-cavity
            -- lifecycle exists for.
            IF @ToolCavityId IS NULL
            BEGIN
                SET @Message = N'Die-cast-origin LOT requires a configured Cavity (FDS-05-034).';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                RETURN;
            END

            -- Validated path (unchanged): cavity must belong to the Tool and be Active.
            IF NOT EXISTS (
                SELECT 1 FROM Tools.ToolCavity WHERE Id = @ToolCavityId AND ToolId = @ToolId
            )
            BEGIN
                SET @Message = N'Cavity does not belong to the specified Tool.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                RETURN;
            END

            IF NOT EXISTS (
                SELECT 1 FROM Tools.ToolCavity tc
                INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
                WHERE tc.Id = @ToolCavityId AND sc.Code = N'Active'
            )
            BEGIN
                SET @Message = N'Cavity is not in Active status.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                RETURN;
            END
        END

        -- ---- 6. MaxParts per-location cap (RECEIVED origin only) ----
        -- Loose-receive scans place inventory at a location; cap the per-location
        -- non-Closed total of this Item to Parts.Item.MaxParts (NULL = uncapped),
        -- mirroring the Lots.Lot_MoveToValidated placement check. Gated to the
        -- 'Received' origin: production births (die-cast / machining / assembly
        -- mints) are deliberately NOT capped here -- halting the line because a
        -- location is "full" is a downstream logistics problem, not a birth-time
        -- reject. Operator placement via the move path is capped in
        -- Lots.Lot_MoveToValidated; this closes the equivalent gap on receiving.
        DECLARE @ReceivedOriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
        DECLARE @MaxParts INT = (SELECT MaxParts FROM Parts.Item WHERE Id = @ItemId);
        IF @LotOriginTypeId = @ReceivedOriginId AND @MaxParts IS NOT NULL
        BEGIN
            DECLARE @ExistingParts INT = (
                SELECT ISNULL(SUM(l2.PieceCount), 0)
                FROM Lots.Lot l2
                INNER JOIN Lots.LotStatusCode s2 ON s2.Id = l2.LotStatusId
                WHERE l2.CurrentLocationId = @CurrentLocationId
                  AND l2.ItemId = @ItemId
                  AND s2.Code <> N'Closed');
            IF @ExistingParts + @PieceCount > @MaxParts
            BEGIN
                SET @Message = N'Receiving ' + CAST(@PieceCount AS NVARCHAR(20))
                    + N' would exceed the max parts allowed at this location ('
                    + CAST(@ExistingParts AS NVARCHAR(20)) + N' present, cap '
                    + CAST(@MaxParts AS NVARCHAR(20)) + N').';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                RETURN;
            END
        END

        -- ---- 6b. Consumption-point quantity cap (Parts.ItemLocation, RECEIVED origin only) ----
        -- Distinct from the MaxParts cap above: MaxParts is a blanket per-item ceiling;
        -- this is a per-(Item, consumption-point Location) cap that only applies where one
        -- has actually been configured (data model v1.8 / OI-18). Consumption metadata
        -- cascades the SAME hierarchy as eligibility (a row at the Area tier applies to
        -- every Cell under that Area), so this walks @CurrentLocationId's ancestor chain
        -- and takes the NEAREST IsConsumptionPoint=1 row's MaxQuantity (Depth ASC) --
        -- the most specific configured tier wins when more than one ancestor has a row.
        -- No matching row at any tier = unrestricted, same as before this check existed.
        IF @LotOriginTypeId = @ReceivedOriginId
        BEGIN
            DECLARE @CpMaxQuantity  INT;
            DECLARE @CpLocationName NVARCHAR(200);

            ;WITH LocChain AS (
                SELECT l.Id, l.ParentLocationId, 0 AS Depth
                FROM Location.Location l
                WHERE l.Id = @CurrentLocationId
                UNION ALL
                SELECT p.Id, p.ParentLocationId, c.Depth + 1
                FROM Location.Location p
                INNER JOIN LocChain c ON c.ParentLocationId = p.Id
            )
            SELECT TOP 1 @CpMaxQuantity = il.MaxQuantity, @CpLocationName = loc.Name
            FROM LocChain lc
            INNER JOIN Parts.ItemLocation il ON il.LocationId = lc.Id
                                             AND il.ItemId = @ItemId
                                             AND il.DeprecatedAt IS NULL
                                             AND il.IsConsumptionPoint = 1
            INNER JOIN Location.Location loc ON loc.Id = lc.Id
            ORDER BY lc.Depth ASC;

            IF @CpMaxQuantity IS NOT NULL
            BEGIN
                DECLARE @CpExistingParts INT = (
                    SELECT ISNULL(SUM(l3.PieceCount), 0)
                    FROM Lots.Lot l3
                    INNER JOIN Lots.LotStatusCode s3 ON s3.Id = l3.LotStatusId
                    WHERE l3.CurrentLocationId = @CurrentLocationId
                      AND l3.ItemId = @ItemId
                      AND s3.Code <> N'Closed'
                      AND s3.BlocksProduction = 0);   -- v1.7: held/scrap stock is not usable
                IF @CpExistingParts + @PieceCount > @CpMaxQuantity
                BEGIN
                    SET @Message = N'Receiving ' + CAST(@PieceCount AS NVARCHAR(20))
                        + N' would exceed the consumption-point max configured for this item at '
                        + ISNULL(@CpLocationName, N'this location') + N' ('
                        + CAST(@CpExistingParts AS NVARCHAR(20)) + N' usable on hand, held stock not counted; cap '
                        + CAST(@CpMaxQuantity AS NVARCHAR(20)) + N').';
                    EXEC Audit.Audit_LogFailure
                        @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                        @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                        @FailureReason = @Message, @ProcedureName = @ProcName,
                        @AttemptedParameters = @Params;
                    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                    RETURN;
                END
            END
        END

        -- ---- 7b. Cutover params (0080). Both run BEFORE BEGIN TRANSACTION so a
        --          rejection never opens a txn (a ROLLBACK inside a proc invoked
        --          via INSERT-EXEC raises Msg 3915).
        --          A duplicate @LotName is already rejected in 2b above.
        IF @EntryRouteSequence IS NOT NULL
           AND NOT EXISTS (SELECT 1
                           FROM Parts.RouteTemplate rt
                           INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
                           WHERE rt.ItemId = @ItemId
                             AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
                             AND rs.SequenceNumber = @EntryRouteSequence)
        BEGIN
            SET @Message = N'Entry route step ' + CAST(@EntryRouteSequence AS NVARCHAR(10))
                         + N' does not exist on this part''s active route.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

        DECLARE @TodayUtc DATE = CAST(SYSUTCDATETIME() AS DATE);
        IF @CastDate IS NOT NULL AND @CastDate > @TodayUtc
        BEGIN
            SET @Message = N'Cast date is in the future.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

        -- ---- 7c. Cutover machine (0082). Same pre-transaction placement and
        --          the same reason: a ROLLBACK inside a proc invoked via
        --          INSERT-EXEC raises Msg 3915.
        --          NARROW ON PURPOSE -- active, and a die cast machine. It does
        --          NOT re-check Parts.ItemLocation eligibility: the picker falls
        --          back to every machine when a part has no machine-tier row, so
        --          an eligibility gate here would reject exactly the picks that
        --          fallback exists to allow.
        IF @ProducedAtLocationId IS NOT NULL
           AND NOT EXISTS (SELECT 1
                           FROM Location.Location l
                           INNER JOIN Location.LocationTypeDefinition ltd
                                   ON ltd.Id = l.LocationTypeDefinitionId
                           WHERE l.Id = @ProducedAtLocationId
                             AND l.DeprecatedAt IS NULL
                             AND ltd.Code = N'DieCastMachine')
        BEGIN
            SET @Message = N'Producing machine must be an active die cast machine.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- D4: caller-supplied LotName (pre-printed LTT) uses the value verbatim and
        -- does NOT touch the 'Lot' counter; NULL path mints inline as today.
        DECLARE @SeqLast   BIGINT,
                @SeqEnd    BIGINT,
                @SeqFormat NVARCHAR(50),
                @SeqPrefix NVARCHAR(50),
                @SeqPad    INT;

        IF @LotName IS NOT NULL
        BEGIN
            SET @MintedLotName = @LotName;   -- pre-printed LTT carries its own identity
        END
        ELSE
        BEGIN
            -- Mint the LotName INSIDE the tran (rollback un-burns the counter).
            -- Mint inline (gap-free, row-locked) rather than via INSERT-EXEC of
            -- Lots.IdentifierSequence_Next: this proc is itself invoked via
            -- INSERT-EXEC by callers/tests, and nesting INSERT-EXEC is illegal.
            -- The minting logic mirrors IdentifierSequence_Next exactly and runs
            -- inside this proc's transaction, so a rollback un-burns the counter
            -- (the point of B6). IdentifierSequence_Next remains the standalone
            -- Ignition-facing single-result-set proc for other minting paths.
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
            SET @MintedLotName = CASE WHEN @SeqPad IS NULL OR @SeqPad < 1
                THEN @SeqPrefix + CAST(@SeqLast AS NVARCHAR(20))
                ELSE @SeqPrefix + RIGHT(REPLICATE(N'0', @SeqPad) + CAST(@SeqLast AS NVARCHAR(20)), @SeqPad) END;
        END

        -- D1/D2: CRT at mint. Resolved in ONE place (Lots.ufn_CrtForMint): the part's
        -- Parts.Item.CrtEnabled flag OR the minting terminal's CrtEnabled attribute.
        -- No input LOTs at a die-cast birth (or a loose receive), so the propagation
        -- arm is passed NULL. Mint-time only (D3) -- nothing re-derives this later.
        DECLARE @CrtActive BIT =
            (SELECT CrtActive FROM Lots.ufn_CrtForMint(@ItemId, @TerminalLocationId, NULL));

        INSERT INTO Lots.Lot (
            LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            Weight, WeightUomId, ToolId, ToolCavityId, VendorLotNumber,
            MinSerialNumber, MaxSerialNumber, CurrentLocationId,
            TotalInProcess, InventoryAvailable,
            CreatedByUserId, CreatedAtTerminalId, CreatedAt, CrtActive,
            EntryRouteSequence, CastDate, ProducedAtLocationId
        )
        VALUES (
            @MintedLotName, @ItemId, @LotOriginTypeId, @GoodStatusId, @PieceCount, @MaxLotSize,
            @Weight, @WeightUomId, @ToolId, @ToolCavityId, @VendorLotNumber,
            @MinSerialNumber, @MaxSerialNumber, @CurrentLocationId,
            0, @PieceCount,                          -- B5 materialized: TotalInProcess / InventoryAvailable
            @AppUserId, @TerminalLocationId, SYSUTCDATETIME(), @CrtActive,
            @EntryRouteSequence, @CastDate,        -- 0080: cutover entry point + cast date
            @ProducedAtLocationId                  -- 0082: cutover die cast machine
        );

        SET @NewId = SCOPE_IDENTITY();

        -- Initial status-history row (Old=NULL, New='Good').
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@NewId, NULL, @GoodStatusId, N'LOT created.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- Genealogy closure self-row (Depth=0).
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
        VALUES (@NewId, @NewId, 0);

        -- First-placement movement row (From=NULL).
        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@NewId, NULL, @CurrentLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- ----- Audit (resolved-FK JSON + readable Description) -----
        DECLARE @PartNumber NVARCHAR(50)  = (SELECT PartNumber FROM Parts.Item WHERE Id = @ItemId);
        DECLARE @LocName    NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @CurrentLocationId);
        DECLARE @ToolCode   NVARCHAR(50)  = (SELECT Code FROM Tools.Tool WHERE Id = @ToolId);
        DECLARE @CavityNum  NVARCHAR(50)  = (SELECT CavityCode FROM Tools.ToolCavity WHERE Id = @ToolCavityId);
        DECLARE @MachineName NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @ProducedAtLocationId);
        DECLARE @MachineArea NVARCHAR(200) = (SELECT p.Name FROM Location.Location m
                                              INNER JOIN Location.Location p ON p.Id = m.ParentLocationId
                                              WHERE m.Id = @ProducedAtLocationId);

        -- Cavity prose: the validated cavity's per-part code. The D2 '(manual)'
        -- arm is gone with the free-text fallback itself (0076).
        DECLARE @ToolSuffix NVARCHAR(200) =
            CASE WHEN @ToolId IS NOT NULL
                 THEN N'; Tool ' + ISNULL(@ToolCode, N'?') + N', Cavity ' + ISNULL(@CavityNum, N'?')
                 ELSE N'' END;

        -- Machine prose: the area disambiguates, because machine Names repeat
        -- across die cast areas (four 'Machine 01's in the real plant).
        DECLARE @MachineSuffix NVARCHAR(200) =
            CASE WHEN @ProducedAtLocationId IS NOT NULL
                 THEN N'; Machine ' + ISNULL(@MachineArea, N'?') + N' ' + ISNULL(@MachineName, N'?')
                 ELSE N'' END;

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @MintedLotName + N' ' + Audit.ufn_MidDot() + N' Lot ' + Audit.ufn_MidDot()
            + N' Created at ' + @LocName + N' (' + @PartNumber + N', ' + CAST(@PieceCount AS NVARCHAR(20)) + N' pcs)'
            + @ToolSuffix + @MachineSuffix;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT
                l.Id, l.LotName, l.PieceCount,
                JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name
                            FROM Parts.Item i WHERE i.Id = l.ItemId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name
                            FROM Location.Location loc WHERE loc.Id = l.CurrentLocationId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location,
                JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name
                            FROM Lots.LotStatusCode sc WHERE sc.Id = l.LotStatusId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status,
                JSON_QUERY((SELECT pl.Id, pl.Code, pl.Name
                            FROM Location.Location pl WHERE pl.Id = l.ProducedAtLocationId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ProducedAt
            FROM Lots.Lot l WHERE l.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @CurrentLocationId,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @NewId,
            @LogEventTypeCode   = N'LotCreated',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        -- ----- Die-cast storage deposit: after birth at the machine, move straight to
        -- the Warehouse so the LOT's home is storage (the route + shift tally already
        -- ASSUME the LOT leaves the machine right after creation). Opt-in via
        -- @DepositToStorage; INLINE, non-eligibility-gated system move (warehouse is
        -- storage, not a production location) -> a second LotMovement (machine->WHSE)
        -- and a 'LotMoved' audit, so history reads born-at-machine -> moved-to-storage.
        -- WHSE resolved by well-known code (not a hardcoded id). Soft-skip (LOT stays at
        -- the machine) when no warehouse is configured -> a storage misconfig never
        -- blocks the mint. -----
        DECLARE @StorageDepositSkipped BIT = 0;
        IF @DepositToStorage = 1
        BEGIN
            DECLARE @WarehouseId BIGINT = (
                SELECT TOP 1 Id FROM Location.Location
                WHERE Code = N'WHSE' AND DeprecatedAt IS NULL ORDER BY Id);

            IF @WarehouseId IS NULL OR @WarehouseId = @CurrentLocationId
                SET @StorageDepositSkipped = 1;
            ELSE
            BEGIN
                UPDATE Lots.Lot
                SET CurrentLocationId = @WarehouseId,
                    UpdatedAt         = SYSUTCDATETIME(),
                    UpdatedByUserId   = @AppUserId
                WHERE Id = @NewId;

                INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
                VALUES (@NewId, @CurrentLocationId, @WarehouseId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

                DECLARE @WhseName NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @WarehouseId);
                DECLARE @DepRaw   NVARCHAR(MAX) =
                    @MintedLotName + N' ' + Audit.ufn_MidDot() + N' Movement ' + Audit.ufn_MidDot()
                    + N' ' + @LocName + NCHAR(8594) + @WhseName + N' (auto-deposit to storage)';
                DECLARE @DepActivity NVARCHAR(500) = Audit.ufn_TruncateActivity(@DepRaw);
                DECLARE @DepOld NVARCHAR(MAX) = (
                    SELECT JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = @CurrentLocationId
                                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
                DECLARE @DepNew NVARCHAR(MAX) = (
                    SELECT JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = @WarehouseId
                                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

                EXEC Audit.Audit_LogOperation
                    @AppUserId          = @AppUserId,
                    @TerminalLocationId = @TerminalLocationId,
                    @LocationId         = @WarehouseId,
                    @LogEntityTypeCode  = N'Lot',
                    @EntityId           = @NewId,
                    @LogEventTypeCode   = N'LotMoved',
                    @LogSeverityCode    = N'Info',
                    @Description        = @DepActivity,
                    @OldValue           = @DepOld,
                    @NewValue           = @DepNew;
            END
        END

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT ' + @MintedLotName + N' created.'
                     + CASE WHEN @StorageDepositSkipped = 1
                            THEN N' (storage deposit skipped: no warehouse configured)'
                            ELSE N'' END
                     + @Advisory;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status        = 0;
        SET @NewId         = NULL;
        SET @MintedLotName = NULL;
        SET @Message       = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
