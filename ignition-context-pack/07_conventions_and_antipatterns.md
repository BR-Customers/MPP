# Conventions and anti-patterns

Layout / naming rules to follow in every view, plus patterns to flag rather than silently propagate. Keep this file open alongside any view-authoring or script-writing task.

## View authoring conventions

### Root container keeps `meta.name: "root"`

The top-level component of every Perspective view has the reserved name `root`. Don't rename it — no `RootContainer`, `Root`, `MainContainer`, etc.

**Why:** Ignition's binding paths (`{view.custom.*}`, `{view.params.*}`) and the Designer's component tree both assume the top of the hierarchy is named `root`. Renaming breaks the implicit contract and makes the component tree harder to scan.

```json
"root": {
  "type": "ia.container.flex",
  "meta": { "name": "root" },         // never anything else
  ...
}
```

### Style classes — drop the `psc-` prefix in `style.classes`

Perspective automatically prepends `psc-` to whatever you put in `props.style.classes` when rendering. So in-view references use the **suffix only**.

**Correct:**
```json
"style": { "classes": "canvas" }              // renders <div class="psc-canvas">
"style": { "classes": "surface-card" }
"style": { "classes": "badge badge-info" }    // multi-class space-separated
```

**Wrong** (would render as `psc-psc-canvas`):
```json
"style": { "classes": "psc-canvas" }
```

The CSS file (`stylesheet/stylesheet.css`) defines classes with `.psc-*` names because that's what Perspective will emit at render time. Inside `view.json` you reference them without the prefix because Perspective adds it.

This rule applies to project-defined classes from the Advanced Stylesheet. It does NOT apply to nested Style Class objects from `style-classes/<group>/<name>/style.json` — those are referenced by their full Designer path, e.g., `<integrator>/Components/coreButtonRound`.

### Use `position.display` for conditional flex visibility, not `meta.visible`

In Perspective, the two ways to conditionally hide a component look interchangeable but have different layout consequences:

| Approach | Behavior | Layout impact |
|---|---|---|
| `meta.visible: false` | element rendered with `visibility: hidden` | **still takes space**; siblings still see it as a flex/grid item |
| `position.display: false` | element treated as `display: none` | **removed from layout entirely**; siblings reflow as if it isn't there |

For conditional flex children — for example, sibling category panels where exactly one of N should be visible at a time — bind `position.display` to the visibility expression:

```json
{
  "type": "ia.container.flex",
  "meta": { "name": "PartsCategory" },
  "position": { "basis": "auto" },
  "propConfig": {
    "position.display": {
      "binding": {
        "type": "expr",
        "config": { "expression": "{session.custom.activeCategory} = 'parts'" }
      }
    }
  },
  ...
}
```

When the expression returns `false`, the container is gone from the flex layout. Other siblings (whose expressions return `true`) lay out normally — no leftover gaps from the hidden ones.

**Default rule:** prefer `position.display` for any binding-driven visibility on a flex child. Reserve `meta.visible` for "in DOM but visually hidden" cases (rare).

### Component naming

Every container component (`ia.container.flex`, `ia.container.coord`, …) **shall** be given a meaningful `meta.name`. Every component with property bindings that may change (anything bound to `view.custom.*`, `session.custom.*`, a tag, or an expression) **shall** be named.

A component MAY remain unnamed only when it is unambiguously locatable from context — typically a single static label inside a single-row container with no bindings. Default Designer names like `Label_3` are not considered named.

```
Container_RouteSteps                            (named — container)
  Label_StepCount        (bound to {view.custom.editDraft.steps.length} — named)
  FlexContainer_StepList (named — container)
    FlexRepeater_Steps   (bound to view.custom.editDraft.steps — named)
```

Naming makes Designer scripting (`event.source.parent.getComponent('Label_StepCount')`) survivable, makes PR diffs readable, and makes tab-order intent explicit.

### View-level custom properties as the default

Custom properties live on the **view** (`view.custom.*`) by default, not on individual components. Component-level custom props get orphaned when a component is renamed, deleted, or moved between containers; view-level props stay reachable from any descendant via the `view.custom.*` path.

