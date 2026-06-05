# Eligibility-Style Config Editors — Design

**Date:** 2026-06-05
**Author:** Blue Ridge Automation
**Status:** Approved design (pre-implementation)
**Scope:** Configuration Tool (Arc 1) — Tools screen tabs + Operation Templates fields panel

---

## 1. Problem & Goal

The **Item Master → Eligibility** section established a clean editing model: inline-editable rows, a per-section draft with **Save/Discard that appear only when dirty**, atomic all-or-nothing persistence, and page-scoped row→section messaging. It "feels" good because of that editing *rhythm*, not just its styling.

Three other surfaces do the opposite — read-only rows, a **modal per add**, and **immediate per-row DB writes** with no Save:

- **Tools → Attributes** (modal add + nested definition modal; display-only rows; remove-only)
- **Tools → Cavities** (modal add; status changed via immediate buttons; remove asymmetry)
- **Tools → Assignments** (Mount-to-Cell modal; release button; history table)
- **Operation Templates → Fields panel** (dropdown+button add; immediate add/toggle/remove per row)

**Goal:** port the eligibility editing model onto these surfaces so they look and feel consistent, replacing modal-add + immediate-write with inline draft editing + Save/Discard wherever it fits.

---

## 2. Decisions (from brainstorming, 2026-06-05)

| # | Decision | Choice |
|---|---|---|
| D1 | Core interaction model | **Full eligibility model**: inline draft editing + per-section Save/Discard + atomic `…SaveAll` proc, everywhere it fits |
| D2 | Cavities status (state machine) | **Status as an inline dropdown** — one draft rhythm; a mistaken Scrap is reversible via Discard before Save; saved-Scrapped rows lock |
| D3 | Assignments (append-only history) | **Inline mount, no modal** — adopt the chrome + inline cell-picker; mount/release stay immediate & audited; **no** draft/Save |
| D4 | Operation-Template field ordering | **Not configurable** — fields stay unordered (no `SortOrder`), like eligibility |
| D5 | Attribute value input | **Type-aware** — input adapts to the definition's `DataType`; proc validates conformance |

---

## 3. Reference pattern (what we're copying)

From `BlueRidge/Components/Parts/ItemMaster/Eligibility` + `…/EligibilityRow` + `BlueRidge.Parts.Eligibility`:

- Section embed receives an **input-only** BIGINT id param.
- Owns `view.custom.state = {selected, editDraft}`, **written atomically in one assignment** on load (prevents the transient-mismatch stuck-dirty bug — see `project_mpp_item_master_pattern` memory).
- `isDirty` = `convertWrapperObjectToJson(editDraft) != convertWrapperObjectToJson(selected)`.
- Header shows **Discard** + **Save**, visible/enabled only when dirty.
- Rows = flex-repeater of inline-editable sub-rows. Row → section communication via **page-scoped messages** carrying the row index; the section mutates `editDraft` and writes the **whole state back atomically**.
- `+ Add` appends a blank draft row; `×` removes a row.
- **Save** calls one atomic `…SaveAll` proc (insert-on-null-id / update-on-match / deprecate-on-absent), routes through `Common.Ui.notifyResult`, and on success reloads `selected` from the DB.
- Each section broadcasts `sectionDirtyChanged {section, isDirty}`; the parent gates navigation through the reusable `ConfirmUnsaved` popup.

---

## 4. Shared architecture for the converted sections

Each **draft** section (Attributes, Cavities, Operation-Template Fields) is a self-contained per-section editor following §3. **Assignments is a deliberate non-draft exception** (D3): it adopts the chrome but performs immediate audited mutations, never raises `sectionDirty`, and never blocks navigation.

**Parent gating.** The parent **Tools** view gains a `sectionDirty` flag map and gates **tab switching** and **tool switching** (list-row click) through `ConfirmUnsaved`, mirroring Item Master. The **Operation Templates** view already gates template/version switches on metadata-dirty; that gating extends to cover the Fields section's dirty flag.

**Atomic-state rule (normative).** `load()` and any reseed must write `view.custom.state = {selected: dict(x), editDraft: dict(x)}` in ONE property assignment — never two sequential writes.

**Layering.** Views → entity scripts (`BlueRidge.Parts.*`) → `BlueRidge.Common.Db.*`. No `system.db.*` in views. Validation/business rules live in the procs, not Jython (per `feedback_no_business_logic_in_python`).

---

## 5. Per-screen designs

### 5.1 Tools → Attributes (draft section)

Header `Attributes` + Discard/Save. Columns: `# | Definition | Value | ×`.

