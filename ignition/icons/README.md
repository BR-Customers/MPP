# MPP Custom Perspective Icon Library

This directory holds the **`mpp`** custom Perspective icon library deployed to the Ignition Gateway. Perspective references the icons as `mpp/<icon_name>` (e.g., `mpp/play_arrow`).

## Repo layout (mirrors gateway layout, Ignition 8.3+)

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
| Optical size | 48 |

The locked set lives in `mockup/icons.csv` — that file is the design contract. `mpp/mpp.svg` is its Ignition realization.

## Source URL pattern

Each icon is sourced from the Google `material-design-icons` GitHub repository, which publishes pre-rendered static SVGs at every supported axis combination of the Material Symbols variable font:

```
https://raw.githubusercontent.com/google/material-design-icons/master/symbols/web/<name>/materialsymbolsoutlined/<name>_wght300gradN25_48px.svg
```

(Example: `https://raw.githubusercontent.com/google/material-design-icons/master/symbols/web/play_arrow/materialsymbolsoutlined/play_arrow_wght300gradN25_48px.svg`.)

Note: Google's `fonts.gstatic.com` static endpoint only exposes weight and fill axes — `grad` is not available there. The GitHub repo is the only source that publishes pre-rendered SVGs at every variable-font axis combination, including `gradN25`.

Fallback if a name 404s in the GitHub repo: open <https://fonts.google.com/icons>, search the icon, set Weight=300 / Grade=-25 / Optical Size=48 / Fill=0, and download the static SVG manually.

## Cleanup applied to each fetched SVG

Each fetched SVG comes in this shape:

```xml
<svg xmlns="http://www.w3.org/2000/svg" height="48" viewBox="0 -960 960 960" width="48"><path d="…"/></svg>
```

The viewBox `0 -960 960 960` is intentional — it's the font's own glyph coordinate grid (baseline at 0, glyphs extending upward to 960). Perspective scales by the rendered CSS size regardless, so we keep this viewBox unchanged.

Cleanup steps:

1. **Preserve** the source `viewBox="0 -960 960 960"`. Do not re-map.
2. **Drop** the outer `xmlns`, `height`, and `width` attributes from the source `<svg>` — Perspective's container handles dimensions.
3. **Add** `fill="currentColor"` to each `<path>`. The source paths have no fill set (browser defaults to black); explicit `currentColor` lets Perspective theme tokens drive icon color.
4. **Wrap** as `<svg viewBox="0 -960 960 960" id="<name>">…</svg>` (the inner `<svg>` keeps the viewBox; the outer wrapper in `mpp.svg` carries the `xmlns`).
5. **Append** to `mpp.svg` in the order from `mockup/icons.csv`, grouped by the `group` column (Navigation, Actions, Sections, Status), with section comments.

## Deployment (Ignition 8.3+)

The destination on the gateway is:

```
<install-dir>/data/config/resources/core/com.inductiveautomation.perspective/icons/mpp/
├── mpp.svg
├── config.json
└── resource.json
```

The library folder name (`mpp`) **must** equal the library reference name used in views (`mpp/<icon>`).

Steps:

1. Copy the entire `ignition/icons/mpp/` folder (all three files) to `<install-dir>/data/config/resources/core/com.inductiveautomation.perspective/icons/mpp/` on the gateway. Create the parent folders if they don't exist.
2. Restart the Ignition Gateway service, **or** click **Scan File System** on the Gateway's Platform Overview page (faster — no service interruption).
3. Reference icons from views as `mpp/<material_symbol_name>` (e.g., set an Icon component's `path` to `mpp/play_arrow`).

> **Pre-8.3 note:** Ignition 8.1.x used a different path — single `mpp.svg` at `data/modules/com.inductiveautomation.perspective/icons/mpp.svg` with no `config.json` or `resource.json`. That layout does not work on 8.3.

## Regeneration / adding icons

Workflow when adding icon #36+:

1. Add a row to `mockup/icons.csv`.
2. Fetch the new SVG from the URL pattern above.
3. Apply the cleanup steps.
4. Append a new wrapped `<svg id="<name>">` to `mpp/mpp.svg` in the appropriate group section.
5. Update the `files` array in `resource.json` only if the SVG filename changed (it shouldn't).
6. Redeploy the `mpp/` folder to the gateway and Scan File System.
