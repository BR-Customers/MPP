# Pass-Through Parts Screen — Design Spec

**Date:** 2026-08-06
**Status:** Approved (design) — ready for an implementation plan
**Author:** Blue Ridge Automation
**Arc / Phase:** Arc 2 (Plant Floor) — retargets the existing `ThirdPartyInspection` station view.
**Supersedes (in part):** `docs/superpowers/specs/2026-07-23-inspection-station-third-party-receiving-design.md` §7.1 — that spec's
three-panel check-in → inspect → check-out shape is reduced to two tabs. Its scope determination (§2) and its
"compose from MVP primitives, no new subsystem" conclusion still hold.

---

## 1. Goal

An operator at a pass-through station must be able to **create a LOT for a vendor-supplied part and then consume that
LOT into a finished good on the same screen**, without navigating away.

The screen is two tabs: **Inventory** (receive the pass-through part, print its LTT, see what is on hand) and
**Assembly** (build the finished good that consumes it).

---

## 2. Current state

### 2.1 The screen already exists — as three tabs

`ignition/projects/MPP/.../Views/ShopFloor/ThirdPartyInspection/view.json` (2.8 KB) is a pure tab shell at
`/shop-floor/third-party-inspection`, passing no params to any embed and holding no state:

| Tab | Embeds |
|---|---|
| Check In | `ShopFloor/ReceivingDock` |
| Inspect | `ShopFloor/InspectionEntry` |
| Check Out | `ShopFloor/AssemblyNonSerialized` |

It is seeded as the `DefaultScreen` for terminals `INSP-SORT-T1` and `66B - Ins` in **three** places:
`sql/seeds/011_seed_locations_mpp_plant.sql:923`, `sql/scripts/reconcile_location_dev.sql:1100`, and the generator
`sql/seeds/gen_locations_mpp.js:79`.

### 2.2 The backend is complete

| Capability | Where | Status |
|---|---|---|
| Mint a `Received`-origin pass-through LOT | `Lots.Lot_Create` | built |
| Eligibility, `MaxLotSize`, `MaxParts` gates | `Lot_Create` (`MaxParts` is Received-origin only, added 2026-08-04) | built |
| On-hand at a location, grouped by part, FIFO by arrival | `Lots.Lot_GetLineInventoryByPart` | built |
| Consume a pass-through LOT into an FG | `Workorder.Assembly_CompleteTray` — the BOM×qty FIFO walk has **no `ItemType` filter** | built |
| Projected consumption (display-only) | `Workorder.Assembly_GetComponentProjection` | built |
| LTT render + dispatch | `Lots.LotLabel_Print` + `BlueRidge.Lots.LotLabel.printLabel` | built |

**Eligibility is automatic for pass-through components.** `Parts.v_EffectiveItemLocation`'s **BomDerived** path exists
precisely so a 20-line BOM across N cells does not need 20N `ItemLocation` rows (FDS-02-012). A pass-through item is
eligible at a station because it is a child line on a published BOM of an item with Direct eligibility there.

### 2.3 Two concerns investigated and dismissed

Recorded so they are not re-raised:

- **`session.custom.cell` collision — does not occur.** `ReceivingDock.startup()` and `AssemblyNonSerialized`'s root
  `onStartup` both write `session.custom.cell = {locationId: terminal.zoneLocationId, code/name: zoneName}`. Identical
  values; execution order is irrelevant.
- **Mint-location vs consume-location mismatch — does not occur.** `createLot()` mints at `cell.locationId`;
  `handleTrayComplete` passes `session.custom.cell.locationId` as `@CellLocationId`. `Assembly_CompleteTray` filters
  `l.CurrentLocationId = @CellLocationId` (exact cell, no descendant cascade) — and that is the same id. This equality
  is what makes "receive, then assemble" work with no movement step, and it is load-bearing.
- **LTT printing works.** The `TODO(phase4)` comment in `createLot` is stale: `LotLabel.printLabel` default-resolves
  `labelTypeCodeId` to `Primary` and `printReasonCodeId` to `Initial` when the caller passes `None`.

### 2.4 What is actually wrong

1. **`ReceivingDock` navigates away.** `createLot()` ends with `navigate("/shop-floor/lot-detail/<id>")` on a successful
   print, and `CloseButton` calls `navigate("/")`. Either ejects the operator from the tab shell.
