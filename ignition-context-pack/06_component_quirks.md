# Perspective component quirks (verified)

DOM class names, format-token differences, and rendering details for specific Ignition 8.3 Perspective components — verified empirically via browser DevTools rather than guessed from documentation. Use these instead of inferring class names by extrapolating from sibling components.

## Class naming inside Ignition 8.3 Perspective is inconsistent

There is no single naming convention. Verified via DevTools on a running 8.3 gateway:

| Component | DOM class | Naming style |
|---|---|---|
| `ia.input.text-field` | `.ia_textField` | camelCase suffix |
| `ia.input.numeric-entry-field` | `.ia_numericEntryField` | camelCase suffix (component type is `numeric-entry-field`, NOT `numeric-entry` — the latter renders "component not found") |
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

## `ia.display.table` — `props.columns` entries must carry the FULL column schema

Each object in `props.columns` is **not** a free-form `{field, header}` shorthand — it is a fixed-shape record with ~24 keys, and Designer writes every key on every column whether you set it or not. Hand-authoring an abbreviated column (just `field` + `header`, dropping the rest) produces a **table-wide Component Error banner** or a column that silently fails to render. The single most common breaker:

```json
// WRONG — header as a bare string. Renders Component Error / blank table.
{ "field": "specName", "header": "Spec Name" }

// WRONG — also missing the other 22 keys.
{ "field": "specName", "header": "Spec Name", "width": 120 }
```

`header` (and `footer`) are **objects** (`{title, justify, align, style}`), never strings. The header text is `header.title`. A string where Perspective expects the object is enough on its own to break the table.

### Canonical full column object

Designer serializes column keys **alphabetically**. Use this exact shape as the base for every hand-authored column and change only `field`, `header.title`, `width`, and (when relevant) `render` / `dateFormat` / `numberFormat` / `sortable`:

```json
{
  "align": "center",
  "boolean": "checkbox",
  "dateFormat": "MM/DD/YYYY",
  "editable": false,
  "field": "specName",
  "filter": {
    "boolean": { "condition": "" },
    "date": { "condition": "", "value": "" },
    "enabled": false,
    "number": { "condition": "", "value": "" },
    "string": { "condition": "", "value": "" },
    "visible": "on-hover"
  },
  "footer": { "align": "center", "justify": "left", "style": { "classes": "" }, "title": "" },
  "header": { "align": "center", "justify": "left", "style": { "classes": "" }, "title": "Spec Name" },
  "justify": "auto",
  "nullFormat": { "includeNullStrings": false, "nullFormatValue": "", "strict": false },
  "number": "value",
  "numberFormat": "0,0.##",
  "progressBar": {
    "bar": { "color": "", "style": { "classes": "" } },
    "max": 100,
    "min": 0,
    "track": { "color": "", "style": { "classes": "" } },
    "value": { "enabled": true, "format": "0,0.##", "justify": "center", "style": { "classes": "" } }
  },
  "render": "auto",
  "resizable": true,
  "sort": "none",
  "sortable": true,
  "strictWidth": false,
  "style": { "classes": "" },
  "toggleSwitch": { "color": { "selected": "", "unselected": "" } },
  "viewParams": {},
  "viewPath": "",
  "visible": true,
  "width": ""
}
```

### Per-key notes

| Key | Type / values | Notes |
|---|---|---|
| `field` | string | Matches a key in each `props.data` row dict. |
| `header` / `footer` | **object** `{title, justify, align, style}` | Text lives in `.title`. Bare string here = Component Error. |
| `width` | **number** (px) or `""` | Fixed width is a number (`120`); `""` = auto-size. Don't quote the number. |
| `strictWidth` | bool | `true` forces `width` exactly (no flex-grow). |
| `render` | `"auto"` \| `"number"` \| `"date"` \| `"boolean"` \| `"progress"` \| `"toggle"` \| `"view"` | Drives which of the type-specific blocks (`numberFormat`, `dateFormat`, `progressBar`, `toggleSwitch`, `viewPath`) applies. |
| `dateFormat` | Moment.js tokens | e.g. `"MM/DD/YYYY h:mm A"`. Same token rules as `date-time-input` (see above), NOT Java. |
| `numberFormat` | numeral.js pattern | e.g. `"0,0.##"`. |
| `viewPath` / `viewParams` | string / object | Only used when `render: "view"` (embed a sub-view per cell). |
| `filter` | object | Per-column filter config; `filter.enabled` off by default. |

### Why abbreviated columns sometimes *appear* to work

A column with `header` as an object but missing other keys (e.g. only `field` + `header.title` + `sortable` + `visible`) can render — Perspective fills some defaults at runtime. But it's fragile: the next Designer save rewrites the column to the full alphabetical shape, producing a large spurious diff, and any missing key that Perspective *doesn't* default (notably a string `header`) breaks the whole table. Author the full shape up front; it matches what Designer would write and avoids both the error and the diff churn.

## `ia.display.table` — read the selected row from `props.selection.data`, not `props.data[index]`

When a row-action needs the selected row's data (a "go to detail" button, a row-context popup), read it straight off the selection object — it's the already-resolved row dict:

```python
# CORRECT — selection.data is a LIST of selected-row dicts (one element in
# single-select mode). Index [0] for the selected row, then the field.
table    = self.parent.getChild("Panel").getChild("SpecsTable")
selected = table.props.selection.data       # e.g. [{"id": 42, "specName": "..."}]
specId   = selected[0]["id"]
```

Do NOT pull the whole dataset and re-index it by the selected index:

```python
# WASTEFUL + fragile — copies the ENTIRE dataset into the script frame just to
# read one row, then re-derives the row the selection already gives you
rows   = table.props.data
specId = rows[table.props.selection.selectedRow]["id"]
```

`props.data` is the full dataset; touching it from a script marshals every row across the boundary. **`props.selection.data` is a LIST of the selected rows' dicts — not a bare dict — even when `selectionMode` is single** (the list just has one element). Index `[0]` for the row, then the field. Use `selection.selectedRow` (the integer index) only when you genuinely need the ordinal — never to look the row back up out of `props.data`.

**Gotcha — `selection.data` only contains fields that have a defined column.** The selection payload is built from the table's `columns`, not from the raw row. A field present in `props.data` but with *no column entry* (a common case: a primary-key `id` you don't want displayed) is **absent** from each selection dict, so `selection.data[0]["id"]` raises `KeyError`. To expose a non-displayed field to row-actions, add a column for it with `"visible": false` (full schema, like any other column) — the column makes the field flow into `selection.data` while keeping it out of the rendered table. This is the right way to carry a row's PK to a "go to detail" handler.

### Reaching the table — `getSibling` only finds TRUE siblings

`self.getSibling("SpecsTable")` resolves **only** when the table shares the button's immediate parent. If the table is nested inside a container — a very common layout (table inside a `Panel`, the button outside it) — `getSibling` returns `None` and the next `.props` access throws. Walk the tree explicitly from a common ancestor:

```python
# table lives inside the "Panel" container; the button is Panel's sibling under root
self.parent.getChild("Panel").getChild("SpecsTable")
```

`self.parent` is the common ancestor (root here), `.getChild("Panel")` steps into the container, `.getChild("SpecsTable")` reaches the table. Name every container along the path (see `07` → component naming) so this addressing survives refactors. `getSibling` is the shortcut for the flat case only; the moment a component is one level deeper, switch to `parent.getChild(...).getChild(...)`.

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
