# LOT Detail — genealogy click-through + header breadcrumb

**Date:** 2026-08-25
**Status:** Implemented and smoke-verified live against the local gateway (2026-08-25)
**Scope:** Presentation layer only. No SQL, no migrations, no named queries, no test-suite impact.

---

## Problem

The LOT Detail genealogy tab lists a LOT's parents and children as clickable-looking rows —
`cursor: pointer`, hover affordance — but clicking one does nothing. Both
[ParentRow](../../../ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/LotDetail/ParentRow/view.json)
and
[ChildRow](../../../ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/LotDetail/ChildRow/view.json)
carried their navigation on `events.component.onActionPerformed` attached to an
`ia.container.flex`. Containers emit no `onActionPerformed`, so the handler was
silently dead — the same failure shape as the `onStartup`-in-the-wrong-channel trap
documented in `ignition-context-pack/02_perspective_views.md`.

Even with the click fixed, walking genealogy strands the operator: `navigate()` replaces
the page, plant-floor terminals are kiosked with no browser chrome, and LOT Detail's only
escape hatches are *Back to Home* and *LOT Search*. Three hops down a die-cast → machined →
assembled chain there is no way back up.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Single click** navigates, not double-click | Original ask was double-click. Rejected: the two gestures cannot coexist (a double-click fires `onClick` twice *and* `onDoubleClick`), and double-tap is unreliable on a gloved plant-floor touchscreen with no affordance signalling "tap twice". Single click also makes the existing `cursor: pointer` honest. |
| D2 | **Full clickable trail**, not a single back-chip | A one-level `← LOT` chip forces an operator three hops deep to unwind one step at a time and gives no sense of position in the chain. |
| D3 | Trail reflects **genealogy walks only** | Arriving from LOT Search / Home / a report resets it. The breadcrumb is a genealogy path, not a browsing history. |
| D4 | Trail lives in **`session.custom.lotTrail`** | `navigate()` re-mounts the view, so `view.custom` cannot survive a hop. Page-scoped custom props are not declarable in `page-config`. Session scope is shared across tabs — acceptable on a single-page kiosk terminal. |
| D5 | Navigation stays **`system.perspective.navigate()`** on the existing `/shop-floor/lot-detail/:lotId` route | Keeps every LOT deep-linkable and refreshable, and matches how LOT Search already reaches LOT Detail. Writing `view.params.lotId` in place would desync the URL from the displayed LOT. |
| D6 | Adopt the **vestigial `.psc-pf-breadcrumb`** stylesheet block | It already existed in the Core stylesheet (base `display: none`, plus `.psc-pf-sep` / `.psc-pf-current` children) and was referenced by **zero** views — an abandoned AppHeader breadcrumb. Zero blast radius to adopt; the alternative was a fourth near-duplicate class. |

## Architecture

### The tail invariant

`session.custom.lotTrail` is an oldest-first list of `{"id", "name"}` dicts whose **last entry
is always the LOT currently displayed**. Every other behaviour falls out of that one rule.

It is maintained by `sync()`, called once per `load()`:

- tail id **matches** the LOT being loaded → the operator got here by a genealogy hop or a
  crumb click; the trail stands (a late-resolving `LotName` is patched into the tail crumb).
- tail id **does not match** → they arrived from LOT Search / Home / a report; reset the
  trail to `[thisLot]`.

Those two cases are told apart without any entry-point flag threaded through the navigation —
which is what makes D3 cheap.

Because the tail *is* the current LOT, a genealogy row click only has to name its **target**.
`hopToParent` / `hopToChild` are never told where they came from.

### Revisit truncates, it does not append

`_hop()` scans the trail for the target. Found → truncate to it. Not found → append.

So walking `A → B → C → B` leaves `A › B`, not `A › B › C › B`. The same rule makes a crumb
click self-healing: `jump()` truncates, then `sync()` finds a matching tail and leaves the
truncated trail alone. There is no separate "going backwards" code path.

### Components

| Artifact | Kind | Role |
|---|---|---|
| `Core/…/script-python/BlueRidge/Lots/LotTrail/code.py` | **new** | The whole state machine. `sync` / `hopToParent` / `hopToChild` / `jump` / `crumbs`. No DB access, no domain rules. |
| `MPP/…/session-props/props.json` | edit | Declares `custom.lotTrail: []`. |
| `…/Components/PlantFloor/LotDetail/CrumbChip/` | **new view** | One breadcrumb chip: leading `›` separator (hidden when `isFirst`) + label. Whole chip is the click target. |
| `…/LotDetail/ParentRow`, `…/ChildRow` | edit | `events.component.onActionPerformed` → `events.dom.onClick` (`scope: "G"`), one-liner into `LotTrail`. |
| `Core/…/stylesheet/stylesheet.css` | edit | `.psc-pf-breadcrumb` base `display: none` → `flex`; new `.psc-pf-crumb`, `.psc-pf-crumb-link`, `.psc-pf-crumb-elision`. |
| `…/Views/ShopFloor/LotDetail/view.json` | **deferred** | Header restructure + breadcrumb repeater + one line in `load()`. See below. |

### Two deliberate non-obvious choices

**`crumbs()` returns `[]` for a trail of 0 or 1 entries.** A LOT reached directly renders no
repeater instances, so the breadcrumb occupies no layout space. Done in Python rather than with
a `position.display` expression on purpose — it keeps `len()`-over-a-list-of-dicts out of the
expression language entirely (cf. `feedback_ignition_no_foreach_in_expressions`).

