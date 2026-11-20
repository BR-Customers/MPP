-- =============================================
-- Functions:   Parts.ufn_ResolvePackOut, Parts.ufn_PackOutInForce
-- Author:      Blue Ridge Automation
-- Created:     2026-11-20
-- Version:     1.0
--
-- Description:
--   THE rule for which pack-out a terminal runs (named pack-outs, migration
--   0136). One file because ufn_PackOutInForce reads ufn_ResolvePackOut and an
--   inline TVF cannot be created before what it references (repeatables run in
--   file-name order).
--
--   Parts.ufn_ResolvePackOut(@ItemId, @ClosureMethod, @TerminalLocationId)
--     The terminal's explicit pick (Location.TerminalPackOutSelection) when
--     that pack-out is still active, else the part's active default for the
--     method; returned as the pack-out's ACTIVE version. NULL terminal =
--     default only. Source = 'Selected' | 'Default'. No row = the part has no
--     active pack-out for the method.
--
--   Parts.ufn_PackOutInForce(@ItemId, @ClosureMethod, @TerminalLocationId, @CellLocationId)
--     What every reader uses (spec 7.1a): if there is an open box the next
--     tray would go into (Lots.ufn_ContainerForNextTray), THAT BOX'S OWN
--     version (Source 'OpenBox', even when the pack-out has since been edited
--     or the terminal has since picked another); else ufn_ResolvePackOut.
--     @TerminalLocationId counts as the station only when it is an LTD-7
--     terminal; @CellLocationId NULL = the terminal's parent (its line).
--
--   Both inline (never scalar / multi-statement): every lookup is a seek on
--   UQ_TerminalPackOutSelection, UQ_PackOut_ActiveDefault,
--   UQ_ContainerConfig_ActivePackOut (covering) or
--   IX_Container_OpenByCellItemStation.
--
-- Returns (both): ContainerConfigId, PackOutId, PackOutName, VersionNumber,
--   Source NVARCHAR(10), PartsPerTray, TraysPerContainer, TargetWeight,
--   ToleranceWeight, IsSerialized, DunnageCode, CustomerCode
--   (+ OpenContainerId on ufn_PackOutInForce).
--
-- Change Log:
--   2026-11-20 - 1.0 - Initial version (named pack-outs).
--   2026-11-20 - 1.1 - ufn_ResolvePackOut as plain joins (bench: the TOP/UNION
--                      form doubled ScaleStation_GetRunningPart's CPU).
-- =============================================
CREATE OR ALTER FUNCTION Parts.ufn_ResolvePackOut
(
    @ItemId             BIGINT,
    @ClosureMethod      NVARCHAR(20),
    @TerminalLocationId BIGINT
)
RETURNS TABLE
AS
RETURN
    -- Plain joins, no TOP/UNION/ORDER BY (1.1): the shape is cheap to expand
    -- inside callers that reference it per row (ufn_ScaleStationEligibleParts).
    -- At most one row: one selection per (terminal, part, method) and one
    -- active default per (part, method) are both unique indexes.
    SELECT cc.Id            AS ContainerConfigId,
           p.Id             AS PackOutId,
           p.Name           AS PackOutName,
           cc.VersionNumber,
           CAST(CASE WHEN sel.PackOutId IS NULL THEN N'Default' ELSE N'Selected' END AS NVARCHAR(10)) AS Source,
           cc.PartsPerTray, cc.TraysPerContainer, cc.TargetWeight, cc.ToleranceWeight,
           cc.IsSerialized, cc.DunnageCode, cc.CustomerCode
    FROM (SELECT 1 AS One) x
    OUTER APPLY (
        SELECT s.PackOutId
        FROM Location.TerminalPackOutSelection s
        JOIN Parts.PackOut sp ON sp.Id = s.PackOutId AND sp.DeprecatedAt IS NULL
        WHERE s.TerminalLocationId = @TerminalLocationId
          AND s.ItemId = @ItemId
          AND s.ClosureMethod = @ClosureMethod
    ) sel
    JOIN Parts.PackOut p
      ON p.ItemId = @ItemId AND p.ClosureMethod = @ClosureMethod AND p.DeprecatedAt IS NULL
     AND ((sel.PackOutId IS NOT NULL AND p.Id = sel.PackOutId)
       OR (sel.PackOutId IS NULL AND p.IsDefault = 1))
    JOIN Parts.ContainerConfig cc ON cc.PackOutId = p.Id AND cc.DeprecatedAt IS NULL;
GO

CREATE OR ALTER FUNCTION Parts.ufn_PackOutInForce
(
    @ItemId             BIGINT,
    @ClosureMethod      NVARCHAR(20),
    @TerminalLocationId BIGINT,
    @CellLocationId     BIGINT
)
RETURNS TABLE
AS
RETURN
    WITH ctx AS (
        SELECT
            (SELECT t.Id FROM Location.Location t
             WHERE t.Id = @TerminalLocationId AND t.LocationTypeDefinitionId = 7) AS StationId,
            COALESCE(@CellLocationId,
                     (SELECT t.ParentLocationId FROM Location.Location t WHERE t.Id = @TerminalLocationId)) AS CellId
    )
    SELECT TOP (1)
           x.ContainerConfigId, x.PackOutId, x.PackOutName, x.VersionNumber, x.Source,
           x.PartsPerTray, x.TraysPerContainer, x.TargetWeight, x.ToleranceWeight,
           x.IsSerialized, x.DunnageCode, x.CustomerCode, x.OpenContainerId
    FROM (
        SELECT cc.Id AS ContainerConfigId, p.Id AS PackOutId, p.Name AS PackOutName, cc.VersionNumber,
               CAST(N'OpenBox' AS NVARCHAR(10)) AS Source,
               cc.PartsPerTray, cc.TraysPerContainer, cc.TargetWeight, cc.ToleranceWeight,
               cc.IsSerialized, cc.DunnageCode, cc.CustomerCode,
               b.ContainerId AS OpenContainerId, 0 AS Prio
        FROM ctx
        CROSS APPLY Lots.ufn_ContainerForNextTray(ctx.CellId, @ItemId, ctx.StationId) b
        JOIN Parts.ContainerConfig cc ON cc.Id = b.ContainerConfigId
        JOIN Parts.PackOut p          ON p.Id = cc.PackOutId
        UNION ALL
        SELECT r.ContainerConfigId, r.PackOutId, r.PackOutName, r.VersionNumber, r.Source,
               r.PartsPerTray, r.TraysPerContainer, r.TargetWeight, r.ToleranceWeight,
               r.IsSerialized, r.DunnageCode, r.CustomerCode,
               CAST(NULL AS BIGINT), 1
        FROM ctx
        CROSS APPLY Parts.ufn_ResolvePackOut(@ItemId, @ClosureMethod, ctx.StationId) r
    ) x
    ORDER BY x.Prio;
GO
