-- ============================================================
-- Repeatable:  R__Lots_Lot_ApplyPieceCountCorrection.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: INTERNAL WORKER -- the audited change of a LOT's materialized
--              PieceCount (B5). Extracted from Lots.Lot_RectifyPieceCount v1.0
--              so the LOT Detail count panel and
--              Workorder.DieCastShiftReconciliation_Save correct a count one
--              way (spec 2026-09-21 sec 3.3 / 5.1).
--
--              History is preserved the way the model already preserves it:
--              ONE append-only Lots.LotAttributeChange row carrying the reason,
--              plus a routed 'Lot'/'LotUpdated' audit operation. The count
--              itself is mutated in place -- every writer in the system does
--              that and nothing re-derives it (see Lot_RectifyPieceCount's
--              header for the full argument).
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH. It
--              RAISERRORs on a stale expected count or on availability going
--              negative; the caller's CATCH turns that into its status row.
--              The caller validates status, MaxLotSize and the no-op case.
--
-- Error Handling:
--   None of its own. RAISERROR propagates to the caller's CATCH, which is the
--   only legal ROLLBACK site.
--
-- Change Log:
--   2026-09-22 - 1.0 - Initial version (die cast shift reconciliation, sec 5.1).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_ApplyPieceCountCorrection
    @LotId              BIGINT,
    @NewPieceCount      INT,
    @Reason             NVARCHAR(500),
    @ExpectedPieceCount INT    = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LotName NVARCHAR(50), @OldPieceCount INT, @OldInvAvail INT;
    SELECT @LotName = l.LotName, @OldPieceCount = l.PieceCount, @OldInvAvail = l.InventoryAvailable
    FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK)
    WHERE l.Id = @LotId;

    IF @ExpectedPieceCount IS NOT NULL AND @OldPieceCount <> @ExpectedPieceCount
        RAISERROR(N'The LOT piece count changed while the correction was being entered. Reload and retry.', 16, 1);

    DECLARE @Delta INT = @NewPieceCount - @OldPieceCount;
    DECLARE @NewInvAvail INT = @OldInvAvail + @Delta;
    IF @NewInvAvail < 0
        RAISERROR(N'The corrected piece count is below the pieces already consumed (concurrent update). Reload and retry.', 16, 1);
    IF @NewInvAvail > @NewPieceCount SET @NewInvAvail = @NewPieceCount;

    DECLARE @OldValue NVARCHAR(500) = CAST(@OldPieceCount AS NVARCHAR(500));
    DECLARE @NewValue NVARCHAR(500) = CAST(@NewPieceCount AS NVARCHAR(500));
    DECLARE @ActivityRaw NVARCHAR(MAX) =
        @LotName + N' ' + Audit.ufn_MidDot() + N' Rectify ' + Audit.ufn_MidDot()
        + N' PieceCount ' + @OldValue + NCHAR(8594) + @NewValue + N' (' + @Reason + N')';
    DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

    INSERT INTO Lots.LotAttributeChange
        (LotId, AttributeName, OldValue, NewValue, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
    VALUES
        (@LotId, N'PieceCount', @OldValue, @NewValue, @Reason, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

    UPDATE Lots.Lot
    SET PieceCount = @NewPieceCount, InventoryAvailable = @NewInvAvail,
        UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
    WHERE Id = @LotId;

    DECLARE @OldJson NVARCHAR(MAX) = (
        SELECT N'PieceCount' AS Attribute, @OldPieceCount AS Value, @OldInvAvail AS InventoryAvailable
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @NewJson NVARCHAR(MAX) = (
        SELECT N'PieceCount' AS Attribute, @NewPieceCount AS Value,
               @NewInvAvail AS InventoryAvailable, @Reason AS Reason,
               JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                           FROM Lots.Lot l WHERE l.Id = @LotId
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
               JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name
                           FROM Location.Location loc
                           INNER JOIN Lots.Lot l2 ON l2.CurrentLocationId = loc.Id
                           WHERE l2.Id = @LotId
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    EXEC Audit.Audit_LogOperation
        @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
        @LogEntityTypeCode = N'Lot', @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
        @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = @OldJson, @NewValue = @NewJson;
END;
GO
