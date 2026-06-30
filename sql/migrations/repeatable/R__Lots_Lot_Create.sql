-- ============================================================
-- Repeatable:  R__Lots_Lot_Create.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-09
-- Version:     1.0
-- Description: Creates a LOT (status 'Good'). Phase 1 Task B core skeleton
--              (plan section "Lot core skeleton" steps 1-12; aligned to DM v1.9q +
--              FDS-05-034/-035).
--
--              Flow: validate params/FKs -> validate business rules
--              (eligibility via Parts.v_EffectiveItemLocation Direct U
--              BomDerived; PieceCount <= Parts.Item.MaxLotSize; die-cast
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
    @CavityNote         NVARCHAR(50)  = NULL    -- D2: free-text cavity when no active ToolCavity exists; stored in legacy Lot.CavityNumber
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
               @TerminalLocationId AS TerminalLocationId
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
            -- when we have a user. A NULL @AppUserId rejection cannot be logged
            -- (no actor) - return cleanly without a FailureLog row.
            IF @AppUserId IS NOT NULL
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

        -- ---- 2b. D4: @LotName (caller-supplied identity) validation ----
        -- NULL = mint server-side (the inline IdentifierSequence block below, today's
        -- behavior). Supplied = use it verbatim; do NOT advance the 'Lot' counter (the
        -- pre-printed LTT carries its own identity; burning a counter would desync).
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

        DECLARE @MaxLotSize INT = (SELECT MaxLotSize FROM Parts.Item WHERE Id = @ItemId);
        IF @MaxLotSize IS NOT NULL AND @PieceCount > @MaxLotSize
        BEGIN
            SET @Message = N'PieceCount ' + CAST(@PieceCount AS NVARCHAR(20))
                         + N' exceeds Item MaxLotSize ' + CAST(@MaxLotSize AS NVARCHAR(20)) + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END

        -- ---- 4. Eligibility (Direct U BomDerived, FDS-03-014 hierarchy cascade) ----
        -- Eligible if configured at the Cell OR any ancestor tier (Cell -> WorkCenter
        -- -> Area -> Site). Must match the dropdown (Item_ListEligibleForLocation) so
        -- a picked Item is never rejected here.
        IF NOT EXISTS (
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
        DECLARE @CellHasActiveTool BIT =
            CASE WHEN @LotOriginTypeId = @ManufacturedOriginId
                   AND EXISTS (SELECT 1 FROM Tools.ToolAssignment
                               WHERE CellLocationId = @CurrentLocationId AND ReleasedAt IS NULL)
                 THEN 1 ELSE 0 END;

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

            IF @ToolCavityId IS NULL
            BEGIN
                -- D2 manual-cavity path: no configured ToolCavity row to validate.
                -- Require a free-text note; it is stored in the legacy Lot.CavityNumber
                -- column (auditable, distinguishable from the validated case).
                IF @CavityNote IS NULL OR LTRIM(RTRIM(@CavityNote)) = N''
                BEGIN
                    SET @Message = N'Die-cast-origin LOT requires a Cavity (select a configured cavity or enter one manually) (FDS-05-034).';
                    EXEC Audit.Audit_LogFailure
                        @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                        @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                        @FailureReason = @Message, @ProcedureName = @ProcName,
                        @AttemptedParameters = @Params;
                    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                    RETURN;
                END
            END
            ELSE
            BEGIN
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

        -- D2: free-text cavity stored in the legacy Lot.CavityNumber when no validated
        -- ToolCavityId was supplied (precomputed local; SP template forbids inline CASE
        -- in the VALUES list).
        DECLARE @CavityNumberToStore NVARCHAR(50) =
            CAST(CASE WHEN @ToolCavityId IS NULL THEN @CavityNote ELSE NULL END AS NVARCHAR(50));

        INSERT INTO Lots.Lot (
            LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            Weight, WeightUomId, ToolId, ToolCavityId, CavityNumber, VendorLotNumber,
            MinSerialNumber, MaxSerialNumber, CurrentLocationId,
            TotalInProcess, InventoryAvailable,
            CreatedByUserId, CreatedAtTerminalId, CreatedAt
        )
        VALUES (
            @MintedLotName, @ItemId, @LotOriginTypeId, @GoodStatusId, @PieceCount, @MaxLotSize,
            @Weight, @WeightUomId, @ToolId, @ToolCavityId, @CavityNumberToStore, @VendorLotNumber,
            @MinSerialNumber, @MaxSerialNumber, @CurrentLocationId,
            0, @PieceCount,                          -- B5 materialized: TotalInProcess / InventoryAvailable
            @AppUserId, @TerminalLocationId, SYSUTCDATETIME()
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
        DECLARE @CavityNum  NVARCHAR(50)  = (SELECT CavityNumber FROM Tools.ToolCavity WHERE Id = @ToolCavityId);

        -- Cavity prose: validated cavity number, else the free-text manual note (D2), else '?'.
        DECLARE @ToolSuffix NVARCHAR(200) =
            CASE WHEN @ToolId IS NOT NULL
                 THEN N'; Tool ' + ISNULL(@ToolCode, N'?') + N', Cavity '
                      + ISNULL(@CavityNum, ISNULL(@CavityNote + N' (manual)', N'?'))
                 ELSE N'' END;

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @MintedLotName + N' ' + Audit.ufn_MidDot() + N' Lot ' + Audit.ufn_MidDot()
            + N' Created at ' + @LocName + N' (' + @PartNumber + N', ' + CAST(@PieceCount AS NVARCHAR(20)) + N' pcs)'
            + @ToolSuffix;
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
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
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

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT ' + @MintedLotName + N' created.';
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
