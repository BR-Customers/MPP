# Assembly-Out Closure Method — Terminal Mode + Per-Method Container Config — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the assembly-out closure UI (Count / Weight / Vision) resolve from a persisted terminal mode that selects among a part's per-method container configs, replacing the hardcoded ByVision chrome — with no customer model and no per-container operator choice.

**Architecture:** `Parts.ContainerConfig` becomes 1-many per part keyed by `(ItemId, ClosureMethod)`. A terminal EAV attribute `CurrentClosureMethod` (persisted, changed only at an elevated changeover) selects the active config; the *capability set* is derived from the terminal's bound PLC devices (`TerminalPlcDevice → PlcDeviceType.ClosureMethodCode`). `Workorder.Assembly_CompleteTray` resolves the config by `(ItemId, closure method)` instead of `TOP 1 by ItemId`. A changeover with an open container freezes it via the existing `Quality.Hold_Place` path. The two assembly views render three appearances off `session.custom.closureMethod`.

**Tech Stack:** SQL Server 2022 (migrations + repeatable procs + `test.*` harness), Ignition 8.3 Perspective (file-authored resources + `scan.ps1`), Jython entity scripts, Named Queries.

**Source spec:** `docs/superpowers/specs/2026-07-17-assembly-closure-method-terminal-mode-design.md`

## Global Constraints

- **SQL conventions** (`sql_best_practices_mes.md`): `UpperCamelCase` tables/columns; `BIGINT IDENTITY` PKs; `NVARCHAR` not `VARCHAR`; `DATETIME2(3)`; `DECIMAL` not `FLOAT`; all enum/status columns code-table-backed with FK (no magic strings); append-only events; `DeprecatedAt` soft deletes; UTC storage (`SYSUTCDATETIME()`), ET display.
- **No OUTPUT params (FDS-11-011).** Mutation procs use local `@Status`/`@Message`/`@NewId` and end every exit path with `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;` (drop `@NewId` for Update/Deprecate). Read procs return an empty set for not-found.
- **`RAISERROR` (not `THROW`) in CATCH**, with nested TRY/CATCH for failure logging. Schema-qualify every reference. `EXEC` args are literals or `@variables` only — never inline `CAST`/arithmetic/`CASE`.
- **Status-row procs captured via INSERT-EXEC must not EXEC another status-row proc and must not ROLLBACK inside a caller transaction** — reject-validations run before `BEGIN TRANSACTION`.
- **ASCII-only** in seed/string values (byte-scan before applying) — em-dash/middle-dot become mojibake through `sqlcmd`.
- **No business logic in Python** — domain rules (the device-type→method map, capability derivation) live in SQL/reference tables, never in entity scripts or bindings.
- **Ignition view-edit boundary** — NEW view folders are file-authored (write files + `.\scan.ps1`); EDITS to existing `view.json` are Designer-driven (GSON unicode-escape + Designer-cache race). Every new view folder needs BOTH `view.json` AND `resource.json`. All NQs live in **Core** only.
- **Displayed timestamps ET; stored UTC.** Audit `Description` follows `<SUBJECT> · <CATEGORY> · <ACTION>` with `Audit.ufn_MidDot()` + `Audit.ufn_TruncateActivity()` + resolved-name FK JSON.
- **Git:** commit to `jacques/working`; explicit path staging only (never `-A`/`-u`); omit the `Co-Authored-By: Claude` trailer. Run `.\Run-Tests.ps1` for SQL; `.\scan.ps1` after any Ignition resource write.
- **Migration numbering:** next free versioned ids are `0039`, `0040` (highest applied is `0038`). Repeatable procs (`R__*`) are edited in place.
- **Closure method domain values:** `ByCount`, `ByWeight`, `ByVision` (exactly these codes).

---

## File Structure

**Phase 1 — schema**
- Create `sql/migrations/versioned/0039_closure_method_code_and_container_config.sql` — `Parts.ClosureMethodCode` code table (+seed); backfill `ContainerConfig.ClosureMethod`; NOT NULL + FK; re-key unique index `(ItemId, ClosureMethod)`.

**Phase 2 — terminal mode + derived capability**
- Create `sql/migrations/versioned/0040_closure_terminal_and_plc_capability.sql` — `CurrentClosureMethod` + `VisionAppUrl` `LocationAttributeDefinition` rows (Terminal LTD 7); `Location.PlcDeviceType.ClosureMethodCode` FK column (+seed map); `Quality.HoldTypeCode` `Changeover` row.
- Create `sql/migrations/repeatable/R__Location_Terminal_GetClosureContext.sql` — read proc: for a terminal, return `CurrentClosureMethod`, `VisionAppUrl`, and the derived capability CSV.
- Modify `sql/migrations/repeatable/R__Location_Terminal_GetByIpAddress.sql` — project `CurrentClosureMethod` + `VisionAppUrl`.
- Modify `ignition/projects/MPP/com.inductiveautomation.perspective/startup/onStartup.py` — stash `session.custom.closureMethod` + `session.custom.terminal.visionAppUrl` + `session.custom.closureCapabilities`.
- Create NQ `ignition/projects/Core/ignition/named-query/location/Terminal_GetClosureContext/` (query.sql + resource.json).

**Phase 3 — proc resolution**
- Modify `sql/migrations/repeatable/R__Parts_ContainerConfig_Create.sql` — drop one-per-item rule; `@ClosureMethod` required; enforce `(ItemId, ClosureMethod)`.
- Modify `sql/migrations/repeatable/R__Parts_ContainerConfig_Update.sql` — reject `ClosureMethod` change.
- Modify `sql/migrations/repeatable/R__Parts_ContainerConfig_GetByItem.sql` — return 0-N rows (multi).
- Create `sql/migrations/repeatable/R__Parts_ContainerConfig_GetByItemAndMethod.sql` — single-row resolver.
- Modify `sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql` — resolve by `(ItemId, @ClosureMethod)`; no-match block.
- Create NQ `location`/`parts` NQ folder for `ContainerConfig_GetByItemAndMethod`.

**Phase 4 — changeover**
- Create `sql/migrations/repeatable/R__Location_Terminal_SetClosureMethod.sql` — elevated mutation: validate capability, freeze open container via `Quality.Hold_Place`, update attribute, audit.
- Create NQ `ignition/projects/Core/ignition/named-query/location/Terminal_SetClosureMethod/`.
- Create entity script `ignition/projects/Core/ignition/script-python/BlueRidge/Location/ClosureMode/code.py` — thin wrapper + elevation orchestration.

**Phase 5 — Item Master editor** (Designer-driven edit of existing view)
- Modify `ignition/projects/MPP_Config/.../ItemMaster/ContainerConfig/view.json` — per-method list.
- Modify `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/ContainerConfig/code.py` — `getByItemAll` / `getByItemAndMethod`.

**Phase 6 — assembly views** (Designer-driven edits of existing views)
- Modify `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py` — route `closureMethod`.
- Modify `.../ShopFloor/AssemblyNonSerialized/view.json` and `.../ShopFloor/AssemblySerialized/view.json` — three-appearance conditional + changeover chip.

**Phase 7 — PLC auto-close** — separate follow-on plan (see end).

---

## Phase 1 — Schema foundation

### Task 1: `Parts.ClosureMethodCode` code table

**Files:**
- Create: `sql/migrations/versioned/0039_closure_method_code_and_container_config.sql` (this task writes the code-table portion; Task 2 appends the ContainerConfig portion to the SAME file)
- Test: `sql/tests/0008_Parts_Item/025_ClosureMethodCode.sql`

**Interfaces:**
- Produces: table `Parts.ClosureMethodCode (Id BIGINT PK, Code NVARCHAR(20) UNIQUE, Name NVARCHAR(50), SortOrder INT, DeprecatedAt DATETIME2(3) NULL)` seeded `ByCount`(1)/`ByWeight`(2)/`ByVision`(3).

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0008_Parts_Item/025_ClosureMethodCode.sql`:
```sql
-- =============================================
-- File: 0008_Parts_Item/025_ClosureMethodCode.sql
-- Desc: Parts.ClosureMethodCode exists and is seeded ByCount/ByWeight/ByVision.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/025_ClosureMethodCode.sql';
GO

