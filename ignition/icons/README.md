# MPP Custom Perspective Icon Library

This directory holds `mpp.svg`, the custom icon library deployed to the Ignition gateway under `data/modules/com.inductiveautomation.perspective/icons/mpp.svg`. Perspective references the icons as `mpp/<icon_name>` (e.g., `mpp/play_arrow`).

## Lock spec

The 35 logical icons (34 unique sprites — `cancel` serves both `close` and `reject` aliases in `mockup/icons.csv`) are locked against **Material Symbols Outlined** at the following axis combination (set 2026-05-04 in `mockup/icons.csv`):

| Axis | Value |
|---|---|
| Style | Outlined |
| Weight | 300 |
| Fill | 0 |
| Grade | -25 |
| Optical size | 48 |

The locked set lives in `mockup/icons.csv` — that file is the design contract. `mpp.svg` is its Ignition realization.

## Source URL pattern

Each icon is sourced from the Google `material-design-icons` GitHub repository, which publishes pre-rendered static SVGs at every supported axis combination of the Material Symbols variable font. Our locked axes (weight 300, grade -25, optical size 48, fill 0) use this URL pattern:

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

Cleanup steps applied to each fetched SVG:

1. **Preserve** the source `viewBox="0 -960 960 960"`. Do not re-map to `0 0 48 48`.
2. **Drop** the outer `xmlns`, `height`, and `width` attributes from the source `<svg>` — Perspective's container handles dimensions.
3. **Add** `fill="currentColor"` to each `<path>`. The source paths have no fill set (browser defaults to black); explicit `currentColor` lets Perspective theme tokens drive icon color.
4. **Wrap** as `<svg viewBox="0 -960 960 960" id="<name>">…</svg>` (the inner `<svg>` keeps the viewBox; the outer wrapper in `mpp.svg` carries the `xmlns`).
5. **Append** to `mpp.svg` in the order from `mockup/icons.csv`, grouped by the `group` column (Navigation, Actions, Sections, Status), with section comments.

## Deployment

1. Copy `ignition/icons/mpp.svg` to `<gateway-install>/data/modules/com.inductiveautomation.perspective/icons/mpp.svg`.
2. Refresh any open Perspective session — Ignition 8.1.x hot-reloads custom icon libraries without a gateway restart.
3. Reference icons from views as `mpp/<material_symbol_name>` (e.g., set an Icon component's `path` to `mpp/play_arrow`).

If a gateway restart is needed (older 8.1.x), restart the Ignition Gateway service.

## Regeneration / adding icons

Workflow when adding icon #36+:

1. Add a row to `mockup/icons.csv`.
2. Fetch the new SVG from the URL pattern above.
3. Apply the cleanup steps.
4. Append a new wrapped `<svg id="<name>">` to `mpp.svg` in the appropriate group section.
5. Redeploy `mpp.svg` to the gateway.
