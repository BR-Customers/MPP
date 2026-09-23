-- ============================================================
-- Repeatable:  R__Lots_DieCastLot_Mint.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: INTERNAL WORKER -- creates ONE die cast accumulator LOT in
--              status 'Open' at PieceCount 0, with its status-history row,
--              genealogy self-row, first-placement movement and
--              'DieCastLotOpened' audit. Extracted from Lots.DieCastLot_Open
--              v1.1 so the live press path and
--              Workorder.DieCastShiftReconciliation_Save mint one way
--              (spec 2026-09-21 sec 5.1).
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH.
--              The caller validates first -- LTT format and uniqueness, the
--              cavity, and (live only) that the die is mounted right now and
--              the cavity has no open LOT. Those two guards are exactly what a
--              past shift cannot satisfy, which is why they stay in the live
--              wrapper (spec sec 5.1).
--
--              Returns nothing -- the caller reads the new id back with
--              SELECT Id FROM Lots.Lot WHERE LotName = @LotName (LotName is
--              unique); SCOPE_IDENTITY() is not visible across the EXEC.
--
--              @CastDate / @ProducedAtLocationId are NULL on the live path
--              (v1.1 never set them) and carry the shift's business date and
--              the press when a reconciliation mints after the fact.
--
--              CRT is resolved here (Lots.ufn_CrtForMint) because this IS the
--              die cast ORIGIN mint -- see DieCastLot_Open v1.1's note.
--
-- Error Handling:
--   None of its own -- no TRY/CATCH, no ROLLBACK. Errors propagate to the
--   caller's CATCH by design, which is the only legal ROLLBACK site.
--
-- Change Log:
--   2026-09-22 - 1.0 - Initial version (die cast shift reconciliation, sec 5.1).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.DieCastLot_Mint
    @LotName              NVARCHAR(50),
    @ItemId               BIGINT,
    @ToolId               BIGINT,
    @ToolCavityId         BIGINT,
    @CurrentLocationId    BIGINT,
    @ProducedAtLocationId BIGINT        = NULL,
    @CastDate             DATE          = NULL,
    @AuditNote            NVARCHAR(100) = NULL,
    @AppUserId            BIGINT,
    @TerminalLocationId   BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OpenStatusId        BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
    DECLARE @ManufacturedOrigin  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
    DECLARE @MaxLotSize          INT    = (SELECT MaxLotSize FROM Parts.Item WHERE Id = @ItemId);
    DECLARE @CellCode            NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = @CurrentLocationId);
    DECLARE @CrtActive           BIT    = (SELECT CrtActive FROM Lots.ufn_CrtForMint(@ItemId, @TerminalLocationId, NULL));

    INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
        ToolId, ToolCavityId, CurrentLocationId, TotalInProcess, InventoryAvailable,
        CreatedByUserId, CreatedAtTerminalId, CreatedAt, CrtActive, CastDate, ProducedAtLocationId)
    VALUES (@LotName, @ItemId, @ManufacturedOrigin, @OpenStatusId, 0, @MaxLotSize,
        @ToolId, @ToolCavityId, @CurrentLocationId, 0, 0,
        @AppUserId, @TerminalLocationId, SYSUTCDATETIME(), @CrtActive, @CastDate, @ProducedAtLocationId);
    DECLARE @NewId BIGINT = SCOPE_IDENTITY();

    INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
    VALUES (@NewId, NULL, @OpenStatusId, N'Die-cast basket opened.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
    INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@NewId, @NewId, 0);
    INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
    VALUES (@NewId, NULL, @CurrentLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

    DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
        + N' Die Cast ' + Audit.ufn_MidDot() + N' Basket opened at ' + ISNULL(@CellCode, N'?') + ISNULL(@AuditNote, N''));
    DECLARE @NewValue NVARCHAR(MAX) = (SELECT l.Id, l.LotName,
        JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id = l.ItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
        JSON_QUERY((SELECT tc.Id, tc.CavityCode AS Code, tc.CavityCode AS Name FROM Tools.ToolCavity tc WHERE tc.Id = l.ToolCavityId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Cavity
        FROM Lots.Lot l WHERE l.Id = @NewId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId,
        @LocationId = @CurrentLocationId, @LogEntityTypeCode = N'Lot', @EntityId = @NewId,
        @LogEventTypeCode = N'DieCastLotOpened', @LogSeverityCode = N'Info',
        @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;
END;
GO