DECLARE @Cnt NVARCHAR(10) =
    (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Parts.ClosureMethodCode
     WHERE Code IN (N'ByCount', N'ByWeight', N'ByVision') AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual
    @TestName = N'[ClosureMethodCode] three active codes seeded',
    @Expected = N'3', @Actual = @Cnt;

DECLARE @Uq NVARCHAR(10) =
    (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM sys.indexes
     WHERE name = N'UQ_ClosureMethodCode_Code');
EXEC test.Assert_IsEqual
    @TestName = N'[ClosureMethodCode] unique index on Code present',
    @Expected = N'1', @Actual = @Uq;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.\Run-Tests.ps1 -File 0008_Parts_Item/025_ClosureMethodCode.sql`
Expected: FAIL — `Invalid object name 'Parts.ClosureMethodCode'`.

- [ ] **Step 3: Write the migration (code-table portion)**

Create `sql/migrations/versioned/0039_closure_method_code_and_container_config.sql`:
```sql
-- =============================================
-- Migration: 0039_closure_method_code_and_container_config.sql
-- Date: 2026-07-17
-- Desc: Closure method becomes the ContainerConfig discriminator.
--       (1) Parts.ClosureMethodCode code table (+seed).
--       (2) Backfill ContainerConfig.ClosureMethod NULL -> 'ByCount'.
--       (3) ClosureMethod NOT NULL + FK -> ClosureMethodCode.
--       (4) Re-key active unique index (ItemId) -> (ItemId, ClosureMethod).
--       Idempotent-guarded; repo convention (no explicit outer transaction).
-- =============================================

IF OBJECT_ID(N'Parts.ClosureMethodCode') IS NULL
CREATE TABLE Parts.ClosureMethodCode (
    Id           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ClosureMethodCode PRIMARY KEY,
    Code         NVARCHAR(20)  NOT NULL CONSTRAINT UQ_ClosureMethodCode_Code UNIQUE,
    Name         NVARCHAR(50)  NOT NULL,
    SortOrder    INT           NOT NULL CONSTRAINT DF_ClosureMethodCode_SortOrder DEFAULT 0,
    DeprecatedAt DATETIME2(3)  NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM Parts.ClosureMethodCode)
BEGIN
    SET IDENTITY_INSERT Parts.ClosureMethodCode ON;
    INSERT INTO Parts.ClosureMethodCode (Id, Code, Name, SortOrder) VALUES
        (1, N'ByCount',  N'By Count',  1),
        (2, N'ByWeight', N'By Weight', 2),
        (3, N'ByVision', N'By Vision', 3);
    SET IDENTITY_INSERT Parts.ClosureMethodCode OFF;
END
GO
```

- [ ] **Step 4: Apply + run test to verify it passes**

Run: `.\Run-Tests.ps1 -File 0008_Parts_Item/025_ClosureMethodCode.sql`
Expected: PASS (2 assertions).

- [ ] **Step 5: Byte-scan the migration for non-ASCII**

Run: `python -c "import pathlib,sys; b=pathlib.Path('sql/migrations/versioned/0039_closure_method_code_and_container_config.sql').read_bytes(); bad=[(i,x) for i,x in enumerate(b) if x>127]; print('NON-ASCII:',bad[:20]); sys.exit(1 if bad else 0)"`
Expected: `NON-ASCII: []`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/versioned/0039_closure_method_code_and_container_config.sql sql/tests/0008_Parts_Item/025_ClosureMethodCode.sql
git commit -m "feat(sql): Parts.ClosureMethodCode code table + seed"
```

---

### Task 2: `ContainerConfig` — required method, FK, re-keyed unique index

**Files:**
- Modify: `sql/migrations/versioned/0039_closure_method_code_and_container_config.sql` (append)
- Test: `sql/tests/0008_Parts_Item/026_ContainerConfig_multi_method.sql`

**Interfaces:**
- Consumes: `Parts.ClosureMethodCode` (Task 1).
- Produces: `Parts.ContainerConfig.ClosureMethod NVARCHAR(20) NOT NULL` FK → `ClosureMethodCode.Code`; active unique index `UQ_ContainerConfig_ActiveItemMethod (ItemId, ClosureMethod) WHERE DeprecatedAt IS NULL`; old `UQ_ContainerConfig_ActiveItemId` dropped.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0008_Parts_Item/026_ContainerConfig_multi_method.sql`:
```sql
-- =============================================
-- File: 0008_Parts_Item/026_ContainerConfig_multi_method.sql
-- Desc: Two active configs per item allowed when ClosureMethod differs;
--       a second config with the SAME method is rejected by the index.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/026_ContainerConfig_multi_method.sql';
GO

-- cleanup + host item
DELETE cc FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'TEST-CC-MULTI';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CC-MULTI';
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Parts.Item_Create @ItemTypeId = 4, @PartNumber = N'TEST-CC-MULTI', @Description = N'multi', @UomId = 1, @AppUserId = 1;
DECLARE @Item BIGINT = (SELECT NewId FROM @R);
GO

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-MULTI');

-- ByCount config
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
VALUES (@Item, 1, 48, 0, N'ByCount', SYSUTCDATETIME());
-- ByVision config for the SAME item (must be allowed)
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
VALUES (@Item, 12, 8, 0, N'ByVision', SYSUTCDATETIME());

DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[CCMulti] two active configs, different methods, allowed', @Expected = N'2', @Actual = @N;

-- second ByCount must violate the (ItemId, ClosureMethod) unique index
DECLARE @Err NVARCHAR(10) = N'0';
BEGIN TRY
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Item, 1, 48, 0, N'ByCount', SYSUTCDATETIME());
END TRY
BEGIN CATCH
    SET @Err = N'1';
END CATCH
EXEC test.Assert_IsEqual @TestName = N'[CCMulti] duplicate (item, method) rejected by index', @Expected = N'1', @Actual = @Err;
GO

DELETE cc FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'TEST-CC-MULTI';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CC-MULTI';
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.\Run-Tests.ps1 -File 0008_Parts_Item/026_ContainerConfig_multi_method.sql`
Expected: FAIL — the old `UQ_ContainerConfig_ActiveItemId` rejects the second (ByVision) insert, so assertion 1 fails (`Expected 2, got 1`) or the insert throws.

- [ ] **Step 3: Append the schema change to migration 0039**

Append to `sql/migrations/versioned/0039_closure_method_code_and_container_config.sql`:
```sql
-- Backfill any NULL ClosureMethod before NOT NULL (default ByCount).
UPDATE Parts.ContainerConfig SET ClosureMethod = N'ByCount' WHERE ClosureMethod IS NULL;
GO

-- Drop the old (ItemId)-only active unique index.
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ContainerConfig_ActiveItemId')
    DROP INDEX UQ_ContainerConfig_ActiveItemId ON Parts.ContainerConfig;
GO

-- ClosureMethod NOT NULL.
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'Parts.ContainerConfig')
           AND name = N'ClosureMethod' AND is_nullable = 1)
    ALTER TABLE Parts.ContainerConfig ALTER COLUMN ClosureMethod NVARCHAR(20) NOT NULL;
GO

-- FK ClosureMethod -> ClosureMethodCode.Code.
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_ContainerConfig_ClosureMethod')
    ALTER TABLE Parts.ContainerConfig
        ADD CONSTRAINT FK_ContainerConfig_ClosureMethod
        FOREIGN KEY (ClosureMethod) REFERENCES Parts.ClosureMethodCode(Code);
GO

-- Re-keyed active unique index.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ContainerConfig_ActiveItemMethod')
    CREATE UNIQUE INDEX UQ_ContainerConfig_ActiveItemMethod
        ON Parts.ContainerConfig (ItemId, ClosureMethod)
        WHERE DeprecatedAt IS NULL;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0039_closure_method_code_and_container_config')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0039_closure_method_code_and_container_config',
        N'ClosureMethodCode code table; ContainerConfig.ClosureMethod NOT NULL + FK; re-key active unique index to (ItemId, ClosureMethod).');
