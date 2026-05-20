# Item Master — Routes Versioning Workflow (Phase 5 of 8)

**Date:** 2026-05-20
**Status:** Draft — pending Jacques's review
**Scope:** Wire the Routes tab on the Item Master surface end-to-end: read live `Parts.RouteTemplate` data; expose the version selector across all versions (Draft / Published / Deprecated); implement the New Version → edit → Publish / Discard workflow; persist Draft edits via a bundled SaveAll.

Phase 1 left this tab as a published-only static table reading from `view.params.value.steps` (dummy data passed in from the parent's `editDraft.routes` slice). Phase 5 replaces that with the full versioning workflow.

---

## 1. Goals

- Routes tab loads the version list and selected version's steps from the database for the currently-selected Item.
- Engineers can browse any version (Draft / Published / Deprecated) via the version-selector dropdown.
- Engineers can click **New Version** to clone any version (typically the active Published one) into a new Draft, then edit it.
- Draft editing supports: change EffectiveFrom + Name; reorder steps via ↑/↓ buttons; add/remove steps; cascade Area → Operation Template dropdown per step.
- **Save** persists Draft meta + step deltas in one atomic call (bundled SaveAll).
- **Publish** flips the Draft to Published (immutable thereafter).
- **Discard Draft** hard-deletes the Draft row + its steps. (Drafts never reach production, so hard-delete is safe and reclaims the VersionNumber slot.)
- All mutations write `Audit.ConfigLog` via the SP-layer audit calls. UI surfaces success/failure via `Common.Notify.toast` + `Common.Ui.notifyResult`.

---

## 2. Non-Goals (Phase 5 boundary)

| Capability | Disposition |
|---|---|
| Operation Template Library / Editor (`Parts.OperationTemplate` CRUD UI) | **Out of scope.** Phase 5 of the *Phased Plan Config Tool* covers it. Routes tab consumes the OperationTemplate list as a dropdown source; engineering authors new templates elsewhere. Toast a "Not wired yet" link if a missing template needs creation mid-edit. |
| BOMs versioning workflow (Phase 6) | Parallel — see § 12 (Versioned-tab pattern) for the mechanics that generalize. |
| Quality Specs cross-link (Phase 7) | Not affected — Quality Specs tab is its own surface. |
| Eligibility editor (Phase 8) | Not affected. |
| Multi-Draft per Item | **Single Draft per Item.** `RouteTemplate_CreateNewVersion` will be hardened to reject if an active Draft already exists for the same `ItemId` (one open editing session at a time per Item). See § 6 R3. |
| Operation `RequiresSubLotSplit` configuration | Read-only context surfaced on each step (informational); managed by the Operation Template Editor, not by this tab. |
| Operator-side Cell selection | Per FDS-03-009 routes do NOT prescribe Cells — the operator picks from `ItemLocation` at runtime. The Eligibility tab (Phase 8) owns Cell-level eligibility. |
| Effective Date validation (e.g., "must be ≥ today") | Soft constraint only — the Publish proc accepts any date. Future-effective routes are a valid use case (e.g., scheduling a process change). Client-side UI shows a warning if EffectiveFrom is in the past relative to "now" but does not block. |
| Reordering across Areas (e.g., "Trim before Die Cast") | The UI does not enforce Area ordering. Engineering owns this — bad ordering is engineering's bug, not a constraint the MES will police. |

---

## 3. Data Model Touchpoints

All tables already exist; no migration needed.

| Table | Role for Phase 5 | Key columns |
|---|---|---|
| `Parts.RouteTemplate` | Versioned route header. | `Id`, `ItemId`, `VersionNumber`, `Name`, `EffectiveFrom`, `PublishedAt`, `DeprecatedAt`, `CreatedByUserId`, `CreatedAt` |
| `Parts.RouteStep` | Ordered steps within a route. Drafts are mutable; Published versions are immutable (enforced by proc). | `Id`, `RouteTemplateId`, `OperationTemplateId`, `SequenceNumber`, `IsRequired`, `Description` |
| `Parts.OperationTemplate` | Reusable operation definitions; dropdown source. **Versioned independently** of routes. Each row carries `AreaLocationId` — driver for the cascading Area → Operation Template dropdown. | `Id`, `Code`, `VersionNumber`, `Name`, `AreaLocationId`, `Description`, `RequiresSubLotSplit`, `DeprecatedAt` |
| `Parts.OperationTemplateField` | Tells us what data the operation collects — displayed in the "Data Collection" column as a comma-joined list of `DataCollectionField.Code` values. | `OperationTemplateId`, `DataCollectionFieldId`, `IsRequired`, `DeprecatedAt` |
| `Parts.DataCollectionField` | Vocabulary (DieInfo, CavityInfo, Weight, GoodCount, BadCount, MaterialVerification, SerialNumber, …). Joined for the Data Collection display string. | `Id`, `Code`, `Name` |
| `Location.Location` | Areas — the cascading dropdown's first level. Filtered to `HierarchyLevel == 2` (Areas) via the existing `BlueRidge.Location.Location.getAllAreas` helper. | `Id`, `Name`, `HierarchyLevel` |

**No new tables.** No schema changes. No migrations.

### Three-state lifecycle (recap from data model)

```
       _CreateNewVersion         _Publish               _Deprecate
NULL ──────────────────► Draft ──────────► Published ───────────────► Deprecated
                          │                                              ▲
                          └─ _DiscardDraft (hard delete) ─► gone         │
                                                              _Deprecate │
                                                          (Draft can     │
                                                           also be       │
                                                           deprecated    │
                                                           without       │
                                                           publishing —  │
                                                           rarely used   │
                                                           — see § 4 ──┘
```

**State derivation:**
- `PublishedAt IS NULL AND DeprecatedAt IS NULL` → **Draft** (mutable, invisible to production)
- `PublishedAt IS NOT NULL AND DeprecatedAt IS NULL` → **Published** (immutable, visible to production via `_GetActiveForItem` once `EffectiveFrom <= now`)
- `DeprecatedAt IS NOT NULL` → **Deprecated** (read-only display in history)

A Deprecated row may have either `PublishedAt` non-NULL (retired published version) or NULL (rarely — a soft-deleted Draft; we will instead prefer the `_DiscardDraft` hard-delete path).

---

## 4. State Machine and Permitted Operations

Per state, the only permitted state transitions:

| From state | Allowed transitions | Proc |
|---|---|---|
| **Draft** | → Draft (save edits in place) | `RouteTemplate_SaveAll` (new — § 5.1) |
| **Draft** | → Published | `RouteTemplate_Publish` (existing — extended with @EffectiveFrom + @Name overrides per § 5.4) |
| **Draft** | → gone (hard delete) | `RouteTemplate_DiscardDraft` (new — § 5.3) |
| **Published** | → Deprecated | `RouteTemplate_Deprecate` (existing) |
| **Published** | → new Draft (fork) | `RouteTemplate_CreateNewVersion` (existing — extended with single-Draft guard per § 6 R3) |
| **Deprecated** | → new Draft (fork — engineering may resurrect a retired pattern) | `RouteTemplate_CreateNewVersion` (existing) |
| **Deprecated** | → no other transitions | — |

**Forbidden transitions (enforced by procs):**
- Published → Published (re-publish a republished route — rejected by `_Publish` with "already published")
- Published step edits — `RouteStep_*` discrete mutators check `parent.PublishedAt IS NULL` and reject otherwise. The new `RouteTemplate_SaveAll` carries the same guard.
- Edit fields on a Deprecated row.
- Publish a Deprecated row.

### What's editable in each state

| State | Header fields | Steps |
|---|---|---|
| Draft | Name, EffectiveFrom | Add / remove / reorder / change OperationTemplate per step / IsRequired |
| Published | nothing (read-only) | nothing |
| Deprecated | nothing (read-only) | nothing |

---

## 5. API Layer — NQs and Stored Procedures

### 5.1 Inventory: what exists vs. what's new

| Proc | Status | Notes |
|---|---|---|
| `Parts.RouteTemplate_ListByItem` | **Exists** | Used by version dropdown. Adjust UI call to pass `@ActiveOnly = 0` so the dropdown can show Deprecated versions too (collapsed by default; "Show deprecated" toggle reveals them — see § 7.2). |
| `Parts.RouteTemplate_Get` | **Exists** | Header for the currently-selected version. |
| `Parts.RouteStep_ListByRoute` | **Exists** | Step rows joined to OperationTemplate Code + Name. **Extend** (or wrap with a new proc) to also return the Data Collection field summary — see § 5.5. |
| `Parts.RouteTemplate_CreateNewVersion` | **Exists — hardening needed** | Per § 6 R3 add the single-Draft-per-Item guard. |
| `Parts.RouteTemplate_Publish` | **Exists — extension needed** | Per § 5.4 add optional `@EffectiveFrom` + `@Name` overrides + a zero-steps guard. |
| `Parts.RouteTemplate_Deprecate` | **Exists** | No change. Per its own docs there is no FK guard against active Lots — production history is preserved via the immutable snapshot on each Lot. |
| `Parts.RouteTemplate_SaveAll` | **NEW** | § 5.2 — bundled Draft save. Replaces the discrete `RouteStep_Add` / `_Update` / `_MoveUp` / `_MoveDown` / `_Remove` calls **from this editor's perspective**. The discrete procs remain in the codebase for Script Console / other future callers (per `mpp-bundled-save-pattern` memory). |
| `Parts.RouteTemplate_DiscardDraft` | **NEW** | § 5.3 — hard-delete a Draft + its steps. Rejects if the row is Published or Deprecated. |
| `Parts.OperationTemplate_ListByArea` | **Verify** — existing `OperationTemplate_List(@AreaLocationId, @ActiveOnly)` matches this signature; check the call doesn't return Deprecated rows by default (it does — `@ActiveOnly = 1`). | Used for the cascading per-step dropdown. |
| `Parts.OperationTemplateField_SummaryByTemplate` | **NEW (small helper)** | § 5.5 — returns one row per OperationTemplate with a comma-joined string of `DataCollectionField.Code` values. Powers the "Data Collection" column on both the published-view and draft-edit table. Alternative: surface this via a Named Query that runs a STRING_AGG query directly; pick simpler option in plan. |

### 5.2 `Parts.RouteTemplate_SaveAll` (NEW)

Signature (mirrors `Location.LocationTypeDefinition_SaveAll`):

```sql
CREATE OR ALTER PROCEDURE Parts.RouteTemplate_SaveAll
    @Id              BIGINT,                       -- Draft RouteTemplate.Id — required (must already exist via _CreateNewVersion)
    @Name            NVARCHAR(200),
    @EffectiveFrom   DATETIME2(3),
    @AppUserId       BIGINT,
    @StepsJson       NVARCHAR(MAX)   = N'[]'       -- array of {Id|null, OperationTemplateId, IsRequired, Description|null}
AS
```

**Semantics:**

1. Validate `@Id` resolves to a row that is **Draft** (`PublishedAt IS NULL AND DeprecatedAt IS NULL`). Reject otherwise — "Cannot save a Published route. Create a new version first." or "RouteTemplate is deprecated."
2. Parse `@StepsJson` into a temp table with `RowIndex` (1-based; `RowIndex` IS the new `SequenceNumber`).
3. Validate every incoming row has a non-NULL `OperationTemplateId` and the FK resolves to an active OperationTemplate.
4. Validate no two incoming rows reference the **same `OperationTemplateId`** if business wants that constraint — **flag as assumption, not currently enforced; default to permissive** (engineering may legitimately repeat the same operation, e.g., two trim passes). Default: do not enforce uniqueness.
5. For incoming rows with a non-NULL `Id`, validate the row currently belongs to this `RouteTemplate.Id` (catches stale Ids / cross-Route mixups).
6. Open transaction; in order:
   - UPDATE header `Name`, `EffectiveFrom`.
   - DELETE steps whose `Id` is NOT in incoming. **Hard-delete** — RouteStep has no `DeprecatedAt`. The Draft is mutable; history is preserved on the parent Route's audit log via `OldValue` / `NewValue` snapshots, and there are no FKs to RouteStep from production tables (production references `RouteTemplate.Id`, not `RouteStep.Id`).
   - UPDATE step rows with matching `Id` — `OperationTemplateId`, `IsRequired`, `Description`, `SequenceNumber = RowIndex`.
   - INSERT step rows with NULL `Id` — `SequenceNumber = RowIndex`.
7. `Audit.Audit_LogConfigChange` with `OldValue` = pre-state snapshot, `NewValue` = full @Params + @StepsJson.
8. `COMMIT`. Emit `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId` (NewId echoed for symmetry with other SaveAll procs).

**Note on hard-delete vs soft-delete for RouteStep:** RouteStep does not carry `DeprecatedAt` in the data model — confirmed by reading `MPP_MES_DATA_MODEL.md` § RouteStep. This matches the `Location.LocationAttribute` reconciliation idiom in `Location_SaveAll` (instance variant: physical delete-where-missing / update-where-matched / insert-where-new). It does NOT match the schema-editor `LocationTypeDefinition_SaveAll` pattern (which soft-deletes via `DeprecatedAt`). Choosing the physical-delete idiom here because:
- RouteStep has no `DeprecatedAt` column to flip
- Drafts are private to the engineer until Published; intermediate step deletions need not be auditable beyond the Route-level snapshot
- Production never references a RouteStep directly — only the parent `RouteTemplate.Id`

Equally important: this is **only valid for Drafts**. The proc explicitly rejects calls against Published / Deprecated rows. Once a route is Published, its steps become immutable — `_CreateNewVersion` is the path to revisions.

### 5.3 `Parts.RouteTemplate_DiscardDraft` (NEW)

Signature:

```sql
CREATE OR ALTER PROCEDURE Parts.RouteTemplate_DiscardDraft
    @Id        BIGINT,
    @AppUserId BIGINT
AS
```

**Semantics:**

1. Resolve `@Id`. Reject if not found, if `PublishedAt IS NOT NULL`, or if `DeprecatedAt IS NOT NULL`. The proc only accepts active Drafts.
2. Capture `OldValue` snapshot of header + steps for the audit row.
3. Open transaction:
   - DELETE from `Parts.RouteStep WHERE RouteTemplateId = @Id`
   - DELETE from `Parts.RouteTemplate WHERE Id = @Id`
4. `Audit.Audit_LogConfigChange` with `EventCode = N'Deleted'`, OldValue = snapshot, NewValue = NULL.
5. COMMIT. Return `Status, Message`. (No `NewId` — entity is gone.)

**Why hard-delete?** Drafts are inherently disposable — they were never visible to production, never referenced by Lots, never cited in any cross-table FK. The `VersionNumber` slot they occupied is freed, so the next `_CreateNewVersion` for that Item can recycle it (or jump to `MAX(VersionNumber) + 1` whichever the proc chooses — current behavior is the latter, which is acceptable; an abandoned Draft of v3 followed by a new Draft becoming v4 is operationally fine, not a defect).

### 5.4 `Parts.RouteTemplate_Publish` — extension

The current proc takes `@Id, @AppUserId` only. Phase 5 needs:

- `@EffectiveFrom DATETIME2(3) NULL = NULL` — when non-NULL, UPDATE the Draft's EffectiveFrom before flipping `PublishedAt`. When NULL, the row's existing EffectiveFrom is used.
- `@Name NVARCHAR(200) NULL = NULL` — same pattern for the Name field.
- **Zero-steps guard** — reject publish if the Draft has zero `RouteStep` rows. A Published Route with no steps is nonsensical; better to fail loudly than ship a broken row.

The convention (mirroring `LocationTypeDefinition_SaveAll`) is that engineering would call `RouteTemplate_SaveAll` first to persist their meta + step edits, then call `RouteTemplate_Publish` (no overrides). The optional `@EffectiveFrom` + `@Name` overrides exist for the case where the publish-as-of date is a last-second decision; UI may default the Publish call to passing the current draft's EffectiveFrom verbatim or omit it (no functional difference).

**Implementation note:** This is a small additive change to an existing repeatable proc. The signature change is backwards-compatible because both new params are nullable with NULL defaults. Existing callers (none in production today; this is a new tab) continue to work.

### 5.5 Data Collection summary helper

The mockup's "Data Collection" column on the steps table shows a comma-joined list: e.g. `DieInfo, CavityInfo, Weight, GoodCount, BadCount`. The existing `RouteStep_ListByRoute` returns only the operation's Code and Name — it does not project the data-collection fields.

Two viable approaches:

**Approach A — extend `RouteStep_ListByRoute`** to add a `DataCollectionSummary` projected column via correlated subquery (`STRING_AGG`). Cleanest single-call shape for the view.

**Approach B — new helper proc `OperationTemplateField_SummaryByTemplates(@OperationTemplateIdsJson)`** that returns one row per template Id with `DataCollectionSummary`. The view calls it after step-list load.

**Recommendation: Approach A.** One round-trip; the view's table binding gets the column directly. The change to `RouteStep_ListByRoute` is purely additive (one more column).

Updated `RouteStep_ListByRoute` output:

```
Id, RouteTemplateId, SequenceNumber, OperationTemplateId,
OperationCode, OperationName, OperationAreaName,
DataCollectionSummary,                              -- NEW
IsRequired, Description
```

The view's row template binds the new `OperationAreaName` (already grabbable via JOIN) for the Area cell and `DataCollectionSummary` for the data-collection cell. The mockup's published table reads `templateLabel` (a synthesized "Code v1 — Name" string) — that's a view-side concat from Code + VersionNumber + Name, not a column projection requirement.

### 5.6 NQ inventory

| NQ resource | Backing proc | Used by |
|---|---|---|
| `named-query/parts/RouteTemplate_ListByItem` | `Parts.RouteTemplate_ListByItem` | Version dropdown source on Routes tab |
| `named-query/parts/RouteTemplate_Get` | `Parts.RouteTemplate_Get` | Selected-version header (badge state, EffectiveFrom display) |
| `named-query/parts/RouteStep_ListByRoute` | `Parts.RouteStep_ListByRoute` (with new column) | Step rows for the selected version |
| `named-query/parts/RouteTemplate_CreateNewVersion` | `Parts.RouteTemplate_CreateNewVersion` | "New Version" button |
| `named-query/parts/RouteTemplate_Publish` | `Parts.RouteTemplate_Publish` (extended) | Publish button |
| `named-query/parts/RouteTemplate_DiscardDraft` | NEW proc | Discard Draft button |
| `named-query/parts/RouteTemplate_Deprecate` | `Parts.RouteTemplate_Deprecate` | (optional Phase 5; arguably belongs in the version-history sub-popup not yet designed; defer unless trivial) |
| `named-query/parts/RouteTemplate_SaveAll` | NEW proc | Save button |
| `named-query/parts/OperationTemplate_ListByArea` | `Parts.OperationTemplate_List` (existing — `@AreaLocationId` param) | Cascading per-step Area → OperationTemplate dropdown |

NQ identifiers follow the camelCase + Designer-canonical `sqlType` enum convention; `BIGINT` = `3`, `NVARCHAR` = `7`, `DATETIME` = `8`, `BIT` = `6` per `feedback_ignition_nq_resource_schema.md`.

### 5.7 Entity script: `BlueRidge.Parts.Route`

New module under `script-python/BlueRidge/Parts/Route/`. Public functions:

| Function | NQ | Notes |
|---|---|---|
| `listVersions(itemId, includeDeprecated=False)` | `RouteTemplate_ListByItem` (passes `@ActiveOnly = NOT includeDeprecated`) | Returns list of dicts ordered newest-first |
| `getHeader(id)` | `RouteTemplate_Get` | Returns one dict or None |
| `getSteps(routeTemplateId)` | `RouteStep_ListByRoute` | Returns list of dicts, ordered by SequenceNumber |
| `getOperationTemplatesByArea(areaLocationId)` | `OperationTemplate_ListByArea` | Returns dict list for the per-step cascading dropdown |
| `createNewVersion(parentRouteTemplateId, effectiveFrom, appUserId=None)` | `RouteTemplate_CreateNewVersion` via `Common.Db.execMutation` | Returns `{Status, Message, NewId}` |
| `saveAll(id, name, effectiveFrom, stepsList, appUserId=None)` | `RouteTemplate_SaveAll` via `execMutation` | `stepsList` is Python list of dicts; serialized via `json.dumps` |
| `publish(id, effectiveFrom=None, name=None, appUserId=None)` | `RouteTemplate_Publish` (extended) via `execMutation` | NULLs allowed in both override params |
| `discardDraft(id, appUserId=None)` | `RouteTemplate_DiscardDraft` via `execMutation` | |
| `deprecate(id, appUserId=None)` | `RouteTemplate_Deprecate` via `execMutation` | |

Every public method routes through `BlueRidge.Common.Db` (execList / execOne / execMutation) and deep-unwraps inputs via `BlueRidge.Common.Util._u` at the entry boundary — both per project convention.

---

## 6. View Changes — Routes Tab Internals

### 6.1 Architectural choice — abandon Phase 1's bidi-`params.value` for Routes

**Recommendation: the Routes tab owns its own state.** The Phase 1 pattern (parent ItemMaster passes `editDraft.routes` as a bidi-bound Object param) was sized for a static, read-only published view. The Phase 5 surface — multi-version selector, draft editor with its own dirty state, cascading dropdowns per row — is its own mini-app whose data and lifecycle don't sit comfortably inside the parent's `editDraft`. Forcing them through bidi params pushes hundreds of fields through a binding round-trip on every keystroke; it's also a category-mismatch (the parent's "save" doesn't save Routes; Routes has its own Save).

**New contract for the tab:** receives `view.params.itemId` (BIGINT, input-only) from the parent. Holds all of its own data in `view.custom.*`. Loads data on `itemId` change via `propertyChange` script + entity-script call. Save / Publish / Discard fire their own NQ calls and refresh themselves on success.

This is a **deliberate departure from R1 in the Phase 1 design** — Phase 1 explicitly flagged the bidi-Object-param mechanism as untested and noted the fallback. The Routes tab adopts the fallback as its first choice because the workflow's complexity makes the bidi pattern an over-fit. (ContainerConfig in Phase 4 may still use the Phase 1 pattern — it's a small flat form.)

