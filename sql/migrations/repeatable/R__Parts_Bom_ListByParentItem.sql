-- =============================================
-- Procedure:   Parts.Bom_ListByParentItem
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.0
--
-- Description:
--   Returns Bom rows for the given parent Item, joined to Location.AppUser
--   for the CreatedByUser display name. Includes PublishedAt and DeprecatedAt
--   so the UI can badge rows as Draft/Published/Deprecated. Adds the
--   LineCount and Status columns the Item Master BOMs editor needs to
--   render the version dropdown without follow-up round-trips.
--
--   Ordering: active Drafts first (one at most per parent), then non-deprecated
--   rows by EffectiveFrom DESC then VersionNumber DESC, then (when included)
--   Deprecated rows.
--
--   @IncludeDeprecated = 0 (default) excludes Deprecated rows. Set to 1
--   to surface Deprecated versions in the dropdown ("Include Deprecated"
--   header toggle).
--
--   @ActiveOnly is an alias kept for backward compatibility with earlier
--   callers. Internally, @IncludeDeprecated has priority; if it is left
--   NULL the proc falls back to @ActiveOnly semantics (@ActiveOnly = 1
--   means exclude Deprecated; @ActiveOnly = 0 means include them).
--
-- Parameters:
--   @ParentItemId      BIGINT  - Required.
--   @IncludeDeprecated BIT     - When 1, includes Deprecated rows. Default 0.
--   @ActiveOnly        BIT     - Legacy alias; 1 = exclude deprecated. Default 1.
--
-- Result set:
--   Zero or more Bom rows:
--     Id, ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt,
--     CreatedByUserId, CreatedByDisplayName, CreatedAt, LineCount, Status
--   Status is one of 'Draft' | 'Published' | 'Deprecated'.
--
-- Dependencies:
--   Tables: Parts.Bom, Parts.BomLine, Location.AppUser
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-05-26 - 3.0 - Added @IncludeDeprecated, LineCount column, Status
--                      column, Draft-first ordering. Kept @ActiveOnly as
--                      a backward-compatible alias.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Bom_ListByParentItem
    @ParentItemId      BIGINT,
    @IncludeDeprecated BIT  = NULL,
    @ActiveOnly        BIT  = 1
AS
BEGIN
    SET NOCOUNT ON;

    -- Reconcile @IncludeDeprecated vs legacy @ActiveOnly.
    -- When @IncludeDeprecated is explicit (non-NULL), it wins.
    -- Otherwise, @ActiveOnly = 1 → exclude deprecated.
    DECLARE @ShowDep BIT =
        CASE
            WHEN @IncludeDeprecated IS NOT NULL THEN @IncludeDeprecated
            WHEN @ActiveOnly = 0                THEN 1
            ELSE 0
        END;

    SELECT
        b.Id,
        b.ParentItemId,
        b.VersionNumber,
        b.EffectiveFrom,
        b.PublishedAt,
        b.DeprecatedAt,
        b.CreatedByUserId,
        u.DisplayName AS CreatedByDisplayName,
        b.CreatedAt,
        (SELECT COUNT(*) FROM Parts.BomLine bl WHERE bl.BomId = b.Id) AS LineCount,
        CASE
            WHEN b.DeprecatedAt IS NOT NULL THEN N'Deprecated'
            WHEN b.PublishedAt  IS NULL     THEN N'Draft'
            ELSE N'Published'
        END AS [Status]
    FROM Parts.Bom b
    INNER JOIN Location.AppUser u ON u.Id = b.CreatedByUserId
    WHERE b.ParentItemId = @ParentItemId
      AND (@ShowDep = 1 OR b.DeprecatedAt IS NULL)
    ORDER BY
        -- Active Drafts first
        CASE WHEN b.PublishedAt IS NULL AND b.DeprecatedAt IS NULL THEN 0 ELSE 1 END,
        -- Then non-deprecated Published by EffectiveFrom DESC
        CASE WHEN b.DeprecatedAt IS NULL THEN 0 ELSE 1 END,
        b.EffectiveFrom DESC,
        b.VersionNumber DESC;
END;
GO