2. **`ReceivingDock` never broadcasts `inventoryChanged`.** `AssemblyNonSerialized` carries a page-scoped
   `inventoryChanged` handler that compares `payload.cellLocationId` to its own cell and bumps `refreshToken`; only
   `InventoryManager` sends that message. After a receive, the Assembly tab's component projection is stale.
3. **`ReceivingDock` has no on-hand list.** It is create-only.
4. **The on-hand card lies about status.** `BlueRidge.Lots.Lot.getLineInventoryCards` hardcodes
   `"lotStatusCode": "Good"` (`Lot/code.py:496`) because `Lot_GetLineInventoryByPart` selects no status column. A Hold
   or Scrap LOT renders a green **Good** pill — while `Assembly_CompleteTray` skips it (`sc.BlocksProduction = 0`).
   Pre-existing and shared with the `InventoryManager` popup, but this screen puts the panel front-and-centre.

---

## 3. Decisions locked

1. **Revise `ThirdPartyInspection` in place; do not add a parallel screen.** The Inspect tab is dropped — it is not
   earning its place, and `InspectionEntry` remains reachable at `/shop-floor/inspection` and via LOT Detail's
   `params={lotName}` deep link, so no capability is lost.
2. **Keep the route and the view path** (`/shop-floor/third-party-inspection`,
   `BlueRidge/Views/ShopFloor/ThirdPartyInspection`). Renaming would mean touching all three seeding sites plus a Dev-DB
   update for zero functional gain. Only the `page-config` **title** changes.
3. **The Inventory tab is `ReceivingDock`, not `InventoryManager`** — because the operator needs a **printed LTT** on the
   vendor box, and `InventoryManager`'s receive path deliberately does not print (2026-07-15 loose-parts decision 3).
   `ReceivingDock` is made embed-aware rather than forked.
4. **The Assembly tab stays `AssemblyNonSerialized`.** Matches the customer-confirmed 2026-07-24 shape (bought-in part
   consumed by a newly-minted pass-through FG; FG-style 1 lot → 1 tray → 1 container). A serialized flavour is added
   only if a serialized pass-through station appears.
5. **Fix the status-pill defect (§2.4 item 4) as part of this work**, accepting that it makes the change non-zero-SQL and
   requires a full-suite re-run.
6. **`InventoryManager` is untouched.** It remains the check-in-by-LTT-scan path, reachable from the Assembly tab's
   header `InventoryButton`.

---

## 4. Change inventory

### 4.1 `Views/ShopFloor/ThirdPartyInspection/view.json` — rewrite

```
root (ia.container.flex, direction column, style.classes "canvas", height 100%)
└── TabContainer (ia.container.tab, grow 1, basis 0)
    ├── tab "Inventory" → ia.display.view → BlueRidge/Views/ShopFloor/ReceivingDock
    │                      params: { "embedded": true }
    └── tab "Assembly"  → ia.display.view → BlueRidge/Views/ShopFloor/AssemblyNonSerialized
```

- The `InspectTab` child and its `props.tabs` entry are deleted.
- `runWhileHidden: true` stays on both tabs so each embed's `onStartup` fires on page load, not on first tab click.
- `useDefaultViewHeight: false` / `useDefaultViewWidth: false` and `position.grow: 1` on both embeds (unchanged).
- Tab styling classes are unchanged and already defined in the Core stylesheet:
  `menuStyle.classes: "tab-strip"`, `contentStyle.classes: "tab-content-fill"`,
  `tabStyle.active.classes: "tab-item tab-item-active"`, inactive/disabled `"tab-item"`.

### 4.2 `Views/ShopFloor/ReceivingDock/view.json` — gains an `embedded` mode

New `params.embedded` defaulting to `false`, **with an explicit `propConfig` entry**:

```json
"propConfig": { "params.embedded": { "paramDirection": "input" } }
```

A `params`-block default alone never receives an embed-passed value — the `paramDirection` declaration is required.
Standalone `/shop-floor/receiving` receives the default and is unchanged in every respect.

New `view.custom.refreshToken: 0` (inert when standalone).

