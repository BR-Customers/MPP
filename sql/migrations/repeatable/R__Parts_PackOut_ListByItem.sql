-- =============================================
-- Procedure:   Parts.PackOut_ListByItem
-- Author:      Blue Ridge Automation
-- Created:     2026-11-20
-- Version:     1.0
--
-- Description:
--   READ. A part's active named pack-outs with their active version's values:
--   one button each in the station Pack-Out popup, one row each in the Config
--   Tool Item Master. With @TerminalLocationId:
--     IsSelected = the terminal's explicit pick for that (part, method);
--     IsRunning  = what Parts.ufn_PackOutInForce says this terminal runs now
--                  (an open box's pack-out wins, then the pick, then the
--                  default).
--   Without a terminal, IsSelected = 0 and IsRunning = IsDefault.
--   Ordered by closure method, default first, then name. Read proc: no status
--   row, no OUTPUT params (FDS-11-011).
--
-- Parameters: @ItemId BIGINT, @TerminalLocationId BIGINT = NULL.
--
-- Result: PackOutId, ClosureMethod, Name, IsDefault, IsSelected, IsRunning,
--   ContainerConfigId, VersionNumber, PartsPerTray, TraysPerContainer,
--   TargetWeight, ToleranceWeight, IsSerialized, DunnageCode, CustomerCode,
--   UpdatedAtEt (latest of header change / version save, Eastern).
--
-- Change Log:
--   2026-11-20 - 1.0 - Initial version (named pack-outs).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.PackOut_ListByItem
    @ItemId             BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.Id AS PackOutId, p.ClosureMethod, p.Name, p.IsDefault,
           CAST(CASE WHEN s.PackOutId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsSelected,
           CAST(CASE WHEN @TerminalLocationId IS NULL THEN p.IsDefault
                     WHEN r.PackOutId = p.Id THEN 1 ELSE 0 END AS BIT) AS IsRunning,
           cc.Id AS ContainerConfigId, cc.VersionNumber, cc.PartsPerTray, cc.TraysPerContainer,
           cc.TargetWeight, cc.ToleranceWeight, cc.IsSerialized, cc.DunnageCode, cc.CustomerCode,
           CAST(CAST(CASE WHEN p.UpdatedAt > cc.CreatedAt THEN p.UpdatedAt ELSE cc.CreatedAt END AS DATETIME2(3))
                AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS UpdatedAtEt
    FROM Parts.PackOut p
    JOIN Parts.ContainerConfig cc ON cc.PackOutId = p.Id AND cc.DeprecatedAt IS NULL
    JOIN Parts.ClosureMethodCode m ON m.Code = p.ClosureMethod
    LEFT JOIN Location.TerminalPackOutSelection s
           ON s.TerminalLocationId = @TerminalLocationId AND s.ItemId = p.ItemId
          AND s.ClosureMethod = p.ClosureMethod AND s.PackOutId = p.Id
    OUTER APPLY (SELECT f.PackOutId FROM Parts.ufn_PackOutInForce(p.ItemId, p.ClosureMethod, @TerminalLocationId, NULL) f
                 WHERE @TerminalLocationId IS NOT NULL) r
    WHERE p.ItemId = @ItemId AND p.DeprecatedAt IS NULL
    ORDER BY m.SortOrder, p.IsDefault DESC, p.Name;
END;
GO
