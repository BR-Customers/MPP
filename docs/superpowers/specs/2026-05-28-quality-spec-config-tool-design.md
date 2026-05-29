# Quality Spec Configuration Tool — Design

**Date:** 2026-05-28
**Status:** Spec drafted, pending user review
**Scope:** Standalone Quality Spec authoring screen (`/quality-specs`) + Phase 7 cross-navigation from the Item Master Quality Specs tab. Versioned Draft/Published/Deprecated editor over the already-built `Quality.QualitySpec*` SQL layer, with a small SQL workstream (UomId FK, bundled SaveDraft proc, spec-level Deprecate proc, audit-readability rework) and the full Ignition front-end.

---

## 1. Purpose

Engineering users need to author and version **quality specs** — named inspection specifications that attach (optionally) to an Item and/or an Operation Template, each carrying a versioned set of measurable **attributes** (name, data type, UOM, target, limits, required flag, sort order). This satisfies **FDS-08-008 / -009 / -010** (Quality Spec Management, Versioning, Attributes). Runtime inspection recording (FDS-08-011+) is Arc 2 plant-floor work and is **out of scope** here — this is the Configuration Tool authoring surface only.

The SQL data layer already exists (migration `0008_quality_spec_defect_code.sql` + ~20 repeatable procs + `sql/tests/0011_Quality_Spec/`). This build is **mostly Ignition front-end**, plus a contained SQL delta to (a) add the UomId FK the editor needs, (b) add a bundled draft-save proc matching the project's editDraft/explicit-Save convention, (c) add a spec-level deprecate proc, and (d) bring every quality-spec mutation proc onto the audit-readability convention.

## 2. Scope

**In scope:**

- New standalone page `/quality-specs` — master-detail Quality Spec Library + Editor.
- Draft / Published / Deprecated version lifecycle (BOMs vocabulary), with **date-resolved active versions** (no auto-deprecate on publish).
- Attribute grid editor with `UomId` FK dropdown, DataType-driven field gating, ▲▼ reorder, add/remove.
- Spec header editing (Name, Description) + spec-level Deprecate; spec creation via New Spec modal.
- Version History tab (read-only audit of versions).
- Phase 7 cross-nav: "Go to spec →" on the Item Master Quality Specs embed navigates to the standalone screen with the spec preselected.
- SQL delta: `UomId` FK migration; `QualitySpecVersion_SaveDraft` (bundled attribute reconciliation); `QualitySpec_Deprecate`; read-proc UOM joins; **audit-readability rework on every quality-spec mutation proc**; updated tests.
- New `named-query/quality/*` NQs + extended `BlueRidge.Quality.QualitySpec` entity script.

**Out of scope:**

- Runtime inspection (`QualitySample`, `QualityResult`, `QualityAttachment`) — Arc 2.
- Sampling triggers on the spec — `SampleTriggerCodeId` lives on the runtime `QualitySample`, never on the spec/attribute (confirmed against procs + mockup).
- The AuditLog UI refactor + `ConfigChangeDetail` popup fix — that is **Slice 1 of the audit readability refactor** (`2026-05-28-audit-readability-refactor-design.md`), landing before this work. We *consume* it; we don't build it.
- Backfill of pre-existing audit rows.

## 3. Lifecycle Model — Draft / Published / Deprecated, date-resolved active

The UI uses BOMs vocabulary on the already-built `QualitySpecVersion` procs:

| State | DB shape | Buttons |
|---|---|---|
| **Draft** | `PublishedAt IS NULL AND DeprecatedAt IS NULL` | Save Draft, Publish, Discard Draft |
| **Published** | `PublishedAt IS NOT NULL AND DeprecatedAt IS NULL` | Deprecate Version |
| **Deprecated** | `DeprecatedAt IS NOT NULL` | (view only) |

**Key difference from BOMs — date-resolved active versions (no auto-deprecate):** Publishing a version sets `PublishedAt` but does **not** deprecate the prior Published version. Multiple Published versions coexist; the operationally "active" one is resolved by `Quality.QualitySpecVersion_GetActiveForSpec @AsOfDate` (latest `EffectiveFrom <= today`, not deprecated). This enables scheduling a future spec revision while the current one stays active. The UI reflects this with a derived sub-badge on Published versions:

