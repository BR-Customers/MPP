-- ============================================================
-- Repeatable:  R__Location_Location_ListCutoverDestinationsForLine.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-17
-- Version:     2.0
-- Description: Where the inventory cutover scan may count stock in.
--
--              The selected LINE is always offered and sorts first. Beyond it,
--              the locations flagged Location.IsCutoverDestination (0083): the
--              warehouse and the two trim stores.
--
--              NOT every IsStockLocation row. That flag answers "can stock rest
--              here", which is also true of Shipping IN/OUT and two inspection
--              points -- four destinations nobody asked to offer.
--
--              @LineLocationId is the operator's first pick, which since
--              2026-09-17 may itself be a store (Warehouse / a trim store --
--              see Location_ListCutoverSources). A store is its own
--              destination.
--
--              ISDEFAULT (v2.0). Exactly one row, chosen as:
--                1. the pick itself, when it is a store;
--                2. else the first store (by Code) where @ItemId is eligible,
--                   ancestor cascade -- trim-shop eligibility is recorded on
--                   the shop, not the store. Depositing at the line is then a
--                   deliberate choice rather than the silent default;
--                3. else the line (no part yet, or a part no store takes).
--              The warehouse has no eligibility rows, so rule 2 only ever lands
--              on a trim store.
--
--              DISPLAYNAME. Both trim stores are Named 'Trim Storage' and the
--              site model is authoritative for Names, so the floor names are
--              applied here: Trim Shop 1 is Tumble, Trim Shop 2 is Blast.
--              Location_ListCutoverSources carries the SAME CASE -- change both.
--              Any other name that repeats in the result is still qualified
--              with its parent.
--
--              Read proc: no @Status/@Message, no OUTPUT params, one result
--              set; empty means nothing is configured (FDS-11-011).
--
-- Change Log:
--   2026-09-14 - 1.0 - Initial.
--   2026-09-17 - 2.0 - @ItemId; IsDefault follows the part's trim-shop
--                      eligibility; a store pick is its own default; trim
--                      stores labelled Tumble / Blast.
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Location_ListCutoverDestinationsForLine
    @LineLocationId BIGINT = NULL,
    @ItemId         BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DefaultId BIGINT = @LineLocationId;

    IF @ItemId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM Location.Location
                       WHERE Id = @LineLocationId AND IsCutoverDestination = 1)
    BEGIN
        -- No row leaves @DefaultId at the line.
        SELECT TOP 1 @DefaultId = d.Id
        FROM Location.Location d
        WHERE d.IsCutoverDestination = 1
          AND d.DeprecatedAt IS NULL
          AND EXISTS (SELECT 1
                      FROM Parts.v_EffectiveItemLocation eil
                      INNER JOIN Location.ufn_AncestorLocationIds(d.Id) a
                              ON a.LocationId = eil.LocationId
                      WHERE eil.ItemId = @ItemId)
        ORDER BY d.Code;
    END;

    WITH cand AS (
        -- The line itself: always offered, always first.
        SELECT l.Id, l.Code, l.Name, p.Name AS ParentName, 0 AS SortRank
        FROM Location.Location l
        LEFT JOIN Location.Location p ON p.Id = l.ParentLocationId
        WHERE l.Id = @LineLocationId
          AND l.DeprecatedAt IS NULL

        UNION ALL

        -- The configured destinations. Excludes the line so it cannot appear
        -- twice (a store picked as the source is also flagged).
        SELECT l.Id, l.Code, l.Name, p.Name AS ParentName, 1 AS SortRank
        FROM Location.Location l
        LEFT JOIN Location.Location p ON p.Id = l.ParentLocationId
        WHERE l.IsCutoverDestination = 1
          AND l.DeprecatedAt IS NULL
          AND l.Id <> ISNULL(@LineLocationId, -1)
    ),
    labelled AS (
        SELECT Id, Code, Name, ParentName, SortRank,
               CASE Code WHEN N'TRIM1-STORE' THEN N'Tumble Trim Storage'
                         WHEN N'TRIM2-STORE' THEN N'Blast Trim Storage'
                         ELSE Name END AS Label
        FROM cand
    )
    SELECT
        Id,
        Code,
        Name,
        ParentName,
        CAST(CASE WHEN Id = @DefaultId THEN 1 ELSE 0 END AS BIT) AS IsDefault,
        CASE WHEN COUNT(*) OVER (PARTITION BY Label) > 1
             THEN ISNULL(ParentName + N' - ', N'') + Label
             ELSE Label END AS DisplayName
    FROM labelled
    ORDER BY SortRank, Label, Code;
END;
GO
