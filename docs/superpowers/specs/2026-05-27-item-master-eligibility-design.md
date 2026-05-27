# Item Master Phase 8 — Eligibility Editor Design

**Date:** 2026-05-27
**Status:** Spec drafted, pending user review
**Scope:** Phase 8 of the Item Master Configuration Tool — the Eligibility tab on `/items` for managing per-Item `Parts.ItemLocation` rows with hierarchy-cascade semantics.

---

## 1. Purpose

Engineering users SHALL be able to add, update, and remove `Parts.ItemLocation` rows for a selected Item via the Eligibility tab on the `/items` page. Each row maps the Item to a Location at any tier (Area / WorkCenter / Cell), with optional consumption-point metadata (Min / Max / Default piece counts). The runtime eligibility check at plant-floor scan-in (`Parts.ItemLocation_IsEligible`, FDS-03-014) consumes these rows via the hierarchy-cascade resolution path.

This phase realizes FDS-03-015 (Eligibility Management — MVP) and exposes FDS-03-018 (Consumption Metadata — MVP).

## 2. Scope

**In scope:**
- Per-Item editor of direct `Parts.ItemLocation` rows.
- Location selection at any tier via a single typeahead dropdown grouped by tier (Site / Area / WorkCenter / Cell).
- Per-row consumption metadata fields, conditionally shown when `IsConsumptionPoint` is checked.
- Bundled SaveAll commit model: editor accumulates row adds + edits + removes locally; one transactional save reconciles.
- Soft-delete via `DeprecatedAt` (project convention).
- Single `Audit.ConfigLog` row per SaveAll invocation with full pre/post payload.
- Section participates in the existing per-section dirty-state gate (ConfirmUnsaved popup on tab/item-row switch).

**Out of scope:**
- BOM-derived eligibility surfacing. It resolves automatically at runtime via `Parts.v_EffectiveItemLocation`; no UI exposure required per FDS-03-014.
- Per-Cell effective grid view (mockup-style). Considered and rejected during brainstorming — see §10.
- Item-Type ↔ Location-Type compatibility enforcement. Engineer is trusted; no business-rule guard rails in either the dropdown or the proc. See §10.
- Versioning lifecycle (Draft / Published / Deprecated). Eligibility doesn't version — changes are immediate on save.
- Bulk-import or CSV-paste flows. Future enhancement.
- Cross-Item / by-Location editor surface. Phase G admin views may add this later; out of scope here.

## 3. Data Model — No Schema Changes

`Parts.ItemLocation` already carries every column needed. Schema (migration `0006_routes_operations_eligibility` + columns added in `0010_phase9_tools_and_workorder`):

| Column | Type | Notes |
|---|---|---|
| `Id` | `BIGINT IDENTITY PK` | Surrogate key |
| `ItemId` | `BIGINT NOT NULL FK → Parts.Item.Id` | The eligible Item |
| `LocationId` | `BIGINT NOT NULL FK → Location.Location.Id` | Eligibility target at any tier |
| `IsConsumptionPoint` | `BIT NOT NULL DEFAULT 0` | `1` = consumes Item (input); `0` = produces / eligibility-only |
| `MinQuantity` | `INT NULL` | Required when `IsConsumptionPoint = 1` |
| `MaxQuantity` | `INT NULL` | Required when `IsConsumptionPoint = 1` |
| `DefaultQuantity` | `INT NULL` | Required when `IsConsumptionPoint = 1` |
| `CreatedAt` | `DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()` | Insert audit |
| `DeprecatedAt` | `DATETIME2(3) NULL` | Soft-delete |

Existing unique index `UQ_ItemLocation_ActiveItemLocation` on `(ItemId, LocationId) WHERE DeprecatedAt IS NULL` enforces "at most one active row per Item-Location pair." Reuse it for SaveAll's uniqueness guarantee.

## 4. UI / Editor Design

### 4.1 Layout

