# Downtime codes scoped by OperationCategory — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task. Steps use checkbox (`- [x]`).

**Goal:** Replace `Oee.DowntimeReasonCode`'s single physical-Area FK with a nullable `OperationCategoryId` (DieCast / Trim / MachiningAssembly; NULL = plant-wide), so a downtime code shows at every area in its process category — a mechanical mirror of the shipped defect-code refactor (#1).

**Architecture:** Reuse the exact `Parts.OperationCategory` infrastructure and the #1 recipe. The committed #1 files are the concrete template for every task — this plan gives the DowntimeReasonCode-specific deltas: two extra dimensions (`DowntimeReasonTypeId`, `DowntimeSourceCodeId`) that stay untouched, a `CreatedByUserId` column, and a plant-floor downtime entry surface (`DowntimeManager`).

**Tech Stack:** SQL Server 2022 (versioned + repeatable migrations, `sqlcmd` test harness), Ignition 8.3 Named Queries, Jython, Perspective view.json.

**Spec:** `docs/superpowers/specs/2026-08-05-downtime-code-operation-category-scoping-design.md`
**#1 template (committed):** migration `0048_defect_code_operation_category.sql`; `R__Quality_DefectCode_{Create,Update,Get,List,Deprecate}.sql`; `quality/DefectCode_*` NQs; `sql/seeds/030_seed_defect_codes.sql`; `BlueRidge/Quality/DefectCode/code.py`; `sql/tests/0011_Quality_Spec/040_DefectCode_crud.sql`; the defect-code views.

## Global Constraints
- FDS-11-011 (no OUTPUT params; status-row procs end every path with `SELECT @Status,@Message[,@NewId]`; one result set; `RAISERROR` in CATCH). Audit Description `<SUBJECT> · <ACTION>` via `ufn_MidDot`/`ufn_TruncateActivity`; resolved-name FK sub-objects in Old/NewValue JSON. No business logic in Python (type→category map in SQL). ASCII-only seeds (byte-scan). Existing view.json = Designer-closed file edits + `scan.ps1`; new SQL/NQ/Python are safe edits.
- **Git safety:** stay on `jacques/working`; NO `git checkout`; explicit `git add <paths>`; no `Co-Authored-By`. **DB:** validate on a throwaway `MPP_MES_DowntimeCat`; never reset `MPP_MES_Dev`. **Migration number:** highest is `0050`; use `0051` (confirm free — no `0051` file exists yet).

## File Structure
- Create `sql/migrations/versioned/0051_downtime_code_operation_category.sql`
- Modify `R__Oee_DowntimeReasonCode_{Create,Update,Get,List}.sql`
- Modify `oee/DowntimeReasonCode_{Create,Update,Get,List}` NQ query.sql + resource.json
- Modify the downtime-code seed (find it: `grep -rl DowntimeReasonCode sql/seeds`)
- Modify `BlueRidge/Oee/DowntimeReasonCode/code.py`
- Modify the DowntimeReasonCode crud test (find it: `sql/tests/**/*DowntimeReasonCode*` or `*DowntimeCode*`)
- Designer views: `MPP_Config .../Popups/DowntimeCodeEditor`, `.../DowntimeCodeRow`, `.../Views/Oee/DowntimeCodes`; plant-floor `.../Popups/DowntimeManager` (+ `Views/ShopFloor/DowntimeEntry`)

---

### Task 1: Migration `0051` — add `OperationCategoryId`, backfill, drop `AreaLocationId`

**Files:** Create `sql/migrations/versioned/0051_downtime_code_operation_category.sql`

- [x] **Step 1:** Write the migration (verbatim mirror of `0048`, table `Oee.DowntimeReasonCode`):