| Change | Gated on `embedded` |
|---|---|
| `createLot()` suppresses `navigate("/shop-floor/lot-detail/…")`; calls `resetForm()` and bumps `refreshToken` in place | yes |
| `createLot()` sends page-scoped `inventoryChanged` with `{"cellLocationId": cell.locationId}` **immediately after LOT creation succeeds, before the print call** — so a print failure still refreshes the sibling tab | yes |
| `CloseButton` hidden — bind `position.display` to the expression `{view.params.embedded} = false` (`position.display`, not `meta.visible`, so it leaves the flex row entirely) | yes |
| New **On hand at this station** panel (§4.3) — its container binds `position.display` to `{view.params.embedded}` | yes |
| `view.custom.refreshToken` declared | always |

The rest of `createLot()` — part resolution, int coercion, `Lot.create`, `notifyResult`, the print call, the
`printFailed` / `lastLabelLotId` handling, `reprintLast()` — is unchanged.

### 4.3 The on-hand panel

A direct lift of `InventoryManager`'s, which is already a solved shape:

```
ia.display.flex-repeater
  props.instances ← expr:
    runScript("BlueRidge.Lots.Lot.getLineInventoryCards", 0,
              {session.custom.cell.locationId}, {view.custom.refreshToken})
  props.path: "BlueRidge/Components/PlantFloor/Trim/InventoryRow"
  props.elementPosition: { basis: "92px", shrink: 0 }
  props.direction: "column", style.gap "8px", style.overflowY "auto"
```

`refreshToken` is passed **as an argument**, not merely referenced in a surrounding condition — `runScript` caches on
its args, so a token outside the arg list never re-executes. `getLineInventoryCards` already returns display-only cards
(`selectable: false`), so `InventoryRow`'s `SelectButton` stays hidden and its `trimLotSelected` message never fires.

The panel is gated on `embedded` to keep the standalone Receiving Dock unchanged. Un-gating it later is a one-line
change if the dock wants the same view of its own floor.

### 4.4 The status-pill fix

**`sql/migrations/repeatable/R__Lots_Lot_GetLineInventoryByPart.sql`** — append one column to the SELECT, after
`ArrivedAt`:

```sql
sc.Code AS LotStatusCode
```

`sc` is already joined (`INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId` — it backs the `<> 'Closed'`
filter), so this is a projection change only: no new join, no filter change, no ordering change. Bump the header to
v1.1 with the reason. Appended rather than inserted mid-list to minimise churn for positional readers.

**`ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py:496`** —

```python
"lotStatusCode": r.get("LotStatusCode") or "",
```

replacing the hardcoded `"Good"`. `Trim/InventoryRow` already binds `params.lotStatusCode` to its `StatusPill`, so a
Hold LOT renders correctly with no view change.

**Named query `lots/Lot_GetLineInventoryByPart`** — unchanged. It is a thin `EXEC` wrapper and `Common.Db.execList`
maps by column name, not position.

### 4.5 Three fixed-shape captures to widen

| File | Capture |
|---|---|
| `sql/tests/0027_PlantFloor_Machining/100_Lot_GetLineInventoryByPart.sql:78` | `#inv` temp table **and** its explicit INSERT column list (the table has an `IDENTITY Seq`, so both halves need the new column) |
| `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/090_FinishedGoodClose_OnComplete.sql:66` | `@InvBefore` |
| same file, ~line 92 | `@InvAfter` |

Plus **one new assertion** in `100_Lot_GetLineInventoryByPart.sql`: place a hold on an on-hand LOT, re-read, assert
`LotStatusCode = 'Hold'`. Without it the new column ships untested.

### 4.6 `page-config/config.json`

Title only: `"Third-Party Inspection"` → `"Pass-Through Parts"`. The route key is unchanged.

### 4.7 Explicitly not touched

- Any seed file or `gen_locations_mpp.js` — the route string is unchanged, so all three seeding sites stay valid and Dev
  needs no update.
- `AssemblyNonSerialized`, `AssemblySerialized`, `AssemblyIn` — no changes; the `inventoryChanged` handler already exists.
- `Components/PlantFloor/InventoryManager` — no changes.
- `InspectionEntry` — no changes.

---

## 5. Data flow