```
┌─ Eligibility ───────────────────────────────────────────────────────────────┐
│  Eligibility for 5G0 — Front Cover Assembly       [Discard] [Save]          │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ #   Location                              Consumption  Qty Fields    × │
│  │ ──────────────────────────────────────────────────────────────────── │    │
│  │ 1   [DC — Die Cast (Area)            ▼]    [☐]                    [×]│    │
│  │ 2   [TR — Trim Shop (Area)           ▼]    [☑]  Min[50] Max[200] Def[100]  [×]│    │
│  │ 3   [DC-007 — DC Machine 7 (Cell)    ▼]    [☐]                    [×]│    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  [ + Add Location ]                                                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Row Components

Each row in the LinesRepeater is an embedded sub-view `BlueRidge/Components/Parts/ItemMaster/EligibilityRow/`. The row mirrors `BomLineRow` for sizing and uniform 30px control heights. Column headers live in the parent Eligibility view above the LinesRepeater, mirroring the BOMs ColumnHeader pattern (the row sub-view contains only controls, not labels).

| Column | Width | Component | Notes |
|---|---|---|---|
| `#` | 36px | `ia.display.label` | 1-indexed row number (from `params.rowIndex + 1`) |
| Location | grow 1 | `ia.input.dropdown` | Typeahead, filterable, options sorted by `(tierOrdinal, code)` with tier in label |
| IsConsumptionPoint | 60px | `ia.input.checkbox` | Toggles visibility of qty fields. Header label above reads "Consumption". |
| Min / Max / Default | 240px combined | 3 × `ia.input.text-field` | `position.display` bound to `IsConsumptionPoint`; collapses when unchecked |
| Remove | 40px | `ia.input.button` | × symbol |

**No reorder arrows.** `Parts.ItemLocation` has no `SortOrder` column. Rows display in canonical sort order from `Parts.ItemLocation_ListByItem` (sorted `(LocationTierOrdinal ASC, LocationCode ASC)`). New rows added in the editor session append at the bottom of `state.editDraft.rows`; on next save+reload they slot into their canonical position. This avoids ephemeral reorderings that don't persist.

When `IsConsumptionPoint` is unchecked, the three qty fields collapse via `position.display` (not `meta.visible` — they share no layout slot with other content, so collapse is preferred). Row width adjusts naturally.

### 4.3 Location Dropdown

Single typeahead dropdown bound via property + script transform to `view.custom.locationOptions` (loaded by parent embed, see §5.3). Label format:

```
DC — Die Cast (Area)
ML — Machining (Area)
TR — Trim (Area)
DC-CELLS — DC Cells (WorkCenter)
ML-CELLS — Machining Cells (WorkCenter)
DC-001 — Die Cast Machine 1 (Cell)
DC-007 — Die Cast Machine 7 (Cell)
DC-012 — Die Cast Machine 12 (Cell)
```

Sort key: `(tierOrdinal ASC, code ASC)` so dropdown reads as a natural progression. `filterable: true` enables type-to-search across the whole list. No optgroup separators (Ignition dropdown does not support them) — the tier suffix in the label carries the grouping signal.

### 4.4 State Shape

`view.custom.state` is a single nested object updated as one atomic property write:

```python
view.custom.state = {
    "selected": {
        "rows": [
            {
                "id": 42,
                "locationId": 17,
                "locationLabel": "DC-007 — DC Machine 7 (Cell)",
                "locationTierOrdinal": 4,
                "isConsumptionPoint": False,
                "minQuantity": None,
                "maxQuantity": None,
                "defaultQuantity": None
            },
            ...
        ]
    },
    "editDraft": { "rows": [...] }
}
```

Companion props (siblings of `state`):
- `view.custom.locationOptions` — populated via `runScript` from `Location.Location_ListForEligibilityPicker`. Powers the row dropdown.
- `view.custom.isDirty` — expression binding via `convertWrapperObjectToJson(state.editDraft) != convertWrapperObjectToJson(state.selected)`. Initial value `false`.

### 4.5 Save / Discard / Dirty Plumbing

Identical to BOMs / ContainerConfig / Identity:
- `view.custom.isDirty` binding drives Save/Discard button visibility (`meta.visible`).
- Dirty `onChange` fires `sectionDirtyChanged{section: "eligibility", isDirty: <bool>}` page-scoped.
- Parent `ItemMaster` view's existing `sectionDirty` flag map gates tab switches and item-row clicks via `ConfirmUnsaved` popup.
- `sectionSaveRequested{section: "eligibility"}` message → embed calls its own `handleSave()`.
- `sectionDiscardRequested{section: "eligibility"}` message → embed resets `state.editDraft = dict(state.selected)`.

### 4.6 Per-row Message Propagation

