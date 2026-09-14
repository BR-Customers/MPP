# Cutover Machine — Eligibility Dropdown & `ProducedAtLocationId` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the inventory cutover scan screen's free-text **Machine #** with a dropdown of die cast machines driven by part eligibility, and persist the operator's pick onto the LOT as a typed FK.

**Architecture:** A new SQL read proc answers "which die cast machines run this part" by exact `Parts.ItemLocation` match at the machine tier, falling back to every active machine when the part has no row. A new nullable FK `Lots.Lot.ProducedAtLocationId` stores the pick, written by `Lots.Lot_Create` and echoed into the `LotCreated` event JSON. The Ignition layer swaps a text-field for a cascading dropdown in the three responsive cutover views and carries a `LocationId` where it used to carry a string.

**Tech Stack:** SQL Server 2022 (T-SQL, versioned + repeatable migrations, `test.Assert_*` harness), Ignition 8.3 Perspective file-based project (Jython 2.7 script modules, named queries, `view.json`).

**Spec:** `docs/superpowers/specs/2026-09-14-cutover-machine-eligibility-design.md` — read it before starting. Every "why" lives there; this plan is the "how".

## Global Constraints

- **Branch:** `jacques/working`. Never commit to `main`.
- **Staging:** stage explicit paths only. Never `git add -u` or `git add -A` — a concurrent user may have unrelated files in the working tree.
- **Commit messages:** omit the `Co-Authored-By: Claude` trailer.
- **Tests target `MPP_MES_Test`**, the throwaway DB — `Run-Tests.ps1` DROPs its target. Never point it at `MPP_MES_Dev`, which is hand-built and unbacked.
- **SQL conventions:** `UpperCamelCase` identifiers; `NVARCHAR` never `VARCHAR`; `BIGINT` FKs; `DATETIME2(3)`; no magic integers — resolve code tables by `Code`.
- **Ignition JDBC (FDS-11-011):** stored procedures SHALL NOT use `OUTPUT` parameters. Read procs return one result set; mutation procs end every exit path with a `SELECT` of local status variables.
- **`Lots.Lot_Create`'s status row has FOUR columns:** `Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50)`. Every `INSERT … EXEC` temp table must match that shape exactly.
- **Rejecting validations run BEFORE `BEGIN TRANSACTION`.** A `ROLLBACK` inside a proc invoked via `INSERT-EXEC` raises Msg 3915.
- **ASCII only** in any string that reaches a `.sql` file — `sqlcmd` reads files in the Windows codepage and turns an em-dash or middot into mojibake. This includes the dropdown label built in Jython, for consistency.
- **All named queries live in the `Core` project.** `MPP` and `MPP_Config` have zero local named queries.
- **After writing any Ignition file:** run `.\scan.ps1` from the repo root. No gateway restart needed.
- **Existing `view.json` files are Designer's territory.** If you file-edit them, Designer must be closed, and you must `scan.ps1` afterwards. Designer serializes `=` `'` `<` `>` as 6-character unicode escapes (`=`), so anchor any literal-string match on escape-free text.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `sql/migrations/versioned/0082_lot_produced_at_location.sql` | Add the `ProducedAtLocationId` column + FK; record in `SchemaVersion` | 1 |
| `MPP_MES_DATA_MODEL.md` | Source of truth for the column's documentation prose | 1 |
| `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql` | Generated from the data model; carries the `MS_Description` | 1 |
| `sql/tests/0070_Cutover_EntryRoute/055_ProducedAtLocation_schema.sql` | Asserts the column, its type, its nullability and its FK | 1 |
| `sql/migrations/repeatable/R__Location_Location_ListDieCastMachinesForItem.sql` | The eligibility read proc | 2 |
| `sql/tests/0070_Cutover_EntryRoute/060_DieCastMachine_ListForItem.sql` | Shortlist / fallback / deprecation / ordering coverage | 2 |
| `sql/migrations/repeatable/R__Lots_Lot_Create.sql` | Gains `@ProducedAtLocationId`: validate, write, audit | 3 |
| `sql/tests/0070_Cutover_EntryRoute/070_Lot_Create_ProducedAt.sql` | Accept / reject / omit / audit-JSON coverage | 3 |
| `sql/migrations/repeatable/R__Lots_Lot_SearchAdvanced.sql` | Machine filter + displayed column consider the cutover machine | 6b |
| `sql/tests/0067_Lot_SearchAdvanced/060_cutover_machine.sql` | Cutover LOT findable and displayed by machine | 6b |
| `ignition/projects/Core/ignition/named-query/location/DieCastMachine_ListForItem/` | NQ wrapping the read proc | 4 |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py` | `getDieCastMachineDropdown` | 4 |
| `ignition/projects/Core/ignition/named-query/lots/Lot_Create/` | NQ gains the `producedAtLocationId` parameter | 5 |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` | `create` forwards `producedAtLocationId` | 5 |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Cutover/Scan/code.py` | `machineLocationId` / `machineName` state; `addBasket` passes the machine | 5 |
| `ignition/projects/MPP/com.inductiveautomation.perspective/session-props/props.json` | Session state shape | 6 |
| `.../views/BlueRidge/Views/ShopFloor/_CutoverScan/{Desktop,Tablet,Phone}/view.json` | The dropdown, the header label, the setup plumbing | 6 |

---

## Task 1: Migration 0082 — `Lots.Lot.ProducedAtLocationId`

**Files:**
- Create: `sql/migrations/versioned/0082_lot_produced_at_location.sql`
- Create: `sql/tests/0070_Cutover_EntryRoute/055_ProducedAtLocation_schema.sql`
- Modify: `MPP_MES_DATA_MODEL.md` (the `Lots.Lot` column table, and the revision-history table at the top)
- Regenerate: `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql`

**Interfaces:**
- Consumes: nothing.
- Produces: column `Lots.Lot.ProducedAtLocationId BIGINT NULL`, FK constraint `FK_Lot_ProducedAtLocation` → `Location.Location(Id)`. Tasks 3 and 5 write it.

- [ ] **Step 1: Write the failing schema test**

Create `sql/tests/0070_Cutover_EntryRoute/055_ProducedAtLocation_schema.sql`:

```sql
-- =============================================
-- File:         0070_Cutover_EntryRoute/055_ProducedAtLocation_schema.sql
-- Description:  Lots.Lot.ProducedAtLocationId (migration 0082) -- the die cast
--               machine that produced a LOT.
--
--               Cutover is the only writer: a LOT born at a die cast terminal
--               gets its machine from CreatedAtTerminalId's parent, but a
--               cutover LOT is created at a MACHINING terminal weeks after the
--               casting, so the machine exists only on the paper tag.
--
--               NULLable by design -- every non-cutover LOT leaves it NULL.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/055_ProducedAtLocation_schema.sql';
GO

-- (1) The column exists.
DECLARE @a1 NVARCHAR(10) = CASE WHEN COL_LENGTH(N'Lots.Lot', N'ProducedAtLocationId') IS NOT NULL
                                THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] column exists on Lots.Lot',
    @Expected = N'1', @Actual = @a1;

-- (2) It is BIGINT and NULLable. NOT NULL would break every existing caller.
DECLARE @a2 NVARCHAR(50) = (
    SELECT ty.name + N'/' + CAST(c.is_nullable AS NVARCHAR(1))
    FROM sys.columns c
    INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID(N'Lots.Lot') AND c.name = N'ProducedAtLocationId');
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] column is BIGINT NULL',
    @Expected = N'bigint/1', @Actual = @a2;

-- (3) It is a real FK to Location.Location, not a loose id.
DECLARE @a3 NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id
                            AND c.column_id = fkc.parent_column_id
    WHERE fk.parent_object_id = OBJECT_ID(N'Lots.Lot')
      AND fk.referenced_object_id = OBJECT_ID(N'Location.Location')
      AND c.name = N'ProducedAtLocationId');
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] column is an FK to Location.Location',
    @Expected = N'1', @Actual = @a3;

-- (4) The migration is recorded.
DECLARE @a4 NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM dbo.SchemaVersion
    WHERE MigrationId = N'0082_lot_produced_at_location');
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] migration 0082 recorded in SchemaVersion',
    @Expected = N'1', @Actual = @a4;

-- (5) The column carries an MS_Description (generated from the data model).
DECLARE @a5 NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM sys.extended_properties ep
    WHERE ep.major_id = OBJECT_ID(N'Lots.Lot')
      AND ep.minor_id = COLUMNPROPERTY(OBJECT_ID(N'Lots.Lot'), N'ProducedAtLocationId', 'ColumnId')
      AND ep.name = N'MS_Description');
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] column is documented',
    @Expected = N'1', @Actual = @a5;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd sql/tests && powershell -NoProfile -File Run-Tests.ps1 -Filter "0070"
```

