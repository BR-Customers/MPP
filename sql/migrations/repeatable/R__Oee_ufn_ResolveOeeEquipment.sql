-- ============================================================
-- Repeatable:  R__Oee_ufn_ResolveOeeEquipment.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
-- Description: THE definition of "a piece of equipment" for OEE purposes --
--              the set of Location.Location rows that downtime is logged
--              against and that an OEE figure can be computed for.
--
--              Two conditions, both necessary:
--
--              (1) SELF-SCOPING. Oee.ufn_ResolveDowntimeScope(Id) = Id. That
--                  resolver is what Oee.DowntimeEvent.LocationId is already
--                  bucketed by: a Machining/Assembly sub-cell resolves UP to
--                  its WorkCenter line, so the line is the equipment and the
--                  sub-cell is not. A die cast press has no WorkCenter
--                  ancestor, so it resolves to itself and IS the equipment.
--
--              (2) NOT A DEVICE OR A STORE. Self-scoping alone is too broad:
--                  Terminals and Printers under a die cast Area also resolve to
--                  themselves (10 Terminals do so in Dev today), as do
--                  InventoryLocation / Receiving. A terminal is an operator IO
--                  device and a rack is a store -- neither runs a shift, and
--                  neither can have downtime meaningfully attributed to it.
--                  Excluded by LocationTypeDefinition code.
--
--              Tier is restricted to WorkCenter / Cell so the Enterprise, Site
--              and Area rows (which trivially self-scope) never appear.
--
--              Single source of truth: both Oee.ShiftOverride_ListEquipment
--              (the picker) and Oee.ShiftOverride_Create (the validation) read
--              this function, so the list an operator can choose from and the
--              set the proc will accept cannot drift apart.
--
--              Adding a new equipment LocationTypeDefinition needs no change
--              here -- it is admitted automatically. Adding a new DEVICE or
--              STORE definition under a die cast Area does need it added to
--              the exclusion list below.
--
--              Read-only inline TVF: no OUTPUT params, no audit, no status row.
--
--              NAME IS ORDER-SENSITIVE -- do not "tidy" it to ufn_OeeEquipment.
--              Reset-DevDatabase deploys repeatables in filename order, and a
--              FUNCTION gets no deferred name resolution (Msg 4121) -- unlike a
--              procedure, which does. This file must therefore sort AFTER
--              R__Oee_ufn_ResolveDowntimeScope.sql, the scalar function it
--              calls. "Resolve..." keeps it adjacent to that sibling and after
--              it ("ResolveD" < "ResolveO").
--
-- Result set:
--   LocationId, Code, Name, TierCode, DefinitionCode, ParentName, SortOrder
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationTypeDefinition, Location.LocationType
--   Funcs:  Oee.ufn_ResolveDowntimeScope
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (backlog 6.1).
-- ============================================================
CREATE OR ALTER FUNCTION Oee.ufn_ResolveOeeEquipment ()
RETURNS TABLE
AS
RETURN
(
    SELECT
        l.Id        AS LocationId,
        l.Code,
        l.Name,
        lt.Code     AS TierCode,
        ltd.Code    AS DefinitionCode,
        p.Name      AS ParentName,
        l.SortOrder
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType           lt  ON lt.Id  = ltd.LocationTypeId
    LEFT  JOIN Location.Location               p   ON p.Id   = l.ParentLocationId
    WHERE l.DeprecatedAt IS NULL
      AND lt.Code IN (N'WorkCenter', N'Cell')
      -- Devices and stores are not equipment (see header condition 2).
      AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Receiving')
      -- Downtime for this location is logged against this location (condition 1).
      AND Oee.ufn_ResolveDowntimeScope(l.Id) = l.Id
);
GO