- **Active** — Published, `EffectiveFrom <= today`, and the newest such version.
- **Scheduled MM/DD** — Published, `EffectiveFrom > today` (future-effective; context-pack §07 convention).
- **Superseded** — Published, `EffectiveFrom <= today`, but a newer Published version is active.

Transitions:

- **New Version** → clones the latest non-deprecated version's attributes into a new Draft (`VersionNumber + 1`). Blocked (Status=0) if a Draft already exists for the spec (built proc behavior).
- **Save Draft** → reconciles attributes + `EffectiveFrom` on the Draft row in place.
- **Publish** → `publishWithSave` (SaveDraft then `_Publish`, Routes-style) so attribute edits commit atomically with publish. Publish proc validates ≥1 attribute and required-field completeness; returns Status=0 + Message on failure.
- **Discard Draft** → hard-deletes the Draft version + its attributes (the only legitimate DELETE).
- **Deprecate Version** → Published → Deprecated.
- **Deprecate Spec** → soft-deletes the whole spec header (new proc, cascades to versions).

## 4. SQL Workstream

The built procs are Draft/Published/Deprecated-ready; this delta fills the gaps the editor + decisions require.

### 4.1 Migration — `0017_qualityspec_attribute_uom_fk.sql` (next free slot; latest is `0016`)

- Add `UomId BIGINT NULL` to `Quality.QualitySpecAttribute` with FK → `Parts.Uom(Id)`.
- The editor writes `UomId`; the legacy free-text `Uom NVARCHAR(20)` column is left in place (no destructive drop — dev DB resets rebuild from scratch) but is no longer written by the editor procs. Mark it deprecated in the data-model doc.
- Reconcile the data-model doc drift noted by research: document `PublishedAt` on `QualitySpecVersion` and the `UNIQUE(QualitySpecId, VersionNumber)` / `UNIQUE(QualitySpecVersionId, AttributeName)` indexes that migration 0008 already created.

### 4.2 New procs (repeatable)

- **`R__Quality_QualitySpecVersion_SaveDraft.sql`** — bundled attribute reconciliation. Params: `@QualitySpecVersionId BIGINT`, `@EffectiveFrom DATETIME2(3)`, `@AttributesJson NVARCHAR(MAX)`, `@AppUserId BIGINT`. Reconciles desired-state JSON against active attributes: `Id`-null → INSERT, `Id`-match → UPDATE, active `Id` absent → DELETE; `SortOrder` from array index (1-based). Each JSON element: `{Id, AttributeName, DataType, UomId, TargetValue, LowerLimit, UpperLimit, IsRequired}`. Guards: only operates on a Draft version (Status=0 otherwise). Status-row return. Replaces the per-action `_Add/_Update/_Remove/_MoveUp/_MoveDown` procs **for this editor** (those stay for any other consumer but are not called per-click — per the "editDraft + one explicit Save, no per-click procs" convention).
- **`R__Quality_QualitySpec_Deprecate.sql`** — spec-header soft-delete. Params: `@QualitySpecId BIGINT`, `@AppUserId BIGINT`. Sets the header's deprecation marker and cascade-deprecates its versions. Status-row return. (Adds a `DeprecatedAt` column to `Quality.QualitySpec` in 4.1 if not present — research shows the header currently has no soft-delete column.)

### 4.3 Read-proc joins

- `Quality.QualitySpecAttribute_ListByVersion` joins `Parts.Uom` to return `UomId` + `UomCode`/`UomAbbreviation` for display.
- `Quality.QualitySpec_List` already returns `VersionCount` / `ActiveVersionCount` + the link FKs; confirm it returns enough for the library list (spec name, item PartNumber, op-template code, derived state). Extend if needed.

### 4.4 Audit-readability rework (every quality-spec mutation proc)

Per the approved audit-readability convention (`2026-05-28-audit-readability-refactor-design.md` §3/§4), each mutation proc composes a human-readable `Description` (Activity) and resolved-name `OldValue`/`NewValue` JSON at write time. Quality specs are built to convention from day one — no later backport slice. See §7 for the full catalog.

### 4.5 Tests

