-- =============================================
-- Procedure:   Tools.ToolCavity_ListActiveByTool
-- Author:      Blue Ridge Automation
-- Created:     2026-06-15
--
-- Description:
--   Arc 2 Phase 3 (§4.3). Returns the ACTIVE (DeprecatedAt IS NULL) cavities of
--   a Tool whose ToolCavityStatusCode is 'Active', ordered by CavityNumber — the
--   die-cast operator station's cavity picker (only cavities a LOT may be cast
--   from). Read proc: NO status row, NO OUTPUT params; an empty rowset means the
--   Tool has no active cavities (mirrors Tools.ToolAssignment_ListActiveByCell).
--
--   PRODUCED-ITEM NOTE (§4.3 open question, resolved 2026-06-15):
--     Tools.ToolCavity carries NO ItemId / produced-part link (verified against
--     migration 0010). The produced Item is NOT modeled per-cavity in the Tools
--     schema — it is derived from the run configuration (Lots.Lot.ItemId, set at
--     Lot_Create from the eligible Item at the Cell; Workorder.WorkOrder.ItemId).
--     Therefore this proc intentionally OMITS a producing ItemId column. A caller
--     that needs the produced part reads it from the LOT / WorkOrder context.
-- =============================================
CREATE OR ALTER PROCEDURE Tools.ToolCavity_ListActiveByTool
    @ToolId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        tc.Id,
        tc.ToolId,
        t.Code            AS ToolCode,
        t.Name            AS ToolName,
        tc.CavityNumber,
        tc.StatusCodeId,
        sc.Code           AS StatusCode,
        sc.Name           AS StatusName,
        tc.Description
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.Tool                t  ON t.Id  = tc.ToolId
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
    WHERE tc.ToolId = @ToolId
      AND tc.DeprecatedAt IS NULL
      AND sc.Code = N'Active'
    ORDER BY tc.CavityNumber;
END;
GO
