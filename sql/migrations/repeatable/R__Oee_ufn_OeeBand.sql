-- =============================================
-- Repeatable:  R__Oee_ufn_OeeBand.sql
-- Object:      Oee.ufn_OeeBand
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     1.0
-- Description: Colour band for an availability or quality ratio on the OEE
--              dashboard: green >= 0.85, amber >= 0.70, red below, NULL for
--              NULL. The ONE place the thresholds live (spec
--              docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--              sec 6.5). Placeholders until MPP supplies its own.
-- Change Log:
--   2026-10-29 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_OeeBand (@Ratio DECIMAL(9,4))
RETURNS TABLE
AS
RETURN
(
    SELECT CAST(CASE WHEN @Ratio IS NULL  THEN NULL
                     WHEN @Ratio >= 0.85  THEN N'green'
                     WHEN @Ratio >= 0.70  THEN N'amber'
                     ELSE N'red' END AS NVARCHAR(10)) AS Band
);
GO