Update `sql/tests/0011_Quality_Spec/` for the `UomId` column + SaveDraft reconciliation + spec-deprecate + the publish-without-auto-deprecate semantics, plus a few audit-assertion tests verifying Description shape (mirroring the audit refactor's per-slice test additions). Reset dev DB.

## 5. Named Queries (`named-query/quality/`)

Group folder is the schema name (`quality/`), not `parts/`. Mutations all use `attributes.type: "Query"` (status-row rule). `sqlType`: 3=BIGINT, 7=NVARCHAR/JSON, 8=DateTime, 6=Boolean, 5=Float8/DECIMAL.

**Reads:** `QualitySpec_List`, `QualitySpec_Get`, `QualitySpecVersion_ListBySpec`, `QualitySpecVersion_Get`, `QualitySpecAttribute_ListByVersion`, `Uom_List` (or reuse `parts/Uom_List`). Existing `QualitySpec_ListForItem` stays (Item Master embed).

**Mutations (type:Query):** `QualitySpec_Create`, `QualitySpec_Update`, `QualitySpec_Deprecate`, `QualitySpecVersion_Create` (v1), `QualitySpecVersion_CreateNewVersion`, `QualitySpecVersion_SaveDraft`, `QualitySpecVersion_Publish`, `QualitySpecVersion_DiscardDraft`, `QualitySpecVersion_Deprecate`.

> Confirm built-proc parameter names during build: research flagged `_GetActiveForSpec` (not `_GetActive`) and `@SourceVersionId` (not `@ParentVersionId`). NQ wrappers match the actual proc signatures.

## 6. Ignition Front-End

### 6.1 Entity script — extend `BlueRidge.Quality.QualitySpec`

Mirror `BlueRidge.Parts.Bom`'s surface (the cleaner reference vs Routes). All DB access through `Common.Db.*`; `@AppUserId` via `Common.Util._currentAppUserId()`; deep-unwrap entry points with `extractQualifiedValues`; JSON params via `convertWrapperObjectToJson` / `system.util.jsonEncode`.

- **Reads:** `getAllForList(filter)`, `getSpecHeader(specId)`, `listVersions(specId, includeDeprecated)`, `getVersionFull(versionId)` (header + attributes, derive state + active/scheduled/superseded), `listUoms()`. Keep existing `listForItem(itemId)`.
- **Mutations:** `createSpec(data)`, `updateSpecHeader(data)`, `deprecateSpec(specId)`, `createNewVersion(specId)` (routes to `_Create` for v1 / `_CreateNewVersion` otherwise; refuses if a Draft exists), `saveDraft(versionId, effectiveFrom, attributes)`, `publish(versionId, effectiveFrom, attributes)` (saveDraft then `_Publish`), `discardDraft(versionId)`, `deprecateVersion(versionId)`.

### 6.2 Standalone screen — `Views/Quality/QualitySpecs/view.json`

Extend the existing wireframe shell into a working master-detail. Owns `view.custom`:

- `specs` (library rows), `filter` (`{searchText, type}` where type ∈ All/Item-Linked/Op-Linked/Unlinked), `selectedSpecId`, `incomingSpecId` (cross-nav preselect).
- `specHeader = {selected, editDraft}` — name + description (header dirty source).
- `state = {selected, editDraft}` — the active version bundle: `{id, specId, versionNumber, effectiveFrom, effectiveFromDisplay, publishedAt, deprecatedAt, status, attributes: []}`.
- `isDirty` — binding-based, `convertWrapperObjectToJson` JSON compare of header AND (when a Draft is selected) attributes + effectiveFrom.
- `activeVersionId`, `versions`, `uoms`.

**Atomic state writes throughout** — `load()` / version-change / new-version write `view.custom.state = {"selected": …, "editDraft": …}` in ONE assignment (and `specHeader` likewise). Sequential writes cause the spurious-dirty-latch documented in CLAUDE.md.

Layout (per mockup, lines 1055–1399):

- **Left rail (~300px):** search box + type filter dropdown + `+ New Spec` button + scrollable spec list. Each row: spec name + state badge (Published/Draft/Deprecated, with Active/Scheduled sub-badge) + linkage subline (`Item: 5G0 · Op: CNC-5G0`).
- **Right detail:** spec header card (Name editable, Linked Item read-only, Linked Op Template read-only, Description editable, Save + Deprecate Spec) → version bar (version dropdown + state badge + EffectiveFrom + lifecycle buttons) → tabs (Attributes grid | Version History read-only table).

Dirty + nav guard: self-contained `ConfirmUnsaved` (Save & Continue / Discard & Continue / Cancel) on spec-switch and page-nav-away when `isDirty`. **No** Item Master parent gating (this is standalone). `ConfirmDestructive` for Deprecate Spec / Deprecate Version / Discard Draft.

### 6.3 New sub-view — `Components/Quality/QualitySpecAttributeRow/view.json`

Mirror `BomLineRow`. All params `paramDirection: "input"` (`rowIndex, attrCount, mode, attribute, uoms, dataTypes`). Editable only when `mode == "draft"`; display labels otherwise. Controls: AttributeName text field, DataType dropdown (Numeric/Boolean/Text), **UOM dropdown** (from `uoms`), Target/Lower/Upper numeric entries, Required checkbox, ▲▼ move, ✕ remove. **DataType gating:** UOM + Target + Lower + Upper disabled (greyed, `—` placeholder) when DataType ∈ {Boolean, Text}; reserve slot width via `meta.visible` so row geometry stays uniform.

Edits cross the embed boundary via **page-scoped messages** carrying `rowIndex` (embed params are input-only): `qsAttrMoveUp`, `qsAttrMoveDown`, `qsAttrRemove`, `qsAttrNameChanged`, `qsAttrDataTypeChanged`, `qsAttrUomChanged`, `qsAttrTargetChanged`, `qsAttrLowerChanged`, `qsAttrUpperChanged`, `qsAttrRequiredChanged`. Parent handlers mutate `state.editDraft.attributes` by building a fresh draft dict and reassigning the whole `state.editDraft` atomically. `+ Add Attribute` appends an empty attribute (`Id: None` → INSERT).

The attribute grid is a `flex-repeater` whose `props.instances` is a property binding on `state.editDraft.attributes` + a script transform emitting per-row `{rowIndex, attribute, attrCount, mode, uoms, dataTypes}`.

### 6.4 New Spec modal

Small popup (reuse the popup pattern): Name, Linked Item dropdown *(optional, — none —)*, Linked Operation Template dropdown *(optional)*, Description, initial Effective Date. Create → `createSpec` → `notifyResult` → refresh library + select the new spec (which has no versions yet → prompts a first New Version).

### 6.5 Page registration + nav

- `page-config/config.json`: `/quality-specs` → `BlueRidge/Views/Quality/QualitySpecs` with a `title`.
- Sidebar: add a Quality Specs entry under the Quality nav category.

### 6.6 Phase 7 cross-nav

`Components/Parts/ItemMaster/QualitySpecs/view.json` (currently a read-only stub with the literal "Phase 7 will add…" hint): add a per-row **"Go to spec →"** button → navigate to `/quality-specs` passing the spec id (page param). The standalone screen reads `incomingSpecId` on load and preselects it. Remove the placeholder hint label.

## 7. Audit Readability — Quality Spec Catalog

Every quality-spec mutation proc emits the approved convention. Subject = `<PartNumber> — <ItemDescription>` when item-linked (or op-template / spec name when not), separator `·` (`NCHAR(183)`), change symbols `+ - ~`, `field old→new` diffs, 3-specifics cap + `+N more`, `; N attributes` suffix, 500-char cap.

| Op | Example Activity |
|---|---|
| Create spec | `5G0 — Front Cover · Quality Spec "Dimensional Spec" · Created` |
| Update header | `5G0 · Quality Spec "Dimensional Spec" · Updated Name "Dim Spec"→"Dimensional Spec"; Description "…"→"…"` |
| New Version | `5G0 · Quality Spec "Dimensional Spec" v3 (Draft) · Created (cloned from v2)` |
| Save Draft | `5G0 · Quality Spec "Dimensional Spec" v3 (Draft) · +Attr "Bore Dia" (Numeric, mm); -Attr "Old Check"; ~Attr "Flatness" UpperLimit 0.003→0.0035; 4 attributes; effective 2026-06-01` |
| Publish | `5G0 · Quality Spec "Dimensional Spec" v3 · Published; 4 attributes; effective 2026-06-01` |
| Discard Draft | `5G0 · Quality Spec "Dimensional Spec" v3 (Draft) · Discarded` |
| Deprecate version | `5G0 · Quality Spec "Dimensional Spec" v3 · Deprecated` |
| Deprecate spec | `5G0 · Quality Spec "Dimensional Spec" · Deprecated` |

Publish line carries **no** "(deprecated vN)" suffix — the date-resolved model has no auto-deprecate (contrast BOMs/Routes catalog entries).

**Resolved-name JSON** (`OldValue`/`NewValue`, via `FOR JSON PATH` subqueries):
- `ItemId → {Id, PartNumber, Description}`
- `OperationTemplateId → {Id, Code, Name}`
- each attribute row → `{Id, AttributeName, DataType, Uom: {Id, Code, Name}, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder}`

This dovetails with the refactor's §4.1 rule (`UomId → {Id, Code, Name}`) and makes the quality-spec procs a clean reference impl of the convention for a *versioned-with-children* entity.

## 8. Build Sequence

1. **SQL** — migration (UomId FK + QualitySpec.DeprecatedAt + data-model doc reconcile); `QualitySpecVersion_SaveDraft`; `QualitySpec_Deprecate`; read-proc UOM joins; audit-convention rework on every mutation proc; tests; reset dev DB. Verify all tests green.
2. **Named queries** — reads + mutations under `quality/`. Verify every read NQ exists as a folder (per `feedback_check_nq_files_first` lesson).
3. **Entity script** — extend `BlueRidge.Quality.QualitySpec`.
4. **`QualitySpecAttributeRow`** sub-view.
5. **Standalone screen** — shell → library list + filter → header card → version bar + lifecycle → attribute grid → version history → dirty/ConfirmUnsaved wiring.
6. **New Spec modal.**
7. **Page registration + sidebar nav.**
8. **Phase 7 cross-nav** from Item Master embed.
9. `.\scan.ps1` → Designer smoke test (library renders, filter, select, new spec, new version, edit attributes + dirty, save draft, publish, scheduled badge, deprecate, discard, cross-nav, audit rows in `/audit`).

## 9. Open Questions / Risks

1. **`QualitySpec` header soft-delete column.** Research indicates the header has no `DeprecatedAt`. The spec-level Deprecate (your decision) requires adding it in 4.1. Confirm column name (`DeprecatedAt` + `DeprecatedByUserId`) matches project convention.
2. **Publish validation rules.** What makes a version publishable? Assumed: ≥1 attribute, and every attribute has AttributeName + DataType (+ for Numeric, at least one of Target/Lower/Upper). Confirm during build; enforced in `_Publish` proc, not the UI.
3. **EffectiveFrom on Draft vs Publish.** Mockup shows an editable Effective Date in the draft/pending header. Assumed: `EffectiveFrom` is editable on the Draft and locked at Publish (matching BOMs). Constraint `EffectiveFrom >= cast(getdate() as date)` at publish time.
4. **Existing standalone shell view (~32KB).** Extend in place vs rebuild. Recommendation: extend the existing shell to preserve any layout already matching the mockup; rebuild sections that are pure placeholder.
5. **Audit UI dependency.** Slice 1 (Activity column + `ConfigChangeDetail` fix) lands before this work (user confirmed). If it slips, quality-spec audit rows still write correctly but render in the pre-refactor AuditLog UI.

## 10. References

- Decisions captured this session: standalone screen + Phase 7 cross-nav; Draft/Published/Deprecated UI; UomId FK dropdown; date-resolved publish (no auto-deprecate); add `QualitySpec_Deprecate`.
- FDS §8.3 (`MPP_MES_FDS.md` — FDS-08-008/009/010); data model §5 quality schema (`MPP_MES_DATA_MODEL.md`).
- Mockup: `mockup/index.html` lines 1055–1399 (standalone screen) + 775–806 (Item Master link tab) + 2893–2939 (New Spec modal).
- SQL: `sql/migrations/versioned/0008_quality_spec_defect_code.sql`; `sql/migrations/repeatable/R__Quality_QualitySpec*.sql`; tests `sql/tests/0011_Quality_Spec/`.
- Reference impls: `BlueRidge.Parts.Bom` + `Components/Parts/ItemMaster/Boms` + `BomLineRow` (versioned editor pattern); `LocationTypeEditor` (standalone editor + ConfirmUnsaved).
- Audit convention: `docs/superpowers/specs/2026-05-28-audit-readability-refactor-design.md` (§3 Description format, §4 JSON FK resolution, §5.1 quality-spec catalog stub superseded by §7 here).
- Conventions/memories: `project_mpp_item_master_pattern` (atomic state writes), `feedback_ignition_embed_params_input_only`, `feedback_ignition_nq_type_for_status_row_procs`, `feedback_ignition_no_foreach_in_expressions`, `feedback_check_nq_files_first`, `project_mpp_confirm_unsaved_pattern`, `feedback_no_business_logic_in_python`.
