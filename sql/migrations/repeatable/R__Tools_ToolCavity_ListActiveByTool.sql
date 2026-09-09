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
--   PRODUCED-ITEM NOTE -- SUPERSEDED 2026-09-09 by migration 0072.
--     This proc used to record that Tools.ToolCavity carried no ItemId, and
--     that the produced Item was derived from the run configuration
--     (Lots.Lot.ItemId). That reasoning holds only while every cavity has a
--     LOT open on it. MPP runs FAMILY DIES -- one 12-cavity die casting four
--     part numbers, three cavities each -- and a cavity can be Closed or
--     Scrapped while the die keeps running, leaving it with no LOT and so no
--     knowable part. 0072 adds Tools.ToolCavity.ItemId as CONFIGURATION (a
--     cavity's part changes only when the die is re-cut) and this proc now
--     returns it. Still NULLable: a non-family die may leave it unset and
--     keep deriving the part from the LOT.
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
        tc.Description,
        -- APPENDED LAST (0072): positional INSERT-EXEC consumers keep their
        -- existing column order and only add trailing columns.
        tc.ItemId,
        it.PartNumber     AS ItemPartNumber,
        it.Description    AS ItemDescription
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.Tool                t  ON t.Id  = tc.ToolId
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
    LEFT  JOIN Parts.Item                 it ON it.Id = tc.ItemId
    WHERE tc.ToolId = @ToolId
      AND tc.DeprecatedAt IS NULL
      AND sc.Code = N'Active'
    ORDER BY tc.CavityNumber;
END;
GO
