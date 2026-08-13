# Hold Management Redesign — Design Spec

**Date:** 2026-08-13
**Author:** Blue Ridge Automation (Jacques Potgieter, with Claude)
**Status:** Approved for planning
**Scope tag:** MVP (Arc 2 Phase 7 — Hold / FDS-08-006, FDS-08-007a)

## Problem

Two front-end defects in the existing Hold subsystem:

1. **Place Hold does not work from LOT Detail.** The `BtnPlaceHold` button on
   `ShopFloor/LotDetail` is hardcoded `enabled: false` with tooltip *"Place Hold
   is a later phase action."* It was never wired. (Its sibling `BtnScrap` is dead
   the same way.) Only **Release Hold** is live on LOT Detail.

2. **Hold Management is one massive scrolling view.** `ShopFloor/HoldManagement`
   is a single `overflowY: auto` column stacking seven panels top-to-bottom:
   Filter · Open LOTs + Open Containers (two columns) · Place Hold form · Container
   Advisory · Scrap-Held-LOT form · Bulk Hold · Release Hold form. Much of it is
   clumsy re-entry of context the operator already has — typing a LOT name to place
   or scrap, hand-entering a Hold Event Id integer to release.

**The backend is not the problem.** `Quality.Hold_Place`, `Quality.Hold_Release`,
`Quality.Hold_ListOpen`, `Quality.Hold_ListAssociatedContainers` procs and the
`BlueRidge.Quality.Hold` Python wrappers (`place`, `release`, `placeBulk`,
`getOpenByLot(One)`, `getOpenByContainer`, `listOpen`, `listAssociatedContainers`)
are all implemented and covered by tests under
`sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/`. This is purely a Perspective
front-end restructure with a possible thin Python wrapper addition.

## Goals

- Wire a working place-and-release-hold experience onto LOT Detail.
- Break Hold Management into a tabbed, master-detail layout that eliminates the
  single-scroll wall and the redundant type-a-name / type-an-Id forms.
- Do it once: build **one reusable component** used verbatim in both hosts.

## Non-goals

- No SQL schema or proc changes (procs already exist and are tested).
- No new elevation/AD flow — mirror the existing session-`appUserId` pattern the
  live Release Hold and CRT buttons already use.
- Scrap-Held-LOT is **not** added to LOT Detail. It stays a Hold-Management
  ("Bulk & Scrap" tab) concern.
- No change to AIM PlaceOnHold async dispatch or the container-advisory business
  logic.

## Architecture

### Component 1 (new) — `BlueRidge/Components/PlantFloor/Quality/HoldPanel`

The single reusable place/release sub-view, embedded in both hosts.

**Params (input-only** — per the embed-params-input-only rule; the component
never writes back through params):

| Param         | Type   | Meaning |
|---------------|--------|---------|
| `lotId`       | BIGINT | Bound LOT target (0/null = none) |
| `containerId` | BIGINT | Bound Container target (0/null = none) |
| `allowLookup` | bool   | When true and no bound target, show the target-entry front door |

**Internal state** (`view.custom`, each with a fully-shaped default per the
pre-declared-bound-props rule):

- `state.target` — `{kind: "lot"|"container"|null, id, label}` resolved target.
- `state.hold` — shaped hold dict from `getOpenByLotOne` / container equivalent:
  `{IsHeld, Id, HoldTypeCode, Reason, PlacedByInitials, PlacedAt}` (shaped-empty
  `{IsHeld: false, ...nulls}` when not held).
- `state.placeDraft` — `{holdTypeCodeId, reason}`.
- `state.releaseDraft` — `{releaseRemarks}`.
- `state.lookupDraft` — `{lotName, containerId}` (only used when `allowLookup`).
- `holdTypeOptions` — the three hold types (Quality=1, Customer Complaint=2,
  Precautionary=3), as today.

**Behavior / render states:**

1. **No target + `allowLookup`** → show a compact target row: LOT name (scan/type)
   **or** Container Id, plus a "Load" action. Resolving a LOT name goes through
   `BlueRidge.Lots.Lot.getByName`; a container id is used directly. Exactly one of
   the two, mirroring the current Place-Hold validation. On resolve, set
   `state.target` and re-read the hold.