Expected: the five `[ProducedAt]` assertions FAIL (`0` vs `1`, and `NULL` vs `bigint/1`). Everything else in `0070_Cutover_EntryRoute` passes.

- [ ] **Step 3: Write the migration**

Create `sql/migrations/versioned/0082_lot_produced_at_location.sql`:

```sql
-- ============================================================
-- Migration:   0082_lot_produced_at_location.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-14
-- Description: Lots.Lot.ProducedAtLocationId -- the die cast machine that
--              produced this LOT.
--
--              WHY. In normal production the machine needs no column: a die
--              cast terminal's PARENT is the machine (DC1-M01-T1 -> DC1-M01),
--              so Lot.CreatedAtTerminalId answers "which machine cast this".
--
--              The inventory cutover scan breaks that implication. The basket
--              was cast weeks ago and the scan happens at a MACHINING terminal,
--              so CreatedAtTerminalId records the machining terminal and the
--              casting machine survives only on the paper tag in the operator's
--              hand. The cutover window is the one chance to capture it.
--
--              WHY NOT DieNumber. That column is the LEGACY DIE, superseded by
--              the ToolId FK in v1.9 and scheduled for removal once all writers
--              move to the FK. A machine stored there would have to be
--              untangled by the removal migration.
--
--              WHAT. BIGINT NULL FK -> Location.Location(Id). NULL for every
--              LOT born at a die cast terminal and for every received
--              purchased component. Lots.Lot is the unpartitioned header table,
--              so adding a nullable column is metadata-only.
--
--              NO INDEX -- nothing queries by machine yet. NO BACKFILL -- LOTs
--              from the cutover releases already shipped never captured one.
-- ============================================================

-- ---- 1. The column ----
IF COL_LENGTH('Lots.Lot', 'ProducedAtLocationId') IS NULL
    ALTER TABLE Lots.Lot
        ADD ProducedAtLocationId BIGINT NULL
            CONSTRAINT FK_Lot_ProducedAtLocation REFERENCES Location.Location(Id);
GO

-- ---- 2. Report, so a failed add is visible at deploy ----
DECLARE @Present NVARCHAR(20) =
    CASE WHEN COL_LENGTH('Lots.Lot', 'ProducedAtLocationId') IS NOT NULL
         THEN N'present' ELSE N'MISSING' END;
PRINT 'Lots.Lot.ProducedAtLocationId: ' + @Present;
GO

-- ---- 3. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0082_lot_produced_at_location')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0082_lot_produced_at_location',
            N'Lots.Lot.ProducedAtLocationId (BIGINT NULL, FK -> Location.Location) -- the die cast machine that produced a LOT. Written only by the inventory cutover scan, where the creating terminal is a machining terminal and cannot imply the casting machine. Not DieNumber, which is the legacy die column slated for removal.');
GO
PRINT 'Migration 0082 (lot_produced_at_location) applied.';
GO
```

- [ ] **Step 4: Document the column in the data model**

In `MPP_MES_DATA_MODEL.md`, find the `Lots.Lot` column table — the row for `DieNumber` is the landmark (`| DieNumber | NVARCHAR(50) | NULL | **Legacy as of v1.9** …`). Insert this row immediately **after** the `ToolCavityId` row and **before** the `DieNumber` row:

```markdown
| ProducedAtLocationId | BIGINT | FK → Location.Location.Id, NULL | Added v2.5 (migration `0082`). The **die cast machine** that produced this LOT. Written only by the inventory cutover scan: a LOT born at a die cast terminal derives its machine from `CreatedAtTerminalId`'s parent, but a cutover LOT is created at a machining terminal weeks after the casting, so the machine exists only on the paper tag. NULL for every non-cutover LOT and for every received purchased component. Not to be confused with `DieNumber`, which is the legacy DIE column. |
```

Add a revision-history row at the top of the same document, following the format of the existing rows:

```markdown
| 2.5 | 2026-09-14 | Blue Ridge Automation | **`Lots.Lot.ProducedAtLocationId`** (migration `0082`) — a nullable FK to `Location.Location` recording the die cast machine that produced a LOT. Populated only by the inventory cutover scan, whose operator reads the machine off the paper tag; every other mint leaves it NULL because a die cast terminal's parent already names the machine. Spec `docs/superpowers/specs/2026-09-14-cutover-machine-eligibility-design.md`. |
```

- [ ] **Step 5: Regenerate the extended properties**

```bash
node sql/scripts/gen_extended_properties.js
```

Expected: the script rewrites `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql` and prints a parse summary. Confirm the new description landed and is ASCII:

```bash
grep -c "ProducedAtLocationId" sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql
```

Expected: a non-zero count. The generator refuses to emit a byte above `0x7F`, so if the prose you wrote contained an em-dash it will have transliterated it — that is the intended behaviour, not an error.

- [ ] **Step 6: Run the tests and watch them pass**

```bash
cd sql/tests && powershell -NoProfile -File Run-Tests.ps1 -Filter "0070"
```

Expected: all five `[ProducedAt]` assertions PASS; the rest of `0070_Cutover_EntryRoute` still passes. `Run-Tests.ps1` resets `MPP_MES_Test` from scratch, so this also proves 0082 applies cleanly to a virgin database.

If the run exits 1 with zero reported failures, a test file's `sqlcmd` errored — usually teardown FK order. Read the red output.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/versioned/0082_lot_produced_at_location.sql sql/tests/0070_Cutover_EntryRoute/055_ProducedAtLocation_schema.sql sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql MPP_MES_DATA_MODEL.md
git commit -m "feat(sql): 0082 Lot.ProducedAtLocationId -- the die cast machine that made it"
```

---

## Task 2: `Location.Location_ListDieCastMachinesForItem`

**Files:**
- Create: `sql/migrations/repeatable/R__Location_Location_ListDieCastMachinesForItem.sql`
- Create: `sql/tests/0070_Cutover_EntryRoute/060_DieCastMachine_ListForItem.sql`

**Interfaces:**
- Consumes: nothing from Task 1 (independent).
- Produces: `Location.Location_ListDieCastMachinesForItem @ItemId BIGINT = NULL`, returning one result set with columns **`Id BIGINT, Code NVARCHAR(100), Name NVARCHAR(200), AreaCode NVARCHAR(100), AreaName NVARCHAR(200), IsEligible BIT`**, ordered by `(AreaCode, Code)`. Task 4 wraps it.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0070_Cutover_EntryRoute/060_DieCastMachine_ListForItem.sql`:

```sql
-- =============================================
-- File:         0070_Cutover_EntryRoute/060_DieCastMachine_ListForItem.sql
-- Description:  Which die cast machines the cutover scan offers for a part.
--
--               EXACT match at the machine tier, deliberately NOT the
--               Parts.v_EffectiveItemLocation ancestor cascade: eligibility is
--               recorded mostly at the Area and Line tiers, so the cascade
--               returns the same 11 machines for every part in the plant and
--               filters nothing. The machine-tier rows are the deliberate
--               signal.
--
--               A part with NO machine-tier row falls back to every active die
--               cast machine (IsEligible = 0 on each), so the operator can
--               always record what the paper tag says.
--
--               This file builds its own area + machines so it is
--               order-independent inside the suite.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/060_DieCastMachine_ListForItem.sql';
GO

-- Resolve an item that provably carries NO die-cast-machine eligibility row,
-- rather than naming one. The fallback assertions below are only meaningful if
-- the item's ONLY machine-tier rows are the ones this file creates, and the
-- seeded plant maps several real parts to real machines.
DECLARE @Item BIGINT = (
    SELECT TOP 1 i.Id FROM Parts.Item i
    WHERE i.DeprecatedAt IS NULL
      AND NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il
                      INNER JOIN Location.Location l ON l.Id = il.LocationId
                      INNER JOIN Location.LocationTypeDefinition d
                              ON d.Id = l.LocationTypeDefinitionId
                      WHERE il.ItemId = i.Id AND il.DeprecatedAt IS NULL
                        AND d.Code = N'DieCastMachine')
    ORDER BY i.Id);

DECLARE @AreaDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionArea');
DECLARE @MachDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @Facility BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                            INNER JOIN Location.LocationTypeDefinition d
                                    ON d.Id = l.LocationTypeDefinitionId
                            WHERE d.Code = N'Facility' AND l.DeprecatedAt IS NULL
                            ORDER BY l.Id);

-- Pre-flight: clear this file's fixtures from any earlier failed run.
DELETE il FROM Parts.ItemLocation il
INNER JOIN Location.Location l ON l.Id = il.LocationId
WHERE l.Code IN (N'ZZDC-M01', N'ZZDC-M02', N'ZZDC-M03');
DELETE FROM Location.Location WHERE Code IN (N'ZZDC-M01', N'ZZDC-M02', N'ZZDC-M03');
DELETE FROM Location.Location WHERE Code = N'ZZDC-AREA';

-- Fixture: one area with three machines. M01 + M02 are eligible for the item;
-- M03 is not. A fourth machine is created deprecated to prove exclusion.
DECLARE @Area BIGINT;
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder, CreatedAt)
VALUES (@AreaDef, @Facility, N'ZZ Die Cast Fixture', N'ZZDC-AREA', 900, SYSUTCDATETIME());
SET @Area = SCOPE_IDENTITY();

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder, CreatedAt, DeprecatedAt)
VALUES (@MachDef, @Area, N'Machine 01', N'ZZDC-M01', 901, SYSUTCDATETIME(), NULL),
       (@MachDef, @Area, N'Machine 02', N'ZZDC-M02', 902, SYSUTCDATETIME(), NULL),
       (@MachDef, @Area, N'Machine 03', N'ZZDC-M03', 903, SYSUTCDATETIME(), SYSUTCDATETIME());

DECLARE @M01 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZDC-M01');
DECLARE @M02 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZDC-M02');
DECLARE @M03 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZDC-M03');

INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt)
VALUES (@Item, @M01, SYSUTCDATETIME()),
       (@Item, @M02, SYSUTCDATETIME()),
       (@Item, @M03, SYSUTCDATETIME());   -- deprecated machine: must not appear

CREATE TABLE #M (Id BIGINT, Code NVARCHAR(100), Name NVARCHAR(200),
                 AreaCode NVARCHAR(100), AreaName NVARCHAR(200), IsEligible BIT);

-- (1) An item with machine-tier rows gets exactly those machines.
DELETE FROM #M;
INSERT INTO #M EXEC Location.Location_ListDieCastMachinesForItem @ItemId = @Item;
DECLARE @c1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
                            FROM #M WHERE Code LIKE N'ZZDC-%');
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] eligible item gets its two machines',
    @Expected = N'2', @Actual = @c1;

-- (2) A deprecated machine is excluded even though it has an eligibility row.
DECLARE @c2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
                            FROM #M WHERE Id = @M03);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] deprecated machine excluded',
    @Expected = N'0', @Actual = @c2;

-- (3) Every row of a shortlist is flagged eligible.
DECLARE @c3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
                            FROM #M WHERE Code LIKE N'ZZDC-%' AND IsEligible = 0);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] shortlist rows carry IsEligible = 1',
    @Expected = N'0', @Actual = @c3;

-- (4) The area is resolved for the label -- machine Names collide across areas
--     (four 'Machine 01's in the real plant), so the area is what disambiguates.
DECLARE @c4 NVARCHAR(200) = (SELECT AreaName FROM #M WHERE Id = @M01);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] area name resolved for the label',
    @Expected = N'ZZ Die Cast Fixture', @Actual = @c4;

-- (5) Ordering is (AreaCode, Code) -- not Name, which is ambiguous.
DECLARE @c5 NVARCHAR(100) = (SELECT STRING_AGG(Code, N',') WITHIN GROUP (ORDER BY AreaCode, Code)
                             FROM #M WHERE Code LIKE N'ZZDC-%');
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] ordered by area then code',
    @Expected = N'ZZDC-M01,ZZDC-M02', @Actual = @c5;

-- (6) Fallback: an item with NO machine-tier row gets EVERY active machine.
DECLARE @TotalActive NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'DieCastMachine' AND l.DeprecatedAt IS NULL);

DELETE FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId IN (@M01, @M02, @M03);

DELETE FROM #M;
INSERT INTO #M EXEC Location.Location_ListDieCastMachinesForItem @ItemId = @Item;
DECLARE @c6 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #M);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] no machine-tier row falls back to all machines',
    @Expected = @TotalActive, @Actual = @c6;

-- (7) Fallback rows are flagged so a caller can tell a shortlist from a fallback.
DECLARE @c7 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #M WHERE IsEligible = 1);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] fallback rows carry IsEligible = 0',
    @Expected = N'0', @Actual = @c7;

-- (8) NULL item is the fallback branch too (first paint, before a part is picked).
DELETE FROM #M;
INSERT INTO #M EXEC Location.Location_ListDieCastMachinesForItem @ItemId = NULL;
DECLARE @c8 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #M);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] NULL item returns all machines',
    @Expected = @TotalActive, @Actual = @c8;

-- (9) A deprecated ItemLocation row does not make its machine eligible.
INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt, DeprecatedAt)
VALUES (@Item, @M01, SYSUTCDATETIME(), SYSUTCDATETIME());
DELETE FROM #M;
INSERT INTO #M EXEC Location.Location_ListDieCastMachinesForItem @ItemId = @Item;
DECLARE @c9 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #M);
EXEC test.Assert_IsEqual @TestName = N'[DcMachines] deprecated eligibility row does not shortlist',
    @Expected = @TotalActive, @Actual = @c9;

DROP TABLE #M;

-- Teardown: eligibility rows before locations (FK), children before parent.
DELETE il FROM Parts.ItemLocation il
INNER JOIN Location.Location l ON l.Id = il.LocationId
WHERE l.Code IN (N'ZZDC-M01', N'ZZDC-M02', N'ZZDC-M03');
DELETE FROM Location.Location WHERE Code IN (N'ZZDC-M01', N'ZZDC-M02', N'ZZDC-M03');
DELETE FROM Location.Location WHERE Code = N'ZZDC-AREA';
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd sql/tests && powershell -NoProfile -File Run-Tests.ps1 -Filter "0070"
```

