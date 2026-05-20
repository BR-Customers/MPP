# Item Master Phase 8 — Eligibility Editor — Design Spec

**Date:** 2026-05-20
**Status:** Draft — pending Jacques's review
**Scope:** Phase 8 of the 8-phase Item Master Configuration Tool — wire the Eligibility tab to live `Parts.ItemLocation` data with full FDS-03-014 / FDS-03-015 / FDS-03-018 coverage. Replaces the Phase 1 4-column Cell-list mockup shell with a **two-panel browse-and-map editor** that surfaces all three location tiers (Area / WorkCenter / Cell) and per-row consumption metadata.

This is the final Phase of the Item Master surface. After Phase 8 lands, the `/items` page is feature-complete.

---

## 1. Goals

End-state for Phase 8:

- Opening the Eligibility tab on a selected Item loads all current `Parts.ItemLocation` pairings into the right panel, grouped by tier (Area / WorkCenter / Cell), with consumption metadata inline-expandable per row.
- Engineering can browse any tier — Area, WorkCenter, or Cell — via the left panel. The flex-repeater lists locations matching the picker that are NOT yet mapped. Click a location → it stages on the right side, grouped under its tier section. Metadata defaults from the first existing row.
- Engineering can edit metadata inline (click the row's expand chevron → 4 inputs). Changes accumulate in `editDraft`.
- Engineering clicks **Save** → a new bundled proc commits all staged adds + metadata edits atomically. Dirty indicator clears.
- Engineering can remove a mapped location: click the row body → confirm popup → instant `_Remove` call (no Save required for removals — per the workflow shape Jacques approved).
- Cells under an already-mapped Area show an **"Inherited from Area"** badge so engineering sees the cascade visually. The badge is informational; the Cell row's metadata still wins per FDS-03-018 (Cell-tier row's metadata overrides Area-tier when both exist).

After Phase 8, Phases 1–8 of Item Master are complete. Routes (5) and BOMs (6) versioning workflows are already specced + planned; ContainerConfig save (4) and Quality Specs cross-link (7) remain.

---

## 2. Architecture Decision — Two-Panel Browse-and-Map Editor

Per Jacques's design direction:

- **Left = Browse panel** (the "source"): tier-scoped picker showing candidate locations.
- **Right = Mapped panel** (the "destination"): the eligibility map for this Item, grouped by tier.
- **Add interaction**: click in left → stages in right (in `editDraft`).
- **Save interaction**: bottom bar — commits all staged adds + metadata edits as one bundled proc call.
- **Remove interaction**: click a row in right → confirm popup → instant `_Remove` call.

This is the **first compound editor in the project that splits "add" and "remove" into different commit semantics**. Justification:

| Operation | Semantic | Why |
|---|---|---|
| Add new pairing | Stage + Save | Engineering typically adds many at once ("Part 5G0 eligible on DC-3, DC-7, DC-12, DC-15") — batch commit avoids 4 round-trips and keeps the dirty-indicator pattern intact. |
| Edit metadata | Stage + Save | Same reason — engineer types Min/Max/Default across multiple rows; one Save commits. |
| Remove pairing | Instant on confirm | Engineering removes one at a time, deliberately. Click-then-confirm-then-Save is two extra clicks. Per Jacques: "popup a confirmation… then remove it." |

The hybrid is documented as the **Phase 8 reference pattern** in § 12 for any future editor that needs the same semantic split.

### 2.1 Three-layer rule (unchanged)

```
View bindings        -> view.custom.* (parent state)
view.scripts         -> BlueRidge.Parts.ItemLocation.{stageAdd, removeImmediate, saveAll, ...}
BlueRidge.Parts.*    -> BlueRidge.Common.Db.{execList, execMutation}
BlueRidge.Common.Db  -> the only layer that calls system.db.runNamedQuery
Named Queries        -> EXEC Parts.ItemLocation_{ListByItemWithTier, SaveAll, Remove}
                        EXEC Location.Location_{GetTree, ListByTier}
Stored Procs         -> 1 NEW (ItemLocation_SaveAll), 1 small extension
                        (ItemLocation_ListByItem projects HierarchyLevel + TypeCode)
```

---

## 3. SQL — one new bundled proc + one small extension

### 3.1 Inventory

| Proc | Status | Phase 8 use |
|---|---|---|
| `Parts.ItemLocation_Add` | Exists | Not called from this UI in Phase 8 (SaveAll handles batch adds). Stays callable from Script Console / other consumers. |
| `Parts.ItemLocation_Remove` | Exists | Called by the **instant-remove** flow (click → confirm → fire). |
| `Parts.ItemLocation_SetConsumptionMetadata` | Exists | Not called directly from this UI (SaveAll handles metadata as part of the bundle). Stays callable from Script Console. |
| `Parts.ItemLocation_ListByItem` | **Extend** — add `HierarchyLevel`, `TypeCode`, `ParentLocationId` to projection so UI can group rows by tier and detect Area-parent-of-Cell relationships. | Read path for editor load. |
| `Parts.ItemLocation_ListByLocation` | Exists, untouched | Not used in Phase 8 (inverse view; future Eligibility Map page may use it). |
| `Parts.ItemLocation_SaveAll` | **NEW** | Bundled adds + metadata updates. |
| `Location.Location_GetTree(@RootLocationId)` | Exists | Drives the left panel's Cell/WorkCenter list under a selected Area. |
| `Location.Location_ListByTier('Area')` | Exists | Drives the top-level Area dropdown. |
| `BlueRidge.Location.Location.getAllAreas()` | Exists | Same — already-deployed Ignition helper. |

