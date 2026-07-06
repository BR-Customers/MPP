# Operation-Type Model Restructure — Design Spec

**Date:** 2026-07-02
**Status:** Draft — awaiting Jacques review
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Config Tool (Arc 1) data-model correction; unblocks Machining & Assembly plant-floor flow
**Companion:** This is **Spec 1 of 2**. Spec 2 (`2026-07-02-machining-assembly-plant-floor-flow-design.md`) builds the machining/assembly LOT flow (FIFO selection, machining-in/out sublot, assembly-out create+consume, inventory panel) **on top of** this restructure. Spec 1 is buildable first and independently; Spec 2 depends on the `OperationType` role introduced here.

---

## 1. Motivation

The customer walkthrough of the machining/assembly lines exposed a modeling smell in the operation-template layer:

- `Parts.OperationTemplate` carries `AreaLocationId` — a FK to a **specific Area instance** (DC1, TRIM1, MA1, …) — plus `UNIQUE(Code, VersionNumber)`. The four die-cast areas (DC1–DC4) and both trim shops (TRIM1, TRIM2) are the **same generic Area type** (`LocationTypeDefinitionId = 3`); die-cast-ness vs trim-ness lives only in the name. So a single "die casting" operation must be **duplicated four times** (four Codes, four field sets) to run in four areas, and every change to its data-collection fields must be replicated four times. Same for the trim shops.
- Route-step → terminal resolution has no stable key. A part's route is a list of steps → templates whose Codes are frequently **part-specific** (`CNC-5G0`, `DC-5G0`, `ASSY-FRONT`, `TRIM-5G0`), so a terminal cannot look at a route and identify "the machining-in step" by Code or by Area (machining-in and machining-out share the Machining area).

**The fix (agreed in brainstorming):** decouple the operation *definition* from the *area*. An operation template becomes a reusable "what/how" (operation + data-collection fields), classified by a normalized **operation role** (`OperationType`) that the terminal binds to and the route-step resolver matches on. The area an operation runs in is supplied by the executing terminal at runtime, not baked into the template.

This single change:
1. Lets one die-cast template serve all four die-cast areas (kills the 4× duplication).
2. Gives terminals a stable role to resolve the right template for a scanned LOT — including disambiguating machining-**in** vs machining-**out** (same Area, different role).
3. Preserves full route flexibility — routes still freely compose steps; only the join key changes from Area to role.
4. Restores the "operation templates are reusable across products" claim the FDS already makes (FDS-03-012), extending it across areas.

---

## 2. Scope & non-goals

**In scope (Spec 1):**
- New `Parts.OperationType` role table + `Parts.OperationCategory` grouping table (see §4 D1).
- `Parts.OperationTemplate`: drop `AreaLocationId`, add `OperationTypeId`.
- Migrate the 5 seed operation-template files + backfill existing rows.
- Rewrite the 6 affected stored procs, 4 Named Queries, 1 entity script, 2 Config-Tool views.
- FDS + Data Model doc amendments.

**Explicitly NOT in scope (Spec 2 or later):**
- The machining/assembly plant-floor workflows (FIFO selection, sublot split, assembly-out consumption, inventory panel). Spec 2.
- The terminal-view → `OperationType` binding mechanism (which default view / tab focus maps to which role). Designed and built in Spec 2; Spec 1 only creates the role table it will bind to.
- Any change to defect-code / downtime-reason area filtering **behavior** (see §7 — no live code coupling exists; only FDS prose changes).
- Route "no runtime collapse" — that is a Spec 2 configuration standard, not a schema change.

---

## 3. Configuration/behavior vs Development — reading guide

Per the explicit ask, every deliverable below is tagged:

- **[CONFIG]** — a configuration / seed-data / behavior-standard change. No schema or code logic; changes what data or convention we load, or how the plant is configured. Can be done by an engineer editing seed/config, no build/test cycle for *logic*.
- **[DEV]** — an actual development requirement: schema DDL, stored-proc logic, Named Query, entity script, or Perspective view code that must be written, reviewed, and tested.

A consolidated tag matrix is in §11.

---

## 4. Design

### 4.1 New classification tables

**`Parts.OperationCategory`** — small grouping code table (Config-Tool display + product reuse).