Expected: the file errors with `Could not find stored procedure 'Location.Location_ListDieCastMachinesForItem'`, and `Run-Tests.ps1` exits 1.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Location_Location_ListDieCastMachinesForItem.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Location_Location_ListDieCastMachinesForItem.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-14
-- Version:     1.0
-- Description: Which die cast machines the inventory cutover scan offers for a
--              part.
--
--              EXACT MATCH AT THE MACHINE TIER, not the FDS-03-014 ancestor
--              cascade that Location_ListMachiningDestinations uses. Measured
--              against Dev 2026-09-14, the cascade returns ELEVEN machines for
--              every part in the plant: eligibility is recorded predominantly
--              at the Area (135 rows) and Line (272 rows) tiers and every
--              machine beneath an eligible area inherits it. A filter that
--              returns the same rows regardless of input is not a filter. The
--              machine-tier rows (9 in Dev) are the deliberate signal -- the
--              six 6MA parts were mapped to DC1-M10 on purpose.
--
--              FALLBACK: a part with NO machine-tier row gets EVERY active die
--              cast machine, flagged IsEligible = 0. The operator must always
--              be able to record what the paper tag says; eligibility is a
--              shortlist, never a gate on the scan.
--
--              ORDERED BY (AreaCode, Code), NOT Name: machine Names collide
--              across areas -- DC1-M01 and DC2-M01 are both 'Machine 01' -- so
--              the area is what disambiguates them in a picker.
--
--              Read proc: no @Status/@Message, no OUTPUT params, one result
--              set; an empty rowset means no die cast machines are configured
--              at all (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Location_ListDieCastMachinesForItem
    @ItemId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Decide the fallback ONCE rather than per row: either the item has
    -- machine-tier eligibility (return exactly those) or it has none (return
    -- every active machine).
    DECLARE @EligibleCount INT = (
        SELECT COUNT(*)
        FROM Location.Location m
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = m.LocationTypeDefinitionId
        WHERE ltd.Code = N'DieCastMachine'
          AND m.DeprecatedAt IS NULL
          AND @ItemId IS NOT NULL
          AND EXISTS (SELECT 1 FROM Parts.ItemLocation il
                      WHERE il.ItemId = @ItemId
                        AND il.LocationId = m.Id
                        AND il.DeprecatedAt IS NULL));

    SELECT
        m.Id,
        m.Code,
        m.Name,
        area.Code AS AreaCode,
        area.Name AS AreaName,
        CAST(CASE WHEN @EligibleCount = 0 THEN 0 ELSE 1 END AS BIT) AS IsEligible
    FROM Location.Location m
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = m.LocationTypeDefinitionId
    LEFT JOIN Location.Location area ON area.Id = m.ParentLocationId
    WHERE ltd.Code = N'DieCastMachine'
      AND m.DeprecatedAt IS NULL
      AND (@EligibleCount = 0
           OR EXISTS (SELECT 1 FROM Parts.ItemLocation il
                      WHERE il.ItemId = @ItemId
                        AND il.LocationId = m.Id
                        AND il.DeprecatedAt IS NULL))
    ORDER BY area.Code, m.Code;
END;
GO
```

- [ ] **Step 4: Run the tests and watch them pass**

```bash
cd sql/tests && powershell -NoProfile -File Run-Tests.ps1 -Filter "0070"
```

Expected: all nine `[DcMachines]` assertions PASS, and Task 1's `[ProducedAt]` assertions still pass.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Location_Location_ListDieCastMachinesForItem.sql sql/tests/0070_Cutover_EntryRoute/060_DieCastMachine_ListForItem.sql
git commit -m "feat(sql): die cast machines for a part -- exact machine-tier eligibility, fallback to all"
```

---

## Task 3: `Lots.Lot_Create` accepts and records the machine

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_Create.sql`
- Create: `sql/tests/0070_Cutover_EntryRoute/070_Lot_Create_ProducedAt.sql`

**Interfaces:**
- Consumes: `Lots.Lot.ProducedAtLocationId` (Task 1).
- Produces: `Lots.Lot_Create` gains `@ProducedAtLocationId BIGINT = NULL` as its **last** parameter. Status row shape is unchanged: `Status, Message, NewId, MintedLotName`. Task 5 calls it through the named query.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0070_Cutover_EntryRoute/070_Lot_Create_ProducedAt.sql`:

```sql
-- =============================================
-- File:         0070_Cutover_EntryRoute/070_Lot_Create_ProducedAt.sql
-- Description:  Lot_Create's @ProducedAtLocationId -- the die cast machine the
--               cutover operator read off the paper tag.
--
--               The parameter defaults NULL so every existing caller (die cast
--               mint, machining/assembly mints, every other test file) is
--               unaffected; the omitted case is asserted here explicitly.
--
--               Validation is deliberately NARROW: active, and a die cast
--               machine. It does NOT re-check eligibility, because the picker's
--               fallback list is by definition ineligible -- gating on
--               eligibility would reject exactly the picks the fallback exists
--               to allow.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/070_Lot_Create_ProducedAt.sql';
GO

DECLARE @U      BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Item   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MachDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @Facility BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                            INNER JOIN Location.LocationTypeDefinition d
                                    ON d.Id = l.LocationTypeDefinitionId
                            WHERE d.Code = N'Facility' AND l.DeprecatedAt IS NULL
                            ORDER BY l.Id);

-- Pre-flight: this file uses fixed LOT names, so a failed run can strand them.
DECLARE @Stale TABLE (Id BIGINT);
INSERT INTO @Stale SELECT Id FROM Lots.Lot WHERE LotName IN (N'ZZPA-0001', N'ZZPA-0002');
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId  IN (SELECT Id FROM @Stale)
                                        OR DescendantLotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.Lot                WHERE Id IN (SELECT Id FROM @Stale);

DELETE FROM Location.Location WHERE Code = N'ZZPA-M01';
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder, CreatedAt)
VALUES (@MachDef, @Facility, N'Machine 99', N'ZZPA-M01', 990, SYSUTCDATETIME());
DECLARE @Mach BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZPA-M01');

CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- (1) A valid die cast machine is accepted and written.
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 12, @AppUserId = @U,
    @LotName = N'ZZPA-0001', @ProducedAtLocationId = @Mach;
DECLARE @Lot1 BIGINT = (SELECT NewId FROM #C);
DECLARE @d1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] valid die cast machine accepted',
    @Expected = N'1', @Actual = @d1;

DECLARE @d2 NVARCHAR(20) = (SELECT CAST(ProducedAtLocationId AS NVARCHAR(20))
                            FROM Lots.Lot WHERE Id = @Lot1);
DECLARE @d2e NVARCHAR(20) = CAST(@Mach AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] machine written to the LOT',
    @Expected = @d2e, @Actual = @d2;

-- (2) The LotCreated event JSON carries a resolved-name ProducedAt object.
DECLARE @Json NVARCHAR(MAX) = (SELECT TOP 1 NewValue FROM Lots.LotEventLog
                               WHERE LotId = @Lot1 ORDER BY Id);
DECLARE @d3 NVARCHAR(100) = JSON_VALUE(@Json, N'$.ProducedAt.Code');
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] event JSON carries the machine code',
    @Expected = N'ZZPA-M01', @Actual = @d3;

DECLARE @d4 NVARCHAR(200) = JSON_VALUE(@Json, N'$.ProducedAt.Name');
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] event JSON carries the machine name',
    @Expected = N'Machine 99', @Actual = @d4;

-- (3) The audit Description names the machine, beside the existing tool clause.
DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Lots.LotEventLog
                               WHERE LotId = @Lot1 ORDER BY Id);
EXEC test.Assert_Contains @TestName = N'[ProducedAt] audit description names the machine',
    @HaystackStr = @Desc, @NeedleStr = N'Machine 99';

-- (4) Omitted (the default) leaves the column NULL and the JSON key absent.
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 12, @AppUserId = @U,
    @LotName = N'ZZPA-0002';
DECLARE @Lot2 BIGINT = (SELECT NewId FROM #C);
DECLARE @d5 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] omitted parameter still creates',
    @Expected = N'1', @Actual = @d5;

DECLARE @d6 NVARCHAR(20) = (SELECT CAST(ProducedAtLocationId AS NVARCHAR(20))
                            FROM Lots.Lot WHERE Id = @Lot2);
EXEC test.Assert_IsNull @TestName = N'[ProducedAt] omitted leaves the column NULL', @Value = @d6;

DECLARE @Json2 NVARCHAR(MAX) = (SELECT TOP 1 NewValue FROM Lots.LotEventLog
                                WHERE LotId = @Lot2 ORDER BY Id);
DECLARE @d7 NVARCHAR(100) = JSON_VALUE(@Json2, N'$.ProducedAt.Code');
EXEC test.Assert_IsNull @TestName = N'[ProducedAt] omitted writes no ProducedAt key', @Value = @d7;

-- (5) A location that is not a die cast machine is rejected, and no LOT is made.
DECLARE @BeforeCount INT = (SELECT COUNT(*) FROM Lots.Lot);
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 12, @AppUserId = @U,
    @ProducedAtLocationId = @Line;      -- a production LINE, not a machine
DECLARE @d8 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] non-machine location rejected',
    @Expected = N'0', @Actual = @d8;

DECLARE @d9 NVARCHAR(500) = (SELECT Message FROM #C);
EXEC test.Assert_Contains @TestName = N'[ProducedAt] rejection message names the rule',
    @HaystackStr = @d9, @NeedleStr = N'die cast machine';

DECLARE @d10 NVARCHAR(10) = (SELECT CAST(COUNT(*) - @BeforeCount AS NVARCHAR(10)) FROM Lots.Lot);
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] rejection creates no LOT',
    @Expected = N'0', @Actual = @d10;

-- (6) A deprecated machine is rejected.
UPDATE Location.Location SET DeprecatedAt = SYSUTCDATETIME() WHERE Id = @Mach;
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 12, @AppUserId = @U,
    @ProducedAtLocationId = @Mach;
DECLARE @d11 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] deprecated machine rejected',
    @Expected = N'0', @Actual = @d11;
UPDATE Location.Location SET DeprecatedAt = NULL WHERE Id = @Mach;

DROP TABLE #C;

-- Teardown. LotGenealogyClosure BEFORE the LOTs (Msg 547 otherwise), and the
-- LOTs before the machine they reference.
DELETE FROM Lots.LotEventLog WHERE LotId IN (@Lot1, @Lot2);
DELETE FROM Lots.LotMovement WHERE LotId IN (@Lot1, @Lot2);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (@Lot1, @Lot2);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (@Lot1, @Lot2)
                                        OR DescendantLotId IN (@Lot1, @Lot2);
DELETE FROM Lots.Lot WHERE Id IN (@Lot1, @Lot2);
DELETE FROM Location.Location WHERE Code = N'ZZPA-M01';
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd sql/tests && powershell -NoProfile -File Run-Tests.ps1 -Filter "0070"
```

Expected: the file errors with `Lots.Lot_Create has too many arguments specified` (or `@ProducedAtLocationId is not a parameter`), and `Run-Tests.ps1` exits 1.

- [ ] **Step 3: Add the parameter and the failure-log context**

In `sql/migrations/repeatable/R__Lots_Lot_Create.sql`:

Append the parameter after `@CastDate` in the signature:

```sql
    @CastDate           DATE          = NULL,  -- cutover: date read off the physical LTT. Drives FIFO for migrated stock. NULL for a normal mint.
    @ProducedAtLocationId BIGINT      = NULL   -- cutover: the die cast machine off the tag (0082). NULL for every normal mint.
```

Add it to the `@Params` JSON so a rejection's failure log records what was attempted — find the `FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)` that closes `@Params` and extend the select list:

```sql
               @EntryRouteSequence AS EntryRouteSequence, @CastDate AS CastDate,
               @ProducedAtLocationId AS ProducedAtLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
```

- [ ] **Step 4: Add the validation, before `BEGIN TRANSACTION`**

Immediately after the `@CastDate is in the future` block (the last member of the `-- ---- 7b. Cutover params (0080).` group) and **before** the `-- ===== Mutation (atomic) =====` / `BEGIN TRANSACTION` line, insert:

```sql
        -- ---- 7c. Cutover machine (0082). Same pre-transaction placement and
        --          the same reason: a ROLLBACK inside a proc invoked via
        --          INSERT-EXEC raises Msg 3915.
        --          NARROW ON PURPOSE -- active, and a die cast machine. It does
        --          NOT re-check Parts.ItemLocation eligibility: the picker falls
        --          back to every machine when a part has no machine-tier row, so
        --          an eligibility gate here would reject exactly the picks that
        --          fallback exists to allow.
        IF @ProducedAtLocationId IS NOT NULL
           AND NOT EXISTS (SELECT 1
                           FROM Location.Location l
                           INNER JOIN Location.LocationTypeDefinition ltd
                                   ON ltd.Id = l.LocationTypeDefinitionId
                           WHERE l.Id = @ProducedAtLocationId
                             AND l.DeprecatedAt IS NULL
                             AND ltd.Code = N'DieCastMachine')
        BEGIN
            SET @Message = N'Producing machine must be an active die cast machine.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
            RETURN;
        END
```

- [ ] **Step 5: Write the column on INSERT**

In the `INSERT INTO Lots.Lot (…)` column list, append after `EntryRouteSequence, CastDate`:

```sql
            EntryRouteSequence, CastDate, ProducedAtLocationId
        )
```

and in the matching `VALUES (…)` list, after `@EntryRouteSequence, @CastDate`:

```sql
            @EntryRouteSequence, @CastDate,        -- 0080: cutover entry point + cast date
            @ProducedAtLocationId                  -- 0082: cutover die cast machine
        );
```

- [ ] **Step 6: Extend the audit Description and the `NewValue` JSON**

In the `-- ----- Audit (resolved-FK JSON + readable Description) -----` block, add two scalar declarations beside the existing `@ToolCode` / `@CavityNum` ones:

```sql
        DECLARE @MachineName NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @ProducedAtLocationId);
        DECLARE @MachineArea NVARCHAR(200) = (SELECT p.Name FROM Location.Location m
                                              INNER JOIN Location.Location p ON p.Id = m.ParentLocationId
                                              WHERE m.Id = @ProducedAtLocationId);
```

Add the machine clause beside the existing `@ToolSuffix`:

```sql
        -- Machine prose: the area disambiguates, because machine Names repeat
        -- across die cast areas (four 'Machine 01's in the real plant).
        DECLARE @MachineSuffix NVARCHAR(200) =
            CASE WHEN @ProducedAtLocationId IS NOT NULL
                 THEN N'; Machine ' + ISNULL(@MachineArea, N'?') + N' ' + ISNULL(@MachineName, N'?')
                 ELSE N'' END;
```

Append it to `@ActivityRaw`, after `@ToolSuffix`:

```sql
            + @ToolSuffix + @MachineSuffix;
```

And add the resolved-name object to `@NewValue`, after the `Status` entry. `FOR JSON` omits a key whose subquery yields NULL, so a LOT with no machine produces exactly the JSON it produces today:

```sql
                JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name
                            FROM Lots.LotStatusCode sc WHERE sc.Id = l.LotStatusId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status,
                JSON_QUERY((SELECT pl.Id, pl.Code, pl.Name
                            FROM Location.Location pl WHERE pl.Id = l.ProducedAtLocationId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ProducedAt
```

- [ ] **Step 7: Update the proc header**

Bump `-- Version:     1.5` to `1.6`, set `-- Modified:   2026-09-14`, and add to the description block, above the `v1.5` paragraph:

```
--              v1.6 (2026-09-14, migration 0082): @ProducedAtLocationId -- the
--              die cast machine the cutover operator read off the paper tag.
--              Defaults NULL so every existing caller is unaffected. Validated
--              BEFORE BEGIN TRANSACTION as an active DieCastMachine location;
--              deliberately NOT re-checked against Parts.ItemLocation, because
--              the picker falls back to every machine for a part with no
--              machine-tier row. Written to the column and echoed into the
--              LotCreated NewValue JSON as a resolved-name ProducedAt object.
```

- [ ] **Step 8: Run the tests and watch them pass**

```bash
cd sql/tests && powershell -NoProfile -File Run-Tests.ps1 -Filter "0070"
```

Expected: all twelve `[ProducedAt]` assertions from `070_…` PASS, alongside Tasks 1 and 2.

- [ ] **Step 9: Run the FULL suite — this proc has many callers**

```bash
cd sql/tests && powershell -NoProfile -File Run-Tests.ps1
```

Expected: zero failures. `Lot_Create` is called by die cast, trim, machining, assembly and cutover paths; an optional trailing parameter must not disturb any of them. If the run exits 1 with zero reported failures, a file's `sqlcmd` errored — read the red output rather than trusting the summary.

- [ ] **Step 10: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Create.sql sql/tests/0070_Cutover_EntryRoute/070_Lot_Create_ProducedAt.sql
git commit -m "feat(sql): Lot_Create records the producing die cast machine"
```

---

## Task 4: Named query + `getDieCastMachineDropdown`

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/location/DieCastMachine_ListForItem/query.sql`
- Create: `ignition/projects/Core/ignition/named-query/location/DieCastMachine_ListForItem/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py`

**Interfaces:**
- Consumes: `Location.Location_ListDieCastMachinesForItem` (Task 2).
- Produces: `BlueRidge.Location.Location.getDieCastMachineDropdown(itemId, _refreshToken=None)` → `list[dict]` of `{"label": "<AreaName> - <MachineName>", "value": <LocationId int>}`, always a list, never `None`. Tasks 5 and 6 call it.

- [ ] **Step 1: Create the named query**

`ignition/projects/Core/ignition/named-query/location/DieCastMachine_ListForItem/query.sql`:

```sql
EXEC Location.Location_ListDieCastMachinesForItem @ItemId = :itemId
```

`ignition/projects/Core/ignition/named-query/location/DieCastMachine_ListForItem/resource.json` — copied from the sibling `Location_ListMachiningDestinationsForItem`, which has the identical single-BIGINT-parameter shape:

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [
    "query.sql"
  ],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [
      {
        "zone": "",
        "role": ""
      }
    ],
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-09-14T12:00:00Z"
    },
    "parameters": [
      {
        "type": "Parameter",
        "identifier": "itemId",
        "sqlType": 3
      }
    ]
  }
}
```

`type: "Query"` because this returns a result set. `sqlType: 3` is this repo's BIGINT parameter type — copy it, don't guess.

- [ ] **Step 2: Add the wrapper**

Append to the end of `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py` (after `getStockDestinationOrEmpty`):

```python
def getDieCastMachineDropdown(itemId, _refreshToken=None):
    """Die cast machines the cutover scan offers for a part, shaped for
       ia.input.dropdown: [{label: 'Die Cast 1 - Machine 10', value: <LocationId>}].
       Always a list, never None.

       The AREA prefix is not decoration. Machine Names repeat across die cast
       areas -- DC1-M01 and DC2-M01 are both 'Machine 01' -- so a Name-only
       label shows four identical rows.

       ASCII separator on purpose: the same string is echoed into SQL audit
       prose, and sqlcmd reads .sql files in the Windows codepage, where a
       middot becomes mojibake.

       The proc falls back to EVERY active machine when the part carries no
       machine-tier eligibility row, so an empty list here means no die cast
       machines are configured at all.

       _refreshToken is ignored -- runScript bindings pass a bumped token to
       force a re-read (runScript caches on args)."""
    itemId = _u(itemId)
    try:
        rows = BlueRidge.Common.Db.execList(
            "location/DieCastMachine_ListForItem", {"itemId": itemId}) or []
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("getDieCastMachineDropdown failed: %s" % str(e),
                                  level="warn")
        return []
    options = []
    for r in rows:
        area = r.get("AreaName") or ""
        name = r.get("Name") or r.get("Code") or ""
        options.append({"label": ("%s - %s" % (area, name)) if area else name,
                        "value": r.get("Id")})
    return options