```
Terminal loads /shop-floor/third-party-inspection
  ├─ both embeds' onStartup → session.custom.cell = terminal.zoneLocationId
  └─ no appUserId → mpp-initials popup (same popup id from both embeds → one popup)

Inventory tab                                  Assembly tab
─────────────                                  ────────────
part# + vendor lot + qty [+ serial range]
  → Lot.create(Received, cell.locationId)
      ├─ sendMessage("inventoryChanged",  ──────►  handler compares payload.cellLocationId
      │    {cellLocationId}, scope "page")         to its own cell → refreshToken++
      │                                            → component projection re-reads
      ├─ LotLabel.printLabel(lotId, None, None)
      │    → defaults Primary / Initial → ZPL → session.custom.printer
      └─ resetForm(); refreshToken++
           → on-hand panel shows the new LOT

                                               pick FG → parts count → Close Tray
                                                 → Assembly_CompleteTray(
                                                     @CellLocationId = session.custom.cell.locationId)
                                                 → BOM×qty FIFO consume from that exact cell
                                                 → FG LOT minted, Consumption genealogy (RelationshipTypeId=3)
                                                 → tray → container → Complete → AIM shipper id + label
```

---

## 6. Gates and error handling

### 6.1 Server-side gates, surfaced by `notifyResult`

`Lot_Create` rejects, in order: **eligibility** (`Parts.v_EffectiveItemLocation`, Direct ∪ BomDerived,
ancestor-cascaded via `Location.ufn_AncestorLocationIds`), **`PieceCount ≤ Item.MaxLotSize`**, **`MaxParts` at the
location** (Received-origin only — production mints are never halted on a full location). The view performs no
eligibility check; it does only part-number resolution and int coercion.

`Assembly_CompleteTray` pre-checks FIFO stock sufficiency per BOM line and returns a short-list message naming the
short component(s); the consume walk excludes `sc.BlocksProduction = 1` (Hold/Scrap) statuses.

### 6.2 Configuration preconditions — what will actually fail on the floor

1. **The pass-through item must be a child line on a *published* BOM of a finished good that has Direct
   `ItemLocation` eligibility at the station.** That single fact does double duty: it is what lets `Lot_Create` accept
   the receive (BomDerived path) *and* what lets `Assembly_CompleteTray` consume it. Missing either half yields
   `Item is not eligible at the specified location.`
2. The station terminal needs a printer whose `LabelTypes` attribute covers the LTT, plus an active `Primary`
   `LabelTemplate` — otherwise every receive ends in `printFailed`. The LOT still exists and is still consumable; the
   banner offers Reprint.
3. The finished good needs a `Parts.ContainerConfig` row for the terminal's closure method — `Assembly_CompleteTray`
   resolves by `(ItemId, ClosureMethod)` with **no fallback**.

### 6.3 Failure modes carried over unchanged

- **Fallback / unregistered terminal.** `zoneLocationId` resolves to the whole Madison Facility, so the mint, the
  on-hand read, and the consume all happen at the Facility node. `Parts.v_EffectiveItemLocation` anchors both its
  Direct and BomDerived legs to `ItemLocation.LocationId`, and `Location.ufn_AncestorLocationIds` only walks
  *upward* — so the Facility's ancestor set contains no configured cell. `Lot_Create` and `Assembly_CompleteTray`
  both **fail closed** with an operator-visible message (`Item is not eligible at the specified location.` /
  `Finished-good Item is not eligible at this cell.`), not open eligibility. The only silent surface is the on-hand
  panel, which returns an empty list — the `ReceivingDock` subtitle already renders "No cell selected" in that
  state. The subtitle reading "Madison Facility" is the tell. Affects both tabs identically; neither improved nor
  worsened here.
- **Print failure.** `printFailed = True` + `lastLabelLotId` → `PrintFailureBanner` + Reprint. Because the broadcast
  fires before the print, the Assembly tab refreshes even when the label fails.
- **Duplicate initials popup.** Both embeds call `openPopup("mpp-initials", …)` with the same popup id. This is
  pre-existing behaviour of the current three-tab shell; verify in smoke that exactly one popup appears.

---

## 7. Verification

### 7.1 SQL — full suite, not filtered

