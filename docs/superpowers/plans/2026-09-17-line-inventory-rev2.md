# Line Inventory -- Revision 2 Delta Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the already-built Line Inventory panel from spec revision 1 (BOM rollup x finished-good
horizon) to revision 2:
- list the parts the line **consumes**;
- colour by **% of the line's MaxQuantity** (orange <= 30%, red <= 10%);
- default each terminal to the parts its operator acts on, with a line-wide toggle;
- let anyone signed in set Max from a Tolerances popup.

**Architecture:**
- One SQL read (`Lots.Lot_GetLineInventorySummary` v2.0) decides membership, scope, level, order and
  button mode.
- Two new ItemLocation procs back the Tolerances popup: a list, and a Max-only setter.
- Python stays display glue.
- The already-built views gain a red level, a header toggle, a Tolerances button and an overflow
  footer. Three small new views make up the popup.
- `Item.LowInventoryHorizon` is retired by a forward migration.

**Tech Stack:** SQL Server 2022 (repeatable + versioned migrations, `sql/tests` framework), Ignition 8.3
Perspective (file-based views, Jython 2.7 script modules, named queries in Core).

**Spec:** `docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md` (revision 2) ·
**Mockup:** `mockup/line_inventory_rev2_mock.html` · **Supersedes:** Tasks 7, 9, 10 of
`docs/superpowers/plans/2026-09-17-line-inventory-sidebar.md` (Tasks 1-6 and 8 of that plan are built and stay).

## Global Constraints

**SQL**
- **Migration numbers.** `0092` is **abandoned** and must never be written: `0093` is committed by
  another session and may reach prod first, which would make a later `0092` out of order.
  - This plan's migration is `0094_retire_low_inventory_horizon.sql`.
  - The projection retirement (Task R7) takes the next free number when it is written.
  - Re-check `ls sql/migrations/versioned | tail -3` before creating either.
- Stored procs:
  - no `OUTPUT` params;
  - a read proc returns ONE result set, and an empty set means nothing to show;
  - a mutation proc ends every path with `SELECT @Status AS Status, @Message AS Message`;
  - a validation failure also calls `Audit.Audit_LogFailure`;
  - CATCH uses `RAISERROR`, following `R__Parts_ItemLocation_SetConsumptionMetadata.sql`.
- `EXEC` arguments are literals or `@variables` only.
- Enum/type/status values are resolved **by code**, never by literal Id. The one documented exception
  is the WorkCenter tier `LocationTypeId = 4`, matching `Location.Terminal_ListByLineOf`.
- Business rules live in SQL:
  - which parts are listed;
  - terminal-role scope;
  - Max resolution;
  - the level thresholds (**Critical: `Available * 10 <= Max`; Low: `Available * 10 <= Max * 3`**,
    integer maths, with `Max` NULL or `<= 0` meaning no level);
  - sort order;
  - button mode.
- Terminal-role scope map, in SQL:

  | Role | Scope |
  |---|---|
  | `MachiningIn`, `MachiningOut` | `Component` |
  | `AssemblyIn`, `AssemblyOut` | `PassThrough` |
  | NULL, unknown, or `@LineWide = 1` | no type filter |

- "Available" = `SUM(Lot.InventoryAvailable)` over LOTs at the line or any descendant, with
  `InventoryAvailable > 0` and a status that has `BlocksProduction = 0` and a code that is not `Closed`
  or `Open`.
- Max = the `MaxQuantity` of the **nearest** active `IsConsumptionPoint = 1` `Parts.ItemLocation` row
  walking up from the line (`Depth ASC`), the same resolution as `Lots.Lot_Create` section 6b.
- ASCII only in SQL string literals. The audit arrow uses `NCHAR(8594)` and the separator uses
  `Audit.ufn_MidDot()`.
- Audit Description convention: `<SUBJECT> <middot> <CATEGORY> <middot> <ACTION>`, capped by
  `Audit.ufn_TruncateActivity`. `OldValue`/`NewValue` carry resolved-name FK sub-objects.

**Ignition views**
- Style classes omit `psc-` (`"pf-inv-row"` maps to `.psc-pf-inv-row`).
- Every bound `view.custom.*` is pre-declared with a shaped default.
- Event-script lines start with `\t`.
- `system.perspective.*` from a component event needs `"scope": "G"`.
- Page-message handlers use `pageScope: true`.
- Expressions are C-style (`=`, `!=`, `&&`, `||`, `if()`), with no `\u`/`\n`/`\t` inside expression
  string literals.
- Python is Jython 2.7: no f-strings. A never-raising guard catches `(Exception, java.lang.Exception)`.
- Named queries live only in Core. Status-row procs are `type: "Query"`. `sqlType`: 2 for INT, 3 for
  BIGINT, 6 for BIT, 7 for NVARCHAR.
- **Every view this plan touches was created in this project today, so editing its file is correct.**
  The Designer-only rule applies to the five terminal screens, `InventoryManager`, `AppHeaderLarge`
  and Item Master (Task R6, for Jacques).
- After any Ignition resource change, run `.\scan.ps1` from the repo root and check the gateway
  `wrapper.log`.

**UI copy**
- Scope sentences: `Castings at this line`, `Bought parts at this line`, `All parts this line uses`,
  and `Nothing at this line` when there are no rows.
- Footer: `+N more below <middot> all above 30%` or `+N more below <middot> K low`, where K counts
  hidden rows at `Low` or `Critical`, and `""` when nothing is hidden. The visible capacity is 12
  rows.
- Tolerances warning line: `Max is also the most this line can hold -- a check-in that would go over
  it is refused.`
- Low tokens (existing): `--pf-inv-low-bg: rgba(255,145,48,0.16)`, `--pf-inv-low-border: #FF9130`.
  Critical tokens (new): `--pf-inv-crit-bg: rgba(239,68,68,0.18)`, `--pf-inv-crit-border: #F05252`.

**Tests / DB / git**
- Tests run only on throwaway DBs via `.\sql\tests\Run-Tests.ps1 -DatabaseName <DB> -Filter <text>`.
  Each concurrent task gets its own DB (named in its dispatch). **Never** reset or write
  `MPP_MES_Dev`; the controller applies changes there with `sqlcmd -S localhost -d MPP_MES_Dev -E -C`
  (the `-C` is required).
- Git: `jacques/working`; stage explicit paths only; no `Co-Authored-By` trailer.

---

## File Structure

| Path | Task | Status |
|---|---|---|
| `sql/migrations/versioned/0094_retire_low_inventory_horizon.sql` | R1 | Create |
| `sql/migrations/repeatable/R__Parts_Item_Update.sql` | R1 | Modify (remove horizon) |
| `sql/migrations/repeatable/R__Parts_Item_Get.sql` | R1 | Modify (drop last column) |
| `ignition/projects/Core/ignition/named-query/parts/Item_Update/{query.sql,resource.json}` | R1 | Modify |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Item/code.py` | R1 | Modify |
| `MPP_MES_DATA_MODEL.md`, `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql` | R1 | Modify / regenerate |
| `sql/tests/0008_Parts_Item/{030_Item_BoxQuantity_Horizon.sql,010_Item_crud.sql}`, `sql/tests/0064_Crt_PartScoped/080_config_roundtrip.sql` | R1 | Modify |
| `sql/migrations/repeatable/R__Lots_Lot_GetLineInventorySummary.sql` | R2 | Rewrite (v2.0) |
| `sql/tests/0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql` | R2 | Rewrite |
| `sql/migrations/repeatable/R__Parts_ItemLocation_SetMaxQuantity.sql` | R3 | Create |
| `sql/migrations/repeatable/R__Parts_ItemLocation_ListConsumptionForLine.sql` | R3 | Create |
| `sql/tests/0008_Parts_Item/040_ItemLocation_SetMaxQuantity.sql`, `041_ItemLocation_ListConsumptionForLine.sql` | R3 | Create |
| `ignition/projects/Core/com.inductiveautomation.perspective/stylesheet/stylesheet.css` | R4 | Modify |
| `.../views/BlueRidge/Components/PlantFloor/LineInventory/view.json` | R4 | Rewrite |
| `.../Components/PlantFloor/LineInventoryRow/view.json` | R4 | Modify |
| `.../Components/PlantFloor/LineTolerances/{view.json,resource.json}` | R4 | Create |
| `.../Components/PlantFloor/LineToleranceRow/{view.json,resource.json}` | R4 | Create |
| `.../Components/PlantFloor/LineToleranceEdit/{view.json,resource.json}` | R4 | Create |
| `ignition/projects/Core/ignition/named-query/lots/Lot_GetLineInventorySummary/{query.sql,resource.json}` | R5 | Modify |
| `ignition/projects/Core/ignition/named-query/parts/ItemLocation_ListConsumptionForLine/`, `ItemLocation_SetMaxQuantity/` | R5 | Create |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` | R5 | Modify |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/ItemLocation/code.py` | R5 | Modify |

---

### Task R1: Retire `Item.LowInventoryHorizon`

**Files:** as listed for R1 above.

**Interfaces:**
- Produces:
  - `Parts.Item` no longer has `LowInventoryHorizon` or `CK_Item_LowInventoryHorizon_Positive`.
  - `Parts.Item_Update` loses `@LowInventoryHorizon`; `@BoxQuantity` behaviour is unchanged (v2.6
    semantics kept).
  - `Parts.Item_Get`'s last column becomes `BoxQuantity`.
  - `BlueRidge.Parts.Item.update(meta)` no longer forwards `lowInventoryHorizon`.

- [ ] **Step 1: Make the tests describe the target first.** In `sql/tests/0008_Parts_Item/030_Item_BoxQuantity_Horizon.sql`:
  - change the Phase 1 horizon-existence assertion to assert the column is **gone**:
    `[Schema] Item.LowInventoryHorizon retired (0094)`, expected `0` from
    `CASE WHEN COL_LENGTH('Parts.Item','LowInventoryHorizon') IS NULL THEN N'0' ELSE N'1' END`;
  - delete the negative-horizon CHECK phase, every `@LowInventoryHorizon` argument, and every assertion
    about the horizon (set, reject-on-PassThrough, retype phase horizon parts);
  - keep every BoxQuantity assertion unchanged;
  - in Phase 6 (`#G` capture), drop the `LowInventoryHorizon INT` column and change the Get assertion to
    read `BoxQuantity` of the PassThrough fixture (set it first if the phase no longer does).

  In `010_Item_crud.sql` and `0064_Crt_PartScoped/080_config_roundtrip.sql`, narrow the fixed-shape
  `Item_Get` capture tables by the trailing `LowInventoryHorizon INT` column.

  Keep the file name (renaming a test file is churn). Update its header Description to say the
  horizon was retired by 0094.