**Generalization:** this same recommendation applies to BOMs (Phase 6). See § 12 — versioned-tab pattern.

### 6.2 Tab state model (`view.custom`)

```yaml
itemId:                 (input — readonly from view.params)
versions:               []        # list of {Id, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByDisplayName}
                                  #   loaded via Route.listVersions(itemId, includeDeprecated=showDeprecated)
showDeprecated:         false     # toggle on version dropdown; rebinds versions when flipped
selectedVersionId:      null      # currently-displayed version (header + steps)
selectedHeader:         null      # dict from Route.getHeader(selectedVersionId)
mode:                   "view"    # "view" | "draft" — drives which header strip + which step table renders
opTemplatesByArea:      {}        # cache: { areaLocationId: [opTemplate dicts] }
                                  #   populated lazily on draft Area dropdown changes
areas:                  []        # list of {Id, Name} for the Area dropdown — loaded once from
                                  #   BlueRidge.Location.Location.getAllAreas() — already exists from
                                  #   Defect Codes / Downtime Codes work

# Draft-only fields. Populated by "New Version" click; cleared on Discard or successful Publish.
draftId:                null      # the Draft RouteTemplate.Id
draftEditDraft:         null      # in-flight draft state — { Name, EffectiveFrom, steps[] }
draftSelected:          null      # baseline copy after last successful Save — drives the dirty indicator
                                  # Dirty indicator: draftEditDraft != draftSelected
```