- **New row:** Definition dropdown listing only `ToolAttributeDefinition`s for the tool's `ToolType` **not already present** on the tool; type-aware value input.
- **Existing row:** Definition rendered as a read-only label (changing the key = remove + re-add); value editable; `×` removes.
- **Type-aware value (D5):** the row carries all four input types, showing only the one matching the row's `DataType` via `position.display`:
  - `String` → `ia.input.text-field`
  - `Integer` / `Decimal` → `ia.input.numeric-entry-field`
  - `Boolean` → `ia.input.checkbox`
  - `Date` → `ia.input.date-time-input`
- **Canonical storage** in `ToolAttribute.Value` (NVARCHAR): String as-is; Integer/Decimal as numeric string; Boolean as `"true"`/`"false"`; Date as `"YYYY-MM-DD"`.
- `+ New definition` remains a small popup (`AddAttributeDefinition`), refreshing the available-definitions dropdown on success.
- **Save → `Tools.ToolAttribute_SaveAll`** (full reconcile: insert new, update value, **delete-on-absent** — `ToolAttribute` is a current-values table with no `DeprecatedAt`, so removal is a hard `DELETE` of the value row, matching the existing `ToolAttribute_Remove`), with **per-DataType validation** (reject non-conforming values with `Status=0` naming the field).

### 5.2 Tools → Cavities (draft section)

Header `Cavities` + Discard/Save. Columns: `# | Description | Status | ×`.

- **New row:** number (numeric, editable), description, status defaults `Active`; `×` discards the unsaved draft row.
- **Existing row:** number **read-only** (immutable per model); description editable; status dropdown `Active / Closed / Scrapped`. A **saved-Scrapped** row is locked (read-only, dimmed). **No `×`/delete on saved cavities** — end-of-life is `Scrapped`, not deletion.
- **Save → `Tools.ToolCavity_SaveAll`** — **insert + update only** (number on insert; description + status on update). It does **not** deprecate-on-absent (cavities persist). Enforces: number immutable on existing rows; no transition out of `Scrapped`; unique active `(ToolId, CavityNumber)`.

### 5.3 Tools → Assignments (non-draft; look only)

- **Active-mount banner** when mounted: cell name + assigned-at/by + **Release**.
- **Inline mount zone** (replaces the `MountToCell` popup): compatible-cell dropdown (**reuses `Tools.Tool_ListCompatibleCells`**) + optional notes + **Mount**; disabled while a mount is active.
- **Read-only history** table below with the same column-header chrome.
- Mount/Release call the existing `ToolAssignment_Assign` / `ToolAssignment_Release` procs immediately (elevated, audited). No draft, no `sectionDirty`.
- **Delete** the `MountToCell` popup view + the entity `getCellsForDropdown` stays (now consumed by the inline picker instead of the popup).

### 5.4 Operation Templates → Fields panel (draft section)

Metadata + version-lifecycle panels unchanged. Fields panel becomes a per-section editor. Header `Data Collection Fields` + Discard/Save. Columns: `# | Code | Name | Required | ×`.

- **New row:** field dropdown (available `DataCollectionField`s not yet attached) → fills Code/Name; Required checkbox.
- **Existing row:** Code/Name read-only; Required checkbox editable; `×` removes.
- Unordered (D4 — no `SortOrder`).
- **Save → `Parts.OperationTemplateField_SaveAll`** (full reconcile: insert / update `IsRequired` / deprecate-on-absent).
- The old per-row immediate mutations (`addField` / `setFieldRequired` / `removeField`) are retired from the UI.

---

## 6. SQL changes

New stored procs (repeatable migrations) + thin Named Queries:

| Proc | Params | Reconcile | Notes |
|---|---|---|---|
| `Tools.ToolAttribute_SaveAll` | `@ToolId`, `@RowsJson`, `@AppUserId` | insert / update / **delete-on-absent (hard)** | `ToolAttribute` has no `DeprecatedAt` — removal is a hard `DELETE`. Validates each row's value against its definition `DataType` (TRY_CAST int/decimal/date; Boolean ∈ {true,false}); rejects with `Status=0` + field name. Honors `UQ_ToolAttribute_ToolAttributeDefinition`. |
| `Tools.ToolCavity_SaveAll` | `@ToolId`, `@RowsJson`, `@AppUserId` | insert + **update only** (no deprecate-on-absent) | Number immutable on existing; reject transitions out of `Scrapped`; honor `UQ_ToolCavity_ActiveToolCavityNumber`. |
| `Parts.OperationTemplateField_SaveAll` | `@OperationTemplateId`, `@RowsJson`, `@AppUserId` | insert / update `IsRequired` / **deprecate-on-absent** | Honors `UQ_OperationTemplateField_ActiveTemplateField`. |

