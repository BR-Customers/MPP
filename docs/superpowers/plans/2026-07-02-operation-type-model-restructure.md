# Operation-Type Model Restructure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decouple `Parts.OperationTemplate` from a specific Area by dropping `AreaLocationId` and adding `OperationTypeId` (FK to a new `Parts.OperationType` role table, grouped by a new `Parts.OperationCategory` table), so one operation template is reusable across all four die-cast areas / two trim shops and terminals resolve templates by operation role.

**Architecture:** Expand → migrate → contract. An **expand** versioned migration adds the two new tables + seeds, adds `OperationTemplate.OperationTypeId` (nullable), and relaxes `AreaLocationId` to nullable so both columns coexist during the transition. Consumers (seeds, 6 procs, NQs, entity script) migrate to `OperationTypeId` one task at a time, each leaving the SQL suite green. A final **contract** migration makes `OperationTypeId NOT NULL` and drops `AreaLocationId`. Config-Tool views + docs land last.

**Tech Stack:** SQL Server 2022 (versioned + repeatable `R__` migrations, file-based SQL test suite run via `Reset-DevDatabase` + `Run-Tests`), Ignition 8.3 (Core Named Queries + Jython entity scripts + Perspective views), governed by `sql_best_practices_mes.md` and `sql_version_control_guide.md`.

## Global Constraints

- **Branch:** `jacques/working`. Confirm `git branch --show-current` before committing. Stage explicit paths only (never `git add -A`/`-u`). Omit the `Co-Authored-By: Claude` commit trailer.
- **SQL conventions:** `UpperCamelCase` tables/columns; `BIGINT IDENTITY` surrogate `Id` PK; `BIGINT` FKs; `NVARCHAR` (never `VARCHAR`); `DATETIME2(3)`; timestamps stored UTC via `GETUTCDATETIME()`; all enum/status columns are code-table-backed FKs (no free-text, no magic ints); append-only events; `DeprecatedAt` soft deletes.
- **Seed strings ASCII-only** (em-dash/middle-dot become mojibake via sqlcmd codepage — byte-scan before applying).
- **Ignition JDBC (FDS-11-011):** procs SHALL NOT use `OUTPUT` params. Mutation procs end every exit path with `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;` (drop `@NewId` for Update). Read procs return one result set; empty set = not found. Status-row mutation NQs use `attributes.type: "Query"`.
- **Audit convention:** `Audit.ConfigLog.Description` shaped `<SUBJECT> · <CATEGORY?> · <ACTION>` via `Audit.ufn_MidDot()` + `Audit.ufn_TruncateActivity()`; `OldValue`/`NewValue` JSON carry resolved-name FK sub-objects (`OperationTypeId: {Id, Code, Name}`, not bare id).
- **Confirmed decisions (from spec review):** D1 — `OperationCategory` is a normalized table (not a column). D2 — both new tables ship fixed-seed, no CRUD UI. D3 — template→role backfill map is confirmed (see Task 1).
- **NQ topology:** all Named Queries live in **Core**; MPP/MPP_Config children have none. Run `scan.ps1` after any NQ/entity-script change; a brand-new Core NQ needs a gateway restart to register for inherited visibility.
- **View-edit boundary:** the two Config-Tool views are **existing** → edit in **Designer**, not by file-authoring.
- **Migration numbers:** shown here as `0030` (expand) / `0031` (contract). **Confirm the next free versioned number at build** (`ls sql/migrations/versioned/`) and renumber both if taken.

---

### Task 1: Expand migration — new tables, seeds, additive column

**Files:**
- Create: `sql/migrations/versioned/0030_operation_type_expand.sql`
- Create: `sql/tests/0009_Parts_Process/005_OperationType_seed.sql`

**Interfaces:**
- Produces: tables `Parts.OperationCategory(Id, Code, Name, Description, CreatedAt, DeprecatedAt)` and `Parts.OperationType(Id, Code, Name, OperationCategoryId, Description, CreatedAt, DeprecatedAt)`; column `Parts.OperationTemplate.OperationTypeId BIGINT NULL FK → Parts.OperationType(Id)`; `Parts.OperationTemplate.AreaLocationId` becomes **nullable**. `OperationType.Code` seed values: `DieCast, TrimIn, TrimOut, MachiningIn, MachiningOut, AssemblyIn, AssemblyOut, CNC`. `OperationCategory.Code`: `DieCast, Trim, MachiningAssembly`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0009_Parts_Process/005_OperationType_seed.sql` (follow the assertion style of the sibling tests in `sql/tests/0009_Parts_Process/`):

```sql
-- 005_OperationType_seed.sql — OperationCategory + OperationType tables seeded; OperationTemplate has OperationTypeId
SET NOCOUNT ON;