```

Note `itemId` is **not** guarded with an early `return []` on `None` — a NULL item is a legitimate call that the proc answers with the full machine list (first paint, before a part is picked).

- [ ] **Step 3: Update the module header**

In the same file, bump `# Version:` to the next number, add `getDieCastMachineDropdown(itemId) -> list[{label, value}]` to the read-surface list at the top, and append a change-log line:

```
#   2026-09-14 - 1.9 - Cutover scan: getDieCastMachineDropdown(itemId) - die
#                      cast machines for a part via
#                      location/DieCastMachine_ListForItem. Label carries the
#                      AREA because machine Names repeat across areas.
```

- [ ] **Step 4: Scan the gateway**

```bash
powershell -NoProfile -File scan.ps1
```

Expected: a JSON body with `"scanActive": true` and a fresh `lastScanTimestamp`.

- [ ] **Step 5: Verify the wrapper against the live gateway**

There is no unit-test harness for Jython project scripts. Verify through the database instead — confirm the proc returns what the wrapper will reshape:

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -W -s"|" -Q "SET NOCOUNT ON; DECLARE @I BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = '12232-6MA -0000'); EXEC Location.Location_ListDieCastMachinesForItem @ItemId = @I;"
```

Expected on Dev: one row — `DC1-M10 | Machine 10 | DC1 | Die Cast 1 | 1`. The wrapper will turn that into `{"label": "Die Cast 1 - Machine 10", "value": <id>}`.

Then the fallback part:

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -W -s"|" -Q "SET NOCOUNT ON; DECLARE @I BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = '12231-6MA -0000'); EXEC Location.Location_ListDieCastMachinesForItem @ItemId = @I;"
```

