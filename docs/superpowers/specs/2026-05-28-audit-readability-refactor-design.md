# Audit Log Readability Refactor — Design

**Date:** 2026-05-28
**Status:** Spec drafted, pending user review
**Scope:** Project-wide convention for `Audit.ConfigLog` row content — `Description` prose + `OldValue` / `NewValue` JSON shape. Refactors ~31 audit-writing procs to emit human-readable narrative at write time. Companion UI tweaks to the AuditLog browser.

---

## 1. Purpose

`Audit.ConfigLog` rows currently encode the WHAT (entity type code, generic Description) but not the WHO/WHERE/WHICH. A typical Eligibility-save audit row reads:

| Date | User | Event | Entity Type | Entity ID | Description |
|---|---|---|---|---|---|
| 2026-05-28 14:32 | jpotgieter | Updated | ItemLocation | 1 | Eligibility map updated. |

To know which Item changed, the reader must JOIN `Audit.ConfigLog` to `Parts.Item`. To know which Location was added/removed, the reader must open the detail popup and read raw JSON containing `{LocationId: 3}` (with no Code/Name context). Same problem applies to BOMs, Routes, Identity, Container Config, Plant Hierarchy, LocationTypeEditor, Downtime Codes, and Defect Codes — every audit-writing proc emits IDs not names.

This refactor establishes a project-wide convention so every audit row tells a one-line story:

> `5G0 — Front Cover Assembly · Eligibility · +DIECAST (Production Area); -DC-401; ~DC-501 IsConsumptionPoint false→true`

…and the detail JSON encodes resolved-name objects (`{Id, Code, Name}`) instead of bare IDs.

## 2. Scope

**In scope:**

- New convention for `Audit.ConfigLog.Description` — composed at write time, never hardcoded.
- New convention for `OldValue` / `NewValue` JSON — every FK resolved to `{Id, Code, Name}` (or equivalent named tuple) before storage.
- Per-category Description format catalog (Eligibility / BOMs / Routes / Identity / Container Config / Quality Specs / Location Hierarchy / Location Types / Downtime Codes / Defect Codes / Operation Templates / Tools).
- Readability rules (per-operation cap, total cap, truncation semantics).
- AuditLog UI tweaks: rename `Description` → `Activity`, allow wrap, drop `EntityId`, keep `Changes` summary column.
- Backport plan + effort estimates per area.
- Convention codified in `sql_best_practices_mes.md` + CLAUDE.md so new procs inherit it.

**Out of scope:**

- Schema changes to `Audit.ConfigLog` itself — same columns, same types, just richer content.
- Backfill of pre-refactor rows (would require expensive joins against potentially-deprecated entities; not worth it). Old rows stay as-is. Convention takes effect for rows written after each proc lands.
- `Audit.FailureLog` — different surface (failure-reason narrative, not change narrative). Could get a similar pass later but distinct effort.
- Per-row audit grain (one row per atomic change). We keep one ConfigLog row per transaction (one Save = one row), matching the established pattern.

## 3. Convention: `Description` Format

### 3.1 Standard shape

```
<SUBJECT> · <CATEGORY?> · <ACTION>
```

- **Subject** — the primary entity being changed, in human-readable form (PartNumber + Description, Code + Name, etc.).
- **Category** — sub-area being changed (Identity / Container Config / Routes / BOMs / Quality Specs / Eligibility). Only present for compound editors (Item Master). Atomic entities (Downtime Code, Defect Code, Location) omit it; their Subject already conveys the category.
- **Action** — what specifically happened. Multi-change actions are concatenated with `; `.

Separator is the middle dot `·` (U+00B7), which gives a clean visual scan pattern without colliding with the `:` / `-` / `.` characters likely to appear in entity names. Implemented as `NCHAR(183)` in SQL to dodge codepage gotchas (lesson from the picker em-dash incident).

### 3.2 Per-change action verbs

| Verb | Symbol | Meaning |
|---|---|---|
| Added | `+` | New row / new line / new relationship |
| Removed | `-` | Soft-deleted (DeprecatedAt set) — for atomic entities or rows |
| Updated | `~` | Existing row's fields changed |
| Created | (verb) | First instance of the entity itself |
| Deprecated | (verb) | The whole subject was soft-deleted |
| Published | (verb) | Versioned entity transitioned Draft → Published |
| Reordered | (verb) | SortOrder change |
| Moved | (verb) | ParentLocationId / parent change |