```sql
-- ============================================================
-- Migration: 0051_downtime_code_operation_category.sql
-- Description: Scope downtime reason codes by process, not physical Area.
--   Add Oee.DowntimeReasonCode.OperationCategoryId (nullable FK -> Parts.OperationCategory)
--   + index; backfill from AreaLocationId (DC%->DieCast, TRIM%->Trim, MA%->MachiningAssembly,
--   else NULL=plant-wide); drop AreaLocationId (FK dynamic + index + column). Idempotent-guarded.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0051_downtime_code_operation_category')
BEGIN PRINT 'Migration 0051 already applied -- skipping.'; RETURN; END
GO

IF COL_LENGTH(N'Oee.DowntimeReasonCode', N'OperationCategoryId') IS NULL
    ALTER TABLE Oee.DowntimeReasonCode ADD OperationCategoryId BIGINT NULL
        CONSTRAINT FK_DowntimeReasonCode_OperationCategory REFERENCES Parts.OperationCategory(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DowntimeReasonCode_OperationCategoryId')
    CREATE INDEX IX_DowntimeReasonCode_OperationCategoryId ON Oee.DowntimeReasonCode (OperationCategoryId);
GO

IF COL_LENGTH(N'Oee.DowntimeReasonCode', N'AreaLocationId') IS NOT NULL
BEGIN
    DECLARE @DieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
    DECLARE @Trim    BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');
    DECLARE @MachAsm BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'MachiningAssembly');
    UPDATE drc
    SET OperationCategoryId =
        CASE WHEN loc.Code LIKE N'DC%'   THEN @DieCast
             WHEN loc.Code LIKE N'TRIM%' THEN @Trim
             WHEN loc.Code LIKE N'MA%'   THEN @MachAsm
             ELSE NULL END
    FROM Oee.DowntimeReasonCode drc
    LEFT JOIN Location.Location loc ON drc.AreaLocationId = loc.Id
    WHERE drc.OperationCategoryId IS NULL;
END
GO

DECLARE @fk SYSNAME = (
    SELECT fk.name FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.parent_object_id = OBJECT_ID(N'Oee.DowntimeReasonCode') AND c.name = N'AreaLocationId');
IF @fk IS NOT NULL EXEC(N'ALTER TABLE Oee.DowntimeReasonCode DROP CONSTRAINT ' + @fk);
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DowntimeReasonCode_AreaLocationId')
    DROP INDEX IX_DowntimeReasonCode_AreaLocationId ON Oee.DowntimeReasonCode;
GO
IF COL_LENGTH(N'Oee.DowntimeReasonCode', N'AreaLocationId') IS NOT NULL
    ALTER TABLE Oee.DowntimeReasonCode DROP COLUMN AreaLocationId;
GO

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES (N'0051_downtime_code_operation_category', N'DowntimeReasonCode scoped by OperationCategory (nullable, plant-wide=NULL); drop AreaLocationId.');
GO
PRINT 'Migration 0051 (downtime_code_operation_category) applied.';
GO
```
Note: if `IX_DowntimeReasonCode_AreaLocationId` doesn't exist under that name, the drop is a guarded no-op — fine.

- [x] **Step 2:** Reset `MPP_MES_DowntimeCat`, verify `COL_LENGTH('Oee.DowntimeReasonCode','OperationCategoryId')` non-null, `AreaLocationId` NULL.
- [x] **Step 3:** Commit `feat(oee): migration 0051 — DowntimeReasonCode.OperationCategoryId replaces AreaLocationId`.

---

### Task 2: `DowntimeReasonCode_Create` + `_Update` procs

**Files:** Modify `R__Oee_DowntimeReasonCode_Create.sql`, `R__Oee_DowntimeReasonCode_Update.sql`