Expected on Dev: 22 rows, every one with `IsEligible = 0`.

If either call fails with "Could not find stored procedure", the repeatable has not been applied to `MPP_MES_Dev` — apply it with `sqlcmd -S localhost -d MPP_MES_Dev -E -C -i sql/migrations/repeatable/R__Location_Location_ListDieCastMachinesForItem.sql`. Do **not** run `Reset-DevDatabase.ps1` against `MPP_MES_Dev`; it is hand-built and unbacked.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/location/DieCastMachine_ListForItem ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py
git commit -m "feat(ignition): die cast machine dropdown source for the cutover scan"
```

---

## Task 5: Carry the machine through the Ignition script layer

**Files:**
- Modify: `ignition/projects/Core/ignition/named-query/lots/Lot_Create/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/lots/Lot_Create/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Cutover/Scan/code.py`

**Interfaces:**
- Consumes: `Lots.Lot_Create @ProducedAtLocationId` (Task 3); `BlueRidge.Location.Location.getDieCastMachineDropdown` (Task 4).
- Produces: `BlueRidge.Cutover.Scan.loadSession(lineLocationId, itemId, entryRoleCode, machineLocationId, session)` — the fourth positional argument is now a **LocationId**, not a string. Session state `session.custom.cutover.session` carries `machineLocationId` (BIGINT or None) and `machineName` (str). Task 6 binds to both.

- [ ] **Step 1: Add the parameter to the `Lot_Create` named query**

Append to `ignition/projects/Core/ignition/named-query/lots/Lot_Create/query.sql`:

```sql
    @CastDate           = :castDate,
    @ProducedAtLocationId = :producedAtLocationId
```

(The existing last line is `@CastDate = :castDate` with no trailing comma — add the comma, then the new line.)

In `resource.json`, append to the `parameters` array:

```json
      {
        "type": "Parameter",
        "identifier": "producedAtLocationId",
        "sqlType": 3
      }
```

- [ ] **Step 2: Forward it from `BlueRidge.Lots.Lot.create`**

In `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py`, in the `params` dict inside `create`, after the `"castDate"` entry:

```python
        "castDate":           d.get("castDate"),
        # Cutover scan: the die cast machine off the paper tag (0082). None for
        # every normal mint, where the creating terminal's parent IS the machine.
        "producedAtLocationId": d.get("producedAtLocationId"),
```

Add `producedAtLocationId` to the docstring's field list on the same line as `entryRouteSequence, castDate`.

- [ ] **Step 3: Reshape the cutover session state**

In `ignition/projects/Core/ignition/script-python/BlueRidge/Cutover/Scan/code.py`, in `_EMPTY`, replace the `machineNumber` key:

```python
                "toolIsAmbiguous": False,
                "machineLocationId": None, "machineName": ""},
```

- [ ] **Step 4: Resolve the machine in `loadSession`**

Change the signature:

```python
def loadSession(lineLocationId, itemId, entryRoleCode, machineLocationId, session):
```

Replace the `machineNumber = _u(machineNumber)` line with:

```python
    machineLocationId = _u(machineLocationId)
```

After the existing `tools = BlueRidge.Tools.Tool.listForItem(itemId)` block and before `st = getState(session)`, insert:

```python
    # The machine's display label comes from the SAME list the operator picked
    # from, so the header can never disagree with the dropdown -- and the lookup
    # doubles as re-validation: if the part changed and the previously chosen
    # machine is no longer offered, the match fails and the pick clears rather
    # than silently persisting a stale machine.
    machineName = ""
    if machineLocationId is not None:
        for opt in BlueRidge.Location.Location.getDieCastMachineDropdown(itemId):
            if opt.get("value") == machineLocationId:
                machineName = opt.get("label") or ""
                break
        if not machineName:
            machineLocationId = None
```

Then in the `st["session"] = {...}` dict, replace the `machineNumber` entry:

```python
        "machineLocationId": machineLocationId, "machineName": machineName,
```

- [ ] **Step 5: Pass it from `addBasket`**

In `addBasket`'s `BlueRidge.Lots.Lot.create({...})` payload, after the `"castDate"` entry:

```python
        "castDate": e.get("castDate"),
        "producedAtLocationId": s.get("machineLocationId"),
```

Leave `addBox` untouched — a received purchased component was never cast here.

- [ ] **Step 6: Update the module header**

Bump `# Version:` to `1.3`, extend the `loadSession` line in the public-surface block to show the new argument name, and append:

```
#   2026-09-14 - 1.3 - Machine # is a die cast machine LocationId, not free
#                      text. session.machineNumber -> machineLocationId +
#                      machineName (the dropdown's own label, re-resolved on
#                      load so a part change clears a stale machine).
#                      addBasket passes producedAtLocationId; addBox does not.
```

- [ ] **Step 7: Scan and verify nothing else calls the old signature**

```bash
powershell -NoProfile -File scan.ps1
grep -rn "machineNumber" ignition/projects/ --include=*.py --include=*.json
```

Expected from the grep: only the three `_CutoverScan` `view.json` files, which Task 6 fixes. Any hit in a `.py` file is a miss — fix it before committing.

- [ ] **Step 8: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/lots/Lot_Create ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Cutover/Scan/code.py
git commit -m "feat(cutover): carry the die cast machine as a LocationId through to Lot_Create"
```

---

## Task 6: The dropdown in the three cutover views

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/session-props/props.json`
- Modify: `.../views/BlueRidge/Views/ShopFloor/_CutoverScan/Desktop/view.json`
- Modify: `.../views/BlueRidge/Views/ShopFloor/_CutoverScan/Tablet/view.json`
- Modify: `.../views/BlueRidge/Views/ShopFloor/_CutoverScan/Phone/view.json`

**Interfaces:**
- Consumes: `BlueRidge.Location.Location.getDieCastMachineDropdown` (Task 4); `session.custom.cutover.session.machineLocationId` / `.machineName` and `loadSession`'s new fourth argument (Task 5).
- Produces: nothing downstream.

**Before you start:** these are **existing** views. Prefer editing them in Designer. If you file-edit, Designer must be closed first, and you must `scan.ps1` afterwards. The Phone view serializes `=` as `=`, so anchor literal matches on escape-free substrings.

- [ ] **Step 1: Reshape the session property**

In `session-props/props.json`, inside `custom.cutover.session`, replace:

```json
        "toolIsAmbiguous": false,
        "machineNumber": ""
```

with:

```json
        "toolIsAmbiguous": false,
        "machineLocationId": null,
        "machineName": ""
```

- [ ] **Step 2: Reshape `setupDraft` in all three views**

Near the top of each `view.json` (around line 9), inside the `custom.setupDraft` default object, replace `"machineNumber": ""` with:

```json
      "machineLocationId": null
```

The default must exist — a binding that reads a custom property which does not yet exist renders a Component Error.

- [ ] **Step 3: Replace the text-field with a dropdown**

In each view, find the component named `MachineNumberInput` and replace the whole component object with:

```json
{
  "type": "ia.input.dropdown",
  "meta": {
    "name": "MachineDropdown"
  },
  "props": {
    "placeholder": "Pick the machine",
    "style": {
      "minHeight": "44px"
    }
  },
  "propConfig": {
    "props.options": {
      "binding": {
        "type": "expr",
        "config": {
          "expression": "runScript(\"BlueRidge.Location.Location.getDieCastMachineDropdown\", 0, {view.custom.setupDraft.itemId})"
        }
      }
    },
    "props.value": {
      "binding": {
        "type": "property",
        "config": {
          "path": "view.custom.setupDraft.machineLocationId",
          "bidirectional": true
        }
      }
    }
  }
}
```

