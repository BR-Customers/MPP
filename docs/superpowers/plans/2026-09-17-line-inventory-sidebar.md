# M&A Line Inventory Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A compact, right-docked Line Inventory panel on all five M&A screens. It lists parts by
description with finished goods excluded. Rows turn orange when stock drops below a per-finished-good
horizon, and PassThrough parts get a one-tap box check-in button.

**Architecture:**
- **SQL owns every rule.** One new read proc resolves the line, the running finished goods, the
  rolled-up BOM thresholds, the on-hand totals and the button mode.
- **Python is thin glue.** It fetches the rows, formats them for display and wraps `Lot_Create`.
- **Views are new and file-authored.** Two views (the panel and its row) plus a quantity popup.
  They are embedded into the five existing terminal views through Designer.
- **Retirements.** The tray projection proc and the low-inventory toast are retired.

**Tech Stack:** SQL Server 2022 (T-SQL, repeatable + versioned migrations, `sql/tests` framework), Ignition 8.3
Perspective (file-based views, Jython 2.7 script modules, named queries in the Core project).

**Spec:** `docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md` · **Mockup:** `mockup/line_inventory_sidebar_mock.html`

## Global Constraints

**SQL**
- Migration file name is `0091_line_inventory_sidebar.sql`. **Re-check the next free number before
  Task 1** (`ls sql/migrations/versioned | tail -3`, and grep `docs/superpowers/specs` for claimed
  numbers; `0090` is claimed by the OEE spec). If you renumber, rename every `0091` reference in this
  plan.
- Stored procs: no `OUTPUT` params (FDS-11-011).
  - A read proc returns one result set; an empty set means nothing to show.
  - A mutation proc ends every path with `SELECT @Status AS Status, @Message AS Message`.
- `EXEC` arguments must be literals or `@variables` only; no inline `CAST` / arithmetic.
- Seed and data strings are **ASCII only** (no em-dash, middle-dot or arrow characters in new
  literals). `Item_Update` already uses `NCHAR(8594)` for its arrow, so keep that.
- Every business rule lives in SQL, never in Python or bindings.

**Ignition views**
- Style classes in `view.json` omit the `psc-` prefix: `"classes": "pf-inv-row"` maps to CSS
  `.psc-pf-inv-row`.
- Every `view.custom.*` a binding reads is pre-declared with a shaped default.
- **Event scripts:**
  - Every line starts with `\t`.
  - A `system.perspective.*` call from a component event needs `"scope": "G"`.
  - Message handlers that receive page messages use `pageScope: true`.
  - Use `system.perspective.sendMessage` (never `sendMessageAsync`).
- **Named queries:**
  - Named queries live **only** in the Core project.
  - A status-row proc's NQ is `type: "Query"`.
  - Integer params are `sqlType: 3`.
- **Existing `view.json` files are edited in Designer** (Tasks 7-10). New views, stylesheets, NQs, Python
  and SQL are file edits. After adding or changing any Ignition resource on disk, run `.\scan.ps1` from the
  repo root.

**UI copy**
- Row description = `Parts.Item.Description` (fall back to `PartNumber` only when Description is NULL).
- One-tap button text = `+` plus the box quantity with thousands separators (`+5,000`).
- Ask-quantity button text = `+ LOT`.
- Low tokens: `--pf-inv-low-bg: rgba(255,145,48,0.16)`, `--pf-inv-low-border: #FF9130`.
- Panel is 320px wide. Rows are 40px with 4px gaps and 28px-tall 72px-wide buttons. There is **no scrolling**
  (`overflow: hidden`).

**Tests and git**
- Tests run against the throwaway `MPP_MES_Test` DB only: `.\sql\tests\Run-Tests.ps1 -Filter <text>`.
  **Never** reset `MPP_MES_Dev`.
- Apply to Dev non-destructively with
  `.\sql\scripts\Update-Prod.ps1 -ServerInstance localhost -DatabaseName MPP_MES_Dev -Preview`, then the
  same command without `-Preview`.
- Git: work on `jacques/working`. Stage explicit paths only (never `git add -A` / `-u`). No
  `Co-Authored-By: Claude` trailer.

---

## File Structure

| Path | Status | Responsibility |
|---|---|---|
| `sql/migrations/versioned/0091_line_inventory_sidebar.sql` | Create | `Parts.Item.BoxQuantity`, `.LowInventoryHorizon` + CHECKs |
| `sql/migrations/repeatable/R__Parts_Item_Update.sql` | Modify | Accept/validate/audit the two new fields (NULL-preserving, 0 clears) |
| `sql/migrations/repeatable/R__Parts_Item_Get.sql` | Modify | Return the two new fields (append last) |
| `sql/migrations/repeatable/R__Lots_Lot_GetLineInventorySummary.sql` | Create | The panel's single read proc |
| `sql/migrations/repeatable/R__Lots_Lot_GetLineInventoryByPart.sql` | Modify | Exclude FinishedGood items (Inventory popup) |
| `sql/migrations/repeatable/R__Workorder_Assembly_GetComponentProjection.sql` | Delete (Task 10) | Retired |
| `sql/migrations/versioned/0092_retire_component_projection.sql` | Create (Task 10) | `DROP PROCEDURE` for already-deployed DBs |
| `sql/tests/0008_Parts_Item/030_Item_BoxQuantity_Horizon.sql` | Create | Item_Update rules |
| `sql/tests/0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql` | Create | Summary proc |
| `sql/tests/0027_PlantFloor_Machining/100_Lot_GetLineInventoryByPart.sql` | Modify | + FG-excluded assertion |
| `sql/tests/0028_PlantFloor_Assembly/094_Assembly_ComponentProjection.sql` | Delete (Task 10) | Retired |
| `MPP_MES_DATA_MODEL.md` | Modify | Item table rows + revision note (feeds extended properties) |
| `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql` | Regenerate | via `node sql/scripts/gen_extended_properties.js` |
| `ignition/projects/Core/ignition/named-query/lots/Lot_GetLineInventorySummary/{query.sql,resource.json}` | Create | NQ |
| `ignition/projects/Core/ignition/named-query/parts/Item_Update/{query.sql,resource.json}` | Modify | + 2 params |
| `ignition/projects/Core/ignition/named-query/workorder/Assembly_GetComponentProjection/` | Delete (Task 10) | Retired |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` | Modify | `getLineInventorySummary`, `getLineInventoryInstances`, `getLineInventoryHeader`, `checkInBox`, `checkInAndNotify` |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Item/code.py` | Modify | `update()` passes the two fields; shape keys |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py` | Modify (Task 10) | Remove `getComponentProjection`, `warnLowInventory` + 2 call sites |
| `ignition/projects/Core/com.inductiveautomation.perspective/stylesheet/stylesheet.css` | Modify | `.psc-pf-inv-*` classes + tokens |
| `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/LineInventory/` | Create | Panel view |
| `.../Components/PlantFloor/LineInventoryRow/` | Create | Row view |
| `.../Components/PlantFloor/AddLotQty/` | Create | Numpad quantity popup |
| `.../Components/PlantFloor/ComponentProjectionRow/` | Delete (Task 10) | Retired |
| `.../Views/ShopFloor/{MachiningIn,MachiningOutSplit,AssemblyIn,AssemblySerialized,AssemblyNonSerialized}/view.json` | Designer | Dock the panel |
| `.../Components/PlantFloor/InventoryManager/view.json` | Designer | Group by part |
| `.../Views/ShopFloor/AppHeaderLarge/view.json` | Designer (Task 10) | Remove `lowInventoryWarning` handler |
| `ignition/projects/MPP_Config/.../Components/Parts/ItemMaster/Identity/view.json` | Designer | Two new fields |

---

### Task 1: Migration -- the two Item columns

**Files:**
- Create: `sql/migrations/versioned/0091_line_inventory_sidebar.sql`
- Modify: `MPP_MES_DATA_MODEL.md` (the `### Item` table and the revision history)
- Regenerate: `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql`
- Test: `sql/tests/0008_Parts_Item/030_Item_BoxQuantity_Horizon.sql` (schema phase only in this task)

**Interfaces:**
- Produces: `Parts.Item.BoxQuantity INT NULL`, `Parts.Item.LowInventoryHorizon INT NULL`, CHECK constraints
  `CK_Item_BoxQuantity_Positive` and `CK_Item_LowInventoryHorizon_Positive` (each `IS NULL OR > 0`).

- [ ] **Step 1: Write the failing schema test**

Create `sql/tests/0008_Parts_Item/030_Item_BoxQuantity_Horizon.sql`:

```sql
-- =============================================
-- File:         0008_Parts_Item/030_Item_BoxQuantity_Horizon.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Parts.Item.BoxQuantity / LowInventoryHorizon (migration 0091) and
--               their Parts.Item_Update rules (line inventory sidebar spec).
--               Phase 1: columns + positive CHECKs exist.
--               Phase 2+: Item_Update validation / preserve / clear / audit.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/030_Item_BoxQuantity_Horizon.sql';
GO

-- ---- cleanup ----
DELETE FROM Audit.ConfigLog
    WHERE LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'Item')
      AND EntityId IN (SELECT Id FROM Parts.Item WHERE PartNumber LIKE N'T030-%');
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T030-%';
GO

-- ---- fixture: one PassThrough, one FinishedGood, one Component ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES
    ((SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough'),  N'T030-PT', N'T030 dowel pin', 1, @Now, 1),
    ((SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood'), N'T030-FG', N'T030 finished',  1, @Now, 1),
    ((SELECT Id FROM Parts.ItemType WHERE Code = N'Component'),    N'T030-CO', N'T030 casting',   1, @Now, 1);
GO

-- =============================================
-- Phase 1: schema
-- =============================================
DECLARE @HasBox NVARCHAR(1) = CASE WHEN COL_LENGTH('Parts.Item', 'BoxQuantity') IS NULL THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] Item.BoxQuantity exists', @Expected = N'1', @Actual = @HasBox;
DECLARE @HasHz NVARCHAR(1) = CASE WHEN COL_LENGTH('Parts.Item', 'LowInventoryHorizon') IS NULL THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] Item.LowInventoryHorizon exists', @Expected = N'1', @Actual = @HasHz;
GO

DECLARE @Err NVARCHAR(1) = N'0';
BEGIN TRY
    EXEC(N'UPDATE Parts.Item SET BoxQuantity = 0 WHERE PartNumber = N''T030-PT''');
END TRY
BEGIN CATCH
    SET @Err = N'1';
END CATCH
EXEC test.Assert_IsEqual @TestName = N'[Schema] CHECK rejects BoxQuantity = 0', @Expected = N'1', @Actual = @Err;
GO

DECLARE @Err NVARCHAR(1) = N'0';
BEGIN TRY
    EXEC(N'UPDATE Parts.Item SET LowInventoryHorizon = -5 WHERE PartNumber = N''T030-FG''');
END TRY
BEGIN CATCH
    SET @Err = N'1';
END CATCH
EXEC test.Assert_IsEqual @TestName = N'[Schema] CHECK rejects negative horizon', @Expected = N'1', @Actual = @Err;
GO

-- (Task 2 appends the Item_Update phases above this line.)

-- ---- cleanup ----
DELETE FROM Audit.ConfigLog
    WHERE LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'Item')
      AND EntityId IN (SELECT Id FROM Parts.Item WHERE PartNumber LIKE N'T030-%');
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T030-%';
GO

EXEC test.EndTestFile;
GO
```

Note: the `EXEC(N'...')` dynamic SQL keeps a compile-time "invalid column" error from aborting the whole batch
before the migration exists.

- [ ] **Step 2: Run it to make sure it fails**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "030_Item_BoxQuantity"`
Expected: FAIL on `[Schema] Item.BoxQuantity exists` (and the horizon check).

- [ ] **Step 3: Write the migration**

Create `sql/migrations/versioned/0091_line_inventory_sidebar.sql`:

```sql
-- ============================================================
-- Migration:   0091_line_inventory_sidebar.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Description: Two Parts.Item settings for the M&A Line Inventory sidebar
--              (spec 2026-09-17-line-inventory-sidebar-design.md).
--
--              BoxQuantity INT NULL -- pieces in one purchased box (dowel pins
--              come in 5000s). A PassThrough part with a BoxQuantity gets a
--              one-tap check-in button that creates one Received LOT of this
--              size; without one, the button asks for a count.
--
--              LowInventoryHorizon INT NULL -- set on a FinishedGood: "warn me
--              when the line can't build this many more". A component of a
--              running FG is low when on hand < rolled-up QtyPer x horizon.
--
--              Both are nullable and metadata-only on Parts.Item (no backfill).
--              The > 0 rule is a CHECK; which ItemType may carry each value is
--              enforced in Parts.Item_Update (a CHECK would hard-code type Ids).
-- ============================================================