`mode == "view"` shows:
- Version selector (incl. Deprecated if `showDeprecated`) + state badge (Published / Deprecated / Draft)
- "New Version" button
- Static published-style table (current Phase 1 visual mostly preserved)
- A "Deprecate this version" button on Published rows (subject to design confirmation — see § 11 R5)

`mode == "draft"` shows:
- Draft-header strip — version selector (still browsable to other versions; navigating away with a dirty Draft triggers ConfirmUnsaved); Draft badge; EffectiveFrom date picker; Save / Discard Draft / Publish buttons
- Editable step table with cascading Area → OperationTemplate dropdowns per row, ↑/↓ arrows, ✕ remove, + Add Step at the bottom

### 6.3 Step row model (in `draftEditDraft.steps`)

```yaml
- Id:                  123          # null for newly-added rows
  SequenceNumber:      1            # derived from list index on save
  AreaLocationId:      45
  AreaName:            "Die Cast"   # cached for display; lookup-derived
  OperationTemplateId: 78
  OperationCode:       "DC-5G0"
  OperationName:       "Die Cast 5G0 Front Cover"
  OperationVersionLabel: "v1"       # cached for display
  DataCollectionSummary: "DieInfo, CavityInfo, Weight, GoodCount, BadCount"  # cached for the column
  IsRequired:          true
  Description:         null
```