### 3.2 `Parts.ItemLocation_SaveAll` (NEW)

```sql
CREATE OR ALTER PROCEDURE Parts.ItemLocation_SaveAll
    @ItemId        BIGINT,
    @PairingsJson  NVARCHAR(MAX),   -- list of {Id|null, LocationId, MinQuantity, MaxQuantity, DefaultQuantity, IsConsumptionPoint}
    @AppUserId     BIGINT
AS
```

**Semantics:**

1. Validate `@ItemId` exists + active, `@AppUserId` not null.
2. Parse `@PairingsJson` into a temp table.
3. Validate every incoming row has a non-NULL `LocationId` that resolves to an active `Location.Location`.
4. Validate consumption-metadata sanity per row: non-negative quantities, `Min ≤ Max` when both supplied.
5. Open transaction. For each incoming row:
   - **If `Id` is non-NULL** (existing pairing being updated): `UPDATE Parts.ItemLocation SET MinQuantity, MaxQuantity, DefaultQuantity, IsConsumptionPoint = ... WHERE Id = @Id AND ItemId = @ItemId AND DeprecatedAt IS NULL`. Validate the row belongs to this Item (catches stale Ids).
   - **If `Id` is NULL** (new pairing being added): existence-check by `(ItemId, LocationId)` —
     - If deprecated row exists → reactivate (clear `DeprecatedAt`) and apply metadata.
     - If active row exists → just apply metadata (no-op on the eligibility itself).
     - Otherwise → INSERT new row with the supplied metadata.
6. **Does NOT delete or deprecate anything.** Removal is the responsibility of `_Remove`, called via the click-confirm flow.
7. `Audit.Audit_LogConfigChange` with `EventCode = N'Updated'`, `@OldValue` = pre-state list of pairings for this Item, `@NewValue` = full incoming payload.
8. COMMIT.
9. Emit `SELECT @Status AS Status, @Message AS Message, @AffectedCount AS NewId;` (we reuse `NewId` as a count of affected rows so the caller can confirm what landed).

**Why no remove semantic in SaveAll:** the click-confirm-remove UX gives engineering deliberate per-row control; bundling removes into Save would either double-prompt (confirm then save) or remove without explicit confirm. Splitting keeps each interaction one click of intent.

**Validation messages** (verbatim toasts via `notifyResult`):
- `"Required parameter missing."`
- `"Item not found or deprecated."`
- `"Row N: LocationId not found or deprecated."` (row index from JSON)
- `"Row N: consumption quantities must be non-negative."`
- `"Row N: MinQuantity cannot exceed MaxQuantity."`
- `"Row N: ItemLocation Id <X> does not belong to this Item."`

### 3.3 `Parts.ItemLocation_ListByItem` — extension

Current projection:

```
Id, ItemId, LocationId, LocationName, LocationCode, DefinitionName,
MinQuantity, MaxQuantity, DefaultQuantity, IsConsumptionPoint, CreatedAt, DeprecatedAt
```

Add three columns by extending the existing JOIN to `Location.LocationType`:

```
HierarchyLevel  -- 2=Area, 3=WorkCenter, 4=Cell (per project seed)
TypeCode        -- 'Area' | 'WorkCenter' | 'Cell' | …
ParentLocationId  -- already on Location.Location; project it so UI can detect Area-of-Cell relationships
```

Change is purely additive — existing consumers continue to work. Bump the proc Change Log to 2.2.

### 3.4 SQL test impact

- `_SaveAll` lands with a new test file `032_ItemLocation_SaveAll.sql`. Covers: add 3 rows, edit metadata on 2, idempotent re-run, validation rejects.
- `_ListByItem` projection extension: update the existing `030_ItemLocation_crud.sql` if it asserts an exact column count.
- Estimate: +6 test cases (5 SaveAll + 1 ListByItem update). Test count climbs from current baseline.

---

## 4. Named Queries — three new

| NQ path | Backing proc | Used by |
|---|---|---|
| `parts/ItemLocation_ListByItemWithTier` | `Parts.ItemLocation_ListByItem` (extended) | Editor load — right panel data |
| `parts/ItemLocation_SaveAll` | `Parts.ItemLocation_SaveAll` (new) | Save button |
| `parts/ItemLocation_Remove` | `Parts.ItemLocation_Remove` (existing) | Confirm-remove flow |

