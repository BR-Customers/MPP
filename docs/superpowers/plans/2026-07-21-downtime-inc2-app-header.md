# Downtime Increment 2 — App Header — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dev top-dock (`TestNavHeader`) with a production **App Header** on every plant-floor screen: live clock, terminal/scope/shift/operator context, a Downtime button (opens the manager popup), an Elevated-Login button, a "line down" pill, and a dev-menu toggle.

**Architecture:** One new Perspective view `Views/ShopFloor/AppHeader`, wired as the `top` shared dock in `page-config`. It reads existing `session.custom.*` context + `Shift_GetOpen` + (Inc 1) `Downtime.getByScope` for the pill. No SQL. The Downtime button opens `Components/Popups/DowntimeManager` (built in Inc 3 — until then it opens to an empty/placeholder popup that Inc 3 fills).

**Tech Stack:** Ignition 8.3 Perspective, Jython, `scan.ps1`.

## Global Constraints
- New view → author as files + `.\scan.ps1` (safe; `feedback_ignition_view_edit_boundary`).
- Event-script bodies start with a tab; `system.perspective.*` from dom/component events uses `scope: "G"` (`feedback_ignition_popup_open_scope`, `feedback_ignition_event_script_indent`).
- Use `psc-pf-*` classes + `--mpp-accent-NN` tokens (Core stylesheet; bare `--mpp-accent` is undefined — `project_mpp_core_stylesheet_canonical`).
- Perspective live clock = expression `now(1000)` + `dateFormat(...)` (polls once/sec, ET is the gateway/session tz).
- Commit to `jacques/working`, explicit paths.

## Reference (read first)
- `Views/Dev/TestNavHeader/view.json` (what we replace; session.custom usage, `toggleDock('LeftDock')`)
- `page-config/config.json` `sharedDocks.top` (the `dev-nav` dock)
- A screen header for style (`Views/ShopFloor/AssemblyNonSerialized` header row: title/subtitle/`Operator:`/status pill/action buttons)
- Session context: `session.custom.terminal{terminalLocationId, zoneLocationId, ...}`, `session.custom.cell{locationId,code,name}`, `session.custom.user{initials,displayName}`

---

## Task 1: `AppHeader` view

**Files:** Create `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AppHeader/{view.json,resource.json}`

**Interfaces — Produces:** the top-dock chrome; opens popup id `mpp-downtime-manager` (Inc 3 view path).

- [ ] **Step 1: Author the view** — a single `ia.container.flex` root (row, `alignItems:center`, `psc-pf` header styling, height ~56), children left→right:
  - **Brand/Context** (column): line 1 = terminal name `{session.custom.terminal.terminalName}` (fallback text "Madison Facility" when null); line 2 = scope/cell `{session.custom.cell.name}` (or "(no cell)").
  - **Clock** (label): `props.text` ← expr `dateFormat(now(1000), "EEE MMM d   h:mm:ss a")`.
  - **Shift** (label): `props.text` ← expr `runScript("BlueRidge.Oee.Shift.getOpenOrEmpty", 5000).ScheduleName` wrapped with a "(no shift)" fallback via `if(...)`. (getOpenOrEmpty returns the shaped empty dict — safe.)
  - **Operator** (label): `"Operator: " + coalesce({session.custom.user.initials}, "--")`.
  - **Spacer** (grow 1).
  - **LineDown pill** (label): visible + red (`--mpp-accent`-danger or a red token) when scope has an open event. Bind `props.text`/`meta.visible` to expr:
    `runScript("BlueRidge.Oee.Downtime.getByScope", 30000, runScript("BlueRidge.Oee.Downtime.resolveScope",0,{session.custom.cell.locationId}), true, null)` → transform (script) to `len([r for r in (value or []) if r.get("IsOpen")])`; show "● LINE DOWN (n)" when >0. (30s poll.)
  - **Downtime button** (`pf-btn pf-btn-primary`): `onActionPerformed` (tab, scope G):
    ```python
    	system.perspective.openPopup(id="mpp-downtime-manager", view="BlueRidge/Components/Popups/DowntimeManager", modal=True, showCloseIcon=False, params={})
    ```
  - **Elevated Login button** (`pf-btn pf-btn-secondary`): `onActionPerformed` (tab, scope G): `\tsystem.perspective.login()`
  - **Dev menu button** (`pf-btn pf-btn-secondary`, small): `\tsystem.perspective.toggleDock("LeftDock")`

  Pre-declare every bound `session.custom.*`/`view.custom.*` path with safe fallbacks in expressions (`coalesce`/`if(isNull(...))`) so a missing session prop never Component-Errors (`feedback_ignition_predeclare_bound_custom_props`, `feedback_ignition_coalesce_type_match`).

- [ ] **Step 2: resource.json** — scope `G`, `files:["view.json"]` (mirror an existing ShopFloor view's resource.json).

- [ ] **Step 3: Validate + scan** — `python -m json.tool` the view.json; AST-check embedded scripts (wrap in `def f(self,event=None,value=None)`); `.\scan.ps1`; confirm no deserialize error.

- [ ] **Step 4: Commit**
```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AppHeader
git commit -m "feat(plantfloor): AppHeader view (clock, context, downtime, elevated login, dev toggle)"
```

---

## Task 2: Wire the top dock + verify

**Files:** Modify `ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json`

- [ ] **Step 1: Point the top dock at AppHeader** — in `sharedDocks.top[0]` change `"viewPath": "BlueRidge/Views/Dev/TestNavHeader"` → `"BlueRidge/Views/ShopFloor/AppHeader"`, set `"size": 56`, keep `id: "dev-nav"` (or rename to `"app-header"` — cosmetic; if renamed, nothing else references it). Leave `LeftDock` (DevLauncher) and `notify-host` untouched. `TestNavHeader` stays available at page `/dev/test-nav`.

- [ ] **Step 2: Scan + verify in the plant-floor app** — `.\scan.ps1`; open `http://localhost:8088/data/perspective/client/MPP/shop-floor/downtime` (or any screen). Confirm: the new header renders on top (no red DEV NAV bar), the clock ticks, Operator/context show, the **Downtime** button opens a popup (empty until Inc 3), the **Dev menu** button still toggles the DevLauncher left dock. `get_page_text` should show the clock string + "Operator:".

- [ ] **Step 3: Commit**
```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json
git commit -m "feat(plantfloor): use AppHeader as the top dock (replaces TestNavHeader)"
```

---

## Self-Review
- Clock, context (terminal/cell/shift/operator), Downtime button, Elevated Login, dev toggle, line-down pill — all in Task 1; dock wiring in Task 2. Spec §3 covered. ✅
- No nav buttons (production auto-routes); DevLauncher kept reachable. ✅
- Fallbacks on every bound session prop; new-view file-authoring + scan. ✅
- Data-dependent verify during build: exact `session.custom.terminal` field name for the terminal display name (`terminalName` vs `terminalCode`); the red/danger color token for the pill (use a defined `--mpp-*` value, not bare `--mpp-accent`).