-- Categories: exactly 3 seeded
IF (SELECT COUNT(*) FROM Parts.OperationCategory WHERE DeprecatedAt IS NULL) <> 3
    RAISERROR('FAIL 005: expected 3 OperationCategory rows', 16, 1);

-- Types: exactly 8 seeded, each mapped to a category
IF (SELECT COUNT(*) FROM Parts.OperationType WHERE DeprecatedAt IS NULL) <> 8
    RAISERROR('FAIL 005: expected 8 OperationType rows', 16, 1);

IF EXISTS (SELECT 1 FROM Parts.OperationType ot
           LEFT JOIN Parts.OperationCategory oc ON oc.Id = ot.OperationCategoryId
           WHERE oc.Id IS NULL)
    RAISERROR('FAIL 005: OperationType with unresolved OperationCategoryId', 16, 1);

-- Spot-check a role→category mapping
IF NOT EXISTS (SELECT 1 FROM Parts.OperationType ot
               INNER JOIN Parts.OperationCategory oc ON oc.Id = ot.OperationCategoryId
               WHERE ot.Code = N'MachiningOut' AND oc.Code = N'MachiningAssembly')
    RAISERROR('FAIL 005: MachiningOut must map to MachiningAssembly category', 16, 1);

-- OperationTemplate carries the new FK column
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID(N'Parts.OperationTemplate') AND name = N'OperationTypeId')
    RAISERROR('FAIL 005: OperationTemplate.OperationTypeId missing', 16, 1);

PRINT 'PASS 005_OperationType_seed';
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `Reset-DevDatabase; Run-Tests` (PowerShell, from repo root per `sql_version_control_guide.md`).
Expected: `005_OperationType_seed` FAILS (`Invalid object name 'Parts.OperationCategory'`).

- [ ] **Step 3: Write the expand migration**

Create `sql/migrations/versioned/0030_operation_type_expand.sql`:

```sql
-- 0030_operation_type_expand.sql
-- Adds Parts.OperationCategory + Parts.OperationType; adds OperationTemplate.OperationTypeId (nullable);
-- relaxes OperationTemplate.AreaLocationId to nullable; backfills existing rows. CONTRACT (NOT NULL + drop
-- AreaLocationId) lands in 0031 after all consumers migrate. Idempotent-guarded.
SET XACT_ABORT ON;
BEGIN TRANSACTION;

-- 1. OperationCategory (read-only code table)
IF OBJECT_ID(N'Parts.OperationCategory') IS NULL
CREATE TABLE Parts.OperationCategory (
    Id            BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_OperationCategory PRIMARY KEY,
    Code          NVARCHAR(20)  NOT NULL CONSTRAINT UQ_OperationCategory_Code UNIQUE,
    Name          NVARCHAR(100) NOT NULL,
    Description   NVARCHAR(500) NULL,
    CreatedAt     DATETIME2(3)  NOT NULL CONSTRAINT DF_OperationCategory_CreatedAt DEFAULT GETUTCDATETIME(),
    DeprecatedAt  DATETIME2(3)  NULL
);

-- 2. OperationType (read-only role table)
IF OBJECT_ID(N'Parts.OperationType') IS NULL
CREATE TABLE Parts.OperationType (
    Id                  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_OperationType PRIMARY KEY,
    Code                NVARCHAR(20)  NOT NULL CONSTRAINT UQ_OperationType_Code UNIQUE,
    Name                NVARCHAR(100) NOT NULL,
    OperationCategoryId BIGINT        NOT NULL CONSTRAINT FK_OperationType_Category
                                        REFERENCES Parts.OperationCategory(Id),
    Description         NVARCHAR(500) NULL,
    CreatedAt           DATETIME2(3)  NOT NULL CONSTRAINT DF_OperationType_CreatedAt DEFAULT GETUTCDATETIME(),
    DeprecatedAt        DATETIME2(3)  NULL
);

-- 3. Seed categories
MERGE Parts.OperationCategory AS t
USING (VALUES
    (N'DieCast',            N'Die Cast'),
    (N'Trim',               N'Trim'),
    (N'MachiningAssembly',  N'Machining & Assembly')
) AS s(Code, Name) ON t.Code = s.Code
WHEN NOT MATCHED THEN INSERT (Code, Name) VALUES (s.Code, s.Name);

-- 4. Seed types (category resolved by Code)
MERGE Parts.OperationType AS t
USING (VALUES
    (N'DieCast',      N'Die Cast',      N'DieCast'),
    (N'TrimIn',       N'Trim In',       N'Trim'),
    (N'TrimOut',      N'Trim Out',      N'Trim'),
    (N'MachiningIn',  N'Machining In',  N'MachiningAssembly'),
    (N'MachiningOut', N'Machining Out', N'MachiningAssembly'),
    (N'AssemblyIn',   N'Assembly In',   N'MachiningAssembly'),
    (N'AssemblyOut',  N'Assembly Out',  N'MachiningAssembly'),
    (N'CNC',          N'CNC',           N'MachiningAssembly')
) AS s(Code, Name, CategoryCode) ON t.Code = s.Code
WHEN NOT MATCHED THEN INSERT (Code, Name, OperationCategoryId)
    VALUES (s.Code, s.Name, (SELECT Id FROM Parts.OperationCategory WHERE Code = s.CategoryCode));

-- 5. Add OperationTypeId (nullable during expand)
IF COL_LENGTH(N'Parts.OperationTemplate', N'OperationTypeId') IS NULL
BEGIN
    ALTER TABLE Parts.OperationTemplate ADD OperationTypeId BIGINT NULL
        CONSTRAINT FK_OperationTemplate_OperationType REFERENCES Parts.OperationType(Id);
END;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_OperationTemplate_OperationTypeId')
    CREATE INDEX IX_OperationTemplate_OperationTypeId ON Parts.OperationTemplate(OperationTypeId);

-- 6. Relax AreaLocationId to nullable so seeds/procs can stop supplying it during migration
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID(N'Parts.OperationTemplate') AND name = N'AreaLocationId' AND is_nullable = 0)
    ALTER TABLE Parts.OperationTemplate ALTER COLUMN AreaLocationId BIGINT NULL;

-- 7. Backfill existing rows (non-reset upgrades; no-op on a fresh reset where the table is empty).
--    Confirmed template->role map (spec D3).
UPDATE ot SET OperationTypeId = (SELECT Id FROM Parts.OperationType WHERE Code = m.TypeCode)
FROM Parts.OperationTemplate ot
INNER JOIN (VALUES
    (N'DieCastShot',  N'DieCast'),
    (N'DC-5G0',       N'DieCast'),
    (N'TrimIn',       N'TrimIn'),
    (N'TrimOut',      N'TrimOut'),
    (N'TRIM-5G0',     N'TrimOut'),
    (N'MachiningIn',  N'MachiningIn'),
    (N'MachiningOut', N'MachiningOut'),
    (N'CNC-5G0',      N'CNC'),
    (N'ASSY-FRONT',   N'AssemblyOut')
) AS m(TemplateCode, TypeCode) ON m.TemplateCode = ot.Code
WHERE ot.OperationTypeId IS NULL;

-- 8. Loud guard: any existing template left unmapped is a data error, fail the migration
IF EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE OperationTypeId IS NULL AND AreaLocationId IS NOT NULL)
    RAISERROR('0030: OperationTemplate rows exist with no OperationTypeId mapping — extend the backfill map.', 16, 1);

COMMIT TRANSACTION;
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `005_OperationType_seed` PASSES; full suite still green (no consumer changed yet — `AreaLocationId` still present, now nullable).

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0030_operation_type_expand.sql sql/tests/0009_Parts_Process/005_OperationType_seed.sql
git commit -m "feat(sql): expand migration for OperationType/OperationCategory + OperationTemplate.OperationTypeId"
```