The symbols (`+ - ~`) are used inline within multi-change Action prose ("`+DIECAST; -DC-401; ~DC-501 ...`"). The verbs are used when the whole event is a single state transition ("`Created`", "`Deprecated`", "`Published`").

### 3.3 Field-diff notation

For inline field changes use `Field old→new`:

```
~DC-501 IsConsumptionPoint false→true
~5G0 Description "Old desc" → "New desc"
~CASTING qty 1 → 2
```

- Bare scalars unquoted (`false→true`, `1 → 2`).
- Strings quoted with `"..."`.
- `NULL` rendered as literal `null` (unquoted).
- Multi-field diffs comma-separated: `IsConsumptionPoint false→true, MinQuantity null→0`.

### 3.4 Readability rules — truncation + overflow

For large change sets:

| Rule | Threshold | Behavior |
|---|---|---|
| Per-operation specifics cap | 3 specifics | Show 3, then `+N more` (or `-N more` / `~N more` per op) |
| Operation order | always | Adds first, then Updates, then Removes |
| Total Description cap | 500 chars | Hard cap; suffix `…` if exceeded |
| Detail popup fallback | always | Full per-change list lives in `OldValue` / `NewValue` JSON, never truncated |

Example progression for a BOMs SaveDraft on 5G0:

- 1-change save: `5G0 · BOM v3 (Draft) · +PNA-001 qty 1`
- 3-change save: `5G0 · BOM v3 (Draft) · +PNA-001 qty 1; -OBSOLETE-A; ~CASTING qty 1→2; 3 lines`
- 12-add save: `5G0 · BOM v3 (Draft) · +PNA-001 qty 1, +PNA-002 qty 1, +PNA-003 qty 1, +9 more; 12 lines`
- 12-add + 3-remove + 1-update save: `5G0 · BOM v3 (Draft) · +PNA-001 qty 1, +PNA-002 qty 1, +PNA-003 qty 1, +9 more; ~CASTING qty 1→2; -OBSOLETE-A, -OBSOLETE-B, -1 more; 15 lines`

The trailing `; N lines` (or `N rows`) suffix is included on **bundled-save Description** lines so the reader sees the total even when operations are summarized.

### 3.5 Atomic-entity Created / Deprecated lines

Created and Deprecated are single-state transitions, not change diffs. They get verb-form Descriptions:

- `Downtime Code MECH-FAULT — Mechanical Failure (Production Area) · Created`
- `Downtime Code MECH-FAULT · Deprecated`
- `Defect Code SCR-BLO — Scrap: Blowhole (Trim Shop) · Created`
- `Location MS-101 — CNC Machine 101 (Cell) · Created under MACHSHOP — Machine Shop`
- `Location MS-101 — CNC Machine 101 · Deprecated`

The full snapshot of the created/deprecated entity is still captured in `NewValue` / `OldValue` JSON. Description is just the at-a-glance line.

## 4. Convention: `OldValue` / `NewValue` JSON Format

### 4.1 FK resolution rule

Every FK reference in the JSON expands from bare-ID to a named tuple:

| Column | Old shape | New shape |
|---|---|---|
| `LocationId: 3` | `3` | `{Id: 3, Code: "DIECAST", Name: "Die Cast"}` |
| `ItemId: 1` | `1` | `{Id: 1, PartNumber: "5G0", Description: "Front Cover Assembly"}` |
| `UomId: 1` | `1` | `{Id: 1, Code: "EA", Name: "Each"}` |
| `LocationTypeDefinitionId: 7` | `7` | `{Id: 7, Name: "Production Area"}` |
| `DowntimeReasonTypeId: 2` | `2` | `{Id: 2, Code: "MECH", Name: "Mechanical"}` |
| `AppUserId: 5` | `5` | `{Id: 5, Initials: "JPGS", DisplayName: "Jacques Potgieter"}` |

Scalar columns (BIT, INT, NVARCHAR, DATETIME2) stay as scalars — only FKs expand.

### 4.2 Why resolve at write time

- **Stability across deprecation.** If a Location is later renamed or deprecated, old audit rows still show the Name as it was when the change happened. That's the correct audit semantic.
- **No JOIN at read time.** Detail popup parses the JSON once; no `Location.Location` lookup needed to display human names.
- **Cost is paid once per write, not once per read.** Write happens ~once per minute project-wide; reads happen ~hundreds per audit-browse session.