NQ conventions: v2 schema, Designer-canonical sqlType enum (BIGINT=3, NVARCHAR=7, BIT=6), camelCase param identifiers.

Left-panel data sources use **existing** Location NQs:

| NQ path | Backing proc | Used by |
|---|---|---|
| `location/GetTree` | `Location.Location_GetTree` | Browse panel — Cell + WorkCenter listing under a selected Area |
| `location/Location_ListByTier` | `Location.Location_ListByTier` | Area / WorkCenter / Cell tier-filtered list (when no Area context, e.g., the top-level Area picker) |

---

## 5. Entity script — `BlueRidge.Parts.ItemLocation` (new module)

New module under `script-python/BlueRidge/Parts/ItemLocation/`. Public surface:

```python
def getActiveForItem(itemId):
    """List all ACTIVE ItemLocation pairings for the Item with tier metadata.
       Returns list[dict]; each dict carries:
         Id, LocationId, LocationName, LocationCode, DefinitionName, TypeCode,
         HierarchyLevel, ParentLocationId,
         MinQuantity, MaxQuantity, DefaultQuantity, IsConsumptionPoint, CreatedAt
       Used by the editor on open + after Save / Remove to refresh state."""

def getAvailableLocationsForTier(tierCode, parentAreaId=None, parentWorkCenterId=None):
    """List Locations of the given tier that the editor can offer to add.
       - tierCode='Area': returns all active Areas via getAllAreas() helper
                          (HierarchyLevel == 2).
       - tierCode='WorkCenter': requires parentAreaId; walks Location_GetTree
                                 from that Area, filters to WorkCenter rows.
       - tierCode='Cell': requires parentAreaId; optionally narrows by
                          parentWorkCenterId. Walks Location_GetTree from
                          parentAreaId (or from parentWorkCenterId if set),
                          filters to Cell rows.
       Returns list[dict] with {Id, Name, Code, ParentLocationId, TypeCode,
       HierarchyLevel}. UI consumes for the left-panel flex-repeater."""

def saveAll(itemId, pairingsList, userId=None):
    """Bundled save. pairingsList is the current editDraft — list of dicts
       carrying {Id|None, LocationId, MinQuantity, MaxQuantity,
       DefaultQuantity, IsConsumptionPoint}. Other fields ignored.
       Routes through Parts.ItemLocation_SaveAll. Returns {Status, Message, NewId}."""

def remove(itemId, locationId, userId=None):
    """Instant removal via Parts.ItemLocation_Remove. Returns {Status, Message}.
       Called by the click-then-confirm flow."""

def computeDefaultsFromFirstEntry(editDraft):
    """Helper: given the current editDraft list, return the metadata dict
       (Min/Max/Default/IsConsumptionPoint) of the first row in display
       order (grouped by tier: Areas → WorkCenters → Cells, then by Name).
       Returns the template metadata for staging new additions.
       Empty editDraft → {Min: None, Max: None, Default: None, IsConsumptionPoint: False}."""

def stageAdd(editDraft, location):
    """Pure helper (no DB): return a new editDraft with `location` appended
       as a new row, with metadata copied from computeDefaultsFromFirstEntry.
       View calls this on every left-panel click."""
```

**Implementation notes:**
- All public functions `_u()` deep-unwrap their inputs at entry per project convention.
- `Common.Util.log(...)` at every entry.
- `saveAll` serializes the pairings list via `system.util.jsonEncode(...)` (or equivalent — match the `Location_SaveAll` reference pattern).
- `getAvailableLocationsForTier('Area')` reuses the existing `BlueRidge.Location.Location.getAllAreas()` helper.
- `getAvailableLocationsForTier('Cell', parentAreaId=X)` calls `location/GetTree` with `rootId=X`, filters to rows where `HierarchyLevel == 4`. Same shape as `getAllAreas`'s client-side filter but rooted at the picked Area.

---

## 6. View — Eligibility tab rebuild

### 6.1 — File: `Components/Parts/ItemMaster/Eligibility/view.json` (existing, refactor in Designer)

Per `feedback_ignition_view_edit_boundary` memory — **edits to an existing view.json go through Designer**, not file edits. Phase 8 implementation plan will mark this step explicitly.

Phase 1 shell to keep:
- `view.params.value` — receives `itemId` as the input param.
- root container shell.

Phase 1 elements to replace:
- The static `view.custom.rows` array — replaced by `view.custom.editDraft` + `view.custom.selected` (live data).
- The hardcoded Area dropdown — replaced by NQ-bound dropdown.
- The single 4-column machine table — replaced by the two-panel layout.

### 6.2 — Two-panel layout