Embed-to-parent communication mirrors `BomLineRow` (see `feedback_ignition_no_foreach_in_expressions`, parent's `_applyXxxChange` helpers):

| Source event | Message | Payload | Parent handler |
|---|---|---|---|
| Location dropdown `onActionPerformed` | `eligibilityRowLocationChanged` | `{rowIndex, newLocationId}` | `_applyLocationChange(rowIndex, newLocationId)` — looks up Location label from `locationOptions`, updates row |
| IsConsumptionPoint checkbox `onActionPerformed` | `eligibilityRowConsumptionChanged` | `{rowIndex, isConsumptionPoint}` | `_applyConsumptionChange(rowIndex, flag)` — toggles flag, zeros qty fields if turning off |
| Min/Max/Default text-field `dom.onBlur` | `eligibilityRowQtyChanged` | `{rowIndex, field, newValue}` | `_applyQtyChange(rowIndex, field, value)` — sets the field, coerces to int |
| Remove × `onActionPerformed` | `eligibilityRowRemove` | `{rowIndex}` | `_removeRow(rowIndex)` |
| + Add Location button | direct customMethod call (lives on parent root) | none | `addRow()` — appends empty row with `id: null`, `isConsumptionPoint: false`, all qty NULL |

Bidi binding on row fields to `view.params.rowData.X` is NOT used — parent params are input-only and the writes would be silently dropped. Message-based propagation is the established pattern.

## 5. SQL Surface

### 5.1 New procs

**`Parts.ItemLocation_SaveAllForItem(@ItemId, @RowsJson, @AppUserId)`** — bundled reconciliation. JSON row shape:

```json
[
    { "Id": 42, "LocationId": 17, "IsConsumptionPoint": false,
      "MinQuantity": null, "MaxQuantity": null, "DefaultQuantity": null },
    { "Id": null, "LocationId": 9, "IsConsumptionPoint": true,
      "MinQuantity": 50, "MaxQuantity": 200, "DefaultQuantity": 100 },
    ...
]
```

Reconciliation rules:

| Set | Action |
|---|---|
| Incoming row with non-NULL `Id` matching an active row for this Item | UPDATE in place |
| Incoming row with `Id = NULL`, no active row for `(ItemId, LocationId)`, no deprecated row for the pair | INSERT |
| Incoming row with `Id = NULL`, deprecated row exists for `(ItemId, LocationId)` | Reactivate (UPDATE `DeprecatedAt = NULL` + fields) |
| Incoming row with `Id = NULL`, active row exists for `(ItemId, LocationId)` not in incoming Ids | Reject (`Status=0`, "Duplicate Item+Location pairing") |
| Active row for this Item not in incoming JSON | DEPRECATE (`DeprecatedAt = SYSUTCDATETIME()`) |

Validation:
- `@ItemId` references an active `Parts.Item`.
- `@AppUserId` is non-NULL.
- For each incoming row:
  - `LocationId` references a non-deprecated `Location.Location`.
  - If `IsConsumptionPoint = 1`: `MinQuantity`, `MaxQuantity`, `DefaultQuantity` all non-NULL; `MinQuantity >= 0`; `MinQuantity <= DefaultQuantity <= MaxQuantity`.
  - If `IsConsumptionPoint = 0`: server zeroes Min/Max/Default to NULL on persist (defensive — caller may leave stale values from a toggled checkbox).

Single transaction, all-or-nothing, wrapped in TRY/CATCH. One `Audit.Audit_LogConfigChange` row at the end with `OldValue` = JSON of pre-state rows and `NewValue` = `@RowsJson`. Status-row pattern: `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId` where `@NewId` echoes `@ItemId` for consistency with the project's mutation-proc convention.

NQ wrapper: `parts/ItemLocation_SaveAllForItem` — `type: "Query"` (NOT `UpdateQuery` — the proc returns a status row; see commit `1049ea3` for the lesson).

**`Location.Location_ListForEligibilityPicker(@IncludeDeprecated BIT = 0)`** — read for the row dropdown. Returns: `Id`, `Code`, `Name`, `TierName` (from joined `LocationTypeDefinition`), `TierOrdinal` (from joined `LocationType.HierarchyLevel`), `DisplayLabel` (computed `Code + ' — ' + Name + ' (' + TierName + ')'`). Sorted `(TierOrdinal ASC, Code ASC)`. Excludes deprecated Locations by default. NQ wrapper: `location/Location_ListForEligibilityPicker` with `type: "Query"`, cache enabled (60 sec).

### 5.2 Reused procs

`Parts.ItemLocation_ListByItem(@ItemId)` — existing. If its current SELECT doesn't include the joined `LocationCode`, `LocationName`, `TierName`, `TierOrdinal` columns needed by the editor display, update it (repeatable, low cost). Otherwise leave alone.

### 5.3 Entity script

New module `BlueRidge.Parts.Eligibility` under `script-python/BlueRidge/Parts/Eligibility/code.py`. Public surface:

```python
def listByItem(itemId)            -> list[dict]
def listLocationOptions()         -> list[dict]
def handleSaveAll(itemId, rows)   -> {Status, Message, NewId}
```

Routes through `BlueRidge.Common.Db.execList` / `execMutation` per the three-layer rule.

### 5.4 Procs NOT used by this editor

`Parts.ItemLocation_Add`, `ItemLocation_Remove`, `ItemLocation_SetConsumptionMetadata` stay in place. They're useful for other surfaces (Plant Hierarchy editor's eligibility cross-view, plant-floor admin overrides) but the Eligibility editor only calls `_SaveAllForItem` for writes.