- Each returns the standard status row `SELECT @Status, @Message, @NewId` (`@NewId` = parent id echo).
- Each emits `Audit.ConfigLog` on success / `Audit.FailureLog` on rejection, following the audit Description convention.
- Reuses the established `SaveAll` reconciliation pattern (`project_mpp_bundled_save_pattern`).
- NQ resources: `version: 2`, `type: "Query"` (status-row mutation), one `@…Json` param (`sqlType` 7) + id (`sqlType` 3) + appUserId (`sqlType` 3).
- No schema changes (D4 means no new `SortOrder` column). Existing tables/indexes are sufficient.

---

## 7. File inventory

**SQL (new):**
- `sql/migrations/repeatable/R__Tools_ToolAttribute_SaveAll.sql`
- `sql/migrations/repeatable/R__Tools_ToolCavity_SaveAll.sql`
- `sql/migrations/repeatable/R__Parts_OperationTemplateField_SaveAll.sql`

**Named queries (new):**
- `…/named-query/parts/ToolAttribute_SaveAll/{query.sql,resource.json}`
- `…/named-query/parts/ToolCavity_SaveAll/{query.sql,resource.json}`
- `…/named-query/parts/OperationTemplateField_SaveAll/{query.sql,resource.json}`

**Entity scripts (modify):**
- `BlueRidge/Parts/Tool/code.py` — add `saveAttributesAll`, `saveCavitiesAll`, available-definitions helper; keep mount/release; retire per-row attribute/cavity mutations from UI use.
- `BlueRidge/Parts/OperationTemplate/code.py` — add `saveFieldsAll`, available-DCF helper; retire `addField`/`setFieldRequired`/`removeField` from UI use.

**Views (rewrite sub-views — file-edit + scan, they're effectively new content):**
- `…/Tools/Attributes/view.json` + `…/_Tools/AttributeRow/view.json` (type-aware value)
- `…/Tools/Cavities/view.json` + `…/_Tools/CavityRow/view.json`
- `…/Tools/Assignments/view.json` + `…/_Tools/AssignmentRow/view.json` (inline mount + read-only history)
- `…/OperationTemplates/_OperationTemplates/FieldRow/view.json`

**Views (modify parent wiring — done carefully per view-edit boundary):**
- `BlueRidge/Views/Parts/Tools/view.json` — `sectionDirty` map + tab/tool-switch gating.
- `BlueRidge/Views/Parts/OperationTemplates/view.json` — Fields section dirty gating.

**Views (delete):**
- `…/Popups/MountToCell/view.json`, `…/Popups/AddAttribute/view.json`, `…/Popups/AddCavity/view.json` (retired by inline editing). `AddAttributeDefinition` popup **kept**.

---

## 8. Out of scope

- No change to the eligibility section itself (it's the reference).
- No new `DataCollectionField` / `ToolAttributeDefinition` admin screens (definition-create stays the small popup).
- No field ordering / `SortOrder` (D4).
- No Arc 2 / plant-floor surfaces.

---

## 9. Testing & verification

- **SQL:** proc tests for each `…SaveAll` (insert/update/deprecate reconcile; attribute DataType validation incl. reject paths; cavity number-immutability + Scrapped-lock; unique-index conflicts) under `sql/tests/`.
- **UI:** manual verification per screen — dirty appears on edit, Save persists + clears dirty, Discard reverts, cross-tab/cross-tool navigation gated by `ConfirmUnsaved`, type-aware inputs render per DataType, Assignments inline mount/release immediate, MountToCell popup gone.
- Apply procs non-destructively to `MPP_MES_Dev`; `scan.ps1` for Ignition resources.

---

## 10. Risks & notes

- **View-edit boundary:** several targets are existing views. New/rewritten sub-views are file-edited + scanned; parent-view wiring (`Tools`, `OperationTemplates`) is the riskiest — do in Designer where reconciliation races are a concern, and watch for Designer's `=` escapes when file-matching.
- **Cavity `SaveAll` divergence:** intentionally *not* deprecate-on-absent (cavities persist; end-of-life via Scrapped) — differs from the generic SaveAll and from the attribute/field procs.
- **Per-section atomic state writes** are mandatory to avoid the stuck-dirty popup bug.
- **`runScript`-bound custom props** must carry fully-shaped defaults; type-aware value rows must seed every input's bound path.