`AreaLocationId` is the per-row primary state driving the cascading dropdown. `OperationTemplateId` is the secondary; when `AreaLocationId` changes, `OperationTemplateId` and its display caches reset to the first option in `opTemplatesByArea[newAreaId]` (or null if empty).

### 6.4 Cascading dropdown UX

Per-row, two dropdowns side-by-side in the same cell (or two adjacent cells per the mockup):

1. **Area dropdown** — options from `view.custom.areas`. `bidirectional` bind to `instance.AreaLocationId`. `onChange` script:
   - Set `instance.AreaLocationId = newValue`
   - If `view.custom.opTemplatesByArea[newValue]` is unset, call `Route.getOperationTemplatesByArea(newValue)`, store in cache
   - Set `instance.OperationTemplateId` to first option's Id (or null)
   - Sync display caches (`AreaName`, `OperationCode`, `OperationName`, `OperationVersionLabel`, `DataCollectionSummary`)
2. **Operation Template dropdown** — options from `view.custom.opTemplatesByArea[instance.AreaLocationId]`. `bidirectional` to `instance.OperationTemplateId`. `onChange` script: sync display caches.

The Data Collection summary is **not** re-fetched per dropdown change — it's projected onto each OperationTemplate dropdown option's `value.dataCollectionSummary` field at load time, and the row's display cache is rewritten from the picked option. This keeps the surface a single round-trip per OperationTemplate list load (per Area) and no round-trip per dropdown change.

### 6.5 Add Step / Remove Step / Reorder

- **+ Add Step** appends a blank row to `draftEditDraft.steps` with all fields null. The Area dropdown shows nothing selected; user picks. Save proc validates `OperationTemplateId IS NOT NULL` on every incoming row and rejects unfilled rows with a clear message.
- **✕ Remove** — splices the row out of `draftEditDraft.steps`. Bumps the dirty indicator.
- **↑ / ↓** — swap with adjacent row in `draftEditDraft.steps`. `SequenceNumber` is derived from index at save time — no need to renumber in the draft state.

No drag-and-drop (per project convention).

### 6.6 Dirty indicator + ConfirmUnsaved

The Routes tab is itself an editor with `draftEditDraft` / `draftSelected`. The dirty indicator goes on the **tab-level** Save button (e.g., button label "Save ●" when dirty), NOT on the page-level ItemMaster TitleBar — Routes editing is independent of Item meta editing.

Discarding navigation away while dirty:

- **Switching to a different version in the version dropdown while dirty** — open `ConfirmUnsaved` popup (existing pattern from `LocationTypeEditor`). User picks Save & Switch, Discard & Switch, or Cancel.
- **Switching to a different tab on the page (Tabs strip)** — same `ConfirmUnsaved` popup. The popup's reply message routes back to the Routes tab via page-scoped messaging (per `mpp-confirm-unsaved-popup-pattern`).
- **Clicking a different item in the left panel** — caught by the page-level item-row-click handler. If any tab is dirty, open the same ConfirmUnsaved popup. (Page-level coordination; see § 6.8.)

### 6.7 Workflow scripts (sketch)