---

### Task 2: Migrate seed files to OperationTypeId

**Files:**
- Modify: `sql/seeds/020_seed_items.sql` (DC-5G0, TRIM-5G0, CNC-5G0, ASSY-FRONT operation-template inserts)
- Modify: `sql/seeds/022_seed_die_cast_operation_template.sql` (DieCastShot)
- Modify: `sql/seeds/024_seed_trim_operation_templates.sql` (TrimIn, TrimOut)
- Modify: `sql/seeds/026_seed_machining_operation_templates.sql` (MachiningIn, MachiningOut)

**Interfaces:**
- Consumes: `Parts.OperationType.Code` (Task 1).
- Produces: seeded `OperationTemplate` rows populate `OperationTypeId` (not `AreaLocationId`).

- [ ] **Step 1: Update each seed insert**

In every operation-template `INSERT` across the four files, **remove the `AreaLocationId` column + its `(SELECT Id FROM Location.Location WHERE Code = ...)` value**, and **add `OperationTypeId` resolved by role Code**. Pattern — replace the area lookup:

```sql
-- BEFORE (example from 024_seed_trim_operation_templates.sql):
--   DECLARE @TrimAreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
--   INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, AreaLocationId, Description)
--   VALUES (N'TrimIn', 1, N'Trim In', @TrimAreaId, N'...');

-- AFTER:
DECLARE @TypeTrimIn  BIGINT = (SELECT Id FROM Parts.OperationType WHERE Code = N'TrimIn');
DECLARE @TypeTrimOut BIGINT = (SELECT Id FROM Parts.OperationType WHERE Code = N'TrimOut');
INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, OperationTypeId, Description)
VALUES (N'TrimIn', 1, N'Trim In', @TypeTrimIn, N'...');
```

