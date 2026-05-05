# MPP Material Symbols Icon Library for Ignition Perspective — Design

**Date:** 2026-05-05
**Author:** Jacques Potgieter (with Claude)
**Status:** Approved — ready for implementation plan

## Problem

The MPP MES mockup (`mockup/icons.csv`, `mockup/icon-explorer.html`) locks 35 icons against **Material Symbols Outlined** at a specific axis combination (weight 300, grade -25, fill 0, optical size 48px). The mockup renders these via the variable font hosted at fonts.googleapis.com.

Ignition Perspective ships a built-in `material` icon library, but it is the legacy **Material Icons** library — filled-only, fixed weight, different aesthetic. None of our 35 locked icons exist in Ignition at the matching style. To carry the mockup's visual fidelity into the real application, we must publish a custom Perspective icon library containing the 35 SVGs at the locked style.

## Goal

Deliver a single, deployable SVG sprite file that:

- Contains all 35 icons from `mockup/icons.csv` at the locked Material Symbols style.
- Installs via file copy to `<gateway>/data/modules/com.inductiveautomation.perspective/icons/mpp.svg`.
- Lets Perspective views reference any locked icon as `mpp/<material_symbol_name>` (e.g., `mpp/play_arrow`).
- Inherits color from CSS via `currentColor` so existing theme tokens (`--mpp-icon-color`, `--mpp-icon-color-accent`) continue to work.
- Lives in version control as the source of truth — no build pipeline, no separate `sources/` directory.

## Non-goals

- Build pipeline / fetch script / sources folder.
- Icons beyond the 35 locked in `icons.csv`.
- Updating existing Perspective views to consume the new library (downstream task).
- Theming hooks beyond `currentColor` inheritance.
- Material Symbols Rounded or Sharp variants — Outlined only.
- Modifications to Ignition's built-in `material` library.

## Decisions

The brainstorming session locked four strategic choices:

| # | Decision | Rationale |
|---|---|---|
| 1 | **Scope = exactly the 35 icons in `icons.csv`** | The CSV is the locked design contract. Adding icons later is a low-friction file edit; starting with 35 makes drift detection trivial. |
| 2 | **Naming = Material Symbol names** (e.g., `mpp/play_arrow`, not `mpp/forward`) | Canonical end-to-end. Future regen / additions use the upstream name; no translation layer. The `key` column in `icons.csv` becomes a documentation alias only. |
| 3 | **Library name = `mpp`**, repo path = `ignition/icons/mpp.svg` | Mirrors the gateway path (`com.inductiveautomation.perspective/icons/mpp.svg`); deployment is a one-to-one file copy. Library namespace short and unambiguous within MPP's gateway. |
| 4 | **Hand-assembled single sprite, no build pipeline** | 35 locked icons; the build cost is one-time. Pipeline overhead would never amortize. |

Two tactical choices were also locked during design:

| # | Decision | Rationale |
|---|---|---|
| 5 | **`viewBox="0 0 48 48"`** on each inner `<svg>` | Lock spec is opsz 48; Google ships the path data tuned for the 48-grid at this axis combo. Re-mapping to a 24-grid would compress strokes and lose the wght 300 / grade -25 character. Perspective scales by declared CSS size regardless of viewBox. |
| 6 | **`fill="currentColor"`** on every path | Google's downloads bake in `fill="#000000"`. Replacing with `currentColor` lets Perspective theming and the existing CSS tokens drive icon color. Without this, every icon renders black regardless of style. |

## Sprite file format

Per IA's documented convention (wrapped `<svg>` elements with `id`, **not** `<symbol>`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
    <!--
        MPP MES — Material Symbols icon library
        Lock date: 2026-05-04 (per mockup/icons.csv)
        Style: Outlined · Weight 300 · Fill 0 · Grade -25 · Optical size 48px
        Source: https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/<name>/wght300grad_N25/48px.svg
    -->

    <!-- ===== Navigation ===== -->

    <!-- home — Home -->
    <svg viewBox="0 0 48 48" id="home">
        <path d="..." fill="currentColor" />
    </svg>

    <!-- play_arrow — Forward / play (mockup key: forward) -->
    <svg viewBox="0 0 48 48" id="play_arrow">
        <path d="..." fill="currentColor" />
    </svg>

    <!-- ... 33 more ... -->