- [ ] **Step 2: Run to confirm the failure.**
  `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "0008_Parts_Item"`. Expected: the
  retired-column assertion fails, and the `#G` capture errors on column count.

- [ ] **Step 3: Migration.** Create `sql/migrations/versioned/0094_retire_low_inventory_horizon.sql`:

```sql
-- ============================================================
-- Migration:   0094_retire_low_inventory_horizon.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Description: Drops Parts.Item.LowInventoryHorizon (added by 0091, never shipped
--              to prod). Line Inventory spec revision 2 (Jacques, 2026-09-17)
--              colours a part by % of the line's consumption-point MaxQuantity
--              (Parts.ItemLocation) instead of a finished-good horizon x BOM
--              rollup, which broke at real scale (the RPY / 5BA sets roll up to
--              40-42 parts and machined WIP sat low all day).
--
--              0091 is already recorded in MPP_MES_Dev's SchemaVersion, so the
--              column is removed going forward rather than by editing 0091.
--              0092 is deliberately skipped: 0093 exists and may reach prod first.
--              BoxQuantity (also 0091) is kept.
-- ============================================================

IF OBJECT_ID(N'Parts.CK_Item_LowInventoryHorizon_Positive', N'C') IS NOT NULL
    ALTER TABLE Parts.Item DROP CONSTRAINT CK_Item_LowInventoryHorizon_Positive;
GO

IF COL_LENGTH('Parts.Item', 'LowInventoryHorizon') IS NOT NULL
    ALTER TABLE Parts.Item DROP COLUMN LowInventoryHorizon;
GO

DECLARE @Gone NVARCHAR(20) = CASE WHEN COL_LENGTH('Parts.Item', 'LowInventoryHorizon') IS NULL
                                  THEN N'dropped' ELSE N'STILL PRESENT' END;
PRINT 'Parts.Item.LowInventoryHorizon: ' + @Gone;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0094_retire_low_inventory_horizon')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0094_retire_low_inventory_horizon',
            N'Drop Parts.Item.LowInventoryHorizon (0091, never in prod). Line Inventory rev 2 colours by the line''s ItemLocation.MaxQuantity instead.');
GO
PRINT 'Migration 0094 (retire_low_inventory_horizon) applied.';
GO
```

  Before relying on it, check whether an extended property on the column blocks `DROP COLUMN`. It
  does not in SQL Server (extended properties are dropped with the column), but confirm by running
  the file against the test DB.

- [ ] **Step 4: Procs.**
  - **`R__Parts_Item_Update.sql` → v2.7.** Remove, in order:
    - the `@LowInventoryHorizon` parameter;
    - its entry in `@Params`;
    - its part of the combined negative-value check (the message becomes
      `N'Box quantity cannot be negative.'`);
    - the FinishedGood-only type check;
    - `@OldLowInventoryHorizon` (declare and read);
    - its NULL/0 resolution;
    - its `@OldValue` JSON entry;
    - its `@Diff` CASE;
    - its `SET` assignment;
    - its NewValue entry.

    Add a dated change-log line. `@BoxQuantity` logic must be byte-for-byte unchanged apart from
    losing the combined check's horizon half.
  - **`R__Parts_Item_Get.sql` → v2.5.** Remove `i.LowInventoryHorizon`; `i.BoxQuantity` becomes the
    last column (fix the comma). Add a change-log line.

- [ ] **Step 5: Named query + Python.**
  - `parts/Item_Update/query.sql`: delete the `@LowInventoryHorizon = :lowInventoryHorizon` line and
    the trailing comma it leaves.
  - `resource.json`: remove the `lowInventoryHorizon` parameter entry; keep a trailing newline.
  - `BlueRidge/Parts/Item/code.py`:
    - remove `lowInventoryHorizon` from `update()`'s params dict, its blank-to-0 mapping, and its
      docstring mention;
    - remove `"LowInventoryHorizon"` from `_ITEM_SHAPE_KEYS`;
    - leave `boxQuantity` handling exactly as it is.

- [ ] **Step 6: Data model + extended properties.**
  - `MPP_MES_DATA_MODEL.md`: delete the `LowInventoryHorizon` row from the `### Item` table, and add a
    revision row at the top of the history table (continue the live numbering), e.g.
    `| 2.8 | 2026-09-17 | Blue Ridge Automation | Parts.Item.LowInventoryHorizon retired (migration 0094); Line Inventory colours by ItemLocation.MaxQuantity. |`
  - Run `node sql/scripts/gen_extended_properties.js`.
  - Byte-scan the regenerated file for non-ASCII:
    `python -c "d=open('sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql','rb').read(); print([i for i,b in enumerate(d) if b>127][:5])"`.
    Expected: `[]`.

- [ ] **Step 7: Run tests.** `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "0008_Parts_Item"`,
  then `-Filter "0064_Crt_PartScoped"`. Both must pass. `python -c "import ast,io; ast.parse(io.open(r'ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Item/code.py', encoding='utf-8').read())"`.
  Then run `.\scan.ps1`.

- [ ] **Step 8: Commit.**
```bash
git add sql/migrations/versioned/0094_retire_low_inventory_horizon.sql sql/migrations/repeatable/R__Parts_Item_Update.sql sql/migrations/repeatable/R__Parts_Item_Get.sql ignition/projects/Core/ignition/named-query/parts/Item_Update ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Item/code.py MPP_MES_DATA_MODEL.md sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql sql/tests/0008_Parts_Item/030_Item_BoxQuantity_Horizon.sql sql/tests/0008_Parts_Item/010_Item_crud.sql sql/tests/0064_Crt_PartScoped/080_config_roundtrip.sql
git commit -m "refactor: retire Item.LowInventoryHorizon (0094) -- line inventory colours by ItemLocation max"
```

---

### Task R2: `Lots.Lot_GetLineInventorySummary` v2.0

**Files:** `sql/migrations/repeatable/R__Lots_Lot_GetLineInventorySummary.sql` (rewrite), `sql/tests/0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql` (rewrite).

**Interfaces:**
- Produces: `EXEC Lots.Lot_GetLineInventorySummary @LocationId BIGINT, @TerminalRole NVARCHAR(30) = NULL, @LineWide BIT = 0`, which returns these columns **in this order**:

  | Column | Type / values |
  |---|---|
  | `ItemId` | BIGINT |
  | `Description` | NVARCHAR(500) |
  | `Available` | INT |
  | `MaxQuantity` | INT NULL |
  | `Level` | NVARCHAR(10): `Critical` / `Low` / `Ok` / `None` |
  | `BoxQuantity` | INT NULL |
  | `AddLotMode` | NVARCHAR(10): `OneTap` / `AskQty` / `None` |
  | `ItemLocationId` | BIGINT NULL |
  | `ScopeCode` | NVARCHAR(20): `Castings` / `Purchased` / `All` |

  Sort order: parts with a positive Max first, by `Available / Max` ascending; then those without, by
  Description, then ItemId. Empty set for a NULL location or one with no WorkCenter ancestor.

