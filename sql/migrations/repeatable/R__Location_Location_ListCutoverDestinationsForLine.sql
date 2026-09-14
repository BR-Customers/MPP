-- ============================================================
-- Repeatable:  R__Location_Location_ListCutoverDestinationsForLine.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-14
-- Version:     1.0
-- Description: Where the inventory cutover scan may count stock in.
--
--              The selected LINE is always offered, sorts first, and is flagged
--              IsDefault -- depositing at the line is today's behaviour and
--              stays the default if the operator ignores the control. Beyond
--              it, the locations flagged Location.IsCutoverDestination (0083):
--              the warehouse and the two trim stores.
--
--              NOT every IsStockLocation row. That flag answers "can stock rest
--              here", which is also true of Shipping IN/OUT and two inspection
--              points -- four destinations nobody asked to offer.
--
--              DISPLAYNAME. Both trim stores are named 'Trim Storage'. The
--              window function qualifies a name with its parent ONLY when that
--              name repeats in the result, so the operator never sees the same
--              label twice and 'Warehouse' is not padded to
--              'Madison Facility - Warehouse'. It is dynamic: deprecate one
--              trim store and the other un-qualifies.
--
--              Read proc: no @Status/@Message, no OUTPUT params, one result
--              set; empty means nothing is configured (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Location_ListCutoverDestinationsForLine
    @LineLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH cand AS (
        -- The line itself: always offered, always first, always the default.
        SELECT l.Id, l.Code, l.Name, p.Name AS ParentName,
               CAST(1 AS BIT) AS IsDefault, 0 AS SortRank
        FROM Location.Location l
        LEFT JOIN Location.Location p ON p.Id = l.ParentLocationId
        WHERE l.Id = @LineLocationId
          AND l.DeprecatedAt IS NULL

        UNION ALL

        -- The configured destinations. Excludes the line so it cannot appear
        -- twice if someone also flags it.
        SELECT l.Id, l.Code, l.Name, p.Name AS ParentName,
               CAST(0 AS BIT) AS IsDefault, 1 AS SortRank
        FROM Location.Location l
        LEFT JOIN Location.Location p ON p.Id = l.ParentLocationId
        WHERE l.IsCutoverDestination = 1
          AND l.DeprecatedAt IS NULL
          AND l.Id <> ISNULL(@LineLocationId, -1)
    )
    SELECT
        Id,
        Code,
        Name,
        ParentName,
        IsDefault,
        CASE WHEN COUNT(*) OVER (PARTITION BY Name) > 1
             THEN ISNULL(ParentName + N' - ', N'') + Name
             ELSE Name END AS DisplayName
    FROM cand
    ORDER BY SortRank, Name, Code;
END;
GO