```
root (ia.container.flex, direction: row, gap: 12px)
├── BrowsePanel (basis: 360px, shrink: 0, flex column)
│     ├── TierTabs (flex row, basis: auto) — three tabs: Area / WorkCenter / Cell
│     │
│     ├── ParentPickers (flex column, basis: auto) — visibility depends on selected tier
│     │     ├── AreaDropdown   (visible when tier != Area)            ← bidi to view.custom.browse.areaId
│     │     └── WorkCenterDropdown (visible when tier = Cell and area picked)
│     │                                                                ← bidi to view.custom.browse.workCenterId
│     │     options sourced via:
│     │       - getAllAreas() for AreaDropdown
│     │       - getAvailableLocationsForTier('WorkCenter', areaId) for WC
│     │
│     ├── BrowseList (flex-repeater, grow: 1)
│     │     instances bound to runScript(
│     │       "BlueRidge.Parts.ItemLocation.getAvailableLocationsForTier",
│     │       0,
│     │       {view.custom.browse.tier},
│     │       {view.custom.browse.areaId},
│     │       {view.custom.browse.workCenterId}
│     │     ) — with client-side filter excluding any LocationId already in editDraft
│     │
│     │     each instance = a sub-view BrowseRow with onClick handler that fires
│     │     page-scoped message "stageAddLocation" with the row's data
│     │
│     └── BrowseHint (basis: auto, italic muted text)
│           "Pick a location above; it will stage in the map on the right.
│            Click Save to commit; click a mapped row to remove it."
│
└── MapPanel (grow: 1, flex column)
    ├── MapHeader (flex row, basis: auto)
    │     "Eligibility Map" title + DirtyIndicator + Save button
    │
    ├── MapSections (flex column, grow: 1, overflow-y: auto)
    │     ├── AreaSection — gated by editDraft.some(tier=Area)
    │     │   ├── SectionLabel "Areas"
    │     │   └── MapRow flex-repeater, instances filtered to tier=Area
    │     │
    │     ├── WorkCenterSection — gated by editDraft.some(tier=WorkCenter)
    │     │   ├── SectionLabel "Work Centers"
    │     │   └── MapRow flex-repeater, filtered to tier=WorkCenter
    │     │
    │     └── CellSection — gated by editDraft.some(tier=Cell)
    │         ├── SectionLabel "Cells"
    │         └── MapRow flex-repeater, filtered to tier=Cell
    │
    └── (Save button lives in MapHeader so it's always visible while scrolling)
```

### 6.3 — Sub-views to author (file-write, NEW)

Two new sub-views under `Components/Parts/ItemMaster/Eligibility/`:

**`BrowseRow`** — flex-repeater instance for the left panel.
- Inputs: `instance.location` (the location dict).
- Layout: location icon + Name + Code + small tier badge.
- onClick: page-scoped message `stageAddLocation` with `{location: instance.location}` payload.

**`MapRow`** — flex-repeater instance for the right panel.
- Inputs: `instance.row` (the editDraft entry), `instance.inheritedFromArea` (bool, computed by view-side script).
- Top line: location icon + Name + Code + tier badge + "Inherited from Area" badge (conditional) + chevron icon (rotates 90° when expanded).
- Click on the top line (NOT the chevron) → page-scoped message `confirmRemoveLocation` with `{row: instance.row}` payload.
- Click on the chevron → page-scoped message `toggleExpandRow` with `{rowIndex}`.
- When `instance.row.expanded == true`, the row shows 4 metadata inputs in a sub-container, each bidi-bound to the row's corresponding field (`MinQuantity`, `MaxQuantity`, `DefaultQuantity`, `IsConsumptionPoint`). Bidi writes back through the embedded boundary into the parent's `editDraft[index].<field>`.

### 6.4 — State model (`view.custom` on the Eligibility tab)

```yaml
itemId:               (input mirror from view.params.value)
browse:                                # left-panel state
  tier:                "Area"          # "Area" | "WorkCenter" | "Cell"
  areaId:              null            # required when tier in {WorkCenter, Cell}
  workCenterId:        null            # optional narrower when tier == Cell
selected:              []              # persisted ItemLocation rows from getActiveForItem
editDraft:             []              # current desired-state list; starts == selected (deep copy)
# Each row: {Id|null, LocationId, locationName, locationCode, typeCode,
#            hierarchyLevel, parentLocationId,
#            minQuantity, maxQuantity, defaultQuantity, isConsumptionPoint,
#            expanded (UI-only, transient)}
dirty:                 false           # expr: editDraft != selected (excluding `expanded` UI fields)
```

**Dirty comparison** must ignore the UI-only `expanded` flag. Easiest implementation: a small `_projectForCompare()` helper in the entity script that returns the editDraft minus UI fields, then bind dirty to `runScript("BlueRidge.Parts.ItemLocation.isDirty", 0, editDraft, selected)`. Or — simpler — keep `expanded` on a separate parallel object so the editDraft state is comparison-safe.

**Recommendation:** keep `expanded` flags on a sibling `view.custom.expandedRowIds: list[int]` rather than on the editDraft rows themselves. Dirty comparison then collapses cleanly.

### 6.5 — Message handlers (root view, all pageScope)