Apply the confirmed map (Task 1 Step 3, block 7) to each template: `020` → DC-5G0=`DieCast`, TRIM-5G0=`TrimOut`, CNC-5G0=`CNC`, ASSY-FRONT=`AssemblyOut`; `022` → DieCastShot=`DieCast`; `024` → TrimIn/TrimOut; `026` → MachiningIn/MachiningOut. Keep every other column and all descriptions byte-for-byte (ASCII only).

- [ ] **Step 2: Run the suite to verify green**

Run: `Reset-DevDatabase; Run-Tests`
Expected: full suite green. On this reset the seeds now populate `OperationTypeId`; `AreaLocationId` is left NULL (nullable since Task 1). `005` still passes.

- [ ] **Step 3: Commit**

```bash
git add sql/seeds/020_seed_items.sql sql/seeds/022_seed_die_cast_operation_template.sql sql/seeds/024_seed_trim_operation_templates.sql sql/seeds/026_seed_machining_operation_templates.sql
git commit -m "feat(sql): seed OperationTemplate.OperationTypeId; drop AreaLocationId from seeds"
```

---

### Task 3: `OperationTemplate_Create` → OperationTypeId

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_OperationTemplate_Create.sql`
- Modify (test): `sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql`

**Interfaces:**
- Produces: `Parts.OperationTemplate_Create(@Code NVARCHAR(20), @Name NVARCHAR(100), @OperationTypeId BIGINT, @Description NVARCHAR(500), @AppUserId BIGINT)` → status row `Status, Message, NewId`. (`@AreaLocationId` removed.)

- [ ] **Step 1: Update the CRUD test's Create cases to fail against the current proc**

In `010_OperationTemplate_crud.sql`, change every `EXEC Parts.OperationTemplate_Create` call to pass `@OperationTypeId` instead of `@AreaLocationId`, resolving a type id at the top of the test (e.g. `DECLARE @TypeId BIGINT = (SELECT Id FROM Parts.OperationType WHERE Code = N'DieCast');`). Replace the AreaLocationId assertions with `OperationTypeId` assertions (created row has the passed `OperationTypeId`; NULL `@OperationTypeId` rejected; non-existent/deprecated type rejected). Widen any `INSERT ... EXEC` temp table to the new result shape if needed.

- [ ] **Step 2: Run the suite to verify it fails**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `010_OperationTemplate_crud` FAILS (proc still expects `@AreaLocationId`; `@OperationTypeId` is an unknown parameter).

- [ ] **Step 3: Update the Create proc**

In `R__Parts_OperationTemplate_Create.sql`, make these in-place edits, preserving the proc's three-tier error hierarchy, transaction, and audit structure:

1. **Signature:** replace `@AreaLocationId BIGINT` with `@OperationTypeId BIGINT`.
2. **Required-check:** replace the `@AreaLocationId IS NULL` rejection with `@OperationTypeId IS NULL`.
3. **FK-exists check:** replace the "Area exists + active" validation with:
```sql
IF NOT EXISTS (SELECT 1 FROM Parts.OperationType WHERE Id = @OperationTypeId AND DeprecatedAt IS NULL)
BEGIN
    SELECT @Status = 0, @Message = N'OperationType does not exist or is deprecated.';
    SELECT @Status AS Status, @Message AS Message, CAST(NULL AS BIGINT) AS NewId;
    RETURN;
