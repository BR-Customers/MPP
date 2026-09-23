-- ============================================================
-- Repeatable:  R__Workorder_DieCastCredit_Write.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
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

    INSERT INTO Workorder.DieCastContribution
        (LotId, ShiftId, PieceDelta, AppUserId, TerminalLocationId, EventAt, CellLocationId,
         ShotCounterReading, ToolCavityId, VarianceReasonId, VarianceNote, ReconciliationId)
    SELECT @LotId, @ShiftId, @PieceDelta, @AppUserId, @TerminalLocationId, @At, @CellLocationId,
           @CounterReading, l.ToolCavityId, @VarianceReasonId, @VarianceNote, @ReconciliationId
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
