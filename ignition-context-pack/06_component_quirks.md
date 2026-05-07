# Perspective component quirks (verified)

DOM class names, format-token differences, and rendering details for specific Ignition 8.3 Perspective components — verified empirically via browser DevTools rather than guessed from documentation. Use these instead of inferring class names by extrapolating from sibling components.

## Class naming inside Ignition 8.3 Perspective is inconsistent

There is no single naming convention. Verified via DevTools on a running 8.3 gateway:

| Component | DOM class | Naming style |
|---|---|---|
| `ia.input.text-field` | `.ia_textField` | camelCase suffix |
| `ia.input.numeric-entry` | `.ia_numericEntryField` | camelCase suffix |
| `ia.input.dropdown` | `.ia_dropdown` | single word |
| `ia.input.text-area` | `.ia_textArea` | camelCase suffix |
| `ia.input.date-time-input` | `.ia_datetime_input` | **snake_case all lowercase** |
| `ia.display.icon` | `.ia_iconComponent` | wrapper class |
| `ia.display.label` | `.ia_labelComponent` | wrapper class |
| `ia.display.table` | `.ia_table`, `.ia_table__head`, `.ia_table__body__row`, `.ia_table__cell`, … | BEM-style with surprises (see "Table component DOM") |

The lesson: do not guess class names by extrapolating from a sibling component. Open browser DevTools, inspect the rendered element, copy the class names off the `class=""` attribute. Ten seconds of inspection saves a wrong-selector commit.

## `ia.input.date-time-input` — format prop uses Moment.js tokens

`props.format` does NOT follow Java `DateTimeFormatter` syntax. Verified case: setting `format: "yyyy-MM-dd"` produced display text like `2026-04-Tu` because lowercase `dd` was interpreted as day-of-week abbreviation, not 2-digit day-of-month.

Use **Moment.js / Day.js** token convention:

| Token | Meaning |
|---|---|
| `YYYY` | 4-digit year |
| `YY` | 2-digit year |
| `MM` | 2-digit month |
| `M` | 1-2 digit month |
| `DD` | 2-digit day-of-month |
| `D` | 1-2 digit day-of-month |
| `dd` | day-of-week abbreviation (`Mo`, `Tu`, `We`…) |
| `ddd` | day-of-week short (`Mon`, `Tue`…) |
| `dddd` | day-of-week full (`Monday`…) |
| `HH`, `mm`, `ss` | 24h hour, minutes, seconds |

For a `2026-04-15`-style display: `format: "YYYY-MM-DD"`.

## `ia.input.date-time-input` — value type

`props.value` is a Date — in JSON, this is a numeric **timestamp (milliseconds since epoch)**. Not an ISO string. Initializing `view.custom.someDate` with a string like `"2026-04-15"` produces a binding-type mismatch and the picker won't render the value correctly.

Either:

- **Numeric timestamp directly** in JSON: `1776211200000` for `2026-04-15 00:00:00 UTC`. Compute via `new Date('2026-04-15T00:00:00Z').getTime()` in node, or `system.date.toMillis(system.date.parse('2026-04-15', 'yyyy-MM-dd'))` in script-python.
- **Expression binding** that produces a Date: `parseDate('2026-04-15', 'yyyy-MM-dd')` — note that Ignition's expression-language `parseDate` follows the **Java** pattern (lowercase tokens), not Moment.js. Yes, two different format languages in the same component.

## `ia.display.table` — virtualized DOM, not native `<table>`

The table component renders a div-based virtual table — NOT a native `<table>`. Inspected DOM tree:

```
.psc-data-table.ia_tableComponent          ← outer wrapper (gets your style.classes value)
  .table-container
    .t.ia_table.ia_container--secondary    ← actual table
      .th-container.ia_table__headContainer
        .th.ia_table__head                 ← <<< head bg styled here
          .tr.header.ia_table__head__header
            .tc.ia_table__cell.ia_table__head__header__cell  ← head cell
              .content
      .tb.ia_table__body                   ← <<< body wrapper, NEEDS bg
        .ReactVirtualized__Grid            ← <<< virtualized grid, NEEDS bg
          .ReactVirtualized__Grid__innerScrollContainer  ← <<< NEEDS bg
            .tr-group.ia_table__body__rowGroup.ia_table__body__row--even (or --odd)
              .tr.ia_table__row.ia_table__body__row     ← row hover targets here
                .tc.ia_table__cell                       ← BODY cell — note: NOT __body__cell
                  .content                                  ← actual cell text
  .pager-container.ia_pager.bottom         ← <<< pager bar, NEEDS bg
    .pager
      .size-options
        .iaSelectCommon.ia_select          ← rows-per-page chooser
      .ia_pager__page.ia_pager__page--active   ← active page number
```