```python
# +Add Step button (events.component.onActionPerformed, scope: G)
draft = self.view.custom.draftEditDraft
steps = list(draft['steps'])
steps.append({
    'Id': None, 'SequenceNumber': len(steps) + 1,
    'AreaLocationId': None, 'AreaName': '',
    'OperationTemplateId': None, 'OperationCode': '', 'OperationName': '',
    'OperationVersionLabel': '', 'DataCollectionSummary': '',
    'IsRequired': True, 'Description': None
})
draft['steps'] = steps
self.view.custom.draftEditDraft = dict(draft)  # force binding re-eval

# Save button
draft = self.view.custom.draftEditDraft
result = BlueRidge.Parts.Route.saveAll(
    id            = self.view.custom.draftId,
    name          = draft['Name'],
    effectiveFrom = draft['EffectiveFrom'],
    stepsList     = draft['steps']
)
BlueRidge.Common.Ui.notifyResult(result, 'Route saved', 'Route saved.', 'Save failed')
if result.get('Status'):
    # Rebaseline the dirty indicator
    self.view.custom.draftSelected = dict(draft)
    # Refresh the version list so the Draft's updated Name shows in the dropdown
    self.view.custom.versions = BlueRidge.Parts.Route.listVersions(
        self.view.params.itemId,
        includeDeprecated=self.view.custom.showDeprecated
    )

# Publish button (UI requires Save success before Publish — see § 6.9 for ordering)
result = BlueRidge.Parts.Route.publish(
    id            = self.view.custom.draftId,
    effectiveFrom = self.view.custom.draftEditDraft['EffectiveFrom'],  # optional override
    name          = self.view.custom.draftEditDraft['Name']
)
BlueRidge.Common.Ui.notifyResult(result, 'Route published', 'Route published.', 'Publish failed')
if result.get('Status'):
    publishedId = self.view.custom.draftId
    self.view.custom.draftId = None
    self.view.custom.draftEditDraft = None
    self.view.custom.draftSelected  = None
    self.view.custom.mode = 'view'
    self.view.custom.versions = BlueRidge.Parts.Route.listVersions(self.view.params.itemId, self.view.custom.showDeprecated)
    self.view.custom.selectedVersionId = publishedId
    # Header + steps refresh from the property-change cascade

# Discard Draft button (Confirm popup precedes the call — see § 6.10)
result = BlueRidge.Parts.Route.discardDraft(id=self.view.custom.draftId)
BlueRidge.Common.Ui.notifyResult(result, 'Draft discarded', 'Draft discarded.', 'Discard failed')
if result.get('Status'):
    self.view.custom.draftId = None
    self.view.custom.draftEditDraft = None
    self.view.custom.draftSelected  = None
    self.view.custom.mode = 'view'
    self.view.custom.versions = BlueRidge.Parts.Route.listVersions(self.view.params.itemId, self.view.custom.showDeprecated)
    # selectedVersionId — fall back to the highest-Id active Published; default the dropdown to it
```

### 6.8 Cross-tab dirty coordination

Page-level concern, not Routes-tab-internal. The simplest model: each editable tab broadcasts `isTabDirty: bool` via a page-scoped message on every dirty-state change; the parent ItemMaster keeps `view.custom.dirtyTabs = { containerConfig: false, routes: false, boms: false }` and consults that map before allowing the left-panel item click or the AddItem modal Create.

**Deferred to a follow-up coordination pass** (probably bundled with Phase 6 since BOMs has the same need). Phase 5 ships with: **per-tab ConfirmUnsaved** on its own intra-tab navigation (version dropdown, tab strip leaves Routes); **no page-level item-click guard yet** (operator can stomp on a Routes draft by clicking another item — recoverable since Draft persists in DB once Saved, but unsaved in-memory edits are lost).

Acknowledge as a Phase 5 limitation; lift the limitation in Phase 6's pass.

### 6.9 Implicit Save-then-Publish (UX detail)

The mockup's Publish button is enabled at all times when in Draft mode. Two implementation options:

**Option A — Two-step explicit:** User must click Save before Publish. Publish is disabled (or fails with "Save first") while dirty.

**Option B — Save-as-part-of-Publish (chained):** Publish click first runs SaveAll silently with current draft state, then runs Publish (no overrides needed since the just-saved state is what gets published). One client-side action, two proc calls in series.

**Recommendation: Option B.** Better UX. Implement as two sequential `execMutation` calls in `Route.publish` wrapper — if SaveAll Status=0, abort and surface its message; otherwise call Publish. Both are transactional individually; the surface area for a half-state is narrow (Publish proc itself enforces only-Drafts and zero-steps; SaveAll committed the latest content; Publish flips the bit).

The downside: a sub-100ms window exists where SaveAll succeeded but Publish failed (e.g., gateway hiccup mid-call). The Draft is then up-to-date but unpublished — recoverable by clicking Publish again. Acceptable.

### 6.10 ConfirmUnsaved use

The popup from `Components/Popups/ConfirmUnsaved` (per `mpp-confirm-unsaved-popup-pattern`) is reused. Three trigger points in Routes:

1. **Discard Draft button** while dirty → ConfirmUnsaved with action verbs aliased to {Save & Discard / Discard / Cancel} — wait, this needs care. The semantics differ from a generic close: "Save & Discard" makes no sense. **Better:** when user clicks Discard Draft, open a smaller bespoke confirm popup ("Discard the current Draft? This deletes the unpublished version entirely.") with just `Confirm` / `Cancel` — not `ConfirmUnsaved`. Reuse only the pattern, not the literal popup.
2. **Version dropdown change** while dirty → `ConfirmUnsaved`: Save / Discard / Cancel. Save persists current draft; Discard either reverts in-memory edits (if Draft was saved before — `draftEditDraft = dict(draftSelected)`) OR if Draft has never been saved yet, runs `_DiscardDraft` for true deletion. Cancel keeps the dropdown selection on the current Draft.
3. **Tab strip click leaving Routes** while dirty → same as #2.

For #1, write a small `ConfirmDestructive` popup (sibling to `ConfirmUnsaved`). Or — simpler — use Ignition's `system.perspective.openPopup` with the same `ConfirmUnsaved` view but with the `discardLabel` param set to "Discard Draft" and the `saveLabel` param overridden to "Save Anyway"... no, that confuses the user.

**Recommendation:** add a new `Components/Popups/ConfirmDestructive` view (params: `title`, `message`, `confirmLabel`, `cancelLabel`, `popupId`, `replyMessage`). Two-button. Used here for Discard Draft, future-reused for any "are you sure?" destructive action (e.g., Deprecate buttons elsewhere). Keep `ConfirmUnsaved` for the three-button save/discard/cancel pattern.

### 6.11 File inventory — view changes

| Path | Action | Notes |
|---|---|---|
| `views/BlueRidge/Components/Parts/ItemMaster/Routes/view.json` | **Edit (Designer)** — file already exists with the Phase 1 read-only published shell. Refactor for Phase 5 surface. | Per `feedback_ignition_view_edit_boundary` memory: edits to existing view.json files should be done in Designer, not file edits. Plan calls this out explicitly. |
| `views/BlueRidge/Components/Popups/ConfirmDestructive/{resource.json, view.json}` | **NEW (file write)** | New views can safely be file-written. |
| `views/BlueRidge/Views/Parts/ItemMaster/view.json` | **Edit (Designer)** — change the Routes Embedded View's `props.params` from passing `editDraft.routes` (bidi) to passing `itemId` (input only) | Per § 6.1. |

### 6.12 Stylesheet

