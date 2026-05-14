# Perspective view structure (`view.json`)

How a Perspective view is laid out on disk: top-level keys, the recursive component tree, bindings, events, and the page-config router.

## view.json top-level keys

Every view file has the same shape:

```json
{
  "custom":     { ... },   // view-scoped mutable state
  "params":     { ... },   // input/output params (declared in propConfig)
  "propConfig": { ... },   // bindings on any addressable property
  "props":      { ... },   // static prop defaults (defaultSize, etc.)
  "permissions":{ ... },   // optional: required role tree (per-view auth gate)
  "root":       { ... }    // recursive component tree
}
```

## `propConfig` — bindings on properties

Any property in `custom`, `params`, `props`, or any nested component can be bound. Path-keyed:

```json
"propConfig": {
  "custom.selectedRow": {
    "binding": {
      "type": "property",
      "config": { "path": "view.custom.someInput" },
      "transforms": [
        { "type": "expression", "expression": "if({value}=null, 0, {value})" },
        { "type": "script",     "code": "\treturn value * 2" }
      ]
    },
    "persistent": true,
    "onChange": { "enabled": false, "script": "..." }
  },
  "params.itemId": { "paramDirection": "input", "persistent": true }
}
```

**Binding `type` values:**

| Type | Source |
|---|---|
| `property` | path to another prop (`view.custom.X`, `session.props.Y`, `page.props.Z`, `this.props.W`) |
| `expr` | live Ignition expression-language expression |
| `tag` | tag value subscription |
| `query` | named-query result |
| `udt` | UDT instance binding |

`transforms[]` runs in order — `expression` for one-liners in Ignition expression syntax, `script` for multi-step Python.

`paramDirection: "input" | "output"` declares param flow direction for embedded views.

`persistent: true` means the value survives view-instance state changes.

## `permissions` — per-view auth gate

```json
"permissions": {
  "type": "AnyOf",
  "securityLevels": [
    { "name": "Authenticated", "children": [
      { "name": "Roles", "children": [
        { "name": "Administrator", "children": [] },
        { "name": "Operator",      "children": [] }
      ]}
    ]}
  ]
}
```

Whole view is gated by this tree. Component-level enable/disable is done via expression bindings (see "Auth gate idiom" below).

## `root` — component tree

Each node:

```json
{
  "type": "ia.container.flex",
  "meta": { "name": "ListContainer", "tabIndex": 1, "tooltip": { "text": "..." } },
  "position": { "basis": "50px", "grow": 1, "shrink": 0 },
  "props": { "direction": "column", "style": { "classes": "list-frame" } },
  "events": { "component": {...}, "dom": {...} },
  "propConfig": { ... },
  "children": [ ... ]
}
```

**Common `type` values:**

| Category | Type | Notes |
|---|---|---|
| Container | `ia.container.flex` | Flex layout (most common). `direction`, `justify`, `alignItems`, `wrap`. |
| Container | `ia.container.coord` | Absolute / coord positioning. Predictable but doesn't reflow. |
| Display | `ia.display.label` | Text. |
| Display | `ia.display.icon` | Material / vendor icon. `props.path` like `material/inventory`. |
| Display | `ia.display.image` | Static image. |
| Display | `ia.display.flex-repeater` | Repeats a sub-view per instance. `props.path`, `props.instances[]`. |
| Display | `ia.display.table` | Virtualized data table. Renders div-based DOM, not native `<table>`. See `06_component_quirks.md`. |
| Display | `ia.display.view` | Embeds another view. Sizing can be tricky inside flex parents. |
| Input | `ia.input.button` | Standard button. `onActionPerformed` is the click event. |
| Input | `ia.input.dropdown` | Dropdown. `props.options` is `[{label, value}]`. |
| Input | `ia.input.text-field` | Text input. `props.text` (bidirectional-bindable). |
| Input | `ia.input.date-time-input` | Date/time picker. **Format uses Moment.js tokens**, value is a numeric ms-timestamp. See `06_component_quirks.md`. |
| Navigation | `ia.navigation.menutree` | Hierarchical menu — used for left-rail or settings. |

`position` uses flex-style sizing (`basis`, `grow`, `shrink`) when the parent is `ia.container.flex`. For absolute positioning inside `ia.container.coord`, `position` takes `{ x, y, width, height, anchor }`.

## Events on components

`events` has two channels:

- `events.component` — component-emitted events (`onActionPerformed`, `onSelectionChange`, `onValueChange`, …)
- `events.dom` — raw DOM events (`onClick`, `onBlur`, `onMouseEnter`, …)

Each event's value is either a single config object or an **array** of configs run in sequence:

```json
"events": {
  "dom": {
    "onClick": [
      { "type": "script", "scope": "C", "config": { "script": "self.session.custom.x = 1" } },
      { "type": "nav",    "scope": "C", "config": { "page": "/dashboard" } }
    ]
  }
}
```

**Event type configs:**

| Type | Config fields |
|---|---|
| `nav` | `{ "page": "/path" }` — page navigation |
| `popup` | `{ "type": "open"|"close", "id": "...", "viewPath": "...", "viewParams": {...}, "draggable": true, "modal": false, "showCloseIcon": true, "resizable": true, "overlayDismiss": false, "viewportBound": false, "title": "..." }` |
| `dock` | `{ "type": "toggle"|"open"|"close", "id": "leftDock" }` |
| `script` | `{ "script": "<python>" }` |

For `script`-type events, `self` refers to the component the event is on. `self.session`, `self.view`, `self.page` are all reachable. Long event scripts are an anti-pattern; factor anything past 1–3 lines into a project script (see `07_conventions_and_antipatterns.md`).

## Style classes vs raw CSS

Two layers, used together:

**Style classes** at `style-classes/<group>/<name>/style.json`:

```json
{ "base": { "style": { "backgroundColor": "#00D9D9", "borderRadius": "10px" } } }
```

Add states (`hover`, `pressed`, etc.) as siblings of `base` when needed. Reference from a component as:

```json
"style": { "classes": "<integrator>/Components/coreButtonRound" }
```

This style-class system is the Designer-native way to define reusable visual states.

**Advanced Stylesheet** (`stylesheet/stylesheet.css`): raw CSS for things style-classes can't express — keyframes, transitions, pseudo-classes, overrides on Ignition's internal `.ia_*` component classes. Class names you define here using the `.psc-*` prefix are referenced from `style.classes` by their **suffix only** (Perspective auto-prefixes `psc-` at render time). See `07_conventions_and_antipatterns.md`.

## page-config — URL → viewPath router

`com.inductiveautomation.perspective/page-config/config.json`:

```json
{
  "pages": {
    "/":           { "title": "Home",        "viewPath": "<integrator>/Views/Home/Landing" },
    "/items":      { "title": "Item Master", "viewPath": "<integrator>/Views/Parts/ItemMaster" },
    "/items/edit": {
      "viewPath": "<integrator>/Views/Parts/ItemEditor",
      "docks": { "right": [
        { "id": "actions", "viewPath": "<integrator>/Views/Containers/Actions",
          "show": "onDemand", "anchor": "fixed", "size": 250, "content": "push",
          "modal": false, "resizable": false, "handle": "hide", "iconUrl": "",
          "viewParams": {}, "autoBreakpoint": 480 }
      ]}
    }
  },
  "sharedDocks": {
    "cornerPriority": "top-bottom",
    "top":  [{ "id": "header",  "viewPath": "<integrator>/Views/Containers/Header", "size": 42,  "show": "visible", ... }],
    "left": [{ "id": "sidebar", "viewPath": "<integrator>/Views/Containers/Sidebar","size": 260, "show": "visible", ... }]
  }
}
```

Per-page `docks` add to or override `sharedDocks` for that URL only.

`show` values:
- `"visible"` — always shown
- `"onDemand"` — hidden by default, opened/closed via `system.perspective.openDock()` / `closeDock()`
- `"hidden"` — registered but not currently shown

`content` values:
- `"push"` — dock pushes content area aside when shown
- `"cover"` — dock overlays the content area

Every page entry should have a `title` — it's the browser-tab text and is what operators see when they're juggling Configuration windows.

## session-props

`com.inductiveautomation.perspective/session-props/props.json` carries:

- `props` — Ignition-defined session props (`locale`, `timeZoneId`, `address`, `appBar.togglePosition`, …)
- `propConfig` — binding / persistence flags on each session prop
- `custom` — app-defined session-scope state (cleared on logout per `propConfig` settings)

Cross-page state (e.g., currently-active category, current user's preferred theme) goes in `session.custom.*`. View-scoped state goes in `view.custom.*`.

Writing to session custom from scripts: `system.perspective.setSessionProps({'custom.activeCategory': 'system'})` is more reliable cross-component than direct `session.custom.activeCategory = 'system'` mutation, especially when called from a project-script frame rather than a component event.

## Auth gate idiom (component-level)

Per-view `permissions.securityLevels` covers the whole view. For per-button or per-section auth, bind on the component:

```json
"propConfig": {
  "props.enabled": {
    "binding": { "type": "expr",
      "config": { "expression": "isAuthorized(false, \"Authenticated/Roles/Administrator\")" } }
  },
  "meta.tooltip.enabled": {
    "binding": { "type": "expr",
      "config": { "expression": "!isAuthorized(false, \"Authenticated/Roles/Administrator\")" } }
  }
}
```

Tooltip's enable bound to the negation, so the disabled button shows "You don't have permissions" on hover.

## Bidirectional binding — for `editDraft` form fields, not auto-save

Bidirectional bindings let a form input (text field, dropdown, checkbox) write back into a custom property as the user types. Use this on `editDraft.*` fields so the form mutates draft state without touching the DB:

```json
// Text-field component bound bidirectionally to the draft's Description
"propConfig": {
  "props.text": {
    "binding": {
      "type": "property",
      "config": { "bidirectional": true, "path": "view.custom.editDraft.Description" }
    }
  }
}
```

Every form field on the editor binds bidirectionally into `view.custom.editDraft`. The DB is touched only when the user clicks Save — never on each keystroke or dropdown change.

**Anti-pattern — auto-save on writeback:**

```json
// DON'T do this — turns every keystroke into a DB write
"onChange": {
  "script": "if origin == 'BindingWriteback':\n    project.MyDomain.MyEntity.update(self.custom.editDraft)"
}
```

Calling `.update(...)` from an `onChange` handler is a misuse of `BindingWriteback` — it conflates "the user typed something" with "the user wants to commit." Use an explicit Save button instead (see `07_conventions_and_antipatterns.md` → "Save semantics"). The `origin == 'BindingWriteback'` guard is still useful for genuinely reactive UI work (e.g., recomputing a derived field locally when a source field changes) — just not for triggering DB writes.

## Inter-component messaging

`system.perspective.sendMessage("refreshTrigger")` (no payload) and `system.perspective.sendMessage("refreshTrigger", {'view': 0})` (payload). Receivers configure named message handlers in their view to react. Used for "refresh the list after CRUD" and other cross-component coordination without prop-path coupling.

## Conditional visibility on flex children

For binding-driven visibility on a child of a flex container, bind `position.display` (sets `display: none` — element removed from layout entirely) rather than `meta.visible` (sets `visibility: hidden` — element still occupies layout space). See `07_conventions_and_antipatterns.md` for the full rule.
