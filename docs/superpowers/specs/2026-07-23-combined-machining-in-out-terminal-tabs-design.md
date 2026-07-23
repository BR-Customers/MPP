# Combined Machining IN / OUT terminal — tabbed shell

**Date:** 2026-07-23
**Status:** Design note + implementation plan (no code written)
**Author:** Blue Ridge (design only)

## 1. Problem & locked decision

One physical terminal on a machining line runs **both** Machining IN (pick a casting off
the FIFO queue) and Machining OUT (mint the SubAssembly / sub-LOT split). Rather than
route the operator between two page URLs, we give that terminal a single page whose two
**tabs** are the existing, tested views.

**Locked decision (customer-requested, endorsed):** build a NEW shell view that embeds the
EXISTING `MachiningIn` and `MachiningOutSplit` views as two tabs. Do **not** author a
bespoke unified machining view, and do **not** modify the two embedded views. Reuse buys
us the already-validated queue logic, mint/split proc calls, popups, and message wiring for
free.

## 2. What the two views already are (grounding)

| | Machining IN | Machining OUT |
|---|---|---|
| Resource | `BlueRidge/Views/ShopFloor/MachiningIn` | `BlueRidge/Views/ShopFloor/MachiningOutSplit` |
| Route today | `/shop-floor/machining-in` | `/shop-floor/machining-out` |
| Queue source | `getWipQueueByLocation(0, {session.custom.cell.locationId}, true, token, "MachiningIn")` | `getWipQueueByLocation(0, {session.custom.cell.locationId}, true, token, "MachiningOut")` |
| Params | `"params": {}` — **none** | `"params": {}` — **none** |
| Reads context from | `session.custom.cell` / `session.custom.terminal` / `session.custom.appUserId` | same |
| `onStartup` | binds `session.custom.cell = {locationId: terminal.zoneLocationId, …}`, sets presence policy, opens Initials popup if no operator | **identical** onStartup body |

The decisive facts for this feature:

1. **Both views read the session directly and take no params.** They resolve their queue
   from `session.custom.cell.locationId`, which each view's `onStartup` sets from
   `session.custom.terminal.zoneLocationId`. Embedding them requires **zero** param plumbing
   — the shell does not pass `itemId`/`value` the way Item Master does.
2. **Both queues are the same location, different role code.** IN passes role `"MachiningIn"`,
   OUT passes role `"MachiningOut"`, against the *same* `cell.locationId`. Role-scoping is
   the route's job (per the terminal-mint model: `OperationRoleKind` + lowest-pending route
   step), so one line-resident location legitimately serves both queues.
3. Both views' message handlers are `pageScope: true`. Message types are disjoint
   (`machiningPick` / `bomRenameResult` only in IN; `machiningOutSelected` /
   `moPartialConfirmed` only in OUT) **except** `inventoryChanged`, which both handle by
   refreshing — harmless when both are mounted on one page.

## 3. New view structure

**New view:** `BlueRidge/Views/ShopFloor/MachiningStation` (file-edit-safe — it is a NEW
view with no Designer cache; per CLAUDE.md § "Ignition file-edit boundary").

Root is a flex column. The only child is an `ia.container.tab` that fills the page, holding
two `ia.display.view` embeds:

```
root (ia.container.flex, column)
└── TabContainer (ia.container.tab, position.grow 1)
    ├── MachiningInTab   (ia.display.view, props.path = "BlueRidge/Views/ShopFloor/MachiningIn",      tabIndex 0)
    └── MachiningOutTab  (ia.display.view, props.path = "BlueRidge/Views/ShopFloor/MachiningOutSplit", tabIndex 1)
```

**Embedded views take NO params** — they read the shared session context directly. So the
embeds are just `{ "type": "ia.display.view", "props": { "path": "…" } }` with a `meta.name`
and (for the OUT embed) `position.tabIndex: 1`. This is *simpler* than the Item Master tab
container, which binds `props.params.value` into each embed; we deliberately omit that.