- [ ] **Step 1: Rewrite the test.** Replace `099_Lot_GetLineInventorySummary.sql` entirely with:

```sql
-- =============================================
-- File:         0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17 (rewritten for v2.0, spec revision 2)
-- Description:  Lots.Lot_GetLineInventorySummary v2.0. Line MA1-COMPBR, called
--   with its terminal MA1-COMPBR-AOUT. Consumption rows (Parts.ItemLocation,
--   IsConsumptionPoint = 1) decide membership; % of the nearest row's MaxQuantity
--   decides the level (Critical: Avail*10 <= Max; Low: Avail*10 <= 3*Max).
--   Fixture (all at the line unless noted):
--     CAST1..CAST5  Component   consumption, Max 100, available 5/30/31/10/11
--     PIN           PassThrough consumption, Box 5000; Max 10000 on the AREA (MA1)
--                   and 2000 on the LINE -> nearest (2000) wins; available 60,
--                   plus a HELD LOT of 1000 (excluded) and a CLOSED LOT (excluded)
--     GASKET        PassThrough consumption, no Box, no Max; nothing on hand
--     SA            SubAssembly NOT consumption; 7 on hand
--     FG            FinishedGood on hand (never listed)
--   Every assertion filters to the fixture's own descriptions ('T099 %'), because
--   the line is shared with other suites.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql';
GO

-- ---- cleanup (LOTs -> ItemLocation -> Item) ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'T099-%';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber LIKE N'T099-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T099-%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @TCo BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @TPt BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');
DECLARE @TSa BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'SubAssembly');
DECLARE @TFg BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId, BoxQuantity) VALUES
    (@TCo, N'T099-CAST1',  N'T099 cast 1',       1, @Now, 1, NULL),
    (@TCo, N'T099-CAST2',  N'T099 cast 2',       1, @Now, 1, NULL),
    (@TCo, N'T099-CAST3',  N'T099 cast 3',       1, @Now, 1, NULL),
    (@TCo, N'T099-CAST4',  N'T099 cast 4',       1, @Now, 1, NULL),
    (@TCo, N'T099-CAST5',  N'T099 cast 5',       1, @Now, 1, NULL),
    (@TPt, N'T099-PIN',    N'T099 dowel pin',    1, @Now, 1, 5000),
    (@TPt, N'T099-GASKET', N'T099 gasket',       1, @Now, 1, NULL),
    (@TSa, N'T099-SA',     N'T099 sub assembly', 1, @Now, 1, NULL),
    (@TFg, N'T099-FG',     N'T099 finished',     1, @Now, 1, NULL);

DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');
DECLARE @Area BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1');

-- consumption rows (line tier), plus an AREA-tier row for PIN that must LOSE to the line row
INSERT INTO Parts.ItemLocation (ItemId, LocationId, MaxQuantity, IsConsumptionPoint, CreatedAt)
SELECT i.Id, @Line, v.MaxQ, 1, @Now
FROM (VALUES (N'T099-CAST1', 100), (N'T099-CAST2', 100), (N'T099-CAST3', 100), (N'T099-CAST4', 100),
             (N'T099-CAST5', 100), (N'T099-PIN', 2000), (N'T099-GASKET', NULL)) v(Pn, MaxQ)
INNER JOIN Parts.Item i ON i.PartNumber = v.Pn;
INSERT INTO Parts.ItemLocation (ItemId, LocationId, MaxQuantity, IsConsumptionPoint, CreatedAt)
SELECT Id, @Area, 10000, 1, @Now FROM Parts.Item WHERE PartNumber = N'T099-PIN';

DECLARE @Hold   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @Good   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
SELECT N'T099-' + v.Tag, i.Id, 2, v.St, v.Q, v.Q, @Line, 1, @Now
FROM (VALUES (N'T099-CAST1', N'C1', @Good, 5), (N'T099-CAST2', N'C2', @Good, 30), (N'T099-CAST3', N'C3', @Good, 31),
             (N'T099-CAST4', N'C4', @Good, 10), (N'T099-CAST5', N'C5', @Good, 11),
             (N'T099-PIN', N'P1', @Good, 60), (N'T099-PIN', N'PH', @Hold, 1000), (N'T099-PIN', N'PX', @Closed, 99),
             (N'T099-SA', N'S1', @Good, 7), (N'T099-FG', N'F1', @Good, 30)) v(Pn, Tag, St, Q)
INNER JOIN Parts.Item i ON i.PartNumber = v.Pn;
GO

-- =============================================
-- Phase 1: line-wide -- membership, FG excluded, held/closed excluded, nearest Max
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
CREATE TABLE #R (Seq INT IDENTITY(1,1), ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT,
                 Level NVARCHAR(10), BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO #R (ItemId, Description, Available, MaxQuantity, Level, BoxQuantity, AddLotMode, ItemLocationId, ScopeCode)
EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @LineWide = 1;
DELETE FROM #R WHERE Description NOT LIKE N'T099 %';

DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[LineWide] 8 parts (5 casts, pin, gasket, SA; FG excluded)', @Expected = N'8', @Actual = @N;
DECLARE @PinAv NVARCHAR(10) = (SELECT CAST(Available AS NVARCHAR(10)) FROM #R WHERE Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[LineWide] PIN available 60 (held + closed excluded)', @Expected = N'60', @Actual = @PinAv;
DECLARE @PinMax NVARCHAR(10) = (SELECT CAST(MaxQuantity AS NVARCHAR(10)) FROM #R WHERE Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[LineWide] PIN Max 2000 (nearest row beats the area row)', @Expected = N'2000', @Actual = @PinMax;
DECLARE @PinIl NVARCHAR(1) = (SELECT CASE WHEN r.ItemLocationId = il.Id THEN N'1' ELSE N'0' END
    FROM #R r INNER JOIN Parts.ItemLocation il ON il.ItemId = r.ItemId AND il.LocationId = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR')
    WHERE r.Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[LineWide] PIN ItemLocationId is the LINE row', @Expected = N'1', @Actual = @PinIl;
DECLARE @GaAv NVARCHAR(20) = (SELECT CAST(Available AS NVARCHAR(10)) + N'/' + Level FROM #R WHERE Description = N'T099 gasket');
EXEC test.Assert_IsEqual @TestName = N'[LineWide] GASKET listed at 0 with no Max -> None', @Expected = N'0/None', @Actual = @GaAv;
DECLARE @SaLv NVARCHAR(20) = (SELECT Level + N'/' + AddLotMode FROM #R WHERE Description = N'T099 sub assembly');
EXEC test.Assert_IsEqual @TestName = N'[LineWide] SA (on hand, not consumption) listed, None/None', @Expected = N'None/None', @Actual = @SaLv;
DECLARE @Scope NVARCHAR(20) = (SELECT TOP 1 ScopeCode FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[LineWide] scope All', @Expected = N'All', @Actual = @Scope;
GO

-- =============================================
-- Phase 2: levels at and either side of each boundary
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @R TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT, Level NVARCHAR(10),
                  BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @LineWide = 1;
DECLARE @Lv NVARCHAR(200) = (SELECT STRING_AGG(REPLACE(Description, N'T099 ', N'') + N'=' + Level, N',')
                                    WITHIN GROUP (ORDER BY Description)
                             FROM @R WHERE Description LIKE N'T099 cast %');
EXEC test.Assert_IsEqual @TestName = N'[Level] 5 Crit, 30 Low (at 30%), 31 Ok, 10 Crit (at 10%), 11 Low',
    @Expected = N'cast 1=Critical,cast 2=Low,cast 3=Ok,cast 4=Critical,cast 5=Low', @Actual = @Lv;
DECLARE @PinLv NVARCHAR(10) = (SELECT Level FROM @R WHERE Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[Level] PIN 60 of 2000 = 3% -> Critical', @Expected = N'Critical', @Actual = @PinLv;
GO

-- =============================================
-- Phase 3: order (most urgent share first, then no-Max by description) + button modes
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
CREATE TABLE #O (Seq INT IDENTITY(1,1), ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT,
                 Level NVARCHAR(10), BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO #O (ItemId, Description, Available, MaxQuantity, Level, BoxQuantity, AddLotMode, ItemLocationId, ScopeCode)
EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @LineWide = 1;
DECLARE @Order NVARCHAR(400) = (SELECT STRING_AGG(REPLACE(Description, N'T099 ', N''), N',') WITHIN GROUP (ORDER BY Seq)
                                FROM #O WHERE Description LIKE N'T099 %');
EXEC test.Assert_IsEqual @TestName = N'[Order] pin 3%, cast1 5%, cast4 10%, cast5 11%, cast2 30%, cast3 31%, then gasket, sub assembly',
    @Expected = N'dowel pin,cast 1,cast 4,cast 5,cast 2,cast 3,gasket,sub assembly', @Actual = @Order;
DECLARE @Modes NVARCHAR(200) = (SELECT STRING_AGG(REPLACE(Description, N'T099 ', N'') + N'=' + AddLotMode, N',') WITHIN GROUP (ORDER BY Description)
                                FROM #O WHERE Description IN (N'T099 dowel pin', N'T099 gasket', N'T099 cast 1', N'T099 sub assembly'));
DROP TABLE #O;
EXEC test.Assert_IsEqual @TestName = N'[Mode] pin OneTap, gasket AskQty, cast/SA None',
    @Expected = N'cast 1=None,dowel pin=OneTap,gasket=AskQty,sub assembly=None', @Actual = @Modes;
GO

-- =============================================
-- Phase 4: terminal-role scope
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @M TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT, Level NVARCHAR(10),
                  BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO @M EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @TerminalRole = N'MachiningIn';
DECLARE @MSet NVARCHAR(400) = (SELECT STRING_AGG(REPLACE(Description, N'T099 ', N''), N',') WITHIN GROUP (ORDER BY Description)
                               FROM @M WHERE Description LIKE N'T099 %');
EXEC test.Assert_IsEqual @TestName = N'[Scope] MachiningIn -> castings only', @Expected = N'cast 1,cast 2,cast 3,cast 4,cast 5', @Actual = @MSet;
DECLARE @MScope NVARCHAR(20) = (SELECT TOP 1 ScopeCode FROM @M);
EXEC test.Assert_IsEqual @TestName = N'[Scope] MachiningIn scope Castings', @Expected = N'Castings', @Actual = @MScope;

DECLARE @A TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT, Level NVARCHAR(10),
                  BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO @A EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @TerminalRole = N'AssemblyOut';
DECLARE @ASet NVARCHAR(400) = (SELECT STRING_AGG(REPLACE(Description, N'T099 ', N''), N',') WITHIN GROUP (ORDER BY Description)
                               FROM @A WHERE Description LIKE N'T099 %');
EXEC test.Assert_IsEqual @TestName = N'[Scope] AssemblyOut -> bought parts only', @Expected = N'dowel pin,gasket', @Actual = @ASet;
DECLARE @AScope NVARCHAR(20) = (SELECT TOP 1 ScopeCode FROM @A);
EXEC test.Assert_IsEqual @TestName = N'[Scope] AssemblyOut scope Purchased', @Expected = N'Purchased', @Actual = @AScope;

DECLARE @W TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT, Level NVARCHAR(10),
                  BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO @W EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @TerminalRole = N'AssemblyOut', @LineWide = 1;
DECLARE @WN NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @W WHERE Description LIKE N'T099 %');
EXEC test.Assert_IsEqual @TestName = N'[Scope] LineWide overrides the role', @Expected = N'8', @Actual = @WN;
GO

-- =============================================
-- Phase 5: empty sets
-- =============================================
DECLARE @E TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT, Level NVARCHAR(10),
                  BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO @E EXEC Lots.Lot_GetLineInventorySummary @LocationId = NULL;
DECLARE @Area BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1');
INSERT INTO @E EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Area;
DECLARE @EN NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @E);
EXEC test.Assert_IsEqual @TestName = N'[Empty] NULL / area-level location -> empty', @Expected = N'0', @Actual = @EN;
GO

-- ---- cleanup ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'T099-%';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber LIKE N'T099-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T099-%';
GO

EXEC test.EndTestFile;
GO
```

  Notes for the implementer:
  - If `#R` from Phase 1 survives into later batches, drop it at the end of Phase 1 (`DROP TABLE #R;`).
  - If a fixture insert trips a NOT NULL column the fixture does not set (e.g. on
    `Parts.ItemLocation`), add it with the value the existing ItemLocation tests use.
  - If `LotEventLog` or `LotMovement` rows are auto-created for the fixture LOTs, delete them before
    the LOTs in both cleanup blocks, following
    `sql/tests/0027_PlantFloor_Machining/100_Lot_GetLineInventoryByPart.sql`.

