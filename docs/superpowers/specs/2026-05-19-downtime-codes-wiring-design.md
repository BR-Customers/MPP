# Downtime Codes — Ops View Wiring & Editor Modal

**Date:** 2026-05-19
**Status:** Approved — moving to implementation plan
**Scope:** Wire the existing `BlueRidge/Views/Oee/DowntimeCodes` view to real data and add a single popup editor modal supporting both Create and Update flows.

---

## Context

`Oee.DowntimeReasonCode` is Arc 1 Phase 8 reference data (migration `0009_phase8_oee_reference.sql`). The full SQL surface is built and tested:

| Layer | Status |
|---|---|
| Tables (`Oee.DowntimeReasonCode`, `Oee.DowntimeReasonType`) | ✅ Built |
| Procs: `_List`, `_Get`, `_Create`, `_Update`, `_Deprecate`, `_BulkLoadFromSeed`, `_DowntimeReasonType_List` | ✅ Built, tests passing (937/937 overall) |
| Seed data | 🟡 353 rows ready in `reference/seed_data/downtime_reason_codes.csv` (S-02); ~25 rows missing TypeId |
| Ignition view scaffold (`Views/Oee/DowntimeCodes` + `Components/DowntimeCodeRow`) | 🟡 Built with hardcoded sample rows; filter sidebar + "+Add Code" button present but not wired |
| Named queries under `named-query/oee/` | ❌ Not yet created |
| Entity scripts under `BlueRidge.Oee.*` | ❌ `Oee/` folder exists with `.gitkeep` only |
| Editor modal | ❌ Not yet created |

This spec covers the gap from scaffolded view → fully interactive Ops surface for downtime-code administration.

---

## Architecture

Four layers, following established project conventions ([[mpp-confirm-unsaved-popup-pattern]], `ignition-context-pack/03_script_python.md`, `07_conventions_and_antipatterns.md`):

```
View (DowntimeCodes/view.json, DowntimeCodeEditor/view.json)
  ↓ event handlers (1-line dispatch)
Entity scripts (BlueRidge.Oee.DowntimeReasonCode, .DowntimeReasonType)
  ↓ execList / execOne / execMutation
Common helpers (BlueRidge.Common.Db, .Ui, .Util, .Notify)
  ↓ system.db.runNamedQuery
Named queries (named-query/oee/*)
  ↓ EXEC
Stored procs (Oee.DowntimeReasonCode_* — already built)
```

---

## Components to build

### 1. Named queries (6 new, under `named-query/oee/`)

| NQ path | Wraps proc | Params | Result type |
|---|---|---|---|
| `oee/DowntimeReasonCode_List` | `Oee.DowntimeReasonCode_List` | `@areaLocationId BIGINT NULL`, `@downtimeReasonTypeId BIGINT NULL`, `@searchText NVARCHAR NULL`, `@includeDeprecated BIT` | Query (list[dict]) |
| `oee/DowntimeReasonCode_Get` | `Oee.DowntimeReasonCode_Get` | `@id BIGINT` | Query (single dict) |
| `oee/DowntimeReasonCode_Create` | `Oee.DowntimeReasonCode_Create` | `@code NVARCHAR`, `@description NVARCHAR`, `@areaLocationId BIGINT`, `@downtimeReasonTypeId BIGINT NULL`, `@isExcused BIT`, `@appUserId BIGINT` | Status row |
| `oee/DowntimeReasonCode_Update` | `Oee.DowntimeReasonCode_Update` | `@id BIGINT`, `@description NVARCHAR`, `@areaLocationId BIGINT`, `@downtimeReasonTypeId BIGINT NULL`, `@isExcused BIT`, `@appUserId BIGINT` | Status row |
| `oee/DowntimeReasonCode_Deprecate` | `Oee.DowntimeReasonCode_Deprecate` | `@id BIGINT`, `@appUserId BIGINT` | Status row |
| `oee/DowntimeReasonType_List` | `Oee.DowntimeReasonType_List` | — | Query (list[dict]) |

**Schema conventions:** `version: 2`, params use **camelCase** identifiers, sqlType per Designer enum (`3` for BIGINT, `7` for NVARCHAR, `6` for BIT). All Status mutation NQs are `type: "Query"` (not `UpdateQuery`) because we read the `SELECT @Status, @Message, @NewId` row.