**Static tab labels** — use the `LotDetail` (ShopFloor) form, not the Item Master runScript
form. `LotDetail` declares `props.tabs` as a literal array; mirror it:

```json
"props": {
  "currentTabIndex": 0,
  "menuType": "modern",
  "tabs": [
    { "text": "Machining IN",  "runWhileHidden": true, "disabled": false },
    { "text": "Machining OUT", "runWhileHidden": true, "disabled": false }
  ],
  "menuStyle":    { "classes": "tab-strip" },
  "contentStyle": { "classes": "tab-content-fill" },
  "tabStyle": {
    "active":   { "classes": "tab-item tab-item-active" },
    "inactive": { "classes": "tab-item" },
    "disabled": { "classes": "tab-item" }
  }
}
```

`runWhileHidden: true` keeps the inactive tab's view **mounted** so its FIFO queue stays
live (and its `onStartup` cell-binding has already run) — the operator sees a current queue
the instant they switch tabs, not a cold load.

### Tab styling — per project convention

Style only through the typed style-class slots the component exposes — `menuStyle.classes`,
`contentStyle.classes`, `tabStyle.{active,inactive,disabled}.classes`, and the container's
own `style.classes` — reusing the existing `tab-strip` / `tab-content-fill` /
`tab-item` / `tab-item-active` classes already defined in the Core stylesheet and used by
LotDetail and Item Master. Do **not** chase Ignition's internal tab DOM class names in CSS
(per the "tab typed style-class slots" convention). No new CSS is required if we reuse the
existing classes.

## 4. Shared session-terminal context (the whole point)

There is one Perspective session per terminal. `session.custom.terminal` /
`session.custom.cell` / `session.custom.appUserId` are **session-scoped**, so both tabs —
being two embedded views in one page in one session — read the *same* terminal binding.
Picking an operator (Initials popup) or a terminal once serves both tabs.

Terminal context is established up front by `BlueRidge.Location.Terminal.applyToSession`
(called from `onStartup` via IP resolution, from the NavigationTree launch, and from the
TerminalSelector). It sets `session.custom.terminal` (incl. `zoneLocationId`), printer, PLC
devices, and closure context, and clears any stale `session.custom.cell`. Each machining
view's own `onStartup` then derives `session.custom.cell` from `terminal.zoneLocationId`.

**Double-`onStartup` note (not a blocker):** with both views mounted, both root
`onStartup` scripts fire. Their bodies are identical and idempotent for the cell binding
(both write the same `cell` from the same `terminal.zoneLocationId`). Both may call
`openPopup("mpp-initials", …)` when no operator is set — same `popupId`, so the second call
targets the same popup instance rather than stacking a duplicate. Acceptable as-is; if a
flicker is observed in test, the mitigation is to let the shell own the initials/presence
bootstrap and leave the embeds' `onStartup` to the (idempotent) cell binding. **Do not**
edit the embedded views to achieve this in v1 — the locked decision is reuse-without-modify;
revisit only if testing shows a real defect.

## 5. Zone-resolution verification — THE ONE REAL RISK

Both tabs call `getWipQueueByLocation` with the **same** `cell.locationId`
(= `terminal.zoneLocationId`) and only differ by role code. Therefore the combined page is
correct **iff** the terminal registered to this page has its `zoneLocationId` resolve to the
machining **line / work center** that carries both a `MachiningIn` and a `MachiningOut`
route-role step for the LOTs living there.

Verify, at terminal-registration time, on the real terminal (not just dev):

- `session.custom.terminal.zoneLocationId` for this physical terminal points at the
  machining **line/WC** location, **not** a narrower sub-cell that only one role sees, and
  **not** the fallback whole-Facility zone. (Per the "Terminal session context + fallback"
  note, an unregistered IP falls back to `zoneLocationId = whole Facility`, which yields a
  plant-wide queue and false "not eligible" behavior — the tell is a subtitle reading
  "Madison Facility".)
- The IN queue and the OUT queue, read against that one `zoneLocationId`, both return the
  expected LOTs for this line — i.e. the zone resolves the **same** line for both roles.