## 6. Validation Rules — Summary

**Client-side (advisory):**
- Disable Save button when not dirty.
- Highlight rows where `IsConsumptionPoint = true` but a qty field is empty.

**Server-side (authoritative, in SaveAll proc):**
- ItemId active + AppUserId non-NULL.
- LocationId active for each row.
- Uniqueness: no duplicate `(ItemId, LocationId)` among the incoming active set.
- Consumption-point fields: when `IsConsumptionPoint = 1`, Min/Max/Default required + `0 ≤ Min ≤ Default ≤ Max`.
- No Item-Type × Location-Type compatibility checks. Engineer is trusted.

Any validation failure rolls back the whole save and surfaces a single specific message via the toast layer.

## 7. Audit

One `Audit.Audit_LogConfigChange` row per `SaveAllForItem` invocation:

- `LogEntityTypeCode`: `ItemLocation`
- `EntityId`: `@ItemId` (the parent — the save event is for the whole row set, not any single row)
- `LogEventTypeCode`: `Updated`
- `LogSeverityCode`: `Info`
- `Description`: `'Eligibility map updated. <N> rows in payload.'`
- `OldValue`: `JSON_QUERY()` of the pre-state active rows, captured at proc entry.
- `NewValue`: `@RowsJson` as-given.

Per-row deprecation events are NOT separately logged — they're inside the parent ConfigLog row's old/new diff.

## 8. View File Plan

| Path | Action | Notes |
|---|---|---|
| `views/BlueRidge/Components/Parts/ItemMaster/Eligibility/view.json` | Modify | Replace Phase 1 placeholder shell with the full editor wired to state + SaveAll |
| `views/BlueRidge/Components/Parts/ItemMaster/EligibilityRow/view.json` | Create | New sub-view for one editable row. Sibling of `BomLineRow` (not nested) |
| `script-python/BlueRidge/Parts/Eligibility/code.py` | Create | Entity script — listByItem, listLocationOptions, handleSaveAll |
| `named-query/parts/ItemLocation_SaveAllForItem/` | Create | NQ wrapping the new SaveAll proc |
| `named-query/location/Location_ListForEligibilityPicker/` | Create | NQ wrapping the new picker read |
| `named-query/parts/ItemLocation_ListByItem/` | Modify if needed | Update SELECT to include joined Location columns |
| `sql/migrations/repeatable/R__Parts_ItemLocation_SaveAllForItem.sql` | Create | The new SaveAll proc |
| `sql/migrations/repeatable/R__Location_Location_ListForEligibilityPicker.sql` | Create | The new picker read |
| `sql/migrations/repeatable/R__Parts_ItemLocation_ListByItem.sql` | Modify if needed | If joins missing for editor display |
| `sql/tests/0010_Parts_ItemLocation/...` | Create | Test fixtures for `SaveAllForItem` (add/update/deprecate/reactivate paths + validation rejections) |

## 9. Smoke Checklist

Drafted in the spirit of the BOMs smoke (B1–B13). To be expanded into the implementation plan.