**Area dropdown source:** New entity-script function `BlueRidge.Location.Location.getAllAreas()` that calls the existing `getAll()` and filters in Python for `hierarchyLevel == 3` (Area is the third ISA-95 tier — Enterprise/Site/Area/WorkCenter/Cell). No new NQ — MPP has only 3 Area rows (DC/MS/TS), so client-side filter is fine. Returns `[{label: name, value: id}]` dropdown shape.

### 2. Entity scripts (2 new modules)

**`BlueRidge.Oee.DowntimeReasonCode` (`script-python/BlueRidge/Oee/DowntimeReasonCode/code.py`):**

```python
def search(filters):
    """Returns list[dict] filtered per the filter dict.
       filters: {areaLocationId, downtimeReasonTypeId, searchText, includeDeprecated}
       Empty / None values → no filter on that field."""
    # _u() unwraps QualifiedValue wrappers at the boundary

def getOne(id):
    """Single-row lookup. Returns dict or None."""

def add(meta):
    """Create new code. meta = {code, description, areaLocationId,
       downtimeReasonTypeId, isExcused}. Returns {Status, Message, NewId}."""

def update(meta):
    """Update existing code. meta = {id, description, areaLocationId,
       downtimeReasonTypeId, isExcused}. Returns {Status, Message}."""

def deprecate(id):
    """Soft-delete. Returns {Status, Message}."""

def emptyMeta():
    """Returns a blank meta dict for editor create-mode initialization.
       Defaults: code='', description='', areaLocationId=None,
       downtimeReasonTypeId=None, isExcused=False."""
```

**`BlueRidge.Oee.DowntimeReasonType` (`script-python/BlueRidge/Oee/DowntimeReasonType/code.py`):**

```python
def getAll():
    """Returns the 6 seeded types."""

def getForDropdown(includeUnassigned=False):
    """Returns [{label, value}] shape. When includeUnassigned is True,
       prepends {label: '(Unassigned)', value: None} for the filter sidebar."""
```

Both modules pass `Common.Util._u(filters)` / `_u(meta)` at entry, route through `Common.Db.execList / execOne / execMutation`, log via `Common.Util.log`, and pull `AppUserId` via `Common.Util._currentAppUserId()` for mutations.

### 3. Wire the existing `DowntimeCodes` view

Replace the hardcoded `view.custom.rows` sample data binding with a `runScript` call:

```
runScript("BlueRidge.Oee.DowntimeReasonCode.search", 0,
          {view.custom.filter})
```

The script binding's cache TTL is `0` (no cache — re-runs on any filter change). Live filtering = no Apply button.

**Filter sidebar wiring:**
- **Area dropdown** — bind options to `runScript("BlueRidge.Location.Location.getAllAreas", 0)` (or equivalent), value bidirectional to `view.custom.filter.areaLocationId`. Prepend `{label: "All Areas", value: None}`.
- **Reason Type dropdown** — bind options to `runScript("BlueRidge.Oee.DowntimeReasonType.getForDropdown", 0, true)`, value bidirectional to `view.custom.filter.downtimeReasonTypeId`. Prepend `{label: "All Types", value: None}`. The `true` arg includes the `(Unassigned)` virtual option so users can find the ~25 NULL-type rows.
- **Search input** — bidirectional to `view.custom.filter.searchText`.
- **Include Deprecated checkbox** — bidirectional to `view.custom.filter.includeDeprecated` (default false).

**Row component (`Components/DowntimeCodeRow`):**
Existing 6-column row component already takes `code, description, area, type, excused, selected` params. Add wiring:
- Row `dom.onClick` (or Edit button `onActionPerformed`) → opens `DowntimeCodeEditor` popup in `mode="update"` with `editId` param.
- Excused checkbox stays **read-only display** (no auto-save per project convention; toggling is done via the editor modal).

**Title bar `+Add Code` button:**
- `onActionPerformed` → opens `DowntimeCodeEditor` popup in `mode="create"`, no `editId`.

### 4. Editor modal — `BlueRidge/Components/Popups/DowntimeCodeEditor`

New popup view following [[mpp-confirm-unsaved-popup-pattern]] and `07_conventions_and_antipatterns.md` → "Mode discriminator on shared add/edit popups".

**Params:**
- `mode: "create" | "update"`
- `editId: BIGINT | None` — populated when mode is "update"

