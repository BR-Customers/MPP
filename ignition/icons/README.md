# MPP Custom Perspective Icon Library

This directory holds the **`mpp`** custom Perspective icon library deployed to the Ignition Gateway. Perspective references the icons as `mpp/<icon_name>` (e.g., `mpp/play_arrow`).

## Repo layout (mirrors gateway layout, Ignition 8.3)

```
ignition/icons/
└── mpp/                  ← folder name = library name (must match)
    ├── mpp.svg           ← the SVG sprite (35 logical icons, 34 unique sprites)
    ├── config.json       ← { "svgFileName": "mpp.svg" }
    └── resource.json     ← gateway-scope resource manifest
```

## Lock spec

The 35 logical icons (34 unique sprites — `cancel` serves both `close` and `reject` aliases in `mockup/icons.csv`) are locked against **Material Symbols Outlined** at the following axis combination (set 2026-05-04 in `mockup/icons.csv`):

| Axis | Value |
|---|---|
| Style | Outlined |
| Weight | 300 |
| Fill | 0 |
| Grade | -25 |
| Optical size (source grid) | 48 (mapped to 24 viewBox via path transform) |

The locked set lives in `mockup/icons.csv` — that file is the design contract. `mpp/mpp.svg` is its Ignition realization.

## Sprite format

Each icon is wrapped per IA's documented custom-icon-library convention. The path data is the original Material Symbols glyph path in font-grid coordinates (the upstream viewBox is `0 -960 960 960`); a transform on the path maps it into a `0 0 24 24` viewBox so all icons share a consistent 24-unit grid that Perspective sizes via CSS.

```xml
<svg viewBox="0 0 24 24" id="<material_symbol_name>">
    <path transform="translate(0 24) scale(0.025)" d="<original-path-data>"/>
</svg>
```

**No `fill` attribute on the path.** Perspective wraps each rendered icon in an outer `<svg style="fill: currentcolor">` element; that fill cascades down to paths only when the path doesn't override. Setting any `fill` on the path (literal color or `currentColor`) breaks Perspective's color-control hook. Leaving fill off makes the icon recolorable from Perspective via the Icon component's top-level `color` property or via a Perspective Style Class with **Text > Color** set.

## Source URL pattern

Each icon's path data is sourced from the Google `material-design-icons` GitHub repository, which publishes pre-rendered static SVGs at every supported axis combination of the Material Symbols variable font:

```
https://raw.githubusercontent.com/google/material-design-icons/master/symbols/web/<name>/materialsymbolsoutlined/<name>_wght300gradN25_48px.svg
```

Note: Google's `fonts.gstatic.com` static endpoint only exposes weight and fill axes — `grad` is not available there. The GitHub repo is the only source that publishes pre-rendered SVGs at every variable-font axis combination, including `gradN25`.

Fallback if a name 404s in the GitHub repo: open <https://fonts.google.com/icons>, search the icon, set Weight=300 / Grade=-25 / Optical Size=48 / Fill=0, and download the static SVG manually.

## Cleanup applied to each fetched SVG

Each fetched SVG comes in this shape:

```xml
<svg xmlns="http://www.w3.org/2000/svg" height="48" viewBox="0 -960 960 960" width="48"><path d="…"/></svg>
```

Cleanup steps:

1. **Extract** the `<path d="…"/>` element(s) from the source. Most icons have one path; a few have multiple (each becomes its own `<path>` inside our wrapper).
2. **Discard** the source's outer `<svg>` wrapper, its `xmlns`, `height`, `width`, and `viewBox` attributes.
3. **Discard** any `fill` attribute the path may carry. Perspective drives color.
4. **Wrap** in `<svg viewBox="0 0 24 24" id="<name>">` with each path carrying `transform="translate(0 24) scale(0.025)"`. The transform remaps the source's `0 -960 960 960` font grid into the `0 0 24 24` target grid.
5. **Append** to `mpp.svg` in the order from `mockup/icons.csv`, grouped by the `group` column (Navigation, Actions, Sections, Status), with section comments.

## Deployment (Ignition 8.3)

The destination on the gateway is:

```
<install-dir>/data/config/resources/core/com.inductiveautomation.perspective/icons/mpp/
├── mpp.svg
├── config.json
└── resource.json
```

The library folder name (`mpp`) **must** equal the library reference name used in views (`mpp/<icon>`).

Steps:

1. Copy the entire `ignition/icons/mpp/` folder (all three files) to the gateway path above. Create the parent folders if they don't exist (admin permission required since this is under `Program Files`).
2. **Restart the Ignition Gateway service.** "Scan File System" in the Gateway web UI registers new library *folders* but does not reliably reload modified content inside an existing sprite — a service restart is the safest reload.
3. Reference icons from views as `mpp/<material_symbol_name>` (e.g., set an Icon component's `path` to `mpp/play_arrow`).

> **Pre-8.3 note:** Ignition 8.1.x used a single `<lib>.svg` at `data/modules/com.inductiveautomation.perspective/icons/`. That layout does not work on 8.3.

## Recoloring icons in Perspective

Two approaches both work since the paths have no baked-in fill:

1. **Top-level `color` property on the Icon component** — set directly in the property panel.
2. **Perspective Style Class** — create a style class, set its **Text → Color**, apply the class to the Icon component via `style.classes`. This is the right pattern for project-wide theming via CSS variables.

Sizing and positioning are independent of the library — they're driven by the Icon component's container and `style.width` / `style.height` in Perspective.

## Regeneration / adding icons

Workflow when adding icon #36+:

1. Add a row to `mockup/icons.csv`.
2. Fetch the new SVG from the URL pattern above.
3. Apply the cleanup steps.
4. Append a new wrapped `<svg id="<name>">` to `mpp/mpp.svg` in the appropriate group section.
5. Update the `files` array in `resource.json` only if the SVG filename changed (it shouldn't).
6. Redeploy the `mpp/` folder to the gateway and restart the gateway service.
