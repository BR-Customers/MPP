-- ============================================================
-- Repeatable:  R__Tools_ToolCavity_ListForItemTool.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-12
-- Version:     1.0
-- Description: The cavities of ONE die that produce ONE part. Drives the cutover
--              scan screen's cavity buttons -- the measured spread is 1 to 4
--              cavities per (part, die), which is why they are big touch targets
--              rather than a dropdown.
--
--              CavityCode is the per-part lowercase alphabetic code introduced by
--              migration 0076. The floor writes cavity on the LTT as e.g. 'Da':
--              the CAPITAL letter is the die revision, the LOWERCASE letter is
--              the cavity. So the code returned here is exactly the character the
--              operator reads off the tag -- no translation layer, and the
--              buttons are labelled with it verbatim.
--
--              Read proc: no OUTPUT params, empty result set = nothing found
--              (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Tools.ToolCavity_ListForItemTool
    @ItemId BIGINT,
    @ToolId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT tc.Id,
           tc.CavityCode,
           tc.Description
    FROM Tools.ToolCavity tc
    WHERE tc.ItemId = @ItemId
      AND tc.ToolId = @ToolId
      AND tc.DeprecatedAt IS NULL
    ORDER BY tc.CavityCode;
END;
GO
