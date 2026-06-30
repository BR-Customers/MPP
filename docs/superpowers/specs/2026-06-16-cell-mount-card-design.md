# Cell Mount Card — mount-from-location on the Plant Hierarchy

**Date:** 2026-06-16
**Status:** Approved (design), pending implementation
**Surface:** Configuration Tool → Plant Hierarchy (`/plant`, project `MPP_Config`)

## Problem

An elevated user browsing the Plant Hierarchy should be able to (a) see at a glance
what tool is mounted on a given machine, and (b) mount a tool from the *location*
side when a machine is missing one — the inverse of today's tool-first mount flow
(Tools → Assignments tab). Today the Plant Hierarchy only shows a read-only
"Mounted Tool" card, and only when something is already mounted.

## Decisions (locked)

| Question | Decision |
|---|---|
| Action scope | **Mount when empty + Release when full.** No one-click swap (release then mount). |
| Visibility | **Permanent card for mount-capable cells** (empty *or* occupied), hidden elsewhere. |
| Mount-capable signal | **Data-driven**: a location is a mount target iff some `Tools.ToolType.CompatibleLocationTypeDefinitionId` references the location's `LocationTypeDefinitionId`. No new flag, no hardcoded codes. |
| Auth gating | **None in the UI** — any signed-in config user; attribution = their `AppUserId`. Matches the existing Tools → Assignments tab. (FDS-04-007 elevation remains a future project-wide effort.) |
| Structure | **Reusable embedded component** `BlueRidge/Components/Location/CellMountCard`, mirroring the Tool-side `Assignments` component, inverted. |

## Architecture

```
PlantHierarchy (MPP_Config view)
  DetailArea > FlexContainer
    LocationDetailsPanel        (existing)
    ia.display.view ───────────► BlueRidge/Components/Location/CellMountCard
        params.cellLocationId  ◄─ {view.custom.selected.id}
        position.display       ◄─ {view.custom.cellContext.IsMountTarget} && mode != "view"
```

The card is self-contained: it owns its reads, Mount/Release, and refresh. It never
calls back to the page (mounting does not change the location tree). The parent only
needs the `IsMountTarget` bit to decide whether to render the embed.

## Data layer (Core, `Tools` schema, repeatable procs + `parts/` NQs)

### 1. `Tools.ToolAssignment_GetCellContext(@CellLocationId BIGINT)`
Always returns **exactly one row** (drives both visibility and content):

| Column | Type | Notes |
|---|---|---|
| `IsMountTarget` | BIT | `EXISTS(ToolType WHERE CompatibleLocationTypeDefinitionId = cell's LocationTypeDefinitionId)` |
| `ToolAssignmentId` | BIGINT | active assignment Id, NULL if empty |
| `ToolId` | BIGINT | NULL if empty |
| `ToolCode` | NVARCHAR | NULL if empty |
| `ToolName` | NVARCHAR | NULL if empty |
| `ToolTypeCode` | NVARCHAR | NULL if empty |
| `AssignedAt` | DATETIME2(3) | ET-converted at the boundary (`AT TIME ZONE`), NULL if empty |
| `AssignedByInitials` | NVARCHAR | from `AppUser`, NULL if empty |

A non-Cell / deprecated / unknown `@CellLocationId` still returns one row with
`IsMountTarget = 0` and NULL tool columns.

### 2. `Tools.Tool_ListMountableForCell(@CellLocationId BIGINT)`
Active tools eligible to mount on this cell — inverse of `Tool_ListCompatibleCells`:
- Tool active (`DeprecatedAt IS NULL`).
- Tool's `ToolType.CompatibleLocationTypeDefinitionId` matches the cell's
  `LocationTypeDefinitionId` **or is NULL** (unrestricted type → any cell).
- No open `ToolAssignment` for the tool (`ReleasedAt IS NULL` none) — i.e. currently unmounted.

Result: `Id, Code, Name`, ordered by `Code`. Empty when the cell is not a mount target.

### NQs (Core, group `parts/`)
`parts/ToolAssignment_GetCellContext` (`cellLocationId`), `parts/Tool_ListMountableForCell` (`cellLocationId`). Both `type: "Query"`, `sqlType: 3` for the BIGINT param.

### Entity methods (Core `BlueRidge.Parts.Tool`)
- `getCellMountContextOrEmpty(cellLocationId)` → shaped dict, never None (`IsMountTarget`,
  `ToolAssignmentId`, `ToolId`, `ToolCode`, `ToolName`, `ToolTypeCode`, `AssignedAt`,
  `AssignedByInitials`). `IsMountTarget` coerced to bool.
