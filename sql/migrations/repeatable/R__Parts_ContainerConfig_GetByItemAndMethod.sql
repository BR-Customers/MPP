-- =============================================
-- Procedure:   Parts.ContainerConfig_GetByItemAndMethod
-- Author:      Blue Ridge Automation
-- Created:     2026-07-17
-- Version:     1.0
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
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ContainerConfig_GetByItemAndMethod
    @ItemId        BIGINT,
    @ClosureMethod NVARCHAR(20)
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
      AND ClosureMethod = @ClosureMethod
      AND DeprecatedAt IS NULL;
END;
GO