Concretely: register/confirm the terminal row (IP → `TerminalLocation` → zone) so its zone
is the machining line, then load the combined page and confirm both tabs show non-empty,
line-scoped queues (seed a casting via the demo seed if the line is empty). This is the
single verification that gates the feature; everything else is mechanical.

## 6. Route / page-config addition

Add ONE route to `MPP/com.inductiveautomation.perspective/page-config/config.json`:

```json
"/shop-floor/machining": {
  "title": "Machining Station",
  "viewPath": "BlueRidge/Views/ShopFloor/MachiningStation"
}
```

Leave the existing `/shop-floor/machining-in` and `/shop-floor/machining-out` routes in
place — the standalone screens stay available for lines/terminals that only do one role.
Point the combined terminal's default screen (and/or the NavigationTree entry) at
`/shop-floor/machining`. Choosing the default screen per terminal is a
terminal-registration/data concern, not part of this view build.

## 7. Required files (new-view checklist)

A new view folder needs BOTH files or the Gateway reports "View Not Found" (scan does not
synthesize the descriptor):

```
ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/MachiningStation/
├── view.json        (the tab shell above)
└── resource.json    (scope "G", files: ["view.json"])
```

`resource.json` mirrors the other ShopFloor views:

```json
{ "scope": "G", "version": 1, "restricted": false, "overridable": true, "files": ["view.json"] }
```

(The `attributes.lastModification*` block is written by the Gateway on first save; it is not
required in the authored file.)

## 8. Implementation plan

1. **Create the shell view** — write `…/ShopFloor/MachiningStation/view.json` (flex-column
   root → `ia.container.tab` with the two `ia.display.view` embeds, static `tabs`, typed
   style-class slots per §3) and `resource.json` per §7. New-view file edits are safe.
2. **Add the route** — one entry in `page-config/config.json` (§6). Keep the two existing
   machining routes.
3. **Scan** — run `.\scan.ps1` from the repo root (POST the project-scan endpoint; needs
   both `X-Ignition-API-Token` and `Content-Type: application/json`). No Gateway restart.
4. **Verify zone resolution (§5)** — on the combined terminal, confirm `zoneLocationId` is
   the machining line (subtitle is the line name, not "Madison Facility"), then confirm both
   tabs show line-scoped queues (seed a casting if needed). This is the gating check.
5. **Smoke both tabs** — pick a casting on the IN tab (fires the pick → active machined LOT),
   switch to the OUT tab, confirm the parent machined LOT is present and mint/split works,
   and confirm one Initials/operator selection serves both tabs. Watch for a duplicate
   Initials popup on cold start (§4) — log it if seen; do not fix by editing the embeds.
6. **Point the terminal at it** — set the combined terminal's default screen / NavigationTree
   entry to `/shop-floor/machining` (data/registration step, outside this view build).

## 9. Non-goals / explicitly out of scope

- No edits to `MachiningIn` or `MachiningOutSplit` (locked: reuse without modification).
- No new stored procs, named queries, or Python — the shell is pure view + route.
- No new CSS if the existing `tab-strip` / `tab-content-fill` / `tab-item*` classes are
  reused.
- Standalone `/shop-floor/machining-in` and `/shop-floor/machining-out` are retained.

## 10. Open questions

- **Default landing tab.** Land on Machining IN (tabIndex 0)? Assumed yes — the operator
  picks before they mint. Confirm with the customer.
- **Duplicate `onStartup` / Initials popup.** Needs a quick empirical check in §8.5. If it
  double-opens visibly, decide whether to accept it or (later, separately) hoist the
  presence/initials bootstrap into the shell — which *would* touch the embeds and so is
  deferred out of the locked v1.
- **Combined vs. dedicated per terminal.** Which physical machining terminals get the
  combined page vs. the single-role screens is a terminal-registration decision; this design
  only provides the page.
- **`MachiningOutSplit` naming.** The combined page is generic "Machining"; the OUT view is
  the sublotting-split flavor. Confirm every combined-page line is a sublotting line (OUT =
  split), or whether a non-split Machining OUT flavor also needs a combined shell later.