END;
```
4. **INSERT:** replace `AreaLocationId` in the column list + `@AreaLocationId` in the values list with `OperationTypeId` / `@OperationTypeId`.
5. **Audit JSON:** replace the `AreaLocationId` sub-object in `NewValue` with a resolved `OperationTypeId` sub-object:
```sql
JSON_QUERY((SELECT ot.Id, ot.Code, ot.Name FROM Parts.OperationType ot WHERE ot.Id = @OperationTypeId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS OperationTypeId
```
(bare aliased `FOR JSON` double-encodes — keep the `JSON_QUERY(...)` wrapper). Keep the `<SUBJECT> · <ACTION>` Description shape via `Audit.ufn_MidDot()`/`Audit.ufn_TruncateActivity()`.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `010_OperationTemplate_crud` PASSES; full suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_OperationTemplate_Create.sql sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql
git commit -m "feat(sql): OperationTemplate_Create takes OperationTypeId"
```

---

### Task 4: `OperationTemplate_Update` → OperationTypeId

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_OperationTemplate_Update.sql`
- Modify (test): `sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql`

**Interfaces:**
- Produces: `Parts.OperationTemplate_Update(@Id BIGINT, @Name NVARCHAR(100), @OperationTypeId BIGINT, @Description NVARCHAR(500), @AppUserId BIGINT)` → `Status, Message`.

- [ ] **Step 1: Update the test's Update cases** — pass `@OperationTypeId`; assert the row's `OperationTypeId` changes; assert the old→new audit captures the resolved OperationType sub-objects. Run `Reset-DevDatabase; Run-Tests`; expect the Update cases FAIL.

- [ ] **Step 2: Run to verify fail**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `010` FAILS on the Update cases.

- [ ] **Step 3: Update the Update proc** — same five in-place edits as Task 3 (signature, required-check, FK-exists check, `UPDATE OperationTypeId = @OperationTypeId`, and the OLD-value capture `SELECT ... OperationTypeId ...` plus the NewValue audit sub-object). Preserve the lenient optimistic-lock + per-field audit pattern already in the proc.

- [ ] **Step 4: Run to verify pass**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `010` PASSES; suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_OperationTemplate_Update.sql sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql
git commit -m "feat(sql): OperationTemplate_Update takes OperationTypeId"
```

---

### Task 5: `OperationTemplate_Get` → OperationType/Category

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_OperationTemplate_Get.sql`
- Modify (test): `sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql`

**Interfaces:**
- Produces: `Parts.OperationTemplate_Get(@Id BIGINT)` result columns drop `AreaLocationId`/`AreaName`, add `OperationTypeId, OperationTypeCode, OperationTypeName, OperationCategoryCode, OperationCategoryName`.

- [ ] **Step 1: Update the test's Get assertions** to expect the new columns (`OperationTypeCode`, `OperationCategoryName`) and not `AreaName`. Run to verify FAIL.

- [ ] **Step 2: Run to verify fail**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `010` FAILS on the Get shape.

- [ ] **Step 3: Update the Get proc** — in the SELECT, replace the `AreaLocationId` column + `INNER JOIN Location.Location` with:
```sql
    ot.OperationTypeId,
    typ.Code AS OperationTypeCode,
    typ.Name AS OperationTypeName,
    cat.Code AS OperationCategoryCode,
    cat.Name AS OperationCategoryName
-- ...
FROM Parts.OperationTemplate ot
INNER JOIN Parts.OperationType     typ ON typ.Id = ot.OperationTypeId
INNER JOIN Parts.OperationCategory cat ON cat.Id = typ.OperationCategoryId
```

- [ ] **Step 4: Run to verify pass**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `010` PASSES; suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_OperationTemplate_Get.sql sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql
git commit -m "feat(sql): OperationTemplate_Get returns OperationType + Category"
```

---

### Task 6: `OperationTemplate_List` → type/category filter; retire `_ListByArea`

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_OperationTemplate_List.sql`
- Delete: `sql/migrations/repeatable/R__Parts_OperationTemplate_ListByArea.sql` (if a standalone proc file exists; otherwise skip)
- Modify (test): `sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql`

**Interfaces:**
- Produces: `Parts.OperationTemplate_List(@OperationTypeId BIGINT = NULL, @OperationCategoryId BIGINT = NULL, @ActiveOnly BIT = 1)` → rows with `OperationTypeCode, OperationTypeName, OperationCategoryCode, OperationCategoryName` (no `AreaName`), ordered by category then type then code.

- [ ] **Step 1: Update the test's List assertions** — a category filter returns only that category's templates; result rows carry `OperationCategoryName`. Run to verify FAIL.

- [ ] **Step 2: Run to verify fail**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `010` FAILS on the List filter/shape.

- [ ] **Step 3: Update the List proc** — replace the `@AreaLocationId` filter + `Location.Location` join with `@OperationTypeId`/`@OperationCategoryId` filters and the OperationType/Category joins (as in Task 5). Filter: `(@OperationTypeId IS NULL OR ot.OperationTypeId = @OperationTypeId) AND (@OperationCategoryId IS NULL OR typ.OperationCategoryId = @OperationCategoryId)`. `ORDER BY cat.Code, typ.Code, ot.Code, ot.VersionNumber`. If a separate `R__Parts_OperationTemplate_ListByArea.sql` proc exists, delete the file (its Config-Tool caller moves to the `@OperationCategoryId` filter in Task 9).

- [ ] **Step 4: Run to verify pass**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `010` PASSES; suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_OperationTemplate_List.sql sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql
git rm sql/migrations/repeatable/R__Parts_OperationTemplate_ListByArea.sql   # only if it exists
git commit -m "feat(sql): OperationTemplate_List filters by type/category; retire ListByArea"
```

---

### Task 7: `OperationTemplate_CreateNewVersion` clones OperationTypeId

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_OperationTemplate_CreateNewVersion.sql`
- Modify (test): `sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql`

**Interfaces:**
- Produces: `CreateNewVersion` copies the parent's `OperationTypeId` into the new version row (was cloning `AreaLocationId`).

- [ ] **Step 1: Update the test** — after `CreateNewVersion`, assert the new version's `OperationTypeId` equals the parent's. Run to verify FAIL.

- [ ] **Step 2: Run to verify fail**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `010` FAILS (clone still copies the now-NULL `AreaLocationId`, new version has NULL `OperationTypeId`).

- [ ] **Step 3: Update the proc** — in the clone `INSERT ... SELECT`, replace `AreaLocationId` with `OperationTypeId` in both the column list and the SELECT-from-parent list.

- [ ] **Step 4: Run to verify pass**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `010` PASSES; suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_OperationTemplate_CreateNewVersion.sql sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql
git commit -m "feat(sql): OperationTemplate_CreateNewVersion clones OperationTypeId"
```

---

### Task 8: `RouteStep_ListByRoute` surfaces OperationType instead of Area

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_RouteStep_ListByRoute.sql`
- Modify (test): the RouteStep list test under `sql/tests/0009_Parts_Process/` (locate the file asserting `OperationAreaLocationId`; if none asserts it, add a minimal assertion for the new column shape)

**Interfaces:**
- Produces: `RouteStep_ListByRoute` returns `OperationTypeId, OperationTypeCode, OperationTypeName, OperationCategoryName` in place of `OperationAreaLocationId`.

- [ ] **Step 1: Update/add the test** — assert each returned route step carries `OperationTypeCode` (and no `OperationAreaLocationId`). Run to verify FAIL.

- [ ] **Step 2: Run to verify fail**

Run: `Reset-DevDatabase; Run-Tests`
Expected: FAILS on the RouteStep column shape.

- [ ] **Step 3: Update the proc** — replace `ot.AreaLocationId AS OperationAreaLocationId` (and any `Location.Location` join added for area naming) with `ot.OperationTypeId`, `typ.Code AS OperationTypeCode`, `typ.Name AS OperationTypeName`, `cat.Name AS OperationCategoryName`, joining `Parts.OperationType typ` + `Parts.OperationCategory cat` off `ot`.

- [ ] **Step 4: Run to verify pass**

Run: `Reset-DevDatabase; Run-Tests`
Expected: PASSES; suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_RouteStep_ListByRoute.sql sql/tests/0009_Parts_Process/*RouteStep*.sql
git commit -m "feat(sql): RouteStep_ListByRoute surfaces OperationType not Area"
```

---

### Task 9: Named Queries + entity script

**Files:**
- Modify: `ignition/projects/Core/ignition/named-query/parts/OperationTemplate_Create/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/parts/OperationTemplate_Update/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/parts/OperationTemplate_List/query.sql` (+ its `resource.json` param defs)
- Modify: `ignition/projects/Core/ignition/named-query/parts/OperationTemplate_Get/query.sql` (no param change; result shape only)
- Delete: `ignition/projects/Core/ignition/named-query/parts/OperationTemplate_ListByArea/` (folder)
- Create: `ignition/projects/Core/ignition/named-query/parts/OperationType_ListForDropdown/query.sql` + `resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/OperationTemplate/code.py`

**Interfaces:**
- Consumes: the Task 3–8 proc signatures.
- Produces: `BlueRidge.Parts.OperationTemplate.getOperationTypesForDropdown()` → `[{label, value}]` (label = "Category — Type Name", value = OperationType.Id); `add`/`update`/`search` operate on `operationTypeId`/category.

- [ ] **Step 1: Swap NQ params + result shape**

In `OperationTemplate_Create/query.sql` and `_Update/query.sql`, replace `@AreaLocationId = :areaLocationId` with `@OperationTypeId = :operationTypeId`; update each `resource.json` parameter block (`:operationTypeId`, `sqlType` `3` = BIGINT). In `_List/query.sql`, replace the `:areaLocationId` param with `:operationTypeId` (and optionally `:operationCategoryId`). `_Get/query.sql` needs no param change. Delete the `OperationTemplate_ListByArea` folder.

- [ ] **Step 2: Add the OperationType dropdown NQ**

Create `parts/OperationType_ListForDropdown/query.sql`:
```sql
SELECT typ.Id, typ.Code, typ.Name, cat.Code AS CategoryCode, cat.Name AS CategoryName
FROM Parts.OperationType typ
INNER JOIN Parts.OperationCategory cat ON cat.Id = typ.OperationCategoryId
WHERE typ.DeprecatedAt IS NULL
ORDER BY cat.Code, typ.Code;
```
Create its `resource.json` (`version: 2`, `attributes.type: "Query"`, no params) mirroring a sibling read NQ.

- [ ] **Step 3: Update the entity script**

In `BlueRidge/Parts/OperationTemplate/code.py`:
- Replace `getAreasForDropdown()` with `getOperationTypesForDropdown()` calling the new NQ and returning `[{"label": row["CategoryName"] + u" — " + row["Name"], "value": row["Id"]}]` (build the label in Python, not the expr layer).
- In `_toRailRow()` / `search()` / `getAllForList()`, replace the `AreaName` grouping key with `OperationCategoryName` (from the updated List result).
- In `add(data)` / `update(data)`, pass `operationTypeId` (from `data`) to the NQ instead of `areaLocationId`.
- Keep all DB access routed through the existing `BlueRidge.Common.*` helpers; do not call `system.db.*` directly.

- [ ] **Step 4: Scan + smoke the NQ layer**

Run: `.\scan.ps1` (repo root). Then **restart the gateway** (a brand-new Core NQ — `OperationType_ListForDropdown` — must register for inherited MPP/MPP_Config visibility). Verify in the Designer/DB-browser that each edited NQ executes without a param error.
Expected: all five NQs execute; `getOperationTypesForDropdown()` returns the 8 rows.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/parts/OperationTemplate_Create ignition/projects/Core/ignition/named-query/parts/OperationTemplate_Update ignition/projects/Core/ignition/named-query/parts/OperationTemplate_List ignition/projects/Core/ignition/named-query/parts/OperationTemplate_Get ignition/projects/Core/ignition/named-query/parts/OperationType_ListForDropdown ignition/projects/Core/ignition/script-python/BlueRidge/Parts/OperationTemplate/code.py
git rm -r ignition/projects/Core/ignition/named-query/parts/OperationTemplate_ListByArea
git commit -m "feat(ignition): OperationTemplate NQs + entity script use OperationType"
```

---

### Task 10: Contract migration — NOT NULL + drop AreaLocationId

**Files:**
- Create: `sql/migrations/versioned/0031_operation_type_contract.sql`
- Modify (test): `sql/tests/0009_Parts_Process/005_OperationType_seed.sql`

**Interfaces:**
- Produces: `Parts.OperationTemplate.OperationTypeId` is `NOT NULL`; `AreaLocationId` (column, FK, index) removed.

- [ ] **Step 1: Extend the schema test to require the drop**

Append to `005_OperationType_seed.sql`:
```sql
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID(N'Parts.OperationTemplate') AND name = N'AreaLocationId')
    RAISERROR('FAIL 005: OperationTemplate.AreaLocationId should be dropped', 16, 1);

IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID(N'Parts.OperationTemplate') AND name = N'OperationTypeId' AND is_nullable = 1)
    RAISERROR('FAIL 005: OperationTemplate.OperationTypeId should be NOT NULL', 16, 1);
