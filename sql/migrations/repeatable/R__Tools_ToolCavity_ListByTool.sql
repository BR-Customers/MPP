-- =============================================
-- Procedure:   Tools.ToolCavity_ListByTool
-- Author:      Blue Ridge Automation
-- Created:     2026-04-22
--
-- Description:
--   Returns ToolCavity rows for a Tool ordered by part number, then cavity
--   code. Joined to ToolCavityStatusCode for display, and LEFT JOINed to
--   Parts.Item for the configured cavity-to-part map (0072).
--
-- Change Log:
--   2026-09-09 - ItemId + ItemPartNumber + ItemDescription added (0072,
--                family dies), APPENDED LAST so positional INSERT-EXEC
--                consumers only add trailing columns. LEFT JOIN: ItemId is
--                nullable and a cavity with no mapping must still return.
--   2026-09-10 - CavityNumber INT becomes CavityCode NVARCHAR(4) (migration
--                0076, per-part alphabetic cavity identity). Same column
--                POSITION -- trailing-column-only is the 0072 convention and
--                positional INSERT-EXEC consumers depend on it.
--                ORDER BY gains the part: on a 12-cavity family die casting
--                four parts every part now has a cavity 'a', so ordering by
--                code alone renders a,a,a,a,b,b,b,b,c,c,c,c -- four unrelated
--                parts interleaved. A NULL PartNumber sorts first, which is
--                right: a non-family die is one group.
-- =============================================
CREATE OR ALTER PROCEDURE Tools.ToolCavity_ListByTool
    @ToolId            BIGINT,
    @IncludeDeprecated BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        tc.Id,
        tc.ToolId,
        tc.CavityCode,
        tc.StatusCodeId,
        sc.Code           AS StatusCode,
        sc.Name           AS StatusName,
        tc.Description,
        tc.CreatedAt,
        tc.UpdatedAt,
        tc.CreatedByUserId,
        tc.UpdatedByUserId,
        tc.DeprecatedAt,
        -- APPENDED LAST (0072): positional INSERT-EXEC consumers keep their
        -- existing column order and only add trailing columns.
        tc.ItemId,
        it.PartNumber     AS ItemPartNumber,
        it.Description    AS ItemDescription
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
    LEFT  JOIN Parts.Item                 it ON it.Id = tc.ItemId
    WHERE tc.ToolId = @ToolId
      AND (@IncludeDeprecated = 1 OR tc.DeprecatedAt IS NULL)
    ORDER BY it.PartNumber, tc.CavityCode;
END;
GO