### Key gotchas

- **Body cells use `.ia_table__cell`** (the catch-all) — there is no `.ia_table__body__cell`. Head cells additionally have `.ia_table__head__header__cell` (note the doubled `__header`).
- **`.ia_table__body` is unstyled by default**, and inside it lives a `ReactVirtualized__Grid` + `__innerScrollContainer` with white default background. Style all three or the empty area below rendered rows shows white.
- **`.ia_pager` (the pager strip at table bottom) is unstyled** — needs explicit theming, including the rows-per-page `<select>` and the active-page indicator.

### Working dark-theme selectors

```css
.ia_table { background: var(--surface-raised); }
.ia_table__head { background: var(--surface-card); /* + header text styling */ }
.ia_table__head__cell, .ia_table__head__header__cell { padding: 12px 16px; text-align: left; }

.ia_table__body,
.ia_table__body .ReactVirtualized__Grid,
.ia_table__body .ReactVirtualized__Grid__innerScrollContainer {
    background: var(--surface-raised);
}

.ia_table__body__row,
.ia_table__body__row > * {
    background: var(--surface-raised);
    color: var(--text-primary);
}
.ia_table__body__row:hover,
.ia_table__body__row:hover > * { background: var(--surface-hover); }

.ia_table__cell { padding: 12px 16px; background: transparent; }

.ia_pager, .pager-container {
    background: var(--surface-raised);
    border-top: 1px solid var(--border-subtle);
}
.ia_pager__page--active { background: var(--accent-bg); color: var(--accent-fg); }
.ia_pager .ia_select__select {
    background: var(--surface-raised);
    color: var(--text-primary);
}
```

The `> *` cascade pattern on the row matters: there's an intermediate wrapper between the row and each cell, and we want both to share the surface background without naming whatever the wrapper class is.

## `ia.display.icon` — sizing

Icons render as SVG. **`font-size` does not size them** (it works for icon-fonts but Ignition's icon component renders SVG). Set `width` and `height`:

```css
.psc-nav-icon {
    width: 16px;
    height: 16px;
}

/* and to be safe — target the inner SVG too: */
.psc-nav-icon svg {
    width: 16px;
    height: 16px;
}
```

## `ia.display.icon` — material icon path

`props.path` takes a path-prefix-plus-name format, e.g., `material/inventory`, `material/person`, `material/build`. The available icon names are bundled with the Ignition gateway and depend on which icon library you have installed.

If an icon renders as a warning triangle ⚠, the path didn't resolve — either the prefix is wrong (`materialicons/` vs `material/`) or the specific name isn't in your gateway's icon set. Older sets are missing newer Material Symbols names like `factory`, `inventory_2`, `account_tree`, `dark_mode`, `handyman`, `insights`. Reliable older names: `apartment`, `inventory`, `person`, `build`, `settings`, `timer`, `check_circle`, `warning`, `error`, `description`, `event_note`, `wb_sunny`.

For projects that need newer Material Symbols names, custom axis combinations (weight 300, grade -25, etc.), or a project-locked icon set independent of whatever ships with the gateway, build a custom icon library. See `08_custom_icon_libraries.md` for the full setup — file layout, SVG sprite format, viewBox + no-fill-on-path rules, and source URLs for Material Symbols at non-default axes.

## `ia.container.flex` — direction prop usually works

`props.direction` accepts `"row"`, `"column"`, `"row-reverse"`, `"column-reverse"` and behaves like CSS flex-direction. In rare cases the prop doesn't take effect (observed on dock-rendered views with embedded child views) — when this happens, fall back to inline CSS:

```json
"props": {
  "direction": "row",
  "alignItems": "stretch",
  "wrap": "nowrap",
  "style": {
    "display": "flex",
    "flexDirection": "row",
    "flexWrap": "nowrap"
  }
}
```

The inline `style` with `flexDirection` overrides via CSS specificity if the prop somehow doesn't translate. Not always needed; reach for it when a flex container is misbehaving.

## `ia.display.view` — embedding views

The embedded-view component reads `props.path`. It's surprisingly finicky inside flex parents — embedded views sometimes render at their own `defaultSize` regardless of the parent's `position.basis` / `grow`, leading to layout breakage.

If embedding doesn't size correctly, the workaround is to **inline the embedded view's content** into the parent rather than embed. Verbose but reliable. Alternatives like `useDefaultViewWidth: false` exist but their behavior across Ignition versions is inconsistent.

## When in doubt — DevTools

Anything component-rendered in Perspective is just HTML + CSS in the browser. Open DevTools, inspect the element, look at the actual class names and computed styles. Five minutes of inspection answers most "why doesn't my CSS apply?" questions definitively, without guesswork.
