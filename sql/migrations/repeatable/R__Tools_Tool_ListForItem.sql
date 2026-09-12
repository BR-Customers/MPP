-- ============================================================
-- Repeatable:  R__Tools_Tool_ListForItem.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-12
-- Version:     1.0
-- Description: Which dies can run this part. Tools.ToolCavity is keyed
--              (ToolId, ItemId, CavityCode) with a unique index, so this is one
--              indexed read.
--
--              Under the family-die model a die runs SEVERAL part numbers at
--              once, but a part maps to exactly ONE die -- measured against Dev
--              2026-09-12, all 13 mapped parts do. The inventory cutover scan
--              screen relies on that asymmetry: a single row means the die is
--              RESOLVED and displayed, not chosen, and the operator never sees a
--              picker. More than one row means show the picker -- kept because
--              the real MPP part list may not be so uniform.
--
--              DISTINCT because a die carries one ToolCavity row PER CAVITY for
--              the part; the caller wants a die list, not a cavity list.
--
--              Read proc: no OUTPUT params, empty result set = nothing found
--              (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Tools.Tool_ListForItem
    @ItemId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT
           t.Id,
           t.Code,
           t.Name
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.Tool t ON t.Id = tc.ToolId
    WHERE tc.ItemId = @ItemId
      AND tc.DeprecatedAt IS NULL
      AND t.DeprecatedAt IS NULL
    ORDER BY t.Code;
END;
GO
