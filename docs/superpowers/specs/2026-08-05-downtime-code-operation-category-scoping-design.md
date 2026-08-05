# Downtime codes scoped by OperationCategory (not physical Area)

**Date:** 2026-08-05
**Author:** Blue Ridge Automation
**Status:** Approved — ready for implementation plan
**Relates to:** FAT #3. Direct mirror of the defect-code refactor
(`docs/superpowers/specs/2026-08-04-defect-code-operation-category-scoping-design.md`).

## Problem

`Oee.DowntimeReasonCode.AreaLocationId` is a FK to a single physical `Location` Area (identical to
the pre-refactor `Quality.DefectCode`). A downtime reason authored against `DC1` is invisible at
`DC2`/`DC3`/`DC4`; codes are organized by area when they should be organized by **process**
(Die Cast / Trim / Machining & Assembly), so any area in that category finds them (FAT #3).

The defect-code refactor (#1, shipped) already solved this exact shape by scoping to
`Parts.OperationCategory`. This applies the same recipe to downtime codes.

## Decisions (inherited from #1 — locked)

1. **Scope grain = `Parts.OperationCategory`** (DieCast / Trim / MachiningAssembly), not physical Area.
2. **`OperationCategoryId` nullable; `NULL` = plant-wide** (shows on every downtime entry surface).
   Non-process / site-level codes (Break, shipping, etc.) backfill to `NULL`.
3. **Requesting a category also returns plant-wide codes** (plant floor and config tool).
4. **Single versioned migration** (add + backfill + drop), all consumers in-repo and updated together.
5. The existing `DowntimeReasonType` and `DowntimeSourceCode` dimensions are **untouched** — this
   change only replaces the *Area* dimension with *OperationCategory*.

## Change surface

### 1. Schema — next versioned migration (`0051`, confirm free at plan time)
`Oee.DowntimeReasonCode`:
- Add `OperationCategoryId BIGINT NULL REFERENCES Parts.OperationCategory(Id)` + index.
- Backfill from `AreaLocationId` by process family: `DC%→DieCast`, `TRIM%→Trim`, `MA%→MachiningAssembly`,
  else `NULL` (plant-wide). Guarded/idempotent; no-op on a fresh reset (seed inserts categories directly).
- Drop `AreaLocationId` (FK resolved dynamically + index + column), following the `0033`/`0048` pattern.

### 2. Procs (repeatable) + Core NQs
- **`DowntimeReasonCode_Create` / `_Update`**: `@AreaLocationId → @OperationCategoryId BIGINT = NULL`.
  FK-check only when non-null. Audit `OldValue`/`NewValue` JSON swap the resolved Area sub-object for
  a Category one (`{Id, Code, Name}`), `NULL` rendered "Plant-wide". **Include the `IF @Fields IS NULL
  OR @Fields = N''` no-change guard from the start** (the `STUFF`-on-empty→NULL Description bug hit in
  #1 / SessionPolicy).
- **`DowntimeReasonCode_Get`**: return `OperationCategoryId` + `CategoryName` (LEFT JOIN
  `Parts.OperationCategory`) instead of Area; keep `DowntimeReasonTypeId`/`ReasonTypeName`,
  `DowntimeSourceCodeId`/`SourceCodeName`.
- **`DowntimeReasonCode_List`**: replace `@AreaLocationId` with `@OperationCategoryId BIGINT = NULL`
  (config tool) **and** add `@OperationTypeCode NVARCHAR(20) = NULL` (plant floor, resolved to
  category via `Parts.OperationType`). Effective-category filter = `dc.OperationCategoryId = @cat OR
  dc.OperationCategoryId IS NULL`; no filter → all. Keep the existing `@DowntimeReasonTypeId` filter.
  `ORDER BY` plant-wide-last, CategoryName, Code.
- Update the four Core `oee/DowntimeReasonCode_*` NQ `query.sql` + `resource.json` param sets
  (`operationCategoryId`, `operationTypeCode`).

### 3. Seed + entity script
- Rewrite the downtime-code seed's Area lookups → the three `Parts.OperationCategory` ids; site/Break
  rows → `NULL` (plant-wide). ASCII-only, idempotent, byte-scan before applying.
- **`BlueRidge.Oee.DowntimeReasonCode` entity script**: `getAll`/`search` param `areaLocationId →
  operationCategoryId`; add `getForDropdown(operationTypeCode=None)` (plant-floor, type-resolved) and
  `getCategoryOptions(nullLabel)` (reuse `BlueRidge.Parts.OperationTemplate.getOperationCategoriesForDropdown`);
  row maps expose `category` + `operationCategoryId`; `add`/`update` keyed on `OperationCategoryId`.
  No domain logic in Python — the type→category map stays in SQL.

### 4. Views (Designer — existing view.json)
- **`DowntimeCodeEditor`** (MPP_Config): Area dropdown → "Applies to" dropdown = 3 categories +
  "Plant-wide (all areas)" (value null); value bidi to `editDraft.meta.OperationCategoryId`; drop the
  Area-required save guard (null = plant-wide is valid); load reads `OperationCategoryId`/`CategoryName`.
- **`DowntimeCodeRow`** + **`DowntimeCodes` list** (MPP_Config): Area column/filter → Category
  (+ "All areas" filter option), `filter.areaLocationId → operationCategoryId`, options via
  `getCategoryOptions`.
- **Plant-floor downtime entry** (`Components/Popups/DowntimeManager` and/or `Views/ShopFloor/
  DowntimeEntry`): filter reason codes by the terminal's category — call `getForDropdown` with the
  terminal's operation-type code (as the die-cast reject panel does with `"DieCast"`), so any area in
  a category surfaces its codes. Confirm the exact operation-type code per downtime surface at plan time.

### 5. Tests
Mirror the defect-code crud test for `Oee.DowntimeReasonCode`: create happy + duplicate + invalid
category; update happy + deprecated-reject + **no-change succeeds** (NULL-Description guard); Get
returns category; List by `@OperationTypeCode` returns category **+ plant-wide**, excludes other
categories; List with no filter returns all; audit ConfigLog carries resolved Category JSON.

## Out of scope
- Reason-type / source-code dimensions (unchanged).
- Any downtime *recording* logic (`DowntimeEvent_*` procs) — only the reason-**code** scoping changes.
- Non-Trim/DieCast/MachiningAssembly categories — the nullable/plant-wide design absorbs everything
  else, as in #1.

## Verification
Reset a throwaway DB, apply migrations + seed, assert: `DowntimeReasonCode` has no `AreaLocationId`,
has nullable `OperationCategoryId` + index; die-cast codes → DieCast, trim → Trim, machining → MachiningAssembly,
Break/site → NULL; `DowntimeReasonCode_List @OperationTypeCode='DieCast'` returns die-cast + plant-wide only;
config-tool editor shows the 3 categories + Plant-wide; plant-floor downtime entry lists the terminal
category's codes + plant-wide.