| Message | Payload | Action |
|---|---|---|
| `stageAddLocation` | `{location: {...}}` | `editDraft.append(stageAdd(editDraft, location))` — defaults metadata from computeDefaultsFromFirstEntry. |
| `toggleExpandRow` | `{rowIndex}` | Toggle the rowIndex in `view.custom.expandedRowIds`. |
| `confirmRemoveLocation` | `{row: {...}}` | Open `ConfirmDestructive` popup with title="Remove eligibility?" body="Remove eligibility for <Name> from this Item?"; on confirm, call `BlueRidge.Parts.ItemLocation.remove(itemId, locationId)`, refresh `selected` + `editDraft`. |
| `confirmDestructiveResult` | `{action: "confirm" \| "cancel"}` | Routes confirm → `remove(...)` (uses `view.custom.pendingRemove` for the target row). |

### 6.6 — Save button handler

```python
# Save button onActionPerformed, scope: G
draft = self.view.custom.editDraft or []
result = BlueRidge.Parts.ItemLocation.saveAll(
    self.view.params.value,
    draft,
)
BlueRidge.Common.Ui.notifyResult(result, "Eligibility saved")
if result and result.get("Status"):
    # Refresh from DB so Id assignments + auto-applied defaults reflect
    fresh = BlueRidge.Parts.ItemLocation.getActiveForItem(self.view.params.value)
    self.view.custom.selected  = fresh
    self.view.custom.editDraft = [dict(r) for r in fresh]  # rebaseline
    self.view.custom.expandedRowIds = []                    # collapse all
```

### 6.7 — Tab opens / Item changes — load script

`view.params.value` propertyChange (input is the selected Item.Id from parent):

```python
itemId = currentValue.value
if itemId is None:
    self.view.custom.selected = []
    self.view.custom.editDraft = []
    return
fresh = BlueRidge.Parts.ItemLocation.getActiveForItem(itemId)
self.view.custom.selected  = fresh
self.view.custom.editDraft = [dict(r) for r in fresh]
self.view.custom.expandedRowIds = []
self.view.custom.browse = {"tier": "Area", "areaId": None, "workCenterId": None}
```

This swap is silent — per pack convention 7 § "Save semantics" rule 2: **"Switching to a different entity… silently replaces `editDraft` with the new entity's data. The dirty indicator is the warning."** Phase 8 does not add a navigation guard.

### 6.8 — Visual: "Inherited from Area" badge

Computed per Cell row: a Cell row shows the badge when its `parentLocationId` chain includes an Area-tier `LocationId` that is also present in `editDraft`. Inline script transform on the Cell-section flex-repeater computes this per render.

The badge does NOT change semantics — Cell-tier metadata still overrides Area-tier per FDS-03-018. Engineering may choose to either:
- Leave the redundant Cell row (granting metadata-specific control)
- Remove the Cell row (Area row covers it via cascade)

Either is valid; the badge is purely informational.

### 6.9 — Bidirectional binding on metadata inputs

The 4 metadata inputs (Min / Max / Default / IsConsumptionPoint) inside the expanded-row sub-view bidi-bind to `view.params.row.<field>`. The parent's flex-repeater instance carries the row by **reference** (per Perspective semantics), so a child write propagates back into `editDraft[index]`. **This is the same R1 risk pattern flagged in Phase 1** — if the bidi round-trip through the embedded-view boundary doesn't work, Phase 8's metadata editing won't take.

Fallback: per-row page-scoped messages (`metadataFieldChanged` with `{rowIndex, field, value}`) handled by parent. Listed in § 9 R1.

---

## 7. UX flow walkthrough

**Scenario: setting up 5G0 eligibility from scratch**