GO
```
Note: FK to `Code` requires `ClosureMethodCode.Code` to have a unique constraint — it does (`UQ_ClosureMethodCode_Code`, Task 1).

- [ ] **Step 4: Apply + run test to verify it passes**

Run: `.\Run-Tests.ps1 -File 0008_Parts_Item/026_ContainerConfig_multi_method.sql`
Expected: PASS (2 assertions).

- [ ] **Step 5: Fix the now-inverted legacy Test 5**

In `sql/tests/0008_Parts_Item/020_ContainerConfig_crud.sql`, Test 5 currently asserts a second active config for the same item fails. It seeds no `@ClosureMethod`, so under the new proc (Task 7) it will default. Change Test 5 so the second create uses a **different** method and asserts `Status = 1`, then a **third** create with the **same** method asserts `Status = 0`. Locate Test 5 (the `[CreateDupActive]` block) and replace its single create+assert with:
```sql
-- Test 5 (revised): different method succeeds, same method rejected.
CREATE TABLE #Rcc5a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rcc5a EXEC Parts.ContainerConfig_Create
    @ItemId = @ItemId, @TraysPerContainer = 2, @PartsPerTray = 10, @IsSerialized = 0,
    @ClosureMethod = N'ByWeight', @TargetWeight = 5.0, @AppUserId = 1;
DECLARE @S5a NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #Rcc5a); DROP TABLE #Rcc5a;
EXEC test.Assert_IsEqual @TestName = N'[CreateDiffMethod] second config, different method, Status 1', @Expected = N'1', @Actual = @S5a;

CREATE TABLE #Rcc5b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rcc5b EXEC Parts.ContainerConfig_Create
    @ItemId = @ItemId, @TraysPerContainer = 2, @PartsPerTray = 10, @IsSerialized = 0,
    @ClosureMethod = N'ByWeight', @TargetWeight = 5.0, @AppUserId = 1;
DECLARE @S5b NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #Rcc5b); DROP TABLE #Rcc5b;
EXEC test.Assert_IsEqual @TestName = N'[CreateDupMethod] same method rejected, Status 0', @Expected = N'0', @Actual = @S5b;
```
(The earlier Test 1-4 creates in this file must also gain `@ClosureMethod = N'ByCount'` since it's now required — update each `ContainerConfig_Create` call in the file to pass an explicit method.) This step's full pass is verified in Task 7 Step 4 (after the proc change); for now just save the edits.

- [ ] **Step 6: Byte-scan + commit**

```bash
python -c "import pathlib,sys; b=pathlib.Path('sql/migrations/versioned/0039_closure_method_code_and_container_config.sql').read_bytes(); print('NON-ASCII:',[x for x in b if x>127][:10])"
git add sql/migrations/versioned/0039_closure_method_code_and_container_config.sql sql/tests/0008_Parts_Item/026_ContainerConfig_multi_method.sql sql/tests/0008_Parts_Item/020_ContainerConfig_crud.sql
git commit -m "feat(sql): ContainerConfig 1-many per part keyed by (ItemId, ClosureMethod)"
```

---

## Phase 2 — Terminal mode + derived capability

### Task 3: `PlcDeviceType.ClosureMethodCode` + terminal attrs + Changeover hold type

**Files:**
- Create: `sql/migrations/versioned/0040_closure_terminal_and_plc_capability.sql`
- Test: `sql/tests/0020_PlantFloor_Foundation/030_closure_capability_seed.sql`

**Interfaces:**
- Consumes: `Parts.ClosureMethodCode` (Task 1), `Location.PlcDeviceType` (0038), `Location.LocationAttributeDefinition` (Terminal LTD 7), `Quality.HoldTypeCode` (0004).
- Produces: `Location.PlcDeviceType.ClosureMethodCode NVARCHAR(20) NULL` FK → `ClosureMethodCode.Code` (ScaleStation→ByWeight, TrayInspectionStation→ByVision, MIP types NULL); Terminal LTD-7 `LocationAttributeDefinition` rows `CurrentClosureMethod`, `VisionAppUrl`; `Quality.HoldTypeCode` `Changeover` row (next free Id).

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0020_PlantFloor_Foundation/030_closure_capability_seed.sql`:
```sql
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/030_closure_capability_seed.sql';
GO
-- device-type -> method map
DECLARE @W NVARCHAR(20) = (SELECT ClosureMethodCode FROM Location.PlcDeviceType WHERE Code = N'ScaleStation');
EXEC test.Assert_IsEqual @TestName = N'[Cap] ScaleStation -> ByWeight', @Expected = N'ByWeight', @Actual = @W;
DECLARE @V NVARCHAR(20) = (SELECT ClosureMethodCode FROM Location.PlcDeviceType WHERE Code = N'TrayInspectionStation');
EXEC test.Assert_IsEqual @TestName = N'[Cap] TrayInspectionStation -> ByVision', @Expected = N'ByVision', @Actual = @V;
DECLARE @M NVARCHAR(10) = (SELECT CASE WHEN ClosureMethodCode IS NULL THEN N'NULL' ELSE N'SET' END FROM Location.PlcDeviceType WHERE Code = N'SerializedMipStation');
EXEC test.Assert_IsEqual @TestName = N'[Cap] SerializedMipStation -> NULL', @Expected = N'NULL', @Actual = @M;
-- terminal attribute defs
DECLARE @A NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName IN (N'CurrentClosureMethod', N'VisionAppUrl') AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Cap] two terminal closure attrs defined', @Expected = N'2', @Actual = @A;
-- Changeover hold type
DECLARE @H NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.HoldTypeCode WHERE Code = N'Changeover');
EXEC test.Assert_IsEqual @TestName = N'[Cap] Changeover HoldTypeCode seeded', @Expected = N'1', @Actual = @H;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.\Run-Tests.ps1 -File 0020_PlantFloor_Foundation/030_closure_capability_seed.sql`
Expected: FAIL — `Invalid column name 'ClosureMethodCode'` on `Location.PlcDeviceType`.

- [ ] **Step 3: Write the migration**

Create `sql/migrations/versioned/0040_closure_terminal_and_plc_capability.sql`:
```sql
-- =============================================
-- Migration: 0040_closure_terminal_and_plc_capability.sql
-- Date: 2026-07-17
-- Desc: (1) PlcDeviceType.ClosureMethodCode (device-type -> closure method map).
--       (2) Terminal LTD-7 attrs: CurrentClosureMethod, VisionAppUrl.
--       (3) Quality.HoldTypeCode 'Changeover'.
-- =============================================

-- (1) device-type -> method map ------------------------------------------------
IF COL_LENGTH(N'Location.PlcDeviceType', N'ClosureMethodCode') IS NULL
    ALTER TABLE Location.PlcDeviceType ADD ClosureMethodCode NVARCHAR(20) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_PlcDeviceType_ClosureMethod')
    ALTER TABLE Location.PlcDeviceType
        ADD CONSTRAINT FK_PlcDeviceType_ClosureMethod
        FOREIGN KEY (ClosureMethodCode) REFERENCES Parts.ClosureMethodCode(Code);
GO
UPDATE Location.PlcDeviceType SET ClosureMethodCode = N'ByWeight' WHERE Code = N'ScaleStation'          AND ClosureMethodCode IS NULL;
UPDATE Location.PlcDeviceType SET ClosureMethodCode = N'ByVision' WHERE Code = N'TrayInspectionStation' AND ClosureMethodCode IS NULL;
GO

-- (2) terminal attribute definitions (LTD 7) -----------------------------------
-- SortOrder continues after existing (highest existing +1).
DECLARE @Next INT = ISNULL((SELECT MAX(SortOrder) FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7), 0);
IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'CurrentClosureMethod')
BEGIN
    SET @Next = @Next + 1;
    INSERT INTO Location.LocationAttributeDefinition (LocationTypeDefinitionId, AttributeName, DataType, SortOrder)
    VALUES (7, N'CurrentClosureMethod', N'String', @Next);
END
IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'VisionAppUrl')
BEGIN
    SET @Next = @Next + 1;
    INSERT INTO Location.LocationAttributeDefinition (LocationTypeDefinitionId, AttributeName, DataType, SortOrder)
    VALUES (7, N'VisionAppUrl', N'String', @Next);
END
GO

-- (3) Changeover hold type (next free Id; guarded) -----------------------------
IF NOT EXISTS (SELECT 1 FROM Quality.HoldTypeCode WHERE Code = N'Changeover')
BEGIN
    DECLARE @HId BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Quality.HoldTypeCode);
    SET IDENTITY_INSERT Quality.HoldTypeCode ON;
    INSERT INTO Quality.HoldTypeCode (Id, Code, Name) VALUES (@HId, N'Changeover', N'Changeover Freeze');
    SET IDENTITY_INSERT Quality.HoldTypeCode OFF;
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0040_closure_terminal_and_plc_capability')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0040_closure_terminal_and_plc_capability',
        N'PlcDeviceType.ClosureMethodCode map; Terminal CurrentClosureMethod/VisionAppUrl attrs; Changeover HoldTypeCode.');
GO
```
Note: verify the actual `LocationAttributeDefinition` column names against migration `0002`/`0020` before applying (the seed there uses `AttributeName`/`DataType`/`SortOrder`; match its exact casing and any `Description`/`IsRequired` columns — add them if NOT NULL).