`bidirectional: true` goes **inside** `config`, not beside it — outside, it is silently ignored and the binding stays one-way. The sibling `ItemDropdown` directly above is the model for the whole shape; match its `minHeight`.

Leave the `MachineFieldLabel` above it reading **Machine #**.

- [ ] **Step 4: Repoint the header label**

In each view, find the label named `MachineValue` and change its `props.text` binding path:

```json
"path": "session.custom.cutover.session.machineName"
```

Leave its `pf-kpi-value-mono` class alone for now — Step 7 decides whether the longer string needs anything.

- [ ] **Step 5: Repoint the two setup scripts**

In each view's `root.events` / custom-method scripts (near the bottom of the file), two inline scripts mention `machineNumber`:

The **Start / Apply** script — change the `loadSession` argument:

```
d.get("machineLocationId")
```

(replacing `d.get("machineNumber")`; the argument position is unchanged).

The **Change** script that reseeds `setupDraft` from session state — change the dict entry:

```
"machineLocationId": s.get("machineLocationId")
```

- [ ] **Step 6: Scan and confirm nothing references the old name**

```bash
powershell -NoProfile -File scan.ps1
grep -rn "machineNumber" ignition/projects/
```

Expected: no output at all.

Then confirm every file still parses:

```bash
for f in Desktop Tablet Phone; do python -c "import json,io; json.load(io.open('ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/_CutoverScan/$f/view.json', encoding='utf-8')); print('$f OK')"; done
```

Expected: three `OK` lines. A view that fails to parse renders blank with `getObjectForSave: expected string, got null` in the wrapper log.

- [ ] **Step 7: Verify on screen**

Open `/shop-floor/cutover-scan` in a Perspective session (the gateway's Perspective trial may need resetting first — the Trial Expired page means the gateway trial has lapsed, not that the change is broken).

Check, at each of the three breakpoints:

1. Pick line `MA1-5GOF` and part `12232-6MA -0000` → Machine dropdown offers exactly `Die Cast 1 - Machine 10`.
2. Change the part to `12231-6MA -0000` (no machine-tier row) → the dropdown offers all 22 machines, and the previously selected machine has cleared.
3. Pick a machine, Start the session → the header's MACHINE reads `Die Cast 1 - Machine 10` and does not crowd its neighbours. If it does crowd at a breakpoint, only then adjust that view's KV cell.
4. Press Change → the setup form reopens with the machine still selected.

- [ ] **Step 8: Verify the value reached the database**

Scan one basket, then:

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -W -s"|" -Q "SET NOCOUNT ON; SELECT TOP 3 l.Id, l.LotName, l.ProducedAtLocationId, loc.Code, loc.Name FROM Lots.Lot l LEFT JOIN Location.Location loc ON loc.Id = l.ProducedAtLocationId ORDER BY l.Id DESC;"
```

Expected: the newest LOT carries the machine's `LocationId`, `Code` and `Name`.

And the audit JSON:

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -W -Q "SET NOCOUNT ON; SELECT TOP 1 Description, NewValue FROM Lots.LotEventLog ORDER BY Id DESC;"
```

Expected: `Description` ends with `; Tool …, Cavity …; Machine Die Cast 1 Machine 10`, and `NewValue` contains a `ProducedAt` object with `Id` / `Code` / `Name`.

- [ ] **Step 9: Check for pickled runtime data before committing**

Saving a view in Designer with live data bound can embed DB rows into `view.json`:

```bash
git diff --stat ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/_CutoverScan/
```

Expected: small diffs — tens of lines, not hundreds. A large diff means runtime data got pickled; inspect and strip it.

- [ ] **Step 10: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/session-props/props.json ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/_CutoverScan
git commit -m "feat(cutover): Machine # is an eligibility-driven dropdown, not free text"
```

---

## Task 6b: LOT Search finds cutover LOTs by machine

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_SearchAdvanced.sql`
- Create: `sql/tests/0067_Lot_SearchAdvanced/060_cutover_machine.sql`

**Interfaces:**
- Consumes: `Lots.Lot.ProducedAtLocationId` (Task 1), written by `Lot_Create` (Task 3).
- Produces: **no signature change.** `Lots.Lot_SearchAdvanced`'s parameter list and its result-set column list are both unchanged — only how `@MachineLocationId` matches, and how `OriginMachineName` is resolved. The `#LS` temp-table shape in the existing tests stays valid.

**Why.** `Lot_SearchAdvanced` already has an origin-machine dimension, and it resolves entirely through `Workorder.DieCastContribution` — the per-shift good-piece rows stamped at the press. A **cutover LOT has no contribution rows at all**: it is migrated stock, and `addBasket` calls `Lot_Create` and nothing else. So without this task the machine we just captured is unreachable from the one screen that asks for it, and `OriginMachineName` renders blank for every cutover basket.

This is **not** the live re-derivation the proc header warns against. That header rejects deriving the press from `LotMovement`, because movement drifts. `ProducedAtLocationId` is a value a human recorded off the tag and we stored — the same class of fact as a contribution row, captured by a different route. Contribution rows still win where a LOT has both.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0067_Lot_SearchAdvanced/060_cutover_machine.sql`:

```sql
-- =============================================
-- File:         0067_Lot_SearchAdvanced/060_cutover_machine.sql
-- Description:  A cutover LOT is findable by its die cast machine.
--
--               LOT Search resolves the origin machine through
--               Workorder.DieCastContribution -- the per-shift rows stamped at
--               the press. A cutover LOT has none: it is migrated stock whose
--               machine was read off the paper tag into
--               Lots.Lot.ProducedAtLocationId (migration 0082).
--
--               Both the FILTER and the DISPLAYED column must consider it, or
--               the captured machine is invisible on the one screen that asks
--               the question. Contribution rows still take precedence where a
--               LOT has both.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0067_Lot_SearchAdvanced/060_cutover_machine.sql';
GO

DECLARE @U      BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Item   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MachDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @Facility BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                            INNER JOIN Location.LocationTypeDefinition d
                                    ON d.Id = l.LocationTypeDefinitionId
                            WHERE d.Code = N'Facility' AND l.DeprecatedAt IS NULL
                            ORDER BY l.Id);

-- Pre-flight: fixed LOT name, so a failed run can strand it.
DECLARE @Stale TABLE (Id BIGINT);
INSERT INTO @Stale SELECT Id FROM Lots.Lot WHERE LotName = N'ZZCM-0001';
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId  IN (SELECT Id FROM @Stale)
                                        OR DescendantLotId IN (SELECT Id FROM @Stale);
DELETE FROM Lots.Lot                WHERE Id IN (SELECT Id FROM @Stale);
DELETE FROM Location.Location WHERE Code = N'ZZCM-M01';

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder, CreatedAt)
VALUES (@MachDef, @Facility, N'Machine 77', N'ZZCM-M01', 977, SYSUTCDATETIME());
DECLARE @Mach BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZCM-M01');

CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
CREATE TABLE #LS (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT,
    LotStatusId BIGINT, PieceCount INT, VendorLotNumber NVARCHAR(100),
    CurrentLocationId BIGINT, CreatedAt DATETIME2(3), ItemPartNumber NVARCHAR(100),
    LotStatusCode NVARCHAR(50), LotOriginTypeCode NVARCHAR(50),
    CurrentLocationName NVARCHAR(200), LastOperationName NVARCHAR(100),
    ToolCode NVARCHAR(50), CavityCode NVARCHAR(4), OriginMachineName NVARCHAR(200),
    TotalCount INT
);

-- Fixture: a cutover-style LOT -- ProducedAtLocationId set, and deliberately NO
-- Workorder.DieCastContribution rows, exactly as addBasket creates it.
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 40, @AppUserId = @U,
    @LotName = N'ZZCM-0001', @ProducedAtLocationId = @Mach;