1. Open Item Master, click "5G0 Front Cover Assembly", switch to Eligibility tab.
2. Right panel: empty (no persisted pairings). Left panel: Tier tab "Area" selected by default, area dropdown not shown (Area picker is the top level), flex-repeater shows all 4 Areas (Die Cast, Trim Shop, Machine Shop, Quality Control).
3. Click "Die Cast" → stages in right panel under "Areas" section, with default metadata (all NULL except `IsConsumptionPoint = false` since no prior rows).
4. Click the chevron on the Die Cast row → metadata inputs expand. Engineer types Min=10, Max=200, Default=100, IsConsumptionPoint=true.
5. Switch left-panel Tier tab to "Cell". Area dropdown appears, defaults to "Die Cast" (the most recently picked Area). Flex-repeater shows DC Cells (#3, #7, #12, #15).
6. Click "DC Machine #15" → stages in right panel under "Cells" section. Metadata defaults copy from the first row in editDraft (the Die Cast Area row): Min=10, Max=200, Default=100, IsConsumptionPoint=true.
7. The DC #15 row shows "Inherited from Area" badge (since its parent Area "Die Cast" is also in the map).
8. Engineer doesn't want the Cell-tier row's metadata to differ from the Area — but they want DC #15 specifically excluded from the blanket. They click the DC #15 row → confirm-remove popup → confirm → row removed (it was staged but not persisted; treat as no-op DB call; just splice out of editDraft). **Or:** if they later realize they want it back, click it again from the left panel.
9. Click Save → toast "Eligibility saved" → editor refreshes from DB; both rows now have `Id` populated; `selected` matches `editDraft`; dirty indicator clears.

**Scenario: revoking eligibility on a persisted row**

1. Open the editor — Die Cast Area row appears.
2. Click the row body (not the chevron) → ConfirmDestructive popup: "Remove eligibility for Die Cast from this Item?"
3. Confirm → `_Remove` proc fires → toast "Eligibility removed" → row disappears from both `selected` and `editDraft`. (Implementation: re-fetch from DB after the remove to keep state synced.)

**Scenario: editing metadata on a persisted row**

1. Open editor — Die Cast row already persisted with Min=10/Max=200/Default=100/IsConsumptionPoint=true.
2. Click chevron → metadata expands. Engineer changes Max to 300.
3. Dirty indicator lights up.
4. Click Save → bundled SaveAll fires; row's metadata updated; toast "Eligibility saved"; dirty clears.

---

## 8. Edge cases

| Case | Resolution |
|---|---|
| `getActiveForItem` returns empty (no prior eligibility) | Right panel shows three section headers ("Areas / Work Centers / Cells") each empty. Hint text in the empty space: "Pick a location from the left panel to add eligibility." |
| Engineer picks the same Location twice (staged but not yet saved) | Left-panel client-side filter excludes any `LocationId` already in editDraft. Engineer can't double-stage. |
| Engineer stages an Area, then stages a Cell under it, then stages the WorkCenter that contains the Cell | All three coexist; the Cell row shows "Inherited from Area" badge; the WorkCenter row also shows "Inherited from Area" badge (since its parent Area is in the map). All three are valid and committed on Save. Engineering's responsibility — UI doesn't auto-collapse. |
| User clicks Save with an empty editDraft (everything was staged then removed) | The SaveAll call's payload is `N'[]'` — proc handles gracefully (no rows to upsert; just commits the audit row). Result: Status=1, "No pairings to save."; selected/editDraft refresh from empty. |
| Engineer is mid-edit (dirty), clicks a different Item in the parent's left panel | Per § 6.7: silent replacement, dirty editDraft discarded. Pack convention 7 rule 2 — no nav guard. |
| `_SaveAll` fails part-way (e.g., a Location was deprecated between editDraft load and Save) | Transaction rollback; entire SaveAll fails; Status=0, Message="Row N: LocationId not found or deprecated."; editDraft remains as authored so engineer can fix and retry. |
| Engineer has 50+ pairings (extreme case) | editDraft is a JSON array; one large NQ call. Designer's NVARCHAR(MAX) handles megabytes. Realistically eligibility maps are 5-30 rows per Item. |
| ConfirmDestructive popup needs to remember WHICH row to remove | Set `view.custom.pendingRemove = row` before opening the popup. The `confirmDestructiveResult` handler reads it on confirm, then clears it. |
| User clicks "Remove" on a staged-but-not-persisted row | Splice it out of editDraft locally; no DB call needed. The entity script's `remove()` is only called when `row.Id != None`. |
| Two engineers edit same Item's eligibility concurrently | Last-write-wins per project convention. No `RowVersion`. SaveAll is idempotent on adds (reactivates if dup), but a concurrent Remove between editDraft load + Save would silently no-op the corresponding "update" (since the row no longer exists). Acceptable risk — engineering surface, low concurrency. |
| `_Add` proc's existing behavior (idempotent reactivation) | Honored by SaveAll's same logic — if a deprecated row exists for `(ItemId, LocationId)`, reactivate it and apply metadata. |
| Engineer's metadata edit is "clear this field" (set Min back to NULL) | The metadata-input bidirectional binding sets the value to empty/None. SaveAll forwards NULL — proc updates the column to NULL. No issue. |

---

## 9. Risks + open questions

| # | Risk / question | Mitigation / status |
|---|---|---|
| R1 | Bidirectional binding from MapRow's expanded metadata inputs back into the parent editDraft (via embedded-view-instance reference) is the same untested R1 pattern from Phase 1. If it doesn't propagate, metadata editing won't work. | Fallback: page-scoped `metadataFieldChanged` messages handled by parent — each metadata input fires on `dom.onBlur` (matching the Defect Codes precedent). Slightly more chatty but well-understood. Decision deferrable to Designer smoke. |
| R2 | The dirty indicator must ignore the UI-only `expanded` flag. Recommended approach: store `expandedRowIds` as a sibling `view.custom` array so editDraft rows stay comparison-clean. | Documented in § 6.4. |
| R3 | The bundled `_SaveAll` proc handles **adds + updates** but NOT removes (which fire instantly via `_Remove`). This split is a Phase 8 first; later editors may want it documented as a reference pattern. | Captured as the Phase 8 reference pattern in § 12. |
| R4 | A Save that adds N pairings + a near-simultaneous click-confirm-remove on row M creates a race: editDraft has M, Save submits M, Remove on M was already committed. SaveAll's "reactivate if deprecated" idiom would handle this gracefully — but a SaveAll between Remove-commit and editDraft-refresh would resurrect M. | Order of operations in the entity script: confirm-remove → call `_Remove` → re-fetch `selected` and `editDraft`. The brief window is acceptable; this is engineering UI, not OLTP. |
| R5 | "Inherited from Area" badge is computed client-side. With deeply nested hierarchies (Cell → WorkCenter → Area), the lookup walk per render could be expensive on Items with many pairings. | Pre-compute once on editDraft load; cache `Set[areaLocationId in editDraft]`. O(1) lookup per Cell row. Trivial cost. |
| R6 | The left panel's "exclude already-staged" filter requires walking editDraft on every render. Same as R5 — O(N) where N = pairings. Fine. | Documented. |
| R7 | `_SaveAll` doesn't validate that a Cell's `ParentLocationId` chain ends at an Area present in `editDraft` — i.e., no client-side enforcement prevents inconsistent state. (Engineering can stage a Cell whose Area isn't in the map; the cascade is purely additive.) | Intentional — FDS-03-014 says any tier is independently configurable. Cells without Area-tier coverage simply work as Cell-tier-only eligibility. |
| R8 | The mockup's Tonnage column is dropped from Phase 8. If engineering wants Cell attributes visible while picking, that's a separate enhancement (would require an additional LocationAttribute lookup per row). | Out of scope. Document as future polish. |
| R9 | `getAvailableLocationsForTier('Cell', parentAreaId=X)` walks `Location_GetTree(rootId=X)` and filters client-side. For Areas with hundreds of Cells, this is a single round-trip. MPP scale (4 Areas, ~20 Cells per Area max) is trivial. | Documented. |
| R10 | The "default metadata from first entry" mechanic depends on what "first" means. Three options: (a) display-order first — Areas → WorkCenters → Cells, then alphabetical (what § 5's `computeDefaultsFromFirstEntry` does); (b) chronological-first — the first row ever added, requiring a timestamp tracker; (c) first-staged-in-this-session — the first row added since the editor opened, requiring transient session state. **Recommendation: (a)** — deterministic, no extra state, what the engineer sees at the top of the right panel. If Jacques prefers (b) or (c), the helper changes are small (one extra column on the editDraft row or one extra `view.custom` field). Empty editDraft → all-NULL defaults. | Documented in § 5. Awaiting Jacques's confirmation of the "first" interpretation. |
| R11 | Removing a staged-but-not-persisted row triggers the confirm popup. Slight friction (you confirm to remove something you just clicked into existence). | Alternative: differentiate visually + skip confirm for staged adds. Decision: **keep uniform confirm-popup behavior** to avoid two interaction models. Override decision callable as a polish item if user feedback says it's annoying. |
| R12 | If the user staged WorkCenter rows then changes the Area picker on the left to a different Area, the WorkCenter rows in editDraft remain (they're already mapped). The left panel just refreshes to show WorkCenters in the newly-picked Area. No interaction; behaves correctly. | Documented. |

---

## 10. What "Done" looks like for Phase 8

1. SQL test suite passes — `_SaveAll` test cases + `_ListByItem` projection update. Test count climbs by ~6.
2. `scan.ps1` returns green.
3. Open Item Master, pick an Item with no current eligibility:
   - Eligibility tab shows empty right panel with hint text.
   - Click "Die Cast" in left panel under Area tab → stages on right.
   - Click chevron → metadata inputs appear.
   - Edit metadata → dirty indicator lights.
   - Click Save → toast "Eligibility saved" → dirty clears → row's `Id` populated.
4. Switch left tab to "Cell" → AreaDropdown appears, defaults to "Die Cast" → Cell list populates.
5. Click "DC Machine #3" → stages with metadata copied from Die Cast Area row → "Inherited from Area" badge visible.
6. Click Save → both rows persist.
7. Click DC Machine #3 row body → confirm popup → confirm → row removed.
8. Click Die Cast row body → confirm popup → cancel → row stays.
9. Switch to a different Item in the parent's left panel → Eligibility tab refreshes silently to the new Item's pairings.
10. Open AuditLog page → verify Phase 8 mutations logged: `ItemLocation Updated` for SaveAll, `ItemLocation Deprecated` for Remove.

---

## 11. References

- `MPP_MES_DATA_MODEL.md` — § ItemLocation (column-level), v1.9d hierarchy cascade note
- `MPP_MES_FDS.md` — FDS-03-014 (cascade), FDS-03-015 (engineering manages), FDS-03-018 (consumption metadata)
- `mockup/index.html` — lines 808–855 (Phase 1 mockup, partially superseded)
- `sql/migrations/repeatable/R__Parts_ItemLocation_Add.sql`, `_ListByItem.sql`, `_ListByLocation.sql`, `_Remove.sql`, `_SetConsumptionMetadata.sql`
- `sql/migrations/repeatable/R__Location_Location_GetTree.sql`, `R__Location_Location_ListByTier.sql`
- `script-python/BlueRidge/Location/Location/code.py` — `getAllAreas`, `listByTier`
- `docs/superpowers/specs/2026-05-19-item-master-view-shell-design.md` (Phase 1)
- `docs/superpowers/specs/2026-05-20-item-master-phase3-design.md` (Phase 3 — same project conventions)
- `ignition-context-pack/02_perspective_views.md`, `03_script_python.md`, `04_named_queries.md`, `07_conventions_and_antipatterns.md`
- Memory: `mpp-bundled-save-pattern`, `mpp-confirm-unsaved-popup-pattern` (the new ConfirmDestructive popup designed in Phase 5 is reused here), `project-mpp-item-master-pattern`, `feedback_ignition_view_edit_boundary`, `feedback_ignition_nq_resource_schema`

---

## 12. Phase 8 reference pattern (for future editors)

This editor introduces two project firsts that should be documented in memory once landed:

### 12.1 — Hybrid commit semantics (staged-add + Save, instant-remove on confirm)

The split: add interactions stage in editDraft (committed via Save); remove interactions fire instantly through a confirm popup. Use this pattern when:

- Adding is batchy (engineer does many adds before committing).
- Removing is deliberate and one-at-a-time.
- Editing metadata on existing rows is also batchy.

**Don't use this pattern** when removes are also batchy (e.g., "deprecate these 5 templates at once") — then pure editDraft is cleaner.

### 12.2 — Two-panel browse-and-map editor

Left = candidate browse panel filtered by tier picker + parent context dropdowns. Right = mapped/staged grouped by tier. Click-to-stage from left; click-with-confirm-to-remove on right; inline-expand for per-row detail editing; bottom Save commits staged adds.

Generalizes to any "associate N entities of type X with one entity of type Y" editor — e.g., associating users with roles, machines with maintenance schedules, parts with quality specs (a future enhancement).

---

## 13. File deltas

**New:**

- `sql/migrations/repeatable/R__Parts_ItemLocation_SaveAll.sql` — bundled adds + metadata updates
- `sql/tests/0009_Parts_Process/032_ItemLocation_SaveAll.sql` — SaveAll test coverage
- `ignition/.../named-query/parts/ItemLocation_ListByItemWithTier/{query.sql, resource.json}` — read with tier projection
- `ignition/.../named-query/parts/ItemLocation_SaveAll/{query.sql, resource.json}`
- `ignition/.../named-query/parts/ItemLocation_Remove/{query.sql, resource.json}` — wrapper around existing `_Remove` proc
- `ignition/.../script-python/BlueRidge/Parts/ItemLocation/{code.py, resource.json}` — new entity script
- `ignition/.../views/BlueRidge/Components/Parts/ItemMaster/Eligibility/BrowseRow/{view.json, resource.json}` — new sub-view
- `ignition/.../views/BlueRidge/Components/Parts/ItemMaster/Eligibility/MapRow/{view.json, resource.json}` — new sub-view

**Modified:**

- `sql/migrations/repeatable/R__Parts_ItemLocation_ListByItem.sql` — projection extension (HierarchyLevel, TypeCode, ParentLocationId)
- `sql/tests/0009_Parts_Process/030_ItemLocation_crud.sql` — column-count assertion update if applicable
- `ignition/.../views/BlueRidge/Components/Parts/ItemMaster/Eligibility/view.json` — Designer edit; full rebuild of the tab from the Phase 1 shell

**Not modified:**

- ConfirmDestructive popup (lands first as part of Phase 5's plan; if Phase 5 hasn't shipped yet by Phase 8 impl time, the popup gets authored as part of Phase 8 — same shape regardless)
- `Common/*` helpers
- Existing `_Add`, `_Remove`, `_SetConsumptionMetadata` procs — untouched
- The Eligibility tab's existing `view.params.value` input contract

**File-edit boundary** (per `feedback_ignition_view_edit_boundary`):
- All new view files: file-write safe (no Designer cache).
- Eligibility tab `view.json` (existing): **Designer edit** — plan marks the step explicitly.

---

## 14. Out of scope (deferred)

| Item | Disposition |
|---|---|
| `Parts.ItemLocation_IsEligible(@ItemId, @CellLocationId)` helper proc | Arc 2 territory — scan-in validation. Not Phase 8 (engineering surface). |
| Tonnage / other Cell attribute display in the browse panel | Polish — would require per-row LocationAttribute lookup. Defer. |
| Inverse view: "Eligibility Map Editor" page (`/eligibility`) showing all Items by Location | Separate page; Phase 8 only covers the per-Item editor. |
| Bulk-import eligibility from CSV / Excel | Engineering tool ask; not in Phase 8. |
| Optimistic locking (RowVersion on ItemLocation) | Project-wide adoption pass; not Phase 8. |
| Cell-attribute-aware filtering in the browse panel (e.g., "only show DC Cells with Tonnage ≥ 400") | Engineering UX enhancement; out of scope for MVP. |
| "Suggest cells" feature based on Item's part-type / tooling / Honda customer-code | ML-ish; speculative; out of scope. |

---

**Approval:** Self-approved under auto mode. Subject to Jacques's review of the spec post-write.