**Deltas from the current procs (mirror `R__Quality_DefectCode_{Create,Update}` v3.0):**
- Param `@AreaLocationId BIGINT` → `@OperationCategoryId BIGINT = NULL` (nullable; **keep** `@DowntimeReasonTypeId`, `@DowntimeSourceCodeId`, `@IsExcused`, `@AppUserId`).
- Drop the "AreaLocationId required" clause from the required-param check (category optional). FK-check `Parts.OperationCategory` only when `@OperationCategoryId IS NOT NULL` (message mentions `OperationCategoryId`). Keep the ReasonType/SourceCode FK checks and the unique-code check.
- INSERT column `AreaLocationId` → `OperationCategoryId`.
- Audit: `@AreaName` → `@CatName = ISNULL((SELECT Name FROM Parts.OperationCategory WHERE Id=@OperationCategoryId),N'Plant-wide')`; subject parenthetical uses `@CatName`; NewValue/OldValue JSON swap the `Area` sub-object for a `Category` one (`SELECT oc.Id, oc.Code, oc.Name FROM Parts.OperationCategory oc WHERE oc.Id = drc.OperationCategoryId`). **Keep the `ReasonType` sub-object.**
- **Update proc:** field-diff swaps `Area "old"→"new"` for `Category "old"→"new"`; **include** `IF @Fields IS NULL OR @Fields = N'' SET @Fields = N'no changes';` (the STUFF-on-empty→NULL Description guard — bug hit in #1/SessionPolicy).

- [x] Rewrite both procs per the deltas. Entity code `DowntimeReasonCode`, event codes `Created`/`Updated` already seeded.
- [x] Commit `feat(oee): DowntimeReasonCode Create/Update scope by OperationCategory`.

---

### Task 3: `DowntimeReasonCode_Get` + `_List` procs

**Files:** Modify `R__Oee_DowntimeReasonCode_Get.sql`, `R__Oee_DowntimeReasonCode_List.sql`

- [x] **Get:** SELECT returns `OperationCategoryId`, `oc.Name AS CategoryName` (LEFT JOIN `Parts.OperationCategory oc`) instead of `AreaLocationId`/`AreaName`; **keep** `DowntimeReasonTypeId`/`ReasonTypeName`, `DowntimeSourceCodeId`/`SourceCodeName`, `IsExcused`, `CreatedAt`, `DeprecatedAt`.
- [x] **List:** replace `@AreaLocationId` with `@OperationCategoryId BIGINT = NULL`; add `@OperationTypeCode NVARCHAR(20) = NULL`; **keep** `@DowntimeReasonTypeId`, `@IncludeDeprecated`. Body:

```sql
CREATE OR ALTER PROCEDURE Oee.DowntimeReasonCode_List
    @OperationCategoryId  BIGINT       = NULL,
    @OperationTypeCode    NVARCHAR(20) = NULL,
    @DowntimeReasonTypeId BIGINT       = NULL,
    @IncludeDeprecated    BIT          = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @FilterRequested BIT = CASE WHEN @OperationCategoryId IS NOT NULL OR @OperationTypeCode IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @EffCatId BIGINT = @OperationCategoryId;
    IF @EffCatId IS NULL AND @OperationTypeCode IS NOT NULL
        SELECT @EffCatId = ot.OperationCategoryId FROM Parts.OperationType ot WHERE ot.Code = @OperationTypeCode;

    SELECT drc.Id, drc.Code, drc.Description,
           drc.OperationCategoryId, oc.Name AS CategoryName,
           drc.DowntimeReasonTypeId, drt.Name AS ReasonTypeName,
           drc.DowntimeSourceCodeId, dsc.Name AS SourceCodeName,
           drc.IsExcused, drc.CreatedAt, drc.DeprecatedAt
    FROM Oee.DowntimeReasonCode drc
    LEFT JOIN Parts.OperationCategory oc  ON drc.OperationCategoryId  = oc.Id
    LEFT JOIN Oee.DowntimeReasonType  drt ON drc.DowntimeReasonTypeId = drt.Id
    LEFT JOIN Oee.DowntimeSourceCode  dsc ON drc.DowntimeSourceCodeId = dsc.Id
    WHERE (@IncludeDeprecated = 1 OR drc.DeprecatedAt IS NULL)
      AND (@DowntimeReasonTypeId IS NULL OR drc.DowntimeReasonTypeId = @DowntimeReasonTypeId)
      AND (@FilterRequested = 0 OR drc.OperationCategoryId = @EffCatId OR drc.OperationCategoryId IS NULL)
    ORDER BY CASE WHEN drc.OperationCategoryId IS NULL THEN 1 ELSE 0 END, oc.Name, drc.Code;
END
GO
```
- [x] Commit `feat(oee): DowntimeReasonCode Get/List return Category; List resolves OperationType + plant-wide`.

---

### Task 4: Core Named Queries

**Files:** Modify `oee/DowntimeReasonCode_{Create,Update,Get,List}` `query.sql` + `resource.json`

- [x] Create/Update: `:areaLocationId` → `:operationCategoryId`. List: `:areaLocationId` → `:operationCategoryId` + add `:operationTypeCode` (String); keep `:downtimeReasonTypeId`, `:includeDeprecated`. Get: unchanged EXEC. Update each `resource.json` param set (mirror the `quality/DefectCode_*` resource.json shapes; numeric = sqlType 3, string = sqlType 7). All `type:"Query"`.
- [x] `.\scan.ps1`; commit `feat(oee): DowntimeReasonCode NQs pass operationCategoryId/operationTypeCode`.

---

### Task 5: Seed rewrite

**Files:** Modify the downtime-code seed (find via `grep -rl "DowntimeReasonCode" sql/seeds`)

- [x] Replace the Area-location `DECLARE`s with the three `Parts.OperationCategory` id lookups (`DieCast`/`Trim`/`MachiningAssembly`); map each row's area token → category; site/Break/logistics rows → `NULL` (plant-wide). Rename the temp/insert column `AreaLocationId` → `OperationCategoryId`; drop any `WHERE ... AreaLocationId IS NOT NULL` guard (NULL now valid). ASCII-only — byte-scan before applying.
- [x] Reset `MPP_MES_DowntimeCat`, verify category buckets (die-cast codes→DieCast, trim→Trim, machining→MachiningAssembly, Break/site→NULL). Commit `seed(oee): downtime codes scoped by OperationCategory (site/break = plant-wide)`.

---

### Task 6: Entity script `BlueRidge.Oee.DowntimeReasonCode`

**Files:** Modify `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/DowntimeReasonCode/code.py`

- [x] Mirror `BlueRidge/Quality/DefectCode/code.py`: `getAll`/`search` param `areaLocationId` → `operationCategoryId`; NQ keys `operationCategoryId` + `operationTypeCode`; row map exposes `category`/`operationCategoryId` (was `area`/`areaLocationId`); `add`/`update` read `OperationCategoryId`. Add `getForDropdown(operationTypeCode=None)` (plant-floor) and `getCategoryOptions(nullLabel=None)` (reuse `BlueRidge.Parts.OperationTemplate.getOperationCategoriesForDropdown`). Preserve any downtimeReasonTypeId passthrough.
- [x] `.\scan.ps1`; commit `feat(oee): DowntimeReasonCode entity script scopes by OperationCategory`.

---

### Task 7: SQL tests

**Files:** Modify the DowntimeReasonCode crud test (find via `grep -rl DowntimeReasonCode sql/tests`)

- [x] Mirror `040_DefectCode_crud.sql`: setup fetches the `DieCast` category id; Create/Update calls `@OperationCategoryId=@CatId`; temp-table shapes replace `AreaLocationId/AreaName` with `OperationCategoryId/CategoryName` (keep the ReasonType/SourceCode columns the Get/List return); invalid-FK test asserts `OperationCategoryId`; add **plant-wide create** (NULL category → Status 1), **List by `@OperationTypeCode='DieCast'`** returns die-cast + plant-wide, excludes Trim; **no-change Update succeeds** (NULL-Description guard); audit Description/JSON assert `Category` sub-object.
- [x] Run red→green against `MPP_MES_DowntimeCat`; commit `test(oee): DowntimeReasonCode crud covers OperationCategory + plant-wide + type-resolution`.

---

### Task 8: Designer views + plant-floor downtime entry

**Files (Designer, existing view.json):** `DowntimeCodeEditor`, `DowntimeCodeRow`, `Views/Oee/DowntimeCodes` (MPP_Config); `Components/Popups/DowntimeManager` (+ `Views/ShopFloor/DowntimeEntry`) (MPP)

- [ ] **DowntimeCodeEditor:** Area dropdown → "Applies to" (categories + "Plant-wide (all areas)" via `getCategoryOptions`); value bidi `editDraft.meta.OperationCategoryId`; load reads `OperationCategoryId`/`CategoryName`; drop the Area-required save guard. **Keep** the Reason-Type / Source-Code fields.
- [ ] **DowntimeCodeRow / DowntimeCodes list:** Area column/filter → Category (+ "All areas"); `filter.areaLocationId` → `operationCategoryId`; options via `getCategoryOptions("All areas")`.
- [ ] **DowntimeManager / DowntimeEntry (plant floor):** the reason-code list binding passes the terminal's operation-type code to `getForDropdown` (mirror the die-cast RejectPanel's `"DieCast"`), so a terminal sees its category's codes + plant-wide. Confirm the operation-type code per surface (die-cast downtime → `"DieCast"`, etc.).
- [ ] `.\scan.ps1`; browser-verify each screen; commit `feat(oee): downtime-code UI scoped by OperationCategory (editor/row/list + entry filter)`.

---

## Self-Review
- **Spec coverage:** schema (T1), Create/Update+Category audit+NULL-guard (T2), Get/List+type-resolution+plant-wide (T3), NQs (T4), seed (T5), entity script (T6), tests (T7), views incl. plant-floor entry (T8). ReasonType/SourceCode preserved throughout. ✓
- **Placeholders:** the three `grep`-to-locate notes (seed file, test file, downtime-entry operation-type code) are precise lookups, not vague requirements. ✓
- **Type consistency:** `OperationCategoryId`/`CategoryName` used identically across Get/List/temp-tables/entity map; NQ keys `operationCategoryId`/`operationTypeCode` consistent T4↔T6; `@OperationCategoryId` consistent across procs.