No new classes needed; mockup's Routes panels already use existing utility classes (`badge`, `badge-published`, `badge-draft`, `data-table`, `arrow-btn`, `arrow-btn disabled`, `arrows`, `select`, `search-input`, `detail-panel`, `btn`, `btn-sm`, `btn-primary`, `btn-secondary`, `btn-icon`). Verify present at implementation time; add only if missing.

---

## 7. Edge Cases

### 7.1 Browsing history without leaving the page

Engineer opens 5G0 Front Cover, clicks Routes tab. Version dropdown shows `v2 (Published)` selected by default (highest active Published version per `_GetActiveForItem` semantics). Engineer picks `v1 (Deprecated)` — table refreshes to v1's frozen steps. Header badge shows "Deprecated"; "New Version" button still available (cloning a Deprecated version into a fresh Draft is allowed). No edit controls.

### 7.2 Show Deprecated toggle

Default: version dropdown filters Deprecated rows out (`includeDeprecated = false`). A small "Show all versions" checkbox or chip next to the dropdown flips `view.custom.showDeprecated` and triggers `versions` reload.

### 7.3 Active LOTs on a Route being Deprecated

Per `_Deprecate`'s proc docs: **no FK guard.** Production rows reference an immutable snapshot on each Lot, so deprecating a RouteTemplate doesn't break in-flight work. The UI may surface "Note: deprecating does not affect Lots already in production on this route" inline near the Deprecate button.

### 7.4 Deprecating a Published version while a Draft exists for the same Item

Allowed. The Draft is an independent record; deprecating v2 (Published) while v3 (Draft) exists does not block. After Deprecate, the version dropdown shows v2 (Deprecated) and v3 (Draft); engineer continues editing v3 and publishes it as the new active version.

### 7.5 In-flight Work Orders pointing at a route version

`Workorder.WorkOrder` (per `MPP_MES_DATA_MODEL.md`) carries `RouteTemplateId` on the WO row at creation. Deprecating the RouteTemplate has no effect on the WO — same reasoning as § 7.3: WOs in flight reference the immutable snapshot. New WOs will use whatever `_GetActiveForItem` returns at WO-create time. No UI guard needed.

### 7.6 Two engineers create a Draft for the same Item

Race window. Currently `_CreateNewVersion` does not check for an existing active Draft. § 6 R3 hardens this — the proc rejects the second caller with a clear message ("A Draft for this Item already exists. Open it or have its owner publish/discard first."). The version-list query the UI displays will show the existing Draft already, so the user has visibility; the proc-side guard handles the timing race.

### 7.7 Operator opens an Item whose RouteTemplate has no Published version (only Drafts)

Production code (`_GetActiveForItem`) returns no row; an operator scan would fail with "no active route for this Item." This is consistent with engineering not having finished setup. Routes tab in the Config Tool shows the Draft (state badge "Draft"); engineer publishes it, then operator can proceed. No special UX needed beyond what the version list already shows.

### 7.8 Operation Template referenced by an existing step gets Deprecated

The Operation Template Editor (separate Phase) Deprecate proc currently rejects if any active `RouteStep` references the template (per phased-plan §`Parts.OperationTemplate_Deprecate`). So in practice this race is closed at the OperationTemplate side. If somehow a deprecated OperationTemplate ends up referenced from a published RouteStep, the per-row display shows the cached name + a small visual flag ("Operation deprecated"). For Phase 5 Routes tab, the UI does NOT detect this proactively — but the OperationTemplate dropdown filter (only active) prevents engineering from picking a Deprecated template into a Draft.

### 7.9 RouteStep referencing a soft-deleted Area

Won't happen — `Location.Location` doesn't soft-delete Areas (`DeprecatedAt` exists but Area-level deprecation is rare; if it does happen, FK to OperationTemplate.AreaLocationId prevents the row from disappearing). The view's Area-dropdown options are sourced from `getAllAreas()` which already filters appropriately.

### 7.10 EffectiveFrom in the past

Allowed. The use case: engineering codifies an existing field practice that's been in effect since some prior date. Production reads `_GetActiveForItem(now)` which picks the highest VersionNumber whose `EffectiveFrom <= now` — a back-dated Publish would immediately take effect (or override a newer Publish whose EffectiveFrom is later). Engineering owns this decision. Client-side UI may surface a warning but does not block.

### 7.11 EffectiveFrom in the future

Allowed and intended — schedule a process change to take effect on a future date. `_GetActiveForItem(now)` picks the highest VersionNumber whose `EffectiveFrom <= now`, so a future-effective Published row stays invisible until its date arrives. Engineering can publish weeks in advance.

### 7.12 Two routes published with identical EffectiveFrom

`_GetActiveForItem` returns `TOP 1 ... ORDER BY rt.VersionNumber DESC` — higher VersionNumber wins. Deterministic. No UI guard needed; both versions are valid history.

---

## 8. Assumptions to Confirm With Jacques

| # | Assumption | If wrong … |
|---|---|---|
| A1 | The single-Draft-per-Item constraint is correct — at most one Draft allowed at a time per `ItemId`. | If multi-Draft is desired (e.g., parallel engineering experiments), drop the guard from `_CreateNewVersion` and the UI presents a Draft picker in the dropdown. |
| A2 | Hard-delete is acceptable for `RouteStep` rows when reconciling a Draft `_SaveAll`. (RouteStep has no `DeprecatedAt`; no FKs from production reference RouteStep directly — production references the parent `RouteTemplate.Id` only.) | If soft-delete is desired (e.g., to reconstruct mid-edit history), add `DeprecatedAt` to `RouteStep` via a migration + change the SaveAll reconciliation. |
| A3 | Discard Draft is hard-delete (DELETE both header and steps). | If preferred to keep an audit trail of discarded drafts, change `_DiscardDraft` to set `DeprecatedAt = SYSUTCDATETIME()` instead — but then `_CreateNewVersion` must skip deprecated Drafts when computing next VersionNumber. |
| A4 | The Routes tab abandons Phase 1's bidi-`params.value` pattern in favor of self-sufficient `view.params.itemId` + own `view.custom`. (Rationale § 6.1.) | If Jacques prefers the bidi-Object pattern be exercised here too, redesign § 6 to push the entire `versions[]`, `selectedVersionId`, `draftEditDraft` etc. into the parent's `editDraft.routes` slice. Adds round-trip cost; doubles binding edges. Recommend against. |
| A5 | The version dropdown shows all states (Draft / Published / Deprecated) when "Show all versions" is toggled. Default hides Deprecated; Drafts always shown when present. | If preferred to hide Drafts from anyone but the Draft's author, add `CreatedByUserId` filter to the dropdown query. Multi-user-Draft territory; tied to A1. |
| A6 | `_Publish` is extended (not duplicated) to take optional `@EffectiveFrom` and `@Name` overrides + a zero-steps guard. | If keeping `_Publish` lean, add a separate `_PublishWithMeta` proc and route the Routes tab through that. Cosmetic preference. |
| A7 | Save-then-Publish is chained client-side (single button press → SaveAll then Publish). | If preferred two-step (Publish disabled until clean), set `Publish` enabled condition to `editDraft == selected`. UX preference. |
| A8 | A new `ConfirmDestructive` popup is built (two-button: Confirm + Cancel) — used for Discard Draft and future destructive actions. Distinct from `ConfirmUnsaved` (three-button: Save / Discard / Cancel). | If preferred to reuse `ConfirmUnsaved` with creative label overrides for Discard Draft, the popup must lose its Save button at runtime — its current shape has 3 buttons always present. Marginally cleaner to build the new popup. |
| A9 | Routes tab's dirty state is independent of the page-level Item-meta dirty state. Page-level dirty indicator does NOT light up when only Routes draft is dirty (and vice versa). | If preferred unified, add `Routes.isDirty` to `view.custom.dirtyTabs` map on parent (§ 6.8 deferred). Reasonable enhancement; not blocking. |
| A10 | The Data Collection column reads from a new projected column on `RouteStep_ListByRoute` (per § 5.5 Approach A — extend existing proc). | If preferred non-additive, write a separate helper proc. Cosmetic. |
| A11 | Show Deprecated affects only Routes — not BOMs, not Quality Specs (each owns its own toggle state). | Likely correct. Each tab is its own surface. |

