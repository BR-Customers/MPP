# Custom Perspective icon libraries (Ignition 8.3)

How to ship a project's own SVG icons addressable from any Icon component as `<library>/<icon>`. The setup is fiddly — the rules below were derived empirically through DevTools inspection and trial-and-error on a running 8.3 gateway, not from the official documentation. Several of them are not documented at all (negative-origin viewBox not rendering, fill-attribute-overrides-Perspective's-color-hook).

## Filesystem layout (8.3 — different from 8.1)

```
<install>/data/config/resources/core/com.inductiveautomation.perspective/icons/
└── <library-name>/                     ← folder name MUST equal the library reference name
    ├── <library-name>.svg              ← the SVG sprite
    ├── config.json                     ← { "svgFileName": "<library-name>.svg" }
    └── resource.json                   ← gateway-scope manifest
```

The folder name (`<library-name>`) is what views reference as the path prefix: an Icon component with `props.path = "<library-name>/foo"` resolves to `<svg id="foo">` inside the sprite. Folder name and library reference name are the same string.

**Pre-8.3 path was different:** Ignition 8.1 used a single `<library>.svg` at `data/modules/com.inductiveautomation.perspective/icons/`, with no `config.json` or `resource.json`. That layout does NOT work on 8.3.

### config.json

```json
{
    "svgFileName": "<library-name>.svg"
}
```

The indirection allows the SVG file to have any name; common practice is to make it match the library name.

### resource.json

```json
{
    "scope": "A",
    "version": 1,
    "restricted": false,
    "overridable": true,
    "files": [
        "config.json",
        "<library-name>.svg"
    ],
    "attributes": {
    }
}
```

`scope: "A"` (All) makes the library available across gateway / Designer / client. `files[]` enumerates the resource's content files — the library folder's `.svg` and `.json` siblings.

## SVG sprite format

The sprite is one outer `<svg>` containing many wrapped inner `<svg>` elements, each with a unique `id`. The inner element's `id` is what's referenced as `<library>/<id>` from views.

```xml
<?xml version="1.0" encoding="utf-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">

    <svg viewBox="0 0 24 24" id="my-icon">
        <path d="..."/>
    </svg>

    <svg viewBox="0 0 24 24" id="another-icon">
        <path d="..."/>
    </svg>

</svg>
```

This is IA's documented format. The `id` may alternatively be placed on a `<g>` inside an unnamed inner `<svg>` (also documented), but `id` directly on the inner `<svg>` is the simplest and most common.

## ViewBox: use a positive-origin grid (`0 0 24 24` is canonical)

Two empirically-validated rules:

1. **Negative-origin viewBox does NOT render in 8.3 Perspective.** A viewBox like `0 -960 960 960` (the native font-glyph grid for Material Symbols static SVGs) is rejected — Perspective renders nothing visible even though the underlying SVG is well-formed and the path data is correct. Always remap to a positive-origin viewBox.

2. **`0 0 24 24` is the IA-canonical grid.** It matches IA's documented examples and aligns with the legacy Material Icons grid that Perspective's built-in icon library uses. ViewBox `0 0 48 48` also works but `24` is preferred for cross-icon-library consistency.