### 4.3 Storage impact

For an Eligibility SaveAll on an Item with 5 rows (mixed adds/updates), the OldValue JSON expands roughly:

- Bare-ID: `[{Id:1,LocationId:3,...},{Id:2,LocationId:7,...},...]` ~ 300 bytes
- Resolved: `[{Id:1,LocationId:{Id:3,Code:"DIECAST",Name:"Die Cast"},...},...]` ~ 800 bytes

~3× growth. `NVARCHAR(MAX)` column; not a storage concern at our event volume.

### 4.4 SQL implementation pattern

Resolution happens via `FOR JSON PATH` with subqueries. Reference shape from the Eligibility refactor:

```sql
SET @NewValue = (
    SELECT
        il.Id,
        (SELECT l.Id, l.Code, l.Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS Location,
        il.IsConsumptionPoint,
        il.MinQuantity, il.MaxQuantity, il.DefaultQuantity
    FROM @Incoming i
    INNER JOIN Location.Location l ON l.Id = i.LocationId
    -- ...
    FOR JSON PATH
);
```

Subquery-as-property-value pattern keeps the resolution local to the FK column. Slightly verbose but composable.

## 5. Per-Category Description Catalog

Worked examples for every audit-writing proc area, showing the convention applied.

### 5.1 Item Master compound (parent: `Parts.Item`)

| Sub-section | LogEntityTypeCode | Example Description |
|---|---|---|
| Identity (single-row update) | `Item` | `5G0 · Identity · Updated Description "Front Cover" → "Front Cover Assembly"; MacolaPartNumber 12345 → 12347` |
| Identity (Item create) | `Item` | `5G0 — Front Cover Assembly (Component) · Created` |
| Identity (Item deprecate) | `Item` | `5G0 — Front Cover Assembly · Deprecated` |
| Container Config | `ContainerConfig` | `5G0 · Container Config · Updated ClosureMethod ByCount → ByWeight; TargetWeight null → 1500` |
| Routes (Save Draft) | `RouteTemplate` | `5G0 · Route v2 (Draft) · +Step "Die Cast" #1, +Step "Trim" #2; -Step "Inspect" #4; 5 steps` |
| Routes (Publish) | `RouteTemplate` | `5G0 · Route v2 · Published (deprecated v1); 5 steps; effective 2026-06-01` |
| Routes (Deprecate) | `RouteTemplate` | `5G0 · Route v2 · Deprecated` |
| BOMs (Save Draft) | `Bom` | `5G0 · BOM v3 (Draft) · +Line PNA-001 qty 1, +Line PNA-002 qty 1, +Line PNA-003 qty 1, +9 more; -Line OBSOLETE-PART; ~Line CASTING qty 1→2; 15 lines` |
| BOMs (Publish) | `Bom` | `5G0 · BOM v3 · Published (deprecated v2); 3 lines; effective 2026-06-01` |
| BOMs (Deprecate) | `Bom` | `5G0 · BOM v3 · Deprecated` |
| Quality Specs (Create) | `QualitySpec` | `5G0 · Quality Spec "Diameter D1" · Created; tolerance 1.95–2.05 mm; sampling per 25` |
| Quality Specs (Update) | `QualitySpec` | `5G0 · Quality Spec "Diameter D1" · Updated tolerance Min 1.95→1.96, Max 2.05→2.06` |
| Quality Specs (Deprecate) | `QualitySpec` | `5G0 · Quality Spec "Diameter D1" · Deprecated` |
| Eligibility | `ItemLocation` | `5G0 — Front Cover Assembly · Eligibility · +DIECAST (Production Area); -DC-401; ~DC-501 IsConsumptionPoint false→true; 4 rows` |

### 5.2 Plant Hierarchy (parent: `Location.Location`)

| Action | LogEntityTypeCode | Example Description |
|---|---|---|
| Add Location | `Location` | `Location MS-101 — CNC Machine 101 (Cell) · Created under MACHSHOP — Machine Shop` |
| Update Location attributes | `Location` | `Location MS-101 · Updated Code "MS-101" → "MS-101-A"; Name "CNC Machine 101" → "CNC Machine 101A"; SortOrder 3 → 5` |
| Update Location attribute values | `LocationAttributeValue` | `Location MS-101 · Set attribute Building = "Building 3" (was "Building 2")` |
| Move Location | `Location` | `Location MS-101 · Moved from MACHSHOP — Machine Shop to TRIM — Trim Shop` |
| Deprecate Location | `Location` | `Location MS-101 — CNC Machine 101 · Deprecated` |
| Reorder Location | `Location` | `Location MS-101 · Reordered from #3 to #1 within MACHSHOP` |

