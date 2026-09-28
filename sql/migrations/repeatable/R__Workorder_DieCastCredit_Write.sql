-- ============================================================
-- Repeatable:  R__Workorder_DieCastCredit_Write.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.1
-- Description: INTERNAL WORKER -- writes ONE die cast credit: a
--              Workorder.DieCastContribution row and, when @ApplyToLot = 1,
--              the matching move of the LOT's materialized PieceCount /
--              InventoryAvailable (B5). Extracted from
--              Workorder.DieCastShiftOutput_Record v3.0 and
--              Lots.DieCastLot_Release v2.2 so the live procs and
--              Workorder.DieCastShiftReconciliation_Save write credits one
--              way (spec 2026-09-21 sec 5.1).
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH -- the
--              Oee.ShiftOverride_Restamp pattern. Callers are status-row procs
--              captured via INSERT-EXEC; they validate first, open the
--              transaction, and their CATCH handles anything raised here.
--              This worker validates nothing.
--
--              @ApplyToLot = 0 is the reconciliation's "record the production,
--              leave the count": the LOT is released (its count is corrected
--              through Lots.Lot_ApplyPieceCountCorrection, which leaves the
--              LotAttributeChange trail) or already counted downstream (the
--              count stands -- spec sec 3.3).
--
--              A negative @PieceDelta is legal only with @ReconciliationId;
--              CK_DieCastContribution_DeltaNonNeg enforces it (migration 0097).
--
-- Change Log:
--   2026-09-22 - 1.0 - Initial version (extracted worker, spec sec 5.1).
--   2026-09-25 - 1.1 - Stamps ShiftAttributionSourceId (migration 0099). See
--                      the comment at the INSERT for why it is derived from
--                      @ReconciliationId here rather than passed in.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastCredit_Write
    @LotId              BIGINT,
    @ShiftId            BIGINT,
    @PieceDelta         INT,
    @CounterReading     INT            = NULL,
    @CellLocationId     BIGINT         = NULL,
    @ApplyToLot         BIT            = 1,
    @VarianceReasonId   BIGINT         = NULL,
    @VarianceNote       NVARCHAR(500)  = NULL,
    @ReconciliationId   BIGINT         = NULL,
    @EventAt            DATETIME2(3)   = NULL,
    @AuditLocationId    BIGINT         = NULL,
    @AuditSuffix        NVARCHAR(100)  = N'',
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @At DATETIME2(3) = ISNULL(@EventAt, SYSUTCDATETIME());

    -- WHERE THE ShiftId CAME FROM (0099). Deliberately DERIVED here rather than
    -- taken as a parameter, because this is the ONLY insert into
    -- Workorder.DieCastContribution in the whole system: making it a parameter
    -- would create exactly the thing 0099 removes -- something a future caller
    -- can forget, silently producing a row the resolver then re-derives.
    -- The rule is total and local: a credit written under a reconciliation
    -- header is a team lead's decision (its @ShiftId is the past shift being
    -- reconciled while @EventAt is now), and every other credit was resolved
    -- from the event time by the caller. No cross-table lookup.
    DECLARE @SourceId BIGINT = (
        SELECT Id FROM Oee.ShiftAttributionSource
        WHERE Code = CASE WHEN @ReconciliationId IS NULL THEN N'Derived' ELSE N'Reconciled' END);

    INSERT INTO Workorder.DieCastContribution
        (LotId, ShiftId, PieceDelta, AppUserId, TerminalLocationId, EventAt, CellLocationId,
         ShotCounterReading, ToolCavityId, VarianceReasonId, VarianceNote, ReconciliationId,
         ShiftAttributionSourceId)
    SELECT @LotId, @ShiftId, @PieceDelta, @AppUserId, @TerminalLocationId, @At, @CellLocationId,
           @CounterReading, l.ToolCavityId, @VarianceReasonId, @VarianceNote, @ReconciliationId,
           @SourceId
    FROM Lots.Lot l
    WHERE l.Id = @LotId;

    IF @ApplyToLot = 1 AND @PieceDelta <> 0
        UPDATE Lots.Lot WITH (UPDLOCK, HOLDLOCK)
        SET PieceCount = PieceCount + @PieceDelta, InventoryAvailable = InventoryAvailable + @PieceDelta,
            UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        WHERE Id = @LotId;

    DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);
    DECLARE @Act NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
        + N' Die Cast ' + Audit.ufn_MidDot() + N' Added ' + CAST(@PieceDelta AS NVARCHAR(10)) + N' pc'
        + ISNULL(@AuditSuffix, N''));
    EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId,
        @LocationId = @AuditLocationId, @LogEntityTypeCode = N'Lot', @EntityId = @LotId,
        @LogEventTypeCode = N'DieCastPieceContributed', @LogSeverityCode = N'Info',
        @Description = @Act, @OldValue = NULL, @NewValue = NULL;
END;
GO