```

- [ ] **Step 2: Run to verify fail**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `005` FAILS (`AreaLocationId` still present, `OperationTypeId` still nullable).

- [ ] **Step 3: Write the contract migration**

Create `sql/migrations/versioned/0031_operation_type_contract.sql`:
```sql
-- 0031_operation_type_contract.sql
-- Finalize: OperationTypeId NOT NULL; drop AreaLocationId (FK, index, column). Runs after all consumers migrated.
SET XACT_ABORT ON;
BEGIN TRANSACTION;

-- Guard: no unmapped rows before NOT NULL
IF EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE OperationTypeId IS NULL)
    RAISERROR('0031: OperationTemplate rows with NULL OperationTypeId remain — cannot enforce NOT NULL.', 16, 1);

ALTER TABLE Parts.OperationTemplate ALTER COLUMN OperationTypeId BIGINT NOT NULL;

-- Drop AreaLocationId FK (name may vary — resolve dynamically), then index, then column
DECLARE @fk SYSNAME = (
    SELECT fk.name FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.parent_object_id = OBJECT_ID(N'Parts.OperationTemplate') AND c.name = N'AreaLocationId');
IF @fk IS NOT NULL EXEC(N'ALTER TABLE Parts.OperationTemplate DROP CONSTRAINT ' + @fk);

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_OperationTemplate_AreaLocationId')
    DROP INDEX IX_OperationTemplate_AreaLocationId ON Parts.OperationTemplate;