**View custom state:**
- `view.custom.selected: {meta}` — baseline (loaded from `getOne` in update mode; emptyMeta in create mode)
- `view.custom.editDraft: {meta}` — in-flight edits, mutated by bidirectional bindings
- `view.custom.areaOptions: list[dict]` — populated on startup via `Location.getAllAreas()`
- `view.custom.typeOptions: list[dict]` — populated on startup via `DowntimeReasonType.getForDropdown(False)` — no Unassigned virtual option here (editor is for actual values; engineering will assign one of the 6 real types)

**Layout (column flex):**

```
┌─────────────────────────────────────────────┐
│ HeaderBar:  [title] [dirty indicator] [X]   │
│   title: "Add Downtime Code" | "Edit Code"  │
├─────────────────────────────────────────────┤
│ FormBody:                                   │
│   Code:           [text input]              │  ← readonly in update mode
│   Description:    [text input]              │
│   Area:           [dropdown]                │
│   Reason Type:    [dropdown]                │
│   Excused:        [checkbox]                │
├─────────────────────────────────────────────┤
│ FooterBar:                                  │
│   [Deprecate]  ............... [Cancel][Save] │
│   ^^ visible only when mode=="update"       │
└─────────────────────────────────────────────┘
```

**Field bindings (all bidirectional to `editDraft.meta.<field>`):**

| Field | Component | Binding | Notes |
|---|---|---|---|
| Code | text-field | `editDraft.meta.code` | `props.readOnly: true` bound to `{view.params.mode} = "update"` |
| Description | text-field | `editDraft.meta.description` | Commit on `dom.onBlur` per text-field convention |
| Area | dropdown | `editDraft.meta.areaLocationId` | Required (no NULL option in editor — different from filter) |
| Reason Type | dropdown | `editDraft.meta.downtimeReasonTypeId` | Optional NULL ("(none)" option) per data model — engineering may leave unassigned |
| Excused | checkbox | `editDraft.meta.isExcused` | |

**Dirty indicator:** Bound to `if({view.custom.editDraft} != {view.custom.selected}, "● Unsaved changes", "")`.

**Save button (`onActionPerformed`):**

```python
mode = self.view.params.mode
draft = self.view.custom.editDraft.get("meta", {})
if mode == "create":
    result = BlueRidge.Oee.DowntimeReasonCode.add(draft)
    BlueRidge.Common.Ui.notifyResult(result, "Downtime code created")
else:
    result = BlueRidge.Oee.DowntimeReasonCode.update(draft)
    BlueRidge.Common.Ui.notifyResult(result, "Downtime code updated")
if result and result.get("Status"):
    system.perspective.sendMessage("downtimeCodesRefresh", scope="page")
    system.perspective.closePopup(id="mpp-downtime-code-editor")
```

**Deprecate button (`onActionPerformed`) — visible only when mode="update":**

Opens a small confirm popup ("Deprecate this code?") then on confirm:
```python
result = BlueRidge.Oee.DowntimeReasonCode.deprecate(self.view.params.editId)
BlueRidge.Common.Ui.notifyResult(result, "Downtime code deprecated")
if result and result.get("Status"):
    system.perspective.sendMessage("downtimeCodesRefresh", scope="page")
    system.perspective.closePopup(id="mpp-downtime-code-editor")
```

**Cancel button + Close X (HeaderBar):** Wire through `ConfirmUnsaved` popup pattern. If clean, close immediately; if dirty, open `BlueRidge/Components/Popups/ConfirmUnsaved` and route `confirmUnsavedResult` reply back through the standard handler.

**Parent view message handler:** `DowntimeCodes` view subscribes to page-scoped `downtimeCodesRefresh` and re-evaluates the `runScript` binding (no-op handler that touches `view.custom.filter` to force re-evaluation — or explicit assign of `view.custom.refreshTick`).

---

## Validation behavior

Server-side validation is authoritative — the procs already enforce:
- Code uniqueness (Create)
- Area FK validity (Create + Update)
- Type FK validity if non-NULL (Create + Update)
- DowntimeEvent reference check (Deprecate — refuses if events exist; FUTURE Arc 2 concern but the proc already has the guard)

Client-side validation = lightweight Save-button-disable when `code` or `description` or `areaLocationId` is empty (in create mode); update mode requires only non-empty `description` + `areaLocationId` (Code is readonly). No regex or format check on Code — codes are operational identifiers, free-form within the unique constraint.

