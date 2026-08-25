-- ============================================================
-- Repeatable:  R__Lots_DieCastLot_Void.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-29
-- Version:     1.0
-- Description: Die-Cast Per-Cavity Lifecycle (plan docs/superpowers/plans/
--              2026-07-28-diecast-per-cavity-lifecycle.md), Task 6 / Phase 3.
--              Voids an EMPTY open accumulator basket (Open -> Scrap) -- the
--              counterpart to Release for a basket that never accumulated any
--              good pieces (e.g. opened in error, or a cavity that never shot
--              good product before the tool/cell changed over). A non-empty
--              basket must go through Release instead (this proc rejects it).
--
--              Validations (all pre-transaction, FDS-11-011 no-OUTPUT / single
--              terminal result row):
--                required params -> AppUser exists -> LOT exists and is status
--                'Open' -> PieceCount = 0 (else reject: "Basket is not empty;
--                release it instead.").
--
--              Mutation: Lots.LotStatusHistory Open -> Scrap; Lots.Lot
--              LotStatusId -> Scrap; Audit.Audit_LogOperation
--              'DieCastLotVoided' (entity 'Lot'). No LotMovement -- the basket
--              stays wherever it physically is (an empty basket never left
--              the cell); only its status changes.
--
--              @NewId is always NULL -- Void closes an EXISTING lot, it never
--              mints one.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.DieCastLot_Void
    @LotId BIGINT, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Lots.DieCastLot_Void';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @LotId AS LotId, @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @OpenStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
    DECLARE @ScrapStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Scrap');

    BEGIN TRY
        -- ---- validations (all pre-transaction) ----
        IF @LotId IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message = N'Required parameter missing.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN SET @Message = N'AppUser not found.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                       WHERE l.Id = @LotId AND sc.Code = N'Open')
        BEGIN SET @Message = N'LOT not found or not an open basket.'; GOTO Fail; END
        IF (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId) <> 0
        BEGIN SET @Message = N'Basket is not empty; release it instead.'; GOTO Fail; END

        DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);

        -- ===== mutation =====
        BEGIN TRANSACTION;
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@LotId, @OpenStatusId, @ScrapStatusId, N'Empty die-cast basket voided.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        UPDATE Lots.Lot
        SET LotStatusId = @ScrapStatusId, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        WHERE Id = @LotId;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
            + N' Die Cast ' + Audit.ufn_MidDot() + N' Basket voided (empty)');
        EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=NULL,
            @LogEntityTypeCode=N'Lot', @EntityId=@LotId, @LogEventTypeCode=N'DieCastLotVoided',
            @LogSeverityCode=N'Info', @Description=@Activity, @OldValue=NULL, @NewValue=NULL;
        COMMIT TRANSACTION;

        SET @Status = 1; SET @Message = N'Basket voided (' + @LotName + N').';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @NewId=NULL; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@LotId,
            @LogEventTypeCode=N'DieCastLotVoided', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RAISERROR(@ErrMsg,@ErrSev,@ErrState); RETURN;
    END CATCH
Fail:
    -- Audit.FailureLog.AppUserId is NOT NULL/FK: the required-parameter branch
    -- above can reach here with @AppUserId itself NULL -- guard the audit call
    -- so that case returns cleanly instead of throwing (mirrors Lot_Create /
    -- Lots.DieCastLot_Open's identical guard).
    IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@LotId,
            @LogEventTypeCode=N'DieCastLotVoided', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
END;
GO