| Column | Type | Constraints |
|---|---|---|
| Id | BIGINT | IDENTITY PK |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE |
| Name | NVARCHAR(100) | NOT NULL |
| Description | NVARCHAR(500) | NULL |
| CreatedAt | DATETIME2(3) | NOT NULL DEFAULT GETUTCDATETIME() |
| DeprecatedAt | DATETIME2(3) | NULL |

Seed (3 rows): `DieCast` / "Die Cast", `Trim` / "Trim", `MachiningAssembly` / "Machining & Assembly".

**`Parts.OperationType`** — the operation **role**; what a terminal binds to and the route-step resolver matches on.

| Column | Type | Constraints |
|---|---|---|
| Id | BIGINT | IDENTITY PK |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE |
| Name | NVARCHAR(100) | NOT NULL |
| OperationCategoryId | BIGINT | NOT NULL, FK → Parts.OperationCategory.Id |
| Description | NVARCHAR(500) | NULL |
| CreatedAt | DATETIME2(3) | NOT NULL DEFAULT GETUTCDATETIME() |
| DeprecatedAt | DATETIME2(3) | NULL |

Seed (8 rows):

| Code | Name | Category |
|---|---|---|
| `DieCast` | Die Cast | Die Cast |
| `TrimIn` | Trim In | Trim |
| `TrimOut` | Trim Out | Trim |
| `MachiningIn` | Machining In | Machining & Assembly |
| `MachiningOut` | Machining Out | Machining & Assembly |
| `AssemblyIn` | Assembly In | Machining & Assembly |
| `AssemblyOut` | Assembly Out | Machining & Assembly |
| `CNC` | CNC | Machining & Assembly |

Both tables are **read-only in this customer's deployment** (seeded, no CRUD UI). See D1/D2.

> **Decision point D1 — Category as a table vs a column.** In brainstorming we agreed to fold Category as a *column on `OperationType`*. On grounding, the house convention (CLAUDE.md § SQL design: "All enum/status columns code-table backed with FK — no magic integers, no free-text") argues for a normalized `OperationCategory` table, which *also* cleanly satisfies the "Category CRUDable for product reuse" goal you raised. This spec is written for the **normalized table** (recommended). If you'd rather keep it a plain `NVARCHAR Category` column on `OperationType`, say so and I'll collapse it — it's a one-section edit. **[CONFIG decision]**

> **Decision point D2 — CRUDability.** For MPP: both tables ship **fixed-seed, no CRUD UI** (roles are code-coupled to terminal views; categories are the 3 plant process families). For product reuse across future customers, `OperationCategory` is the natural CRUD candidate later — deferred (YAGNI) until a customer needs it. Confirm fixed-seed is right for MPP. **[CONFIG decision]**

### 4.2 `Parts.OperationTemplate` change

- **DROP** `AreaLocationId BIGINT NOT NULL FK → Location.Location(Id)` and its index `IX_OperationTemplate_AreaLocationId`.
- **ADD** `OperationTypeId BIGINT NOT NULL FK → Parts.OperationType(Id)` + supporting index `IX_OperationTemplate_OperationTypeId`.
- `UNIQUE(Code, VersionNumber)` unchanged. `RequiresSubLotSplit` unchanged (now correlates naturally with `OperationTypeId = MachiningOut`; no schema change, worth a note in the column description).

Nothing else on the template changes. `RouteStep`, `Workorder.ProductionEvent`, and `Quality.QualitySpec` FK the template's **Id**, not its area — **unaffected**.

### 4.3 Terminal → role binding (forward reference only)

The terminal/operator-view → `OperationType` binding is **designed and built in Spec 2**. Spec 1 only guarantees the stable role exists to bind to. Recorded here so the intent is captured: a machining-in view resolves a scanned LOT's fields by finding the route step whose `template.OperationTypeId = MachiningIn`; `Workorder.ProductionEvent` already carries `OperationTemplateId`, so completion history needs no new column.

---

## 5. Data-model & migration plan

### 5.1 Versioned migration (new) — **[DEV]**

Add a new versioned migration (next free number — repo is at ~`0029`; confirm at build, likely `0030`). Single transactional migration:

1. `CREATE TABLE Parts.OperationCategory` + seed 3 rows.
2. `CREATE TABLE Parts.OperationType` (FK → OperationCategory) + seed 8 rows.
3. `ALTER TABLE Parts.OperationTemplate ADD OperationTypeId BIGINT NULL` (nullable first).
4. **Backfill** existing rows (see §5.3 map). Guard: after backfill, `RAISERROR` if any `OperationTypeId IS NULL` remains, so an unmapped Code fails loudly rather than silently blocking the NOT-NULL step.
5. `ALTER COLUMN OperationTypeId … NOT NULL`; add FK + `IX_OperationTemplate_OperationTypeId`.
6. Drop the `AreaLocationId` FK constraint, drop `IX_OperationTemplate_AreaLocationId`, `DROP COLUMN AreaLocationId`.
7. Audit seed: add `Audit.LogEntityType` rows for `OperationType` and `OperationCategory` if they are to be audited (only needed if ever CRUDable — for fixed-seed, optional; include for forward-compat).

We do **not** edit the original `0006_routes_operations_eligibility.sql` (immutable once applied); the new migration supersedes its column.

### 5.2 Seed files — **[DEV]** (mechanical) + **[CONFIG]** (the mapping values)

Update the four seed files to insert `OperationTypeId` (resolved by `OperationType.Code`) instead of `AreaLocationId` (resolved by `Location.Code`):

- `sql/seeds/020_seed_items.sql` (DC-5G0, TRIM-5G0, CNC-5G0, ASSY-FRONT)
- `sql/seeds/022_seed_die_cast_operation_template.sql` (DieCastShot)
- `sql/seeds/024_seed_trim_operation_templates.sql` (TrimIn, TrimOut)
- `sql/seeds/026_seed_machining_operation_templates.sql` (MachiningIn, MachiningOut)

The *rewrite* is [DEV]; *which role each part-specific template maps to* is a [CONFIG] decision (§5.3, D3).

### 5.3 Backfill / seed mapping — **[CONFIG] — needs confirmation (D3)**

Generic templates map unambiguously by Code. The **part-specific** templates (named for 5G0) need a role assignment — proposed, please confirm:

| Existing template (Code) | Current Area | → Proposed `OperationType` |
|---|---|---|
| `DieCastShot` | DC1 | `DieCast` |
| `DC-5G0` | DC1 | `DieCast` |
| `TrimIn` | TRIM1 | `TrimIn` |
| `TrimOut` | TRIM1 | `TrimOut` |
| `TRIM-5G0` | TRIM1 | `TrimOut` ⚠️ confirm |
| `MachiningIn` | MA1 | `MachiningIn` |
| `MachiningOut` | MA1 | `MachiningOut` |
| `CNC-5G0` | MA1 | `CNC` ⚠️ confirm |
| `ASSY-FRONT` | MA1 | `AssemblyOut` ⚠️ confirm |

> **Decision point D3.** The three ⚠️ rows are best-guesses from the names. If `TRIM-5G0` is really a whole-trim (not specifically the OUT step), or `CNC-5G0`/`ASSY-FRONT` should map differently, correct them. Everything else is deterministic.

### 5.4 Data Model doc — **[DEV-doc]**

Edit `MPP_MES_DATA_MODEL.md`:
- Add `### Parts.OperationCategory` and `### Parts.OperationType` sections in §2 (Parts), adjacent to `OperationTemplate`.
- Amend `Parts.OperationTemplate` (line ~395): drop `AreaLocationId` row, add `OperationTypeId` row; note `RequiresSubLotSplit` now correlates to `OperationTypeId = MachiningOut`.
- Add a Revision History row at top (line 13); bump header version (line 3) + table count (line 4).

---

## 6. Stored-proc changes — **[DEV]**

Repeatable (`R__`) procs — re-run on deploy. All six schema-qualify and follow the status-row / JDBC conventions already in place.