- [ ] **Step 2: Run to confirm failure.** `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_T2 -Filter "099_Lot_GetLineInventorySummary"`.
  Expected: the proc rejects `@TerminalRole` / `@LineWide` (too many arguments), or the capture
  column count mismatches.

- [ ] **Step 3: Rewrite the proc** as `R__Lots_Lot_GetLineInventorySummary.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_Lot_GetLineInventorySummary.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     2.0
-- Description: The M&A Line Inventory sidebar's single read (spec revision 2,
--              docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md).
--              One row per part.
--
--              LINE. @LocationId (the terminal's session cell) resolves up to its
--              WorkCenter ancestor (LocationTypeId 4, as Terminal_ListByLineOf).
--
--              MEMBERSHIP. Parts with an active IsConsumptionPoint = 1 ItemLocation
--              row at the line or any ancestor (listed even at 0 on hand), plus every
--              other part with available stock at the line. FinishedGood never.
--
--              AVAILABLE. SUM(InventoryAvailable) over LOTs at the line or any
--              descendant with InventoryAvailable > 0 whose status has
--              BlocksProduction = 0 and is not Closed or Open. A held LOT is not
--              available (Jacques, 2026-09-17).
--
--              MAX. The MaxQuantity of the NEAREST consumption row walking up from the
--              line (Depth ASC) -- the same resolution as Lots.Lot_Create 6b, whose cap
--              this value also is. ItemLocationId names that row so the Tolerances
--              popup edits the row the colour came from.
--
--              LEVEL. Integer maths, no rounding: Critical when Available*10 <= Max,
--              Low when Available*10 <= Max*3, else Ok; None when Max is NULL or <= 0.
--
--              SCOPE. @TerminalRole MachiningIn/MachiningOut -> Component ('Castings');
--              AssemblyIn/AssemblyOut -> PassThrough ('Purchased'); NULL, unknown or
--              @LineWide = 1 -> no filter ('All'). ScopeCode is repeated on every row so
--              the proc keeps ONE result set.
--
--              ORDER. Positive Max first by Available/Max ascending (most urgent on
--              top), then no-Max parts; ties and the no-Max group by Description,
--              then ItemId.
--
--              ADD-LOT MODE. PassThrough + BoxQuantity -> OneTap; PassThrough without
--              -> AskQty; otherwise None.
--
--              FDS-11-011: no OUTPUT params; empty set = nothing to show.
--
-- Change Log:
--   2026-09-17 - 1.0 - BOM rollup x finished-good horizon (spec revision 1).
--   2026-09-17 - 1.1 - Held (BlocksProduction) LOTs excluded from Available.
--   2026-09-17 - 2.0 - Spec revision 2: consumption eligibility + % of Max; terminal
--                      scope + line-wide; BOM / running-FG logic and the
--                      @FinishedGoodItemId parameter removed.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetLineInventorySummary
    @LocationId   BIGINT,
    @TerminalRole NVARCHAR(30) = NULL,
    @LineWide     BIT          = 0
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

    -- scope: role -> item type (NULL = no filter)
    DECLARE @ScopeTypeCode NVARCHAR(30) =
        CASE WHEN ISNULL(@LineWide, 0) = 1 THEN NULL
             WHEN @TerminalRole IN (N'MachiningIn', N'MachiningOut') THEN N'Component'
             WHEN @TerminalRole IN (N'AssemblyIn', N'AssemblyOut')   THEN N'PassThrough'
             ELSE NULL END;
    DECLARE @ScopeTypeId BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = @ScopeTypeCode);
    DECLARE @ScopeCode NVARCHAR(20) =
        CASE @ScopeTypeCode WHEN N'Component' THEN N'Castings'
                            WHEN N'PassThrough' THEN N'Purchased'
                            ELSE N'All' END;

    -- 1. the line and everything under it
    DECLARE @LineLocs TABLE (Id BIGINT NOT NULL PRIMARY KEY);
    WITH Descendants AS (
        SELECT @LineId AS Id
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    )
    INSERT INTO @LineLocs (Id) SELECT Id FROM Descendants;

    -- 2. the line and its ancestors, with depth (nearest = 0)
    DECLARE @Chain TABLE (Id BIGINT NOT NULL PRIMARY KEY, Depth INT NOT NULL);
    WITH Up AS (
        SELECT l.Id, l.ParentLocationId, 0 AS Depth FROM Location.Location l WHERE l.Id = @LineId
        UNION ALL
        SELECT p.Id, p.ParentLocationId, u.Depth + 1
        FROM Location.Location p INNER JOIN Up u ON u.ParentLocationId = p.Id
    )
    INSERT INTO @Chain (Id, Depth) SELECT Id, Depth FROM Up;

    -- 3. nearest consumption row per part
    DECLARE @Consume TABLE (ItemId BIGINT NOT NULL PRIMARY KEY, ItemLocationId BIGINT NOT NULL, MaxQuantity INT NULL);
    INSERT INTO @Consume (ItemId, ItemLocationId, MaxQuantity)
    SELECT x.ItemId, x.Id, x.MaxQuantity
    FROM (
        SELECT il.ItemId, il.Id, il.MaxQuantity,
               ROW_NUMBER() OVER (PARTITION BY il.ItemId ORDER BY c.Depth ASC, il.Id ASC) AS rn
        FROM Parts.ItemLocation il
        INNER JOIN @Chain c ON c.Id = il.LocationId
        WHERE il.IsConsumptionPoint = 1 AND il.DeprecatedAt IS NULL
    ) x
    WHERE x.rn = 1;

    -- 4. available at the line (held / blocking / closed / open excluded)
    DECLARE @OnHand TABLE (ItemId BIGINT NOT NULL PRIMARY KEY, Available INT NOT NULL);
    INSERT INTO @OnHand (ItemId, Available)
    SELECT l.ItemId, SUM(l.InventoryAvailable)
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    WHERE l.CurrentLocationId IN (SELECT Id FROM @LineLocs)
      AND l.InventoryAvailable > 0
      AND sc.BlocksProduction = 0
      AND sc.Code NOT IN (N'Closed', N'Open')
    GROUP BY l.ItemId;

    -- 5. rows
    SELECT
        i.Id                                   AS ItemId,
        ISNULL(i.Description, i.PartNumber)    AS Description,
        ISNULL(oh.Available, 0)                AS Available,
        cp.MaxQuantity                         AS MaxQuantity,
        CAST(CASE WHEN cp.MaxQuantity IS NULL OR cp.MaxQuantity <= 0 THEN N'None'
                  WHEN ISNULL(oh.Available, 0) * 10 <= cp.MaxQuantity     THEN N'Critical'
                  WHEN ISNULL(oh.Available, 0) * 10 <= cp.MaxQuantity * 3 THEN N'Low'
                  ELSE N'Ok' END AS NVARCHAR(10)) AS Level,
        i.BoxQuantity                          AS BoxQuantity,
        CAST(CASE WHEN i.ItemTypeId <> @PassThroughTypeId THEN N'None'
                  WHEN i.BoxQuantity IS NOT NULL THEN N'OneTap'
                  ELSE N'AskQty' END AS NVARCHAR(10)) AS AddLotMode,
        cp.ItemLocationId                      AS ItemLocationId,
        @ScopeCode                             AS ScopeCode
    FROM Parts.Item i
    LEFT JOIN @OnHand  oh ON oh.ItemId = i.Id
    LEFT JOIN @Consume cp ON cp.ItemId = i.Id
    WHERE (oh.ItemId IS NOT NULL OR cp.ItemId IS NOT NULL)
      AND i.ItemTypeId <> @FgTypeId
      AND (@ScopeTypeId IS NULL OR i.ItemTypeId = @ScopeTypeId)
    ORDER BY
        CASE WHEN cp.MaxQuantity > 0 THEN 0 ELSE 1 END,
        CASE WHEN cp.MaxQuantity > 0
             THEN CAST(ISNULL(oh.Available, 0) AS DECIMAL(18,6)) / cp.MaxQuantity END,
        ISNULL(i.Description, i.PartNumber),
        i.Id;
END;
GO
```