IF COL_LENGTH('Parts.Item', 'BoxQuantity') IS NULL
    ALTER TABLE Parts.Item
        ADD BoxQuantity INT NULL
            CONSTRAINT CK_Item_BoxQuantity_Positive CHECK (BoxQuantity IS NULL OR BoxQuantity > 0);
GO

IF COL_LENGTH('Parts.Item', 'LowInventoryHorizon') IS NULL
    ALTER TABLE Parts.Item
        ADD LowInventoryHorizon INT NULL
            CONSTRAINT CK_Item_LowInventoryHorizon_Positive CHECK (LowInventoryHorizon IS NULL OR LowInventoryHorizon > 0);
GO

DECLARE @Box NVARCHAR(20) = CASE WHEN COL_LENGTH('Parts.Item', 'BoxQuantity') IS NOT NULL THEN N'present' ELSE N'MISSING' END;
DECLARE @Hz  NVARCHAR(20) = CASE WHEN COL_LENGTH('Parts.Item', 'LowInventoryHorizon') IS NOT NULL THEN N'present' ELSE N'MISSING' END;
PRINT 'Parts.Item.BoxQuantity: ' + @Box;
PRINT 'Parts.Item.LowInventoryHorizon: ' + @Hz;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0091_line_inventory_sidebar')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0091_line_inventory_sidebar',
            N'Parts.Item.BoxQuantity (INT NULL, > 0; PassThrough one-tap check-in size) and Parts.Item.LowInventoryHorizon (INT NULL, > 0; FinishedGood low-stock horizon) for the M&A Line Inventory sidebar.');
GO
PRINT 'Migration 0091 (line_inventory_sidebar) applied.';
GO
```

- [ ] **Step 4: Document the columns**

In `MPP_MES_DATA_MODEL.md`, `### Item` table, insert after the `| MaxParts | ...` row:

```markdown
| BoxQuantity | INT | NULL, CHECK > 0 | **Added 2026-09-17 (migration 0091).** Pieces in one purchased box (e.g., dowel pins = 5000). Only on PassThrough items (enforced by Item_Update). Drives the one-tap check-in button on the M&A Line Inventory sidebar: one press creates one Received LOT of this size. NULL = the button asks for a count. |
| LowInventoryHorizon | INT | NULL, CHECK > 0 | **Added 2026-09-17 (migration 0091).** Only on FinishedGood items. How many more of this finished good the line should always be able to build: a component is flagged low on the Line Inventory sidebar when on hand < rolled-up BOM QtyPer x this value. NULL = no low flag for this FG. |
```

Add a revision-history row at the top of the table (keep the existing format):
`| 2.2a | 2026-09-17 | Blue Ridge Automation | Parts.Item.BoxQuantity + LowInventoryHorizon (migration 0091) for the M&A Line Inventory sidebar. |`

- [ ] **Step 5: Regenerate extended properties (ASCII check)**

Run: `node sql/scripts/gen_extended_properties.js`
Expected: `R__Descriptions_ExtendedProperties.sql` rewritten with `Parts.Item.BoxQuantity` and
`LowInventoryHorizon` entries.

Then run: `git diff --stat sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql`
Expected: a small diff.

Then run: `python -c "d=open('sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql','rb').read(); print([i for i,b in enumerate(d) if b>127][:5])"`
Expected: `[]`. If it isn't empty, the generator's ASCII folding missed a character from your doc text:
replace it with ASCII in the doc and regenerate.

- [ ] **Step 6: Run the test to make sure it passes**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "030_Item_BoxQuantity"`
Expected: 4 passed, 0 failed.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/versioned/0091_line_inventory_sidebar.sql sql/tests/0008_Parts_Item/030_Item_BoxQuantity_Horizon.sql MPP_MES_DATA_MODEL.md sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql
git commit -m "feat(sql): Item.BoxQuantity + LowInventoryHorizon (0091) for the line inventory sidebar"
```

---

### Task 2: Item_Update / Item_Get carry the two fields

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_Item_Update.sql`
- Modify: `sql/migrations/repeatable/R__Parts_Item_Get.sql`
- Test: `sql/tests/0008_Parts_Item/030_Item_BoxQuantity_Horizon.sql` (append phases)

**Interfaces:**
- Consumes: Task 1 columns.
- Produces:
  - `Parts.Item_Update` gains `@BoxQuantity INT = NULL, @LowInventoryHorizon INT = NULL`, declared **after**
    `@CrtEnabled`. Semantics: NULL = unchanged, 0 = clear, > 0 = set. Result shape stays
    `(Status, Message)`.
  - `Parts.Item_Get` appends `BoxQuantity, LowInventoryHorizon` as its **last two** columns.

- [ ] **Step 1: Append the failing phases**

In `030_Item_BoxQuantity_Horizon.sql`, replace the line `-- (Task 2 appends the Item_Update phases above this line.)` with:

```sql
-- =============================================
-- Phase 2: set on the right type
-- =============================================
DECLARE @Pt BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-PT');
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-FG');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin', @UomId = 1, @AppUserId = 1, @BoxQuantity = 5000;
INSERT INTO @R EXEC Parts.Item_Update @Id = @Fg, @Description = N'T030 finished',  @UomId = 1, @AppUserId = 1, @LowInventoryHorizon = 50;
DECLARE @Ok NVARCHAR(10) = (SELECT CAST(SUM(CAST(Status AS INT)) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Update] both sets succeed', @Expected = N'2', @Actual = @Ok;
DECLARE @Box NVARCHAR(10) = (SELECT CAST(BoxQuantity AS NVARCHAR(10)) FROM Parts.Item WHERE Id = @Pt);
EXEC test.Assert_IsEqual @TestName = N'[Update] BoxQuantity stored', @Expected = N'5000', @Actual = @Box;
DECLARE @Hz NVARCHAR(10) = (SELECT CAST(LowInventoryHorizon AS NVARCHAR(10)) FROM Parts.Item WHERE Id = @Fg);
EXEC test.Assert_IsEqual @TestName = N'[Update] horizon stored', @Expected = N'50', @Actual = @Hz;
DECLARE @Log NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog WHERE EntityId = @Pt ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[Update] audit prose names BoxQuantity', @HaystackStr = @Log, @NeedleStr = N'BoxQuantity';
GO

-- =============================================
-- Phase 3: omitted preserves (a save that does not know the fields)
-- =============================================
DECLARE @Pt BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-PT');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin v2', @UomId = 1, @AppUserId = 1;
DECLARE @Box NVARCHAR(10) = (SELECT CAST(BoxQuantity AS NVARCHAR(10)) FROM Parts.Item WHERE Id = @Pt);
EXEC test.Assert_IsEqual @TestName = N'[Preserve] omitted BoxQuantity kept', @Expected = N'5000', @Actual = @Box;
GO

-- =============================================
-- Phase 4: 0 clears
-- =============================================
DECLARE @Pt BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-PT');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin v2', @UomId = 1, @AppUserId = 1, @BoxQuantity = 0;
DECLARE @S NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Clear] status 1', @Expected = N'1', @Actual = @S;
DECLARE @IsNull NVARCHAR(1) = (SELECT CASE WHEN BoxQuantity IS NULL THEN N'1' ELSE N'0' END FROM Parts.Item WHERE Id = @Pt);
EXEC test.Assert_IsEqual @TestName = N'[Clear] BoxQuantity now NULL', @Expected = N'1', @Actual = @IsNull;
GO

-- =============================================
-- Phase 5: rejections (wrong type, negative)
-- =============================================
DECLARE @Co BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-CO');
DECLARE @Pt BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-PT');
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R1 EXEC Parts.Item_Update @Id = @Co, @Description = N'T030 casting', @UomId = 1, @AppUserId = 1, @BoxQuantity = 100;
DECLARE @S1 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R1);
EXEC test.Assert_IsEqual @TestName = N'[Reject] BoxQuantity on a Component', @Expected = N'0', @Actual = @S1;
DECLARE @M1 NVARCHAR(500) = (SELECT Message FROM @R1);
EXEC test.Assert_Contains @TestName = N'[Reject] message names PassThrough', @HaystackStr = @M1, @NeedleStr = N'PassThrough';

DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R2 EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin v2', @UomId = 1, @AppUserId = 1, @LowInventoryHorizon = 50;
DECLARE @S2 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R2);
EXEC test.Assert_IsEqual @TestName = N'[Reject] horizon on a PassThrough', @Expected = N'0', @Actual = @S2;

DECLARE @R3 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R3 EXEC Parts.Item_Update @Id = @Pt, @Description = N'T030 dowel pin v2', @UomId = 1, @AppUserId = 1, @BoxQuantity = -1;
DECLARE @S3 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R3);
EXEC test.Assert_IsEqual @TestName = N'[Reject] negative BoxQuantity', @Expected = N'0', @Actual = @S3;
GO

-- =============================================
-- Phase 6: Item_Get returns both (last two columns)
-- =============================================
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T030-FG');
CREATE TABLE #G (
    Id BIGINT, ItemTypeId BIGINT, ItemTypeName NVARCHAR(100), PartNumber NVARCHAR(50), Description NVARCHAR(500),
    MacolaPartNumber NVARCHAR(50), DefaultSubLotQty INT, MaxLotSize INT, UomId BIGINT, UomCode NVARCHAR(20),
    UnitWeight DECIMAL(10,4), WeightUomId BIGINT, WeightUomCode NVARCHAR(20), CountryOfOrigin NVARCHAR(2),
    MaxParts INT, CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3), CreatedByUserId BIGINT, UpdatedByUserId BIGINT,
    DeprecatedAt DATETIME2(3), CrtEnabled BIT, BoxQuantity INT, LowInventoryHorizon INT);
INSERT INTO #G EXEC Parts.Item_Get @Id = @Fg;
DECLARE @GHz NVARCHAR(10) = (SELECT CAST(LowInventoryHorizon AS NVARCHAR(10)) FROM #G);
DROP TABLE #G;
EXEC test.Assert_IsEqual @TestName = N'[Get] horizon returned', @Expected = N'50', @Actual = @GHz;
GO
```

Before relying on `#G`, check the current `Item_Get` column list (it is quoted in the spec research:
`Id, ItemTypeId, ItemTypeName, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId,
UomCode, UnitWeight, WeightUomId, WeightUomCode, CountryOfOrigin, MaxParts, CreatedAt, UpdatedAt,
CreatedByUserId, UpdatedByUserId, DeprecatedAt, CrtEnabled`). Then grep `sql/tests` for other
`INSERT ... EXEC Parts.Item_Get` captures and widen each of them by the same two columns.

- [ ] **Step 2: Run to verify failure**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "030_Item_BoxQuantity"`
Expected: FAIL. The procedure has no `@BoxQuantity` parameter ("has too many arguments specified"), and `#G`
has a column-count mismatch.

- [ ] **Step 3: Implement in `R__Parts_Item_Update.sql`**

1. **Header:** add a change-log line under the 2.4 entry:
   ```sql
   --   2026-09-17 - 2.5 - Line inventory sidebar (0091): @BoxQuantity (PassThrough only)
   --                       and @LowInventoryHorizon (FinishedGood only), declared last.
   --                       NULL-PRESERVING with 0 = clear (same deliberate deviation as
   --                       @CrtEnabled): a caller that does not know the fields can never
   --                       wipe them. Result-set shape UNCHANGED (Status, Message).
   ```
2. **Parameters:** change `@CrtEnabled       BIT            = NULL` to
   ```sql
       @CrtEnabled          BIT            = NULL,
       @BoxQuantity         INT            = NULL,
       @LowInventoryHorizon INT            = NULL
   ```
3. **`@Params` JSON:** after `@CrtEnabled AS CrtEnabled` add
   `, @BoxQuantity AS BoxQuantity, @LowInventoryHorizon AS LowInventoryHorizon`.