Toast surfaces all proc failures (duplicate code, FK violation, etc.) via the standard `Common.Ui.notifyResult` route.

---

## Out of scope (explicitly deferred)

1. **Bulk load UI** — `Oee.DowntimeReasonCode_BulkLoadFromSeed` proc exists and is tested. One-shot cutover operation; will run from Designer Script Console with the seed JSON. No UI surface needed.
2. **Per-row Edit button styling refinement** — existing row component has the Edit button slot; we wire the click handler, no visual redesign.
3. **AppUser AD-elevation gate on Deprecate** — Configuration Tool runs in elevated context; per-action AD elevation is the plant-floor pattern, not the Config Tool pattern.

---

## Patterns followed

- [[mpp-confirm-unsaved-popup-pattern]] — Cancel + Close-X wiring
- [[ignition-message-scope-view-vs-page]] — `downtimeCodesRefresh` is page-scoped (popup → parent view)
- [[ignition-tree-writeback-qv-unwrap]] — `_u()` unwrap at entity-script boundary on `filters` and `meta` args
- [[ignition-expr-lookup-requires-dataset]] — Area + Type display names in the row component come from the `_List` proc's joins, not expr-language lookups against `list[dict]`
- `ignition-context-pack/03_script_python.md` — three-layer rule, `Common.*` helper convention
- `ignition-context-pack/07_conventions_and_antipatterns.md` — `editDraft` + explicit Save, dirty indicator, mode discriminator, no auto-save on bindings
- `ignition-context-pack/04_named_queries.md` — status-row mutation pattern, Designer-canonical sqlType enum, v2 resource.json schema

## NOT followed (deliberately)

- **No `SaveAll` bundled proc** — DowntimeReasonCode is a standalone entity (no child rows); the existing discrete `_Create` / `_Update` / `_Deprecate` procs are correct. [[mpp-bundled-save-pattern]] applies when parent + children edit together; that is not this case.
- **No `customMethods` on root scripts** — to sidestep the audit-pages addressing bug ([[ignition-view-customMethods-scope]]). All button handlers are inline 1–3 line dispatches into entity-script `handle*` functions or direct `runScript` bindings.

---

## File deliverables

```
ignition/projects/MPP_Config/ignition/named-query/oee/
├─ DowntimeReasonCode_List/         { query.sql, resource.json }
├─ DowntimeReasonCode_Get/          { query.sql, resource.json }
├─ DowntimeReasonCode_Create/       { query.sql, resource.json }
├─ DowntimeReasonCode_Update/       { query.sql, resource.json }
├─ DowntimeReasonCode_Deprecate/    { query.sql, resource.json }
└─ DowntimeReasonType_List/         { query.sql, resource.json }

ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Oee/
├─ DowntimeReasonCode/code.py + resource.json
└─ DowntimeReasonType/code.py + resource.json

ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Location/Location/code.py
   (MODIFY — add getAllAreas() function alongside existing getAll/getOne/...)

ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/
├─ Views/Oee/DowntimeCodes/view.json                    (MODIFY — file-edit OK, new view never opened in Designer)
├─ Components/DowntimeCodeRow/view.json                 (MODIFY — wire onClick)
└─ Components/Popups/DowntimeCodeEditor/                (NEW — view.json + resource.json)
```

---

## Acceptance criteria

1. Opening `Views/Oee/DowntimeCodes` shows real rows from `Oee.DowntimeReasonCode_List`, not hardcoded sample data.
2. Filter sidebar drives live re-filtering with no Apply button. "(Unassigned)" filter option surfaces the ~25 NULL-type rows.
3. Clicking "+ Add Code" opens the editor in create mode with empty fields; Save creates the row; toast confirms; list refreshes.
4. Clicking a row's Edit button opens the editor in update mode with populated fields; Code is readonly; Save updates; toast confirms; list refreshes.
5. Editor's Deprecate button (update mode only) soft-deletes the row; toast confirms; list refreshes (deprecated row hidden unless "Include deprecated" is on).
6. Closing the editor with unsaved changes prompts the standard `ConfirmUnsaved` 3-button dialog.
7. Server-side validation failures (duplicate code, FK violation) surface as error toasts; editor stays open for retry.
8. All SQL test suites still pass (937/937).