- [ ] **Step 4: Run the test.** Same command as step 2. Expected: all pass. Then run
  `-Filter "0028_PlantFloor_Assembly"` on the same DB, to confirm no neighbour broke.

- [ ] **Step 5: Commit.**
```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetLineInventorySummary.sql sql/tests/0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql
git commit -m "feat(sql): Lot_GetLineInventorySummary v2.0 -- consumption eligibility, % of Max, terminal scope"
```

---

### Task R3: ItemLocation procs for the Tolerances popup

**Files:** create `R__Parts_ItemLocation_SetMaxQuantity.sql`, `R__Parts_ItemLocation_ListConsumptionForLine.sql`, `sql/tests/0008_Parts_Item/040_ItemLocation_SetMaxQuantity.sql`, `sql/tests/0008_Parts_Item/041_ItemLocation_ListConsumptionForLine.sql`.

First check for number collisions: `ls sql/tests/0008_Parts_Item` (040/041 must be free). Also check
whether the existing ItemLocation tests live in a different suite folder (e.g. grep `sql/tests` for
`ItemLocation_Add`); if they do, put the two new files in that folder instead and say so in your
report.

**Interfaces:**
- Produces `EXEC Parts.ItemLocation_SetMaxQuantity @ItemLocationId BIGINT, @MaxQuantity INT = NULL, @AppUserId BIGINT`.
  - Returns `Status, Message`.
  - NULL clears Max.
  - It rejects:
    - missing Id or user;
    - an unknown or deprecated row;
    - a row that is not a consumption point;
    - a Max `<= 0`;
    - a Max below a configured `MinQuantity`.
  - An unchanged value returns Status 1 with Message `No change.` and writes no audit row.
  - It touches **only** `MaxQuantity`.
- Produces `EXEC Parts.ItemLocation_ListConsumptionForLine @LocationId BIGINT`.
  - Returns `ItemLocationId BIGINT, ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT NULL, MinQuantity INT NULL, RowLocationCode NVARCHAR(50)`.
  - One row per consumption part (nearest row wins, the same resolution as R2), ordered by
    Description, then ItemId.
  - Available uses the same definition as R2.
  - The set is empty for a NULL location or one with no WorkCenter ancestor.

- [ ] **Step 1: Write the failing tests.**

  `040_ItemLocation_SetMaxQuantity.sql`:
  1. **Fixture.** One PassThrough item `T040-PIN` (resolve the type by code). A consumption row at
     `MA1-COMPBR` with Min 20, Max 500, Default 40, `IsConsumptionPoint = 1`. A second item
     `T040-NC` with a **non**-consumption row at the same line.
  2. **Phases.** Capture every result with `INSERT ... EXEC` into `(Status BIT, Message NVARCHAR(500))`.
     - **(a)** Set 600 gives Status 1; Max is 600; Min is still 20 and Default is still 40; exactly one
       new `Audit.ConfigLog` row for that ItemLocation, whose Description contains `MaxQuantity`.
     - **(b)** Set 600 again gives Status 1 and Message `No change.`, with no new ConfigLog row.
     - **(c)** NULL gives Status 1, Max NULL, and Min/Default untouched.
     - **(d)** 0 is rejected.
     - **(e)** -5 is rejected.
     - **(f)** 10 is rejected (below Min 20), and the message mentions `Min`.
     - **(g)** The non-consumption row is rejected.
     - **(h)** A deprecated row is rejected. Set `DeprecatedAt` on a third fixture row first.
     - **(i)** A NULL `@ItemLocationId` is rejected.
  3. **Cleanup.** Clean up ConfigLog rows (by `LogEntityTypeId` for `ItemLocation` + `EntityId`),
     then ItemLocation, then Item, in both the leading and trailing cleanup blocks.

  `041_ItemLocation_ListConsumptionForLine.sql`:
  1. **Fixture.** Two PassThrough items.
     - `T041-A`: consumption rows at both `MA1` (area, Max 9000) and `MA1-COMPBR` (line, Max 300).
       One Good LOT of 50 at the line, and one Hold LOT of 500 at the line.
     - `T041-B`: consumption row at the area only (Max 70), nothing on hand.
     - `T041-C`: non-consumption row at the line.
  2. **Assertions** (called with the terminal `MA1-COMPBR-AOUT`, filtered to `T041 %` descriptions):
     - exactly A and B are returned;
     - A has Max 300, Available 50 (the held LOT is excluded), and `RowLocationCode = 'MA1-COMPBR'`;
     - B has Max 70, Available 0, and `RowLocationCode = 'MA1'`;
     - an `MA1` (area) call returns an empty set.
  3. **Cleanup.** Clean up LOTs, then ItemLocation, then Item, in both blocks.

- [ ] **Step 2: Run to confirm failure.** `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_T3 -Filter "ItemLocation_"`.
  Expected: "Could not find stored procedure".