| Proc | Change |
|---|---|
| `Parts.OperationTemplate_Create` | Replace `@AreaLocationId` param with `@OperationTypeId`; validate it exists + is non-deprecated in `Parts.OperationType`; write to new column; update JSON audit params to resolved `{Id, Code, Name}` OperationType sub-object. |
| `Parts.OperationTemplate_Update` | Same param swap + validation + old/new audit capture on `OperationTypeId`. |
| `Parts.OperationTemplate_Get` | Drop `AreaLocationId` + joined `AreaName` from SELECT; add `OperationTypeId` + joined `OperationType.Code/Name` + `OperationCategory.Code/Name`. |
| `Parts.OperationTemplate_List` | Replace `@AreaLocationId` filter with `@OperationTypeId` (and/or `@OperationCategoryId`) optional filter; join OperationType/Category for grouping; return `OperationTypeName` + `CategoryName`. |
| `Parts.OperationTemplate_CreateNewVersion` | Clone `OperationTypeId` instead of `AreaLocationId`. |
| `Parts.RouteStep_ListByRoute` | Replace the derived `ot.AreaLocationId AS OperationAreaLocationId` with `ot.OperationTypeId` + resolved `OperationTypeCode/Name` + `CategoryName` (consumer/display only). |

The dedicated area-filter proc/NQ pair (`OperationTemplate_ListByArea`) is **retired** (replaced by the `@OperationTypeId`/`@OperationCategoryId` filter on `_List`) — or renamed `_ListByType`. Decide at build; recommend fold into `_List`.

---

## 7. Defect-code / downtime-reason filtering — **[CONFIG]/[DEV-doc] only, no code change**

The FDS prose (FDS-02-001, FDS-02-003, FDS-03-009) says operation templates "reference Areas for defect/downtime filtering." **Grounding found no live code path that filters defect or downtime codes off `OperationTemplate.AreaLocationId`** — `Quality.DefectCode` and `Oee.DowntimeReasonCode` carry their **own** `AreaLocationId`, and plant-floor screens filter by the terminal's cell/zone area, not the template's. So:

- **No code change** is required for defect/downtime filtering when we drop `OperationTemplate.AreaLocationId`.
- The FDS prose must be **reworded** (doc-only, §8) to say the *screen's* area (terminal runtime location) drives defect/downtime filtering, not the template.
- Any *future* "filter defects by operation" feature would key off the terminal's runtime area (available in `session.custom.terminal.zoneLocationId`) — noted for Spec 2, not built here.

---

## 8. FDS amendments — **[DEV-doc]**

FDS is v1.4; edit in place + add a Revision History row (lines 33–41). Requirements to amend:

- **FDS-03-012** (Operation Template Design, §3.4) — replace the `AreaLocationId` field line with `OperationTypeId` (+ its role/category meaning); reaffirm cross-area reuse.
- **FDS-03-009** (§3.3) — reword "operation template, which defines the area" → the operation template defines the **operation role** + data-collection requirements; the **area is the terminal's runtime location**.
- **FDS-02-001 note** & **FDS-02-003** (§2.2) — reword "operation templates reference Areas / for filtering" → screens filter defect/downtime codes by the **terminal's area**, not the template.
- **FDS-05-025** (Post-Sort / sort-inspection terminator) — **align, don't collide.** Note that the sort/inspection-terminator marker is orthogonal to `OperationType` (it's a route-step property); no change now, but flag so the two role-ish concepts stay distinct.
- Data-flow table (§1.4) — add `Parts.OperationType` / `OperationCategory` to the Plan-layer chain note.

No OI is opened or closed by Spec 1. (OI-32 and the FIFO/split reconciliations belong to Spec 2.)

---

## 9. Ignition changes — **[DEV]**

**Named Queries (Core)** — 4 to edit, 1 to retire/rename:
- `parts/OperationTemplate_Create`, `_Update` — swap `:areaLocationId` → `:operationTypeId`.
- `parts/OperationTemplate_List` — swap filter param → `:operationTypeId` (+ optional `:operationCategoryId`).
- `parts/OperationTemplate_Get` — result-shape change only (no param).
- `parts/OperationTemplate_ListByArea` — retire or rename `_ListByType`.
- **New:** `parts/OperationType_ListForDropdown` (+ optionally `OperationCategory_List`) feeding the editor dropdown/grouping.

**Entity script** — `BlueRidge.Parts.OperationTemplate` (`code.py`):
- Replace `getAreasForDropdown()` → `getOperationTypesForDropdown()` (returns `[{label, value}]` grouped/labelled by category).
- `_toRailRow()` / `search()` — group by `CategoryName` instead of `AreaName`; the rail/list groups under the 3 categories.
- `add()` / `update()` — pass `operationTypeId` instead of `areaLocationId`.
- No `system.db.*` direct calls; route through the existing `BlueRidge.Common.*` DB helpers already used here.

