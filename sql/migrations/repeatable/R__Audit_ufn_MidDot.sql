-- =============================================
-- Function:    Audit.ufn_MidDot
-- Author:      Blue Ridge Automation
-- Created:     2026-05-28
-- Version:     1.0
--
-- Description:
--   Returns the middle-dot character (U+00B7) used as the standard
--   separator in Audit.ConfigLog.Description prose under the
--   SUBJECT · CATEGORY · ACTION convention.
--
--   Defined as a function so callers don't need to remember NCHAR(183)
--   or worry about file-encoding round-trips through sqlcmd that bit
--   the em-dash literal in R__Location_Location_ListForEligibilityPicker
--   (see Phase 8 Eligibility 2026-05-28 fix).
--
--   Convention reference:
--     docs/superpowers/specs/2026-05-28-audit-readability-refactor-design.md
--
-- Returns:
--   NCHAR(1) - the middle-dot character.
-- =============================================
CREATE OR ALTER FUNCTION Audit.ufn_MidDot()
RETURNS NCHAR(1)
WITH SCHEMABINDING
AS
BEGIN
    RETURN NCHAR(183);
END;
GO