- `getMountableToolsForCell(cellLocationId)` → `[{label: "<Code> — <Name>", value: <ToolId>}]`.
- Reuse existing `assignToCell(toolId, cellLocationId, notes)` and `releaseAssignment(toolId)`.

## Component: `BlueRidge/Components/Location/CellMountCard`

**params:** `cellLocationId` (input). **custom:** `context` (shaped default), `mountable` (`[]`),
`selectedToolId` (null), `mountNotes` (`""`).

**Bindings:** `context` ← `runScript(getCellMountContextOrEmpty, cellLocationId)`;
`mountable` ← `runScript(getMountableToolsForCell, cellLocationId)`.
`onChange` on `params.cellLocationId` → `refresh()`.

**customMethods** (mirror Tool-side `Assignments`):
- `refresh()` — direct-write `context`/`mountable` from the entity methods.
- `handleMount()` — guard tool selected → `assignToCell(... )` → `notifyResult` → on success clear inputs + `refresh()`.
- `handleRelease()` — `releaseAssignment(context.ToolId)` → `notifyResult` → on success `refresh()`.

(Post-action refresh is a direct custom-prop write, not `refreshBinding` — which no-ops in handlers.)

**Layout:**
- **OccupiedState** (`!isNull(context.ToolId)`): `ToolCode — ToolName`, type badge,
  "Assigned `<AssignedAt>` by `<AssignedByInitials>`", **Tool Config** button (`nav /parts/tools`), **Release** button.
- **EmptyState** (`isNull(context.ToolId)`): "No tool mounted" + **Tool** dropdown (`mountable`) +
  optional **Notes** + **Mount** button (disabled until a tool is picked).

## PlantHierarchy changes
- Replace the inline `MountedToolPanel` body with the `ia.display.view` embed of `CellMountCard`.
- Declare `custom.cellContext` (shaped, `IsMountTarget` default false) bound to
  `runScript(getCellMountContextOrEmpty, selected.id)`; the old `custom.mountedTool` prop and
  its binding are removed.
- Embed `position.display` ← `{view.custom.cellContext.IsMountTarget} && {view.custom.mode} != "view"`.
- The card refreshes its own state on action; the parent's `cellContext` only feeds the
  visibility gate (`IsMountTarget` doesn't change on mount/release, so no parent refresh needed).

## Error handling
`assignToCell` / `releaseAssignment` return status rows → `Common.Ui.notifyResult` toasts
(e.g. "Another tool is already mounted on this cell"). Reads return the shaped/empty dict;
null `cellLocationId` → `IsMountTarget = false` → card hidden. No new error paths.

## Testing — `sql/tests/0026_Tools_CellMount/`
- `010_GetCellContext.sql`: mount-target cell empty (`IsMountTarget=1`, ToolId NULL);
  mount-target cell occupied (tool columns populated); non-mount-target cell (`IsMountTarget=0`);
  unknown/deprecated cell (`IsMountTarget=0`, one row).
- `020_ListMountableForCell.sql`: compatible unmounted tool returned; mounted tool excluded;
  incompatible tool-type excluded; NULL-compat tool-type returned for any cell.
Run: `.\Run-Tests.ps1 -Filter "CellMount"` (reset applies the new repeatable procs).

## File inventory
- `sql/migrations/repeatable/R__Tools_ToolAssignment_GetCellContext.sql` (new)
- `sql/migrations/repeatable/R__Tools_Tool_ListMountableForCell.sql` (new)
- `sql/tests/0026_Tools_CellMount/010_GetCellContext.sql`, `020_ListMountableForCell.sql` (new)
- `ignition/projects/Core/ignition/named-query/parts/ToolAssignment_GetCellContext/{query.sql,resource.json}` (new)
- `ignition/projects/Core/ignition/named-query/parts/Tool_ListMountableForCell/{query.sql,resource.json}` (new)
- `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Tool/code.py` (edit: 2 methods)
- `ignition/projects/MPP_Config/.../views/BlueRidge/Components/Location/CellMountCard/{view.json,resource.json}` (new)
- `ignition/projects/MPP_Config/.../views/BlueRidge/Views/Location/PlantHierarchy/view.json` (edit: embed + cellContext)

## Out of scope (YAGNI)
One-click swap; per-cell mount history on the card (stays on the Tool-side Assignments tab);
new elevation/role mechanism; resolving `AssignedByInitials` anywhere beyond this read.
