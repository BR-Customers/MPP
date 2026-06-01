-- =============================================
-- Function:    Audit.ufn_TruncateActivity
-- Author:      Blue Ridge Automation
-- Created:     2026-05-28
-- Version:     1.0
--
-- Description:
--   Applies the standard Audit.ConfigLog.Description cap from the
--   audit-readability convention: 500 chars with NCHAR(8230)
--   horizontal-ellipsis suffix when the input exceeds the cap.
--   Below the cap the input is returned verbatim.
--
--   Cap reflects the at-a-glance read budget on the AuditLog table
--   row. The full diff is always recoverable from OldValue / NewValue
--   JSON via the ConfigChangeDetail popup (spec §6.3 auditor flow).
--
--   NULL input returns NULL (no implicit '' coercion -- callers should
--   never pass NULL but if they do the bug surfaces as NULL Description
--   in the audit row, not silent loss).
--
--   Convention reference:
--     docs/superpowers/specs/2026-05-28-audit-readability-refactor-design.md
--
-- Parameters:
--   @Text NVARCHAR(MAX) - the proposed Description prose.
--
-- Returns:
--   NVARCHAR(500) - truncated as needed; NULL if input is NULL.
-- =============================================
CREATE OR ALTER FUNCTION Audit.ufn_TruncateActivity(@Text NVARCHAR(MAX))
RETURNS NVARCHAR(500)
WITH SCHEMABINDING
AS
BEGIN
    IF @Text IS NULL RETURN NULL;
    IF LEN(@Text) <= 500 RETURN CAST(@Text AS NVARCHAR(500));
    -- Reserve 1 char for the ellipsis -- LEFT 499 chars + NCHAR(8230)
    RETURN LEFT(@Text, 499) + NCHAR(8230);
END;
GO
