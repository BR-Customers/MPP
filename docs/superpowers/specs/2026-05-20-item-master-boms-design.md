# Item Master — BOMs Versioning Workflow (Phase 6 of 8)

**Date:** 2026-05-20
**Status:** Draft — pending Jacques review
**Scope:** Wire the Item Master `BOMs` tab from a static published-only display (Phase 1 shell) into a full versioned-entity editor with Draft → Published → Deprecated lifecycle. Backend procs + NQs + entity script + view edits to the existing tab shell.

**Prerequisites:** Phase 1 (view shell — landed 2026-05-19) and Phase 2 (parent DB read paths — Agent B; R1 bidi smoke superseded by the convention update below). Does NOT depend on Phase 3 (Item Save) or Phase 4 (ContainerConfig save). MAY land before or after Phase 5 (Routes) — they're symmetric versioned-entity workflows.

---

## 0 — Convention reconciliation (added 2026-05-20)

This spec predates the **per-section ownership** convention codified in the `project_mpp_item_master_pattern` memory (2026-05-20 rev). The convention is now authoritative; sections of this spec that contradict it MUST be updated during implementation. The deltas are surgical (medium retrofit, NOT a rewrite — most of the spec stands):

| What this spec says | What the convention requires |
|---|---|
| **D4 (lines 193-227):** `editDraft.boms.activeVersion` lives on the parent ItemMaster view; passed bidirectionally via `view.params.value` as an Object param. | **Drop `editDraft.boms` from the parent entirely.** The BOMs tab embed owns its own `view.custom.selected` + `view.custom.editDraft` LOCALLY. The embed receives only `params.value: bomId` (BIGINT, input-only). |
| **§7.1 (lines 360-395):** flex-repeater `instances` binds to `view.params.value.activeVersion.lines`. Mutations bidi-propagate back to parent's `editDraft.boms.activeVersion.lines`. | Repeater binds to **`view.custom.editDraft.activeVersion.lines`** (the embed's local state). Line mutations write to local state; no bidi back to parent. |
| **§7.3 (lines 444-454):** six message handlers on the parent (`bomActiveVersionChanged`, `bomVersionListRefresh`, `bomLineMoveUp`, etc.) mutate parent's `editDraft.boms.*`. | These handlers move INTO the BOMs embed (they're now intra-tab, not cross-tab). The parent's only BOM-aware message handler is the generic `sectionDirtyChanged` listener that updates `view.custom.sectionDirty.boms`. |
| **§7.5 / Plan Task 19:** parent mutates `editDraft.boms.activeVersion.lines` from child messages. | Parent does NOT touch BOMs state. Save/Discard live inside the BOMs embed and are triggered either by the embed's local buttons OR by `sectionSaveRequested` / `sectionDiscardRequested` from the parent (sent when the ConfirmUnsaved popup resolves). |
| **D3 (lines 184-189):** "BOMs tab lifecycle actions are ISOLATED" relied on the parent's page-level Save button being smart enough to skip BOMs. | Isolation is now **enforced architecturally** — there is no page-level Save button for BOMs. The embed has its own `[Save Draft]`, `[Publish]`, `[Discard Draft]` buttons. |
| **(new requirement, not in this spec)** | **`sectionDirty.boms` tracks unsaved DRAFT LINE EDITS only.** Publish / Deprecate / Discard-Draft are state-machine transitions, NOT "section save" events — they do NOT fire `sectionDirtyChanged` (they fire their own success/error toasts and refresh the embed's `selected` directly). Conflating publish state with section-dirty would block tab/item switching after a successful Publish, which is wrong. |

**Page-scoped messages introduced by the convention** that the BOMs embed must wire:

- **Emit (embed → parent):** `sectionDirtyChanged {section: "boms", isDirty: <bool>}` on every dirty-state transition (entering Draft edit mode flips dirty; SaveAll Draft / Discard Draft / Publish flips it back).
- **Listen (parent → embed):** `sectionSaveRequested {section: "boms"}` — embed responds by running its own SaveAll. `sectionDiscardRequested {section: "boms"}` — embed responds by reverting local editDraft to selected.

The rest of this spec — the proc surface, NQ shapes, entity script, mockup line references, lifecycle state machine, Phase 6 task ordering — stands as written. The retrofit is to **WHERE** state lives (embed-local instead of parent-bundled) and **HOW** dirty propagates (page-scoped message instead of bidi binding). The proc-side semantics and the embed-internal interaction model are unchanged.

---

## 1. Goals

Stand up the **BOMs tab** as a fully interactive versioned-entity editor that mirrors `mockup/index.html` §"Tab: BOMs" (lines 651–773) and `mockup/index.html`'s `bomsNewVersion` / `bomsDiscard` / `bomsPublish` / `bomsAddRow` / `bomsDeleteRow` / `bomsMoveRow` JavaScript handlers (lines 3493–3548).

Phase 6 deliverables:

- Real DB reads — `Parts.Bom` versions for the active Item populate the version dropdown; selected version's `Parts.BomLine` rows render in the table.
- Two display modes per the mockup:
  - **Published mode** — read-only line table for any Published (or Deprecated, optionally) version. `[New Version]` button.
  - **Draft mode** — editable line table with `[+ Add Component]`, per-row `[× Remove]`, per-row `[↑]` / `[↓]` arrows, an Effective Date input, `[Save Draft]`, `[Discard Draft]`, and `[Publish]` buttons.
- Full versioning lifecycle: create new draft (clones prior published lines), edit draft lines, save draft to DB without publishing, publish (with validation), discard draft (physical delete), deprecate a published version.
- One draft per ParentItemId at a time (enforced via filtered UNIQUE index).
- BomLine reordering via array-index → SortOrder reconciliation on Save (no `_MoveUp` / `_MoveDown` per-click procs, per conventions pack v1.2 §"Save semantics").
- BOMs tab's lifecycle actions stay INSIDE the tab — independent of the page-level Item Save (rationale in §5).

---

## 2. Non-Goals (deliberately deferred)

| Capability | Deferred to |
|---|---|
| `Parts.Bom_BulkLoadFromSeed` for Flexware cutover import (per FDS-14-005) | Cutover work — Phased Plan §16. One-shot proc; separate work item, not part of the editor. |
| `Parts.Bom_GetActiveForItem(@AsOfDate)` consumer wiring — driven by Plant Floor production at scan-in | Arc 2 Phase 1 (Plant Floor). Proc is in scope here, but only the read path lands; no consumers in Arc 1. |
| BOM Comparison view (side-by-side diff between two versions) | Out of scope. Single-version-at-a-time editor only. Mentioned in Phased Plan v1.7 §6 as Phase 6 deliverable; deferred — Audit Log (Config Log Browser, landed 2026-05-19) already shows old/new payload diffs per save event. |
| Where-Used Report ("show me every BOM that uses this child Item") | Defer to a future Reporting phase. |
| Multi-level BOM explosion at edit time | FDS-03-006: single-level BOMs only. No recursive UX required. |
| Active-WO guard on `Bom_Deprecate` (reject if in-flight WOs reference this Bom) | Arc 2 — Workorder schema doesn't land until Phase 1 of Arc 2. Proc gets the guard stubbed as a `RETURN N'TODO Arc 2'`-style check with TODO comment. |
| Filtered Item-Picker as a reusable modal (would be shared with Eligibility Phase 8 and Routes Phase 5 reference-picker work) | Out of scope here — Phase 6 uses an inline dropdown bound to `Parts.Item_ListAvailableForBom`. If Routes (Phase 5) lands a reusable picker first, BOMs Phase 6 adopts it on next polish pass. |

---

## 3. Data Model Touchpoints

### 3.1 Existing tables (no schema changes)

`Parts.Bom` (per `MPP_MES_DATA_MODEL.md` §2):

| Column | Type | Role in this design |
|---|---|---|
| `Id` | BIGINT PK | |
| `ParentItemId` | BIGINT FK → Item.Id | Tab is scoped to one ParentItemId at a time |
| `VersionNumber` | INT | Engineered to be monotonically increasing per ParentItemId via `MAX(VersionNumber)+1` in `_CreateNewVersion`. UNIQUE(ParentItemId, VersionNumber) enforces it. |
| `EffectiveFrom` | DATETIME2(3) | Date input on draft header. Defaults to today + 30 days on new draft. Required at Publish time. |
| `PublishedAt` | DATETIME2(3) NULL | NULL = Draft; non-NULL = Published. Set by `Bom_Publish`. |
| `DeprecatedAt` | DATETIME2(3) NULL | Set by `Bom_Deprecate`. |
| `CreatedByUserId` | BIGINT FK → AppUser.Id | |
| `CreatedAt` | DATETIME2(3) | |

`Parts.BomLine` (per `MPP_MES_DATA_MODEL.md` §2):

| Column | Type | Role |
|---|---|---|
| `Id` | BIGINT PK | |
| `BomId` | BIGINT FK → Bom.Id | |
| `ChildItemId` | BIGINT FK → Item.Id | Component item. Inline dropdown sourced from `Parts.Item_ListAvailableForBom`. |
| `QtyPer` | DECIMAL(10,4) | Numeric input on draft row |
| `UomId` | BIGINT FK → Uom.Id | Dropdown sourced from `Parts.Uom_List` |
| `SortOrder` | INT | Reconciled from array-index (1-based) on Save Draft. No discrete `_MoveUp` / `_MoveDown` per conventions pack §"Save semantics" rule 4. |

**No DeprecatedAt on `BomLine`** — confirmed against current data model. Lifecycle lives on parent `Bom`. Line reconciliation is physical INSERT / UPDATE / DELETE inside an active Draft Bom.

### 3.2 New migration: `0016_parts_bom_unique_draft.sql`

Filtered UNIQUE index enforcing one draft per ParentItemId:

```sql
CREATE UNIQUE INDEX UX_Bom_ActiveDraft
    ON Parts.Bom (ParentItemId)
    WHERE PublishedAt IS NULL AND DeprecatedAt IS NULL;
```

**Why:** Prevents two engineers from opening parallel drafts of the same BOM, which would race on Publish and produce ambiguous "active version" state. UX-level we also gate the [New Version] button on `existing draft count == 0` for the active ParentItemId, but the DB index is the safety net.

**Note on migration sequencing:** Landed as `0016_parts_bom_unique_draft.sql` because `0015_audit_add_event_type_deleted.sql` (Routes Phase 5) took the 0015 slot. The migration body is independent of the audit event-type change.

### 3.3 Validation rules embedded in procs

| Rule | Enforced where | Rationale |
|---|---|---|
| `ChildItemId != ParentItemId` (no self-reference) | `Bom_SaveDraft` line validation | Single-level BOMs (FDS-03-006); circular at depth 1 |
| At least one BomLine before Publish | `Bom_Publish` | Mockup tile-row at line 2152 shows "Cannot publish: BOM has no lines." Honor it. |
| `EffectiveFrom` NOT NULL at Publish | `Bom_Publish` | Date input must be set. UI prevents this; proc-level guard is a second layer. |
| One active draft per ParentItemId | `UX_Bom_ActiveDraft` filtered index + `Bom_CreateNewVersion` UI guard | Avoid race conditions. |
| `Code` / `ParentItemId` immutable post-create | Implicit — there is no `Code` column on `Bom`; `ParentItemId` is set at `_CreateNewVersion` and never re-passed | No update path for these fields by design. |
| `VersionNumber` monotonic per ParentItemId | `Bom_CreateNewVersion` (computes `MAX(VersionNumber) + 1`) + UNIQUE constraint | |
| Active-WO guard on Deprecate | `Bom_Deprecate` (stubbed for Arc 2) | Out of scope this round; structural placeholder |

---

## 4. Versioning State Machine

```
              ┌─────────────┐
              │  (no rows)  │  ← initial state for a never-versioned Item
              └─────┬───────┘
                    │ Bom_CreateNewVersion (clone from nothing)
                    ▼
              ┌─────────────┐
       ┌──────│    DRAFT    │──────┐
       │      │  Pub. NULL  │      │
       │      │  Dep. NULL  │      │
       │      └─────┬───────┘      │
       │            │              │
       │ Bom_       │ Bom_Publish  │ Bom_DiscardDraft
       │ SaveDraft  │  (validates) │  (physical DELETE
       │ (in-place) │              │   incl. cascade
       │            ▼              │   of BomLines)
       │      ┌─────────────┐      ▼
       │      │  PUBLISHED  │  ┌─────────┐
       │      │  Pub. SET   │  │ (gone)  │
       │      │  Dep. NULL  │  └─────────┘
       │      └─────┬───────┘
       │            │ Bom_Deprecate (FK guard: no active WOs)
       │            ▼
       │      ┌─────────────┐
       └──────│ DEPRECATED  │
              │  Pub. SET   │
              │  Dep. SET   │
              └─────────────┘
```

**Transitions:**

| From | Action | To | Side effects |
|---|---|---|---|
| (no rows) or any state | `Bom_CreateNewVersion(@ParentItemId, @SourceBomId)` | DRAFT | New Bom row. If `@SourceBomId IS NOT NULL`, copy that version's BomLines verbatim into the new Bom. If NULL (or no prior published exists), draft starts empty. `VersionNumber = MAX + 1`. `EffectiveFrom` defaults to today + 30 days. |
| DRAFT | `Bom_SaveDraft(@Id, @EffectiveFrom, @LinesJson)` | DRAFT | Bundled reconciliation of BomLines per `project_mpp_bundled_save_pattern.md` instance-editor variant (physical DELETE / UPDATE / INSERT). `EffectiveFrom` updated. `PublishedAt` stays NULL. |
| DRAFT | `Bom_Publish(@Id, @EffectiveFrom, @LinesJson)` | PUBLISHED | Saves any pending line edits (idempotent re-save), validates line-count > 0, sets `PublishedAt = SYSUTCDATETIME()`. Prior published version (if any) is NOT auto-deprecated (see §5 decision D2). |
| DRAFT | `Bom_DiscardDraft(@Id)` | (gone) | Physical DELETE of `Parts.Bom` row + cascade to `Parts.BomLine`. |
| PUBLISHED | `Bom_Deprecate(@Id)` | DEPRECATED | Sets `DeprecatedAt = SYSUTCDATETIME()`. Arc 2 will add the active-WO FK guard. |
| DEPRECATED | `Bom_Reinstate(@Id)` | PUBLISHED | NOT included in this phase — out of scope. If needed, a future change order can add a `_Reinstate` proc; for now, deprecate-then-create-new-version is the workaround. |

**Active-version selection** (consumed by Arc 2 — proc body lands here but no Arc 1 consumer):

```sql
-- Bom_GetActiveForItem(@ParentItemId, @AsOfDate)
SELECT TOP 1 Id
FROM Parts.Bom
WHERE ParentItemId = @ParentItemId
  AND PublishedAt IS NOT NULL
  AND DeprecatedAt IS NULL
  AND EffectiveFrom <= ISNULL(@AsOfDate, SYSUTCDATETIME())
ORDER BY EffectiveFrom DESC;
```

This means **multiple published non-deprecated versions can coexist** when their EffectiveFrom dates are in the future. The "active" one at any moment is the most recent EffectiveFrom that's already past. Engineering schedules a v2 with EffectiveFrom 30 days out; production keeps running v1 until v2's date is reached. This contradicts FDS-03-005's wording ("The previous version SHALL be soft-deleted") but aligns with the v1.9 data model's explicit definition of `PublishedAt + DeprecatedAt`. **Decision D2 below addresses this.**

---

## 5. Design Decisions (with rationale + alternatives surfaced)

### D1. Save Draft is a first-class action, separate from Publish

**Chosen:** Three explicit buttons in draft mode: `[Save Draft]`, `[Discard Draft]`, `[Publish]`. Save Draft persists line edits without publishing; Publish optionally also saves line edits (idempotent) then sets PublishedAt.

**Why:** Engineering may edit a draft over multiple sessions before publishing. Without an explicit Save Draft, leaving the page mid-edit loses work. Treating Publish as "save + transition" is unsafe — Publish has validation that may reject (e.g., zero lines), in which case the user wants their edits preserved even if Publish failed.

**Alternative considered:** Combine Save+Publish into one button (simpler UI; matches mockup). Rejected — Save Draft is implicit in the mockup but the real workflow needs it.

### D2. Publishing a new version does NOT auto-deprecate the prior published version

**Chosen:** Publishing v2 leaves v1 with `DeprecatedAt = NULL`. Active-version selection at runtime uses `EffectiveFrom DESC` to pick the right one. Engineering may explicitly deprecate v1 separately if they want.

**Why:** Two reasons:

1. **Future-dated activation.** Engineering may publish v2 with `EffectiveFrom = 2026-07-01` while v1 (EffectiveFrom 2026-01-15) is still production-active. Auto-deprecating v1 on publish would break the future-dated activation use case.
2. **Audit clarity.** Deprecation is an intentional retire action. Bundling it into Publish hides the decision from `Audit.ConfigLog`.

**Conflict flagged:** FDS-03-005 says "The previous version SHALL be soft-deleted (`DeprecatedAt` set)" — this design contradicts the FDS prose. The contradiction was already present between FDS-03-005 and the v1.9 Data Model `Bom` notes ("Published BOMs are immutable. Deprecated retires."). **Assumption A2 below flags this for Jacques to reconcile.**

**Alternative considered:** Auto-deprecate on Publish (honor FDS-03-005 literally). Rejected pending Jacques's confirmation — the future-dated use case is more important than literal FDS compliance.

### D3. BOMs tab lifecycle actions are ISOLATED from the page-level Item Save

**Chosen:** `[Save Draft]`, `[Publish]`, `[Discard Draft]`, `[Deprecate]` (the per-version Deprecate button on Published mode) all execute INSIDE the BOMs tab via direct calls to `Bom_*` procs. The page-level `Save` button on the Item Master title bar persists Item meta + ContainerConfig only — never touches Bom rows.

**Why:** BOMs have their own versioning lifecycle that doesn't align with Item lifecycle. Bundling them creates confusing UX ("I clicked Item Save and accidentally published my draft BOM"). The conventions pack §"Save semantics" rule 3 ("Multi-tab forms share one editDraft") still applies in spirit — `editDraft.boms` IS one slice of the shared editDraft — but the *commit triggers* are per-tab where lifecycle semantics differ.

**Alternative considered:** Item Save persists everything (meta + container + draft BOM lines bundled into one transaction). Rejected — fails the no-surprise principle on a publish action; Publish has different validation than Item Save; deprecation of a published version is unrelated to current edits.

### D4. EditDraft slice shape on the parent

The parent's `view.custom.editDraft.boms` is the per-tab state slice (R1 bidi mechanism from Phase 1). Its shape:

```yaml
editDraft.boms:
  parentItemId:      BIGINT           # mirrors editDraft.meta.Id; cached for proc params
  versions: [                          # all versions for this item, populated by Bom_ListByParentItem
    {id, versionNumber, effectiveFrom, publishedAt, deprecatedAt, lineCount},
    ...
  ]
  activeVersionId:   BIGINT|null       # which version is currently being viewed/edited
  activeVersion:                       # the bundle for the active version
    id:              BIGINT
    versionNumber:   INT
    effectiveFrom:   DATETIME2
    publishedAt:     DATETIME2|null    # NULL → draft mode; non-NULL → published mode
    deprecatedAt:    DATETIME2|null
    lines: [
      {
        id:           BIGINT|null      # NULL for draft rows added since last save
        childItemId:  BIGINT
        partNumber:   "5G0-C"          # display-only, denormalized at read time
        componentName: "Front Cover Casting"  # display-only
        qtyPer:       DECIMAL
        uomId:        BIGINT
        uomCode:      "EA"             # display-only
      },
      ...
    ]
  availableItems: [                    # populated once per item-load; cached for the Add Component dropdown
    {id, partNumber, description, defaultUomId, defaultUomCode, itemTypeName},
    ...
  ]
  uoms: [{id, code}, ...]              # populated from Parts.Uom_List
  includeDeprecated: false             # toggle on the version dropdown header
```

**Dirty detection per the conventions pack:** `editDraft.boms.activeVersion.lines` deep-compared against `selected.boms.activeVersion.lines`. Dirty triggers the page-level `● Unsaved changes` indicator AND a tab-local indicator on the BOMs tab title (Phase 6 stretch — not strictly required).

**Line array MUTATIONS** (all client-side in the embedded view, mutating `view.params.value.lines` which is bidi to `editDraft.boms.activeVersion.lines`):

| Action | Mutation |
|---|---|
| `[+ Add Component]` | Append `{id: null, childItemId: null, partNumber: "", componentName: "", qtyPer: 1, uomId: null, uomCode: ""}` |
| `[× Remove]` row | `lines = [l for i, l in enumerate(lines) if i != rowIdx]` |
| `[↑]` row | Swap `lines[rowIdx]` and `lines[rowIdx-1]` |
| `[↓]` row | Swap `lines[rowIdx]` and `lines[rowIdx+1]` |
| ChildItem dropdown change | Set `lines[rowIdx].childItemId`, `.partNumber`, `.componentName`, default `.uomId` and `.uomCode` from the picked item |
| Qty input change | Bidi binding to `lines[rowIdx].qtyPer` |
| UOM dropdown change | Bidi binding to `lines[rowIdx].uomId`, plus `.uomCode` mirror via onChange |

**On Save Draft:** entity script extracts `lines[]` from `view.custom.editDraft.boms.activeVersion`, builds `LinesJson` payload, calls `Parts.Bom_SaveDraft`. On success, refresh `editDraft.boms` from `Bom_Get(activeVersionId)`.

### D5. Children reconciliation strategy on Bom_SaveDraft is physical, not soft-delete

**Chosen:** Per `project_mpp_bundled_save_pattern.md` instance-editor variant. BomLine has no `DeprecatedAt`; lines that disappear from the incoming JSON are physically DELETEd. SortOrder reconciled from array index.

**Why:** Lifecycle lives on parent Bom — once Published, the lines are immutable as a set. Draft lines are mutable as a set. No need to soft-delete individual lines because the *parent Bom*'s deprecation captures the historical state.

**Safety:** `Bom_SaveDraft` will reject the call if the target Bom is not in Draft state (`PublishedAt IS NOT NULL → Status=0, Message="Cannot edit a published BOM"`). Defensive against UI bugs.

### D6. Version dropdown includes the active draft + all published; Deprecated optional

**Chosen:** Version dropdown options:
- The active Draft (if exists) shown first as `v3 — Draft (Unsaved)` or `v3 — Draft (Saved <ago>)` depending on dirty state
- All Published versions: `v2 — Effective 2026-01-15 (Published)`, `v1 — Effective 2025-08-01 (Published)`, etc., sorted by EffectiveFrom DESC
- Optional `[Include Deprecated]` checkbox on the header (next to the dropdown) — when checked, prepend Deprecated versions: `v0 — Deprecated 2025-08-01`

**Why:** Mockup shows two versions in the dropdown (current Published, the new Draft after `bomsNewVersion`). Engineering needs to switch between versions to inspect a prior Published. Deprecated versions are noise by default but accessible.

### D7. Default `EffectiveFrom` on new draft

**Chosen:** `today + 30 days`. Engineer can override.

**Why:** Gives a soak/review window before activation. Aligns with typical engineering change order lead time.

**Alternative considered:** Default to today (immediate activation). Rejected — too easy to "publish today" accidentally and have a BOM change hit production faster than reviewers can intercept.

### D8. ChildItem picker is inline (dropdown), not a modal

**Chosen:** Inline `ia.input.dropdown` per draft row, sourced from `Parts.Item_ListAvailableForBom`. Options show `partNumber — description`.

**Why:** Phase 6 doesn't need a full Item Picker modal. The dropdown is sufficient for MPP's part count (~150–200 items at cutover). If part count grows or filtering becomes painful, Phase 6 can be retrofitted with the reusable Item Picker modal when it lands (likely shared with Routes Phase 5 or Eligibility Phase 8).

**Hard constraint:** dropdown excludes the parent Item (no self-reference) and `Deprecated` items.

---

## 6. NQ + Proc List

### 6.1 New SQL migrations

| File | Type | Purpose |
|---|---|---|
| `0016_parts_bom_unique_draft.sql` | migration | Filtered UNIQUE index on `Parts.Bom(ParentItemId)` WHERE `PublishedAt IS NULL AND DeprecatedAt IS NULL` |

### 6.2 New repeatable procs

All under `sql/migrations/repeatable/`. All schema-qualify to `Parts.`. All log to `Audit.Audit_LogConfigChange` on success and `Audit.Audit_LogFailure` on validation rejection per the proc template at `sql/scripts/_TEMPLATE_stored_procedure.sql`.

| Proc | Shape | Returns |
|---|---|---|
| `Parts.Bom_ListByParentItem` | `@ParentItemId BIGINT`, `@IncludeDeprecated BIT = 0` | Rowset: Bom rows with `Id, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, LineCount, CreatedByName, CreatedAt`. ORDER BY: Drafts first, then Published DESC by EffectiveFrom, then Deprecated (when included) DESC by DeprecatedAt. |
| `Parts.Bom_Get` | `@Id BIGINT` | Rowset (one row, joins): `Id, ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByName, CreatedAt`. Plus a second proc `Parts.BomLine_ListByBom` for the lines — Ignition JDBC restriction allows only one result set per proc (per `feedback_ignition_designer_unicode_escapes.md` not applicable here but the JDBC compatibility rule in CLAUDE.md is). |
| `Parts.BomLine_ListByBom` | `@BomId BIGINT` | Rowset: BomLine rows joined to `Item` and `Uom` — `Id, BomId, ChildItemId, PartNumber, ComponentName, QtyPer, UomId, UomCode, SortOrder`. ORDER BY SortOrder ASC. |
| `Parts.Bom_GetActiveForItem` | `@ParentItemId BIGINT`, `@AsOfDate DATETIME2 = NULL` | Rowset (0 or 1): the version active at the given timestamp. Arc 1 has no consumer; proc lands now to keep Arc 2 unblocked. |
| `Parts.Bom_CreateNewVersion` | `@ParentItemId BIGINT`, `@SourceBomId BIGINT = NULL`, `@EffectiveFrom DATETIME2 = NULL`, `@AppUserId BIGINT` | Status row + `NewId` = the new draft `Parts.Bom.Id`. If `@SourceBomId` non-NULL, copies that Bom's BomLines verbatim (preserving SortOrder). If `@EffectiveFrom` NULL, defaults to `SYSUTCDATETIME() + 30 days`. Computes `VersionNumber = ISNULL(MAX(VersionNumber), 0) + 1` over rows for `@ParentItemId`. **Guard:** rejects if a draft already exists for `@ParentItemId` (Status=0, Message="A draft BOM already exists. Open it or discard it before creating a new version."). |
| `Parts.Bom_SaveDraft` | `@Id BIGINT`, `@EffectiveFrom DATETIME2`, `@LinesJson NVARCHAR(MAX)`, `@AppUserId BIGINT` | Status row + `NewId` (echoed). **Guards:** target must be Draft (`PublishedAt IS NULL AND DeprecatedAt IS NULL`); within-batch `(ChildItemId)` uniqueness OPTIONAL — see open Q3 below; `ChildItemId != ParentItemId`; UomId must exist on `Parts.Uom`. Then bundled reconciliation per the instance-editor variant of the bundled-save pattern. |
| `Parts.Bom_Publish` | `@Id BIGINT`, `@EffectiveFrom DATETIME2 = NULL`, `@LinesJson NVARCHAR(MAX) = NULL`, `@AppUserId BIGINT` | Status row + `NewId` (echoed). If `@LinesJson` is non-NULL, internally invokes the same save logic as `_SaveDraft` (idempotent save-then-publish). Validates: target must be Draft; at least one BomLine exists post-save; `EffectiveFrom` is non-NULL. Sets `PublishedAt = SYSUTCDATETIME()`. |
| `Parts.Bom_Deprecate` | `@Id BIGINT`, `@AppUserId BIGINT` | Status row. **Guards:** target must be Published (`PublishedAt IS NOT NULL AND DeprecatedAt IS NULL`); active-WO check stubbed (TODO comment for Arc 2: `IF EXISTS(SELECT 1 FROM Workorder.WorkOrder WHERE BomId = @Id AND Status IN ('Open','InProgress'))`). |
| `Parts.Bom_DiscardDraft` | `@Id BIGINT`, `@AppUserId BIGINT` | Status row. **Guard:** target must be Draft. Physical DELETE: BomLine rows FIRST, then Bom row. Audit log captures the pre-delete payload as `OldValue`. |
| `Parts.Item_ListAvailableForBom` | `@ParentItemId BIGINT`, `@SearchText NVARCHAR(50) = NULL` | Rowset: Items not deprecated, excluding the parent. ORDER BY PartNumber. `@SearchText` does substring on PartNumber OR Description if provided. |
| `Parts.Uom_List` | `(no params)` | Rowset: all Uom rows. (May already exist from Phase 2 — confirm at execution.) |

### 6.3 New tests

Per the project SQL convention, every new proc gets a `tests/<XXXX_TestSet>/NNN_<ProcName>.sql` test file. Approximate list:

- `tests/00XX_Bom/010_Bom_CreateNewVersion.sql` — empty-create, clone-create, dup-draft-rejection, future-EffectiveFrom-default
- `tests/00XX_Bom/020_Bom_SaveDraft.sql` — add/edit/remove/reorder lines, immutable Bom rejection, self-reference rejection, missing UomId rejection
- `tests/00XX_Bom/030_Bom_Publish.sql` — zero-lines rejection, missing-EffectiveFrom rejection, idempotent save-and-publish, double-publish rejection
- `tests/00XX_Bom/040_Bom_Deprecate.sql` — happy path, already-deprecated idempotent, deprecate-while-draft rejection
- `tests/00XX_Bom/050_Bom_DiscardDraft.sql` — happy path, discard-while-published rejection
- `tests/00XX_Bom/060_Bom_Get_ListByParentItem.sql` — read paths, ordering, IncludeDeprecated toggle
- `tests/00XX_Bom/070_Bom_GetActiveForItem.sql` — future-dated v2 not picked, past-dated v2 picked, deprecated excluded, no-versions returns empty

Target: extend test suite from 937 → ~970 passing.

### 6.4 New Ignition Named Queries

All under `ignition/projects/MPP_Config/com.inductiveautomation.perspective/named-query/parts/`. Conventions: v2 schema, camelCase params, Designer-canonical sqlType per `feedback_ignition_nq_resource_schema.md`.

- `Bom_ListByParentItem` — `parentItemId BIGINT (sqlType=3)`, `includeDeprecated BIT (sqlType=6)`
- `Bom_Get` — `id BIGINT`
- `BomLine_ListByBom` — `bomId BIGINT`
- `Bom_CreateNewVersion` — `parentItemId BIGINT`, `sourceBomId BIGINT (nullable)`, `effectiveFrom DATETIME (sqlType=8, nullable)`, `appUserId BIGINT`
- `Bom_SaveDraft` — `id BIGINT`, `effectiveFrom DATETIME`, `linesJson NVARCHAR (sqlType=7)`, `appUserId BIGINT`
- `Bom_Publish` — `id BIGINT`, `effectiveFrom DATETIME (nullable)`, `linesJson NVARCHAR (nullable)`, `appUserId BIGINT`
- `Bom_Deprecate` — `id BIGINT`, `appUserId BIGINT`
- `Bom_DiscardDraft` — `id BIGINT`, `appUserId BIGINT`
- `Item_ListAvailableForBom` — `parentItemId BIGINT`, `searchText NVARCHAR (nullable)`
- `Uom_List` — (no params) — may already exist

### 6.5 New entity script: `BlueRidge.Parts.Bom`

Path: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Bom/code.py`. Module surface (mirrors `BlueRidge.Oee.DowntimeReasonCode`, `BlueRidge.Location.LocationTypeDefinition`):

| Function | Purpose |
|---|---|
| `listByParentItem(parentItemId, includeDeprecated=False)` | Returns list[dict] of version summary rows for the version dropdown. |
| `getOne(bomId)` | Returns `{header: {...}, lines: [...]}` bundle. Calls both `Bom_Get` and `BomLine_ListByBom`, joins client-side, deep-unwraps via `Common.Util._u`. |
| `listAvailableItemsForBom(parentItemId, searchText=None)` | Returns list[dict] for the ChildItem dropdown. |
| `listUoms()` | Returns list[dict] of Uom options. Cached for the session if possible (low churn). |
| `handleCreateNewVersion(parentItemId, sourceBomId, effectiveFrom)` | Mutation. Returns Status/Message/NewId. Routes through `Common.Db.execMutation`. |
| `handleSaveDraft(bomId, effectiveFrom, lines)` | Mutation. `lines` is a list of dicts; serializes to JSON for the proc param. Routes through `Common.Db.execMutation`. |
| `handlePublish(bomId, effectiveFrom, lines)` | Mutation. Optionally takes lines (for save-and-publish in one shot). |
| `handleDeprecate(bomId)` | Mutation. |
| `handleDiscardDraft(bomId)` | Mutation. |
| `emptyLine()` | Returns `{id: None, childItemId: None, partNumber: "", componentName: "", qtyPer: 1, uomId: None, uomCode: ""}` for adding a new draft row. |

All `handle*` mutation functions auto-fill `appUserId` from `Common.Util._currentAppUserId()`. All read functions wrap their `Common.Db.execList` / `execOne` calls in try/except and fire an error toast via `Common.Ui.notifyResult` on failure.

---

## 7. View Changes

### 7.1 BOMs tab — `views/BlueRidge/Components/Parts/ItemMaster/Boms/view.json`

**Current state (Phase 1 shell):** static read-only published-version table with a non-functional Version dropdown and `[New Version]` button firing a `Common.Notify.toast("Not wired yet")`. Embedded view receives `view.params.value` bidi-bound to `editDraft.boms` from the parent.

**Phase 6 target:** the same embedded view becomes a full versioned-entity editor. Structure:

```
root (ia.container.flex, direction: column, gap: 10px)
├── HeaderBar (basis: auto, direction: row, alignItems: center, gap: 8px)
│     VersionDropdown (props.options ← {view.params.value.versions} mapped to {label, value})
│           value ← bidi {view.params.value.activeVersionId}
│           onChange → message handler `bomActiveVersionChanged` (page-scoped, fires up to parent)
│     ModeBadge (text + style.classes derived from {view.params.value.activeVersion.publishedAt})
│           "Published" (green) if publishedAt non-null AND deprecatedAt null
│           "Draft" (amber)     if publishedAt null
│           "Deprecated" (gray) if deprecatedAt non-null
│     IncludeDeprecatedCheckbox (props.selected ← bidi {view.params.value.includeDeprecated})
│           onChange → `bomVersionListRefresh` (page-scoped)
│     HeaderSpacer (grow: 1)
│     ┌── Published-mode buttons (position.display gated on activeVersion.publishedAt IS NOT NULL AND deprecatedAt IS NULL)
│     │     BtnDeprecate ("Deprecate")  — events.dom.onClick → Confirm popup → entity_script.handleDeprecate
│     │     BtnNewVersion ("+ New Version") — events.dom.onClick → entity_script.handleCreateNewVersion
│     ├── Draft-mode buttons (position.display gated on activeVersion.publishedAt IS NULL)
│     │     EffectiveDateInput (date input, bidi to {view.params.value.activeVersion.effectiveFrom})
│     │     BtnSaveDraft  — events.dom.onClick → entity_script.handleSaveDraft (passes lines from editDraft)
│     │     BtnDiscardDraft — events.dom.onClick → Confirm popup → entity_script.handleDiscardDraft
│     │     BtnPublish — events.dom.onClick → Confirm popup → entity_script.handlePublish
│     └── Deprecated-mode buttons (position.display gated on deprecatedAt IS NOT NULL)
│           Label "Read-only — this version is deprecated."
│
└── LinesPanel (grow: 1, direction: column)
    ├── LinesTable (flex-repeater)
    │     instances ← forEach(activeVersion.lines, {line: it, rowIndex: index, mode: parent.mode, lineCount: parent.lineCount})
    │     embedded view: BlueRidge/Components/Parts/ItemMaster/Boms/BomLineRow
    │
    └── DraftFooter (basis: auto, position.display gated on draft mode)
          BtnAddComponent ("+ Add Component") — events.dom.onClick → script appends new line to editDraft.boms.activeVersion.lines
```

The flex-repeater renders one row per BomLine. Each row is itself a small embedded view (next sub-section).

### 7.2 New sub-view: `BomLineRow`

Path: `views/BlueRidge/Components/Parts/ItemMaster/Boms/BomLineRow/`

Per-line row component. Receives:
- `params.line` — the line dict
- `params.rowIndex` — for SortOrder (1-based-display, 0-based-iter)
- `params.mode` — `"published"` | `"draft"` | `"deprecated"`
- `params.lineCount` — total lines (for disabling last-row down-arrow, first-row up-arrow)

Layout (mirrors the mockup's `<table>` row but as a `ia.container.flex` row):

```
root (ia.container.flex, direction: row, alignItems: center, gap: 8px)
├── ColIndex (basis: 36px, label of rowIndex+1)
├── ColArrows (basis: 46px, flex row gap: 2px)
│     UpArrow (ia.input.button, disabled if rowIndex == 0, fires page msg `bomLineMoveUp` with rowIndex)
│     DownArrow (ia.input.button, disabled if rowIndex == lineCount-1, fires `bomLineMoveDown`)
│     (Both arrows hidden via meta.visible if mode == "published" or "deprecated")
├── ColItemPicker (grow: 1, basis: 0)
│     If mode == "draft":
│         Dropdown (options from view.params.availableItems, value bidi to params.line.childItemId)
│         onChange → page msg `bomLineItemChanged` with rowIndex + newItemId
│     Else:
│         Label (text = params.line.partNumber)
├── ColComponent (grow: 1, basis: 0)
│     Label (text = params.line.componentName, dim color in draft mode since it's a derived display)
├── ColQty (basis: 80px)
│     If mode == "draft":
│         NumericInput (value bidi to params.line.qtyPer)
│     Else:
│         Label (text = params.line.qtyPer)
├── ColUom (basis: 80px)
│     If mode == "draft":
│         Dropdown (options from view.params.uoms, value bidi to params.line.uomId)
│     Else:
│         Label (text = params.line.uomCode)
└── ColRemove (basis: 36px, visible only in draft mode)
      RemoveButton (× icon, fires page msg `bomLineRemove` with rowIndex)
```

**meta.visible vs position.display in this row** — per `feedback_ignition_meta_visible_in_tables.md`, tabular row layouts where column alignment matters use `meta.visible` (not `position.display`) so the slot stays preserved when hidden. The arrows and remove-button columns use `meta.visible` so the index/itemPicker/component/qty/uom columns align across all row modes.

### 7.3 Page-scoped messages on parent ItemMaster

Add message handlers at `root.scripts.messageHandlers[]` on `BlueRidge/Views/Parts/ItemMaster/view.json`:

| Message | Payload | Handler logic |
|---|---|---|
| `bomActiveVersionChanged` | `{bomId}` | Load `editDraft.boms.activeVersion` from `Bom.getOne(bomId)`. Also update `selected.boms.activeVersion` to the same. |
| `bomVersionListRefresh` | `{}` | Re-fetch `editDraft.boms.versions` from `Bom.listByParentItem(...)`. |
| `bomLineMoveUp` | `{rowIndex}` | Swap `editDraft.boms.activeVersion.lines[rowIndex]` with `[rowIndex-1]`. |
| `bomLineMoveDown` | `{rowIndex}` | Swap with `[rowIndex+1]`. |
| `bomLineRemove` | `{rowIndex}` | Splice `lines` at `rowIndex`. |
| `bomLineItemChanged` | `{rowIndex, newItemId}` | Look up the new item in `availableItems`, update `lines[rowIndex].childItemId`, `.partNumber`, `.componentName`, `.uomId`, `.uomCode`. |

These page-scoped messages are the bridge from the BomLineRow sub-view (deep embedded) to the parent's editDraft mutation. Following `feedback_ignition_message_scope.md`: any handler that lives in a different `view.json` from the sender must be page-scoped (not view-scoped).

### 7.4 New confirmation popups

Two new popup view files under `views/BlueRidge/Components/Popups/`:

- `ConfirmDeprecate` — generic three-button confirm: "Are you sure you want to deprecate this <Entity> version?" / Cancel / Deprecate. Parameterized `entity` and `versionLabel`. Reusable across BOMs Phase 6, Routes Phase 5, future versioned-entity work.
- `ConfirmDiscardDraft` — variant of `ConfirmUnsaved`: "Discard this draft and all of its line edits? This cannot be undone." / Cancel / Discard. Parameterized.

These follow the `project_mpp_confirm_unsaved_pattern.md` shape — page-scoped reply messages back to the editor.

### 7.5 Item Master view edits (parent)

**Required edits to `BlueRidge/Views/Parts/ItemMaster/view.json`:**

1. Add the 6 page-scoped message handlers listed in §7.3 to `root.scripts.messageHandlers[]`.
2. Wire the BOMs tab Embedded View's `props.params.value` binding (already in place from Phase 1) — no changes; Phase 6 just leans on the existing bidi.
3. (Optional polish) Add a per-tab dirty indicator on the BOMs tab strip button (small `●` next to "BOMs" when `editDraft.boms.activeVersion.lines != selected.boms.activeVersion.lines`).

Item view edits are **existing-view edits** — per `feedback_ignition_view_edit_boundary.md`, prefer Designer-step instructions for Jacques to apply, NOT direct file edits. The execution plan calls this out.

**Tab view edits (`Boms/view.json`) are also technically "existing-view" edits** since Phase 1 wrote them. However, in practice the Phase 1 shell was minimal (only the static published-mode header + table); Phase 6 substantially restructures the view. The execution plan will either:
- Have Jacques rebuild the tab view fresh in Designer following the new layout (preferred), OR
- File-edit the existing JSON and have Jacques validate post-scan (risk: Designer cache conflict)

Decision deferred to plan execution time. The new `BomLineRow` sub-view is a NEW file → file-edit safe.

---

## 8. Risks + Open Questions

### Risks

| # | Risk | Mitigation |
|---|---|---|
| **R1 reuse** | BOMs Phase 6 depends on the R1 bidi-Object-param mechanism validated by Agent B's Phase 2 work. If R1 fails and the fallback (page-scoped messages instead of bidi) is adopted, the BOMs tab's `props.params.value` ↔ `editDraft.boms` mechanism must be replaced with the fallback shape. | Land Phase 6 AFTER Phase 2 R1 verdict. If R1 fails, the BomLineRow sub-view's page-scoped messages (already designed for the deeper embed-to-parent hop) extend up to the BOMs-tab-to-ItemMaster hop too. The line-edit UX changes are minimal — the parent's message handlers simply receive line-edit messages directly from the BOMs tab instead of inferring them from bidi propagation. |
| **R2** | Race between [+ New Version] click and the filtered UNIQUE index — if two users click simultaneously, one will get a primary-key violation on insert. | `Bom_CreateNewVersion` catches the index violation in its CATCH block and returns Status=0 with a friendly Message. UI also gates the button on `versions[]` containing zero Draft entries (cheap client-side guard). |
| **R3** | The flex-repeater `props.instances` is bound expr `forEach({view.params.value.activeVersion.lines}, ...)` — when `lines` is empty in a draft, the repeater renders nothing and the user sees a blank panel. Mockup shows `[+ Add Component]` button at the bottom of the panel, which would be the only affordance. | Acceptable UX. The button label is unambiguous, and Phase 6 spec acceptance includes "draft-mode empty state renders the Add Component button visible." |
| **R4** | Long `LinesJson` payloads — if a BOM has many lines, the JSON parameter could exceed payload limits. Honda parts typically have 1–10 components, but edge cases possible. | NVARCHAR(MAX) parameter on the proc; no concrete limit. Server-side OPENJSON parse is performant up to multi-MB payloads. Not a practical concern for MPP's part count. |
| **R5** | Mockup includes a "Discard Draft" affordance that physically deletes — engineering may discard, then immediately want to recover. | Acceptable per D5. `Audit.ConfigLog` row captures the draft's pre-delete payload as `OldValue` so a "recover" path is at worst a manual proc call by an admin against the audit log. Not auto-recoverable through the UI. Document this in the user-facing help text on the Discard confirm popup ("Drafts cannot be recovered after discard"). |
| **R6** | The "active draft" filtered UNIQUE allows exactly one draft per ParentItemId, but does not prevent two engineers from independently editing the same draft (each loaded it before the other saved). The second save wins (last-writer-wins). | Acceptable for MVP — collision is rare given the engineer headcount at MPP. If observed in practice, retrofit with optimistic concurrency via a `@RowVersion` parameter on `Bom_SaveDraft` per Phased Plan v1.7 §"Pattern 7. Optimistic locking". Not in Phase 6 scope. |
| **R7** | Embedded BomLineRow at depth-2 (Item Master → BOMs tab → row) may stress the bidi propagation more than ContainerConfig's depth-1 embed. | Page-scoped messages from BomLineRow up to ItemMaster (§7.3) bypass the depth-2 propagation entirely. The line-edit UX uses the message pathway, not direct bidi mutation through two embed boundaries. Bidi is only on the top-level Boms tab `value` param. |

### Open Questions for Jacques

| # | Question | Default if no input |
|---|---|---|
| **A1** | **D2 conflicts with FDS-03-005.** Is the auto-deprecate-on-publish requirement still valid, or should the v1.9 Data Model's `EffectiveFrom DESC` selection be the canonical rule? | Default to D2 (do NOT auto-deprecate). If A1 resolves to "honor FDS-03-005 literally," `Bom_Publish` adds a step to set DeprecatedAt on prior published versions, and the design's future-dated v2 use case becomes impossible. |
| **A2** | **Within-batch unique ChildItemId on the same Bom?** Two BomLines on the same Bom with the same ChildItemId would represent "two of component X with different qty/uom" — likely a data-entry error but technically legal in the data model (no UNIQUE constraint). | Default to **allow duplicates** (data model permissive). If A2 resolves to "reject duplicates," `Bom_SaveDraft` adds a within-batch validation step. |
| **A3** | **DropdownVersion label format** — mockup shows `v1 — Effective 2026-01-15 (Published)`. For Draft entries, options include `v3 — Draft (Unsaved)` (dirty) vs `v3 — Draft (Saved <ago>)` (clean). Are these labels Jacques-OK? | Default to those exact labels. |
| **A4** | **Default EffectiveFrom of today + 30 days** — too long? Too short? | Default to today + 30 days. Configurable via a single constant in the proc. |
| **A5** | **`Bom_Reinstate` proc** — not in scope. If engineering needs to un-deprecate a version in practice, what's the workflow? | Workaround: deprecate-the-deprecated + create-new-version-from-the-old. If A5 resolves to "add a `_Reinstate` proc," it's a small addition; design is forward-compatible. |
| **A6** | **Phase ordering with Phase 5 (Routes)** — both spec docs land in parallel. Should they share any helper procs (e.g., a generic `Parts.VersionedEntity_*` family)? | Default: no shared helpers. Routes and BOMs are similar shape but distinct entities — DRY via a generic family would entangle two domains and the data model touches them differently (Routes' `RouteStep` references `OperationTemplate`, BOMs' `BomLine` references `Item`). Keep them parallel-but-distinct. |
| **A7** | **`[Deprecate]` button location** — the design puts it on the BOMs tab header next to the Version dropdown. Should it also appear at the page level (TitleBar's Deprecate button)? | Default to **tab-level only**. The page-level Deprecate (per Phase 3 design) is for deprecating the **Item itself**, not any individual BOM version. |

---

## 9. Generalizable-to-Routes Callouts

Where Phase 5 (Routes) is likely to share mechanics with Phase 6 (this), called out for Jacques's post-Round-1 reconciliation pass:

| Mechanic | Likely shared with Routes | Notes |
|---|---|---|
| **Three-state lifecycle (Draft → Published → Deprecated)** | YES | Data model: `RouteTemplate.PublishedAt` + `DeprecatedAt` mirror `Bom`. Same state machine. |
| **One draft per parent enforced via filtered UNIQUE index** | YES | `UX_RouteTemplate_ActiveDraft ON (ItemId) WHERE PublishedAt IS NULL AND DeprecatedAt IS NULL` would be the parallel index. |
| **`_CreateNewVersion` with optional `@SourceTemplateId` for cloning** | YES | Same shape; copies child rows verbatim. |
| **`_SaveDraft` as bundled proc with children-as-JSON** | YES | Same instance-editor variant of bundled-save pattern. Children for Routes are `RouteStep` rows. |
| **`_Publish` as save-and-transition with min-children validation** | YES | Routes require min 1 RouteStep; BOMs require min 1 BomLine. Parallel guard. |
| **`_DiscardDraft` as physical DELETE with cascade** | YES | Same. |
| **`_Deprecate` with active-WO FK guard (Arc 2 stub)** | YES | Same. |
| **In-tab lifecycle isolation from page-level Item Save (D3)** | YES | Routes Save/Publish should be independent of Item Save, same rationale. |
| **EffectiveFrom default of today + 30 days** | YES | Same engineering soak window applies. |
| **Auto-deprecate-on-publish question (A1)** | YES | FDS-03-010 has the same prose as FDS-03-005 for Routes. The decision applies symmetrically. |
| **Per-tab dirty indicator** | YES | Same approach. |
| **Confirm popups (`ConfirmDeprecate`, `ConfirmDiscardDraft`)** | YES | Parameterized for entity name — reusable across both tabs. |
| **Page-scoped messages from row sub-view up to ItemMaster parent** | YES | `RouteStepRow` would use the same pattern for `routeStepMoveUp/Down/Remove/Reorder`. |

**Symmetric divergences (where BOMs and Routes will differ):**

- BomLine's `ChildItemId` is a regular item dropdown. RouteStep's `OperationTemplateId` is an Operation Template dropdown sourced from the (also versioned!) `Parts.OperationTemplate` family — Routes Phase 5 has to handle the nested-versioning case where the parent route's child step references a versioned operation. This is Routes-specific complexity not in BOMs.
- BomLine has 2 editable fields (`QtyPer`, `UomId`). RouteStep has 1 editable field (`IsRequired` BIT — and `OperationTemplateId` selection). Different row UX.
- BOM cardinality: 1–10 components. Route cardinality: 4–6 steps. Same order of magnitude; either pattern works for both.

---

## 10. Acceptance Criteria (what "Done" looks like for Phase 6)

1. SQL test suite extends from 937 → 970+ passing (all new procs + tests landed).
2. `Reset-DevDatabase.ps1` runs clean — new migration `0016_parts_bom_unique_draft.sql` applies; new repeatable procs apply; new test files exercise.
3. Designer scan returns HTTP 200; no NPEs on any new NQ.
4. BOMs tab loads with real DB data for the selected Item:
   - Version dropdown populated.
   - Selected version's lines render.
   - Mode badge (Draft / Published / Deprecated) matches the version's state.
5. `[+ New Version]` (from Published mode) → switches to Draft mode with cloned lines, new EffectiveFrom = today + 30 days, success toast.
6. Editing a draft line (qty change, UOM change, item change via dropdown) flips the page-level `● Unsaved changes` indicator.
7. `[+ Add Component]` appends an empty row; user can fill it.
8. `[× Remove]` deletes a row.
9. `[↑]` / `[↓]` reorder rows; first/last row arrows correctly disabled.
10. `[Save Draft]` persists line edits to DB; success toast; reloading the page shows the persisted state.
11. `[Publish]` validates (zero lines blocked with friendly toast; missing EffectiveFrom blocked); on success the version transitions to Published mode, the dropdown updates, prior version stays Published unless explicitly deprecated (D2).
12. `[Discard Draft]` opens the `ConfirmDiscardDraft` popup → on confirm physically deletes the draft row; success toast.
13. `[Deprecate]` (on Published mode) opens the `ConfirmDeprecate` popup → on confirm sets DeprecatedAt; version transitions to Deprecated mode.
14. Switching to a different Item resets the BOMs tab state to that Item's versions.
15. Switching to a different version (within the same Item) reloads the active version's lines without triggering the dirty indicator on subsequent fresh edits.
16. `Audit.ConfigLog` rows captured for every create / save / publish / deprecate / discard, with full payload diffs visible in the Audit Log Browser (landed 2026-05-19).

---

## 11. References

- **Phase 1 spec (the contract being extended):** `docs/superpowers/specs/2026-05-19-item-master-view-shell-design.md`
- **Phase 1 plan:** `docs/superpowers/plans/2026-05-19-item-master-view-shell.md`
- **Mockup** §"Tab: BOMs" lines 651–773; JS handlers lines 3493–3548
- **Data Model:** `MPP_MES_DATA_MODEL.md` §2 Parts schema — `Bom`, `BomLine`, `Item`, `Uom`, `ItemType`. View `Parts.v_EffectiveItemLocation` (consumes published BOMs).
- **FDS:** `MPP_MES_FDS.md` §3.2 Bills of Material (FDS-03-004 through FDS-03-006); FDS-01-013 (BOM source at cutover); FDS-14-005 (Flexware import — out of scope here); FDS-05-033 (Trim → Machining 1-line BOM consumption — informs design assumption that single-level is sufficient).
- **Phased Plan Config Tool:** `MPP_MES_PHASED_PLAN_CONFIG_TOOL.md` §6 BOM Management — historical reference; this design supersedes it for the proc shape (bundled SaveAll instead of discrete `_Add` / `_Update` / `_Remove` / `_MoveUp` / `_MoveDown` per the modern bundled pattern).
- **Reference impl:** `sql/migrations/repeatable/R__Location_LocationTypeDefinition_SaveAll.sql` (bundled SaveAll shape — schema-editor variant); `sql/migrations/repeatable/R__Location_Location_SaveAll.sql` (bundled SaveAll — instance-editor variant — closer to BOM since children have no DeprecatedAt).
- **Memory:**
  - `project_mpp_item_master_pattern.md` — the 5-tab embedded-view + R1 bidi pattern
  - `project_mpp_bundled_save_pattern.md` — both variants of the bundled pattern; this design uses the instance-editor variant
  - `project_mpp_confirm_unsaved_pattern.md` — ConfirmDeprecate and ConfirmDiscardDraft popup shape
  - `feedback_ignition_message_scope.md` — page-scoped messages for embedded → parent
  - `feedback_ignition_nq_resource_schema.md` — Designer sqlType enum for new NQs
  - `feedback_ignition_view_edit_boundary.md` — file-edit vs Designer
  - `feedback_ignition_meta_visible_in_tables.md` — meta.visible for tabular row column alignment
- **Conventions pack:**
  - `ignition-context-pack/07_conventions_and_antipatterns.md` §"Save semantics" — editDraft + explicit Save; no `_MoveUp/_MoveDown` procs; rule 3 multi-tab forms
  - `ignition-context-pack/02_perspective_views.md` — bidi binding on Embedded View params
  - `ignition-context-pack/03_script_python.md` — `Common.Db.execMutation` and `Common.Util._currentAppUserId`
  - `ignition-context-pack/04_named_queries.md` — NQ v2 schema, Designer sqlType enum
- **CLAUDE.md** — Ignition JDBC compatibility (FDS-11-011: no OUTPUT params, one result set per proc, etc.); SQL design conventions.
