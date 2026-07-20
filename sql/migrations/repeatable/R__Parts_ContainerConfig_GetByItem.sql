-- =============================================
-- Procedure:   Parts.ContainerConfig_GetByItem
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.0
--
-- Description:
--   Returns the active ContainerConfig(s) for a given Item, one per closure
--   method, ordered by ClosureMethodCode.SortOrder. Empty result = no active
--   config. A part may carry up to one active config per closure method
--   (enforced by filtered unique index UQ_ContainerConfig_ActiveItemMethod),
--   so this returns 0-to-N rows -- callers iterate.
--
--   ClosureMethod is the required per-method discriminator (FK to
--   Parts.ClosureMethodCode); TargetWeight is used when ClosureMethod =
--   'ByWeight'.
--
-- Parameters:
--   @ItemId BIGINT - FK → Parts.Item. Required.
--
-- Result set:
--   Zero-to-N ContainerConfig rows (one per active closure method).
--
-- Dependencies:
--   Tables: Parts.ContainerConfig
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-04-23 - 2.1 - Phase G.3: MaxParts exposed (OI-12)
--   2026-04-27 - 2.2 - OI-12 correction: MaxParts removed from SELECT (moved to Parts.Item)
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ContainerConfig_GetByItem
    @ItemId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id, ItemId, TraysPerContainer, PartsPerTray, IsSerialized,
        DunnageCode, CustomerCode,
        ClosureMethod, TargetWeight,
        CreatedAt, UpdatedAt, DeprecatedAt
    FROM Parts.ContainerConfig
    WHERE ItemId = @ItemId
      AND DeprecatedAt IS NULL
    ORDER BY (SELECT cmc.SortOrder FROM Parts.ClosureMethodCode cmc WHERE cmc.Code = ClosureMethod);
END;
GO
