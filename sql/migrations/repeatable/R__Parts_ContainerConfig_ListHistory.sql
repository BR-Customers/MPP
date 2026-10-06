-- =============================================
-- Procedure:   Parts.ContainerConfig_ListHistory
-- Author:      Blue Ridge Automation
-- Created:     2026-10-06
-- Version:     1.0
--
-- Description:
--   Returns the PAST pack-out value sets for an Item, newest first within
--   each closure method, so an editor can offer "load a previous pack-out".
--
--   Parts.ContainerConfig_Update overwrites the active row in place, so a
--   superseded value set survives in only two places, and this proc reads
--   both:
--     1. Audit.ConfigLog 'Updated' rows for the Item's configs -- OldValue is
--        the JSON snapshot the update replaced.
--     2. Deprecated Parts.ContainerConfig rows -- the values a cleared
--        pack-out held when it was removed.
--
--   Identical value sets collapse to one row (the most recent occurrence),
--   and a set equal to the method's CURRENT active config is left out --
--   reloading what is already live is not a choice worth offering.
--
--   Read-only. Loading a row here changes nothing; the editor still saves
--   through ContainerConfig_Create / _Update, which validate and audit.
--
-- Parameters:
--   @ItemId BIGINT - FK -> Parts.Item. Required.
--
-- Result set:
--   Zero-to-N rows (TOP 30):
--     HistoryKey INT            - 1..N, stable only within this result
--     ClosureMethod, PartsPerTray, TraysPerContainer, TargetWeight,
--     ToleranceWeight, DunnageCode, CustomerCode, IsSerialized
--     SupersededAt DATETIME2(3) - Eastern time (stored UTC)
--     SupersededBy NVARCHAR     - initials of who replaced/cleared it, or NULL
--     Label NVARCHAR(200)       - ASCII display text for a dropdown
--
-- Dependencies:
--   Tables: Parts.ContainerConfig, Parts.ClosureMethodCode, Audit.ConfigLog,
--           Audit.LogEntityType, Audit.LogEventType, Location.AppUser
--
-- Change Log:
--   2026-10-06 - 1.0 - Initial version (shop-floor Pack-Out popup).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ContainerConfig_ListHistory
    @ItemId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @EntityTypeId BIGINT =
        (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ContainerConfig');
    DECLARE @UpdatedId BIGINT =
        (SELECT Id FROM Audit.LogEventType WHERE Code = N'Updated');
    DECLARE @DeprecatedId BIGINT =
        (SELECT Id FROM Audit.LogEventType WHERE Code = N'Deprecated');

    ;WITH Past AS (
        -- 1. Values an in-place Update replaced.
        SELECT
            cc.ClosureMethod,
            TRY_CAST(JSON_VALUE(cl.OldValue, N'$.PartsPerTray')      AS INT)           AS PartsPerTray,
            TRY_CAST(JSON_VALUE(cl.OldValue, N'$.TraysPerContainer') AS INT)           AS TraysPerContainer,
            TRY_CAST(JSON_VALUE(cl.OldValue, N'$.TargetWeight')      AS DECIMAL(10,4)) AS TargetWeight,
            TRY_CAST(JSON_VALUE(cl.OldValue, N'$.ToleranceWeight')   AS DECIMAL(10,4)) AS ToleranceWeight,
            CAST(JSON_VALUE(cl.OldValue, N'$.DunnageCode')  AS NVARCHAR(50))           AS DunnageCode,
            CAST(JSON_VALUE(cl.OldValue, N'$.CustomerCode') AS NVARCHAR(50))           AS CustomerCode,
            CAST(CASE WHEN JSON_VALUE(cl.OldValue, N'$.IsSerialized') = N'true'
                      THEN 1 ELSE 0 END AS BIT)                                        AS IsSerialized,
            cl.LoggedAt                                                                AS SupersededAtUtc,
            cl.UserId                                                                  AS SupersededByUserId
        FROM Parts.ContainerConfig cc
        INNER JOIN Audit.ConfigLog cl
            ON  cl.LogEntityTypeId = @EntityTypeId
            AND cl.EntityId        = cc.Id
            AND cl.LogEventTypeId  = @UpdatedId
        WHERE cc.ItemId = @ItemId
          AND ISJSON(cl.OldValue) = 1

        UNION ALL

        -- 2. Values a cleared (deprecated) pack-out held when it was removed.
        SELECT
            cc.ClosureMethod,
            cc.PartsPerTray,
            cc.TraysPerContainer,
            cc.TargetWeight,
            cc.ToleranceWeight,
            cc.DunnageCode,
            cc.CustomerCode,
            cc.IsSerialized,
            cc.DeprecatedAt,
            (SELECT TOP (1) cl.UserId
             FROM Audit.ConfigLog cl
             WHERE cl.LogEntityTypeId = @EntityTypeId
               AND cl.EntityId        = cc.Id
               AND cl.LogEventTypeId  = @DeprecatedId
             ORDER BY cl.LoggedAt DESC)
        FROM Parts.ContainerConfig cc
        WHERE cc.ItemId = @ItemId
          AND cc.DeprecatedAt IS NOT NULL
    ),
    Ranked AS (
        SELECT p.*,
               ROW_NUMBER() OVER (
                   PARTITION BY p.ClosureMethod, p.PartsPerTray, p.TraysPerContainer,
                                p.TargetWeight, p.ToleranceWeight,
                                ISNULL(p.DunnageCode, N''), ISNULL(p.CustomerCode, N''),
                                p.IsSerialized
                   ORDER BY p.SupersededAtUtc DESC) AS Occurrence
        FROM Past p
        WHERE p.PartsPerTray > 0
          AND p.TraysPerContainer > 0
          -- Leave out a set identical to the method's current active config.
          AND NOT EXISTS (
              SELECT 1
              FROM Parts.ContainerConfig a
              WHERE a.ItemId = @ItemId
                AND a.DeprecatedAt IS NULL
                AND a.ClosureMethod = p.ClosureMethod
                AND EXISTS (
                    SELECT a.PartsPerTray, a.TraysPerContainer, a.TargetWeight, a.ToleranceWeight,
                           ISNULL(a.DunnageCode, N''), ISNULL(a.CustomerCode, N''), a.IsSerialized
                    INTERSECT
                    SELECT p.PartsPerTray, p.TraysPerContainer, p.TargetWeight, p.ToleranceWeight,
                           ISNULL(p.DunnageCode, N''), ISNULL(p.CustomerCode, N''), p.IsSerialized))
    ),
    Shaped AS (
        SELECT
            r.ClosureMethod, r.PartsPerTray, r.TraysPerContainer,
            r.TargetWeight, r.ToleranceWeight,
            r.DunnageCode, r.CustomerCode, r.IsSerialized,
            r.SupersededAtUtc,
            CAST(r.SupersededAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
                 AS DATETIME2(3))                                   AS SupersededAt,
            u.Initials                                              AS SupersededBy,
            ISNULL(cmc.SortOrder, 99)                               AS MethodSort
        FROM Ranked r
        LEFT JOIN Location.AppUser u          ON u.Id     = r.SupersededByUserId
        LEFT JOIN Parts.ClosureMethodCode cmc ON cmc.Code = r.ClosureMethod
        WHERE r.Occurrence = 1
    )
    SELECT TOP (30)
        CAST(ROW_NUMBER() OVER (ORDER BY s.MethodSort, s.SupersededAtUtc DESC) AS INT) AS HistoryKey,
        s.ClosureMethod, s.PartsPerTray, s.TraysPerContainer,
        s.TargetWeight, s.ToleranceWeight,
        s.DunnageCode, s.CustomerCode, s.IsSerialized,
        s.SupersededAt,
        s.SupersededBy,
        CAST(CONCAT(
            s.PartsPerTray, N' per tray x ', s.TraysPerContainer,
            CASE WHEN s.TraysPerContainer = 1 THEN N' tray' ELSE N' trays' END,
            CASE WHEN s.TargetWeight IS NOT NULL
                 THEN N', ' + FORMAT(s.TargetWeight, N'0.####')
                      + ISNULL(N' +/- ' + FORMAT(s.ToleranceWeight, N'0.####'), N'')
                 ELSE N'' END,
            N'  (until ', FORMAT(s.SupersededAt, N'yyyy-MM-dd HH:mm'),
            ISNULL(N', ' + s.SupersededBy, N''), N')'
        ) AS NVARCHAR(200))                                                             AS Label
    FROM Shaped s
    ORDER BY s.MethodSort, s.SupersededAtUtc DESC;
END;
GO