**Config-Tool Perspective views** (MPP_Config) — 2:
- `BlueRidge/Views/Parts/OperationTemplates/view.json` — the list groups/filters by **Category** (via the type join) instead of Area; the persistent filter custom prop `filter.areaLocationId` → `filter.operationTypeId` (or category). Pre-declare the new bound custom props with shaped defaults (per the pre-declare convention).
- `BlueRidge/Components/Popups/NewOperationTemplate/view.json` — the Area dropdown becomes an **OperationType** dropdown bound to `editDraft.OperationTypeId`; seed `editDraft` with the full shape.

Both views are **existing** → edit in **Designer**, not file-edit (view-edit boundary). Run `scan.ps1` after any new NQ/entity-script — that is sufficient, **including for the brand-new `OperationType_ListForDropdown` Core NQ** (inherited visibility registers on scan; **no gateway restart**).

---

## 10. Testing — **[DEV]**

- Rework `sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql`: replace `@AreaLocationId` assertions with `@OperationTypeId` (create/update happy-path; reject NULL; reject non-existent/deprecated type; CreateNewVersion clones the type).
- Fix fixture in `060_OperationTemplateField_SaveAll.sql` (insert a valid `OperationTypeId`).
- New assertions: `OperationType`/`OperationCategory` seed presence + FK integrity; `_List`/`_Get` return the type+category; backfill guard raises on unmapped Code.
- Full suite must stay green (`Run-Tests`).

---

## 11. Config vs Dev — consolidated matrix

| # | Deliverable | Tag |
|---|---|---|
| 1 | Decide Category = table vs column (D1) | **[CONFIG]** decision |
| 2 | Decide fixed-seed vs CRUDable (D2) | **[CONFIG]** decision |
| 3 | Confirm the 3 ⚠️ template→role mappings (D3) | **[CONFIG]** decision |
| 4 | `OperationCategory` + `OperationType` tables + seeds | **[DEV]** (schema) + **[CONFIG]** (seed values) |
| 5 | `OperationTemplate` drop `AreaLocationId` / add `OperationTypeId` (versioned migration + backfill) | **[DEV]** |
| 6 | Reseed the 4 seed files to `OperationTypeId` | **[DEV]** (mechanics), **[CONFIG]** (values) |
| 7 | 6 stored procs rewritten | **[DEV]** |
| 8 | 4 NQs edited + 1 retired + 1 new | **[DEV]** |
| 9 | Entity script `OperationTemplate/code.py` | **[DEV]** |
| 10 | 2 Config-Tool views (Designer) | **[DEV]** |
| 11 | Defect/downtime filtering | **[CONFIG]/doc only** — no code change (§7) |
| 12 | FDS + Data Model doc edits | **[DEV-doc]** |
| 13 | SQL tests reworked | **[DEV]** |

---

## 12. Risks & notes

- **NOT-NULL migration:** `AreaLocationId` is `NOT NULL`; the add→backfill→NOT-NULL→drop ordering (§5.1) with the loud backfill guard avoids a half-migrated column. On a fresh `Reset-DevDatabase`, the migration runs against an empty `OperationTemplate` (backfill no-ops), then the updated seeds insert `OperationTypeId` directly — both paths verified in the plan.
- **Designer view-edit boundary:** the two Config-Tool views are existing → Designer edits, expect "Files vs Gateway" reconciliation; the diffs are small structural swaps (Area→Type dropdown/filter).
- **`OperationTemplate_ListByArea` retirement:** confirm no other caller (grounding found only the Config-Tool view); safe to fold into `_List`.
- **Alignment with Spec 2:** the `OperationType` codes here are the exact roles Spec 2's terminal views bind to — keep them stable once seeded.

---

## 13. Open decisions for Jacques

1. **D1** — `OperationCategory` as a normalized table (recommended) vs a plain column on `OperationType`.
2. **D2** — fixed-seed both tables for MPP (recommended), defer CRUD to product-reuse.
3. **D3** — confirm the three ⚠️ template→role mappings (`TRIM-5G0`, `CNC-5G0`, `ASSY-FRONT`).
