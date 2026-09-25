-- ============================================================
-- Repeatable:  R__Lots_DieCastLot_Mint.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.1
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
--   2026-09-25 - 1.1 - @AuditNote's separator is owned HERE: one space before a
--                      non-empty note, nothing before an empty one. v1.0
--                      concatenated the note straight on, so every caller had to
--                      remember its own leading space and a caller that forgot ran
--                      the note into the cell code. The note is trimmed first, so
--                      a v1.0-style caller still renders one space, not two.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.DieCastLot_Mint
    @LotName              NVARCHAR(50),
    @ItemId               BIGINT,
    @ToolId               BIGINT,
    @ToolCavityId         BIGINT,
    @CurrentLocationId    BIGINT,
    @ProducedAtLocationId BIGINT        = NULL,
    @CastDate             DATE          = NULL,
    -- @AuditNote: a trailing note appended to the audit Description -- e.g.
    -- N'(shift reconciliation #9)'. THIS PROCEDURE OWNS THE SEPARATOR: exactly one
    -- space between the base activity text and a non-empty note, and nothing at all
    -- when the note is NULL, empty or whitespace. Callers pass the BARE note. The
    -- note is trimmed first, so a caller that passes a leading space out of habit
    -- (the v1.0 contract, which made every caller supply its own) still gets one
    -- space, never two -- the separator cannot be got wrong from outside.
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

    -- The separator is OWNED HERE (v1.1): one space before a non-empty note,
    -- nothing at all otherwise. Callers pass the bare note, never a leading space.
    DECLARE @Note NVARCHAR(101) = LTRIM(RTRIM(ISNULL(@AuditNote, N'')));
    IF @Note <> N'' SET @Note = N' ' + @Note;

    DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
        + N' Die Cast ' + Audit.ufn_MidDot() + N' Basket opened at ' + ISNULL(@CellCode, N'?') + @Note);
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