IF COL_LENGTH(N'Parts.OperationTemplate', N'AreaLocationId') IS NOT NULL
    ALTER TABLE Parts.OperationTemplate DROP COLUMN AreaLocationId;

COMMIT TRANSACTION;
```

- [ ] **Step 4: Run to verify pass**

Run: `Reset-DevDatabase; Run-Tests`
Expected: `005` PASSES; full suite green (all consumers already off `AreaLocationId`).

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0031_operation_type_contract.sql sql/tests/0009_Parts_Process/005_OperationType_seed.sql
git commit -m "feat(sql): contract migration — OperationTypeId NOT NULL, drop AreaLocationId"
```

---

### Task 11: Config-Tool views (Designer)

**Files (edit in Designer, not by file-authoring):**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/OperationTemplates/view.json`
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/NewOperationTemplate/view.json`

**Interfaces:**
- Consumes: `getOperationTypesForDropdown()` + the type/category List result (Task 9).

- [ ] **Step 1: OperationTemplates list — group by Category**

In Designer, open `Views/Parts/OperationTemplates`. Replace the Area filter/grouping: rename the persistent filter custom prop `filter.areaLocationId` → `filter.operationTypeId` (or `filter.operationCategoryId`); rebind the list grouping to the `OperationCategoryName` field returned by the updated `search()`/List. Pre-declare any new bound custom prop with a shaped default (per the pre-declare-bound-custom-props convention). Remove the old `getAreasForDropdown` binding.

