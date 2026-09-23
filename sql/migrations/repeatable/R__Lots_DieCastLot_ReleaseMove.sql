-- ============================================================
-- Repeatable:  R__Lots_DieCastLot_ReleaseMove.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: INTERNAL WORKER -- the closing half of a die cast release:
--              Open -> Good, the LOT moved to storage, the movement row and
--              the 'DieCastLotReleased' audit. Extracted from
--              Lots.DieCastLot_Release v2.2 so a LOT created by a shift
--              reconciliation leaves the press exactly as a live release does
--              (spec 2026-09-21 D4 / sec 5.1).
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH. The
--              caller resolves storage and validates the LOT first.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.DieCastLot_ReleaseMove
    @LotId              BIGINT,
    @StorageLocationId  BIGINT,
    @AuditNote          NVARCHAR(100) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OpenStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
    DECLARE @GoodStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @FromLocationId BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotId);
    DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);

    INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
    VALUES (@LotId, @OpenStatusId, @GoodStatusId, N'Die-cast basket released to storage.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

    UPDATE Lots.Lot
    SET LotStatusId = @GoodStatusId, CurrentLocationId = @StorageLocationId,
        UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
    WHERE Id = @LotId;

    INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
    VALUES (@LotId, @FromLocationId, @StorageLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

    DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
        + N' Die Cast ' + Audit.ufn_MidDot() + N' Released to storage' + ISNULL(@AuditNote, N''));
    EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId,
        @LocationId = @StorageLocationId, @LogEntityTypeCode = N'Lot', @EntityId = @LotId,
        @LogEventTypeCode = N'DieCastLotReleased', @LogSeverityCode = N'Info',
        @Description = @Activity, @OldValue = NULL, @NewValue = NULL;
END;
GO