4. **Validation:** after the `MaxParts must be greater than zero` block, add these checks (each one follows
   the same failure pattern as its neighbours):
   ```sql
        -- Business rule: BoxQuantity / LowInventoryHorizon never negative (0 = clear)
        IF (@BoxQuantity IS NOT NULL AND @BoxQuantity < 0)
           OR (@LowInventoryHorizon IS NOT NULL AND @LowInventoryHorizon < 0)
        BEGIN
            SET @Message = N'Box quantity and low-inventory horizon cannot be negative.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @TypeCode NVARCHAR(30) = (
            SELECT it.Code FROM Parts.Item i
            INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
            WHERE i.Id = @Id);

        -- Business rule: a box quantity belongs to a bought (PassThrough) part
        IF ISNULL(@BoxQuantity, 0) > 0 AND @TypeCode <> N'PassThrough'
        BEGIN
            SET @Message = N'Box quantity can only be set on a PassThrough part.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Business rule: a low-inventory horizon belongs to a FinishedGood
        IF ISNULL(@LowInventoryHorizon, 0) > 0 AND @TypeCode <> N'FinishedGood'
        BEGIN
            SET @Message = N'Low-inventory horizon can only be set on a FinishedGood.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END
   ```
   These checks must sit after the "target must exist" check, so that `@TypeCode` is non-NULL.
5. **Old values:** add `DECLARE @OldBoxQuantity INT; DECLARE @OldLowInventoryHorizon INT;`. In the
   `SELECT @OldPartNumber = ...` add `@OldBoxQuantity = BoxQuantity, @OldLowInventoryHorizon = LowInventoryHorizon`.
6. **Resolve the effective values:** place this directly after the `SET @CrtEnabled = ...` line:
   ```sql
        -- NULL = leave alone; 0 = clear; > 0 = set.
        SET @BoxQuantity = CASE WHEN @BoxQuantity IS NULL THEN @OldBoxQuantity
                                WHEN @BoxQuantity = 0 THEN NULL ELSE @BoxQuantity END;
        SET @LowInventoryHorizon = CASE WHEN @LowInventoryHorizon IS NULL THEN @OldLowInventoryHorizon
                                        WHEN @LowInventoryHorizon = 0 THEN NULL ELSE @LowInventoryHorizon END;
   ```
7. **OldValue JSON:** in the `@OldValue` SELECT, after `i.CrtEnabled` add
   `, i.BoxQuantity, i.LowInventoryHorizon`.
8. **Audit prose (`@Diff` `CONCAT`):** append after the `CrtEnabled` CASE (keep the comma placement):
   ```sql
            ,
            CASE WHEN ISNULL(@OldBoxQuantity, -1) <> ISNULL(@BoxQuantity, -1)
                 THEN N', BoxQuantity ' + ISNULL(CAST(@OldBoxQuantity AS NVARCHAR(20)), N'null') + @Arrow + ISNULL(CAST(@BoxQuantity AS NVARCHAR(20)), N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(@OldLowInventoryHorizon, -1) <> ISNULL(@LowInventoryHorizon, -1)
                 THEN N', LowInventoryHorizon ' + ISNULL(CAST(@OldLowInventoryHorizon AS NVARCHAR(20)), N'null') + @Arrow + ISNULL(CAST(@LowInventoryHorizon AS NVARCHAR(20)), N'null')
                 ELSE N'' END
   ```
9. **`UPDATE`:** after `CrtEnabled = @CrtEnabled,` add
   `BoxQuantity = @BoxQuantity, LowInventoryHorizon = @LowInventoryHorizon,`.
10. **NewValue JSON:** find the NewValue snapshot built after the UPDATE (search for `@NewValue`). If it
    reads the row back, it picks the columns up once you add `i.BoxQuantity, i.LowInventoryHorizon` to its
    SELECT list. If it is built from the parameters, add `@BoxQuantity AS BoxQuantity,
    @LowInventoryHorizon AS LowInventoryHorizon`.

- [ ] **Step 4: Implement in `R__Parts_Item_Get.sql`**

Change the tail of the SELECT list to:

```sql
        i.CrtEnabled,         -- APPEND-LAST: see Result set note above
        i.BoxQuantity,        -- APPEND-LAST (2026-09-17, 0091)
        i.LowInventoryHorizon -- APPEND-LAST (2026-09-17, 0091)
```

Add a header change-log line: `--   2026-09-17 - BoxQuantity, LowInventoryHorizon appended (line inventory sidebar).`

- [ ] **Step 5: Run the tests**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0008_Parts_Item"`
Expected: 0 failed. That covers the existing `010_Item_crud.sql` update tests plus the new file.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_Item_Update.sql sql/migrations/repeatable/R__Parts_Item_Get.sql sql/tests/0008_Parts_Item/030_Item_BoxQuantity_Horizon.sql
git commit -m "feat(sql): Item_Update/Item_Get carry BoxQuantity + LowInventoryHorizon (null-preserving, 0 clears)"
```
Also stage any other test files you widened in Step 1.

---

### Task 3: `Lots.Lot_GetLineInventorySummary`

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_GetLineInventorySummary.sql`
- Test: `sql/tests/0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql`

**Interfaces:**
- Consumes: Task 1 columns.
- Produces: `EXEC Lots.Lot_GetLineInventorySummary @LocationId BIGINT, @FinishedGoodItemId BIGINT = NULL`
  returns rows with these columns:

  | Column | Type |
  |---|---|
  | `ItemId` | BIGINT |
  | `Description` | NVARCHAR(500) |
  | `Available` | INT |
  | `Threshold` | INT NULL |
  | `IsLow` | BIT |
  | `BoxQuantity` | INT NULL |
  | `AddLotMode` | NVARCHAR(10): `OneTap` / `AskQty` / `None` |
  | `RunningFinishedGoods` | NVARCHAR(1000) NULL |
  | `LowInventoryHorizon` | INT NULL |

  Rows are ordered `IsLow DESC, Description, ItemId`. The set is empty when there is no WorkCenter
  ancestor.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql`:

```sql
-- =============================================
-- File:         0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Lots.Lot_GetLineInventorySummary (line inventory sidebar spec).
--   Line MA1-COMPBR (WorkCenter); called with its Assembly Out terminal
--   MA1-COMPBR-AOUT (resolves up to the line).
--   BOM tree:  FG  <- SA x2 + PIN x3 + GASKET x1
--              SA  <- CAST x1 + PIN x1
--   so per FG: SA 2, CAST 2, PIN 3 + 2x1 = 5, GASKET 1.  Horizon 10 ->
--   thresholds SA 20, CAST 20, PIN 50, GASKET 10.
--   On hand at the line: PIN 60 (not low), CAST 5 (low), GASKET 0 (listed,
--   low), plus an unrelated PassThrough BOLT 7 (listed, no threshold) and
--   an FG LOT (never listed).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql';
GO

-- ---- cleanup ----
DECLARE @Fg0 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-FG');
DECLARE @Sa0 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-SA');
DELETE FROM Lots.Container WHERE ItemId = @Fg0;
DELETE FROM Lots.Lot WHERE LotName LIKE N'T099-%';
DELETE bl FROM Parts.BomLine bl INNER JOIN Parts.Bom b ON b.Id = bl.BomId WHERE b.ParentItemId IN (@Fg0, @Sa0);
DELETE FROM Parts.Bom WHERE ParentItemId IN (@Fg0, @Sa0);
DELETE FROM Parts.ContainerConfig WHERE ItemId = @Fg0;
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T099-%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @TFg BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
DECLARE @TSa BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'SubAssembly');
DECLARE @TCo BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @TPt BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId, BoxQuantity, LowInventoryHorizon) VALUES
    (@TFg, N'T099-FG',     N'T099 finished good', 1, @Now, 1, NULL, 10),
    (@TSa, N'T099-SA',     N'T099 sub assembly',  1, @Now, 1, NULL, NULL),
    (@TCo, N'T099-CAST',   N'T099 casting',       1, @Now, 1, NULL, NULL),
    (@TPt, N'T099-PIN',    N'T099 dowel pin',     1, @Now, 1, 5000, NULL),
    (@TPt, N'T099-GASKET', N'T099 gasket',        1, @Now, 1, NULL, NULL),
    (@TPt, N'T099-BOLT',   N'T099 bolt',          1, @Now, 1, 2000, NULL);
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-FG');
DECLARE @Sa BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-SA');
DECLARE @Ca BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-CAST');
DECLARE @Pi BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-PIN');
DECLARE @Ga BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-GASKET');
DECLARE @Bo BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-BOLT');

-- FG BOM: a Deprecated v1 (must be ignored) + Published v2
INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (@Fg, 1, @Now, @Now, @Now, 1, @Now);
INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @Pi, 99, 1, 1);
INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
    VALUES (@Fg, 2, @Now, @Now, 1, @Now);
DECLARE @FgBom BIGINT = SCOPE_IDENTITY();
INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES
    (@FgBom, @Sa, 2, 1, 1), (@FgBom, @Pi, 3, 1, 2), (@FgBom, @Ga, 1, 1, 3);
INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
    VALUES (@Sa, 1, @Now, @Now, 1, @Now);
DECLARE @SaBom BIGINT = SCOPE_IDENTITY();
INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES
    (@SaBom, @Ca, 1, 1, 1), (@SaBom, @Pi, 1, 1, 2);

DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES
    (N'T099-PIN1',  @Pi, 2, 1,       40, 40, @Line, 1, @Now),
    (N'T099-PIN2',  @Pi, 2, 1,       20, 20, @Line, 1, @Now),
    (N'T099-PINX',  @Pi, 2, @Closed, 99, 99, @Line, 1, @Now),   -- closed: excluded
    (N'T099-CAST1', @Ca, 1, 1,        5,  5, @Line, 1, @Now),
    (N'T099-BOLT1', @Bo, 2, 1,        7,  7, @Line, 1, @Now),
    (N'T099-FG1',   @Fg, 1, 1,       30, 30, @Line, 1, @Now);   -- FG: never listed

-- container config (needed for an open container)
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Fg, 4, 10, 0, N'ByCount', @Now);
GO

-- =============================================
-- Phase 1: idle line (no open container, no hint) -> only on-hand non-FG, no low
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @R TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, Threshold INT, IsLow BIT,
                  BoxQuantity INT, AddLotMode NVARCHAR(10), RunningFinishedGoods NVARCHAR(1000), LowInventoryHorizon INT);
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term;
DELETE FROM @R WHERE Description NOT LIKE N'T099 %';   -- ignore other fixtures' stock on this line

DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Idle] 3 on-hand parts (PIN, CAST, BOLT)', @Expected = N'3', @Actual = @N;
DECLARE @Low NVARCHAR(10) = (SELECT CAST(SUM(CAST(IsLow AS INT)) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Idle] nothing low', @Expected = N'0', @Actual = @Low;
DECLARE @PinAvail NVARCHAR(10) = (SELECT CAST(Available AS NVARCHAR(10)) FROM @R WHERE Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[Idle] PIN available 60 (closed LOT excluded)', @Expected = N'60', @Actual = @PinAvail;
DECLARE @FgRows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @R WHERE Description = N'T099 finished good');
EXEC test.Assert_IsEqual @TestName = N'[Idle] FG never listed', @Expected = N'0', @Actual = @FgRows;
DECLARE @RunNull NVARCHAR(1) = (SELECT TOP 1 CASE WHEN RunningFinishedGoods IS NULL THEN N'1' ELSE N'0' END FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Idle] no running FG', @Expected = N'1', @Actual = @RunNull;
GO

-- =============================================
-- Phase 2: hint FG (selected on screen, no container) -> BOM rollup + low flags
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-FG');
DECLARE @R TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, Threshold INT, IsLow BIT,
                  BoxQuantity INT, AddLotMode NVARCHAR(10), RunningFinishedGoods NVARCHAR(1000), LowInventoryHorizon INT);
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @FinishedGoodItemId = @Fg;
DELETE FROM @R WHERE Description NOT LIKE N'T099 %';

DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Hint] 5 parts (SA, CAST, PIN, GASKET, BOLT)', @Expected = N'5', @Actual = @N;
DECLARE @PinT NVARCHAR(10) = (SELECT CAST(Threshold AS NVARCHAR(10)) FROM @R WHERE Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[Hint] PIN threshold 50 (3 + 2x1, x10; deprecated BOM ignored)', @Expected = N'50', @Actual = @PinT;
DECLARE @PinL NVARCHAR(1) = (SELECT CAST(IsLow AS NVARCHAR(1)) FROM @R WHERE Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[Hint] PIN not low (60 >= 50)', @Expected = N'0', @Actual = @PinL;
DECLARE @CaT NVARCHAR(10) = (SELECT CAST(Threshold AS NVARCHAR(10)) FROM @R WHERE Description = N'T099 casting');
EXEC test.Assert_IsEqual @TestName = N'[Hint] CAST threshold 20 (1 x 2 x 10)', @Expected = N'20', @Actual = @CaT;
DECLARE @CaL NVARCHAR(1) = (SELECT CAST(IsLow AS NVARCHAR(1)) FROM @R WHERE Description = N'T099 casting');
EXEC test.Assert_IsEqual @TestName = N'[Hint] CAST low (5 < 20)', @Expected = N'1', @Actual = @CaL;
DECLARE @GaA NVARCHAR(10) = (SELECT CAST(Available AS NVARCHAR(10)) + N'/' + CAST(IsLow AS NVARCHAR(1)) FROM @R WHERE Description = N'T099 gasket');
EXEC test.Assert_IsEqual @TestName = N'[Hint] GASKET listed at 0 and low', @Expected = N'0/1', @Actual = @GaA;
DECLARE @SaL NVARCHAR(1) = (SELECT CAST(IsLow AS NVARCHAR(1)) FROM @R WHERE Description = N'T099 sub assembly');
EXEC test.Assert_IsEqual @TestName = N'[Hint] SA listed and low (0 < 20)', @Expected = N'1', @Actual = @SaL;
DECLARE @BoT NVARCHAR(1) = (SELECT CASE WHEN Threshold IS NULL AND IsLow = 0 THEN N'1' ELSE N'0' END FROM @R WHERE Description = N'T099 bolt');
EXEC test.Assert_IsEqual @TestName = N'[Hint] BOLT (not in BOM) has no threshold', @Expected = N'1', @Actual = @BoT;
DECLARE @Hz NVARCHAR(10) = (SELECT TOP 1 CAST(LowInventoryHorizon AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Hint] horizon 10 reported', @Expected = N'10', @Actual = @Hz;
DECLARE @Run NVARCHAR(1000) = (SELECT TOP 1 RunningFinishedGoods FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Hint] running FG named', @Expected = N'T099 finished good', @Actual = @Run;
GO

-- =============================================
-- Phase 3: AddLotMode + result ORDER (captured with an IDENTITY to keep proc order)
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-FG');
CREATE TABLE #O (Seq INT IDENTITY(1,1), ItemId BIGINT, Description NVARCHAR(500), Available INT, Threshold INT, IsLow BIT,
                 BoxQuantity INT, AddLotMode NVARCHAR(10), RunningFinishedGoods NVARCHAR(1000), LowInventoryHorizon INT);
INSERT INTO #O (ItemId, Description, Available, Threshold, IsLow, BoxQuantity, AddLotMode, RunningFinishedGoods, LowInventoryHorizon)
EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @FinishedGoodItemId = @Fg;
DECLARE @Order NVARCHAR(400) = (
    SELECT STRING_AGG(REPLACE(Description, N'T099 ', N''), N',') WITHIN GROUP (ORDER BY Seq)
    FROM #O WHERE Description LIKE N'T099 %');
EXEC test.Assert_IsEqual @TestName = N'[Order] low first then alphabetical',
    @Expected = N'casting,gasket,sub assembly,bolt,dowel pin', @Actual = @Order;
DECLARE @Modes NVARCHAR(200) = (
    SELECT STRING_AGG(REPLACE(Description, N'T099 ', N'') + N'=' + AddLotMode, N',') WITHIN GROUP (ORDER BY Seq)
    FROM #O WHERE Description LIKE N'T099 %');
DROP TABLE #O;
EXEC test.Assert_IsEqual @TestName = N'[Mode] OneTap / AskQty / None by type + box',
    @Expected = N'casting=None,gasket=AskQty,sub assembly=None,bolt=OneTap,dowel pin=OneTap', @Actual = @Modes;
GO

-- =============================================
-- Phase 4: open container (no hint) makes the FG "running"; NULL horizon -> no flags
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-FG');
DECLARE @Cfg BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Fg);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, OpenedAt, CreatedByUserId)
    VALUES (@Fg, @Cfg, @Term, 1, SYSUTCDATETIME(), 1);
DECLARE @R TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, Threshold INT, IsLow BIT,
                  BoxQuantity INT, AddLotMode NVARCHAR(10), RunningFinishedGoods NVARCHAR(1000), LowInventoryHorizon INT);
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term;
DECLARE @CaL NVARCHAR(1) = (SELECT CAST(IsLow AS NVARCHAR(1)) FROM @R WHERE Description = N'T099 casting');
EXEC test.Assert_IsEqual @TestName = N'[Container] open container makes FG running (CAST low)', @Expected = N'1', @Actual = @CaL;

UPDATE Parts.Item SET LowInventoryHorizon = NULL WHERE Id = @Fg;
DELETE FROM @R;
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term;
DELETE FROM @R WHERE Description NOT LIKE N'T099 %';
DECLARE @Low NVARCHAR(10) = (SELECT CAST(SUM(CAST(IsLow AS INT)) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[NoHorizon] no low flags', @Expected = N'0', @Actual = @Low;
DECLARE @GaListed NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @R WHERE Description = N'T099 gasket');
EXEC test.Assert_IsEqual @TestName = N'[NoHorizon] BOM parts still listed', @Expected = N'1', @Actual = @GaListed;
UPDATE Parts.Item SET LowInventoryHorizon = 10 WHERE Id = @Fg;
GO

-- =============================================
-- Phase 5: empty sets (NULL location, location with no WorkCenter ancestor)
-- =============================================
DECLARE @R TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, Threshold INT, IsLow BIT,
                  BoxQuantity INT, AddLotMode NVARCHAR(10), RunningFinishedGoods NVARCHAR(1000), LowInventoryHorizon INT);
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = NULL;
DECLARE @Area BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1');
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Area;
DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Empty] NULL / area-level location -> empty', @Expected = N'0', @Actual = @N;
GO

-- ---- cleanup ----
DECLARE @Fg0 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-FG');
DECLARE @Sa0 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'T099-SA');
DELETE FROM Lots.Container WHERE ItemId = @Fg0;
DELETE FROM Lots.Lot WHERE LotName LIKE N'T099-%';
DELETE bl FROM Parts.BomLine bl INNER JOIN Parts.Bom b ON b.Id = bl.BomId WHERE b.ParentItemId IN (@Fg0, @Sa0);
DELETE FROM Parts.Bom WHERE ParentItemId IN (@Fg0, @Sa0);
DELETE FROM Parts.ContainerConfig WHERE ItemId = @Fg0;
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T099-%';
GO

EXEC test.EndTestFile;
GO
```

Before running, confirm that `MA1` is an Area (not a WorkCenter) and that `MA1-COMPBR` is a WorkCenter.
Run `SELECT l.Code, ltd.LocationTypeId FROM Location.Location l JOIN Location.LocationTypeDefinition ltd ON
ltd.Id = l.LocationTypeDefinitionId WHERE l.Code IN (N'MA1', N'MA1-COMPBR')` against `MPP_MES_Test` after a
`Run-Tests` reset. The expected LocationTypeIds are 3 and 4. If a fixture insert trips a NOT NULL column the
test doesn't set, add that column with the value the neighbouring test (094) uses.

- [ ] **Step 2: Run to verify failure**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "099_Lot_GetLineInventorySummary"`
Expected: FAIL, "Could not find stored procedure 'Lots.Lot_GetLineInventorySummary'".

- [ ] **Step 3: Implement the proc**

Create `sql/migrations/repeatable/R__Lots_Lot_GetLineInventorySummary.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_Lot_GetLineInventorySummary.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.0
-- Description: The M&A Line Inventory sidebar's single read (spec
--              2026-09-17-line-inventory-sidebar-design.md). One row per part.
--
--              LINE. @LocationId (the terminal's session cell) resolves up to its
--              WorkCenter ancestor -- the same resolution as
--              Location.Terminal_ListByLineOf. The pool is every open LOT
--              (status <> Closed, InventoryAvailable > 0) at that WorkCenter or
--              any descendant (line-resident flow).
--
--              RUNNING FINISHED GOODS. Every FinishedGood with an OPEN
--              Lots.Container anywhere under the line, plus @FinishedGoodItemId
--              (the FG the Assembly OUT screen has selected before a container
--              opens).
--
--              THRESHOLD. For each running FG with a LowInventoryHorizon, walk
--              its active BOM tree (Published, not Deprecated, highest
--              VersionNumber per parent), multiplying QtyPer down the levels and
--              summing a child reached by several paths. Threshold =
--              CEILING(rolled qty x horizon); the larger wins across FGs.
--              IsLow = Threshold IS NOT NULL AND Available < Threshold.
--
--              ROWS. Every non-FG part in a running FG's tree (even at 0 on
--              hand) plus every other non-FG part on hand. FinishedGood items
--              are never returned.
--
--              ADD-LOT MODE. PassThrough with BoxQuantity -> OneTap; PassThrough
--              without -> AskQty; anything else -> None.
--
--              HEADER. RunningFinishedGoods (comma-joined descriptions) and
--              LowInventoryHorizon (the largest running horizon) are repeated on
--              every row so the proc keeps one result set.
--
--              ORDER. IsLow DESC, Description, ItemId.
--
--              FDS-11-011: no OUTPUT params; empty set = nothing to show
--              (NULL location or no WorkCenter ancestor).
--
--              BOM recursion is capped at 10 levels (MPP trees are 2-3 deep);
--              the active-BOM set is materialized first because a recursive CTE
--              member may not contain an aggregate.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetLineInventorySummary
    @LocationId         BIGINT,
    @FinishedGoodItemId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LocationId IS NULL
        RETURN;

    DECLARE @LineId BIGINT = (
        SELECT TOP 1 l.Id
        FROM Location.ufn_AncestorLocationIds(@LocationId) a
        INNER JOIN Location.Location l ON l.Id = a.LocationId
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        WHERE ltd.LocationTypeId = 4);   -- WorkCenter tier

    IF @LineId IS NULL
        RETURN;

    DECLARE @FgTypeId          BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
    DECLARE @PassThroughTypeId BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');
    DECLARE @ClosedStatusId    BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
    DECLARE @OpenContainerId   BIGINT = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Open');

    -- 1. the line and everything under it
    DECLARE @LineLocs TABLE (Id BIGINT NOT NULL PRIMARY KEY);
    WITH Descendants AS (
        SELECT @LineId AS Id
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    )
    INSERT INTO @LineLocs (Id) SELECT Id FROM Descendants;

    -- 2. running finished goods
    DECLARE @Running TABLE (ItemId BIGINT NOT NULL PRIMARY KEY, Horizon INT NULL, Description NVARCHAR(500) NULL);
    INSERT INTO @Running (ItemId, Horizon, Description)
    SELECT i.Id, i.LowInventoryHorizon, ISNULL(i.Description, i.PartNumber)
    FROM Parts.Item i
    WHERE i.ItemTypeId = @FgTypeId
      AND (   i.Id = @FinishedGoodItemId
           OR EXISTS (SELECT 1 FROM Lots.Container c
                      WHERE c.ItemId = i.Id
                        AND c.ContainerStatusCodeId = @OpenContainerId
                        AND c.CurrentLocationId IN (SELECT Id FROM @LineLocs)));

    -- 3. active BOM per parent (materialized: no aggregate inside the recursion)
    DECLARE @ActiveBom TABLE (ParentItemId BIGINT NOT NULL PRIMARY KEY, BomId BIGINT NOT NULL);
    INSERT INTO @ActiveBom (ParentItemId, BomId)
    SELECT x.ParentItemId, x.Id
    FROM (
        SELECT b.ParentItemId, b.Id,
               ROW_NUMBER() OVER (PARTITION BY b.ParentItemId ORDER BY b.VersionNumber DESC, b.Id DESC) AS rn
        FROM Parts.Bom b
        WHERE b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL
    ) x
    WHERE x.rn = 1;

    -- 4. rolled-up requirement per part, largest across running FGs
    DECLARE @Req TABLE (ItemId BIGINT NOT NULL PRIMARY KEY, Threshold INT NULL);
    WITH Tree AS (
        SELECT r.ItemId AS RootItemId, bl.ChildItemId,
               CAST(bl.QtyPer AS DECIMAL(18,4)) AS RolledQty, 1 AS Depth
        FROM @Running r
        INNER JOIN @ActiveBom ab   ON ab.ParentItemId = r.ItemId
        INNER JOIN Parts.BomLine bl ON bl.BomId = ab.BomId
        UNION ALL
        SELECT t.RootItemId, bl.ChildItemId,
               CAST(t.RolledQty * bl.QtyPer AS DECIMAL(18,4)), t.Depth + 1
        FROM Tree t
        INNER JOIN @ActiveBom ab   ON ab.ParentItemId = t.ChildItemId
        INNER JOIN Parts.BomLine bl ON bl.BomId = ab.BomId
        WHERE t.Depth < 10
    )
    INSERT INTO @Req (ItemId, Threshold)
    SELECT n.ChildItemId,
           MAX(CASE WHEN r.Horizon IS NULL THEN NULL
                    ELSE CAST(CEILING(n.Qty * r.Horizon) AS INT) END)
    FROM (SELECT RootItemId, ChildItemId, SUM(RolledQty) AS Qty
          FROM Tree GROUP BY RootItemId, ChildItemId) n
    INNER JOIN @Running r ON r.ItemId = n.RootItemId
    GROUP BY n.ChildItemId;

    -- 5. on hand at the line
    DECLARE @OnHand TABLE (ItemId BIGINT NOT NULL PRIMARY KEY, Available INT NOT NULL);
    INSERT INTO @OnHand (ItemId, Available)
    SELECT l.ItemId, SUM(l.InventoryAvailable)
    FROM Lots.Lot l
    WHERE l.CurrentLocationId IN (SELECT Id FROM @LineLocs)
      AND l.LotStatusId <> @ClosedStatusId
      AND l.InventoryAvailable > 0
    GROUP BY l.ItemId;

    DECLARE @RunningText NVARCHAR(1000) =
        (SELECT STRING_AGG(Description, N', ') WITHIN GROUP (ORDER BY Description) FROM @Running);
    DECLARE @Horizon INT = (SELECT MAX(Horizon) FROM @Running);

    -- 6. rows
    SELECT
        i.Id                                   AS ItemId,
        ISNULL(i.Description, i.PartNumber)    AS Description,
        ISNULL(oh.Available, 0)                AS Available,
        rq.Threshold                           AS Threshold,
        CAST(CASE WHEN rq.Threshold IS NOT NULL AND ISNULL(oh.Available, 0) < rq.Threshold
                  THEN 1 ELSE 0 END AS BIT)    AS IsLow,
        i.BoxQuantity                          AS BoxQuantity,
        CAST(CASE WHEN i.ItemTypeId <> @PassThroughTypeId THEN N'None'
                  WHEN i.BoxQuantity IS NOT NULL THEN N'OneTap'
                  ELSE N'AskQty' END AS NVARCHAR(10)) AS AddLotMode,
        @RunningText                           AS RunningFinishedGoods,
        @Horizon                               AS LowInventoryHorizon
    FROM Parts.Item i
    LEFT JOIN @OnHand oh ON oh.ItemId = i.Id
    LEFT JOIN @Req    rq ON rq.ItemId = i.Id
    WHERE (oh.ItemId IS NOT NULL OR rq.ItemId IS NOT NULL)
      AND i.ItemTypeId <> @FgTypeId
    ORDER BY IsLow DESC, Description ASC, i.Id ASC;
END;
GO
```

