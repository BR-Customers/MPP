# MPP MES — Configuration Tool Frontend Conventions

**Document:** MPP-MES-FECONV-001
**Project:** Madison Precision Products MES Replacement
**Prepared By:** Blue Ridge Automation
**Version:** 1.2
**Date:** 2026-05-05

---

## Revision History

| Version | Date | Author | Change Summary |
|---|---|---|---|
| 1.0 | 2026-05-05 | Blue Ridge Automation | Initial conventions: three-layer DB architecture, save semantics, versioning workflow refinements |
| 1.1 | 2026-05-05 | Blue Ridge Automation | Section 4 expanded to align with the Blue Ridge "Standardization & Collaboration" Ignition standards deck: component naming requirement, view-level custom props as the default, binding/script efficiency hierarchy (replaces standalone 3-line cap rule), page-title requirement in page-config. |
| 1.2 | 2026-05-05 | Blue Ridge Automation | Component naming clarified: root container keeps reserved `meta.name: "root"`. Style class references in `view.json` use the suffix only (no `psc-` prefix) — Perspective adds the prefix at render time. |

---

## Purpose

This document defines architectural and interaction conventions for the Configuration Tool's Ignition Perspective frontend. It complements `MPP_MES_CONFIGURATION_UI_SPEC.md` (which describes screen-by-screen behavior) by specifying the cross-cutting rules that all screens follow.

Three concerns are covered:

1. **Three-layer DB architecture** — how Perspective views, entity scripts, and shared helpers interact with stored procedures.
2. **Save semantics** — when database writes happen relative to user actions.
3. **Versioned-entity workflow refinements** — clarifications on top of the general Draft / Published / Deprecated state machine documented in the UI Spec.

These conventions also apply to the Plant Floor (Arc 2) build except where the Plant Floor explicitly diverges (e.g., real-time terminal interactions may have different save semantics — to be specified separately).

---

## Scope vs. UI Spec

| Decision | This doc | UI Spec |
|---|---|---|
| Three-layer architecture (View → Entity Script → Common helpers) | yes | — |
| `BlueRidge.Common.Db` helper API | yes | — |
| Notification / banner mechanism | yes | — |
| `editDraft` pattern, dirty indicator, multi-tab rules | yes | — |
| Versioning state machine (Draft / Published / Deprecated) | recap only | authoritative |
| Per-screen layout, components, stored proc names | — | yes |
| `EffectiveFrom` constraint, optimistic locking | yes | — |
| Edit-when-Draft-already-exists behavior | yes | — |

Cross-reference whenever a screen's behavior is governed by a rule here.

---

## Section 1 — Three-Layer DB Architecture

### Layering rule

Perspective views never call `system.db.*` directly. Entity scripts never call `system.db.execQuery` / `execUpdate` directly. All database access flows through `BlueRidge.Common.Db`.

| Layer | Path | Allowed to call |
|---|---|---|
| **View** | `views/BlueRidge/Views/<Schema>/<Page>/view.json` | Entity scripts only |
| **Entity Script** | `script-python/BlueRidge/<Schema>/<Entity>/code.py` | `BlueRidge.Common.*` and other entity scripts |
| **Common Helpers** | `script-python/BlueRidge/Common/<Module>/code.py` | `system.db.*`, `system.perspective.*`, low-level Ignition APIs |

**Why:** named-query names stay out of views (rename without grepping 30 files); UI-shape vs. DB-shape conversion has one home; business logic doesn't leak into bindings; the same entity script serves UI events, gateway timers, and (eventually) REST endpoints.

### `BlueRidge.Common.Db` — three sibling functions

#### Mutation result shape (returned by `execMutation`)

A plain dict whose keys match the proc's final `SELECT` aliases — no wrapper class, no derived fields. Callers read the same keys the SQL author wrote.

```python
# After an Add proc:
{"Status": "OK",    "Message": "Part created",                  "NewId": 4172}
{"Status": "ERROR", "Message": "PartNumber 'XYZ' already exists", "NewId": None}

# After an Update or Deprecate proc (no NewId in the SELECT):
{"Status": "OK",    "Message": "Part updated"}
{"Status": "ERROR", "Message": "This record was modified by another user. Please reload and try again."}
```

