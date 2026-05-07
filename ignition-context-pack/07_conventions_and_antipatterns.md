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

### Upsert procs (one proc handles INSERT and UPDATE)

`add<Entity>` is called by both `add()` and `update()` script functions, distinguishing between insert and update by whether the ID is null or not. Hides intent in the proc, complicates the SQL, makes the result-row contract ambiguous (do we have a `NewId` or not?).

**Better:** separate `Add<Entity>` and `Update<Entity>` procs / NQs. Each has a clear contract: Add returns `Status`+`Message`+`NewId`, Update returns `Status`+`Message`.

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
