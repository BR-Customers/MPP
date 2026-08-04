# Defect codes scoped by OperationCategory (not physical Area)

**Date:** 2026-08-04
**Author:** Blue Ridge Automation
**Status:** Approved — ready for implementation plan
**Relates to:** FDS-08-016, FDS-08-017 (defect-code area filtering, previously deferred)

## Problem

`Quality.DefectCode.AreaLocationId` is a `NOT NULL` FK to a single `Location.Location` row.
"Die Cast" is four separate Area locations (`DC1`–`DC4`), so a code authored against `DC1`
is invisible at `DC2`/`DC3`/`DC4`. The seed file (`030_seed_defect_codes.sql`) already flags
this as a known defect (FDS-08-017: *"die-cast codes attach to DC1 only, so DC2-4 will not see
them once area-filtering is wired"*).

Two concrete pains:

1. **Authoring** — the config-tool `DefectCodeEditor` forces the user to pick one arbitrary
   die-cast Area for a code that logically applies to *all* die cast.
2. **Runtime** — the plant-floor `RejectPanel` dropdown currently passes **no** area filter at
   all (`getForDropdown` with no argument), so every reject screen lists every code in the
   plant. The Area FK is doing no useful runtime filtering today; it only forces an authoring
   decision.

## Key insight — the abstraction already exists

The rest of the shop floor already moved off physical-area scoping:

- Migrations `0032`/`0033` dropped `Parts.OperationTemplate.AreaLocationId` and replaced it with
  `OperationTypeId`. Operation templates resolve by **process role**, not location.
- Migration `0032` created **`Parts.OperationCategory`** with exactly three rows:
  `DieCast`, `Trim`, `MachiningAssembly`. Every `Parts.OperationType` (DieCast, TrimIn/Out,
  MachiningIn/Out, AssemblyIn/Out, CNC) already maps up to one of these categories via
  `OperationType.OperationCategoryId`.
- The reject flow already carries process context: `Workorder.RejectEvent_Record` takes
  `@OperationTypeCode` today (it drives the additive-vs-subtractive scrap rule via
  `OperationType.ScrapIsAdditive`). The die-cast `RejectPanel.submitReject()` already sets
  `draft["operationTypeCode"] = "DieCast"`.

Defect codes are the **last thing still pinned to a single physical Area** while the process
taxonomy that spans DC1–4 is already built and already threaded through the reject screen.
This change is therefore a **swap** (`AreaLocationId → OperationCategoryId`), not net-new modeling.

## Decisions (locked)

1. **Scope grain = `OperationCategory` (3 values)**, not `OperationType` (8) and not many-to-many
   Areas. A die-cast code shows at every die-cast terminal regardless of In/Out. Matches the
   existing table and how MPP groups defects today; one selection per code, no In/Out duplication.
2. **`OperationCategoryId` is nullable; `NULL` = plant-wide** (applies everywhere, shows on every
   reject screen). The ~15 non-process codes (shipping, labels, ISO audit, inventory balance,
   missed shipment — today dumped on the site-level `MPP-MAD` location) backfill to `NULL`.
   Genuinely universal defects (e.g. Mixed Parts, Test Part) can also be made plant-wide by choice.
   MPP can reclassify later (FDS-08-017 stays the refinement vehicle).
3. **Requesting a specific category always also returns plant-wide codes** — in both the
   plant-floor dropdown and the config-tool filtered list. Plant-wide codes are relevant everywhere.
4. **Single versioned migration** (add + backfill + drop), not expand/contract. Every consumer is
   in-repo and updated in the same commit; dev resets rebuild from scratch.

## Change surface

### 1. Schema — `0047` versioned migration

`Quality.DefectCode`:

- **Add** `OperationCategoryId BIGINT NULL REFERENCES Parts.OperationCategory(Id)`.
- **Add** `IX_DefectCode_OperationCategoryId`.
- **Backfill** from `AreaLocationId` by walking each row's Area to its process family:
  - `DC1`/`DC2`/`DC3`/`DC4` → `DieCast`
  - `TRIM1`/`TRIM2` → `Trim`
  - `MA1`/`MA2` → `MachiningAssembly`
  - `MPP-MAD` (site) / anything else → `NULL` (plant-wide)

  Backfill is guarded/idempotent. On a fresh reset `DefectCode` is empty when this migration
  runs (seed `030` runs later), so the backfill is a no-op there and the rewritten seed inserts
  categories directly. On an in-place dev DB, the backfill maps existing rows before the drop.
- **Drop** `AreaLocationId`: resolve the FK name dynamically and drop it, drop
  `IX_DefectCode_AreaLocationId`, drop the column. (Follows the `0033` dynamic-FK-drop pattern.)
- Record in `dbo.SchemaVersion`.

Ordering note: versioned migrations run before repeatable procs re-apply in a reset, so the
`R__Quality_DefectCode_*` procs recreate against the new schema. The repeatable procs and this
migration land in the same commit.

### 2. Stored procs (repeatable) + Core NQs

- **`Quality.DefectCode_Create`** / **`_Update`**: `@AreaLocationId` → `@OperationCategoryId BIGINT = NULL`.
  Audit `OldValue`/`NewValue` JSON swap the resolved-name Area sub-object for a Category one
  (`{Id, Code, Name}`); `NULL` rendered as `"Plant-wide"` in the Description. Description follows
  the `<SUBJECT> · <CATEGORY?> · <ACTION>` convention.
- **`Quality.DefectCode_Get`**: same params; SELECT returns `OperationCategoryId` + `CategoryName`
  (LEFT JOIN `Parts.OperationCategory`) instead of `AreaLocationId`/`AreaName`.
- **`Quality.DefectCode_List`** — the plant-wide + type-resolution logic lives here (SQL, not Python):
  - `@OperationCategoryId BIGINT = NULL` — config-tool path (NULL = show all).
  - `@OperationTypeCode NVARCHAR(20) = NULL` — plant-floor path; resolved type→category via join
    to `Parts.OperationType`.
  - Effective category = `@OperationCategoryId` if given, else the category resolved from
    `@OperationTypeCode`, else none.
  - Filter: with an effective category, `WHERE dc.OperationCategoryId = @cat OR dc.OperationCategoryId IS NULL`
    (category **plus** plant-wide). With no effective category, return all (respecting
    `@IncludeDeprecated`).
  - `ORDER BY CategoryName, Code` (plant-wide is its own group).
- Update the four Core NQ `query.sql` files (`DefectCode_Create`, `_Update`, `_List`, `_Get`)
  to the new parameter names. `_List` gains `:operationTypeCode`.

### 3. Seed + entity script

- **`sql/seeds/030_seed_defect_codes.sql`**: replace the `@DC1/@MA1/@TRM/@SIT` location lookups
  with the three `Parts.OperationCategory` ids; the `MPP-MAD`/logistics rows insert `NULL`
  (plant-wide). Remove the FDS-08-017 "DC1 only" caveat comment. ASCII-only, idempotent on
  `UQ_DefectCode_Code` (insert-where-not-exists) — unchanged pattern.
- **`BlueRidge.Quality.DefectCode` (Core entity script)**: rename `getAll`/`getForDropdown`
  parameter `areaLocationId` → `operationCategoryId`; add `getForDropdown(operationTypeCode=None)`
  passthrough to `DefectCode_List`'s `@OperationTypeCode`. Row mapping returns
  `operationCategoryId` + `categoryName` instead of `areaLocationId`/`areaName`. **No domain logic
  added** — the type→category map stays in SQL (honors the "no business logic in Python" rule).

### 4. UI — existing views, done in Designer

Per the Ignition view-edit boundary rule, edits to existing `view.json` files are Designer work,
not file edits. §1–3 above are file edits (SQL / NQ / entity script / seed); the view changes are
Designer:

- **`DefectCodeEditor`** (MPP_Config): the Area dropdown becomes an "Applies to" dropdown =
  the 3 categories + a **"Plant-wide (all areas)"** option mapping to `NULL`.
- **`DefectCodeRow`** and the **`DefectCodes`** list view (MPP_Config): the Area column and the
  Area filter dropdown show Category / "Plant-wide".
- **`RejectPanel`** (MPP plant floor): the dropdown binding
  `runScript("BlueRidge.Quality.DefectCode.getForDropdown", 0)` gains the argument `"DieCast"`
  (the panel already declares that operation on submit). The die-cast reject screen then shows
  die-cast **+ plant-wide** codes only, instead of every code in the plant as it does today.

## Out of scope / deferred

- Reject-entry surfaces for trim/machining/assembly do not exist yet; only the die-cast
  `RejectPanel` consumes defect codes at runtime today, so only it needs the `"DieCast"` argument.
  When those surfaces are built they pass their own operation-type code — no further schema change.
- Finer per-line or per-machine defect targeting. Not requested; category grain is the decision.
- MPP reclassification of the plant-wide bucket into real categories — remains an FDS-08-017
  follow-up, unblocked by the nullable design.

## Verification

- Reset a throwaway `MPP_MES_Test`, apply migrations + seed, assert:
  - `Quality.DefectCode` has no `AreaLocationId` column; has `OperationCategoryId` (nullable) + index.
  - Die-cast codes (100–139, 191, …) resolve to the `DieCast` category; machining codes to
    `MachiningAssembly`; trim codes to `Trim`; logistics codes (201–205, 212, 225, 247–256) are `NULL`.
  - `DefectCode_List @OperationTypeCode = 'DieCast'` returns die-cast **+ plant-wide** codes and
    excludes trim/machining-only codes.
  - `DefectCode_List` with no args returns all active codes.
  - `DefectCode_Create` / `_Update` round-trip a category and a plant-wide (`NULL`) code; audit
    rows carry the resolved-name Category JSON.
- Manual: config-tool editor shows the 3 categories + Plant-wide; die-cast `RejectPanel` dropdown
  no longer lists trim/machining-only codes.
