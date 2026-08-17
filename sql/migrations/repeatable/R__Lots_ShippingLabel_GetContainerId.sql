-- ============================================================
-- Repeatable:  R__Lots_ShippingLabel_GetContainerId.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-28
-- Version:     1.0
-- Description: Resolves the ContainerId behind a ShippingLabel so the reprint path
--              can re-render the container label (design 2026-07-28 sec 3.6).
--              Read proc; empty rowset = label not found.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_GetContainerId
    @ShippingLabelId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ShippingLabelId IS NULL
        RETURN;

    SELECT sl.ContainerId AS ContainerId
    FROM Lots.ShippingLabel sl
    WHERE sl.Id = @ShippingLabelId;
END;
GO