### 5.3 Location Types (parent: `Location.LocationTypeDefinition`)

| Action | LogEntityTypeCode | Example Description |
|---|---|---|
| SaveAll (create with attributes) | `LocationTypeDefinition` | `Location Type Definition "Production Area" (Area tier) · Created; +Attribute Building, +Attribute Floor, +Attribute SquareFt` |
| SaveAll (update + attribute reconciliation) | `LocationTypeDefinition` | `Location Type Definition "Production Area" · +Attribute Building; -Attribute Floor; ~Attribute SquareFt → SquareFootage` |
| Deprecate | `LocationTypeDefinition` | `Location Type Definition "Production Area" · Deprecated (cascade: 3 attributes deprecated)` |

### 5.4 Downtime / Defect codes (atomic)

| Action | LogEntityTypeCode | Example Description |
|---|---|---|
| Create | `DowntimeReasonCode` | `Downtime Code MECH-FAULT — Mechanical Failure (Production Area, Excused) · Created` |
| Update | `DowntimeReasonCode` | `Downtime Code MECH-FAULT · Updated Name "Mechanical" → "Mechanical Failure"; Excused false → true` |
| Deprecate | `DowntimeReasonCode` | `Downtime Code MECH-FAULT · Deprecated` |
| Create | `DefectCode` | `Defect Code SCR-BLO — Scrap: Blowhole (Trim Shop) · Created` |
| Update | `DefectCode` | `Defect Code SCR-BLO · Updated Area "Trim Shop" → "Die Cast"; Description "Blowhole" → "Surface blowhole"` |
| Deprecate | `DefectCode` | `Defect Code SCR-BLO · Deprecated` |

### 5.5 Future / not-yet-built (convention applies when built)

| Area | Example Description |
|---|---|
| Operation Templates | `Operation "Die Cast Cycle" v2 · Updated CycleTime 45s → 50s; Added Parameter "PreheatTemp" 180°C` |
| Tools (mount/release on plant floor) | `Tool D-5G0-001 — 5G0 Die · Mounted on DC-401 (released D-5G0-002, lifetime 142,318 shots)` |

## 6. UI Changes

### 6.1 AuditLog table columns