**`crumbs()` instances are flat dicts**, not the `{'row': {...}}` wrapper ParentRow / ChildRow
use. Those row views declare a single `row` param; CrumbChip declares its five params
individually, and flex-repeater instance keys map straight onto view params.

### Elision

The stored trail is hard-capped at `MAX_STORED = 25` (oldest dropped). Only the last
`MAX_CRUMBS = 5` render; an elided trail gets a leading inert `...` chip. The cap on rendering
is purely presentational, so the underlying trail stays honest.

### Value unwrapping

`session.custom.lotTrail` and `view.params.row` both read back as `QualifiedValue` wrapping
`ImmutableMap`. `extractQualifiedValues` unwraps the outer layer but **not** `ImmutableMap`, so
`.get(...)` raises `AttributeError` (`feedback_ignition_immutable_map_unwrap`). `LotTrail._plain`
round-trips through `system.util.jsonEncode` / `jsonDecode` for plain dicts, mirroring
`BlueRidge.Lots.Lot._tallyRows`. LOT ids are normalized through `_asId` so trail comparisons
never miss on `Long`-vs-`str` alone.

## `Views/ShopFloor/LotDetail/view.json` — the three changes

Applied by targeted text surgery, **not** parse-mutate-redump: this file carries inconsistent
legacy indentation, so a whole-file re-serialize would have normalized 72 KB and guaranteed a
conflict with the concurrent agent editing the same view. Only the `TitleBlock.children` array
and the `load()` script string were rewritten; a structural before/after comparison with those
two spans elided confirmed the rest of the view is byte-identical.

**1. `root.scripts.customMethods[load]`** — append one line at the end:

```python
BlueRidge.Lots.LotTrail.sync(self.session, lotId, self.view.custom.lot)
```

**2. Header restructure.** `TitleBlock` is `direction: column`, so a breadcrumb added as a
sibling of `Meta` lands *below* it. Wrap both in a row:

```
TitleBlock (column)
├─ Title                                   (unchanged)
└─ MetaRow (row, alignItems: center, gap 12px)        ← new
   ├─ Meta                                 (unchanged binding, moved down one level)
   └─ Breadcrumb                           ← new
```

**3. `Breadcrumb`** — `ia.display.flex-repeater`, `direction: "row"`,
`path: BlueRidge/Components/PlantFloor/LotDetail/CrumbChip`, `useDefaultViewWidth: false`,
`style.classes: "pf-breadcrumb"`, with `props.instances` bound `type: property` to
`session.custom.lotTrail` plus a script transform:

```python
return BlueRidge.Lots.LotTrail.crumbs(value, self.view.params.lotId)
```

## Verification

No SQL touched, so the test suite is unaffected. Static checks: every touched/new JSON file
parses with no BOM, `code.py` AST-parses, both new files are pure ASCII, the 51 pre-existing
`=` escapes in `LotDetail/view.json` survived, and `scan.ps1` returned clean.

**Live smoke, run against the local gateway 2026-08-25** (`MPP_MES_Dev`, LOT `000000024-04`
id 10274 → its consumed casting `000000024` id 10267). Driven by scripted DOM interaction —
the in-app browser pane does not composite, so screenshots were unavailable, but real click
events and DOM/computed-style reads work:

| # | Check | Result |
|---|---|---|
| 1 | LOT opened directly by URL | No breadcrumb — `crumbs()` returned `[]` at trail length 1 |
| 2 | Genealogy tab → click parent row | Navigated to `/lot-detail/10267`; header became `LOT Detail · 000000024` |
| 3 | Breadcrumb after the hop | Two chips: `000000024-04` as `psc-pf-crumb-link`, `000000024` as `psc-pf-current` |
| 4 | Flex-repeater sizing (the main layout risk) | `display: flex`, 184 × 28 px, chips content-sized 98 px / 76 px, no clipping |
| 5 | Leading separator suppressed by `isFirst` | First `.psc-pf-sep` computed `display: none` (width 0); second visible |
| 6 | Click the `000000024-04` crumb | Navigated back to `/lot-detail/10274`; trail truncated to one entry, breadcrumb chips `[]` |
| 7 | Arrive by direct URL with a live trail (D3 reset) | Trail `[10274, 10267]`, navigated to 10274 → reset to `[10274]`, breadcrumb gone |
| 8 | Gateway log across the whole sequence | `LotTrail.sync()` at 10274 → 10267 → 10274 → 10267 → 10274, zero exceptions |

Not exercised live: the `MAX_CRUMBS = 5` elision chip and `MAX_STORED = 25` cap (Dev has no
genealogy chain deep enough), and the mid-trail refresh path (item 7 of the original plan —
`load()` re-running after a hold / scrap / count change).

## Rejected alternatives

- **In-place `view.params.lotId` write instead of `navigate()`** — no URL change, so the
  displayed LOT and the deep link diverge; breaks refresh and back-button.
- **Trail seeded by passing `fromLotId` down into the row views** — needs extra repeater
  instance params in LotDetail and extra params on both row views. Unnecessary once the tail
  invariant holds.
- **`position.display` expression to hide the empty breadcrumb** — replaced by `crumbs()`
  returning `[]`, which avoids list handling in the expression language.
- **Front-dropping the stored trail at `MAX_CRUMBS`** — would make dropped ancestors invisible
  to the revisit-truncation check, producing duplicate crumbs. Cap rendering, not storage.
