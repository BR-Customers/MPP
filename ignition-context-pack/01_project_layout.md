# Project filesystem layout (Ignition 8.3 file-based projects)

Ignition 8.3 stores projects as a tree of folders on disk — one folder per resource — so the layout is what you'll diff in git. This file describes the standard top-level structure, the per-resource metadata model, and the scope codes that govern where each resource runs.

## Top-level structure

```
<ProjectName>/
├─ project.json                              # title, description, parent (inheritance), enabled
├─ com.inductiveautomation.perspective/      # all UI resources
│  ├─ page-config/{config.json, resource.json}      # URL → viewPath router + sharedDocks
│  ├─ session-props/{props.json, resource.json}     # session.props.* + custom session state
│  ├─ session-permissions/{data.bin, resource.json}
│  ├─ style-classes/<group>/<name>/{style.json, resource.json}
│  ├─ stylesheet/{stylesheet.css, resource.json}    # raw CSS — animations / keyframes / overrides
│  └─ views/<path>/<viewName>/{view.json, resource.json, thumbnail.png}
├─ com.inductiveautomation.vision/           # legacy Vision; usually empty for new projects
└─ ignition/                                 # non-Perspective resources
   ├─ designer-properties/{data.bin, resource.json}
   ├─ global-props/{data.bin, resource.json}
   ├─ named-query/<group>/<name>/{query.sql, resource.json}
   ├─ script-python/<package>/<module>/{code.py, resource.json}
   ├─ startup/{onStartup.py, resource.json}
   ├─ shutdown/{onShutdown.py, resource.json}
   ├─ update/{onUpdate.py, resource.json}    # signature: onUpdate(actor, resources)
   └─ timer/<TimerName>/{handleTimerEvent.py, resource.json}
```

**Hard rule:** every resource is a *folder* containing a `resource.json` plus its content file(s). There are no loose files at any level — even single-file resources are wrapped in their own folder. If you see a folder with content files but no `resource.json`, the gateway scanner will not register it as a resource and the Designer will not show it.

## resource.json — metadata that lives beside every resource

Standard fields:

```json
{
  "scope": "G",                             // see "Scope codes" below
  "version": 1,
  "restricted": false,
  "overridable": true,                      // whether a child project may override this
  "files": ["view.json", "thumbnail.png"],  // content files this resource owns
  "attributes": {
    "lastModificationSignature": "<sha256>",
    "lastModification": {
      "actor": "<designer-username>",       // git-style audit trail
      "timestamp": "2026-03-17T14:11:41Z"
    }
    // ...resource-type-specific fields below
  }
}
```

`lastModificationSignature` is computed by the gateway/Designer from the content; you can leave it blank or omit it on hand-authored files and the gateway will recompute on the next save. Tools that author resources programmatically should write a sensible value or simply omit the field.

### Resource-type-specific `attributes` fields

| Resource type | Notable fields |
|---|---|
| Named query | `type: "Query" | "UpdateQuery"`, `parameters[]` (each `{type:"Parameter", identifier, sqlType:<int>}`), `cacheEnabled` / `cacheAmount` / `cacheUnit`, `database`, `fallbackEnabled` / `fallbackValue`, `maxReturnSize` / `useMaxReturnSize` / `autoBatchEnabled`, `enabled`, `permissions[]` |
| Timer | `delay` (ms), `fixedDelay` (bool), `sharedThread` (bool), `enabled` |
| Script-python module | `hintScope` (int — 2 = available everywhere) |
| View | minimal — just `lastModification` + signature |

## Scope codes

Resources tag their scope in `resource.json` and event configs tag scope inline:

| Code | Meaning | Used on |
|------|---------|---------|
| `G` | Gateway only | timer scripts, views, startup / shutdown / update |
| `A` | All — Gateway + Designer + Client | script-python modules |
| `DG` | Designer + Gateway | named queries |
| `C` | Client (browser session) only | inline event configs (`scope: "C"`) |

Inside a `view.json` event handler, `scope: "C"` runs in the browser session and `scope: "G"` runs on the gateway. Choose `C` for anything that needs immediate UI feedback (DOM events, navigation, dock toggling) and `G` for anything that needs server-side context (DB writes, gateway tag access, gateway-only APIs).

## project.json

```json
{
  "title": "MyProject",
  "description": "Short description shown in the Gateway projects page",
  "enabled": true,
  "inheritable": false,
  "parent": ""
}
```

`parent` enables project inheritance — a child project sees the parent's resources and may override any where `overridable: true`. Empty string means the project is standalone.

## Top-level component organization inside `views/`

A common convention is to wrap all of an integrator's project content under a single top-level folder named after the integrator package, then split into `Views/` (top-level pages addressable by `page-config`) and `Components/` (reusable view fragments embedded in pages).

```
views/
└─ <integrator>/                       # e.g., "BlueRidge", "Acme"
   ├─ Views/
   │  ├─ <Domain>/<Page>/              # top-level pages
   │  └─ Containers/<ShellView>/       # layout / shell views (Header, Sidebar, etc.)
   └─ Components/
      ├─ Utils/                        # generic cross-cutting utility views
      ├─ Navigation/                   # nav chrome (header, menu, breadcrumbs)
      ├─ <ReusableComponentName>/      # a reusable component embedded in pages
      └─ _<ReusableComponentName>/     # private internals of that component
```

The underscore-prefix convention means "internals of `<X>`" — *not* "things related to schema `<X>`". See `07_conventions_and_antipatterns.md` for the full naming rules.

## Empty folders + git

Git does not track empty folders. If you scaffold the structure ahead of populating it, drop a `.gitkeep` file in each empty leaf so the layout shows up in commits. Once a leaf has real content, the `.gitkeep` becomes optional and can be removed.
