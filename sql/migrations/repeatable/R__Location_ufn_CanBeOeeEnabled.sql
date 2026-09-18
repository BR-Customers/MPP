-- ============================================================
-- Repeatable:  R__Location_ufn_CanBeOeeEnabled.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.0
-- Description: May a location of this TYPE be marked IsOeeEnabled?
--
--              Two conditions, both necessary:
--                (1) Cell or WorkCenter tier. An Area, Site or Enterprise row
--                    is a grouping, not a thing a shift runs on; flagging one
--                    would scope downtime across a whole shop or plant.
--                (2) Not a device or a store. A terminal is an operator IO
--                    device, a printer and a scale are peripherals, and a rack
--                    is a store -- none of them "go down".
--
--              This is the rule the old Oee.ufn_ResolveOeeEquipment carried
--              inline; it now lives at the WRITE path so the equipment set can
--              be a plain flag lookup.
--
--              Deprecated definitions still answer truthfully -- the caller
--              (Location_SaveAll) rejects a deprecated definition separately
--              with its own message.
--
-- Parameters:
--   @LocationTypeDefinitionId BIGINT - the definition to test. Unknown -> 0.
--
-- Returns:
--   BIT - 1 eligible, 0 not.
--
-- Dependencies:
--   Tables: Location.LocationTypeDefinition, Location.LocationType
--
-- Change Log:
--   2026-09-17 - 1.0 - Initial version (OEE-enabled locations spec).
-- ============================================================
CREATE OR ALTER FUNCTION Location.ufn_CanBeOeeEnabled (@LocationTypeDefinitionId BIGINT)
RETURNS BIT
AS
BEGIN
    IF @LocationTypeDefinitionId IS NULL RETURN 0;

    DECLARE @Ok BIT = 0;

    SELECT @Ok = CASE
            WHEN lt.Code IN (N'WorkCenter', N'Cell')
             AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Receiving', N'Scale')
            THEN 1 ELSE 0 END
    FROM Location.LocationTypeDefinition ltd
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE ltd.Id = @LocationTypeDefinitionId;

    RETURN ISNULL(@Ok, 0);
END
GO