Run the whole `MPP_MES_Test` suite and compare the assertion count against the current baseline. Per the fixed-shape
`INSERT-EXEC` hazard, a filtered run **passes even when a capture is broken** — a widened result set surfaces as
`Msg 213` and a runner exit-1, not a `FAIL:` line. Grep for **both** `FAIL:` and `ERROR running`.

### 7.2 Ignition — file-authored, Designer closed, then `scan.ps1`

`ThirdPartyInspection` is a small rewrite (new-view-scale). `ReceivingDock` is an existing ~23 KB view, so its edits go
through verified Python string-splices with a `json.loads` round-trip and a JSON-walk check — **not** the Edit tool,
because Designer's `=` / `'` escapes fight literal-string matching. If Designer is open on either view, file
edits will be silently reverted (observed twice on 2026-08-05).

### 7.3 Gateway smoke — the step that finds the real defects

Every defect in the 2026-08-05 AIM pass survived SQL testing and code review and was found only by driving the screen.

1. Terminal opens the screen → two tabs; subtitle shows the real zone (**not** "Madison Facility"); the initials popup
   appears exactly once.
2. Inventory tab: receive an eligible pass-through part → success toast, LTT prints, form clears, **no navigation**, the
   LOT appears in the on-hand panel.
3. Switch to Assembly → the component projection already reflects the receive. *(Proves the `inventoryChanged`
   broadcast landed — a design-level check.)*
4. Close a tray consuming that part → FG LOT minted; LOT Detail genealogy shows the pass-through LOT as a `Consumption`
   child.
5. Rejection paths: ineligible part; qty over `MaxLotSize`; qty over the location's `MaxParts` → error toast, no LOT
   minted.
6. Place a hold on an on-hand LOT → the panel's pill reads **Hold**, and a tray close short-lists that part.
   *(Proves the §4.4 fix — a design-level check.)*
7. Standalone `/shop-floor/receiving` regression: still navigates to LOT Detail on success, still shows Close, shows no
   on-hand panel. *(Proves `embedded` defaults to false — a design-level check.)*
8. Print-failure path: banner + Reprint appear, and the Assembly tab still refreshed.

Steps 3, 6 and 7 are the ones that would catch a wrong design; the rest are confirmation.

---

## 8. Scope note

`reference/MPP_Scope_Matrix.xlsx` row 3 (Production · Receiving, pass-through included) is **MVP**. Row 20
(Traceability · Pass-through Parts Tracking) is marked MVP with a **"Future"** note, and
`MPP_MES_USER_JOURNEYS.md:361` reads that note as covering *dedicated operational screens* — receiving inspection,
vendor-lot verification, staging procedures — rather than the underlying tracking capability.

This work sits on that line. It is defensible as MVP because it builds **no new capability**: every proc it calls is
already MVP-scoped and already built, and the change is one tab shell plus an embed flag. But it is a
pass-through-specific screen, which is the category row 20 defers. **Flag it to MPP as a scope confirmation** rather
than assuming it; if they read row 20 strictly, the work is still small enough to hold.

What this design does **not** build, and should not: routing pass-through LOTs through machining/assembly WIP queues,
`OperationRoleKind` participation, or any downstream in-plant tracking workflow. Received parts stay unrouted.

---

## 9. Assumptions

- **A1** — The station terminal's `zoneLocationId` is the cell where assembly happens. This is what makes the receive
  and the consume agree. False on a fallback terminal (§6.3) and false if a station is ever configured with a zone above
  its assembly cell. **Confirm during smoke step 1.**
- **A2** — Pass-through parts at these stations are consumed into a finished good on the same screen, not moved
  elsewhere first. If they must be staged, the `InventoryManager` LTT-scan check-in on the Assembly tab covers it.
- **A3** — `AssemblyNonSerialized` is the right flavour for every pass-through station (decision 4). One serialized
  station would require the flavour switch that decision deferred.
- **A4** — Dropping the Inspect tab loses nothing, because `/shop-floor/inspection` and the LOT Detail deep link remain.
  If operators discovered inspection *only* through that tab, discoverability regresses. **Worth asking MPP.**

---

## 10. Revision history

| Version | Date | Author | Change |
|---|---|---|---|
| 1.0 | 2026-08-06 | Blue Ridge Automation | Initial design. Approved section-by-section in dialogue. |