- [ ] **Step 4: Run the test**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "099_Lot_GetLineInventorySummary"`
Expected: 0 failed.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetLineInventorySummary.sql sql/tests/0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql
git commit -m "feat(sql): Lot_GetLineInventorySummary -- line parts, BOM-horizon low flag, add-lot mode"
```

---

### Task 4: Inventory popup read excludes finished goods

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_GetLineInventoryByPart.sql`
- Test: `sql/tests/0027_PlantFloor_Machining/100_Lot_GetLineInventoryByPart.sql`

**Interfaces:**
- Produces: the same 8 columns and order as today, with FinishedGood items removed. The ordering changes to
  `Description, PartNumber, arrival, LotId` so that the popup groups read alphabetically by description.

- [ ] **Step 1: Add the failing assertion**

In `100_Lot_GetLineInventoryByPart.sql`, add a new fixture item and LOT in the fixture batch (after the
`I1T-B1` insert):

```sql
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-I1-FG')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES ((SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood'), N'P-I1-FG', N'I1 finished good', 1, @Now, 1);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'I1T-FG1', (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-I1-FG'), 1, 1, 9, 9, @Cell, 1, @Now);
```

Add `(SELECT Id FROM Parts.Item WHERE PartNumber = N'P-I1-FG')` to both cleanup `WHERE l.ItemId IN (...)`
lists (the `LotName LIKE N'I1T-%'` clause already covers the LOT). Then add a new phase before the final
cleanup that captures into the file's existing 8-column table shape (copy the table declaration used by the
file's first phase) and asserts:

```sql
DECLARE @FgN NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Rows WHERE PartNumber = N'P-I1-FG');
EXEC test.Assert_IsEqual @TestName = N'[I1] finished goods excluded', @Expected = N'0', @Actual = @FgN;
```

(`@Rows` is whatever the file names its capture table; use that name.) If an existing assertion checks order
by `PartNumber` across A/B, it still holds, because the descriptions `I1 inventory part A/B` sort the same way.

- [ ] **Step 2: Run to verify failure**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "100_Lot_GetLineInventoryByPart"`
Expected: FAIL on `[I1] finished goods excluded` (actual 1).

- [ ] **Step 3: Implement**