---

## 9. Open Questions / Risks

| # | Item | Severity | Mitigation / next step |
|---|---|---|---|
| R1 | The bidi-`params.value` pattern (Phase 1 R1) is still untested in the project. Routes opts out (§ 6.1), so Phase 5 doesn't validate it either. ContainerConfig (Phase 4) is the remaining first-use site. | Medium | Validate during Phase 4 smoke. If it fails, Phase 5's choice in § 6.1 is vindicated and ContainerConfig falls back too. Re-explore for any future tab where a flat form is shared with parent state. |
| R2 | The version dropdown displays all versions including Deprecated and Draft. With many versions over a route's lifetime (5+ years of revisions), the dropdown could grow large. | Low | Default to last-N (e.g., 5) Published + any Draft; "Show all" expansion lifts the cap. Not Phase 5 critical; revisit if a real-world Item exceeds 10 versions. |
| R3 | The single-Draft-per-Item guard in `_CreateNewVersion` is a behavioral change — currently the proc allows multiple Drafts. The hardening adds a check; if any existing test fixture creates two Drafts in series, it will fail. | Medium | Inspect `0009_Parts_Process/020_RouteTemplate_crud.sql` before changing the proc; update test if needed. Likely the test only creates one Draft per Item. |
| R4 | The page-level cross-tab dirty coordination (§ 6.8) is deferred to Phase 6. Operator can lose unsaved in-memory draft edits by clicking another item. | Low | Acceptable trade-off — Saved drafts persist; only the in-memory delta is lost. Document in the user-facing release note. Lift in Phase 6. |
| R5 | The mockup does not show a per-version Deprecate button explicitly. The mockup's New Version button is the only Published-mode action. Should Deprecate live on the Routes tab at all, or in a separate version-history sub-popup? | Open question | Recommend a small "Deprecate this version" button in the Published-mode header strip, gated to active-Published rows (not the active production row — must require confirmation: deprecating the only active Published version means no production until a new one Publishes). Confirm with Jacques. |
| R6 | "Active production version" — the UI currently has no visual cue distinguishing the version that `_GetActiveForItem(now)` would return from other Published versions. With multiple future-dated or back-dated Publishes coexisting, this is ambiguous. | Medium | Add a small "Active now" pill on the version dropdown option that currently satisfies `_GetActiveForItem(SYSUTCDATETIME())`. Cosmetic enhancement; not blocking Phase 5 ship. |
| R7 | The OperationTemplate dropdown filters to **active** templates only. Engineering may legitimately want to reference a Deprecated template in a Draft (e.g., to compare). | Low | Lock dropdown to active. Engineers needing to compare a deprecated template's behavior can open the Operation Template Library (separate page). |
| R8 | `RouteTemplate_SaveAll` accepts no `@OldEffectiveFrom` / `@OldName` optimistic-lock parameters. Two engineers editing the same Draft simultaneously will lose one set of edits (last write wins). | Low | Acceptable for Phase 5 — same risk shape as every other compound editor in the project (LocationTypeEditor, future BomEditor). Optimistic concurrency adds complexity for a workflow that's primarily single-user-per-Draft (per A1 single-Draft guard). |
| R9 | `_DiscardDraft` deletes the Draft + steps but the `Audit.ConfigLog` row remains. Discarded-draft audit data could grow if engineers churn drafts. | Very low | Discarded-draft log rows are part of the regular audit retention policy (OI-35 territory). No phase 5 action. |
| R10 | The `_Publish` proc's new zero-steps guard breaks any test that intentionally publishes an empty route. | Low | Inspect test suite (likely no such test; routes-with-zero-steps aren't valid). Update if found. |
| R11 | Step row Add → blank dropdowns → user navigates away → unsaved Draft now contains an invalid row (OperationTemplateId IS NULL). Save will reject. UX needs to surface this clearly so the user doesn't get stuck. | Low | Save error message includes the row index; consider also: highlight rows with unset OperationTemplateId in red border in the table. |

---

## 10. What "Done" Looks Like for Phase 5

1. SQL test suite: `937/937 → 9XX/9XX` — at least one passing test for each of: `RouteTemplate_SaveAll` (create-mode rejection: no — Draft must already exist; update-mode success; update-mode rejects on Published; update-mode rejects orphan StepId), `RouteTemplate_DiscardDraft` (Draft hard-delete; rejects on Published; rejects on Deprecated), `RouteTemplate_Publish` (zero-steps guard; EffectiveFrom override applied; Name override applied), `RouteTemplate_CreateNewVersion` (existing-Draft guard).
2. `scan.ps1` returns green.
3. Routes tab in `/items` for 5G0 Front Cover renders:
   - Version dropdown lists `v2 (Published)` (default selected) and `v1 (Deprecated)` if "Show all" toggled.
   - Published-mode table renders v2's steps with the Data Collection column populated.
4. Click **New Version** → Draft v3 created, mode switches to Draft, table becomes editable. Steps populated from v2.
5. Edit a step: change Area → OperationTemplate dropdown repopulates → pick new OpTemplate → Data Collection column updates. Dirty indicator on Save button flips.
6. Click **+ Add Step** → empty row appended. Click ✕ on a row → row removed. Click ↑ / ↓ on a row → row moves.
7. Click **Save** → toast "Route saved." → dirty indicator clears.
8. Click **Publish** (chained Save+Publish per § 6.9) → toast "Route published." → version dropdown updates, v3 now shows as Published with state badge; mode returns to view.
9. Click **New Version** again → Draft v4 created. Switch version dropdown to v4. Edit. Click **Discard Draft** → confirm popup → confirm → toast "Draft discarded." → v4 disappears from version list.
10. While editing v5 Draft, click v3 in the version dropdown → ConfirmUnsaved opens. Click "Save & Switch" → Draft persists, dropdown changes to v3 (view mode).
11. Open browser to a second Item; verify the Routes tab loads its own data (no leakage from 5G0).
12. Audit log entries for every mutation: `Created` for new Drafts; `Updated` for SaveAll; `Updated` for Publish; `Deleted` for DiscardDraft; `Deprecated` for Deprecate (if a Deprecate button is added per R5).