1. **Cold open** — `/items` → pick 5G0 → click Eligibility tab. Rows list renders showing 5G0's current ItemLocation rows. No dirty dot.
2. **Add row** — click `+ Add Location`. New empty row appears with `id: null`. Location dropdown shows all tiers grouped. Dirty dot appears, tabs disable.
3. **Pick a Location** — type a few chars, pick `DC-007 — DC Machine 7 (Cell)`. Row updates with the chosen Location label.
4. **Toggle consumption point** — check the IsConsumptionPoint checkbox. Min/Max/Default fields appear via position.display. Uncheck — fields collapse back.
5. **Enter qty bounds** — Min=50, Max=200, Default=100. Tab through. State updates.
6. **Remove row** — `×` deletes the row from editDraft locally.
7. **Save** — click Save. Toast "Eligibility saved. <N> rows updated." (or similar). Dirty clears. Tabs re-enable. Reload — changes persist and rows return in canonical `(tierOrdinal, code)` order.
8. **Validation: duplicate Location** — add a row pointing at a Location already in the list (e.g., DC-007 twice). Save → toast "Duplicate Item+Location pairing." No changes commit.
9. **Validation: consumption-point qty missing** — toggle IsConsumptionPoint on, leave Min blank. Save → toast "Min/Max/Default required when consumption point is enabled." No commit.
10. **Validation: Min > Max** — Min=200, Max=50. Save → toast "Min must be ≤ Max." No commit.
11. **Discard** — make edits, click Discard. State reverts to last saved. Dirty clears.
12. **Tab-switch gate** — make edits, click another tab → tab is visually disabled. Click another item row → ConfirmUnsaved popup fires.
13. **Reactivation** — deprecate an Item-Location pair (Save with the row removed from editDraft). Then add a new row pointing at the same Location. Save → proc reactivates the deprecated row (no new Id created). Verify by querying `Parts.ItemLocation` — the original `Id` should now have `DeprecatedAt = NULL`.
14. **Audit** — open `/audit` → `Audit.ConfigLog` shows one Updated row per save with full `OldValue` / `NewValue` JSON delta.

## 10. Decisions + Rejected Alternatives

| Decision | Rejected alternative | Reason |
|---|---|---|
| Tiered list editor (single row per ItemLocation row) | Per-Cell effective grid (mockup-style, checkbox per Cell) | Schema has no "deny" semantic to support unchecking a Cell when eligibility cascades from a parent tier. Per-Cell view also fights the FDS-prescribed "1 Area row covers 20 Cells" compaction. |
| Single typeahead dropdown grouped by tier | Tree picker popup; two-step tier-then-location dropdowns | Engineers know plant codes. Typeahead is fastest. Tree popup is overkill for a single-pick operation. |
| No Item-Type × Location-Type business-rule enforcement | Hardcoded Python matrix; soft-warn matrix; new config table | User feedback: "I don't want the business logic to live in a python script." Runtime scan-in already enforces eligibility via `ItemLocation_IsEligible`, so misconfiguration is caught downstream. |
| Bundled SaveAll | Per-row mutations on blur / explicit row-save | Matches the established pattern (Routes / BOMs / LocationTypeDefinition). Atomic commits. Consistent dirty-state + ConfirmUnsaved behavior. |
| Soft delete via `DeprecatedAt` | Hard `DELETE` from the table | Project-wide convention. Audit trail preserved. Reactivation via the deprecated-row path keeps `Id` stable. |
| One ConfigLog row per save (parent-level) | Per-row audit events (one Add/Update/Deprecate row each) | Matches `LocationTypeDefinition_SaveAll` audit shape. Diff is captured in `OldValue` / `NewValue` JSON. |
| No BOM-derived eligibility UI surfacing | Read-only panel showing "this Item is also implicitly eligible at X because it's a component of Item Y" | BOM-derived eligibility resolves automatically at runtime. Surfacing it complicates the editor without serving a configuration need. |

## 11. References

- FDS: `MPP_MES_FDS.md` §3.5 Part-to-Location Eligibility (FDS-03-014, FDS-03-015, FDS-03-018)
- Data Model: `MPP_MES_DATA_MODEL.md` § Parts schema
- SQL: migration `0006_routes_operations_eligibility`, migration `0010_phase9_tools_and_workorder` (added consumption-metadata columns)
- Existing procs: `R__Parts_ItemLocation_Add.sql`, `R__Parts_ItemLocation_Remove.sql`, `R__Parts_ItemLocation_SetConsumptionMetadata.sql`, `R__Parts_ItemLocation_ListByItem.sql`, `R__Parts_ItemLocation_ListByLocation.sql`
- Pattern memories: `project_mpp_item_master_pattern` (per-section ownership), `project_mpp_bundled_save_pattern` (SaveAll proc shape), `feedback_ignition_no_foreach_in_expressions` (property+script transform for list-shaped bindings)
- Sibling specs: `2026-05-20-item-master-boms-design.md`, `2026-05-20-item-master-phase4-design.md`