In `R__Lots_Lot_GetLineInventoryByPart.sql`:
- bump the header to `Version: 1.2` / `Modified: 2026-09-17` and add a v1.2 note ("FinishedGood items
  excluded and ordering by Description first, for the Line Inventory popup grouping; column shape
  unchanged");
- add `AND i.ItemTypeId <> (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood')` to the `WHERE`;
- change the `ORDER BY` to

```sql
    ORDER BY ISNULL(i.Description, i.PartNumber) ASC,
             i.PartNumber ASC,
             COALESCE(la.ArrivedAtUtc, l.CreatedAt) ASC,
             l.Id ASC;
```

- [ ] **Step 4: Run the tests**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "PlantFloor"`
Expected: 0 failed (this also covers `0029/090_FinishedGoodClose_OnComplete.sql`, which calls this proc;
if that file relied on FG rows coming back from this proc, stop and report rather than changing it).

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetLineInventoryByPart.sql sql/tests/0027_PlantFloor_Machining/100_Lot_GetLineInventoryByPart.sql
git commit -m "feat(sql): line inventory popup read excludes finished goods, orders by description"
```

---

### Task 5: Named queries + Python glue

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/lots/Lot_GetLineInventorySummary/query.sql`
- Create: `ignition/projects/Core/ignition/named-query/lots/Lot_GetLineInventorySummary/resource.json`
- Modify: `ignition/projects/Core/ignition/named-query/parts/Item_Update/query.sql` + `resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Item/code.py`

**Interfaces:**
- Consumes: Task 2 and Task 3 proc signatures.
- Produces (`BlueRidge.Lots.Lot`):
  - `getLineInventorySummary(locationId, finishedGoodItemId=None) -> list[dict]` (proc rows; `[]` on no
    location).
  - `getLineInventoryInstances(locationId, finishedGoodItemId=None, _refreshToken=None) -> list[dict]`.
    Each dict has the keys `itemId, description, available, availableText, isLow, addLotMode,
    boxQuantity, buttonText, locationId`.
  - `getLineInventoryHeader(locationId, finishedGoodItemId=None, _refreshToken=None) -> str`.
  - `checkInBox(itemId, locationId, pieceCount, appUserId=None, terminalLocationId=None) -> dict`. The
    dict has `{Status, Message, NewId, MintedLotName}`.
  - `checkInAndNotify(itemId, locationId, pieceCount, description, appUserId=None, terminalLocationId=None)
    -> dict`. Perspective-session only:
    it toasts, raises the CRT notice and sends the page message `inventoryChanged`.
- Produces (`BlueRidge.Parts.Item`): `update(meta)` also forwards `boxQuantity` / `lowInventoryHorizon`
  (camel or Pascal); omitted = `None`.

Python is display glue only: it formats numbers and header text. It makes no low/button decisions.

- [ ] **Step 1: Create the NQ**

`named-query/lots/Lot_GetLineInventorySummary/query.sql`:

```sql
EXEC Lots.Lot_GetLineInventorySummary @LocationId = :locationId, @FinishedGoodItemId = :finishedGoodItemId
```

`resource.json`: copy `named-query/lots/Lot_GetLineInventoryByPart/resource.json` exactly, then change
`lastModification` to `{"actor": "claude", "timestamp": "2026-09-17T12:00:00Z"}` and `parameters` to:

```json
    "parameters": [
      {"type": "Parameter", "identifier": "locationId", "sqlType": 3},
      {"type": "Parameter", "identifier": "finishedGoodItemId", "sqlType": 3}
    ]
```

- [ ] **Step 2: Extend the Item_Update NQ**

`named-query/parts/Item_Update/query.sql`: change the last line to

```sql
    @CrtEnabled       = :crtEnabled,
    @BoxQuantity      = :boxQuantity,
    @LowInventoryHorizon = :lowInventoryHorizon
```

In its `resource.json`, append two entries to `parameters`:
`{"type": "Parameter", "identifier": "boxQuantity", "sqlType": 3}` and
`{"type": "Parameter", "identifier": "lowInventoryHorizon", "sqlType": 3}`. Keep the existing
`crtEnabled` entry's sqlType as-is.

- [ ] **Step 3: `BlueRidge.Parts.Item`**

In `update(meta)`:
- add to the docstring key list: `boxQuantity, lowInventoryHorizon (NULL-preserving; 0 clears -- same rule as
  crtEnabled, enforced in the proc)`;
- add two entries to the params dict:

```python
            "boxQuantity":         _pick("boxQuantity",         "BoxQuantity"),
            "lowInventoryHorizon": _pick("lowInventoryHorizon", "LowInventoryHorizon"),
```

In `_ITEM_SHAPE_KEYS`, append `"BoxQuantity", "LowInventoryHorizon",` after `"CrtEnabled",`.

- [ ] **Step 4: `BlueRidge.Lots.Lot` -- add after `getLineInventoryByPart`**

```python
def getLineInventorySummary(locationId, finishedGoodItemId=None):
    """Line Inventory sidebar rows (Lots.Lot_GetLineInventorySummary). One dict per
       part: ItemId, Description, Available, Threshold, IsLow, BoxQuantity,
       AddLotMode (OneTap/AskQty/None), RunningFinishedGoods, LowInventoryHorizon.
       Every rule (line resolution, running FG, BOM horizon, button mode) is in the
       proc. Returns [] when there is no location."""
    locationId = _u(locationId)
    if locationId is None:
        return []
    return BlueRidge.Common.Db.execList(
        "lots/Lot_GetLineInventorySummary",
        {"locationId": locationId, "finishedGoodItemId": _u(finishedGoodItemId)}) or []


def _thousands(n):
    try:
        return "{:,}".format(int(n))
    except (ValueError, TypeError):
        return "%s" % (n,)


def getLineInventoryInstances(locationId, finishedGoodItemId=None, _refreshToken=None):
    """Flex-repeater instances for Components/PlantFloor/LineInventory. Display
       formatting only (thousands separators, button caption). Scalar args only
       (ImmutableList re-eval rule); _refreshToken is the ignored re-read arg."""
    out = []
    for r in getLineInventorySummary(locationId, finishedGoodItemId):
        r = r or {}
        mode = r.get("AddLotMode") or "None"
        box = r.get("BoxQuantity")
        if mode == "OneTap":
            caption = "+" + _thousands(box)
        elif mode == "AskQty":
            caption = "+ LOT"
        else:
            caption = ""
        out.append({
            "itemId":        r.get("ItemId"),
            "description":   r.get("Description") or "",
            "available":     r.get("Available") or 0,
            "availableText": _thousands(r.get("Available") or 0),
            "isLow":         bool(r.get("IsLow")),
            "addLotMode":    mode,
            "boxQuantity":   box,
            "buttonText":    caption,
            "locationId":    _u(locationId),
        })
    return out


def getLineInventoryHeader(locationId, finishedGoodItemId=None, _refreshToken=None):
    """Subline for the Line Inventory panel header. Always returns a string."""
    rows = getLineInventorySummary(locationId, finishedGoodItemId)
    if not rows:
        return "No inventory at this line"
    running = rows[0].get("RunningFinishedGoods")
    horizon = rows[0].get("LowInventoryHorizon")
    if not running:
        return "No finished good running"
    if horizon is None:
        return "No low-stock horizon set for %s" % running
    return "Low below %s x %s" % (_thousands(horizon), running)


def checkInBox(itemId, locationId, pieceCount, appUserId=None, terminalLocationId=None):
    """Create one Received LOT of pieceCount at locationId (one box = one LOT).
       Thin wrapper over create(); Lot_Create's eligibility and cap gates apply.
       Returns the create() status dict."""
    data = {
        "itemId":            _u(itemId),
        "lotOriginTypeId":   getOriginTypeIdByCode("Received"),
        "currentLocationId": _u(locationId),
        "pieceCount":        _u(pieceCount),
    }
    return create(data, appUserId, terminalLocationId)
```

Then add `checkInAndNotify` directly below `checkInBox`. The view already knows the operator and the
terminal (`self.session.custom.appUserId`, `self.session.custom.terminal.terminalLocationId`; see
`InventoryManager.receiveLoose`), so both callers pass them in:

```python
def checkInAndNotify(itemId, locationId, pieceCount, description, appUserId=None, terminalLocationId=None):
    """Perspective-session helper shared by LineInventoryRow and AddLotQty:
       check in one box, toast the outcome, raise the CRT notice, and tell the
       page to refresh. Callers pass session.custom.appUserId and the terminal id.
       Returns the create() status dict."""
    res = checkInBox(itemId, locationId, pieceCount, appUserId, terminalLocationId)
    BlueRidge.Common.Ui.notifyResult(
        res, "Box checked in",
        "LOT %s - %s - %s pcs" % ((res or {}).get("MintedLotName") or "",
                                  description or "", _thousands(pieceCount)))
    if res and res.get("Status"):
        BlueRidge.Common.Ui.crtNotice(crtNamesFor([res.get("NewId")]))
        system.perspective.sendMessage("inventoryChanged",
                                       payload={"lotId": res.get("NewId")}, scope="page")
    return res
```

`create()` falls back to `_currentAppUserId()` when `appUserId` is None.

- [ ] **Step 5: Scan, then verify in the Script Console**

Run: `.\scan.ps1`
Expected: the scan reports success, with no named-query errors in the gateway log.

In the Designer Script Console (Core project, or MPP, which inherits it), with a known M&A line cell id:

```python
loc = system.db.runScalarQuery("SELECT TOP 1 Id FROM Location.Location WHERE Code = 'MA1-COMPBR'", "MPP")
print BlueRidge.Lots.Lot.getLineInventoryHeader(loc)
for r in BlueRidge.Lots.Lot.getLineInventoryInstances(loc): print r
```

Expected: a header string and a list of dicts with the nine keys, with no finished goods. Before running,
apply the SQL to Dev with
`.\sql\scripts\Update-Prod.ps1 -ServerInstance localhost -DatabaseName MPP_MES_Dev -Preview`. The preview
should list `0091` (and any other unapplied migration; if it lists `0090` unbuilt, stop and ask). Then run
the same command without `-Preview`.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/lots/Lot_GetLineInventorySummary ignition/projects/Core/ignition/named-query/parts/Item_Update ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Item/code.py
git commit -m "feat(ignition): line inventory summary NQ + Lot/Item script glue"
```

---

### Task 6: Stylesheet + the three new views

**Files:**
- Modify: `ignition/projects/Core/com.inductiveautomation.perspective/stylesheet/stylesheet.css`
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/LineInventoryRow/{view.json,resource.json}`
- Create: `.../Components/PlantFloor/LineInventory/{view.json,resource.json}`
- Create: `.../Components/PlantFloor/AddLotQty/{view.json,resource.json}`

**Interfaces:**
- Consumes: Task 5's `getLineInventoryInstances`, `getLineInventoryHeader`, `checkInAndNotify`.
- Produces:
  - View `BlueRidge/Components/PlantFloor/LineInventory` with params `locationId` (BIGINT) and
    `finishedGoodItemId` (BIGINT or null). It refreshes on page message `inventoryChanged` and every 30 s.
  - View `BlueRidge/Components/PlantFloor/AddLotQty` with params `itemId`, `description`, `locationId`.
    It opens as popup id `mpp-add-lot`.

- [ ] **Step 1: Stylesheet**

Append to the Core `stylesheet.css`:

```css
/* ---- M&A Line Inventory sidebar (2026-09-17) ----
   Compact rows so 10+ parts fit with no scrolling. Low = whole row tinted
   orange with a bright orange border (no badge). */
:root {
    --pf-inv-low-bg: rgba(255, 145, 48, 0.16);
    --pf-inv-low-border: #FF9130;
}
.psc-pf-inv-panel {
    background: var(--mpp-surface-raised);
    border: 1px solid var(--mpp-border-subtle);
    border-radius: var(--mpp-radius-md);
    overflow: hidden;
}
.psc-pf-inv-head {
    padding: 12px 14px 8px;
    border-bottom: 1px solid var(--mpp-border-subtle);
}
.psc-pf-inv-title {
    font-size: var(--mpp-fs-md);
    font-weight: var(--mpp-fw-semibold);
    color: var(--mpp-text-primary);
}
.psc-pf-inv-sub {
    font-size: 13px;
    color: var(--mpp-text-secondary);
    opacity: 0.75;
}
.psc-pf-inv-list {
    padding: 8px;
    gap: 4px;
    overflow: hidden !important;
}
.psc-pf-inv-row {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 40px;
    padding: 0 6px 0 10px;
    background: var(--mpp-neutral-30);
    border: 1px solid var(--mpp-border-subtle);
    border-radius: var(--mpp-radius-md);
    box-sizing: border-box;
}
.psc-pf-inv-row-low {
    background: var(--pf-inv-low-bg);
    border: 2px solid var(--pf-inv-low-border);
    padding: 0 5px 0 9px;
}
.psc-pf-inv-desc {
    font-size: 14px;
    line-height: 1.15;
    color: var(--mpp-text-secondary);
    white-space: normal;
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
}
.psc-pf-inv-qty {
    font-family: var(--mpp-font-mono, Consolas, monospace);
    font-size: 17px;
    font-weight: 600;
    text-align: right;
    color: var(--mpp-text-primary);
}
.psc-pf-inv-row-low .psc-pf-inv-qty {
    color: #FFC08A;
}
.psc-pf-inv-btn {
    height: 28px !important;
    min-height: 28px !important;
    width: 72px;
    padding: 0 6px !important;
    font-size: 13px !important;
    font-family: var(--mpp-font-mono, Consolas, monospace);
}
.psc-pf-inv-foot {
    padding: 6px 8px;
    border-top: 1px solid var(--mpp-border-subtle);
    justify-content: flex-end;
}
```

Before appending, grep the stylesheet for `--mpp-fw-semibold` and `--mpp-font-mono`. If `--mpp-font-mono`
doesn't exist, the fallback in `var(...)` covers it. If `--mpp-neutral-30` is not defined in the Core
`:root`, use `var(--mpp-surface-card)`.

- [ ] **Step 2: `LineInventoryRow` view**

`LineInventoryRow/resource.json`:

```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": [
    "view.json"
  ],
  "attributes": {
    "lastModificationSignature": "",
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-09-17T12:00:00Z"
    }
  }
}
```

`LineInventoryRow/view.json`:

```json
{
  "custom": {
    "busyUntil": 0
  },
  "params": {
    "addLotMode": "None",
    "available": 0,
    "availableText": "0",
    "boxQuantity": null,
    "buttonText": "",
    "description": "",
    "isLow": false,
    "itemId": null,
    "locationId": null
  },
  "propConfig": {
    "params.addLotMode": {"paramDirection": "input"},
    "params.available": {"paramDirection": "input"},
    "params.availableText": {"paramDirection": "input"},
    "params.boxQuantity": {"paramDirection": "input"},
    "params.buttonText": {"paramDirection": "input"},
    "params.description": {"paramDirection": "input"},
    "params.isLow": {"paramDirection": "input"},
    "params.itemId": {"paramDirection": "input"},
    "params.locationId": {"paramDirection": "input"}
  },
  "props": {
    "defaultSize": {"height": 40, "width": 304}
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {"name": "root"},
    "props": {
      "alignItems": "center",
      "style": {"classes": "pf-inv-row"}
    },
    "propConfig": {
      "props.style.classes": {
        "binding": {
          "type": "expr",
          "config": {
            "expression": "if({view.params.isLow}, \"pf-inv-row pf-inv-row-low\", \"pf-inv-row\")"
          }
        }
      }
    },
    "children": [
      {
        "type": "ia.display.label",
        "meta": {"name": "Description"},
        "position": {"basis": "0", "grow": 1},
        "props": {"style": {"classes": "pf-inv-desc", "minWidth": "0"}},
        "propConfig": {
          "props.text": {"binding": {"type": "expr", "config": {"expression": "{view.params.description}"}}}
        }
      },
      {
        "type": "ia.display.label",
        "meta": {"name": "Available"},
        "position": {"basis": "54px", "shrink": 0},
        "props": {"style": {"classes": "pf-inv-qty"}},
        "propConfig": {
          "props.text": {"binding": {"type": "expr", "config": {"expression": "{view.params.availableText}"}}}
        }
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "Slot"},
        "position": {"basis": "72px", "shrink": 0},
        "props": {"justify": "flex-end", "alignItems": "center"},
        "children": [
          {
            "type": "ia.input.button",
            "meta": {"name": "AddButton"},
            "position": {"shrink": 0},
            "props": {"style": {"classes": "pf-btn pf-btn-primary pf-inv-btn"}},
            "propConfig": {
              "meta.visible": {
                "binding": {"type": "expr", "config": {"expression": "{view.params.addLotMode} != \"None\""}}
              },
              "props.text": {
                "binding": {"type": "expr", "config": {"expression": "{view.params.buttonText}"}}
              },
              "props.enabled": {
                "binding": {"type": "expr", "config": {"expression": "toMillis(now(500)) > {view.custom.busyUntil}"}}
              }
            },
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "script",
                  "scope": "G",
                  "config": {
                    "script": "\tnowMs = system.date.toMillis(system.date.now())\n\tif nowMs < (self.view.custom.busyUntil or 0):\n\t\treturn\n\tmode = self.view.params.addLotMode\n\tif mode == \"AskQty\":\n\t\tsystem.perspective.openPopup(\"mpp-add-lot\", \"BlueRidge/Components/PlantFloor/AddLotQty\", params={\"itemId\": self.view.params.itemId, \"description\": self.view.params.description, \"locationId\": self.view.params.locationId}, modal=True, showCloseIcon=True)\n\t\treturn\n\tif mode != \"OneTap\":\n\t\treturn\n\t# double-tap guard: the button stays disabled for 2 s\n\tself.view.custom.busyUntil = nowMs + 2000\n\ttermId = None\n\ttry:\n\t\ttermId = self.session.custom.terminal.terminalLocationId\n\texcept:\n\t\ttermId = None\n\tBlueRidge.Lots.Lot.checkInAndNotify(self.view.params.itemId, self.view.params.locationId, self.view.params.boxQuantity, self.view.params.description, self.session.custom.appUserId, termId)"
                  }
                }
              }
            }
          }
        ]
      }
    ]
  }
}
```

The Slot keeps its 72px even when the button is hidden, so quantities stay aligned (the meta.visible
exception for aligned rows).

- [ ] **Step 3: `LineInventory` view**

`LineInventory/resource.json`: same content as Step 2's resource.json.

`LineInventory/view.json`:

```json
{
  "custom": {
    "refreshToken": 0
  },
  "params": {
    "finishedGoodItemId": null,
    "locationId": null
  },
  "propConfig": {
    "params.finishedGoodItemId": {"paramDirection": "input"},
    "params.locationId": {"paramDirection": "input"}
  },
  "props": {
    "defaultSize": {"height": 700, "width": 320}
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {"name": "root"},
    "props": {
      "direction": "column",
      "style": {"classes": "pf-inv-panel", "height": "100%"}
    },
    "scripts": {
      "customMethods": [],
      "extensionFunctions": null,
      "messageHandlers": [
        {
          "messageType": "inventoryChanged",
          "pageScope": true,
          "sessionScope": false,
          "viewScope": false,
          "script": "\tself.view.custom.refreshToken = (self.view.custom.refreshToken or 0) + 1"
        }
      ]
    },
    "children": [
      {
        "type": "ia.container.flex",
        "meta": {"name": "Head"},
        "position": {"shrink": 0},
        "props": {"direction": "column", "style": {"classes": "pf-inv-head"}},
        "children": [
          {
            "type": "ia.display.label",
            "meta": {"name": "Title"},
            "props": {"text": "Line Inventory", "style": {"classes": "pf-inv-title"}}
          },
          {
            "type": "ia.display.label",
            "meta": {"name": "Sub"},
            "props": {"style": {"classes": "pf-inv-sub"}},
            "propConfig": {
              "props.text": {
                "binding": {
                  "type": "expr",
                  "config": {
                    "expression": "runScript(\"BlueRidge.Lots.Lot.getLineInventoryHeader\", 30000, {view.params.locationId}, {view.params.finishedGoodItemId}, {view.custom.refreshToken})"
                  }
                }
              }
            }
          }
        ]
      },
      {
        "type": "ia.display.flex-repeater",
        "meta": {"name": "Rows"},
        "position": {"basis": "0", "grow": 1},
        "props": {
          "direction": "column",
          "path": "BlueRidge/Components/PlantFloor/LineInventoryRow",
          "elementPosition": {"basis": "40px", "shrink": 0, "grow": 0},
          "useDefaultViewWidth": false,
          "useDefaultViewHeight": false,
          "style": {"classes": "pf-inv-list"}
        },
        "propConfig": {
          "props.instances": {
            "binding": {
              "type": "expr",
              "config": {
                "expression": "runScript(\"BlueRidge.Lots.Lot.getLineInventoryInstances\", 30000, {view.params.locationId}, {view.params.finishedGoodItemId}, {view.custom.refreshToken})"
              }
            }
          }
        }
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "Foot"},
        "position": {"shrink": 0},
        "props": {"style": {"classes": "pf-inv-foot"}},
        "children": [
          {
            "type": "ia.input.button",
            "meta": {"name": "DetailButton"},
            "position": {"shrink": 0},
            "props": {"text": "Inventory detail...", "style": {"classes": "pf-btn pf-btn-secondary pf-inv-btn", "width": "auto"}},
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "script",
                  "scope": "G",
                  "config": {
                    "script": "\tsystem.perspective.openPopup(\"mpp-inventory\", \"BlueRidge/Components/PlantFloor/InventoryManager\", params={\"locationId\": self.view.params.locationId}, modal=False, showCloseIcon=True, draggable=True, resizable=True)"
                  }
                }
              }
            }
          }
        ]
      }
    ]
  }
}
```

Both runScript bindings use a 30000 ms poll rate, so a check-in at another terminal on the line shows up
within 30 s.

- [ ] **Step 4: `AddLotQty` popup view**

`AddLotQty/resource.json`: same as Step 2's.

`AddLotQty/view.json`:

```json
{
  "custom": {
    "qty": ""
  },
  "params": {
    "description": "",
    "itemId": null,
    "locationId": null
  },
  "propConfig": {
    "params.description": {"paramDirection": "input"},
    "params.itemId": {"paramDirection": "input"},
    "params.locationId": {"paramDirection": "input"}
  },
  "props": {
    "defaultSize": {"height": 560, "width": 440}
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {"name": "root"},
    "props": {
      "direction": "column",
      "style": {"gap": "10px", "padding": "16px", "classes": "pf-inv-panel"}
    },
    "scripts": {
      "customMethods": [
        {
          "name": "submit",
          "params": [],
          "script": "\traw = (\"%s\" % (self.view.custom.qty or \"\")).strip()\n\tif not raw.isdigit() or int(raw) <= 0:\n\t\tBlueRidge.Common.Notify.toast(\"Quantity required\", \"Enter how many pieces are in the box.\", \"warning\")\n\t\treturn\n\ttermId = None\n\ttry:\n\t\ttermId = self.session.custom.terminal.terminalLocationId\n\texcept:\n\t\ttermId = None\n\tres = BlueRidge.Lots.Lot.checkInAndNotify(self.view.params.itemId, self.view.params.locationId, int(raw), self.view.params.description, self.session.custom.appUserId, termId)\n\tif res and res.get(\"Status\"):\n\t\tsystem.perspective.closePopup(\"mpp-add-lot\")"
        }
      ],
      "extensionFunctions": null,
      "messageHandlers": [
        {
          "messageType": "addLotKeyPressed",
          "pageScope": true,
          "sessionScope": false,
          "viewScope": false,
          "script": "\ta = payload.get(\"action\") if payload else None\n\tq = self.view.custom.qty or \"\"\n\tif a == \"key\":\n\t\tif len(q) < 6:\n\t\t\tself.view.custom.qty = q + (\"%s\" % payload.get(\"key\"))\n\telif a == \"backspace\":\n\t\tself.view.custom.qty = q[:-1]\n\telif a == \"clear\":\n\t\tself.view.custom.qty = \"\"\n\telif a == \"enter\":\n\t\tself.submit()"
        }
      ]
    },
    "children": [
      {
        "type": "ia.display.label",
        "meta": {"name": "Title"},
        "position": {"shrink": 0},
        "props": {"text": "Add LOT", "style": {"classes": "pf-inv-title"}}
      },
      {
        "type": "ia.display.label",
        "meta": {"name": "Part"},
        "position": {"shrink": 0},
        "props": {"style": {"classes": "pf-inv-sub"}},
        "propConfig": {
          "props.text": {"binding": {"type": "expr", "config": {"expression": "{view.params.description}"}}}
        }
      },
      {
        "type": "ia.display.label",
        "meta": {"name": "QtyDisplay"},
        "position": {"shrink": 0},
        "props": {"style": {"classes": "pf-inv-qty", "fontSize": "34px", "padding": "6px 12px"}},
        "propConfig": {
          "props.text": {"binding": {"type": "expr", "config": {"expression": "if(len({view.custom.qty}) = 0, \"0\", {view.custom.qty})"}}}
        }
      },
      {
        "type": "ia.display.view",
        "meta": {"name": "Numpad"},
        "position": {"basis": "360px", "shrink": 0},
        "props": {
          "path": "BlueRidge/Components/PlantFloor/Numpad",
          "params": {"messageName": "addLotKeyPressed"}
        }
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "Buttons"},
        "position": {"shrink": 0},
        "props": {"style": {"gap": "10px"}},
        "children": [
          {
            "type": "ia.input.button",
            "meta": {"name": "Cancel"},
            "position": {"basis": "0", "grow": 1},
            "props": {"text": "Cancel", "style": {"classes": "pf-btn pf-btn-secondary", "minHeight": "36px"}},
            "events": {"component": {"onActionPerformed": {"type": "script", "scope": "G",
              "config": {"script": "\tsystem.perspective.closePopup(\"mpp-add-lot\")"}}}}
          },
          {
            "type": "ia.input.button",
            "meta": {"name": "Add"},
            "position": {"basis": "0", "grow": 1},
            "props": {"style": {"classes": "pf-btn pf-btn-primary", "minHeight": "36px"}},
            "propConfig": {
              "props.text": {"binding": {"type": "expr", "config": {"expression": "\"Add \" + if(len({view.custom.qty}) = 0, \"0\", {view.custom.qty}) + \" pcs\""}}}
            },
            "events": {"component": {"onActionPerformed": {"type": "script", "scope": "G",
              "config": {"script": "\tself.view.rootContainer.submit()"}}}}
          }
        ]
      }
    ]
  }
}
```

Before relying on it, open `Components/PlantFloor/Numpad/view.json` and confirm the page message it sends
carries `{"action": "key"|"backspace"|"clear"|"enter", "key": <digit>}` (the `InitialsEntry` handler reads
exactly that). Also check the Numpad's natural height and adjust `basis` if needed.

- [ ] **Step 5: Validate JSON, scan, smoke-test the panel alone**

Run: `python -c "import json,sys; [json.load(open(p,encoding='utf-8')) for p in sys.argv[1:]]; print('ok')" ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/LineInventory/view.json ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/LineInventoryRow/view.json ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/AddLotQty/view.json`
Expected: `ok`.

Run: `.\scan.ps1`
Expected: success. Then open `LineInventory` in Designer, set `params.locationId` to a real M&A line id
(from Task 5 Step 5), and check:
- rows render;
- no Component Error;
- low rows are orange.

Check the gateway `wrapper.log` for view deserialization errors if the view is blank.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/Core/com.inductiveautomation.perspective/stylesheet/stylesheet.css ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/LineInventory ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/LineInventoryRow ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/AddLotQty
git commit -m "feat(ignition): LineInventory panel, compact row with one-tap box check-in, AddLotQty numpad popup"
```