| Column | Change |
|---|---|
| Date | unchanged |
| User | unchanged |
| Event | unchanged (LogEventTypeCode — Created / Updated / Deprecated / etc.) |
| Entity Type | unchanged (LogEntityTypeCode) |
| ~~Entity ID~~ | **dropped** (already in audit-log handoff) |
| Description | **renamed to `Activity`**; widened with `grow: 1`; `whiteSpace: pre-wrap`; max 2 visible lines with overflow-hidden + tooltip on hover for full text |
| Severity | unchanged |
| Changes | **kept** (yesterday's `summarizeJsonDiff` column); now genuinely useful because the JSON contains resolved names |

### 6.2 ConfigChangeDetail popup — currently broken, fix is in scope

The `BlueRidge/Components/Popups/ConfigChangeDetail` popup was built in the 2026-05-19 audit-pages work to render `OldValue` and `NewValue` side-by-side via `Common.Util.prettyJson`. **It is currently not working** (Jacques 2026-05-28). Diagnosing + fixing the popup is **in scope** for this refactor — it's the load-bearing surface for the "show me the full unabridged diff" user flow described in §6.3 below, and without it the truncation-and-recover story isn't actually recoverable.

Diagnostic to run first (Slice 1):
- Open `/audit` → click any existing ConfigLog row → observe whether the popup opens at all, opens-but-empty, or opens-with-error.
- If silent no-op: check the row-click handler scope (`scope: "G"` per `feedback_ignition_popup_open_scope.md` — common failure mode where `scope: "C"` silently drops `system.perspective.openPopup` calls).
- If opens-but-empty: check the `viewParams` payload — `OldValue` / `NewValue` may not be reaching the popup's bound props.
- If opens-with-error: check the popup's bindings against the actual ConfigLog row shape returned by `BlueRidge.Audit.ConfigLog.search` (may have drifted from when the popup was built).

Fix lands in Slice 1 alongside the column rename and EntityId drop. Acceptance: clicking any ConfigLog row in the AuditLog table opens the popup with both `OldValue` and `NewValue` JSON pretty-printed and side-by-side; close button works; subsequent row clicks open with the new row's data.

Optional polish (later, NOT this refactor): per-field highlighting of changes (red strikethrough on removed lines, green on added). Mentioned in audit handoff doc as a "nice to have not done". Defer until the basic popup is verified working.

### 6.3 Auditor user flow

The whole point of the truncation + cap rules in §3.4 is that **no data is ever lost** — the at-a-glance Description narrative is recoverable in two clicks. End-to-end flow:

1. **Auditor opens `/audit`** → AuditLog table renders with Date / User / Event / Entity Type / Activity / Severity / Changes columns. Default last-7-days filter.
2. **Auditor scans Activity column** — each row reads as `<Subject> · <Category> · <Action summary>`. Large changes show `+N more` overflow counters. 500-char cap keeps rows visually consistent.
3. **A row looks suspicious or interesting** (e.g., "Why was DC-401 removed from 5G0?", "Who deprecated the v2 BOM?") — auditor clicks the row.
4. **`ConfigChangeDetail` popup opens** showing the full `OldValue` (left) and `NewValue` (right) JSON, pretty-printed via `Common.Util.prettyJson`. With FK resolution per §4, JSON reads `LocationId: {Id: 3, Code: "DIECAST", Name: "Die Cast"}` — no DB lookups required.
5. **Auditor closes the popup** → table state preserved (filters intact, scroll position retained). Free to click another row immediately.

No JOINs against `Parts.Item` / `Location.Location` / etc. ever happen on the auditor side. Every name needed for the audit narrative was resolved at write time and lives in the row.

Failure modes the user flow defends against:
- **Entity later renamed** — audit row still shows the name as it was at write time (per §4.2).
- **Entity later deprecated** — audit row still shows the name; no NULL / "deleted" markers.
- **Very large change set** — Description truncates gracefully; full diff still in popup.
- **JSON readability for very deep nesting** — `prettyJson` handles arbitrary depth; popup is scrollable.

## 7. Refactor Approach

Each audit-writing proc gains four pieces, in this order at the proc:

1. **Subject resolution** — `SELECT @PartNumber = ..., @ItemDesc = ...` at proc start.
2. **Change-set capture** — temp variable / table for what's being changed (already done in SaveAll-style procs; minor addition for Update-style procs).
3. **Activity prose composition** — string building from the change-set, respecting truncation rules.
4. **Resolved JSON snapshots** — OldValue / NewValue with FK expansion.

No shared SQL helper for the prose composition. Each proc owns its narrative because each domain's language is distinct ("Step", "Line", "Attribute", etc.). Convention enforced by code review against this spec + the catalog in §5.

Two small helpers added to `Audit` schema:

- `Audit.ufn_TruncateActivity(@Text NVARCHAR(MAX))` — applies the 500-char cap with `…` suffix. Single inline-table-valued or scalar function. Trivial.
- `Audit.NCHAR_MIDDOT` — the middle-dot character returned by `NCHAR(183)`. Computed-once constant function to keep the separator visually consistent. Optional; procs can also inline `NCHAR(183)`.

## 8. Backport Plan

Eight independent slices. Each slice ships its own commit chain + updated tests + a few new audit assertion tests verifying the Description shape.

| # | Slice | Procs touched | Tests touched | Effort |
|---|---|---|---|---|
| 1 | **Convention spec + UI** (this doc + UI changes) | 0 SQL | 0 SQL | 1 session — lands the convention doc, AuditLog UI Activity column rename + wrap, EntityId drop, Changes column finish, **+ diagnose and fix ConfigChangeDetail popup (currently broken, see §6.2)** |
| 2 | **Eligibility** (reference impl) | `ItemLocation_SaveAllForItem` | `040_ItemLocation_SaveAllForItem.sql` | 1 session |
| 3 | **BOMs** | `Bom_Create`, `_CreateNewVersion`, `_SaveDraft`, `_Publish`, `_Deprecate`, `_DiscardDraft` | `010_Bom_crud.sql` and siblings | 1 session |
| 4 | **Routes** | `RouteTemplate_Create`, `_CreateNewVersion`, `_SaveAll`, `_Publish`, `_Deprecate`, `_DiscardDraft` | `020`-`031` Route tests | 1 session |
| 5 | **Item core (Identity + ContainerConfig)** | `Item_Create`, `Item_Update`, `Item_Deprecate`, `ContainerConfig_Create`, `_Update` | Item + ContainerConfig tests | 1 session |
| 6 | **Plant Hierarchy** | `Location_Create`, `_Update`, `_Deprecate`, `_MoveSortOrderUp`, `_MoveSortOrderDown`, `LocationAttributeValue_Set` | Location CRUD tests | 1 session |
| 7 | **LocationTypeEditor** | `LocationTypeDefinition_SaveAll`, `_Deprecate` | `030`-`040` LocationTypeDefinition tests | 1 session |
| 8 | **Downtime + Defect Codes** | `DowntimeReasonCode_Create`, `_Update`, `_Deprecate`, `DefectCode_*` | Downtime + Defect tests | 1 session |

Total: **~31 procs touched across 7 SQL slices + 1 spec/UI slice**.

Slices 2-8 are mutually independent — could be parallelized via subagent-driven-development, though sequential keeps test failures localized.

After each slice lands, every NEW audit row written by that area's procs uses the convention. Pre-refactor rows are NOT backfilled — they stay as-is. Old + new render in the same AuditLog UI (old rows just look generic; new rows tell stories).

## 9. Spec Self-Review — Open Questions / Risks

1. **`LogEntityTypeCode` granularity.** Currently we have `Item`, `ItemLocation`, `Bom`, `BomLine`, `RouteTemplate`, etc. as distinct codes. Do we keep this granularity (one code per affected table) or collapse to top-level domain (everything in Item Master becomes `Item` regardless of sub-section)? Recommendation: **keep granular** — lets the audit filter "show me only BOM changes" work without text searches. Sub-section is already in the Description prose.

2. **Multi-row events that span entity types** (e.g., a Plant Hierarchy SaveAll that updates a Location AND its attribute values). One ConfigLog row or two? Recommendation: **one row at the top-level entity** (`Location`), with the attribute-value changes folded into the Action prose. Simpler reader experience.

3. **`Activity` column width on the AuditLog table.** With wrap allowed + 2-line cap, what's the right basis? Recommendation: `grow: 1, basis: 0` so it absorbs all leftover horizontal space after the fixed-width columns. Mocks can refine.

4. **Locale / language assumption.** All Description text is English. Honda's MES requirements don't mandate multi-lingual audit; the team and the customer both operate in English. Convention assumes English text; if multi-lingual becomes a requirement later, the resolved-name JSON makes re-rendering feasible.

5. **What happens to the existing `summarizeJsonDiff` helper** (`Common.Util.summarizeJsonDiff` from yesterday's audit handoff)? It still produces the `Changes` column summary. With resolved JSON, the summary will read better ("`CountryOfOrigin: "US" → "MX"`" is fine; "`LocationId: {Id:3,Code:"DIECAST"...} → {Id:4,...}`" is noisy). Recommendation: **enhance `summarizeJsonDiff` to detect resolved-name objects** and render `LocationId: DIECAST → DC-401` instead of dumping the whole sub-object. ~20 lines of Python.

6. **Audit rows for Add/Remove eligibility specifically** — should `Add` use the verb-form (`5G0 · Eligibility · Added DIECAST`) or the symbol-form (`5G0 · Eligibility · +DIECAST`)? Recommendation: **symbol-form** for bundled SaveAll (since most saves have multiple changes); **verb-form** only for true single-state transitions like Create/Deprecate. Catalog in §5 follows this rule.

## 10. References

- Sibling specs: `2026-05-27-item-master-eligibility-design.md` (the immediate trigger), `2026-05-19-audit-pages-design.md` (current AuditLog UI)
- Memories: `feedback_check_nq_files_first.md` (lesson from Phase 8), `project_mpp_bundled_save_pattern.md` (SaveAll convention these procs follow)
- Existing audit infrastructure: `R__Audit_Audit_LogConfigChange.sql` (proc unchanged by this refactor; callers change), `BlueRidge.Common.Util.summarizeJsonDiff` (2026-05-27 helper for Changes column)
- In-flight: `HANDOFF_AUDIT_LOG_2026-05-28.md` (the Changes column Designer-side finish — folds into Slice 1)
- Convention sources: `sql_best_practices_mes.md` (will be updated with §3 + §4 conventions), CLAUDE.md (will gain a brief Audit Description Convention section pointing here)