- [ ] **Step 3: Implement `Parts.ItemLocation_SetMaxQuantity`.**
  - **Model:** copy the structure of `R__Parts_ItemLocation_SetConsumptionMetadata.sql`: the same
    `@ProcName`/`@Params` pattern, validation blocks each calling `Audit.Audit_LogFailure` with
    `@LogEntityTypeCode = N'ItemLocation'` and `@LogEventTypeCode = N'Updated'`, the same TRY/CATCH
    with `RAISERROR`, and the status-row exits.
  - **Validation order:**
    1. required params;
    2. the row exists and is active;
    3. `IsConsumptionPoint = 1`, with the message
       `N'This part is not a consumption point at this location.'`;
    4. `@MaxQuantity IS NOT NULL AND @MaxQuantity <= 0`, with the message
       `N'Max must be greater than zero, or blank to clear it.'`;
    5. `@MaxQuantity < MinQuantity` when both are set, with the message
       `N'Max cannot be below the Min configured for this part here (' + CAST(Min) + N').'`. Build the
       message into a variable first, per the EXEC-arguments rule.
  - **No-op:** if `ISNULL(old, -1) = ISNULL(@MaxQuantity, -1)`, SELECT Status 1 / `N'No change.'`
    and RETURN, with no transaction and no audit.
  - **Update:** inside `BEGIN TRANSACTION`, `UPDATE Parts.ItemLocation SET MaxQuantity = @MaxQuantity
    WHERE Id = @ItemLocationId`, then `EXEC Audit.Audit_LogConfigChange` with:
    - `@LogEntityTypeCode = N'ItemLocation'`, `@EntityId = @ItemLocationId`,
      `@LogEventTypeCode = N'Updated'`, `@LogSeverityCode = N'Info'`;
    - `@Description` = `Audit.ufn_TruncateActivity(<PartNumber> + ' ' + Audit.ufn_MidDot() + ' Eligibility ' + Audit.ufn_MidDot() + ' Updated MaxQuantity ' + <old or 'null'> + NCHAR(8594) + <new or 'null'> + ' @ ' + <LocationCode>)`,
      built into a local variable first;
    - `@OldValue` / `@NewValue`: JSON with `MaxQuantity`, plus resolved sub-objects
      `Item: {Id, PartNumber, Description}` and `Location: {Id, Code, Name}`.
  - **Finish:** COMMIT, then Status 1 / `N'Max updated.'`.
  - **Header:** document why this proc exists alongside `SetConsumptionMetadata` (that proc replaces
    Min/Default, this one edits only Max), and that MaxQuantity is also `Lots.Lot_Create`'s check-in
    cap.

- [ ] **Step 4: Implement `Parts.ItemLocation_ListConsumptionForLine`.**
  - Reuse R2's line resolution, `@LineLocs`, `@Chain`, nearest-row and `@OnHand` blocks **verbatim**.
    Copy them, and put a comment on each copy that names `Lots.Lot_GetLineInventorySummary` as the
    source of truth. A shared function is not worth it here: the blocks are table-variable fills
    inside a proc.
  - Then SELECT `cp.ItemLocationId, i.Id AS ItemId, ISNULL(i.Description, i.PartNumber) AS
    Description, ISNULL(oh.Available, 0) AS Available, il.MaxQuantity, il.MinQuantity, loc.Code AS
    RowLocationCode`, joining the nearest row back to `Parts.ItemLocation il` and
    `Location.Location loc`.
  - Exclude FinishedGood, ORDER BY Description, then ItemId.
  - Resolve the "nearest row" the same way as R2: the `ROW_NUMBER` over `c.Depth ASC, il.Id ASC`.

- [ ] **Step 5: Run the tests.** Same command as step 2; all must pass. Also run
  `-Filter "0008_Parts_Item"` on the same DB to confirm no neighbour broke.

- [ ] **Step 6: Commit.**
```bash
git add sql/migrations/repeatable/R__Parts_ItemLocation_SetMaxQuantity.sql sql/migrations/repeatable/R__Parts_ItemLocation_ListConsumptionForLine.sql sql/tests/0008_Parts_Item/040_ItemLocation_SetMaxQuantity.sql sql/tests/0008_Parts_Item/041_ItemLocation_ListConsumptionForLine.sql
git commit -m "feat(sql): ItemLocation_SetMaxQuantity + ListConsumptionForLine for the line Tolerances popup"
```

---

### Task R4: Views -- red level, header toggle + Tolerances, overflow footer, Tolerances popup

**Files:** as listed for R4. The Python these views call is written in R5. Author against the names
below; bindings stay dead until R5 lands, and that is expected.

**Interfaces (consumed from R5, exact):**
- `BlueRidge.Lots.Lot.getLineInventoryInstances(locationId, terminalRole, lineWide, _refreshToken)`
  returns a list. Its row keys are `itemId, description, available, availableText, level,
  addLotMode, boxQuantity, buttonText, locationId`.
- `BlueRidge.Lots.Lot.getLineInventoryHeader(locationId, terminalRole, lineWide, _refreshToken)`
  returns a str.
- `BlueRidge.Lots.Lot.getLineInventoryFooter(locationId, terminalRole, lineWide, _refreshToken)`
  returns a str (`""` when nothing is hidden).
- `BlueRidge.Parts.ItemLocation.getToleranceInstances(locationId, _refreshToken)` returns a list.
  Its row keys are `itemLocationId, description, availableText, maxText, maxQuantity`.
- `BlueRidge.Parts.ItemLocation.saveMaxAndNotify(itemLocationId, rawValue)` returns a status dict.
  It toasts, and on success sends page message `inventoryChanged`. A blank `rawValue` clears Max.

- [ ] **Step 1: Stylesheet.** Append to the Core `stylesheet.css`, after the existing Line Inventory
  block:

```css
/* ---- Line Inventory rev 2 (2026-09-17): critical level, header controls, footer, tolerances ---- */
:root {
    --pf-inv-crit-bg: rgba(239, 68, 68, 0.18);
    --pf-inv-crit-border: #F05252;
}
.psc-pf-inv-row-crit {
    background: var(--pf-inv-crit-bg);
    border: 2px solid var(--pf-inv-crit-border);
    padding: 0 5px 0 9px;
}
.psc-pf-inv-row-crit .psc-pf-inv-qty {
    color: #FCA5A5;
}
.psc-pf-inv-hrow {
    align-items: center;
    justify-content: space-between;
    gap: 6px;
}
.psc-pf-inv-hbtn {
    height: 28px !important;
    min-height: 28px !important;
    padding: 0 9px !important;
    font-size: 12px !important;
    background: transparent;
    border: 1px solid var(--mpp-border-default);
    color: var(--mpp-text-secondary);
}
.psc-pf-inv-hbtn-on {
    background: var(--mpp-accent-20);
    border-color: var(--mpp-accent-60);
    color: var(--mpp-accent-90);
}
.psc-pf-inv-foottxt {
    font-size: 13px;
    color: var(--mpp-text-secondary);
    opacity: 0.8;
}
.psc-pf-inv-foottxt-warn {
    color: #FFC08A;
    font-weight: 600;
    opacity: 1;
}
.psc-pf-inv-warn {
    font-size: 13px;
    color: #FFC08A;
    background: rgba(255, 145, 48, 0.10);
    border: 1px solid rgba(255, 145, 48, 0.35);
    border-radius: var(--mpp-radius-md);
    padding: 7px 10px;
}
```

  Change `.psc-pf-inv-foot` so the footer can hold text on the left and the button on the right.
  Replace its `justify-content: flex-end;` with `justify-content: space-between; align-items: center;
  gap: 8px;`. Grep first to confirm it is only used by `LineInventory`.

- [ ] **Step 2: `LineInventoryRow`.** In its `view.json`:
  - rename param `isLow` to `level` (default `"None"`), in both `params` and `propConfig`;
  - change the root `props.style.classes` expression to
    `if({view.params.level} = "Critical", "pf-inv-row pf-inv-row-crit", if({view.params.level} = "Low", "pf-inv-row pf-inv-row-low", "pf-inv-row"))`.

  Nothing else changes.