| Key | Type | Meaning |
|---|---|---|
| `Status` | str | `"OK"` on success; `"ERROR"` (or any non-`OK` value) on a business-rule failure surfaced from the proc. Comparison is case-sensitive against `"OK"`. |
| `Message` | str | The proc's `Message` column. Empty string on success unless the proc populated it. |
| `NewId` | int or None | Present only for Add procs (which select `@NewId`). Update / Deprecate result dicts have no `NewId` key. Callers should use `.get("NewId")` rather than `[...]` indexing if the proc type isn't known. |

Choosing a plain dict (over a namedtuple or class) keeps the wire shape and the script-side shape identical — no translation layer between SQL and Jython. Adding a new proc-side column (e.g., `@AffectedRows`) automatically appears in the result dict without touching the helper.

#### `execList(nq, params=None) → list[dict]`

For read procs that return 0..N data rows. Empty list = "no rows matched"; never `None`, never an exception for the not-found case.

```python
# Entity script
def getAll():
    return BlueRidge.Common.Db.execList("parts/getAllParts")
    # → [{"Id": 1, "PartNumber": "5GO-AP4-001", ...}, ...]
```

Implementation contract:

- Calls `system.db.execQuery(nq, params)` if `params` non-`None`, else without params.
- Reads `getColumnNames()`, zips each row into a dict.
- Logs the call: `BlueRidge.Common.Util.log("execList nq=%s params=%s rows=%d" % (nq, params, len(rows)))`.

#### `execOne(nq, params=None) → dict or None`

For read procs that return 0 or 1 row. Returns the dict or `None`.

```python
def getOne(partId):
    return BlueRidge.Common.Db.execOne("parts/getPart", {"PartId": partId})
    # → {"Id": 1, ...} or None
```

If the proc returns more than one row, log a warning and return the first.

#### `execMutation(nq, params=None) → dict`

For Add / Update / Deprecate procs that follow the MPP convention `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId` (or the same without `NewId` for Update / Deprecate).

```python
def add(data):
    params = {
        "PartNumber":  data.get("PartNumber"),
        "Description": data.get("Description"),
        "UoMId":       data.get("UoMId"),
        "AppUserId":   _currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("parts/addPart", params)
```

Implementation contract:

- Calls `system.db.execQuery(nq, params)` (always `execQuery`, even though procs return one row — never `execUpdate`, which discards the result set).
- Reads the first row, zips it into a dict keyed by the proc's `SELECT` aliases (`Status`, `Message`, optionally `NewId`).
- If the result set is empty (proc didn't `SELECT` anything), returns `{"Status": "ERROR", "Message": "No status returned from proc"}`.
- If the result set has more than one row, logs a warning and returns the first row.
- Returns the dict even on `Status='ERROR'`. **Does not raise** — business-rule failures are not exceptions.
- Hard JDBC errors and proc `RAISERROR` propagate as `system.db` exceptions. Callers may wrap in try/except for those, but typically don't need to.

Logs the call and outcome.

### `BlueRidge.Common.Ui` — notification helper

#### `notifyResult(result, successText, errorText=None)`

Sends one Perspective message to the shared `NotificationBanner` based on `result["Status"]`.

```python
def runAction(self, event):
    result = BlueRidge.Parts.Part.add(self.view.custom.editDraft)
    BlueRidge.Common.Ui.notifyResult(result, successText="Part created")
    if result["Status"] == "OK":
        system.perspective.sendMessage("refreshTrigger")
```

Behavior:

- On success (`result.get("Status") == "OK"`): sends `{"type": "success", "text": successText}`.
- On failure: sends `{"type": "error", "text": result.get("Message") or errorText or "Save failed"}`. (Proc-supplied message wins, then caller-supplied fallback, then a generic.)
- Pure UI — calls `system.perspective.sendMessage("notify", payload)`. Does not touch the DB.

### `BlueRidge/Components/NotificationBanner` — shared component

A Perspective view mounted once, in the project's top dock or as a session-overlay container. Subscribes to message name `"notify"`.

Payload contract:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `type` | string | yes | One of `success`, `error`, `warning`, `info`. |
| `text` | string | yes | Banner copy. |
| `durationMs` | int | no | Auto-dismiss timeout. Default 4000 (success / info), 8000 (warning / error). |

Behavior:

- Stacks if multiple messages arrive simultaneously (max 3 visible).
- Auto-dismisses after `durationMs`.
- User can manually close via X button.
- Color and icon coded by `type`.

### Example: full read + mutation flows

**Read flow** — load all parts on screen open:

```python
# script-python/BlueRidge/Parts/Part/code.py
def getAll():
    return BlueRidge.Common.Db.execList("parts/getAllParts")

def getOne(partId):
    return BlueRidge.Common.Db.execOne("parts/getPart", {"PartId": partId})
```

```json
// view.json — onStartup binding on view.custom.parts
"custom.parts": {
  "binding": {
    "type": "expr",
    "config": { "expression": "runScript('BlueRidge.Parts.Part.getAll', 0)" }
  }
}
```

**Mutation flow** — Save button on Part editor:

```python
# script-python/BlueRidge/Parts/Part/code.py
def add(data):
    params = {
        "PartNumber":  data.get("PartNumber"),
        "Description": data.get("Description"),
        "UoMId":       data.get("UoMId"),
        "AppUserId":   _currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("parts/addPart", params)

def update(data):
    params = {
        "Id":          data.get("Id"),
        "PartNumber":  data.get("PartNumber"),
        "Description": data.get("Description"),
        "UoMId":       data.get("UoMId"),
        "RowVersion":  data.get("RowVersion"),   # optimistic locking
        "AppUserId":   _currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("parts/updatePart", params)
```

The Save button's `onActionPerformed` event calls `BlueRidge.Parts.Part.add` or `.update` based on whether `editDraft.Id` is set, passes the result to `BlueRidge.Common.Ui.notifyResult`, commits `selected = editDraft` on success, and sends `"refreshTrigger"`. Inline event scripts are capped at 3 lines (see Section 4); if the Save handler grows past that, factor it into the entity script as `BlueRidge.Parts.Part.handleSave(draft)`.

### Anti-patterns to avoid

- View calling `system.db.execQuery` directly. Always go through an entity script.
- Entity script calling `system.db.execQuery` directly. Always go through `BlueRidge.Common.Db`.
- `eval()` of dynamic script paths (Spinner-style generic Add / Archive buttons that take a script-path string and `eval` `<path>.add(...)`). Write specific handlers.
- Stored procs doing UPSERT (one proc handles INSERT and UPDATE based on whether the ID is null). MPP convention is separate Add and Update procs.
- Multi-line Python pasted into `view.json` event configs. See Section 4.

---

## Section 2 — Save Semantics

### Pattern B: editDraft + explicit Save

Every editing surface (Add modal, Edit modal, in-place editor pane) maintains a local `editDraft` that diverges from the displayed `selected` row. The DB is touched only when the user clicks **Save**.

```json
// view.json — view.custom state
"custom": {
  "selected":  {},   // the currently selected entity, as last loaded from DB
  "editDraft": {}    // the in-flight edits; mutated by form bindings
}
```

When the user selects a row from the list:

```python
self.view.custom.selected  = selected_row
self.view.custom.editDraft = dict(selected_row)   # shallow copy
```

Form components (text fields, dropdowns, checkboxes) bind bidirectionally to `editDraft.*` paths. **Edits to `editDraft` do not write to the DB.**

Save:

```python
result = BlueRidge.Parts.Part.update(self.view.custom.editDraft)
BlueRidge.Common.Ui.notifyResult(result, successText="Saved")
if result["Status"] == "OK":
    self.view.custom.selected = dict(self.view.custom.editDraft)   # commit local
    system.perspective.sendMessage("refreshTrigger")
```

Cancel:

```python
self.view.custom.editDraft = dict(self.view.custom.selected)   # revert
```

### Universal rules

1. **Zero auto-save.** No bound checkbox, dropdown, or arrow click writes to the DB on its own. Every database write is the result of an explicit user click on a Save (or Save-equivalent: Publish, Deprecate) button.

2. **No navigation guard.** Switching to a different entity (clicking another row in the list) silently replaces `editDraft` with the new entity's data. Unsaved edits are lost without a warning dialog.

   *Rationale:* operators are trained; the dirty indicator is the warning; modal interrupts disrupt workflow more than they help.

3. **Multi-tab forms share one `editDraft`.** Editors with multiple tabs (e.g., Item Master with several tabs per Part) keep one `editDraft` object across all tabs. Tab switches do not commit. The user can edit fields on Tab 1, switch to Tab 2, edit more fields, and clicking Save persists all of it together. Switching to a *different entity* discards all of it.

4. **Up / Down arrow buttons mutate `editDraft` ordering only.** Reordering a list (e.g., Route steps, BOM components) updates `editDraft.steps[]` order locally. The new order is committed only when Save is clicked.

5. **Toggle controls (`IsActive`, etc.) do not auto-save.** They flip a property on `editDraft`; Save commits.

### Dirty indicator

Whenever `editDraft != selected`, the editor displays a small visual cue (no popup, no navigation block, no DB call):

```
[Save] [Cancel]    ● Unsaved changes
```

Implementation: an expression-bound text on a small label component in the editor footer.

```json
"propConfig": {
  "props.text": {
    "binding": {
      "type": "expr",
      "config": { "expression": "if({view.custom.editDraft} != {view.custom.selected}, '● Unsaved changes', '')" }
    }
  }
}
```

### Multi-tab persistence example (Item Master)

The Item Master editor has tabs: General, BOM, Routes, Quality, Eligibility. The user:

1. Clicks Part `5GO-AP4-001` in the list. `selected` = that part; `editDraft` = a copy.
2. Edits Description on the General tab. `editDraft.Description` differs from `selected.Description`. The dirty indicator appears.
3. Switches to the Eligibility tab. Toggles three location checkboxes. `editDraft.eligibility[]` differs.
4. Switches back to General. Description edits are still present.
5. Clicks Save. Both Description and eligibility changes persist together.

If at step 4 the user clicks a different Part instead, all edits to `editDraft` are silently dropped and `editDraft` is replaced with the new Part's data. The dirty indicator clears.

### Eligibility Map (UI Spec Screen 10) — supersedes the existing spec

Screen 10 in `MPP_MES_CONFIGURATION_UI_SPEC.md` currently states *"Click any cell to toggle eligibility. Changes save immediately."* **This document supersedes that.** Eligibility Map cells flip in `editDraft` on click; the screen's Save button commits the diff against `selected` (calling `Parts.ItemLocation_Add` for newly checked cells and `Parts.ItemLocation_Remove` for newly unchecked cells).

### Route Builder (UI Spec Screen 9) move-up / move-down — supersedes the existing spec

Screen 9 currently maps the up / down arrows directly to `Parts.RouteStep_MoveUp` / `_MoveDown` procs. **This document supersedes that.** Arrow clicks reorder `editDraft.steps[]` locally; the screen's Save button commits the new ordering.

The `_MoveUp` / `_MoveDown` procs may still exist for batch-import or migration tooling, but the UI does not call them on click.

---

## Section 3 — Versioned-Entity Workflow Refinements

The general state machine for `BomTemplate`, `RouteTemplate`, `OperationTemplate`, and `QualitySpec` (Draft / Published / Deprecated) is documented in `MPP_MES_CONFIGURATION_UI_SPEC.md`. This section captures refinements on top of it.

### State machine recap

| State | DB shape | Buttons |
|---|---|---|
| Draft | `PublishedAt IS NULL AND DeprecatedAt IS NULL` | Discard, Save, Publish |
| Published | `PublishedAt IS NOT NULL AND DeprecatedAt IS NULL` | Edit, Deprecate |
| Deprecated | `DeprecatedAt IS NOT NULL` | (view only) |

- Editing a Published version creates a new Draft row with `VersionNumber + 1`.
- Saving a Draft mutates the Draft row in place (no new row per Save).
- Publishing a Draft sets its `PublishedAt = now()` and stamps `DeprecatedAt = now()` on the previous Published.
- Discarding a Draft hard-deletes that row.
- A Published version cannot be un-Published. The only forward path is Edit (creates a new Draft) or Deprecate.

### Refinement 1 — Edit-when-Draft-already-exists (pattern δ)

If a user clicks **Edit** on a Published version and a Draft for the same logical entity already exists (created by them or someone else), present a dialog:

```
┌──────────────────────────────────────────────────────────────┐
│ A draft already exists for this Route                        │
├──────────────────────────────────────────────────────────────┤
│ Draft v4 — last edited 2 days ago by Jen Lewis               │
│                                                              │
│ ○ Continue editing existing Draft                            │
│ ○ Start fresh from current Published                         │
│   (Draft v4 will be discarded)                               │
│                                                              │
│                                          [Cancel] [Continue] │
└──────────────────────────────────────────────────────────────┘
```

Default selection: "Continue editing existing Draft." Most engineers will pick this and parallel Drafts stay rare.

If "Start fresh" is chosen, the existing Draft is hard-deleted (same as a Discard) before the new Draft row is created from the current Published.

Implementation note: the existing-Draft check happens in the entity script's `getCurrentDraft(logicalId)` call before opening the editor. The dialog appears only if a Draft is found.

### Refinement 2 — Validation timing

| Action | Validation level | Rationale |
|---|---|---|
| Save (on Draft) | None at proc level. UI may flag missing-required-fields visually. | Drafts may be incomplete; saving partial work is the whole point. |
| Publish | Full validation in the stored proc. Proc returns `Status='ERROR'` with a specific `Message` if any rule fails. | Publishing means "this version goes live" — must be complete and consistent. |
| Deprecate | Minimal — proc checks the version is currently Published. | Deprecation rarely fails; the main check is state. |

The UI may also preflight-validate Publish (e.g., disable the Publish button until required fields are populated) for UX. The proc remains authoritative — the button being clickable is no guarantee the Publish will succeed.

### Refinement 3 — Optimistic locking via `RowVersion`

Every versioned-entity table carries a `RowVersion BIGINT` column (or SQL Server's `rowversion` type, projected to `BIGINT` for Ignition compatibility). Every Update proc:

1. Accepts `@RowVersion` as a parameter.
2. Compares it to the row's current `RowVersion` before applying changes.
3. On mismatch: returns `Status='ERROR', Message='This record was modified by another user. Please reload and try again.'` — surfaced to the operator via the standard `notifyResult` path.
4. On match: applies changes, increments `RowVersion`, returns `Status='OK'`.

Entity scripts pass `editDraft.RowVersion` (which was loaded with the row originally and never touched during the edit session) into the Update proc.

### Refinement 4 — `EffectiveFrom` constraint

Versioned entities carry both `PublishedAt` and `EffectiveFrom`:

| Column | Type | Meaning |
|---|---|---|
| `PublishedAt` | `DATETIME2(3)` | Timestamp when the user clicked Publish. Set by the Publish proc. |
| `EffectiveFrom` | `DATE` | Date the version becomes operationally active. Set by the user at Publish time. |

**Constraint:** `EffectiveFrom >= cast(getdate() as date)` at Publish time. Validated in the stored proc; the UI also blocks the Publish button when the picker date is in the past.

**UI default:** today's date. The user may move it forward.

A version may be **Published-but-not-yet-Effective** — i.e., scheduled. Plant-floor consumption queries must filter by both `PublishedAt IS NOT NULL`, `DeprecatedAt IS NULL`, and `EffectiveFrom <= today`, taking the highest `VersionNumber` that satisfies all three.

### Refinement 5 — Future-effective visual hint

Published rows where `EffectiveFrom > today` display a small badge in the list view next to the state indicator:

```
v4   Published    Effective 06/15
v3   Published    (current)
v2   Deprecated
```

Pure UI; no behavioral change. The badge is bound to:

```
if({row.EffectiveFrom} > today(), 'Effective ' + dateFormat({row.EffectiveFrom}, 'MM/dd'), '')
```

---

## Section 4 — Cross-Cutting Conventions

### Audit user attribution

Every mutation passes `@AppUserId` resolved from `session.custom.appUserId` (set at login by `Location.AppUser_GetByAdAccount`, per the existing UI Spec). Entity scripts inject this so views never have to remember:

```python
def _currentAppUserId():
    return system.perspective.getSessionInfo()['custom'].get('appUserId')
```

### Logging

Every public entity-script function calls `BlueRidge.Common.Util.log(msg)` at entry and at the return point. `log` lives in the shared `BlueRidge/Common/Util/code.py` module and uses `inspect.currentframe().f_back` to auto-fill the calling module and function name into the gateway log line — callers do not need a per-module wrapper.

```python
# In BlueRidge/Common/Util/code.py
import inspect
def log(msg):
    frame  = inspect.currentframe().f_back
    module = frame.f_globals.get('__name__', 'unknown')
    func   = frame.f_code.co_name
    system.util.getLogger(module).info("%s() %s" % (func, msg))

# In any entity script
def add(data):
    BlueRidge.Common.Util.log("data=%s" % data)
    # ...
    BlueRidge.Common.Util.log("resp=%s" % resp)
    return resp
```

Spinner uses a per-module `log(msg)` wrapper that delegates into the domain's Util module. **Don't carry that pattern into MPP** — direct calls to `BlueRidge.Common.Util.log` keep one source of truth.

### Page titles in `page-config`

Every entry in `page-config/config.json` SHALL include a `title` field. The browser tab is what an operator sees when they're juggling Configuration Tool windows alongside email, SAP, and the Honda EDI portal — meaningful titles are not optional.

```json
"pages": {
  "/config/items":   { "title": "Item Master",        "viewPath": "BlueRidge/Views/Parts/ItemMaster" },
  "/config/routes":  { "title": "Route Builder",      "viewPath": "BlueRidge/Views/Parts/RouteBuilder" },
  "/config/audit":   { "title": "Audit Log",          "viewPath": "BlueRidge/Views/Audit/AuditLog" }
}
```

Pages without a sensible static title (e.g., editors that change with selection) MAY override the title at runtime via `system.perspective.setSessionProps` or by binding `page.title`, but the static fallback in `page-config` MUST still be present.

### Component naming

Every container component (`ia.container.flex`, `ia.container.coord`, etc.) SHALL be given a `meta.name`. Every component with property bindings that may change (anything bound to `view.custom.*`, `session.custom.*`, a tag, or an expression) SHALL be named.

A component MAY remain unnamed only when it is unambiguously locatable from context — typically a single static label inside a single-row container with no bindings. Default Designer names like `Label_3` are not considered named.

```
Container_RouteSteps
  Label_StepCount        ← bound to {view.custom.editDraft.steps.length}; named
  FlexContainer_StepList
    FlexRepeater_Steps   ← bound to view.custom.editDraft.steps; named
```

Naming makes Designer scripting (`event.source.parent.getComponent('Label_StepCount')`) survivable, makes PR diffs readable, and makes tab-order intent explicit.

**Exception — the root container.** The top-level component of every view keeps its reserved `meta.name` of `"root"`. Do not rename it. Ignition's binding paths (`{view.custom.*}`, `{view.params.*}`) and the Designer's component tree both assume `root` is the top of the hierarchy.

### Style class references — no `psc-` prefix in `style.classes`

Perspective adds the `psc-` prefix automatically when rendering Style Classes from the Advanced Stylesheet. In `view.json`, reference the class by its **suffix only**:

```json
"style": { "classes": "surface-card" }       // CORRECT — renders as <div class="psc-surface-card">
"style": { "classes": "psc-surface-card" }   // WRONG — would render as <div class="psc-psc-surface-card">
```

This applies to all classes defined in `stylesheet.css` with the `.psc-*` naming convention. It does NOT apply to nested Style Class paths from the `style-classes/` folder (those are referenced by full path, e.g., `BlueRidge/Components/coreButtonRound`).

Multiple classes are space-separated:

```json
"style": { "classes": "badge badge-info" }   // both classes applied
```

### View-level custom properties as the default

Custom properties SHALL live on the view (`view.custom.*`) by default, not on individual components. Component-level custom props get orphaned when a component is renamed, deleted, or moved between containers; view-level props stay reachable from any descendant via the `view.custom.*` path.

The narrow exception: a property that is genuinely scoped to one component instance and should not be reachable elsewhere (e.g., a flex-repeater instance's `index`). When in doubt, put it on the view.

```
view.custom.selected         ← OK (view-level)
view.custom.editDraft        ← OK (view-level)
EditPanel.custom.dirty       ← AVOID (component-level on a panel that may move)
```

This is also why the editDraft/selected/dirty-indicator pattern in Section 2 lives at `view.custom.*` — anything below the view is fragile.

### Binding and script efficiency hierarchy

When a property needs to be computed or driven, prefer the cheapest mechanism that fits, in this order:

| Rank | Mechanism | When to use |
|---|---|---|
| **1 (fastest)** | **Expression binding** | Any computation expressible in Ignition's expression language. Conditionals, string formatting, arithmetic, dataset access, `runScript('Pkg.Mod.fn', 0, args)`. |
| **2** | **Project-script call** (binding transform `script` calling a one-liner into `BlueRidge.<...>`) | When the logic doesn't fit in an expression but is reusable. Project scripts are preloaded; the JVM doesn't recompile per call. |
| **3 (slowest)** | **Inline event/transform script** (Python pasted into `view.json`) | Last resort. Inline scripts are interpreted at action time, not preloaded. Cap at 3 logical lines; longer goes into a project script and is called as a one-liner. |

In practice this means:

- Bind a label's text to `if({view.custom.dirty}, '● Unsaved changes', '')` (expression, fastest), not a transform script doing the same.
- Wire a Save button's `onActionPerformed` to a one-line `BlueRidge.Parts.Part.handleSave(self.view.custom.editDraft)` call — *not* 8 inline lines of Python.
- Treat the rare ≤3-line inline script as an exception you'd justify in code review, not the default.

This hierarchy is the Blue Ridge Ignition standard ("almost all scripts should be called from project scripting libraries"), formalized for MPP.

### No drag-and-drop

Per CLAUDE.md project convention. Sortable lists use up / down arrow buttons, which manipulate `editDraft` ordering per Section 2.

### Single shared `BlueRidge.Common.Util`

One Util module — not the per-domain Util duplicates seen in the Spinner reference project. Common helpers (`extractQualifiedValues`, `convertWrapperObjectToJson`, `log`, `logging`) live in `BlueRidge/Common/Util/code.py` and are reused across all domains.

---

## Related Documents

| Document | Relevance |
|---|---|
| `MPP_MES_CONFIGURATION_UI_SPEC.md` | Screen-by-screen UI behavior. This doc supersedes Screen 9 (move-up / move-down arrows) and Screen 10 (auto-save eligibility cells). |
| `MPP_MES_PHASED_PLAN_CONFIG_TOOL.md` | Stored Procedure Template + Conventions section; this doc reuses the `@Status, @Message, @NewId` contract defined there. |
| `MPP_MES_DATA_MODEL.md` | `RowVersion`, `EffectiveFrom`, `PublishedAt`, `DeprecatedAt` column specifications. |
| `MPP_MES_FDS.md` § FDS-11 | JDBC compatibility constraints (no OUTPUT params, one result set per proc). |
| `CLAUDE.md` | Cross-project conventions (no drag-and-drop, no `Co-Authored-By: Claude` trailer, SQL design rules). |