Narrow exception: a property genuinely scoped to one component instance and not reachable elsewhere (e.g., a flex-repeater instance's `index`). When in doubt, put it on the view.

### Page titles in `page-config`

Every entry in `page-config/config.json` should include a `title` field. The browser tab is what users see when juggling multiple windows — meaningful titles are not optional.

```json
"pages": {
  "/items":  { "title": "Item Master",  "viewPath": "<integrator>/Views/Parts/ItemMaster" },
  "/audit":  { "title": "Audit Log",    "viewPath": "<integrator>/Views/Audit/AuditLog" }
}
```

Pages where the title varies with selection (e.g., editors that show the current entity's name) MAY override `page.title` at runtime via session script, but the static fallback in `page-config` should still be present.

### No drag-and-drop

Sortable lists use up / down arrow buttons, not HTML5 drag-and-drop. Touch screens on the plant floor handle taps reliably and drags poorly; the same UI works in both keyboard-driven and touch-driven contexts; it is also far easier to test deterministically.

Arrow clicks mutate `editDraft.<list>` ordering locally; Save commits the new order (see "Save semantics" below).

## Save semantics — `editDraft` with an explicit Save button

The DB is touched only when the user explicitly clicks **Save**. Form inputs mutate a local `editDraft` object — never the source-of-truth `selected` or the DB.

### The pattern

Every editing surface (Add modal, Edit modal, in-place editor pane) maintains two view-level custom properties:

```json
"custom": {
  "selected":  {},   // the currently selected entity, as last loaded from DB
  "editDraft": {}    // in-flight edits; form components bind bidirectionally to this
}
```

When the user selects a row:

```python
self.view.custom.selected  = selected_row
self.view.custom.editDraft = dict(selected_row)   # shallow copy
```

Form components (text fields, dropdowns, checkboxes) bind bidirectionally to `editDraft.<field>` paths (see `02_perspective_views.md` → "Bidirectional binding"). **Edits to `editDraft` do not write to the DB.**

Save:

```python
result = <integrator>.<Domain>.<Entity>.update(self.view.custom.editDraft)
<integrator>.Common.Ui.notifyResult(result, successTitle="Saved")
if result.get("Status"):
    self.view.custom.selected = dict(self.view.custom.editDraft)
    system.perspective.sendMessage("refreshTrigger")
```

Cancel:

```python
self.view.custom.editDraft = dict(self.view.custom.selected)
```

### Universal rules

1. **Zero auto-save.** No bound checkbox, dropdown, arrow click, or toggle writes to the DB on its own. Every database write is the result of an explicit click on a Save (or Save-equivalent: Publish, Deprecate) button.
2. **No navigation guard.** Switching to a different entity (clicking another row) silently replaces `editDraft` with the new entity's data. The dirty indicator is the warning — modal interrupts disrupt workflow more than they help.
3. **Multi-tab forms share one `editDraft`.** Editors with multiple tabs (e.g., Item Master with several tabs per item) keep one `editDraft` across tabs. Tab switches do not commit. Save persists changes from every tab together. Switching to a different *entity* discards all of it.
4. **Up / Down arrows mutate `editDraft` ordering only.** Reordering a list (e.g., Route steps) updates `editDraft.steps[]` order locally; Save commits the new order. There is no `_MoveUp` / `_MoveDown` proc called per click.
5. **Toggle controls (`IsActive`, etc.) do not auto-save.** They flip a property on `editDraft`; Save commits.

### Dirty indicator

Whenever `editDraft != selected`, display a visual cue — no popup, no nav block, no DB call:

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

## Mutation feedback — route every result through `notifyResult`

Every mutation in the UI ends with one call to `<integrator>.Common.Ui.notifyResult(result, successTitle, successMsg=None, errorTitle=None)`. The helper inspects `result["Status"]` (truthy = success, falsy = business-rule failure) and fires a toast via `<integrator>.Common.Notify.toast` — success toast with `successTitle`/`successMsg` on success, error toast carrying the proc's `Message` on failure.

Wire this into the Save event after the mutation call:

```python
result = <integrator>.Items.Item.update(self.view.custom.editDraft)
<integrator>.Common.Ui.notifyResult(result, successTitle="Saved")
if result.get("Status"):
    ...
```

The toast surface (popup-per-toast, top-right FIFO max 5, errors persist, non-errors auto-dismiss) is documented in `03_script_python.md` → "Common.Notify". Payload contract: `{title, message, level, ttl}` where `level` is one of `success` / `info` / `warning` / `error`.

**Don't reimplement notification logic per screen.** A button that calls `notifyResult` should never also do `system.perspective.sendMessage(...)` for the same outcome — that's a sign someone bypassed the helper. Fix the bypass; don't double-route.

## Mode discriminator on shared add/edit popups

When the same popup view serves both Add and Edit modes (one editor, two entry points), an **explicit `view.custom.mode` prop** reads more clearly than `editDraft.Id == null` checks scattered through bindings:

```
view.custom.mode: "view" | "create" | "update"
```

- `"view"` — no entity selected; details panel hidden
- `"create"` — new entity being authored; `selected.meta` is `None`, `editDraft.meta.Id` is `None`, Deprecate button hidden
- `"update"` — existing entity being edited; `selected.meta` populated, `editDraft.meta.Id` set, Deprecate button visible

Bindings that depend on the mode reference `view.custom.mode` directly:

```json
"position.display": {
  "binding": {
    "type": "expr",
    "config": { "expression": "{view.custom.mode} = \"update\"" }
  }
}
```

The discriminator is set explicitly in the click handlers that transition between modes (selecting a definition → `mode = "update"`; clicking +Add → `mode = "create"`; deprecating → `mode = "view"`). `editDraft.Id == null` is still the underlying truth, but the named mode prop is what bindings and operators see.

This is OPTIONAL. For editors that only ever serve one purpose (always Edit, or always Add), an explicit mode prop is overhead. Reach for it when the same view does both.

## Versioned-entity workflow — Draft / Published / Deprecated

For configuration entities that need version history (e.g., recipes, route templates, BOMs, quality specs), use a three-state lifecycle on the row itself rather than a parallel "drafts" table.

### State machine

| State | DB shape | Buttons shown |
|---|---|---|
| **Draft** | `PublishedAt IS NULL AND DeprecatedAt IS NULL` | Discard, Save, Publish |
| **Published** | `PublishedAt IS NOT NULL AND DeprecatedAt IS NULL` | Edit, Deprecate |
| **Deprecated** | `DeprecatedAt IS NOT NULL` | (view only) |

Transitions:

- **Editing a Published version** creates a new Draft row with `VersionNumber + 1` (procedure: `<Entity>_CreateNewVersion`).
- **Saving a Draft** mutates the Draft row in place — no new row per Save.
- **Publishing a Draft** sets its `PublishedAt = getdate()` and stamps `DeprecatedAt = getdate()` on the previous Published version.
- **Discarding a Draft** hard-deletes that row (the only legitimate `DELETE`).
- **Published → Deprecated** is the only forward path from Published other than Edit.
- A Published version cannot be un-Published; correct mistakes by Editing (creates a new Draft) or Deprecating.

### Edit-when-Draft-already-exists

If a user clicks **Edit** on a Published version and a Draft for the same logical entity already exists (created by them or someone else), present a dialog before opening the editor:

```
A draft already exists for this Route

Draft v4 — last edited 2 days ago by Jen Lewis

○ Continue editing existing Draft
○ Start fresh from current Published
  (Draft v4 will be discarded)

                              [Cancel] [Continue]
```

Default selection: "Continue editing existing Draft." If "Start fresh" is chosen, the existing Draft is discarded (hard-deleted) before the new Draft row is created from the Published version.

The check happens in the entity script's `getCurrentDraft(logicalId)` call before opening the editor. The dialog appears only if a Draft is found.

### Validation timing

| Action | Validation level | Rationale |
|---|---|---|
| Save (on Draft) | None at proc level. UI may flag missing-required-fields visually. | Drafts may be incomplete — saving partial work is the whole point. |
| Publish | Full validation in the proc. Returns `Status=0` with a specific `Message` if any rule fails. | Publishing means "this version goes live" — must be complete. |
| Deprecate | Minimal — proc checks current state is Published. | Deprecation rarely fails; the main check is state. |

The UI may preflight-validate Publish (e.g., disable the Publish button until required fields are populated) for UX. The proc remains authoritative — a clickable button is not a guarantee the Publish will succeed.

### Optimistic locking via `RowVersion`

Every versioned-entity table carries a `RowVersion BIGINT` column (or SQL Server's native `rowversion`, projected to `BIGINT` for JDBC). Every Update proc:

1. Accepts `@RowVersion` as a parameter.
2. Compares it to the row's current `RowVersion` before applying changes.
3. On mismatch: returns `Status=0, Message='This record was modified by another user. Please reload and try again.'` — surfaced via the standard `notifyResult` path.
4. On match: applies changes, increments `RowVersion`, returns `Status=1`.

Views load `RowVersion` with the row, never touch it during editing, and pass it through on save. `editDraft.RowVersion` is the same value as `selected.RowVersion`.

### `EffectiveFrom` (scheduled-publish) constraint

When a versioned entity needs to be published *in advance* of going live, add an `EffectiveFrom DATE` column distinct from `PublishedAt DATETIME2(3)`:

| Column | Type | Meaning |
|---|---|---|
| `PublishedAt` | `DATETIME2(3)` | When the user clicked Publish. Set by the Publish proc. |
| `EffectiveFrom` | `DATE` | When the version becomes operationally active. User-chosen at Publish time. |

Constraint: `EffectiveFrom >= cast(getdate() as date)` at Publish time. Validated in the proc; the UI also disables the Publish button when the picker date is in the past. UI default: today's date.

Plant-floor consumption queries filter by `PublishedAt IS NOT NULL AND DeprecatedAt IS NULL AND EffectiveFrom <= today`, taking the highest `VersionNumber` that satisfies all three.

**Future-effective badge** — Published rows where `EffectiveFrom > today` show a small badge in the list view:

```
v4   Published    Effective 06/15
v3   Published    (current)
v2   Deprecated
```

Bound via expression:

```
if({row.EffectiveFrom} > today(), 'Effective ' + dateFormat({row.EffectiveFrom}, 'MM/dd'), '')
```

## Audit user attribution — `session.custom.appUserId`

At login, resolve the operator's identity (typically from an AD lookup or initials-based attribution) into an internal `AppUserId` and store it on the session:

```python
# In a login flow:
self.session.custom.appUserId = <integrator>.Common.User.resolveByAd(self.session.props.auth.user.userName)
```

Every mutation passes this to the proc as `@AppUserId`. Entity scripts inject it via `<integrator>.Common.Util._currentAppUserId()` so views never have to remember.

Why a resolved internal id (not the AD username): the database uses `BIGINT FK → AppUser.Id` for all author columns. Resolving once at login amortizes the AD lookup and gives the rest of the application a stable, type-safe identifier.

## Folder naming conventions

### Underscore-prefix component folders are per-component, not per-domain

Inside `views/<integrator>/Components/`, the convention is:

- `Components/<ComponentName>/` — a reusable component view (top-level, embedded directly into other views)
- `Components/_<ComponentName>/` — internal sub-views that build up that *specific* reusable component (only created when that component has internals worth grouping)
- `Components/Utils/` — generic cross-cutting utility views (loaders, banners, dividers, tiny shared bits)
- `Components/Navigation/` — nav chrome (header, menu, breadcrumbs)

So `_Metrics` exists *because* `Metrics` is a reusable component with multiple internal pieces — not because "Metrics" is a domain or schema. There would be no `_Parts`, `_Location`, `_Quality` etc. folders unless you'd built reusable components literally named `Parts`, `Location`, `Quality`.

**When scaffolding:** create only `Components/Utils/` and `Components/Navigation/`. Add other `Components/<Name>/` folders one at a time as a real reusable component is identified. Create `_<Name>/` only after the parent reusable `<Name>/` exists and is complex enough to need internal grouping.

For `script-python` and `named-query` trees, schema-aligned domain folders ARE correct (`script-python/<integrator>/<DomainA>/`, `named-query/<schemaA>/`) — that convention is different from the Components folder.

### `Views/Containers/` for layout / shell views

`Views/Containers/` holds layout / shell views: `Header`, `Sidebar`, `Footer`, `Main`, `ConfigShell` — anything that wraps page content. Domain folders (`Views/Items/`, `Views/Audit/`, etc.) hold the actual page views.

## Efficiency hierarchy — expression > project script > inline

When a property needs to be computed or driven, prefer the cheapest mechanism:

| Rank | Mechanism | When to use |
|---|---|---|
| **1 (fastest)** | Expression binding | Any computation expressible in Ignition's expression language. Conditionals, string formatting, arithmetic, dataset access, `runScript('Pkg.Mod.fn', 0, args)`. |
| **2** | Project-script call (binding transform `script` calling a one-liner into a project script) | When the logic doesn't fit in an expression but is reusable. Project scripts are preloaded; the JVM doesn't recompile per call. |
| **3 (slowest)** | Inline event/transform script (Python pasted into `view.json`) | Last resort. Inline scripts are interpreted at action time, not preloaded. Cap at 3 logical lines; longer goes into a project script and is called as a one-liner. |

In practice:

- Bind a label's text to `if({view.custom.dirty}, '● Unsaved changes', '')` (expression — fastest), not a transform script doing the same.
- Wire a Save button's `onActionPerformed` to a one-line `<integrator>.<Domain>.<Entity>.handleSave(self.view.custom.editDraft)` call — *not* 8 inline lines of Python.
- Treat the rare ≤3-line inline script as an exception you'd justify in code review, not the default.

## Anti-patterns to flag (don't silently propagate)

When you encounter these in existing code, raise them rather than copying or unilaterally rewriting. Discuss the better solution with the project owner — they may have context you don't.

### `eval()` of dynamic script paths

Generic Add / Archive / Save buttons that take a script-path string parameter and `eval` it:

```python
script = self.view.params.script.replace('/', '.')   # "<integrator>/<Domain>/<Entity>" → "<integrator>.<Domain>.<Entity>"
eval(script + ".add('{0}')".format(uuid))
```

Brittle, security-smell, breaks IDE refactoring, untyped, kills any "find usages" search. **Better:** explicit handler functions, or a message-based dispatch where the button publishes `system.perspective.sendMessage("save", payload)` and the view that owns the data subscribes.

### Upsert procs (one proc handles INSERT and UPDATE of the *same* entity)

`add<Entity>` is called by both `add()` and `update()` script functions, distinguishing between insert and update on a stand-alone entity by whether the ID is null. Hides intent in the proc, complicates the SQL, makes the result-row contract ambiguous (do we have a `NewId` or not?), and forces every caller to know it's calling an upsert.

**Better:** separate `Add<Entity>` and `Update<Entity>` procs / NQs. Each has a clear contract: Add returns `Status`+`Message`+`NewId`, Update returns `Status`+`Message`.

**Not the same thing — `SaveAll` for parent + dependent children.** A `SaveAll<Parent>` proc that takes parent fields plus a JSON array of children and reconciles them in one transaction (insert-on-null-id / update-on-match / deprecate-on-absent) is a different pattern and is *not* an upsert anti-pattern. The distinction:

- **Upsert:** one proc handles "insert OR update *one entity*" — the caller pretends it doesn't know which. Hides intent. Avoid.
- **SaveAll:** one proc handles "save *this parent with these children* atomically" — the caller knows it's editing the whole bundle. Explicit. Use it when children are tightly coupled to the parent and never edited in isolation.

See `04_named_queries.md` → "Bundled mutations — `SaveAll` for parent + dependent children" for the full pattern.

### Multi-line Python pasted into `view.json` event configs

Acceptable for 1–3 lines. Past that, factor into `script-python/<integrator>/<Domain>/<Entity>/code.py` and call as a one-liner from the event:

```json
"events": {
  "component": {
    "onActionPerformed": {
      "type": "script", "scope": "C",
      "config": { "script": "<integrator>.<Domain>.<Entity>.handleSave(self.view.custom.editDraft)" }
    }
  }
}
```

Keeps views diffable in PR review, keeps logic unit-testable from non-UI surfaces, lets IDE search find it.

### Per-tag Tag Change Scripts for application logic

Older projects sometimes attach Python scripts directly to individual tags. Problems:

- **Thread pool exhaustion** — every tag with a script consumes from the shared pool; a slow script blocks others
- **Scripts scattered across the tag tree** — hard to discover, hard to test, hard to refactor
- **Memory leaks** observed in production with long-running gateways

**Better:** Project Tag Change Scripts (gateway-event level) that call a project script as a one-liner.

### View custom props on individual components

`SomeComponent.custom.dirty = true` instead of `view.custom.dirty = true`. The component-level prop becomes orphaned the moment the component is renamed, moved, or replaced. Stick to view-level customs unless you have a specific reason to scope to a component instance.

### Mixing direct `system.db.*` calls with entity-script abstractions

Some views call `system.db.execQuery(...)` directly from a binding transform. Some entity scripts call `system.db.execQuery(...)` directly. Some entity scripts call into a `Common.Db.execList(...)` helper. The mix means there's no single place to add cross-cutting concerns (logging, audit user injection, retry on transient failures).

**Better:** enforce the three-layer rule (View → Entity script → Common helpers). Only `Common.Db.*` calls `system.db.*`. Every other layer goes through it.

## Phrasing the flag

When you spot one of these and want to raise it rather than fix unilaterally:

> "I noticed [pattern] in [location]. My concern is [why it's risky / brittle / hard to maintain]. Possible alternatives are [option A], [option B]. What do you want to do?"

Not:

> "I fixed [pattern]."

The first lets the project owner decide; the second presumes they would have made the same call.