No green-checkmark items: this phase does not test browser-side full UX in CI; manual smoke per the steps above.

---

## 11. References

- `MPP_MES_DATA_MODEL.md` — § Parts schema (RouteTemplate, RouteStep, OperationTemplate, OperationTemplateField, DataCollectionField)
- `MPP_MES_FDS.md` — FDS-03-005, FDS-03-007 through FDS-03-013, FDS-03-017a (data collection capture)
- `MPP_MES_PHASED_PLAN_CONFIG_TOOL.md` § Phase 5 — Process Definition: Routes & Operations (matrix of existing procs)
- `mockup/index.html` lines 499–647 (Routes tab — Published + Draft modes)
- `sql/migrations/repeatable/R__Parts_RouteTemplate_*.sql` (existing procs — Create / CreateNewVersion / Get / GetActiveForItem / ListByItem / Publish / Deprecate)
- `sql/migrations/repeatable/R__Parts_RouteStep_*.sql` (discrete RouteStep procs — kept; not used by the bundled SaveAll from this editor)
- `sql/migrations/repeatable/R__Location_LocationTypeDefinition_SaveAll.sql` — **reference impl** for Phase 5's new `RouteTemplate_SaveAll`
- `sql/migrations/repeatable/R__Location_Location_SaveAll.sql` — secondary reference (physical-delete reconciliation idiom for value rows; closer match than the schema-editor variant since RouteStep has no `DeprecatedAt`)
- `docs/superpowers/specs/2026-05-19-item-master-view-shell-design.md` — Phase 1 (extends from here)
- `docs/superpowers/plans/2026-05-19-item-master-view-shell.md` — Phase 1 plan (mirror its structure)
- `BlueRidge/Components/Popups/LocationTypeEditor/view.json` — reference editor with editDraft + dirty indicator + Cancel + Deprecate
- `BlueRidge/Components/Popups/ConfirmUnsaved/view.json` — reuse for version-change-while-dirty + tab-leave-while-dirty
- Memory: `mpp-bundled-save-pattern`, `mpp-confirm-unsaved-popup-pattern`, `project-mpp-item-master-pattern`, `ignition-message-scope-view-vs-page`, `feedback_ignition_nq_resource_schema.md`, `feedback_ignition_view_edit_boundary.md`
- `ignition-context-pack/02_perspective_views.md`, `04_named_queries.md`, `07_conventions_and_antipatterns.md` (versioned-entity workflow section)

---

## 12. Versioned-Tab Pattern (Generalization to BOMs and Beyond)

This section pulls the mechanics that generalize. BOMs (Phase 6) should share these. Agent D's parallel BOMs design should converge on the same shape.

### 12.1 Mechanics that DO generalize

1. **Three-state lifecycle.** Draft → Published → Deprecated, gated by `PublishedAt` and `DeprecatedAt` columns on the parent entity. Same allowed-transitions table from § 4.
2. **Bundled `_SaveAll` proc.** Parent meta + child rows as JSON; reconciliation order = update parent → delete-where-missing → update-where-matched → insert-where-new → audit → commit. Per `mpp-bundled-save-pattern` memory.
3. **Bundled `_DiscardDraft` proc.** Hard-deletes the Draft header + its children. Rejects on non-Draft state. Children referenced anywhere else? — for BomLine, check FKs to production tables (likely `Workorder.AllocationEvent.BomLineId` or equivalent — if so, soft-delete is mandatory for BomLine, in which case the BOM SaveAll uses the soft-delete variant). For RouteStep, no such FK, hard-delete is fine.
4. **Extended `_Publish` proc.** Optional `@EffectiveFrom` and `@Name` overrides; zero-children guard.
5. **Single-Draft-per-parent constraint.** `_CreateNewVersion` rejects if an active Draft exists.
6. **Version selector dropdown in the tab.** Loaded via `_ListByParent(@ParentId, @ActiveOnly)`. Filtered by Show-Deprecated toggle. State badge inline.
7. **Two-mode tab UX.** view-mode (selectable version, read-only table, New Version button) vs draft-mode (Effective Date picker, Save / Discard / Publish buttons, editable table).
8. **EditDraft / selected dirty-indicator state on the tab.** Save baseline is `selected`; dirty is `editDraft != selected`; Save commits and rebaselines.
9. **ConfirmUnsaved popup** on version-change-while-dirty and tab-leave-while-dirty.
10. **ConfirmDestructive popup** on Discard Draft.
11. **Tab owns its state** (`view.params.itemId` + own `view.custom`); does NOT push compound state through bidi-`params.value` from the parent. Per § 6.1.
12. **No drag-and-drop**; ↑ / ↓ arrows for reorder.
13. **EditDraft children carry display caches** (Name, Code, version label, summary string) populated on dropdown selection so the row table renders without per-row N+1 lookups.
14. **Chained Save-then-Publish** behind a single Publish button (per § 6.9).
15. **NQ naming + sqlType conventions** per project standard.
16. **Entity script** under `BlueRidge.<Domain>.<Entity>` (`Common.Db` only does DB I/O; `_u()` deep-unwrap at every public-method entry).

### 12.2 Mechanics that DO NOT generalize — Routes-specific

1. **Cascading Area → OperationTemplate dropdown.** Routes has a two-step picker per row. BOMs has a different picker — search-an-Item-by-PartNumber (likely a popup picker or autocomplete). The mechanism is the same (per-row dropdown with `bidirectional` binding + display cache), but the data source and lookup logic are different.
2. **OperationTemplate versioning.** Routes references OperationTemplates which are themselves versioned. The dropdown's labeled value embeds version info (`DC-5G0 v1`). BOMs references Items (not Item versions — Items are not versioned in the same Draft/Published sense), so the dropdown is simpler.
3. **Data Collection column.** Routes-specific projection. BOMs has different per-line context (Qty, UoM).
4. **Step's `IsRequired` flag.** Routes carries it; BOMs may not (BomLine does not have an `IsRequired` column per the data model — every line in a BOM is required by virtue of being on the BOM).
5. **`RequiresSubLotSplit` informational display.** Routes-specific; surface per step.

### 12.3 What Agent D's BOMs design should match

- Same § 4 state machine table
- Same § 5.1 inventory shape (`Bom_SaveAll` mirrors `RouteTemplate_SaveAll`; existing `Bom_CreateNewVersion`, `Bom_Publish`, `Bom_Deprecate`, `Bom_Get`, `Bom_ListByParentItem` are present)
- Same § 5.4 `_Publish` extension shape
- Same § 5.3 `_DiscardDraft` shape (with FK-guard variation per § 12.1 #3 — check `Workorder` schema for any FK to `BomLine`)
- Same § 6.1 self-sufficient tab architecture (`view.params.itemId` + own `view.custom`; NOT bidi-`params.value`)
- Same § 6.6 ConfirmUnsaved / § 6.10 ConfirmDestructive popup reuse
- Same § 6.9 chained Save-then-Publish UX
- Same § 8 assumptions A1, A2 (with FK variation), A3, A4, A6, A7, A8, A9, A11

Reconciliation between Routes and BOMs designs is Jacques's call; both should land before either of the two phases starts implementation, so the patterns are coherent.

---