2. **Target resolved, not held** → hold-type dropdown + reason field + **Place
   hold** button → `BlueRidge.Quality.Hold.place(holdTypeCodeId, lotId=…,
   containerId=…, reason=…, appUserId=session, terminalLocationId=session term)`.
3. **Target resolved, held** → read-only summary (type · placed-by initials ·
   ET time · reason) + release-remarks field + **Release hold** button →
   `BlueRidge.Quality.Hold.release(holdEventId, releaseRemarks=…, appUserId, term)`.

**On any successful place/release:** emit a page-scoped message
`holdChanged` with payload `{lotId, containerId, action: "placed"|"released",
holdEventId}`, then re-read the component's own hold state. The host listens and
reloads its data (LOT Detail `load()`, Hold Management list refresh token).

**Container advisory (FAT-QH-170):** after a successful **LOT** place, the
component calls `Hold.listAssociatedContainers(lotId)`; if non-empty it raises a
`BlueRidge.Common.Ui`/`Notify` toast ("N associated container(s) — review whether
they need holding too"). The verbose yellow advisory panel is dropped; the toast
carries the same warning. (Hold Management no longer needs the standalone advisory
panel.)

**No business logic in the component** — every DB touch routes through the
existing `BlueRidge.Quality.Hold` / `BlueRidge.Lots.Lot` wrappers, consistent with
the no-business-logic-in-Python rule (the component only orchestrates UI).

### Component 2 (thin addition, if needed) — `Hold.getOpenByContainerOne`

`getOpenByLotOne` exists (shaped single-hold dict for the bound-LOT state). The
panel needs the same shape for a bound **container** target. Add a sibling Python
wrapper in `BlueRidge/Quality/Hold/code.py`:

```python
def getOpenByContainerOne(containerId):
    rows = getOpenByContainer(containerId) or []
    if rows:
        h = dict(rows[0]); h["IsHeld"] = True; return h
    return {"IsHeld": False, "Id": None, "HoldTypeCode": None, "Reason": None, "PlacedAt": None}
```

No SQL change — it reuses the existing `Hold_GetOpenByContainer` NQ. (Verify that
NQ returns a `Reason` column shape compatible with the panel; add columns to the
existing read proc only if a needed display field is missing — display-only, no
behavioral change.)

### Host 1 — `ShopFloor/HoldManagement` (rebuild as 2-tab master-detail)

Replace the seven-panel scroll with an `ia.container.tab` (panes mapped by
`position.tabIndex`, per the tab-pane-tabindex rule; styled via
`menuStyle`/`contentStyle`/`tabStyle.classes` like LOT Detail).

**Tab 0 — "Open Holds":** two-column flex.
- **Left (master):** the filter row (text + hold-type dropdown, unchanged bindings
  over `Hold_ListOpen`) above a **single unified list** of open holds — LOTs *and*
  containers in one repeater (kills the current two-column LOT/Container split).
  Each row shows target label, hold type · reason, `#HoldEventId` pill, placed-by
  initials + ET time. Row click selects → sends a page-scoped `holdRowSelected`
  `{lotId, containerId}` to the view. A **"New hold"** button clears the selection
  and puts the panel in lookup mode. Reuse/adapt the existing
  `Quality/HoldRow` component; drop its per-row "Release"/"View"/"Select" buttons
  in favor of whole-row selection driving the detail panel.
- **Right (detail):** an embedded `HoldPanel`. When a row is selected, the view
  passes that row's `lotId`/`containerId` with `allowLookup=false` (release path).
  For "New hold", pass no target + `allowLookup=true` (place path with lookup).
- The view handles `holdChanged` (from the panel) and post-select by bumping its
  `refreshToken` so the list re-reads.

**Tab 1 — "Bulk & Scrap":** the existing **Bulk Hold** (search → multi-select via
`BulkResultRow` → `placeBulk`) and **Scrap-Held-LOT** (`RejectEvent.record` with
`allowHeldLot=True`) panels, moved onto this tab **unchanged** in behavior.

**Removed from the view:** standalone Place-Hold form, type-a-Hold-Event-Id
Release form, separate Open-Containers column, standalone Container-Advisory panel
(now a toast from the panel).

### Host 2 — `ShopFloor/LotDetail` (add a Hold tab, remove dead buttons)

- Add a **"Hold"** tab to the existing `TabContainer` (currently History ·
  Genealogy · Paused-at · Linked Container · Inspections → append at `tabIndex 5`).
  Pane hosts `HoldPanel` with `lotId = view.params.lotId`, `containerId = 0`,
  `allowLookup = false`.
- The tab listens for the panel's `holdChanged` and calls `view.rootContainer.load()`
  so the header **hold pill** (`view.custom.hold`) updates.
- **Remove** the dead `BtnPlaceHold` and `BtnScrap` header buttons. The existing
  header hold **pill** stays. The existing header **Release Hold** button (live
  today) is **removed from the header** — release now lives inside the Hold tab —
  OR kept as a header shortcut; default: remove it from the header to avoid two
  release entry points (single source of truth = the Hold tab). *(Open the plan
  with this as the one small either/or to confirm during implementation.)*
- CRT buttons (`BtnSetCrt`/`BtnClearCrt`) are unaffected.

## Data flow

```
LOT Detail "Hold" tab                Hold Management "Open Holds"
   HoldPanel(lotId=X)                   list(Hold_ListOpen) --select--> HoldPanel(lotId/containerId)
        |                                                                    |
        | place/release via BlueRidge.Quality.Hold.*                         |
        v                                                                    v
   Quality.Hold_Place / Hold_Release  (existing, tested procs)  -----------------
        |
        | success -> page-scoped "holdChanged"
        v
   host reloads (LotDetail.load / HoldManagement.refreshToken++)
```

## Error handling

- All wrapper calls return the standard `{Status, Message, NewId}` status row;
  the panel surfaces them through `BlueRidge.Common.Ui.notifyResult` (existing
  toast convention).
- Panel validation before calling place: target resolved, hold type selected,
  exactly one of LOT/container — mirroring the current Place-Hold guard clauses.
- "Already on hold" / "not found" rejections come from the proc and toast verbatim.
- Bound-target reads that return the shaped-empty hold render the place state (not
  an error) — the shaped-empty dict keeps bindings Quality-Good.

## Testing

- **SQL:** no new procs; existing `0029_PlantFloor_Hold_Sort_Shipping_Aim` tests
  continue to cover place/release/list/associated-containers. If a read proc gains
  a display column, extend its test's expected shape.
- **Component:** manual render-verify in Designer + `.\scan.ps1`; confirm both
  states (place / release), lookup front door, and the `holdChanged` round-trip.
  Per the browser-input-commit limit, verify actual place/release **submits** via
  SQL/proc inspection, not the in-app browser.
- **Regression:** LOT Detail header pill updates after place/release; Hold
  Management list refreshes after panel action and after bulk/scrap.

## Files

**New:**
- `ignition/projects/MPP/.../views/BlueRidge/Components/PlantFloor/Quality/HoldPanel/view.json` (+ `resource.json`)

**Modified:**
- `ignition/projects/Core/.../script-python/BlueRidge/Quality/Hold/code.py` — add `getOpenByContainerOne`
- `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/HoldManagement/view.json` — rebuild as 2-tab master-detail
- `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/LotDetail/view.json` — add Hold tab, remove dead buttons
- `ignition/projects/MPP/.../views/BlueRidge/Components/PlantFloor/Quality/HoldRow/view.json` — adapt to whole-row selection (or supersede)

**Possibly modified (display-only):**
- `sql/migrations/repeatable/R__Quality_Hold_ListOpen.sql` — already carries the
  columns the unified list needs (HoldEventId, LotId, LotName, ContainerId,
  ContainerItemPartNumber, HoldTypeCode, Reason, PlacedByInitials, PlacedAt); no
  change expected.

## Open questions (resolve during planning)

1. LOT Detail header **Release Hold** button — remove (single entry point via Hold
   tab) or keep as a shortcut? Default: remove.
2. `Hold_GetOpenByContainer` column parity for the panel's bound-container summary
   (placed-by / time) — confirm on read; extend the read proc display columns only
   if a field is missing.

## Rollout

Single branch on `jacques/working`. Component first, then Hold Management rebuild,
then LOT Detail tab. `.\scan.ps1` after each Ignition resource change; explicit-path
git staging.