</svg>
```

Each icon block is preceded by a comment recording the Material Symbol name, its CSV `purpose`, and (where it differs) the original mockup `key`.

## Repo layout

```
ignition/
└── icons/
    ├── mpp.svg                 ← deployable sprite (committed)
    └── README.md               ← lock spec, sourcing notes, deploy steps
```

`ignition/icons/` mirrors the gateway path so deployment is unambiguous. `ignition/icons/README.md` documents:

- The lock spec (style / weight / fill / grade / opsz / lock date 2026-05-04).
- The fonts.gstatic.com URL pattern used to source each SVG.
- The two cleanup steps applied to each downloaded SVG (viewBox preserved, fill replaced with `currentColor`).
- Deployment steps (copy to gateway path, verify).
- The relationship to `mockup/icons.csv` (the CSV is the design contract; this library is its Ignition realization).

## Sourcing workflow (one-time)

For each row in `mockup/icons.csv`:

1. **Fetch** the SVG from `https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/<material_symbol>/wght300grad_N25/48px.svg`.
2. **Strip** the baked-in `fill="#..."` attribute and replace each `<path>` with `fill="currentColor"`.
3. **Wrap** in `<svg viewBox="0 0 48 48" id="<material_symbol>">…</svg>`.
4. **Append** to `mpp.svg`, grouped by the CSV's `group` column (Navigation, Actions, Sections, Status), with section-divider comments and a per-icon comment carrying the CSV's `purpose`.

Order within `mpp.svg` follows `icons.csv` order so a future audit can diff the two visually.

## Deployment

1. Locate the running Ignition gateway's data directory.
2. Copy `ignition/icons/mpp.svg` → `<gateway>/data/modules/com.inductiveautomation.perspective/icons/mpp.svg`.
3. No gateway restart required — Perspective hot-reloads icon libraries in 8.1.x.
4. Refresh any open Perspective session.

## Verification

Before claiming the task complete:

1. **Sanity check on first icon.** Before assembling all 35, deploy a one-icon `mpp.svg` (just `play_arrow`) and reference it from a throwaway Perspective Icon component (`path = "mpp/play_arrow"`). Confirm it renders and that setting a CSS color on the component (or its parent) actually re-colors the icon — verifies `currentColor` propagation through Perspective.
2. **Full library check.** After all 35 are assembled and deployed, reference each from a test view (or visually compare against `icon-explorer.html`). All 35 must render at the matching weight 300 / grade -25 character.
3. **Style consistency.** No icon should look heavier, lighter, or differently weighted than its mockup counterpart — flags an axis-mismatch in the source URL.

## Risks and assumptions

- **`fonts.gstatic.com` URL pattern.** The pattern `wght300grad_N25/48px.svg` reflects current Google Fonts static-export behavior at the locked axis combination. If Google's URL doesn't serve that exact combination, fallback is to render each icon via the icon picker on fonts.google.com/icons (manual SVG download per icon at the matching axes). Probability low; cost of the fallback is ~5 extra minutes per icon.
- **`currentColor` propagation.** Standard SVG behavior, confirmed in IA forum threads. The first-icon sanity check (above) catches this before mass assembly.
- **Material Symbols Outlined static SVG availability.** Google supports static-SVG download for the entire Material Symbols set including custom axis combinations. None of the 35 icons are exotic; all are commonly-used names.

## Open follow-ups (out of scope here)

- Updating existing Perspective views (`BlueRidge/Components/Navigation/RailNav`, etc.) to actually consume `mpp/<icon>` paths in place of any current built-in `material/` references.
- Adding icons #36+ when new screens require them — workflow will be: add row to `icons.csv`, append a new wrapped `<svg>` to `mpp.svg`, redeploy.
- Documenting the icon library in the FDS (Section 11 — UI Design? Section to be confirmed when FDS gets its next pass).