Check `git status` for `thumbnail.png` files and make sure none are staged (they are gitignored).

---

### Task 7: Dock the panel on the five terminal screens (Designer)

**Files (Designer edits):**
- `.../Views/ShopFloor/MachiningIn/view.json`
- `.../Views/ShopFloor/MachiningOutSplit/view.json`
- `.../Views/ShopFloor/AssemblyIn/view.json`
- `.../Views/ShopFloor/AssemblySerialized/view.json`
- `.../Views/ShopFloor/AssemblyNonSerialized/view.json`

**Interfaces:**
- Consumes: the `LineInventory` view (Task 6).

The embed to add, identical everywhere except the `finishedGoodItemId` binding:
- **Component:** Embedded View, name `LineInventory`.
- **Position:** `basis: 320px`, `shrink: 0`.
- **`props.path`:** `BlueRidge/Components/PlantFloor/LineInventory`.
- **`props.params.locationId`:** Property binding to `session.custom.cell.locationId`.
- **`props.params.finishedGoodItemId`:**
  - `null` on MachiningIn, MachiningOutSplit, AssemblyIn and AssemblySerialized (the proc finds running
    FGs through open containers);
  - on AssemblyNonSerialized, an Expression binding:
    `if(isNull({view.custom.container.ItemId}), {view.custom.selectedFinishedGoodItemId}, {view.custom.container.ItemId})`.

For reference, the resulting JSON of the embed is:

```json
{
  "type": "ia.display.view",
  "meta": {"name": "LineInventory"},
  "position": {"basis": "320px", "shrink": 0},
  "props": {
    "path": "BlueRidge/Components/PlantFloor/LineInventory",
    "params": {"finishedGoodItemId": null}
  },
  "propConfig": {
    "props.params.locationId": {
      "binding": {"type": "property", "config": {"path": "session.custom.cell.locationId"}}
    }
  }
}
```

- [ ] **Step 1: MachiningIn**

Root is a column: `Header`, `QueuePanel`, `ActiveLotPanel`.
1. Add a Flex container `ContentRow` (direction row, `grow 1`, `basis 0`, style `gap: 16px`) under root,
   after `Header`.
2. Move `QueuePanel` and `ActiveLotPanel` into a new column Flex `MainCol` (direction column, `grow 1`,
   `basis 0`, the same gap root uses between them) inside `ContentRow`.
3. Add the `LineInventory` embed as `ContentRow`'s last child.

- [ ] **Step 2: AssemblyIn**

Same as MachiningIn, with `ScanPanel` and `QueuePanel` moved into `MainCol`.

- [ ] **Step 3: MachiningOutSplit**

It already has `ContentRow` (row). Add the `LineInventory` embed as its last child. Nothing moves.

- [ ] **Step 4: AssemblySerialized**

1. Under `Body`, delete `ComponentsPanel` (the one-line label and its `ComponentsValue` child).
2. In the view's `custom`, delete `queueByPartText` and its binding.
3. Wrap: add `ContentRow` (row, `grow 1`) under root after `PrintBanner`. Move `Body` into it (keep
   `grow 1`), then add the `LineInventory` embed after `Body`.

- [ ] **Step 5: AssemblyNonSerialized**

1. Delete `InventorySidebar`'s children (`SidebarLabel`, `SidebarList`, `ProjectionRepeater`) and put the
   `LineInventory` embed in their place. Alternatively, replace `InventorySidebar` itself with the embed,
   keeping its 320px basis.
2. Set the embed's `finishedGoodItemId` expression as given above.
3. In `custom`, delete `componentProjection` and `queueByPartVertical`, together with their bindings.
4. Search the view for any other reader of those two props (`Ctrl+F` in Designer's JSON view, or grep the
   saved file) and remove it.

