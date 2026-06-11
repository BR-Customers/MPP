-- ============================================================
-- Repeatable:  R__Lots_Lot_UpdateAttribute.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: Single-field LOT header update helper (Phase 2 Task 1 / G1).
--              Used internally by Lot_Split to reduce a parent's PieceCount, and
--              available as a narrow public mutation for one named attribute.
--
--              Flow: validate params + LOT exists -> Lot_AssertNotBlocked (B2:
--              even a correction on a held LOT is rejected; release the hold
--              first) -> read the current value of the named field (CASE
--              @AttributeName, supporting 'PieceCount') -> BEGIN TRAN -> write
--              ONE Lots.LotAttributeChange row (OldValue, NewValue) -> UPDATE
--              the target column -> if PieceCount changed, maintain the B5
--              materialized InventoryAvailable (Phase 2 simplification: equals
--              the new PieceCount; the full event-driven formula is Phase 3) ->
--              Audit_LogOperation 'LotUpdated' (resolved Old/New JSON) -> COMMIT.
--
--              Supported @AttributeName values (Phase 2): 'PieceCount'. An
--              unsupported name is rejected before any mutation. @NewValue is
--              NVARCHAR and is parsed to the target column's type.
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params (FDS-11-011); every exit path ends
--              SELECT @Status, @Message. RAISERROR (not THROW) in the nested
--              CATCH with failure logging OUTSIDE the rolled-back transaction.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_UpdateAttribute
    @LotId              BIGINT,
    @AttributeName      NVARCHAR(100),
    @NewValue           NVARCHAR(500),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Lot_UpdateAttribute';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @AttributeName AS AttributeName, @NewValue AS NewValue,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LotName    NVARCHAR(50);
    DECLARE @OldValue   NVARCHAR(500);
    DECLARE @StatusCode NVARCHAR(20);
    DECLARE @StatusName NVARCHAR(100);
    DECLARE @Blocks     BIT;

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @LotId IS NULL OR @AttributeName IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, AttributeName, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 2. LOT exists (read name + status for the inline B2 guard) ----
        SELECT @LotName    = l.LotName,
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
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 3. Supported attribute ----
        IF @AttributeName <> N'PieceCount'
        BEGIN
            SET @Message = N'Attribute ''' + @AttributeName + N''' is not updatable via Lot_UpdateAttribute (Phase 2: PieceCount only).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- 4. B2 not-blocked guard (inline; mirrors Lots.Lot_AssertNotBlocked).
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

        -- ---- 5. Read current value (CASE @AttributeName) ----
        SET @OldValue = (
            SELECT CASE @AttributeName
                       WHEN N'PieceCount' THEN CAST(PieceCount AS NVARCHAR(500))
                   END
            FROM Lots.Lot WHERE Id = @LotId);

        -- ===== Mutation (atomic) =====
        DECLARE @NewPieceCount INT = TRY_CAST(@NewValue AS INT);
        IF @NewPieceCount IS NULL
        BEGIN
            SET @Message = N'NewValue ''' + ISNULL(@NewValue, N'(null)') + N''' is not a valid PieceCount integer.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Update ' + Audit.ufn_MidDot()
            + N' ' + @AttributeName + N' ' + ISNULL(@OldValue, N'(null)') + NCHAR(8594) + @NewValue;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        BEGIN TRANSACTION;

        INSERT INTO Lots.LotAttributeChange (LotId, AttributeName, OldValue, NewValue, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@LotId, @AttributeName, @OldValue, @NewValue, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        UPDATE Lots.Lot
        SET PieceCount         = @NewPieceCount,
            InventoryAvailable = @NewPieceCount,   -- B5 (Phase 2 simplification; no consumption yet)
            UpdatedAt          = SYSUTCDATETIME(),
            UpdatedByUserId    = @AppUserId
        WHERE Id = @LotId;

        DECLARE @OldJson NVARCHAR(MAX) = (SELECT @AttributeName AS Attribute, @OldValue AS Value FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewJson NVARCHAR(MAX) = (SELECT @AttributeName AS Attribute, @NewValue AS Value FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @LotId,
            @LogEventTypeCode   = N'LotUpdated',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldJson,
            @NewValue           = @NewJson;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT ' + @LotName + N' ' + @AttributeName + N' updated.';
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