- [ ] **Step 2: NewOperationTemplate popup — OperationType dropdown**

In Designer, open `Components/Popups/NewOperationTemplate`. Replace the Area dropdown with an `ia.input.dropdown` bound `options` ← `runScript("BlueRidge.Parts.OperationTemplate.getOperationTypesForDropdown")` and `props.value` bidi-bound to `editDraft.OperationTypeId`. Seed `editDraft` with the full shape including `OperationTypeId: null`.

- [ ] **Step 3: Designer smoke**

In a Perspective session: open the OperationTemplates screen → confirm templates group under **Die Cast / Trim / Machining & Assembly**; open **New Operation Template** → the dropdown lists the 8 roles; create one → it saves with the chosen `OperationTypeId` and appears under the right category; edit an existing template's type → persists; the `/audit` row shows the `OperationType` resolved sub-object.
Expected: all pass. Iterate in Designer if the file-authored NQ/script surface needs adjustment.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/OperationTemplates ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/NewOperationTemplate
git commit -m "feat(ignition): OperationTemplate Config-Tool views group/select by OperationType"
```

---

### Task 12: FDS + Data Model doc updates

**Files:**
- Modify: `MPP_MES_DATA_MODEL.md`
- Modify: `MPP_MES_FDS.md`

- [ ] **Step 1: Data Model edits**

- Add `### Parts.OperationCategory` and `### Parts.OperationType` sections in §2 (Parts), adjacent to `OperationTemplate` (~line 385), with the column tables from Task 1.
- In `Parts.OperationTemplate` (~line 395): remove the `AreaLocationId` row, add `OperationTypeId BIGINT NOT NULL FK → Parts.OperationType`; note `RequiresSubLotSplit` now correlates to `OperationTypeId = MachiningOut`.
- Add a Revision History row at the top (line 13); bump the header version (line 3) + table count (line 4, ~73 → ~75).

- [ ] **Step 2: FDS edits**

- **FDS-03-012** (§3.4): replace the `AreaLocationId` field line with `OperationTypeId` (role + category); reaffirm cross-area reuse.
- **FDS-03-009** (§3.3): reword "operation template, which defines the area" → defines the **operation role** + data-collection; area is the terminal's runtime location.
- **FDS-02-001 note** + **FDS-02-003** (§2.2): reword "operation templates reference Areas / for filtering" → screens filter defect/downtime codes by the **terminal's area**, not the template.
- Add a note aligning **FDS-05-025** (sort/inspection terminator) as orthogonal to `OperationType`.
- Add a Revision History row (lines 33–41); bump the header version.

- [ ] **Step 3: Verify + commit**

Confirm no other doc section still describes the template as area-scoped (grep `AreaLocationId` in both docs → only historical/revision mentions remain).

```bash
git add MPP_MES_DATA_MODEL.md MPP_MES_FDS.md
git commit -m "docs: OperationType restructure in Data Model + FDS"
```

---

## Self-Review

**Spec coverage** (Spec 1 §11 matrix):
- OperationCategory + OperationType tables + seeds → Task 1. ✔
- Drop AreaLocationId / add OperationTypeId (migration + backfill) → Tasks 1 (expand) + 10 (contract). ✔
- Reseed 4 seed files → Task 2. ✔
- 6 procs → Tasks 3–8. ✔
- 4 NQs edited + 1 retired + 1 new → Task 9. ✔
- Entity script → Task 9. ✔
- 2 Config-Tool views → Task 11. ✔
- Defect/downtime filtering (doc-only) → Task 12 (FDS-02-001/003 reword; no code task, per §7). ✔
- FDS + Data Model edits → Task 12. ✔
- SQL tests reworked → Tasks 1, 3–8, 10. ✔

**Placeholder scan:** no TBD/TODO; every code step shows the edit. The one deliberate conditional is the `ListByArea` file (delete "only if it exists") — grounding found the area filter in the List proc + a possible dedicated proc; the step handles both.

**Type consistency:** `@OperationTypeId BIGINT` and the result columns `OperationTypeCode/Name`, `OperationCategoryCode/Name` are used consistently across Tasks 3–9; `getOperationTypesForDropdown()` returns `[{label, value}]` consumed by Task 11; the confirmed template→role map is identical in Task 1 (backfill) and Task 2 (seeds).

**Notes:** Ignition steps (Tasks 9, 11) aren't SQL-TDD — they use scan/gateway-restart + Designer smoke as their verification. The SQL suite stays green after every task because expand keeps both columns until Task 10.