- [ ] **Step 6: Save, check the diff, verify on the gateway**

Save all five views in Designer.

Run: `git diff --stat -- ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor`
Expected: only the five views changed.

Check the diffs contain no pickled runtime data (large embedded row arrays).

Verify in a browser session on each of the five routes (`/shop-floor/machining-in`, `/machining-out`,
`/assembly-in`, `/assembly-serialized`, `/assembly-nonserialized`), with a terminal whose cell is an M&A
line:
- the panel is on the right;
- 10+ rows show with no scrollbar;
- the existing content still fits;
- the numbers match `EXEC Lots.Lot_GetLineInventorySummary @LocationId = <cell>` in SSMS.

The in-app browser cannot commit input bindings, so verify check-ins through SQL:

```sql
SELECT TOP 3 LotName, PieceCount, LotOriginTypeId FROM Lots.Lot ORDER BY Id DESC
```

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/MachiningIn/view.json ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/MachiningOutSplit/view.json ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyIn/view.json ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblySerialized/view.json ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized/view.json
git commit -m "feat(ignition): dock Line Inventory on the five M&A screens; drop the one-line label and projection sidebar"
```

---

### Task 8: Inventory popup grouped by part (Designer)

**Files (Designer edit):**
- `.../Components/PlantFloor/InventoryManager/view.json`
- `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` (card mapping)

**Interfaces:**
- Consumes: Task 4's FG-excluded, description-ordered rows.
- Produces: `getLineInventoryCards` now emits a group-header card before each part's LOTs:
  `{"isHeader": True, "item": <description>, "pieceCount": <part total>, ...}`.

- [ ] **Step 1: Group in the card mapper**

In `getLineInventoryCards`, walk the rows. Whenever `ItemId` changes, emit a header instance before that
part's LOT cards, and show the description instead of the part number:

```python
def getLineInventoryCards(locationId, _refreshToken=None):
    """Flex-repeater instances for the line-inventory popup: one header card per
       part (description + part total), then that part's LOTs FIFO. Finished goods
       are already excluded by the proc. Display formatting only."""
    locationId = _u(locationId)
    if locationId is None:
        return []
    rows = getLineInventoryByPart(locationId) or []
    totals = {}
    for r in rows:
        totals[r.get("ItemId")] = totals.get(r.get("ItemId"), 0) + (r.get("InventoryAvailable") or 0)
    out = []
    pos = 0
    lastItem = object()
    for r in rows:
        r = r or {}
        desc = r.get("Description") or r.get("PartNumber") or ""
        if r.get("ItemId") != lastItem:
            lastItem = r.get("ItemId")
            out.append({
                "lotId": None, "lotName": "", "item": desc,
                "pieceCount": totals.get(lastItem, 0), "arrival": "",
                "position": 0, "lotStatusCode": "", "isSelected": False,
                "selectable": False, "isHeader": True,
            })
        pos += 1
        arr = r.get("ArrivedAt")
        arrival = ""
        if arr is not None:
            try:
                arrival = system.date.format(arr, "MM/dd HH:mm")
            except:
                arrival = ("%s" % arr)[:16]
        out.append({
            "lotId":         r.get("LotId"),
            "lotName":       r.get("LotName") or "",
            "item":          desc,
            "pieceCount":    r.get("InventoryAvailable") or 0,
            "arrival":       arrival,
            "position":      pos,
            "lotStatusCode": r.get("LotStatusCode") or "",
            "isSelected":    False,
            "selectable":    False,
            "isHeader":      False,
        })
    return out
```

`Trim/InventoryRow` is shared with the Trim screens, so do **not** change it. Keep it as the popup's row
view: it shows `item` + `pieceCount` + `lotName`, so a header instance reads as a card carrying the part
description and the part total with an empty LOT name. The extra `isHeader` key is ignored by that view. The
InventoryManager view itself needs no Designer change for this task. If the header cards look wrong in the
browser, report it to Jacques with a screenshot rather than building a new row view. The mockup's orange
low-group treatment is out of scope here, because this popup has no threshold data.

- [ ] **Step 2: Verify + commit**

Run: `.\scan.ps1`
Expected: success. Then open the Inventory popup from a terminal and check:
- no finished-good LOTs;
- LOTs grouped under their part description.

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py
git commit -m "feat(ignition): inventory popup groups LOTs under part description"
```

Also stage `InventoryManager/view.json` if Designer changed it.

---

### Task 9: Item Master -- Box Quantity and Low-Inventory Horizon (Designer)

**Files (Designer edit):**
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Identity/view.json`

**Interfaces:**
- Consumes: Task 2's `Item_Get` columns, and Task 5's `Item.update` forwarding.

- [ ] **Step 1: State shape**

In `custom.state.selected` **and** `custom.state.editDraft`, add `"BoxQuantity": ""` and
`"LowInventoryHorizon": ""` (full-shape rule).

- [ ] **Step 2: `load()`**

In `load()`, add to `loaded`:

```python
		"BoxQuantity":         _s(row.get("BoxQuantity")),
		"LowInventoryHorizon": _s(row.get("LowInventoryHorizon")),
```

Keep the single atomic `self.view.custom.state = {...}` write.

- [ ] **Step 3: `handleSave()`**

In `handleSave()`, after the `MaxParts` line, add:

```python
	# 0 clears in the proc; an emptied field must clear, not preserve.
	payload["BoxQuantity"]         = _toNum(draft.get("BoxQuantity")) or 0
	payload["LowInventoryHorizon"] = _toNum(draft.get("LowInventoryHorizon")) or 0
```

- [ ] **Step 4: Fields**

Copy `FieldRow4/FieldMaxParts` twice into the same row (or a new `FieldRow5`):
- `FieldBoxQuantity`:
  - label "Box Quantity";
  - input bidi-bound to `view.custom.state.editDraft.BoxQuantity`;
  - `props.enabled` = `{view.custom.state.editDraft.ItemTypeName} = "Pass-Through"`.
- `FieldLowInventoryHorizon`:
  - label "Low-Inventory Horizon (FGs)";
  - bound to `...editDraft.LowInventoryHorizon`;
  - enabled when `ItemTypeName = "Finished Good"`.

Check the exact `ItemTypeName` strings: they come from `Parts.ItemType.Name`, which is `Pass-Through` and
`Finished Good`. The proc enforces the rule regardless.

- [ ] **Step 5: Verify + commit**

Save the view. Check `git diff --stat` (only Identity changed, and no pickled data). Then in the Config Tool:
- set a PassThrough part's Box Quantity to 5000 and save;
- set a finished good's horizon to 50 and save;
- clear one;
- try a box quantity on a casting: expect the proc's "only on a PassThrough part" toast.

Confirm in SQL:

```sql
SELECT PartNumber, BoxQuantity, LowInventoryHorizon FROM Parts.Item WHERE BoxQuantity IS NOT NULL OR LowInventoryHorizon IS NOT NULL
```

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Identity/view.json
git commit -m "feat(config): Item Master Identity -- Box Quantity and Low-Inventory Horizon"
```

---

### Task 10: Retire the tray projection and the low-inventory toast

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py`
- Delete: `ignition/projects/Core/ignition/named-query/workorder/Assembly_GetComponentProjection/`
- Delete: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/ComponentProjectionRow/`
- Designer: `.../Views/ShopFloor/AppHeaderLarge/view.json` (remove the `lowInventoryWarning` handler)
- Delete: `sql/migrations/repeatable/R__Workorder_Assembly_GetComponentProjection.sql`
- Delete: `sql/tests/0028_PlantFloor_Assembly/094_Assembly_ComponentProjection.sql`
- Create: `sql/migrations/versioned/0092_retire_component_projection.sql` (re-check the number; it must be
  the next free one after Task 1's)

**Interfaces:**
- Consumes: Task 7 done. After it, nothing on screen reads the projection.

- [ ] **Step 1: Prove nothing else uses them**

Run: `git grep -n -E "getComponentProjection|Assembly_GetComponentProjection|ComponentProjectionRow|warnLowInventory|lowInventoryWarning" -- ignition sql`
Expected: hits only in the files listed above. If any other file hits, stop and report it.

- [ ] **Step 2: Python**

In `Workorder/Assembly/code.py`:
- delete the whole `def warnLowInventory(...)` function;
- delete the whole `def getComponentProjection(...)` function;
- delete the two call sites: in the operator ByCount path, the block

```python
    if result and result.get("Status"):
        warnLowInventory(cellLocationId, fgItem, closureMethod)
```

  and, in `plcCompleteTray`, the single line
  `        warnLowInventory(ctx.get("cellLocationId"), ctx.get("finishedGoodItemId"), closureMethod)`
  (keep the `notifyInventoryChanged` line above it).

`Location.Terminal.listByLineOf` stays.

- [ ] **Step 3: Header handler (Designer)**

In `AppHeaderLarge`, remove the `lowInventoryWarning` message handler (root, Scripting). Save, then check
the diff.

- [ ] **Step 4: SQL retirement**

Create `sql/migrations/versioned/0092_retire_component_projection.sql`:

```sql
-- ============================================================
-- Migration:   0092_retire_component_projection.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Description: Drops Workorder.Assembly_GetComponentProjection. The Assembly OUT
--              sidebar's tray projection (on hand vs. trays left in the current
--              container) is replaced by Lots.Lot_GetLineInventorySummary's
--              per-FG LowInventoryHorizon rule (Jacques, 2026-09-17), and the
--              low-inventory toast that read it is retired. Its repeatable file
--              is deleted in the same commit so Update-Prod does not recreate it.
-- ============================================================
IF OBJECT_ID(N'Workorder.Assembly_GetComponentProjection', N'P') IS NOT NULL
    DROP PROCEDURE Workorder.Assembly_GetComponentProjection;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0092_retire_component_projection')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0092_retire_component_projection',
            N'Drop Workorder.Assembly_GetComponentProjection (tray projection), replaced by the Line Inventory sidebar horizon rule.');
GO
PRINT 'Migration 0092 (retire_component_projection) applied.';
GO
```

Then delete the repeatable file and the `094` test:

```bash
git rm sql/migrations/repeatable/R__Workorder_Assembly_GetComponentProjection.sql sql/tests/0028_PlantFloor_Assembly/094_Assembly_ComponentProjection.sql
git rm -r ignition/projects/Core/ignition/named-query/workorder/Assembly_GetComponentProjection ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/ComponentProjectionRow
```

- [ ] **Step 5: Full test run + scan + smoke**

Run: `.\sql\tests\Run-Tests.ps1`
Expected: 0 failed. An exit 1 with 0 failures means a test's own sqlcmd errored; read `test_output.txt`.

Run: `.\scan.ps1`
Expected: success, and the gateway log has no "Named query not found" or "view not found".

On Assembly OUT (non-serialized), close a tray. The toast no longer appears, the sidebar updates, and the
low rows are orange on a second terminal on the same line within 30 s.

Apply to Dev with `.\sql\scripts\Update-Prod.ps1 -ServerInstance localhost -DatabaseName MPP_MES_Dev -Preview`,
then the same command without `-Preview`.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/versioned/0092_retire_component_projection.sql ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AppHeaderLarge/view.json
git commit -m "refactor: retire the tray projection and the low-inventory toast (replaced by Line Inventory)"
```

(The `git rm` paths from Step 4 are already staged.)

---

### Task 11: Status + spec close-out

**Files:**
- Modify: `PROJECT_STATUS.md` (append-only; add under the current next-session briefing)
- Modify: `docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md` (Status line)

- [ ] **Step 1: Update both**

In `PROJECT_STATUS.md`, add one entry. It states that the M&A Line Inventory sidebar is built in Dev
(migrations `0091`/`0092`), that it is not yet deployed to prod, and that MPP must set:
- a **Box Quantity** on each PassThrough part;
- a **Low-Inventory Horizon** (50) on each finished good.

Until those are set, no row turns orange and every bought part shows `+ LOT`. Link the spec and the plan.
In the spec, set `**Status:** Built <date> (Dev); not yet deployed`.

- [ ] **Step 2: Commit**

```bash
git add PROJECT_STATUS.md docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md
git commit -m "docs: line inventory sidebar built in Dev; config owed from MPP"
```

The prod release follows the five-part release contract in `prod-release-context-pack/`, as its own piece of
work: preview, rehearsal, execute, scoped exports, and the runbook.