DECLARE @Lot BIGINT = (SELECT NewId FROM #C);
DECLARE @e0 NVARCHAR(20) = CAST(@Lot AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[CutoverMachine] fixture LOT created', @Value = @e0;

-- Guard the premise: the fixture really has no contribution rows.
DECLARE @e1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
                            FROM Workorder.DieCastContribution WHERE LotId = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[CutoverMachine] cutover LOT has no DieCastContribution rows',
    @Expected = N'0', @Actual = @e1;

-- (1) The machine FILTER finds it.
DELETE FROM #LS;
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @MachineLocationId = @Mach;
DECLARE @e2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #LS WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[CutoverMachine] machine filter finds the cutover LOT',
    @Expected = N'1', @Actual = @e2;

-- (2) The DISPLAYED column names the machine, not blank.
DECLARE @e3 NVARCHAR(200) = (SELECT OriginMachineName FROM #LS WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[CutoverMachine] origin machine column shows the recorded machine',
    @Expected = N'Machine 77', @Actual = @e3;

-- (3) Filtering by a DIFFERENT machine must not return it.
DECLARE @Other BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                         INNER JOIN Location.LocationTypeDefinition d
                                 ON d.Id = l.LocationTypeDefinitionId
                         WHERE d.Code = N'DieCastMachine' AND l.DeprecatedAt IS NULL
                           AND l.Id <> @Mach ORDER BY l.Id);
DELETE FROM #LS;
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @MachineLocationId = @Other;
DECLARE @e4 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #LS WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[CutoverMachine] another machine does not match it',
    @Expected = N'0', @Actual = @e4;

-- (4) A LOT with neither source must never match -- the new OR must not widen
--     the filter into "everything".
DELETE FROM #LS;
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @MachineLocationId = @Mach;
DECLARE @e5 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
                            FROM #LS ls
                            INNER JOIN Lots.Lot l2 ON l2.Id = ls.Id
                            WHERE l2.ProducedAtLocationId IS NULL
                              AND NOT EXISTS (SELECT 1 FROM Workorder.DieCastContribution d2
                                              WHERE d2.LotId = l2.Id AND d2.CellLocationId = @Mach));
EXEC test.Assert_IsEqual @TestName = N'[CutoverMachine] LOTs with no machine at all never match',
    @Expected = N'0', @Actual = @e5;

DROP TABLE #C; DROP TABLE #LS;

-- Teardown: closure before LOTs, LOTs before the machine they reference.
DELETE FROM Lots.LotEventLog        WHERE LotId = @Lot;
DELETE FROM Lots.LotMovement        WHERE LotId = @Lot;
DELETE FROM Lots.LotStatusHistory   WHERE LotId = @Lot;
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @Lot OR DescendantLotId = @Lot;
DELETE FROM Lots.Lot                WHERE Id = @Lot;
DELETE FROM Location.Location WHERE Code = N'ZZCM-M01';
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd sql/tests && powershell -NoProfile -File Run-Tests.ps1 -Filter "0067" -DatabaseName <your assigned DB>
```

Expected: assertions (1) and (2) FAIL — the filter returns `0` where `1` is expected, and `OriginMachineName` comes back NULL instead of `Machine 77`. The premise guard and (3) and (4) should already pass.

- [ ] **Step 3: Widen the filter predicate**

In `sql/migrations/repeatable/R__Lots_Lot_SearchAdvanced.sql`, replace the `@MachineLocationId` clause in the `WHERE`:

```sql
      -- Origin machine has TWO recorded sources, and a LOT has at most one of
      -- them. A normally-produced LOT accumulates DieCastContribution rows at
      -- the press. A CUTOVER LOT has none -- it is migrated stock whose machine
      -- was read off the paper tag into Lot.ProducedAtLocationId (0082).
      -- Both are RECORDED values; neither is the live LotMovement re-derivation
      -- this proc's header rejects.
      AND (@MachineLocationId IS NULL
           OR l.ProducedAtLocationId = @MachineLocationId
           OR EXISTS (
              SELECT 1 FROM Workorder.DieCastContribution dm
              WHERE dm.LotId = l.Id AND dm.CellLocationId = @MachineLocationId))
```

- [ ] **Step 4: Make the displayed column fall back**

Add a join beside the existing `LEFT JOIN Tools.ToolCavity tc` line:

```sql
    LEFT  JOIN Location.Location  pal ON pal.Id = l.ProducedAtLocationId
```

and change the projected column (currently `press.MachineName AS OriginMachineName,`):

```sql
        COALESCE(press.MachineName, pal.Name) AS OriginMachineName,
```

Contribution rows take precedence: where a LOT has both, the press it actually ran on wins over anything typed at a cutover terminal.

- [ ] **Step 5: Update the proc header**

Bump `-- Version:     1.0` to `1.1`, set `-- Modified:    2026-09-14`, and replace the paragraph beginning `Origin machine is DieCastContribution.CellLocationId` with:

```
--              Origin machine has TWO recorded sources. Normally-produced LOTs:
--              DieCastContribution.CellLocationId (the press, stamped at write
--              time by migration 0061). Cutover LOTs: Lot.ProducedAtLocationId
--              (0082), read off the paper tag -- they have no contribution rows
--              at all, so without it the captured machine is unreachable here.
--              Contribution wins where a LOT has both. Still deliberately NOT
--              derived from LotMovement: 0061 exists to stop live re-derivation
--              of the press, and both sources above are RECORDED, not derived.
```

- [ ] **Step 6: Run the tests and watch them pass**

```bash
cd sql/tests && powershell -NoProfile -File Run-Tests.ps1 -Filter "0067" -DatabaseName <your assigned DB>
```

Expected: all six `[CutoverMachine]` assertions PASS, and every pre-existing `0067_Lot_SearchAdvanced` test still passes — the parameter list and result-set shape did not change, so `010_filters`, `020_date_boundary`, `030_origin_conditional` and especially `050_signature_parity` must be untouched.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_SearchAdvanced.sql sql/tests/0067_Lot_SearchAdvanced/060_cutover_machine.sql
git commit -m "feat(sql): LOT Search finds cutover LOTs by their recorded die cast machine"
```

---

## Task 7: Full-suite regression and release readiness

**Files:**
- Create: `notes/2026-09-14_cutover-machine-verification.md`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: the verification record the release runbook cites.

- [ ] **Step 1: Run the entire SQL suite from a clean database**

```bash
cd sql/tests && powershell -NoProfile -File Run-Tests.ps1
```

Expected: zero failures, exit 0. This rebuilds `MPP_MES_Test` from migrations, so it also proves 0082 and both repeatables apply to a virgin database in order.

- [ ] **Step 2: Confirm the working tree is what you think it is**

```bash
git status --short
git log --oneline -7
```

Expected: six new commits (Tasks 1–6) on `jacques/working`. The shared working tree may hold other people's uncommitted files — confirm none of them were swept into your commits:

```bash
git show --stat HEAD~5 HEAD~4 HEAD~3 HEAD~2 HEAD~1 HEAD
```

- [ ] **Step 3: Write the verification note**

Create `notes/2026-09-14_cutover-machine-verification.md` recording: the Dev part numbers you exercised and what the dropdown offered for each; the LOT ids created and their `ProducedAtLocationId`; the audit Description and `NewValue` you read back; the full-suite result; and anything that behaved differently from the spec.

- [ ] **Step 4: Commit**

```bash
git add notes/2026-09-14_cutover-machine-verification.md
git commit -m "docs(cutover): verification record for the machine eligibility dropdown"
```

- [ ] **Step 5: Hand off to the release**

This change includes a schema migration, so it ships through the five-part production release — preview, rehearsal, execute with `-ExpectedPlan`, scoped git-verified exports, published instruction guide — as described in the spec's § 10. **That is a separate piece of work with its own runbook**; do not start it as part of this plan.

The exports it will need, Core first:

- Core: `location/DieCastMachine_ListForItem`, `lots/Lot_Create`, `BlueRidge/Location/Location`, `BlueRidge/Lots/Lot`, `BlueRidge/Cutover/Scan`
- SQL: migration `0082`, plus repeatables `R__Location_Location_ListDieCastMachinesForItem`, `R__Lots_Lot_Create`, `R__Lots_Lot_SearchAdvanced`, `R__Descriptions_ExtendedProperties`
- MPP: `session-props`, the three `_CutoverScan` views

Note for whoever builds the runbook: **the die-name change** (`Tools.Tool.Name` instead of `Code` in the die dropdown and header, Ignition-only, three `_CutoverScan` views + `Cutover/Scan` + `session-props`) may still be uncommitted in the working tree. Decide whether it rides along or ships separately before building the export.

---

## Notes for the implementer

**If a `Run-Tests.ps1` run exits 1 but reports zero failures**, a test file's `sqlcmd` errored outright — almost always teardown FK order. `Lots.LotGenealogyClosure` must be deleted before the LOTs it references (Msg 547), and locations must be deleted after everything referencing them.

**If `Run-Tests.ps1` fails to reset the database** with a "database in use" error, something holds a connection. Set it to single-user or close the offending session; do not retry in a loop.

**The gateway and `MPP_MES_Dev` are shared.** One gateway serves every worktree, and `MPP_MES_Dev` is hand-built with no backups. `scan.ps1` affects everyone's Designer. Never run `Reset-DevDatabase.ps1` against `MPP_MES_Dev`.

**`Run-Tests.ps1` targets `MPP_MES_Test` by default and DROPs it.** Never pass `-DatabaseName MPP_MES_Dev`.
