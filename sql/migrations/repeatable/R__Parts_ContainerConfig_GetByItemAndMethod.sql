-- =============================================
-- Procedure:   Parts.ContainerConfig_GetByItemAndMethod
-- Author:      Blue Ridge Automation
-- Created:     2026-07-17
-- Version:     1.2
--
-- Description:
--   Returns the single active ContainerConfig for a given (Item, closure
--   method) pair. Empty result = not found. This is the resolver used by
--   the assembly-out flow, where the terminal's CurrentClosureMethod selects
--   which of the part's per-method configs applies.
--
-- Parameters:
--   @ItemId        BIGINT       - FK → Parts.Item. Required.
--   @ClosureMethod NVARCHAR(20) - FK → Parts.ClosureMethodCode.Code. Required.
--
-- Result set:
--   Zero-or-one ContainerConfig row.
--
-- Dependencies:
--   Tables: Parts.ContainerConfig
--
-- Change Log:
--   2026-07-17 - 1.0 - Initial version (per-method resolver)
--   2026-08-27 - 1.1 - ToleranceWeight projected, immediately after
--                       TargetWeight (IND570 checkweigh, migration 0068).
--                       This is the proc the ByWeight setpoint load reads.
--   2026-11-20 - 1.2 - Named pack-outs (0136): + @TerminalLocationId = NULL. Returns
--                       the pack-out IN FORCE (Parts.ufn_PackOutInForce: open box's
--                       version > terminal pick > default), so the PLC close's piece
--                       count, the parts-per-tray prefill and the setpoint push match
--                       the box being filled. Id = that version's ContainerConfig Id.
--                       + PackOutId, PackOutName, PackOutSource, VersionNumber
--                       (appended). CreatedAt/UpdatedAt/DeprecatedAt kept for shape.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ContainerConfig_GetByItemAndMethod
    @ItemId        BIGINT,
    @ClosureMethod NVARCHAR(20),
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        cc.Id, cc.ItemId, f.TraysPerContainer, f.PartsPerTray, f.IsSerialized,
        f.DunnageCode, f.CustomerCode,
        cc.ClosureMethod, f.TargetWeight, f.ToleranceWeight,
        cc.CreatedAt, cc.UpdatedAt, cc.DeprecatedAt,
        f.PackOutId, f.PackOutName, f.Source AS PackOutSource, f.VersionNumber
    FROM Parts.ufn_PackOutInForce(@ItemId, @ClosureMethod, @TerminalLocationId, NULL) f
    JOIN Parts.ContainerConfig cc ON cc.Id = f.ContainerConfigId;
END;
GO