- [ ] **Step 3: `LineInventory`, rewritten.**
  - **Params:** `locationId` (null) and `terminalRole` (`""`), both `paramDirection: input`. Remove
    `finishedGoodItemId`.
  - **Custom:** `{"refreshToken": 0, "lineWide": false}`.
  - **Keep:** root classes, the `inventoryChanged` page handler (bump `refreshToken`), and the
    repeater's element sizing.
  - **Head** (column, class `pf-inv-head`):
    - `HeadRow`, a row flex with class `pf-inv-hrow`, containing:
      - `Title`: label `Line Inventory`, class `pf-inv-title`, `grow 1`;
      - `LineWideButton`: button, text `Line-wide`, class expression
        `if({view.custom.lineWide}, "pf-btn pf-inv-hbtn pf-inv-hbtn-on", "pf-btn pf-inv-hbtn")`;
        `onActionPerformed`: `\tself.view.custom.lineWide = not bool(self.view.custom.lineWide)`;
      - `TolerancesButton`: button, text `Tolerances`, class `pf-btn pf-inv-hbtn`;
        `onActionPerformed` (scope G): `\tsystem.perspective.openPopup("mpp-line-tolerances", "BlueRidge/Components/PlantFloor/LineTolerances", params={"locationId": self.view.params.locationId}, modal=True, showCloseIcon=True)`.
    - `Sub` label, class `pf-inv-sub`, bound to
      `runScript("BlueRidge.Lots.Lot.getLineInventoryHeader", 30000, {view.params.locationId}, {view.params.terminalRole}, {view.custom.lineWide}, {view.custom.refreshToken})`.
  - **Rows** repeater: instances expression
    `runScript("BlueRidge.Lots.Lot.getLineInventoryInstances", 30000, {view.params.locationId}, {view.params.terminalRole}, {view.custom.lineWide}, {view.custom.refreshToken})`.
  - **Foot** (class `pf-inv-foot`):
    - `FootText` label, `grow 1`, text bound to
      `runScript("BlueRidge.Lots.Lot.getLineInventoryFooter", 30000, {view.params.locationId}, {view.params.terminalRole}, {view.custom.lineWide}, {view.custom.refreshToken})`,
      classes bound to `if(indexOf(<same runScript>, "low") >= 0, "pf-inv-foottxt pf-inv-foottxt-warn", "pf-inv-foottxt")`.
      To avoid calling the proc twice, bind a `custom.footer` prop (default `""`) to the runScript,
      and point both the text and the classes at `{view.custom.footer}`. Add `footer` to `custom`.
    - The existing `DetailButton`, unchanged; change its text to `Detail...`.

- [ ] **Step 4: `LineToleranceRow` (new).**
  - **Params (input):** `itemLocationId` (null), `description` (`""`), `availableText` (`""`),
    `maxText` (`""`), `maxQuantity` (null).
  - **Root:** row flex, class `pf-inv-row`, `alignItems: center`.
  - **Children:**
    - `Description` label (class `pf-inv-desc`, `basis 0`, `grow 1`, `minWidth 0`);
    - `Available` label (class `pf-inv-qty`, `basis 64px`, `shrink 0`);
    - `Max` label (class `pf-inv-qty`, `basis 72px`, `shrink 0`, text `{view.params.maxText}`);
    - `EditButton` (class `pf-btn pf-btn-secondary pf-inv-btn`, text `Edit`, `basis 64px`,
      `shrink 0`), whose `onActionPerformed` (scope G) is:
      `\tsystem.perspective.openPopup("mpp-line-tolerance-edit", "BlueRidge/Components/PlantFloor/LineToleranceEdit", params={"itemLocationId": self.view.params.itemLocationId, "description": self.view.params.description, "currentMax": self.view.params.maxQuantity}, modal=True, showCloseIcon=True)`.
  - `defaultSize` `{height 40, width 520}`. Resource json scope G, the same as `LineInventoryRow`'s.

- [ ] **Step 5: `LineTolerances` (new popup).**
  - **Params:** `locationId` (input, null). **Custom:** `{"refreshToken": 0}`.
  - **Root:** column, `gap 10px`, `padding 16px`, class `pf-inv-panel`; `defaultSize`
    `{height 620, width 560}`.
  - **Page handler** `inventoryChanged` (pageScope): bump `refreshToken`.
  - **Children:**
    1. `Title` label `Tolerances`, class `pf-inv-title`, `shrink 0`.
    2. `Warn` label, class `pf-inv-warn`, `shrink 0`, text
       `Max is also the most this line can hold -- a check-in that would go over it is refused.`
    3. `Header` row (`shrink 0`): four labels `Part` / `Available` / `Max` / `""` with the same bases
       as `LineToleranceRow`, style `fontSize 12px`, `opacity 0.7`.
    4. `Rows` flex-repeater:
       - path `BlueRidge/Components/PlantFloor/LineToleranceRow`, direction column;
       - `elementPosition {basis 40px, shrink 0, grow 0}`, `useDefaultViewWidth: false`,
         `useDefaultViewHeight: false`;
       - style `{gap: 4px, overflowY: auto}` (a config popup may scroll);
       - `position {basis 0, grow 1}`;
       - instances
         `runScript("BlueRidge.Parts.ItemLocation.getToleranceInstances", 0, {view.params.locationId}, {view.custom.refreshToken})`.
    5. `Close` button (`pf-btn pf-btn-secondary`, `shrink 0`), with
       `\tsystem.perspective.closePopup("mpp-line-tolerances")`.

- [ ] **Step 6: `LineToleranceEdit` (new numpad popup).**
  - **Model:** copy `Components/PlantFloor/AddLotQty/view.json` exactly (numpad embed at its 424px
    basis, the `busyUntil` double-tap guard, and the key handler), then change it as follows.
  - **Params:** `itemLocationId`, `description`, `currentMax` (all input). **Custom:**
    `{"qty": "", "busyUntil": 0}`.
  - **Title:** `Set Max`. Show `Part` as the description, and add a `Current` label bound to
    `if(isNull({view.params.currentMax}), "Current: not set", "Current: " + toStr({view.params.currentMax}))`.
  - **Key handler:** listens for `toleranceKeyPressed`, and the Numpad embed's `messageName` is
    `toleranceKeyPressed`. The handler keeps the 6-digit limit.
  - **Custom method `submit`:**
    `\tnowMs = system.date.toMillis(system.date.now())\n\tif nowMs < (self.view.custom.busyUntil or 0):\n\t\treturn\n\tself.view.custom.busyUntil = nowMs + 2000\n\tres = BlueRidge.Parts.ItemLocation.saveMaxAndNotify(self.view.params.itemLocationId, self.view.custom.qty)\n\tif res and res.get("Status"):\n\t\tsystem.perspective.closePopup("mpp-line-tolerance-edit")`.
  - **Custom method `clearMax`:** the same guard, then
    `saveMaxAndNotify(self.view.params.itemLocationId, "")` and close on success.
  - **Buttons row:** `Cancel` (close), `Clear Max` (`pf-btn pf-btn-secondary`, calls `clearMax`) and
    `Save` (`pf-btn pf-btn-primary`), whose text is bound to
    `"Save " + if(len({view.custom.qty}) = 0, "-", {view.custom.qty})` and whose `enabled` uses the
    `busyUntil` expression from AddLotQty. Every button's `minHeight` is `36px`.
  - Popup id `mpp-line-tolerance-edit`; `defaultSize` `{height 700, width 440}`.

- [ ] **Step 7: Validate + scan.**
  - Every new or changed `view.json` must parse:
    `python -c "import json,sys; [json.load(open(p,encoding='utf-8')) for p in sys.argv[1:]]; print('ok')" <paths>`.
  - Every new view folder has `view.json` + `resource.json` (scope G, `files: ["view.json"]`).
  - Run `.\scan.ps1`, then check `wrapper.log` for errors naming these views.
  - Do **not** claim a render check; that is owed after R5.

- [ ] **Step 8: Commit.**
```bash
git add ignition/projects/Core/com.inductiveautomation.perspective/stylesheet/stylesheet.css ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/LineInventory ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/LineInventoryRow ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/LineTolerances ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/LineToleranceRow ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/LineToleranceEdit
git commit -m "feat(ignition): line inventory rev 2 views -- red level, line-wide toggle, footer, Tolerances popup"
```
  Confirm no `thumbnail.png` is staged.

---

### Task R5: Named queries + Python glue

**Files:** as listed for R5. Runs **after R2 and R3** are committed and applied to Dev.

**Interfaces:**
- Consumes the R2 and R3 proc signatures and column lists above.
- Produces exactly the R4 "Interfaces" list.

- [ ] **Step 1: NQs.**
  - **`lots/Lot_GetLineInventorySummary/query.sql`:**
    `EXEC Lots.Lot_GetLineInventorySummary @LocationId = :locationId, @TerminalRole = :terminalRole, @LineWide = :lineWide`.
    In its `resource.json`, replace the `finishedGoodItemId` parameter with `terminalRole`
    (sqlType 7) and `lineWide` (sqlType 6); keep `locationId` (sqlType 3).
  - **New `parts/ItemLocation_ListConsumptionForLine`:**
    `EXEC Parts.ItemLocation_ListConsumptionForLine @LocationId = :locationId`. `type: Query`,
    `locationId` sqlType 3.
  - **New `parts/ItemLocation_SetMaxQuantity`:**
    `EXEC Parts.ItemLocation_SetMaxQuantity @ItemLocationId = :itemLocationId, @MaxQuantity = :maxQuantity, @AppUserId = :appUserId`.
    `type: Query`, sqlTypes 3 / 2 / 3.

  For each new `resource.json`, copy an existing sibling in `named-query/parts/` byte-shape and change
  only the parameters and `lastModification`. Keep a trailing newline.