If your source path data is in a different coordinate system (such as Material Symbols' `0 -960 960 960` font grid), remap via a path `transform`:

```xml
<svg viewBox="0 0 24 24" id="my-icon">
    <path transform="translate(0 24) scale(0.025)" d="<original-path-data>"/>
</svg>
```

For source viewBox `0 -960 960 960` → target `0 0 24 24`, the transform `translate(0 24) scale(0.025)` maps every source point `(x, y)` to `(x*0.025, y*0.025 + 24)`, which puts the path inside the visible 0–24 area without flipping the Y axis (both viewBoxes have Y pointing down).

For source viewBox `0 0 48 48` → target `0 0 24 24`, use `transform="scale(0.5)"`.

## Recoloring: NO fill attribute on the path

Perspective wraps every rendered icon in an outer `<svg>` with inline `style="fill: currentcolor"`. That outer-SVG fill cascades down to child paths **only when the path doesn't have its own fill attribute**.

The verified DOM shape Perspective generates around a custom icon:

```html
<svg viewBox="0 0 24 24" data-icon="<library>/<id>" style="fill: currentcolor; flex: 0 1 30px;">
    <g><g>
        <!-- contents of the inner <svg id="..."> from your sprite, copied verbatim -->
        <path d="..." />   <!-- the path's fill attribute is preserved verbatim -->
    </g></g>
</svg>
```

Because SVG attribute fill on a child path **wins** over inherited CSS fill, putting any literal fill (`fill="black"`, `fill="red"`) or even `fill="currentColor"` on the path defeats Perspective's color-control hook. The path renders in whatever fill is baked in, regardless of the Icon component's `color` property or any Style Class applied.

**Rule:** omit the `fill` attribute entirely on every path. Do not use `fill="currentColor"`. Do not use any literal color.

With no fill on the path, Perspective's outer-SVG `fill: currentcolor` cascades down properly. The path then renders in whatever the CSS `color` of the icon resolves to — driven either by the Icon component's top-level `color` property, or by a Perspective Style Class with **Text → Color** set, or by a CSS rule targeting the icon's class.

## Recoloring icons in views

Three approaches, all working when the path has no fill:

1. **Top-level `color` prop on the Icon component.** Set in the property panel directly. Quickest for one-off colors.
2. **Perspective Style Class.** Create a style class in `style-classes/<group>/<name>/style.json` with the **Text → Color** value set; apply via `style.classes` on the Icon. Best for theme-driven coloring across many icons.
3. **CSS rule via the Advanced Stylesheet.** A rule like `.psc-my-icon { color: var(--accent); }` cascades through `currentcolor` and recolors anything with that style class. Best for theme-variable-driven colors.

All three eventually set CSS `color` on the icon; `currentcolor` resolves to it; the outer-SVG fill becomes the new color; and the (no-fill) path inherits.

## Source for Material Symbols at custom axes

For Material Symbols at non-default axis combinations (any combination of `wght`, `grad`, `fill`, `opsz` other than the defaults), the Google Fonts `fonts.gstatic.com` static endpoint exposes only `wght` and `fill` axes — the `grad` axis is **not available there**. The pre-rendered static SVGs for every variable-font axis combination live in the `material-design-icons` GitHub repository:

```
https://raw.githubusercontent.com/google/material-design-icons/master/symbols/web/<icon-name>/materialsymbolsoutlined/<icon-name>_wght<NNN>gradN<NN>_<size>px.svg
```

Examples:

- Outlined / weight 300 / grade -25 / opsz 48: `<icon>_wght300gradN25_48px.svg`
- Outlined / weight 400 / grade 0 / opsz 24 (default): `<icon>_24px.svg`
- Outlined / weight 700 / fill 1 / opsz 48: `<icon>_wght700fill1_48px.svg`

The repo's per-icon `materialsymbolsoutlined/` folder lists every available axis-combo file. Browse it directly via the GitHub UI to confirm the exact filename for an axis combo you want.

Fallback if a name 404s: open <https://fonts.google.com/icons>, search the icon, set the four axes manually, and download the static SVG via the website. Single-icon downloads are fine for adding occasional icons; for bulk fetches the GitHub repo is faster.

## Deployment

1. Copy the entire library folder (`<library-name>/` with all three files) into the gateway path:
   `<install>/data/config/resources/core/com.inductiveautomation.perspective/icons/<library-name>/`
2. **Restart the Ignition Gateway service.** "Scan File System" in the Gateway web UI registers new library folders but does NOT reliably reload modified content inside an existing sprite. A service restart is the safest reload for any sprite content change.
3. References from views: `props.path = "<library-name>/<icon-id>"` on any Icon component. No view-level config needed.

## Adding icons later

Same workflow as initial setup, just append:

1. Acquire the new SVG (Material Symbols GitHub URL, hand-authored, etc.).
2. Extract the `<path d="..."/>` element(s); discard the source's outer wrapper.
3. **Strip any `fill` attribute** from the paths.
4. Wrap each path in `<svg viewBox="0 0 24 24" id="<new-icon-id>">…</svg>` (or whatever viewBox the rest of the library uses), applying any path `transform` needed to map the source coordinate system into the target viewBox.
5. Append to the existing `<library-name>.svg` between the outer `<svg>` tags.
6. `resource.json` needs no change unless the SVG filename itself changed.
7. Redeploy and restart the gateway service.

## Common failure modes (diagnostic)

| Symptom | Likely cause |
|---|---|
| Icon doesn't appear at all (Designer shows the path is unresolved) | Library not registered. Check folder is at the 8.3 path (not the 8.1 `data/modules/...` path). Confirm `config.json` and `resource.json` are present alongside the `.svg`. Restart the gateway. |
| Icon path shows in the picker but renders blank | ViewBox is negative-origin (e.g., `0 -960 960 960`). Remap to `0 0 24 24` with a path transform. |
| Icon renders but stays a fixed color regardless of `color` prop or Style Class | Path has a `fill` attribute (literal or `currentColor`). Remove it. |
| Sprite changes after a hot edit don't take effect | "Scan File System" missed it — restart the gateway service. |
| Color works in Designer preview but not in the deployed Perspective session | Browser cache. Hard-refresh (Ctrl+Shift+R). |

## When in doubt — DevTools

Same rule as `06_component_quirks.md`. The icon ends up as an `<svg>` element in the rendered DOM; inspect it directly to see what classes Perspective applied, what fill the outer SVG has, and whether your path's fill is overriding the cascade. Five minutes of inspection answers most "why doesn't this work?" questions definitively.
