# DevLauncher — location-tree dev navigation

**Date:** 2026-07-07
**Author:** Blue Ridge Automation (Jacques + Claude)
**Status:** Approved design → implementation

## Problem

The dev navigation across the shop-floor (`MPP`) project is a `top` shared dock
(`Dev/TestNavHeader`) — a 96px header wall of ~30 hardcoded buttons. Several
buttons hardcode a cell context, e.g.
`session.custom.cell = {"locationId": 76, "code": "MA1-5GOF-MIN", ...}`, then
`navigate("/shop-floor/machining-in")`. The hardcoded ids rot as the seed
changes, the wall does not reflect the plant's real shape, and the cell-setting
bypasses the production terminal-resolution path.

## Goal

Replace the button wall with a **location-tree-driven launcher**: browse the
whole plant hierarchy exactly as the Config app's Plant Hierarchy does, and on
selecting a **Terminal** node, resolve it like the production Terminal Selector
and navigate to that terminal's default screen. Non-terminal nodes are
browse-only (expand/collapse).

## Key findings that shape the design

- **Terminal Selector already does the exact click action we want.**
  `ShopFloor/TerminalSelector.selectTerminal(row)` sets
  `session.custom.terminal = {terminalLocationId, terminalCode, terminalName,
  zoneLocationId, zoneName, defaultScreen, isFallback}` and
  `navigate(defaultScreen)`.
- **Shop-floor screens self-derive their cell from the terminal.** e.g.
  `MachiningIn` `onStartup`:
  `if t and t.get("zoneLocationId"): session.custom.cell = {"locationId":
  t.get("zoneLocationId"), ...}`. So the launcher only needs to set
  `session.custom.terminal` — the old hardcoded `cell` writes were a bypass hack.
- **The tree is reusable.** `BlueRidge.Location.Tree.buildTree(rootId,
  expandDepth, defaultIcon)` (Core, available to every project) builds the
  `ia.display.tree` items from `Location.Location_GetTree`. Plant Hierarchy calls
  `buildTree(1, 2, "mpp/factory")` — `rootId = 1` is the Enterprise root.
- **Tree selection surfaces node data via a binding, not an event.** Plant
  Hierarchy binds `props.selectionData[0].value` (bidirectional) →
  `view.custom.selected`; `selected` is the clicked node's `data` dict.
- **Terminal identity + default screen is not in the tree data today** — it lives
  in `Terminal_List` (`DefaultScreen`, `IsFallback`, `ZoneId/ZoneName`).

## Design

Two artifacts. No SQL, no dock config (owner wires the dock), no change to the
shared `Location_GetTree` proc.

### 1. `BlueRidge.Location.Tree.buildLauncherTree(rootId=1, expandDepth=2)` (Core)

View-assembly helper (joins two existing read sources — this is not business
logic; terminal identity and default screens still originate in SQL via
`Terminal_List`):

1. `items = buildTree(rootId, expandDepth, "mpp/factory")`.
2. `terminals = BlueRidge.Location.Terminal.listAll()`; build
   `{TerminalId -> row}`.
3. Recursively walk `items`; for every node whose `data.id` matches a terminal:
   - `data["isTerminal"] = True`
   - `data["target"] = row.get("DefaultScreen") or ""`
   - `data["terminal"] = {` mirror of `TerminalSelector.selectTerminal`'s payload:
     `terminalLocationId, terminalCode, terminalName, zoneLocationId, zoneName,
     defaultScreen, isFallback` `}`
   - `node["icon"] = {"path": "mpp/play_arrow", "color": "--mpp-accent-50",
     "style": {}}` so terminals read as launchable.
4. Return `items` (always a list; `[]` on empty).

Non-terminal nodes keep their `buildTree` data untouched, so `data.isTerminal`
is absent/false on them.

### 2. `BlueRidge/Views/Dev/DevLauncher` view (MPP project)

`view.custom` (all bound props pre-declared with fully-shaped defaults):

- `expanded`: `true` — drawer open/closed state.
- `tree`: `[]` — `propConfig` expr binding
  `runScript("BlueRidge.Location.Tree.buildLauncherTree", 0, 1, 2)`.
- `selected`: `{"data": {"id": null, "isTerminal": false, "target": "",
  "terminal": {}}}` — bidirectional target of the tree's
  `props.selectionData[0].value`. Fully shaped so the `launch()` reads never
  traverse a missing path.

Root: `ia.container.flex` column, class `canvas`.

- **Header rail** — a logo/`DEV` button (`ia.input.button` or icon);
  `onActionPerformed` (scope `G`) toggles `view.custom.expanded`.
- **`ia.display.tree`** ("Tree") — `props.items` ← `view.custom.tree`;
  `props.selectionData[0].value` bidirectional → `view.custom.selected`;
  `position.display` ← `expanded`. Reuse Plant Hierarchy's `appearance`
  (chevron expand icons + default node icons).
- **Selection reaction** — a root `launch()` customMethod, wired to the tree's
  selection event (expected `onSelectionChange`; confirm exact event name in
  Designer). Body is event-agnostic — it reads `view.custom.selected`:

  ```python
  data = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.selected) or {}
  data = data.get("data") if "data" in data else data   # tolerate value vs node
  if not data or not data.get("isTerminal"):
      return
  target = data.get("target") or ""
  if not target:
      return
  self.session.custom.terminal = data.get("terminal") or {}
  system.perspective.navigate(target)
  ```

  Non-terminal selections fall through (native expand/collapse only). A terminal
  with no `DefaultScreen` is a no-op (no navigation target).

The view folder ships `view.json` + `resource.json` (scope `G`,
`files: ["view.json"]`) so it registers as a view, then `scan.ps1`.

## Out of scope (owner-handled / deliberately dropped)

- **Dock wiring.** Owner wires the launcher into a left dock (logo-toggled
  drawer) and retires the top `dev-nav` dock.
- **Cross-cutting non-terminal screens** (LOT Search, Genealogy, Supervisor,
  Downtime, Shift Summary, AIM Config, Hold) and utilities (Initials, Clear
  context). The launcher is tree-only and acts only on terminal nodes, per
  decision. These remain reachable in-flow / can be re-added later.
- **New SQL / `Location_GetTree` changes.** None needed — `Terminal_List`
  already carries every field.

## Risks / notes

- Tree selection event name (`onSelectionChange` vs `onItemClicked`) is
  confirmed in Designer; `launch()` reads from `view.custom.selected` so it is
  independent of which event fires it.
- Re-selecting the already-selected terminal will not re-fire a change event
  (value unchanged) — acceptable for a dev tool.
- `buildLauncherTree` reuses `buildTree`'s single-forward-pass output; the
  terminal overlay is a second recursive walk over the assembled node tree.
