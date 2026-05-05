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

Each icon is sourced from Google Fonts' static SVG endpoint at the locked axes:

```
https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/<material_symbol_name>/wght300grad_N25/48px.svg
```

(Example: `https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/play_arrow/wght300grad_N25/48px.svg`.)

Fallback if the URL pattern fails for any icon: open <https://fonts.google.com/icons>, search the icon, set Weight=300 / Grade=-25 / Optical Size=48 / Fill=0, and download the static SVG.

## Cleanup applied to each fetched SVG

1. Preserve the original `viewBox="0 0 48 48"`.
2. Strip any baked-in `fill="#..."` attribute on the root `<svg>` or on `<path>` elements.
3. Set `fill="currentColor"` on each `<path>` so Perspective theme tokens (`--mpp-icon-color`, `--mpp-icon-color-accent`, etc.) drive color.
4. Wrap in `<svg viewBox="0 0 48 48" id="<material_symbol_name>">…</svg>`.
5. Append to `mpp.svg` in the order from `mockup/icons.csv`, grouped by the `group` column (Navigation, Actions, Sections, Status), with section comments.

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