- [ ] **Step 4: Apply + run test to verify it passes**

Run: `.\Run-Tests.ps1 -File 0020_PlantFloor_Foundation/030_closure_capability_seed.sql`
Expected: PASS (4 assertions).

- [ ] **Step 5: Fix the HoldTypeCode count test**

In `sql/tests/0005_Quality_codes/010_Quality_codes_read.sql`, the `HoldTypeCode_List` assertion expects 3 rows. Change `@ExpectedCount = 3` to `@ExpectedCount = 4`.
Run: `.\Run-Tests.ps1 -File 0005_Quality_codes/010_Quality_codes_read.sql`
Expected: PASS.

- [ ] **Step 6: Byte-scan + commit**

```bash
python -c "import pathlib; b=pathlib.Path('sql/migrations/versioned/0040_closure_terminal_and_plc_capability.sql').read_bytes(); print('NON-ASCII:',[x for x in b if x>127][:10])"
git add sql/migrations/versioned/0040_closure_terminal_and_plc_capability.sql sql/tests/0020_PlantFloor_Foundation/030_closure_capability_seed.sql sql/tests/0005_Quality_codes/010_Quality_codes_read.sql
git commit -m "feat(sql): PlcDeviceType closure map + terminal closure attrs + Changeover hold type"
```

---

### Task 4: `Terminal_GetClosureContext` read proc (mode + capability + vision URL)

**Files:**
- Create: `sql/migrations/repeatable/R__Location_Terminal_GetClosureContext.sql`
- Test: `sql/tests/0020_PlantFloor_Foundation/031_Terminal_GetClosureContext.sql`

**Interfaces:**
- Consumes: `Location.TerminalPlcDevice`, `Location.PlcDeviceType.ClosureMethodCode`, `Location.LocationAttribute`/`Definition`.
- Produces: proc `Location.Terminal_GetClosureContext @TerminalLocationId BIGINT` → one row `CurrentClosureMethod NVARCHAR(20) NULL, VisionAppUrl NVARCHAR(400) NULL, ClosureCapabilities NVARCHAR(100)` where capabilities is a comma-joined set always including `ByCount`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0020_PlantFloor_Foundation/031_Terminal_GetClosureContext.sql`:
```sql
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/031_Terminal_GetClosureContext.sql';
GO
-- Build a throwaway terminal with a ScaleStation device -> capabilities include ByCount + ByWeight.
DELETE FROM Location.TerminalPlcDevice WHERE DeviceCode = N'TEST-SCALE-DEV';
DELETE FROM Location.Location WHERE Code = N'TEST-CLOSURE-TERM';
DECLARE @Parent BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId <> 7 AND DeprecatedAt IS NULL ORDER BY Id);
INSERT INTO Location.Location (Code, Name, LocationTypeDefinitionId, ParentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'TEST-CLOSURE-TERM', N'Closure test terminal', 7, @Parent, 1, SYSUTCDATETIME());
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CLOSURE-TERM');
DECLARE @ScaleType BIGINT = (SELECT Id FROM Location.PlcDeviceType WHERE Code = N'ScaleStation');
INSERT INTO Location.TerminalPlcDevice (TerminalLocationId, PlcDeviceTypeId, DeviceCode, UdtInstancePath)
VALUES (@Term, @ScaleType, N'TEST-SCALE-DEV', N'PlcDevices/TEST_Scale');
GO

DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CLOSURE-TERM');
CREATE TABLE #Ctx (CurrentClosureMethod NVARCHAR(20), VisionAppUrl NVARCHAR(400), ClosureCapabilities NVARCHAR(100));
INSERT INTO #Ctx EXEC Location.Terminal_GetClosureContext @TerminalLocationId = @Term;
DECLARE @Caps NVARCHAR(100) = (SELECT ClosureCapabilities FROM #Ctx);
EXEC test.Assert_IsEqual @TestName = N'[CtxCap] scale terminal caps has ByWeight', @Expected = N'1',
    @Actual = CASE WHEN @Caps LIKE N'%ByWeight%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[CtxCap] caps always include ByCount', @Expected = N'1',
    @Actual = CASE WHEN @Caps LIKE N'%ByCount%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[CtxCap] no vision device -> no ByVision', @Expected = N'0',
    @Actual = CASE WHEN @Caps LIKE N'%ByVision%' THEN N'1' ELSE N'0' END;
DROP TABLE #Ctx;
GO
DELETE FROM Location.TerminalPlcDevice WHERE DeviceCode = N'TEST-SCALE-DEV';
DELETE FROM Location.Location WHERE Code = N'TEST-CLOSURE-TERM';
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.\Run-Tests.ps1 -File 0020_PlantFloor_Foundation/031_Terminal_GetClosureContext.sql`
Expected: FAIL — `Could not find stored procedure 'Location.Terminal_GetClosureContext'`.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Location_Terminal_GetClosureContext.sql`:
```sql
-- =============================================
-- Procedure: Location.Terminal_GetClosureContext
-- Desc: Resolve a terminal's closure context: persisted CurrentClosureMethod +
--       VisionAppUrl (LocationAttribute), and the DERIVED capability set from
--       its active PLC devices' PlcDeviceType.ClosureMethodCode. ByCount is
--       always available (needs no device). No OUTPUT params; one result row.
-- =============================================
CREATE OR ALTER PROCEDURE Location.Terminal_GetClosureContext
    @TerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Current NVARCHAR(20) = (
        SELECT la.AttributeValue FROM Location.LocationAttribute la
        INNER JOIN Location.LocationAttributeDefinition lad ON lad.Id = la.LocationAttributeDefinitionId
            AND lad.LocationTypeDefinitionId = 7 AND lad.AttributeName = N'CurrentClosureMethod' AND lad.DeprecatedAt IS NULL
        WHERE la.LocationId = @TerminalLocationId);

    DECLARE @Vision NVARCHAR(400) = (
        SELECT la.AttributeValue FROM Location.LocationAttribute la
        INNER JOIN Location.LocationAttributeDefinition lad ON lad.Id = la.LocationAttributeDefinitionId
            AND lad.LocationTypeDefinitionId = 7 AND lad.AttributeName = N'VisionAppUrl' AND lad.DeprecatedAt IS NULL
        WHERE la.LocationId = @TerminalLocationId);

    -- Derived capability set: ByCount always, plus each device type's method.
    DECLARE @Caps NVARCHAR(100) = N'ByCount';
    SELECT @Caps = @Caps + N',' + m.Code
    FROM (
        SELECT DISTINCT pdt.ClosureMethodCode AS Code
        FROM Location.TerminalPlcDevice tpd
        INNER JOIN Location.PlcDeviceType pdt ON pdt.Id = tpd.PlcDeviceTypeId
        WHERE tpd.TerminalLocationId = @TerminalLocationId
          AND tpd.DeprecatedAt IS NULL
          AND pdt.ClosureMethodCode IS NOT NULL
    ) m
    INNER JOIN Parts.ClosureMethodCode cmc ON cmc.Code = m.Code AND cmc.DeprecatedAt IS NULL
    ORDER BY cmc.SortOrder;

    SELECT @Current AS CurrentClosureMethod, @Vision AS VisionAppUrl, @Caps AS ClosureCapabilities;
END;
GO
```

- [ ] **Step 4: Apply + run test to verify it passes**

Run: `.\Run-Tests.ps1 -File 0020_PlantFloor_Foundation/031_Terminal_GetClosureContext.sql`
Expected: PASS (3 assertions).

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Location_Terminal_GetClosureContext.sql sql/tests/0020_PlantFloor_Foundation/031_Terminal_GetClosureContext.sql
git commit -m "feat(sql): Terminal_GetClosureContext (mode + derived capability + vision url)"
```

---

### Task 5: Project closure context into `session.custom` (Terminal resolver + onStartup)

**Files:**
- Modify: `sql/migrations/repeatable/R__Location_Terminal_GetByIpAddress.sql` (add `CurrentClosureMethod`, `VisionAppUrl` projections)
- Create: NQ `ignition/projects/Core/ignition/named-query/location/Terminal_GetClosureContext/{query.sql,resource.json}`
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/startup/onStartup.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Terminal/code.py` (add `getClosureContext`)

**Interfaces:**
- Consumes: `Location.Terminal_GetClosureContext` (Task 4).
- Produces: `session.custom.closureMethod` (str), `session.custom.closureCapabilities` (list[str]), `session.custom.terminal["visionAppUrl"]` (str). NQ path `location/Terminal_GetClosureContext` param `terminalLocationId`.

- [ ] **Step 1: Add the two projections to the IP resolver**

In `R__Location_Terminal_GetByIpAddress.sql`, add two `LEFT JOIN`s mirroring the existing `DefaultScreen` subquery (around L118-126) for `CurrentClosureMethod` and `VisionAppUrl`, and add `ccm.AttributeValue AS CurrentClosureMethod, vau.AttributeValue AS VisionAppUrl` to the final SELECT (L105-113). Bump the header Change Log to `1.2`.

- [ ] **Step 2: Create the closure-context NQ**

Create `ignition/projects/Core/ignition/named-query/location/Terminal_GetClosureContext/query.sql`:
```sql
EXEC Location.Terminal_GetClosureContext @TerminalLocationId = :terminalLocationId
```
Create the sibling `resource.json` mirroring another `location/*` read NQ (type `Query`, one `terminalLocationId` Int8 param). Copy the shape from `location/Terminal_GetByIpAddress/resource.json`.

- [ ] **Step 3: Add `getClosureContext` to the Terminal entity script**

Append to `BlueRidge/Location/Terminal/code.py`:
```python
def getClosureContext(terminalLocationId):
    """Resolve {CurrentClosureMethod, VisionAppUrl, ClosureCapabilities} for a
       terminal. Returns dict or {} when unresolved."""
    tid = BlueRidge.Common.Util.extractQualifiedValues(terminalLocationId)
    if tid is None:
        return {}
    return BlueRidge.Common.Db.execOne(
        "location/Terminal_GetClosureContext", {"terminalLocationId": tid}) or {}
```

- [ ] **Step 4: Stash closure context in onStartup**

In `onStartup.py`, after the `plcDevices` line (currently the last line), append:
```python
	# Closure context: current mode + capability set (derived from PLC devices).
	cc = BlueRidge.Location.Terminal.getClosureContext(term.get("TerminalLocationId")) or {}
	session.custom.closureMethod = cc.get("CurrentClosureMethod") or ""
	caps = cc.get("ClosureCapabilities") or "ByCount"
	session.custom.closureCapabilities = [c for c in caps.split(",") if c]
	session.custom.terminal["visionAppUrl"] = cc.get("VisionAppUrl") or ""
```
Also add `"visionAppUrl": term.get("VisionAppUrl") or ""` and `session.custom.closureMethod`/`closureCapabilities` defaults into the `isFallback` early-return branch (so fallback terminals get empty strings/`["ByCount"]`, never undefined).

- [ ] **Step 5: Scan + verify**

Run: `.\scan.ps1`
Expected: scan reports the new NQ + modified proc/scripts loaded, no errors in the gateway log.
Manually confirm in a Perspective session on a real terminal: `session.custom.closureMethod` and `session.custom.closureCapabilities` are populated (check via a temporary label binding or the Designer session-props inspector).

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Location_Terminal_GetByIpAddress.sql ignition/projects/Core/ignition/named-query/location/Terminal_GetClosureContext ignition/projects/Core/ignition/script-python/BlueRidge/Location/Terminal/code.py ignition/projects/MPP/com.inductiveautomation.perspective/startup/onStartup.py
git commit -m "feat(ignition): resolve closure mode + capabilities into session.custom at startup"
```

---

## Phase 3 — Config-driven proc resolution

### Task 6: `ContainerConfig_Create` — method required, per-method uniqueness

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_ContainerConfig_Create.sql`
- Test: covered by revised `sql/tests/0008_Parts_Item/020_ContainerConfig_crud.sql` (Task 2 Step 5)

**Interfaces:**
- Produces: `Parts.ContainerConfig_Create` now requires `@ClosureMethod`; the "one active config per Item" rule becomes "one active config per (Item, method)".

- [ ] **Step 1: Make `@ClosureMethod` required**

Change the param default: `@ClosureMethod NVARCHAR(20) = NULL,` → `@ClosureMethod NVARCHAR(20),` and add it to the required-parameter guard at L78:
```sql
IF @ItemId IS NULL OR @TraysPerContainer IS NULL OR @PartsPerTray IS NULL OR @ClosureMethod IS NULL OR @AppUserId IS NULL
```

- [ ] **Step 2: Replace the duplicate-per-item rule with duplicate-per-method**

Replace the L103-114 block (`-- Business rule: no active config already exists for this Item`) with:
```sql
        -- Business rule: no active config already exists for this Item + method.
        IF EXISTS (SELECT 1 FROM Parts.ContainerConfig
                   WHERE ItemId = @ItemId AND ClosureMethod = @ClosureMethod AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'An active ContainerConfig already exists for this Item and closure method.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerConfig',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
```
Also add a method-validity check before the transaction (reject unknown codes):
```sql
        IF NOT EXISTS (SELECT 1 FROM Parts.ClosureMethodCode WHERE Code = @ClosureMethod AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid ClosureMethod code.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerConfig',
                @EntityId = NULL, @LogEventTypeCode = N'Created', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
```
Update the header Description + Change Log to `2.4`.

- [ ] **Step 3: Apply + run the CRUD tests**

Run: `.\Run-Tests.ps1 -File 0008_Parts_Item/020_ContainerConfig_crud.sql`
Expected: PASS — including the revised Test 5 (different method succeeds, same method rejected). If Test 1-4 fail on the required `@ClosureMethod`, add `@ClosureMethod = N'ByCount'` to those create calls (Task 2 Step 5 note).

- [ ] **Step 4: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_ContainerConfig_Create.sql sql/tests/0008_Parts_Item/020_ContainerConfig_crud.sql
git commit -m "feat(sql): ContainerConfig_Create requires method, per-(item,method) uniqueness"
```

---

### Task 7: `ContainerConfig_Update` immutable method + `GetByItem` multi + `GetByItemAndMethod`

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_ContainerConfig_Update.sql`
- Modify: `sql/migrations/repeatable/R__Parts_ContainerConfig_GetByItem.sql`
- Create: `sql/migrations/repeatable/R__Parts_ContainerConfig_GetByItemAndMethod.sql`
- Create: NQ `ignition/projects/Core/ignition/named-query/parts/ContainerConfig_GetByItemAndMethod/{query.sql,resource.json}`
- Test: `sql/tests/0008_Parts_Item/027_ContainerConfig_resolve.sql`

**Interfaces:**
- Produces: `ContainerConfig_Update` rejects a `@ClosureMethod` that differs from the row's current method; `ContainerConfig_GetByItem` returns 0-N rows ordered by method `SortOrder`; new `Parts.ContainerConfig_GetByItemAndMethod @ItemId, @ClosureMethod` → 0-or-1 row.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0008_Parts_Item/027_ContainerConfig_resolve.sql`:
```sql
EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/027_ContainerConfig_resolve.sql';
GO
DELETE cc FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'TEST-CC-RES';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CC-RES';
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Parts.Item_Create @ItemTypeId = 4, @PartNumber = N'TEST-CC-RES', @Description = N'res', @UomId = 1, @AppUserId = 1;
DECLARE @Item BIGINT = (SELECT NewId FROM @R);
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 1, 48, 0, N'ByCount', SYSUTCDATETIME());
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 12, 8, 0, N'ByVision', SYSUTCDATETIME());
GO
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-RES');
-- GetByItem returns both
CREATE TABLE #All (Id BIGINT, ItemId BIGINT, TraysPerContainer INT, PartsPerTray INT, IsSerialized BIT, DunnageCode NVARCHAR(50), CustomerCode NVARCHAR(50), ClosureMethod NVARCHAR(20), TargetWeight DECIMAL(10,4));
INSERT INTO #All EXEC Parts.ContainerConfig_GetByItem @ItemId = @Item;
EXEC test.Assert_IsEqual @TestName = N'[Resolve] GetByItem returns 2 rows', @Expected = N'2', @Actual = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #All);
-- GetByItemAndMethod returns the ByVision one (12x8)
CREATE TABLE #One (Id BIGINT, ItemId BIGINT, TraysPerContainer INT, PartsPerTray INT, IsSerialized BIT, DunnageCode NVARCHAR(50), CustomerCode NVARCHAR(50), ClosureMethod NVARCHAR(20), TargetWeight DECIMAL(10,4));
INSERT INTO #One EXEC Parts.ContainerConfig_GetByItemAndMethod @ItemId = @Item, @ClosureMethod = N'ByVision';
EXEC test.Assert_IsEqual @TestName = N'[Resolve] GetByItemAndMethod picks ByVision PartsPerTray', @Expected = N'8', @Actual = (SELECT CAST(PartsPerTray AS NVARCHAR(10)) FROM #One);
DROP TABLE #All; DROP TABLE #One;
GO
DELETE cc FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'TEST-CC-RES';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CC-RES';
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.\Run-Tests.ps1 -File 0008_Parts_Item/027_ContainerConfig_resolve.sql`
Expected: FAIL — `GetByItemAndMethod` missing; `GetByItem` may return only 1 row depending on current TOP.

- [ ] **Step 3: Make `GetByItem` return all active rows**

In `R__Parts_ContainerConfig_GetByItem.sql`, remove any `TOP 1`, keep the `WHERE ItemId = @ItemId AND DeprecatedAt IS NULL`, add `ORDER BY (SELECT SortOrder FROM Parts.ClosureMethodCode cmc WHERE cmc.Code = cc.ClosureMethod)`. Update header contract to "0-or-N rows, one per active method."

- [ ] **Step 4: Create `GetByItemAndMethod`**

Create `sql/migrations/repeatable/R__Parts_ContainerConfig_GetByItemAndMethod.sql`:
```sql
-- =============================================
-- Procedure: Parts.ContainerConfig_GetByItemAndMethod
-- Desc: Single active ContainerConfig for (ItemId, ClosureMethod). 0-or-1 row.
--       Empty set = not found. No OUTPUT params.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ContainerConfig_GetByItemAndMethod
    @ItemId        BIGINT,
    @ClosureMethod NVARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT cc.Id, cc.ItemId, cc.TraysPerContainer, cc.PartsPerTray, cc.IsSerialized,
           cc.DunnageCode, cc.CustomerCode, cc.ClosureMethod, cc.TargetWeight
    FROM Parts.ContainerConfig cc
    WHERE cc.ItemId = @ItemId AND cc.ClosureMethod = @ClosureMethod AND cc.DeprecatedAt IS NULL;
END;
GO
```

- [ ] **Step 5: Reject method change in `Update`**

In `R__Parts_ContainerConfig_Update.sql`, add a reject-validation before the transaction:
```sql
        IF @ClosureMethod IS NOT NULL
           AND @ClosureMethod <> (SELECT ClosureMethod FROM Parts.ContainerConfig WHERE Id = @Id)
        BEGIN
            SET @Message = N'ClosureMethod is immutable; deprecate and create a new config to change it.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerConfig',
                @EntityId = @Id, @LogEventTypeCode = N'Updated', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END
```
(Match the exact `@Id`/`@ProcName`/`@Params` variable names already declared in that proc.)

- [ ] **Step 6: Create the NQ for `GetByItemAndMethod`**

Create `ignition/projects/Core/ignition/named-query/parts/ContainerConfig_GetByItemAndMethod/query.sql`:
```sql
EXEC Parts.ContainerConfig_GetByItemAndMethod @ItemId = :itemId, @ClosureMethod = :closureMethod
```
Create the sibling `resource.json` copying the shape of `parts/ContainerConfig_GetByItem/resource.json` and adding a `closureMethod` String param.

- [ ] **Step 7: Apply + run tests**

Run: `.\Run-Tests.ps1 -File 0008_Parts_Item/027_ContainerConfig_resolve.sql`
Expected: PASS (2 assertions).
Then run: `.\scan.ps1` (loads the new NQ).

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_ContainerConfig_Update.sql sql/migrations/repeatable/R__Parts_ContainerConfig_GetByItem.sql sql/migrations/repeatable/R__Parts_ContainerConfig_GetByItemAndMethod.sql ignition/projects/Core/ignition/named-query/parts/ContainerConfig_GetByItemAndMethod sql/tests/0008_Parts_Item/027_ContainerConfig_resolve.sql
git commit -m "feat(sql): ContainerConfig immutable method, multi-row GetByItem, GetByItemAndMethod"
```

---

### Task 8: `Assembly_CompleteTray` — resolve config by (Item, method)

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql` (L125-130 + param)
- Test: `sql/tests/0028_PlantFloor_Assembly/093_Assembly_CompleteTray_by_method.sql`

**Interfaces:**
- Consumes: `Parts.ContainerConfig` keyed by `(ItemId, ClosureMethod)`.
- Produces: `Workorder.Assembly_CompleteTray` gains required `@ClosureMethod NVARCHAR(20)`; resolves the config for `(@FinishedGoodItemId, @ClosureMethod)`; blocks with `Status=0` when none exists.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0028_PlantFloor_Assembly/093_Assembly_CompleteTray_by_method.sql` — set up an FG item with a `ByVision` config (12×8) and a `ByCount` config (1×48), seed component stock + BOM, then:
```sql
-- (fixtures mirror 092_Assembly_CompleteTray.sql; add BOTH configs for the FG)
-- Assert 1: calling with @ClosureMethod = 'ByVision' + @PieceCount = 8 succeeds (Status 1).
-- Assert 2: calling with @ClosureMethod = 'ByWeight' (no such config) returns Status 0
--           with a message containing 'no ByWeight'.
```
Model the fixtures + INSERT-EXEC + `test.Assert_IsEqual` on `Status` after `092_Assembly_CompleteTray.sql`. (Full fixture SQL: copy 092's setup, add the second config row, pass `@ClosureMethod` to the proc call.)

- [ ] **Step 2: Run test to verify it fails**

Run: `.\Run-Tests.ps1 -File 0028_PlantFloor_Assembly/093_Assembly_CompleteTray_by_method.sql`
Expected: FAIL — proc has no `@ClosureMethod` param (or resolves TOP-1 and picks the wrong config).

- [ ] **Step 3: Add the param + method-scoped resolution**

Add param `@ClosureMethod NVARCHAR(20),` to the signature. Replace the L125-130 config lookup:
```sql
        SELECT TOP 1 @ContainerConfigId = cc.Id, @PartsPerTray = cc.PartsPerTray,
               @TraysPerContainer = cc.TraysPerContainer,
               @ClosureMethod = COALESCE(cc.ClosureMethod, @ClosureMethod, N'ByCount')
        FROM Parts.ContainerConfig cc
        WHERE cc.ItemId = @FinishedGoodItemId AND cc.DeprecatedAt IS NULL
        ORDER BY cc.Id DESC;
```
with:
```sql
        SELECT @ContainerConfigId = cc.Id, @PartsPerTray = cc.PartsPerTray,
               @TraysPerContainer = cc.TraysPerContainer
        FROM Parts.ContainerConfig cc
        WHERE cc.ItemId = @FinishedGoodItemId AND cc.ClosureMethod = @ClosureMethod
          AND cc.DeprecatedAt IS NULL;
```
Add a reject-validation before `BEGIN TRANSACTION` (after the existing `@ContainerConfigId IS NULL` check region — reuse or extend it) so the message names the method:
```sql
        IF @ContainerConfigId IS NULL
        BEGIN
            SET @Message = N'Part has no ' + @ClosureMethod + N' pack-out configured at this station.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerTray',
                @EntityId = NULL, @LogEventTypeCode = N'TrayClosed', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            GOTO Reply;
        END
```
`@ClosureMethod` is now an input, so remove it from the `COALESCE`/derivation and keep the existing `@ClosureMethod NOT IN ('ByCount','ByWeight','ByVision')` validity check (it already exists ~L141). Update the `@Params` JSON to include `@ClosureMethod` and bump the header.

- [ ] **Step 4: Apply + run test**

Run: `.\Run-Tests.ps1 -File 0028_PlantFloor_Assembly/093_Assembly_CompleteTray_by_method.sql`
Then the full Phase-6 assembly suite: `.\Run-Tests.ps1 -Dir 0028_PlantFloor_Assembly`
Expected: PASS. Update `092_Assembly_CompleteTray.sql` to pass `@ClosureMethod = N'ByCount'` (or the fixture's method) if it now fails on the required param.

- [ ] **Step 5: Update the Assembly_CompleteTray NQ + commit**

Add `@ClosureMethod = :closureMethod` to `ignition/projects/Core/ignition/named-query/workorder/Assembly_CompleteTray/query.sql` and a `closureMethod` String param to its `resource.json`. Run `.\scan.ps1`.
```bash
git add sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql sql/tests/0028_PlantFloor_Assembly ignition/projects/Core/ignition/named-query/workorder/Assembly_CompleteTray
git commit -m "feat(sql): Assembly_CompleteTray resolves config by (item, closure method)"
```

---

## Phase 4 — Changeover action

### Task 9: `Terminal_SetClosureMethod` — elevated changeover + freeze open container

**Files:**
- Create: `sql/migrations/repeatable/R__Location_Terminal_SetClosureMethod.sql`
- Test: `sql/tests/0020_PlantFloor_Foundation/032_Terminal_SetClosureMethod.sql`

**Interfaces:**
- Consumes: `Location.LocationAttribute(Definition)`, `Location.Terminal_GetClosureContext` capability logic, `Quality.Hold_Place`, `Quality.HoldTypeCode 'Changeover'`, `Lots.Container` (open at cell).
- Produces: proc `Location.Terminal_SetClosureMethod @TerminalLocationId, @NewMethod, @AppUserId` → status row `Status, Message`. Validates method ∈ capability set; upserts the `CurrentClosureMethod` attribute; if an Open container exists at the terminal's zone cell, calls `Quality.Hold_Place @ContainerId`; audits `ClosureModeChanged`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0020_PlantFloor_Foundation/032_Terminal_SetClosureMethod.sql`: build a terminal with a ScaleStation device (capable of ByWeight); assert:
- setting `ByWeight` returns `Status = 1` and the `CurrentClosureMethod` attribute row now reads `ByWeight`;
- setting `ByVision` (not capable) returns `Status = 0`;
- with an Open container at the cell, setting a new method leaves that container at `ContainerStatusCodeId = 4` (Hold) and creates an open `Quality.HoldEvent` with the `Changeover` type.
Use the INSERT-EXEC + `test.Assert_IsEqual` pattern; tear down the terminal/device/container/holdevent in FK-safe order (HoldEvent → Container → TerminalPlcDevice → Location).

- [ ] **Step 2: Run test to verify it fails**

Run: `.\Run-Tests.ps1 -File 0020_PlantFloor_Foundation/032_Terminal_SetClosureMethod.sql`
Expected: FAIL — proc missing.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Location_Terminal_SetClosureMethod.sql`. Structure per the template: all reject-validations before `BEGIN TRANSACTION` (method exists, terminal exists, method ∈ derived capability set); then in a transaction — upsert the `CurrentClosureMethod` `LocationAttribute` (mirror `R__Location_LocationAttribute_Set` logic inline, since this is a status-row proc captured via INSERT-EXEC and must not `EXEC` another status-row proc); find the Open container at the terminal's zone cell and, if present, freeze it. Because `Quality.Hold_Place` is itself a status-row proc, **inline** the freeze (INSERT `Quality.HoldEvent` with `Changeover` type + `PriorContainerStatusCodeId = 1`, `UPDATE Lots.Container SET ContainerStatusCodeId = 4`) rather than `EXEC`-ing it — comment it as a mirror of `Hold_Place`. Audit `ClosureModeChanged` (new `LogEventType`; add its seed to migration 0040 if absent) with old→new JSON. End with `SELECT @Status AS Status, @Message AS Message;`.
```sql
-- Capability check (mirror Terminal_GetClosureContext derivation):
IF @NewMethod <> N'ByCount' AND NOT EXISTS (
    SELECT 1 FROM Location.TerminalPlcDevice tpd
    INNER JOIN Location.PlcDeviceType pdt ON pdt.Id = tpd.PlcDeviceTypeId
    WHERE tpd.TerminalLocationId = @TerminalLocationId AND tpd.DeprecatedAt IS NULL
      AND pdt.ClosureMethodCode = @NewMethod)
BEGIN
    SET @Message = N'This terminal cannot run ' + @NewMethod + N' (no capable device).';
    SELECT @Status AS Status, @Message AS Message; RETURN;
END
```

- [ ] **Step 4: Apply + run test**

Run: `.\Run-Tests.ps1 -File 0020_PlantFloor_Foundation/032_Terminal_SetClosureMethod.sql`
Expected: PASS (3+ assertions).

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Location_Terminal_SetClosureMethod.sql sql/tests/0020_PlantFloor_Foundation/032_Terminal_SetClosureMethod.sql sql/migrations/versioned/0040_closure_terminal_and_plc_capability.sql
git commit -m "feat(sql): Terminal_SetClosureMethod changeover (capability-gated, freezes open container)"
```

---

### Task 10: Changeover entity script + NQ (elevation orchestration)

**Files:**
- Create: NQ `ignition/projects/Core/ignition/named-query/location/Terminal_SetClosureMethod/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/ClosureMode/code.py`

**Interfaces:**
- Consumes: `Location.Terminal_SetClosureMethod`, `BlueRidge.Location.AppUser.elevate` (existing per-action AD elevation), `BlueRidge.Common.Db`, `BlueRidge.Common.Ui.notifyResult`.
- Produces: `BlueRidge.Location.ClosureMode.changeover(terminalLocationId, newMethod, adAccount, password)` → result dict `{Status, Message}` after elevating for the `Changeover` action and calling the proc with the elevated `appUserId`.

- [ ] **Step 1: Create the mutation NQ**

Create `location/Terminal_SetClosureMethod/query.sql`:
```sql
EXEC Location.Terminal_SetClosureMethod @TerminalLocationId = :terminalLocationId, @NewMethod = :newMethod, @AppUserId = :appUserId
```
`resource.json`: type `Query` (status-row mutation — per the NQ-type rule), params `terminalLocationId` Int8, `newMethod` String, `appUserId` Int8.

- [ ] **Step 2: Write the entity script**

Create `BlueRidge/Location/ClosureMode/code.py`:
```python
"""BlueRidge.Location.ClosureMode - assembly-out closure-mode changeover.

   Elevates for the 'Changeover' protected action, then calls the
   Terminal_SetClosureMethod mutation with the elevated appUserId. Stateless
   per-action elevation: the returned appUserId is passed straight to the proc
   (session.custom.appUserId is NOT relied upon)."""

import BlueRidge.Common.Db
import BlueRidge.Location.AppUser


def changeover(terminalLocationId, newMethod, adAccount, password):
    el = BlueRidge.Location.AppUser.elevate(adAccount, password, "Changeover", terminalLocationId)
    if not el or not el.get("success"):
        return {"Status": 0, "Message": (el or {}).get("message") or "Elevation failed."}
    return BlueRidge.Common.Db.execMutation("location/Terminal_SetClosureMethod", {
        "terminalLocationId": terminalLocationId,
        "newMethod": newMethod,
        "appUserId": el.get("appUserId"),
    })
```

- [ ] **Step 3: Scan + verify**

Run: `.\scan.ps1`
Expected: NQ + script loaded, no gateway errors. (End-to-end elevation is blocked until `_validateAdCredentials` is wired — verify the proc path with the dev bootstrap user by temporarily calling `Terminal_SetClosureMethod` directly, then revert.)

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/location/Terminal_SetClosureMethod ignition/projects/Core/ignition/script-python/BlueRidge/Location/ClosureMode/code.py
git commit -m "feat(ignition): closure-mode changeover entity script + mutation NQ"
```

---

### Task 11: Changeover chip on the assembly views (Designer)

**Files:**
- Modify (Designer): `.../ShopFloor/AssemblyNonSerialized/view.json` + `.../AssemblySerialized/view.json`

> **Designer task** (existing views — file-edit boundary). Do this in Designer, not raw file edits.

- [ ] **Step 1: Rebind the `ConfirmMethod` chip to the live mode**

Bind the header `ConfirmMethod` label `props.text` to an expression mapping `{session.custom.closureMethod}` → display text (`ByCount`→"By Count", etc.), replacing the hardcoded `"ByVision"`. Bind `data-method` similarly for styling.

- [ ] **Step 2: Make the chip open the changeover popup**

Add a `dom.onClick` (scope `G`) that opens a new `ChangeoverElevation` popup (a small view: method dropdown limited to `{session.custom.closureCapabilities}`, AD account + password fields, Confirm). Confirm calls `BlueRidge.Location.ClosureMode.changeover(...)`, routes through `notifyResult`, and **on success assigns `self.session.custom.closureMethod` directly** so the running view re-renders without re-login.

- [ ] **Step 3: Guarded enablement**

Bind the chip's clickability so a supervisor-only tooltip shows; the changeover proc is the authority, but the chip should visually indicate the current mode at all times.

- [ ] **Step 4: Scan + verify + commit**

`.\scan.ps1`; verify in a session that the chip shows the current mode and the popup lists only capable methods. Commit the view + the new popup view folder (with its `resource.json`).

---

## Phase 5 — Item Master ContainerConfig editor (per-method list)

### Task 12: `getByItemAll` / `getByItemAndMethod` entity-script accessors

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/ContainerConfig/code.py`

**Interfaces:**
- Produces: `getByItemAll(itemId)` → list[dict] (all active configs, method-ordered); `getByItemAndMethod(itemId, method)` → dict or `{}`.

- [ ] **Step 1: Add the accessors**

```python
def getByItemAll(itemId):
    """All active ContainerConfigs for an item (0-N, method-ordered). Always a list."""
    iid = BlueRidge.Common.Util.extractQualifiedValues(itemId)
    if iid is None:
        return []
    return BlueRidge.Common.Db.execList("parts/ContainerConfig_GetByItem", {"itemId": iid}) or []


def getByItemAndMethod(itemId, method):
    """Single active ContainerConfig for (item, method), or {}."""
    iid = BlueRidge.Common.Util.extractQualifiedValues(itemId)
    m = BlueRidge.Common.Util.extractQualifiedValues(method)
    if iid is None or not m:
        return {}
    return BlueRidge.Common.Db.execOne(
        "parts/ContainerConfig_GetByItemAndMethod", {"itemId": iid, "closureMethod": m}) or {}
```

- [ ] **Step 2: Scan + commit**

`.\scan.ps1`; then:
```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Parts/ContainerConfig/code.py
git commit -m "feat(ignition): ContainerConfig getByItemAll + getByItemAndMethod accessors"
```

### Task 13: ContainerConfig editor — per-method list (Designer)

**Files:**
- Modify (Designer): `ignition/projects/MPP_Config/.../ItemMaster/ContainerConfig/view.json`

> **Designer task** (existing view — file-edit boundary). Preserve the per-section-ownership + atomic-state pattern.

- [ ] **Step 1** Restructure `view.custom.state` so `selected`/`editDraft` hold a **list** of configs (≤3, one per method). Load via `BlueRidge.Parts.ContainerConfig.getByItemAll(itemId)` in one atomic `state` write.
- [ ] **Step 2** Render a section per method (Count/Weight/Vision) — each with its own PartsPerTray / TraysPerContainer / Dunnage (+ TargetWeight only on Weight). Add/remove a method-config via the existing add/deprecate procs.
- [ ] **Step 3** Save loops the drafts → `add`/`update` per method; broadcast one `sectionDirtyChanged` for the whole section (versioned/Publish lifecycle stays orthogonal).
- [ ] **Step 4** `.\scan.ps1`; verify load/edit/save of a 2-method part in a session; commit.

---

## Phase 6 — Assembly view three-appearance rework

### Task 14: Route `closureMethod` through the Assembly entity script

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py`

**Interfaces:**
- Produces: `handleTrayComplete(...)` passes `session.custom.closureMethod` to `completeTray(...)` → the `workorder/Assembly_CompleteTray` NQ `closureMethod` param.

- [ ] **Step 1** In `handleTrayComplete` (and `completeTray`), thread the already-declared `closureMethod` param down to the NQ call (it's currently accepted but unused). Have the view pass `self.session.custom.closureMethod`.
- [ ] **Step 2** `.\scan.ps1`; commit:
```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py
git commit -m "feat(ignition): route session closure method into Assembly_CompleteTray"
```

### Task 15: `AssemblyNonSerialized` three appearances (Designer)

**Files:**
- Modify (Designer): `.../ShopFloor/AssemblyNonSerialized/view.json`

> **Designer task.** Replace hardcoded ByVision chrome with a conditional on `{session.custom.closureMethod}`.

- [ ] **Step 1** Wrap the middle panel in three sibling containers gated by `position.display`:
  - `ByCount` → the existing "Parts in tray" + Complete Tray panel.
  - `ByWeight` → live weight vs target panel (bind to the ScaleStation UDT members via the terminal's device path; "waiting for scale — {NET_NetWeightValue} / {TRG_TargetWeightValue}"); no count field.
  - `ByVision` → an `ia.display.inline-frame` (external vision app) sourced from `{session.custom.terminal.visionAppUrl}` on the left + dispositions/status on the right.
- [ ] **Step 2** Remove the hardcoded `"Per-Tray Close - ByVision"` string (bind the header to the resolved method) and the static camera PASS pane (moves into the ByVision panel only).
- [ ] **Step 3** `.\scan.ps1`; verify each appearance renders by flipping `session.custom.closureMethod` in a dev session; the Count path completes a tray end-to-end. Commit.

### Task 16: `AssemblySerialized` three appearances (Designer)

**Files:**
- Modify (Designer): `.../ShopFloor/AssemblySerialized/view.json`

> **Designer task.** Same treatment as Task 15, adapted to the serialized panel (per-part MIP handshake stays; only the closure appearance switches).

- [ ] **Step 1** Apply the same three-panel `position.display` conditional + chip rebind + de-hardcode the ByVision copy.
- [ ] **Step 2** `.\scan.ps1`; verify; commit.

---

## Phase 7 — PLC-driven auto-close (follow-on plan)

Out of scope for this plan — depends on live PLC tags and the AD-elevation seam being wired. A separate plan (`docs/superpowers/plans/YYYY-MM-DD-assembly-plc-autoclose.md`) will cover: a gateway watcher subscribing to `ScaleStation.NET_TargetWeightMetFlag` and `TrayInspectionStation.OkToContinue` per bound device, writing `TRG_TargetWeightValue`←`ContainerConfig.TargetWeight` and `PartNumber`←`Item.PlcId`, and calling `Assembly_CompleteTray` on assertion. `TrayInspectionWatcher` already scaffolds the vision side.

---

## Self-Review Notes

- **Spec coverage:** §2.1 → Tasks 1-2; §2.2 (derived capability, PlcDeviceType map, VisionAppUrl) → Tasks 3-5; §2.3 resolution → Tasks 7-8; §3 changeover + freeze + live-session refresh → Tasks 9-11; §4 three appearances + trigger tags → Tasks 14-16 (triggers themselves = Phase 7); §5.1-5.4 blast-radius items each map to a task (ContainerConfig procs 6-7, Assembly_CompleteTray 8, GetByItem multi 7, tests fixed in 2/3, Item Master editor 12-13, views 15-16); §7 backfill=`ByCount` (Task 2), Hold-on-Open verified (Task 9), `Container_Open` config-id (unchanged — SAFE per blast radius).
- **Frontend caveat:** Tasks 11, 13, 15, 16 are Designer-driven per the view-edit boundary — they carry build-specs + scan/verify rather than red/green unit tests, which is the correct test loop for Perspective views in this repo.
- **Type consistency:** `closureMethod` (str code), `closureCapabilities` (list[str]), `getByItemAll`→list, `getByItemAndMethod`→dict, `changeover(...)`→`{Status,Message}` — consistent across Tasks 5, 10, 12, 14.
- **Verify-before-apply flags:** exact `LocationAttributeDefinition` column set (Task 3 Step 3 note) and `Quality.HoldTypeCode`/`LogEventType` seed ids must be confirmed against migrations `0002`/`0004`/`0020` before applying.
