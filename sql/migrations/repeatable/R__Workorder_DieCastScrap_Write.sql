-- ============================================================
-- Repeatable:  R__Workorder_DieCastScrap_Write.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: INTERNAL WORKER -- writes die cast scrap as additive
--              Workorder.RejectEvent rows (record only: never decrements a
--              LOT, never closes one -- the 0042 ScrapIsAdditive rule).
--              Extracted from Workorder.DieCastShiftOutput_Record v3.0 (the
--              per-LOT, per-cavity and die-wide inserts) and
--              Lots.DieCastLot_Release v2.2 (closing scrap), so the live procs
--              and Workorder.DieCastShiftReconciliation_Save write scrap one
--              way (spec 2026-09-21 sec 5.1).
--
--              Every row STAMPS its identity (ItemId, ToolId, ToolCavityId,
--              ShiftId, CellLocationId) -- 0084: the reject reports read
--              re.ItemId and never reach the part through the LOT.
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH. The
--              caller validates the JSON and the defect codes first.
--              A negative quantity is written as given: only the
--              reconciliation passes one (a compensating row, spec D13).
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastScrap_Write
    @ToolId             BIGINT,
    @ShiftId            BIGINT,
    @CellLocationId     BIGINT         = NULL,
    @LinesJson          NVARCHAR(MAX)  = NULL,
    @DieWideJson        NVARCHAR(MAX)  = NULL,
    @Remarks            NVARCHAR(200)  = N'Die-cast per-cavity scrap',
    @NoLotRemarks       NVARCHAR(200)  = NULL,
    @ReconciliationId   BIGINT         = NULL,
    @RecordedAt         DATETIME2(3)   = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @At DATETIME2(3) = ISNULL(@RecordedAt, SYSUTCDATETIME());
    DECLARE @NoLotText NVARCHAR(200) = ISNULL(@NoLotRemarks, @Remarks + N' (no basket)');

    IF @LinesJson IS NOT NULL AND ISJSON(@LinesJson) = 1
    BEGIN
        -- with a LOT: part and cavity come from the LOT (authoritative for what is in it)
        INSERT INTO Workorder.RejectEvent
            (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
             DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt,
             ApprovedByUserId, ReconciliationId)
        SELECT NULL, l.Id, l.ItemId, @ToolId, l.ToolCavityId, @ShiftId, @CellLocationId,
               s.defectCodeId, s.quantity, NULL, @Remarks, @AppUserId, @TerminalLocationId, @At,
               s.approvedByUserId, @ReconciliationId
        FROM OPENJSON(@LinesJson) WITH (lotId BIGINT N'$.lotId', scrapLines NVARCHAR(MAX) N'$.scrapLines' AS JSON) ln
        CROSS APPLY OPENJSON(ln.scrapLines) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity',
                                                  approvedByUserId BIGINT N'$.approvedByUserId') s
        INNER JOIN Lots.Lot l ON l.Id = ln.lotId
        WHERE ln.lotId IS NOT NULL;

        -- without a LOT: a fact about the CAVITY (0084 spec sec 3.6)
        INSERT INTO Workorder.RejectEvent
            (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
             DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt,
             ApprovedByUserId, ReconciliationId)
        SELECT NULL, NULL, tc.ItemId, @ToolId, tc.Id, @ShiftId, @CellLocationId,
               s.defectCodeId, s.quantity, NULL, @NoLotText, @AppUserId, @TerminalLocationId, @At,
               s.approvedByUserId, @ReconciliationId
        FROM OPENJSON(@LinesJson) WITH (lotId BIGINT N'$.lotId', toolCavityId BIGINT N'$.toolCavityId',
                                        scrapLines NVARCHAR(MAX) N'$.scrapLines' AS JSON) ln
        CROSS APPLY OPENJSON(ln.scrapLines) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity',
                                                  approvedByUserId BIGINT N'$.approvedByUserId') s
        INNER JOIN Tools.ToolCavity tc ON tc.Id = ln.toolCavityId
        WHERE ln.lotId IS NULL;
    END

    -- die-wide: every ACTIVE cavity, the LOT attached only where one is open (0084 D8)
    IF @DieWideJson IS NOT NULL AND ISJSON(@DieWideJson) = 1
        INSERT INTO Workorder.RejectEvent
            (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
             DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt,
             ApprovedByUserId, ReconciliationId)
        SELECT NULL, ol.LotId, tc.ItemId, @ToolId, tc.Id, @ShiftId, @CellLocationId,
               sl.defectCodeId, sl.quantity, NULL, N'Die-cast die-wide scrap',
               @AppUserId, @TerminalLocationId, @At, NULL, @ReconciliationId
        FROM OPENJSON(@DieWideJson) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') sl
        CROSS JOIN Tools.ToolCavity tc
        INNER JOIN Tools.ToolCavityStatusCode csc ON csc.Id = tc.StatusCodeId
        OUTER APPLY (SELECT TOP 1 l.Id AS LotId FROM Lots.Lot l
                     INNER JOIN Lots.LotStatusCode lsc ON lsc.Id = l.LotStatusId
                     WHERE l.ToolCavityId = tc.Id AND lsc.Code = N'Open') ol
        WHERE tc.ToolId = @ToolId AND tc.DeprecatedAt IS NULL AND csc.Code = N'Active';
END;
GO