- [ ] **Step 2: `BlueRidge.Lots.Lot`.** Replace `getLineInventorySummary`,
  `getLineInventoryInstances` and `getLineInventoryHeader` with the versions below, and add
  `getLineInventoryFooter`. Keep `_thousands`, `checkInBox` and `checkInAndNotify` unchanged.

```python
_LINE_INV_VISIBLE_ROWS = 12
_SCOPE_TEXT = {"Castings": "Castings at this line",
               "Purchased": "Bought parts at this line",
               "All": "All parts this line uses"}


def getLineInventorySummary(locationId, terminalRole=None, lineWide=False):
    """Line Inventory rows (Lots.Lot_GetLineInventorySummary v2.0): ItemId, Description,
       Available, MaxQuantity, Level (Critical/Low/Ok/None), BoxQuantity, AddLotMode
       (OneTap/AskQty/None), ItemLocationId, ScopeCode. Membership, scope, level and
       order are decided by the proc. Returns [] when there is no location."""
    locationId = _u(locationId)
    if locationId is None:
        return []
    role = _u(terminalRole)
    if role is not None and ("%s" % role).strip() == "":
        role = None
    return BlueRidge.Common.Db.execList(
        "lots/Lot_GetLineInventorySummary",
        {"locationId": locationId, "terminalRole": role,
         "lineWide": 1 if _u(lineWide) else 0}) or []


def getLineInventoryInstances(locationId, terminalRole=None, lineWide=False, _refreshToken=None):
    """Flex-repeater instances for Components/PlantFloor/LineInventory. Display
       formatting only. Scalar args only; _refreshToken is the ignored re-read arg."""
    out = []
    for r in getLineInventorySummary(locationId, terminalRole, lineWide):
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
            "level":         r.get("Level") or "None",
            "addLotMode":    mode,
            "boxQuantity":   box,
            "buttonText":    caption,
            "locationId":    _u(locationId),
        })
    return out


def getLineInventoryHeader(locationId, terminalRole=None, lineWide=False, _refreshToken=None):
    """Scope sentence for the panel header. Always returns a string."""
    rows = getLineInventorySummary(locationId, terminalRole, lineWide)
    if not rows:
        return "Nothing at this line"
    return _SCOPE_TEXT.get(rows[0].get("ScopeCode"), _SCOPE_TEXT["All"])


def getLineInventoryFooter(locationId, terminalRole=None, lineWide=False, _refreshToken=None):
    """Overflow sentence for the panel footer ('' when every row fits). Counts hidden
       rows the PROC flagged Low/Critical; it decides nothing itself."""
    rows = getLineInventorySummary(locationId, terminalRole, lineWide)
    hidden = rows[_LINE_INV_VISIBLE_ROWS:]
    if not hidden:
        return ""
    flagged = len([r for r in hidden if (r or {}).get("Level") in ("Low", "Critical")])
    if flagged:
        return u"+%d more below · %d low" % (len(hidden), flagged)
    return u"+%d more below · all above 30%%" % len(hidden)
```

- [ ] **Step 3: `BlueRidge.Parts.ItemLocation`.** Append (keep the existing `_u` and eligibility
  functions):

```python
def listConsumptionForLine(locationId, _refreshToken=None):
    """Consumption parts for the Tolerances popup (Parts.ItemLocation_ListConsumptionForLine):
       ItemLocationId, ItemId, Description, Available, MaxQuantity, MinQuantity,
       RowLocationCode. Returns [] when there is no location."""
    locationId = _u(locationId)
    if locationId is None:
        return []
    return BlueRidge.Common.Db.execList(
        "parts/ItemLocation_ListConsumptionForLine", {"locationId": locationId}) or []


def getToleranceInstances(locationId, _refreshToken=None):
    """Flex-repeater instances for Components/PlantFloor/LineTolerances. Display only."""
    out = []
    for r in listConsumptionForLine(locationId):
        r = r or {}
        mx = r.get("MaxQuantity")
        out.append({
            "itemLocationId": r.get("ItemLocationId"),
            "description":    r.get("Description") or "",
            "availableText":  BlueRidge.Lots.Lot._thousands(r.get("Available") or 0),
            "maxText":        "not set" if mx is None else BlueRidge.Lots.Lot._thousands(mx),
            "maxQuantity":    mx,
        })
    return out


def setMaxQuantity(itemLocationId, maxQuantity, appUserId=None):
    """Parts.ItemLocation_SetMaxQuantity. maxQuantity None clears Max. The proc owns
       every rule (consumption point only, > 0, not below Min). Returns {Status, Message}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execMutation(
        "parts/ItemLocation_SetMaxQuantity",
        {"itemLocationId": _u(itemLocationId), "maxQuantity": _u(maxQuantity),
         "appUserId": appUserId})


def saveMaxAndNotify(itemLocationId, rawValue):
    """Tolerances popup save: a blank value clears Max; a non-number is refused here
       (input parsing, not a business rule); everything else is the proc's call.
       Toasts the outcome and, on success, tells the page to recolour."""
    raw = ("%s" % (_u(rawValue) if _u(rawValue) is not None else "")).strip().replace(",", "")
    if raw == "":
        value = None
    else:
        try:
            value = int(raw)
        except (ValueError, TypeError):
            BlueRidge.Common.Notify.toast("Invalid number", "Enter a whole number, or clear Max.", "warning")
            return {"Status": 0, "Message": "Invalid number"}
    res = setMaxQuantity(itemLocationId, value)
    BlueRidge.Common.Ui.notifyResult(res, "Max saved")
    if res and res.get("Status"):
        system.perspective.sendMessage("inventoryChanged", payload={}, scope="page")
    return res
```

  Check first that `BlueRidge.Lots.Lot._thousands` is reachable from another module (Jython
  module-level functions are). If the project convention frowns on cross-module private helpers,
  copy a local `_thousands` into this module instead, and say which you did.

- [ ] **Step 4: Verify.**
  - `ast.parse` both modules (UTF-8).
  - Run `.\scan.ps1`, then check `wrapper.log`.
  - Read-only against Dev (`sqlcmd ... -E -C`): run the two new procs and the summary proc with a
    real M&A line cell (e.g. `MA2-6FBCHOP`), and confirm the column names match the Python keys.
  - Read the three views from R4 and confirm every `runScript` argument order and every row param
    name matches.
  - Do not write to Dev. Do not claim the Python ran unless it did.

- [ ] **Step 5: Commit.**
```bash
git add ignition/projects/Core/ignition/named-query/lots/Lot_GetLineInventorySummary ignition/projects/Core/ignition/named-query/parts/ItemLocation_ListConsumptionForLine ignition/projects/Core/ignition/named-query/parts/ItemLocation_SetMaxQuantity ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Parts/ItemLocation/code.py
git commit -m "feat(ignition): line inventory rev 2 glue -- scope/level/footer, tolerances list + Max save"
```

---

### Task R6: Designer edits (Jacques)

Not agent work. These go in the handoff note in Task R8:
1. **Dock `LineInventory` on the five screens**, passing `locationId` from
   `session.custom.cell.locationId` and `terminalRole`:

   | Screen | `terminalRole` |
   |---|---|
   | MachiningIn | `MachiningIn` |
   | MachiningOutSplit | `MachiningOut` |
   | AssemblyIn | `AssemblyIn` |
   | AssemblySerialized | `AssemblyOut` |
   | AssemblyNonSerialized | `AssemblyOut` |

   Also remove AssemblySerialized's `ComponentsPanel`, and replace AssemblyNonSerialized's
   `InventorySidebar` contents.
2. **`InventoryManager`:** switch the `OnHandRepeater` binding to `getInventoryPopupCards`.
3. **Item Master Identity:** add a **Box Quantity** field, enabled for Pass-Through.
4. **`AppHeaderLarge`:** remove the `lowInventoryWarning` handler.

### Task R7: Retire the tray projection (after R6)

Same content as the original plan's Task 10, except the migration takes the **next free number**
(never `0092`). Blocked until R6 lands, because AssemblyNonSerialized still binds the projection.

### Task R8: Status + handoff

Append to `PROJECT_STATUS.md` and write `notes/2026-09-17_line-inventory-designer-handoff.md`
covering:
- the R6 list;
- that Dev needs `0089` for any button to render;
- that MPP must enter a Max per consumption part (through the Tolerances popup) and a Box Quantity
  per bought part.

Set the spec status to `Built <date> (Dev); Designer docking owed`.
