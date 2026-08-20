# CRT Part-Scoped Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CRT (Controlled Run Tag) part-scoped and propagating, so suspect material is tagged at mint and cannot advance to production until Quality clears it per-LOT.

**Architecture:** Two schema columns and three inline table-valued/scalar functions. Every mint proc asks one resolver whether the new LOT is CRT; every advance/consume proc asks one guard whether a LOT is blocked. Nothing that already works is replaced — `Lots.Lot.CrtActive`, `Lot_SetCrt` / `Lot_ClearCrt`, `Container_Ship`'s ship block, the AIM hold and the 200% inspection prompt are all reused as-is.

**Tech Stack:** SQL Server 2022, T-SQL repeatable procs (`R__*.sql`) and versioned migrations, Ignition Perspective 8.3 (file-based `view.json`), Jython 2.7 project scripts.

**Source spec:** `docs/superpowers/specs/2026-08-19-crt-part-scoped-design.md`. Read it before starting; the decision table D1–D9 is the authority for every behavioural question.

## Global Constraints

- **FDS-11-011:** no `OUTPUT` parameters, ever. `@Status` / `@Message` / `@NewId` are LOCAL variables; every exit path ends with exactly one `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;`. **One result set per proc.**
- **All rejecting validations run BEFORE `BEGIN TRANSACTION`.** A `ROLLBACK` inside a proc invoked via `INSERT-EXEC` throws Msg 3915, so the CATCH block is the only legal ROLLBACK site.
- A proc captured via `INSERT … EXEC` must **not** `EXEC` another status-row proc. Inline sub-mutations instead.
- `RAISERROR` (not `THROW`) in CATCH blocks. Schema-qualify every database reference. `EXEC` parameters must be literals or `@variables` — never inline `CAST` / arithmetic / `CASE`.
- **Functions get no deferred name resolution (Msg 4121).** A repeatable `R__` file defining a FUNCTION must sort alphabetically AFTER anything it references. State the reason in the file header so nobody "tidies" the name.
- Conventions: `UpperCamelCase`, `BIGINT` FKs, `NVARCHAR` never `VARCHAR`, `DATETIME2(3)`, timestamps stored UTC via `SYSUTCDATETIME()`, user attribution via `BIGINT FK → Location.AppUser(Id)`.
- **Audit:** `Audit.ConfigLog` / `OperationLog` Description in the shape `<SUBJECT> · <CATEGORY?> · <ACTION>` via `Audit.ufn_MidDot()`, resolved-name FK sub-objects wrapped in `JSON_QUERY(...)`, truncated with `Audit.ufn_TruncateActivity()`.
- **Seed/data strings are ASCII-only.** `sqlcmd` reads `.sql` in the Windows codepage, so an em-dash or middle-dot becomes mojibake and surfaces in Ignition. Byte-scan generated SQL before finishing.
- **Ignition view.json are Designer-serialized:** `=`, `'`, `<`, `>` are 6-char unicode escapes (`=`). Build escapes at runtime (`BS = chr(92)`) — tool parameters decode `\\u` in transit. Re-validate with `json.load()` after every write, never write a UTF-8 BOM (`io.open(p,'w',encoding='utf-8',newline='')`), and **check each file's existing line endings and preserve them** (they vary; `CavityLotRow` is CRLF, `DieCastBody` is LF).
- Every `view.custom.*` a binding READS must be declared in the `custom` block with a fully-shaped default, and the binding source must return that shape on the empty path. Every embed param needs a `propConfig` `paramDirection: "input"` entry.
- **Tests run against a private throwaway database.** `cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Crt" -Filter "<yours>"`. **Never** the bare `MPP_MES_Test` (concurrent work drops it) and **never** `MPP_MES_Dev`. Grep output for **BOTH** `FAIL` and `ERROR running` — this class of breakage surfaces as a runner exit-1 with green assertion counts.
- **Four `sql/tests/0022_PlantFloor_DieCast` files (030/040/050/070) are ALREADY broken** before you start, on a stale `ToolAssignment.CellLocationId` fixture. Do not chase them; confirm your run's error list matches HEAD's rather than assuming.
- **Elevation is currently non-functional on the dev gateway.** `_ELEVATION_USER_SOURCE` is `"Active Directory"`, which does not exist there (only `default`, `MPP`, `opcua-module`, all INTERNAL). To exercise Task 9's gate locally, either create a user source of that name or temporarily set the constant to `"MPP"` — **and do not commit that revert.**

## File Structure

| File | Responsibility |
|---|---|
| `sql/migrations/versioned/00NN_crt_part_scoped.sql` | **Create.** Both columns + the `IsProductionDestination` seed. |
| `sql/migrations/repeatable/R__Lots_ufn_zz_CrtForMint.sql` | **Create.** The three-way OR of D1. `zz_` is a deploy-order marker. |
| `sql/migrations/repeatable/R__Lots_ufn_zz_CrtBlocks.sql` | **Create.** `ufn_CrtBlocksAdvance` + `ufn_CrtBlocksMoveTo`. |
| `R__Lots_Lot_Create.sql`, `R__Workorder_MachiningOut_Mint.sql`, `R__Workorder_Assembly_CompleteTray.sql`, `R__Lots_Lot_Split.sql`, `R__Lots_Lot_Merge.sql` | **Modify.** Stamp `CrtActive` from the resolver. |
| `R__Lots_Lot_MoveTo.sql`, `R__Lots_Lot_MoveToValidated.sql` | **Modify.** Destination-aware block (D5). |
| `R__Workorder_MachiningIn_RecordPick.sql` | **Modify.** Advance block. |
| `R__Lots_LotLabel_Print.sql`, `R__Lots_LotLabel_Reprint.sql` | **Modify.** `{CrtMark}` substitution. |
| `.../MPP_Config/.../Parts/ItemMaster/Identity/view.json` | **Modify.** `CrtEnabled` checkbox. |
| `.../MPP/.../Views/ShopFloor/LotDetail/view.json` | **Modify.** CRT badge + Enable/Disable toggle. |
| `.../Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` | **Modify.** `setCrt` / `clearCrt` wrappers. |
| `sql/tests/0063_Crt_PartScoped/010..070_*.sql` | **Create.** One file per behavioural area: schema, resolver, guards, propagation, enforcement, label. |

---

### Task 1: Schema — the two columns and the seed

**Files:**
- Create: `sql/migrations/versioned/00NN_crt_part_scoped.sql` — **determine NN at build time**: run `ls sql/migrations/versioned/ | tail -3`. `0061` is taken on this branch; `main` carries others (`0058_session_policy_operator_30min`, `0059_vision_app_ip`). Pick the next free ordinal higher than every file present.
- Test: `sql/tests/0063_Crt_PartScoped/010_schema.sql`

**Interfaces:**
- Consumes: nothing.
- Produces: `Parts.Item.CrtEnabled BIT NOT NULL DEFAULT 0`; `Location.LocationTypeDefinition.IsProductionDestination BIT NOT NULL DEFAULT 0`, seeded per the table below.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0063_Crt_PartScoped/010_schema.sql`:

```sql
-- =============================================
-- File:         0063_Crt_PartScoped/010_schema.sql
-- Author:       Blue Ridge Automation
-- Description:  Schema for part-scoped CRT (design 2026-08-19, section 4).
--               Parts.Item.CrtEnabled and
--               Location.LocationTypeDefinition.IsProductionDestination,
--               plus the production-vs-not seed that D5 depends on.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0063_Crt_PartScoped/010_schema.sql';
GO

DECLARE @n INT;

SET @n = CASE WHEN COL_LENGTH('Parts.Item','CrtEnabled') IS NULL THEN 0 ELSE 1 END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] Parts.Item.CrtEnabled exists',
    @Expected = N'1', @Actual = @n;

SET @n = CASE WHEN COL_LENGTH('Location.LocationTypeDefinition','IsProductionDestination') IS NULL THEN 0 ELSE 1 END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] LocationTypeDefinition.IsProductionDestination exists',
    @Expected = N'1', @Actual = @n;

SELECT @n = COUNT(*) FROM Parts.Item WHERE CrtEnabled <> 0;
EXEC test.Assert_IsEqual @TestName = N'[Schema] CrtEnabled defaults to 0 for every existing item',
    @Expected = N'0', @Actual = @n;

SELECT @n = COUNT(*) FROM Location.LocationTypeDefinition
WHERE Code IN (N'DieCastMachine', N'TrimPress', N'CNCMachine', N'AssemblyStation',
               N'SerializedAssemblyLine', N'ProductionLine', N'ProductionArea')
  AND IsProductionDestination = 1;
EXEC test.Assert_IsEqual @TestName = N'[Schema] all 7 production definitions seeded to 1',
    @Expected = N'7', @Actual = @n;

SELECT @n = COUNT(*) FROM Location.LocationTypeDefinition
WHERE Code IN (N'InspectionStation', N'InspectionLine', N'InventoryLocation',
               N'Receiving', N'SupportArea', N'Printer', N'Scale', N'Terminal')
  AND IsProductionDestination = 1;
EXEC test.Assert_IsEqual @TestName = N'[Schema] no non-production definition is flagged',
    @Expected = N'0', @Actual = @n;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Crt" -Filter "0063"
```

Expected: FAIL on `Parts.Item.CrtEnabled exists` (Expected 1, Actual 0).

- [ ] **Step 3: Write the migration**

Create the migration file. Note the header block must follow the house shape — copy the header style from `sql/migrations/versioned/0061_diecast_contribution_cell.sql`.

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF COL_LENGTH('Parts.Item', 'CrtEnabled') IS NULL
    ALTER TABLE Parts.Item
        ADD CrtEnabled BIT NOT NULL CONSTRAINT DF_Item_CrtEnabled DEFAULT 0;
GO

IF COL_LENGTH('Location.LocationTypeDefinition', 'IsProductionDestination') IS NULL
    ALTER TABLE Location.LocationTypeDefinition
        ADD IsProductionDestination BIT NOT NULL
            CONSTRAINT DF_LTD_IsProductionDestination DEFAULT 0;
GO

-- D5a: production-vs-not is DATA, so a new definition declares itself rather
-- than requiring a proc edit. Idempotent -- re-running re-asserts the same set.
UPDATE Location.LocationTypeDefinition
   SET IsProductionDestination = 1
 WHERE Code IN (N'DieCastMachine', N'TrimPress', N'CNCMachine',
                N'AssemblyStation', N'SerializedAssemblyLine',
                N'ProductionLine', N'ProductionArea')
   AND IsProductionDestination <> 1;

UPDATE Location.LocationTypeDefinition
   SET IsProductionDestination = 0
 WHERE Code IN (N'InspectionStation', N'InspectionLine', N'InventoryLocation',
                N'Receiving', N'SupportArea', N'Printer', N'Scale', N'Terminal')
   AND IsProductionDestination <> 0;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'00NN_crt_part_scoped')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'00NN_crt_part_scoped',
            N'Part-scoped CRT: Parts.Item.CrtEnabled and Location.LocationTypeDefinition.IsProductionDestination (+ seed).');
GO
```

Replace `00NN` with the ordinal chosen in Step 1, in **both** the filename and the two `MigrationId` literals.

- [ ] **Step 4: Run the test and watch it pass**

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Crt" -Filter "0063"
```

Expected: 5 passed, 0 failed. Grep the output for both `FAIL` and `ERROR running`.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/00NN_crt_part_scoped.sql sql/tests/0063_Crt_PartScoped/010_schema.sql
git commit -m "feat(crt): part flag and production-destination classification

Parts.Item.CrtEnabled drives part-scoped CRT (design D1).
Location.LocationTypeDefinition.IsProductionDestination makes the
movement block of D5 data-driven rather than a hardcoded list of
definition codes in a proc -- a new definition declares itself."
```

---

### Task 2: `Lots.ufn_CrtForMint` — the single place CRT is decided

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_ufn_zz_CrtForMint.sql`
- Test: `sql/tests/0063_Crt_PartScoped/020_crt_for_mint.sql`

**Interfaces:**
- Consumes: `Parts.Item.CrtEnabled` (Task 1).
- Produces: `Lots.ufn_CrtForMint(@ItemId BIGINT, @TerminalLocationId BIGINT, @InputLotIdsCsv NVARCHAR(MAX)) RETURNS TABLE` with one column `CrtActive BIT`. **Inline TVF, not scalar** — it is called from `SELECT` inside mint procs and an iTVF inlines into the plan. Callers use `(SELECT CrtActive FROM Lots.ufn_CrtForMint(...))`.

The `zz_` infix is a **deploy-order marker**, not part of the object name: functions get no deferred name resolution (Msg 4121), and this file must sort after anything it references. Say so in the header.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0063_Crt_PartScoped/020_crt_for_mint.sql`. Fixture: one item with `CrtEnabled = 0` (`@ItemPlain`), one with `CrtEnabled = 1` (`@ItemCrt`), one Terminal location carrying the `CrtEnabled` attribute (`@TermCrt`), one without (`@TermPlain`), and two LOTs — one `CrtActive = 1` (`@LotCrt`), one `0` (`@LotPlain`).

```sql
EXEC test.BeginTestFile @FileName = N'0063_Crt_PartScoped/020_crt_for_mint.sql';
GO
-- ... fixture setup omitted here for brevity in this step ONLY because the
-- implementer must write it against live ids; see the fixture block below.
DECLARE @b BIT;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemPlain, NULL, NULL);
EXEC test.Assert_IsEqual @TestName = N'[ForMint] nothing set -> 0', @Expected = N'0', @Actual = @b;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemCrt, NULL, NULL);
EXEC test.Assert_IsEqual @TestName = N'[ForMint] part flag alone -> 1', @Expected = N'1', @Actual = @b;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemPlain, @TermCrt, NULL);
EXEC test.Assert_IsEqual @TestName = N'[ForMint] terminal switch alone -> 1', @Expected = N'1', @Actual = @b;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemPlain, @TermPlain, CAST(@LotCrt AS NVARCHAR(20)));
EXEC test.Assert_IsEqual @TestName = N'[ForMint] CRT input alone -> 1 (propagation)', @Expected = N'1', @Actual = @b;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemPlain, @TermPlain, CAST(@LotPlain AS NVARCHAR(20)));
EXEC test.Assert_IsEqual @TestName = N'[ForMint] clean input -> 0', @Expected = N'0', @Actual = @b;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemPlain, @TermPlain,
    CAST(@LotPlain AS NVARCHAR(20)) + N',' + CAST(@LotCrt AS NVARCHAR(20)));
EXEC test.Assert_IsEqual @TestName = N'[ForMint] one CRT among several inputs -> 1', @Expected = N'1', @Actual = @b;

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@ItemPlain, NULL, N'');
EXEC test.Assert_IsEqual @TestName = N'[ForMint] empty csv is not an error -> 0', @Expected = N'0', @Actual = @b;
GO
EXEC test.EndTestFile;
GO
```

Fixture block to place before the assertions (adjust ids to whatever the reset seeds):

```sql
DECLARE @ItemPlain BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @ItemCrt   BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id <> @ItemPlain ORDER BY Id);
UPDATE Parts.Item SET CrtEnabled = 0 WHERE Id = @ItemPlain;
UPDATE Parts.Item SET CrtEnabled = 1 WHERE Id = @ItemCrt;

DECLARE @TermPlain BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @TermCrt BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.Id <> @TermPlain ORDER BY l.Id);

DECLARE @AdCrt BIGINT = (SELECT TOP 1 Id FROM Location.LocationAttributeDefinition
    WHERE AttributeName = N'CrtEnabled' AND DeprecatedAt IS NULL);
DELETE FROM Location.LocationAttribute WHERE LocationId IN (@TermCrt, @TermPlain) AND LocationAttributeDefinitionId = @AdCrt;
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue)
VALUES (@TermCrt, @AdCrt, N'1');

DECLARE @LotPlain BIGINT = (SELECT TOP 1 Id FROM Lots.Lot ORDER BY Id);
DECLARE @LotCrt   BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE Id <> @LotPlain ORDER BY Id);
UPDATE Lots.Lot SET CrtActive = 0 WHERE Id = @LotPlain;
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @LotCrt;
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Crt" -Filter "0063"
```

Expected: `ERROR running 020_crt_for_mint.sql` — *Invalid object name 'Lots.ufn_CrtForMint'*.

- [ ] **Step 3: Write the function**

Create `sql/migrations/repeatable/R__Lots_ufn_zz_CrtForMint.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_ufn_zz_CrtForMint.sql
-- Description: The ONE place the CRT-at-mint decision is made (design D1).
--              A LOT mints CRT-active if ANY of:
--                1. its part carries Parts.Item.CrtEnabled = 1, OR
--                2. the minting terminal carries the CrtEnabled location
--                   attribute (migration 0058), OR
--                3. any consumed input LOT is already CrtActive (D2 propagation).
--              Evaluated at MINT TIME ONLY (D3) -- nothing re-derives later.
--
-- FILE NAME IS ORDER-SENSITIVE. The 'zz_' is a DEPLOY-ORDER MARKER, not part
-- of the object name. A FUNCTION gets no deferred name resolution (Msg 4121),
-- so this file must sort AFTER everything it references. Do not tidy the name.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_CrtForMint
(
    @ItemId             BIGINT,
    @TerminalLocationId BIGINT        = NULL,
    @InputLotIdsCsv     NVARCHAR(MAX) = NULL
)
RETURNS TABLE
AS
RETURN
(
    SELECT CONVERT(BIT, CASE WHEN
        EXISTS (SELECT 1 FROM Parts.Item i
                 WHERE i.Id = @ItemId AND i.CrtEnabled = 1)
     OR EXISTS (SELECT 1
                  FROM Location.LocationAttribute la
                  JOIN Location.LocationAttributeDefinition ad
                    ON ad.Id = la.LocationAttributeDefinitionId
                 WHERE la.LocationId = @TerminalLocationId
                   AND ad.AttributeName = N'CrtEnabled'
                   AND ad.DeprecatedAt IS NULL
                   AND la.AttributeValue = N'1')
     OR EXISTS (SELECT 1
                  FROM STRING_SPLIT(ISNULL(@InputLotIdsCsv, N''), N',') s
                  JOIN Lots.Lot l ON l.Id = TRY_CAST(s.value AS BIGINT)
                 WHERE l.CrtActive = 1)
        THEN 1 ELSE 0 END) AS CrtActive
);
```

- [ ] **Step 4: Run the test and watch it pass**

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Crt" -Filter "0063"
```

Expected: 12 passed (5 from Task 1 + 7 here), 0 failed.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_ufn_zz_CrtForMint.sql sql/tests/0063_Crt_PartScoped/020_crt_for_mint.sql
git commit -m "feat(crt): ufn_CrtForMint - the single CRT-at-mint decision

Three-way OR of design D1: part flag, terminal switch, or a CRT input
LOT. Inline TVF so it folds into the caller's plan. The zz_ infix is a
deploy-order marker (Msg 4121, functions get no deferred name
resolution), not part of the object name."
```

---

### Task 3: `ufn_CrtBlocksAdvance` and `ufn_CrtBlocksMoveTo` — the guards

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_ufn_zz_CrtBlocks.sql`
- Test: `sql/tests/0063_Crt_PartScoped/030_crt_blocks.sql`

**Interfaces:**
- Consumes: `Location.LocationTypeDefinition.IsProductionDestination` (Task 1).
- Produces: `Lots.ufn_CrtBlocksAdvance(@LotId BIGINT) RETURNS TABLE` → `Blocked BIT`; `Lots.ufn_CrtBlocksMoveTo(@LotId BIGINT, @ToLocationId BIGINT) RETURNS TABLE` → `Blocked BIT`. Both inline TVFs, consumed as `(SELECT Blocked FROM …)`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0063_Crt_PartScoped/030_crt_blocks.sql`:

```sql
EXEC test.BeginTestFile @FileName = N'0063_Crt_PartScoped/030_crt_blocks.sql';
GO
-- Run-Tests.ps1 resets with -SkipDemoSeed, so Lots.Lot starts EMPTY and is then
-- filled by whatever earlier test files happened to create. Never grab an
-- arbitrary existing LOT: its status, hold state and location are another
-- test's business, and a guard test that passes because the LOT was already
-- closed proves nothing. INSERT your own, as 020_crt_for_mint.sql does:
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, CrtActive)
VALUES (N'TEST-CRT-<UNIQUE>', @Item, 1 /*Manufactured*/, 1 /*Good*/, 10, @StartLoc, @App, 1);
DECLARE @LotCrt BIGINT = SCOPE_IDENTITY();

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, CrtActive)
VALUES (N'TEST-OK-<UNIQUE>', @Item, 1 /*Manufactured*/, 1 /*Good*/, 10, @StartLoc, @App, 0);
DECLARE @LotOk BIGINT = SCOPE_IDENTITY();
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @LotCrt;
UPDATE Lots.Lot SET CrtActive = 0 WHERE Id = @LotOk;

DECLARE @ProdLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.IsProductionDestination = 1 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @SafeLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.IsProductionDestination = 0 AND d.Code IN (N'InventoryLocation', N'InspectionStation', N'Receiving')
      AND l.DeprecatedAt IS NULL ORDER BY l.Id);

DECLARE @b BIT;

SELECT @b = Blocked FROM Lots.ufn_CrtBlocksAdvance(@LotCrt);
EXEC test.Assert_IsEqual @TestName = N'[Blocks] CRT lot blocks advance', @Expected = N'1', @Actual = @b;

SELECT @b = Blocked FROM Lots.ufn_CrtBlocksAdvance(@LotOk);
EXEC test.Assert_IsEqual @TestName = N'[Blocks] clean lot does not block advance', @Expected = N'0', @Actual = @b;

SELECT @b = Blocked FROM Lots.ufn_CrtBlocksMoveTo(@LotCrt, @ProdLoc);
EXEC test.Assert_IsEqual @TestName = N'[Blocks] CRT lot blocked moving to production', @Expected = N'1', @Actual = @b;

SELECT @b = Blocked FROM Lots.ufn_CrtBlocksMoveTo(@LotCrt, @SafeLoc);
EXEC test.Assert_IsEqual @TestName = N'[Blocks] CRT lot ALLOWED moving to inspection/inventory (D5)', @Expected = N'0', @Actual = @b;

SELECT @b = Blocked FROM Lots.ufn_CrtBlocksMoveTo(@LotOk, @ProdLoc);
EXEC test.Assert_IsEqual @TestName = N'[Blocks] clean lot moves to production freely', @Expected = N'0', @Actual = @b;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Crt" -Filter "0063"
```

Expected: `ERROR running 030_crt_blocks.sql` — *Invalid object name 'Lots.ufn_CrtBlocksAdvance'*.

- [ ] **Step 3: Write both functions**

Create `sql/migrations/repeatable/R__Lots_ufn_zz_CrtBlocks.sql`. Both live in one file because they are one concept and are always deployed together; the `zz_` marker applies for the same Msg 4121 reason as Task 2. `CREATE FUNCTION` must be first in its batch, so separate the two with `GO`.

```sql
-- ============================================================
-- Repeatable:  R__Lots_ufn_zz_CrtBlocks.sql
-- Description: The CRT enforcement guards (design D4, D5).
--              ufn_CrtBlocksAdvance -- a CRT LOT cannot be consumed or
--                advanced. Trivial today, but it is the SEAM: if the rule
--                ever considers hold state, inspection status or a grace
--                period, it changes here and every caller inherits it.
--              ufn_CrtBlocksMoveTo -- a CRT LOT cannot move to a PRODUCTION
--                destination, but CAN move to inspection, inventory,
--                receiving or a support area, so suspect material can still
--                be taken to quarantine.
--
-- FILE NAME IS ORDER-SENSITIVE -- see R__Lots_ufn_zz_CrtForMint.sql. Msg 4121.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_CrtBlocksAdvance (@LotId BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT CONVERT(BIT, CASE WHEN EXISTS (
        SELECT 1 FROM Lots.Lot l WHERE l.Id = @LotId AND l.CrtActive = 1
    ) THEN 1 ELSE 0 END) AS Blocked
);
GO

CREATE OR ALTER FUNCTION Lots.ufn_CrtBlocksMoveTo (@LotId BIGINT, @ToLocationId BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT CONVERT(BIT, CASE WHEN EXISTS (
        SELECT 1
          FROM Lots.Lot l
          JOIN Location.Location dst ON dst.Id = @ToLocationId
          JOIN Location.LocationTypeDefinition d ON d.Id = dst.LocationTypeDefinitionId
         WHERE l.Id = @LotId
           AND l.CrtActive = 1
           AND d.IsProductionDestination = 1
    ) THEN 1 ELSE 0 END) AS Blocked
);
GO
```

- [ ] **Step 4: Run the test and watch it pass**

Expected: 17 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_ufn_zz_CrtBlocks.sql sql/tests/0063_Crt_PartScoped/030_crt_blocks.sql
git commit -m "feat(crt): the advance and move-to guards

ufn_CrtBlocksAdvance is the seam for D4; ufn_CrtBlocksMoveTo implements
D5's destination rule so a CRT lot can still be taken to quarantine."
```

---

### Task 4: Stamp CRT at every mint point

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_Create.sql`
- Modify: `sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql`
- Modify: `sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql` (**lines 271–280** currently inline the terminal-attribute lookup — that block is DELETED and replaced by the resolver call)
- Modify: `sql/migrations/repeatable/R__Lots_Lot_Split.sql`, `R__Lots_Lot_Merge.sql`
- Test: `sql/tests/0063_Crt_PartScoped/040_propagation.sql`

**Interfaces:**
- Consumes: `Lots.ufn_CrtForMint` (Task 2).
- Produces: every newly minted `Lots.Lot` row carries a correct `CrtActive`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0063_Crt_PartScoped/040_propagation.sql`. This is the heart of D2/D3 — write these four assertions:

```sql
EXEC test.BeginTestFile @FileName = N'0063_Crt_PartScoped/040_propagation.sql';
GO
-- Fixture: flag a casting part, leave the sub-assembly part UNFLAGGED. The point
-- of assertion 2 is that the sub-assembly inherits CRT from its INPUT, not from
-- its own part.
DECLARE @CastItem BIGINT = (SELECT TOP 1 i.Id FROM Parts.Item i
    JOIN Parts.ItemType t ON t.Id = i.ItemTypeId
    WHERE t.Code = N'Component' AND i.DeprecatedAt IS NULL ORDER BY i.Id);
DECLARE @SubItem BIGINT = (SELECT TOP 1 i.Id FROM Parts.Item i
    JOIN Parts.ItemType t ON t.Id = i.ItemTypeId
    WHERE t.Code = N'SubAssembly' AND i.DeprecatedAt IS NULL ORDER BY i.Id);
UPDATE Parts.Item SET CrtEnabled = 1 WHERE Id = @CastItem;
UPDATE Parts.Item SET CrtEnabled = 0 WHERE Id = @SubItem;

DECLARE @Loc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'DieCastMachine' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @Origin BIGINT = (SELECT TOP 1 Id FROM Lots.LotOriginType ORDER BY Id);

CREATE TABLE #r (Status BIT, Message NVARCHAR(500), NewId BIGINT);

-- 1. A LOT of a CrtEnabled part mints CRT-active.
INSERT INTO #r EXEC Lots.Lot_Create @ItemId = @CastItem, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Loc, @PieceCount = 10, @AppUserId = 1;
DECLARE @CastLot BIGINT = (SELECT TOP 1 NewId FROM #r);
DECLARE @castingCrt BIT = (SELECT CrtActive FROM Lots.Lot WHERE Id = @CastLot);
EXEC test.Assert_IsEqual @TestName = N'[Prop] casting of a CRT part mints CrtActive=1',
    @Expected = N'1', @Actual = @castingCrt;

-- 2. A mint that CONSUMES it inherits CRT even though @SubItem is NOT flagged (D2).
--    Exercised through the resolver directly so the test does not depend on
--    MachiningOut_Mint's full route/BOM preconditions.
DECLARE @subCrt BIT = (SELECT CrtActive FROM Lots.ufn_CrtForMint(
    @SubItem, NULL, CAST(@CastLot AS NVARCHAR(20))));
EXEC test.Assert_IsEqual @TestName = N'[Prop] sub-assembly from a CRT casting is CrtActive=1 (part not flagged)',
    @Expected = N'1', @Actual = @subCrt;

-- 3. Clearing the casting FIRST yields a CLEAN sub-assembly -- D2's release valve.
DELETE FROM #r;
INSERT INTO #r EXEC Lots.Lot_ClearCrt @LotId = @CastLot, @AppUserId = 1;
DECLARE @subAfterClear BIT = (SELECT CrtActive FROM Lots.ufn_CrtForMint(
    @SubItem, NULL, CAST(@CastLot AS NVARCHAR(20))));
EXEC test.Assert_IsEqual @TestName = N'[Prop] clearing the casting before minting yields a clean sub-assembly',
    @Expected = N'0', @Actual = @subAfterClear;

-- 4. Re-tag the casting, mint a real sub-assembly LOT from it, then clear the
--    casting AGAIN. The sub-assembly keeps its own tag -- D3, mint-time only.
DELETE FROM #r;
INSERT INTO #r EXEC Lots.Lot_SetCrt @LotId = @CastLot, @AppUserId = 1;
DELETE FROM #r;
INSERT INTO #r EXEC Lots.Lot_Create @ItemId = @SubItem, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Loc, @PieceCount = 10, @AppUserId = 1;
DECLARE @SubLot BIGINT = (SELECT TOP 1 NewId FROM #r);
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @SubLot;   -- stands in for the consuming mint
DELETE FROM #r;
INSERT INTO #r EXEC Lots.Lot_ClearCrt @LotId = @CastLot, @AppUserId = 1;
DECLARE @subStillCrt BIT = (SELECT CrtActive FROM Lots.Lot WHERE Id = @SubLot);
EXEC test.Assert_IsEqual @TestName = N'[Prop] clearing the casting later does NOT un-tag an existing sub-assembly',
    @Expected = N'1', @Actual = @subStillCrt;

DROP TABLE #r;
GO
EXEC test.EndTestFile;
GO
```

Assertion 2 and 3 drive the resolver directly rather than `MachiningOut_Mint`, so the
test does not carry that proc's full route/BOM/eligibility preconditions. Assertion 4
still needs a real second LOT, because it is asserting that a STORED value is not
retroactively changed. The end-to-end path through `MachiningOut_Mint` is covered by
re-running the existing Machining suite in Step 4.

- [ ] **Step 2: Run it and watch it fail**

Expected: assertion 1 fails — `Expected 1, Actual 0` — because nothing stamps `CrtActive` at `Lot_Create` yet.

- [ ] **Step 3: Wire the resolver into each mint proc**

In **`Lots.Lot_Create`**, after the existing validations and inside the transaction, before the `INSERT INTO Lots.Lot`:

```sql
    -- D1/D2: CRT at mint. No input LOTs at a die-cast birth.
    DECLARE @CrtActive BIT =
        (SELECT CrtActive FROM Lots.ufn_CrtForMint(@ItemId, @TerminalLocationId, NULL));
```

Add `CrtActive` to the `INSERT` column list and `@CrtActive` to its `VALUES`.

In **`Workorder.MachiningOut_Mint`**, pass the consumed casting:

```sql
    DECLARE @CrtActive BIT =
        (SELECT CrtActive FROM Lots.ufn_CrtForMint(@ProducedItemId, @TerminalLocationId,
                                                   CAST(@SourceLotId AS NVARCHAR(20))));
```

In **`Workorder.Assembly_CompleteTray`**, **delete lines 271–280** (the inlined
`SELECT @CrtActive = CASE WHEN la.AttributeValue = N'1' …` block) and replace with:

```sql
        -- D1: the terminal-switch lookup that used to be inlined here now lives
        -- in Lots.ufn_CrtForMint, so the CRT decision is made in ONE place.
        -- Consumed sub-assemblies and components propagate per D2.
        SET @CrtActive =
            (SELECT CrtActive FROM Lots.ufn_CrtForMint(@FinishedGoodItemId,
                                                       @TerminalLocationId,
                                                       @ConsumedLotIdsCsv));
```

`@ConsumedLotIdsCsv` is built where the proc already enumerates the tray's consumed LOTs; if no such variable exists, build it with `STRING_AGG(CAST(LotId AS NVARCHAR(20)), N',')` over the same set the genealogy insert uses.

In **`Lots.Lot_Split`** and **`Lots.Lot_Merge`**, pass the source LOT(s) as the CSV and the same `@ItemId` the child is minted with.

- [ ] **Step 4: Run the test and watch it pass**

Expected: 21 passed, 0 failed. **Also re-run the full die-cast and assembly suites** — `Assembly_CompleteTray` changed, and its existing CRT behaviour must be unaffected:

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Crt" -Filter "Assembly"
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Crt" -Filter "DieCast"
```

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Create.sql sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql sql/migrations/repeatable/R__Lots_Lot_Split.sql sql/migrations/repeatable/R__Lots_Lot_Merge.sql sql/tests/0063_Crt_PartScoped/040_propagation.sql
git commit -m "feat(crt): stamp CrtActive at every mint point

Lot_Create, MachiningOut_Mint, Assembly_CompleteTray, Lot_Split and
Lot_Merge all resolve CRT through ufn_CrtForMint. Assembly_CompleteTray's
inlined terminal-attribute lookup is DELETED -- that decision now lives in
one place. Propagation is mint-time only (D3): clearing a casting stops it
tainting future mints but leaves existing descendants tagged."
```

---

### Task 5: Enforcement — block advance and production moves

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_MoveTo.sql`, `R__Lots_Lot_MoveToValidated.sql`
- Modify: `sql/migrations/repeatable/R__Workorder_MachiningIn_RecordPick.sql`, `R__Workorder_MachiningOut_Mint.sql`, `R__Lots_Lot_Split.sql`, `R__Lots_Lot_Merge.sql`
- Test: `sql/tests/0063_Crt_PartScoped/060_enforcement.sql`

**Interfaces:**
- Consumes: `Lots.ufn_CrtBlocksAdvance`, `Lots.ufn_CrtBlocksMoveTo` (Task 3).
- Produces: a rejection — `Status = 0` and a `Message` naming the LOT and the string `CRT`. Not one uniform sentence: the move, advance, split and merge cases each say what was actually refused, and the merge names WHICH source LOT is tagged so an operator merging six knows which one to take to Quality.

> **Superseded by the corrected spec (2026-08-20).** `Assembly_CompleteTray` is **NOT** guarded — the operator never scans the consumed sub-assemblies, so there is no deliberate hand-off to refuse, and blocking would stop the line whenever CRT stock sat in the cell. It propagates instead. `MachiningOut_Mint` guards **only the scanned `@SourceLotId`**, never the FIFO tail, so a CRT casting drawn from behind taints the sub-assembly rather than being laundered. `Lot_Split` and `Lot_Merge` **do** block. See `docs/superpowers/specs/2026-08-19-crt-part-scoped-design.md` section 6, "Where blocking and propagation meet".

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0063_Crt_PartScoped/060_enforcement.sql` asserting, for a CRT LOT:

```sql
EXEC test.BeginTestFile @FileName = N'0063_Crt_PartScoped/060_enforcement.sql';
GO
-- Run-Tests.ps1 resets with -SkipDemoSeed, so Lots.Lot starts EMPTY and is then
-- filled by whatever earlier test files happened to create. Never grab an
-- arbitrary existing LOT: its status, hold state and location are another
-- test's business, and a guard test that passes because the LOT was already
-- closed proves nothing. INSERT your own, as 020_crt_for_mint.sql does:
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, CrtActive)
VALUES (N'TEST-CRT-<UNIQUE>', @Item, 1 /*Manufactured*/, 1 /*Good*/, 10, @StartLoc, @App, 1);
DECLARE @LotCrt BIGINT = SCOPE_IDENTITY();

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, CrtActive)
VALUES (N'TEST-OK-<UNIQUE>', @Item, 1 /*Manufactured*/, 1 /*Good*/, 10, @StartLoc, @App, 0);
DECLARE @LotOk BIGINT = SCOPE_IDENTITY();
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @LotCrt;
UPDATE Lots.Lot SET CrtActive = 0 WHERE Id = @LotOk;

DECLARE @ProdLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.IsProductionDestination = 1 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @SafeLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.IsProductionDestination = 0
      AND d.Code IN (N'InventoryLocation', N'InspectionStation', N'Receiving')
      AND l.DeprecatedAt IS NULL ORDER BY l.Id);

CREATE TABLE #m (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @status BIT, @message NVARCHAR(500), @movementCount INT;
DECLARE @before INT = (SELECT COUNT(*) FROM Lots.LotMovement WHERE LotId = @LotCrt);

-- Lot_MoveTo to a PRODUCTION destination is rejected and writes nothing.
INSERT INTO #m EXEC Lots.Lot_MoveTo @LotId = @LotCrt, @ToLocationId = @ProdLoc, @AppUserId = 1;
SELECT TOP 1 @status = Status, @message = Message FROM #m;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] MoveTo production rejected', @Expected = N'0', @Actual = @status;
EXEC test.Assert_Contains @TestName = N'[Enforce] rejection names CRT', @Expected = N'CRT', @Actual = @message;
SET @movementCount = (SELECT COUNT(*) FROM Lots.LotMovement WHERE LotId = @LotCrt) - @before;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] MoveTo production wrote no LotMovement row', @Expected = N'0', @Actual = @movementCount;

-- Lot_MoveTo to inspection/inventory SUCCEEDS (D5).
DELETE FROM #m;
INSERT INTO #m EXEC Lots.Lot_MoveTo @LotId = @LotCrt, @ToLocationId = @SafeLoc, @AppUserId = 1;
SELECT TOP 1 @status = Status FROM #m;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] MoveTo quarantine allowed', @Expected = N'1', @Actual = @status;

-- A CLEAN lot moves to production freely.
DELETE FROM #m;
INSERT INTO #m EXEC Lots.Lot_MoveTo @LotId = @LotOk, @ToLocationId = @ProdLoc, @AppUserId = 1;
SELECT TOP 1 @status = Status FROM #m;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] clean lot moves to production', @Expected = N'1', @Actual = @status;

DROP TABLE #m;
GO
EXEC test.EndTestFile;
GO
```

**`MachiningIn_RecordPick` is asserted separately** because it carries route,
eligibility and cell-context preconditions this fixture does not satisfy. Add its
assertion by mirroring the setup in the existing Machining suite (`sql/tests/0027_*`);
the assertion itself is:

```sql
EXEC test.Assert_IsEqual @TestName = N'[Enforce] MachiningIn_RecordPick rejects a CRT lot',
    @Expected = N'0', @Actual = @status;
```

**The Hold-precedence assertion** needs a LOT that is BOTH held and CRT. Place a hold
through the existing hold proc, then assert the message names the hold rather than CRT,
proving the pre-existing guard still fires first:

```sql
EXEC test.Assert_Contains @TestName = N'[Enforce] held+CRT lot is rejected for the HOLD, not CRT',
    @Expected = N'hold', @Actual = @message;
```

- [ ] **Step 2: Run it and watch it fail**

Expected: `[Enforce] MoveTo production rejected` fails with `Expected 0, Actual 1` — the move currently succeeds.

- [ ] **Step 3: Add each guard BEFORE `BEGIN TRANSACTION`**

**`Lots.Lot_MoveTo` returns a TWO-column status row — `(Status, Message)`, no `NewId`.**
Verified against the file: every existing rejection ends
`SELECT @Status AS Status, @Message AS Message;`. Emitting a third column from your
branch would give the proc two different result shapes and break every fixed-shape
`INSERT-EXEC` capture of it — which aborts the calling test file with Msg 213 rather
than failing an assertion.

**Placement matters too.** `@LotName` is not declared until **line ~118**, which is
after the last existing rejection (~line 114) but still before `BEGIN TRANSACTION`
(~line 136). Put the guard **between the `@LotName` declaration and `BEGIN
TRANSACTION`** — that keeps the Hold/Scrap/Closed rejections ahead of it (they keep
precedence) and still satisfies the before-transaction rule. Re-check those line
numbers before editing; they will have shifted.

```sql
    -- D5: a CRT LOT cannot move to a PRODUCTION destination. Moves to
    -- inspection, inventory, receiving or a support area still succeed, so
    -- suspect material can be taken to quarantine.
    IF (SELECT Blocked FROM Lots.ufn_CrtBlocksMoveTo(@LotId, @ToLocationId)) = 1
    BEGIN
        SET @Message = N'LOT ' + ISNULL(@LotName, N'?')
                     + N' is marked CRT and cannot be moved to a production location until Quality clears it.';
        SELECT @Status AS Status, @Message AS Message;
        RETURN;
    END
```

Repeat in `Lot_MoveToValidated` — **but confirm its result shape independently.** Match
whatever that proc's own existing rejections emit; do not assume it matches `Lot_MoveTo`.

In `MachiningIn_RecordPick`, `MachiningOut_Mint` (the scanned `@SourceLotId` only), `Lot_Split` (the parent) and `Lot_Merge` (any source), use the advance guard. **Not** in `Assembly_CompleteTray` -- see the note above:

```sql
    -- D4: a CRT LOT cannot be consumed or advanced.
    IF (SELECT Blocked FROM Lots.ufn_CrtBlocksAdvance(@LotId)) = 1
    BEGIN
        SET @Message = N'LOT ' + ISNULL(@LotName, N'?')
                     + N' is marked CRT and cannot be used until Quality clears it.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RETURN;
    END
```

**Before writing each guard, read that proc's existing rejection branches and copy
their `SELECT` column list verbatim.** The shapes differ across procs — `Lot_MoveTo`
emits `(Status, Message)` while others add `NewId` — and a branch that emits a
different shape from its siblings gives the proc two result shapes, which aborts any
fixed-shape `INSERT-EXEC` capture with Msg 213 instead of failing an assertion.

`@Status` is already initialised to `0` at the top of all three procs (verified), so do
not set it.

- [ ] **Step 4: Run the test and watch it pass**

Expected: 0063 fully green. **Then run the whole suite** — you have changed five widely-used procs:

```bash
cd sql/tests && ./Run-Tests.ps1 -DatabaseName "MPP_MES_Test_Crt"
```

Confirm the only `ERROR running` entries are the four pre-existing `0022_PlantFloor_DieCast` files.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_MoveTo.sql sql/migrations/repeatable/R__Lots_Lot_MoveToValidated.sql sql/migrations/repeatable/R__Workorder_MachiningIn_RecordPick.sql sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql sql/migrations/repeatable/R__Lots_Lot_Split.sql sql/migrations/repeatable/R__Lots_Lot_Merge.sql sql/tests/0063_Crt_PartScoped/060_enforcement.sql
git commit -m "feat(crt): block advance and production moves for a CRT lot

Every guard rejects BEFORE BEGIN TRANSACTION -- a ROLLBACK in a proc
invoked via INSERT-EXEC throws Msg 3915. The move block is
destination-aware (D5), so quarantine stays reachable, and the existing
Hold/Scrap/Closed rejections keep precedence."
```

---

### Task 6: The `{CrtMark}` label token

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_LotLabel_Print.sql`, `R__Lots_LotLabel_Reprint.sql`
- Test: `sql/tests/0063_Crt_PartScoped/070_label_mark.sql`

**Interfaces:**
- Consumes: `Lots.Lot.CrtActive`.
- Produces: `{CrtMark}` substituted in the rendered ZPL — `CRT` when active, empty string when not.

- [ ] **Step 1: Write the failing test**

```sql
EXEC test.BeginTestFile @FileName = N'0063_Crt_PartScoped/070_label_mark.sql';
GO
-- Run-Tests.ps1 resets with -SkipDemoSeed, so Lots.Lot starts EMPTY and is then
-- filled by whatever earlier test files happened to create. Never grab an
-- arbitrary existing LOT: its status, hold state and location are another
-- test's business, and a guard test that passes because the LOT was already
-- closed proves nothing. INSERT your own, as 020_crt_for_mint.sql does:
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, CrtActive)
VALUES (N'TEST-CRT-<UNIQUE>', @Item, 1 /*Manufactured*/, 1 /*Good*/, 10, @StartLoc, @App, 1);
DECLARE @LotCrt BIGINT = SCOPE_IDENTITY();

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, CrtActive)
VALUES (N'TEST-OK-<UNIQUE>', @Item, 1 /*Manufactured*/, 1 /*Good*/, 10, @StartLoc, @App, 0);
DECLARE @LotOk BIGINT = SCOPE_IDENTITY();
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @LotCrt;
UPDATE Lots.Lot SET CrtActive = 0 WHERE Id = @LotOk;

-- Lots.LotLabel_Print emits (Status, Message, NewId, ZplContent) -- verified against
-- the proc, whose header documents exactly that. The temp table MUST match it: a
-- wrong column list aborts this whole file with Msg 213, which surfaces as a runner
-- error rather than a FAIL. LotLabel_Print also takes @PrinterName; check whether it
-- is required before relying on the two-argument call below.
CREATE TABLE #z (Status BIT, Message NVARCHAR(500), NewId BIGINT, ZplContent NVARCHAR(MAX));
DECLARE @zplCrt NVARCHAR(MAX), @zplOk NVARCHAR(MAX);

INSERT INTO #z EXEC Lots.LotLabel_Print @LotId = @LotCrt, @AppUserId = 1;
SELECT TOP 1 @zplCrt = ZplContent FROM #z;
DELETE FROM #z;
INSERT INTO #z EXEC Lots.LotLabel_Print @LotId = @LotOk, @AppUserId = 1;
SELECT TOP 1 @zplOk = ZplContent FROM #z;

EXEC test.Assert_Contains @TestName = N'[Label] CRT lot renders the mark',
    @Expected = N'CRT', @Actual = @zplCrt;

DECLARE @tokenLeft INT =
    CASE WHEN CHARINDEX(N'{CrtMark}', ISNULL(@zplOk, N'')) > 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsEqual @TestName = N'[Label] clean lot leaves no unsubstituted token',
    @Expected = N'0', @Actual = @tokenLeft;

DECLARE @markInClean INT =
    CASE WHEN CHARINDEX(N'CRT', ISNULL(@zplOk, N'')) > 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsEqual @TestName = N'[Label] clean lot carries no CRT mark',
    @Expected = N'0', @Actual = @markInClean;

DROP TABLE #z;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it and watch it fail**

Expected: the clean-label assertion fails — the raw `{CrtMark}` token survives unsubstituted, or the CRT label has no mark.

- [ ] **Step 3: Add the substitution**

Wherever the print proc does its `REPLACE(@Zpl, N'{LotName}', …)` chain, add:

```sql
    SET @Zpl = REPLACE(@Zpl, N'{CrtMark}',
                       CASE WHEN @CrtActive = 1 THEN N'CRT' ELSE N'' END);
```

`@CrtActive` comes from the same `Lots.Lot` read the proc already does for `@LotName`. Add the token to the seeded `Lots.LabelTemplate` ZPL bodies in a positioned field near the LOT number — ASCII only.

- [ ] **Step 4: Run the test and watch it pass**

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_LotLabel_Print.sql sql/migrations/repeatable/R__Lots_LotLabel_Reprint.sql sql/tests/0063_Crt_PartScoped/070_label_mark.sql
git commit -m "feat(crt): {CrtMark} label token

One token in the existing templates rather than CRT template variants
(D8) -- no duplication, nothing to drift. A label printed before Quality
clears the LOT still says CRT; reprint for a clean ticket."
```

---

### Task 7: Python wrappers for the toggle

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py`
- Create: `ignition/projects/Core/ignition/named-query/lots/Lot_SetCrt/{query.sql,resource.json}`, `.../Lot_ClearCrt/{query.sql,resource.json}` (only if these named queries do not already exist — check first)

**Interfaces:**
- Consumes: `Lots.Lot_SetCrt(@LotId, @AppUserId, @TerminalLocationId)`, `Lots.Lot_ClearCrt(...)` — both already exist with that exact signature.
- Produces: `BlueRidge.Lots.Lot.setCrt(lotId, appUserId=None, terminalLocationId=None)` and `clearCrt(...)`, each returning `{Status, Message, NewId}`.

- [ ] **Step 1: Check what already exists**

```bash
ls ignition/projects/Core/ignition/named-query/lots/ | grep -i crt
grep -n "def setCrt\|def clearCrt" ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py
```

If the named queries exist, skip their creation and wire the wrappers to them.

- [ ] **Step 2: Add the wrappers**

Append to `BlueRidge/Lots/Lot/code.py`, matching the file's existing wrapper style (never `import BlueRidge.X` — call modules directly):

```python
def setCrt(lotId, appUserId=None, terminalLocationId=None):
    """Activate the Controlled Run Tag on a LOT. Elevation-gated at the UI
       (actionCode CrtToggle); this wrapper does not gate. Returns
       {Status, Message, NewId}."""
    return BlueRidge.Common.Db.execMutation("lots/Lot_SetCrt", {
        "lotId": _u(lotId),
        "appUserId": appUserId or BlueRidge.Common.Util._currentAppUserId(),
        "terminalLocationId": terminalLocationId,
    })


def clearCrt(lotId, appUserId=None, terminalLocationId=None):
    """Clear the Controlled Run Tag. Per design D3 this stops the LOT
       tainting FUTURE mints; LOTs already minted from it keep their own tag."""
    return BlueRidge.Common.Db.execMutation("lots/Lot_ClearCrt", {
        "lotId": _u(lotId),
        "appUserId": appUserId or BlueRidge.Common.Util._currentAppUserId(),
        "terminalLocationId": terminalLocationId,
    })
```

- [ ] **Step 3: Verify the module parses**

```bash
python -c "import ast,io;ast.parse(io.open('ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py',encoding='utf-8').read());print('ok')"
```

Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py ignition/projects/Core/ignition/named-query/lots/
git commit -m "feat(crt): setCrt / clearCrt Python wrappers"
```

---

### Task 8: Config Tool — the `CrtEnabled` checkbox

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Identity/view.json`
- Modify: the Item read/update procs and their named queries so `CrtEnabled` round-trips — find them with `grep -rln "Item_Update\|Item_Get" sql/migrations/repeatable/`

**Interfaces:**
- Consumes: `Parts.Item.CrtEnabled` (Task 1).
- Produces: an editable checkbox on Item Master → Identity.

- [ ] **Step 1: Add the column to the read and update procs**

`Parts.Item_Get` (or equivalent) gains `CrtEnabled` in its `SELECT`. **Append it LAST** so positional `INSERT-EXEC` captures in the test suite keep working. `Parts.Item_Update` gains a `@CrtEnabled BIT = 0` parameter and sets the column.

- [ ] **Step 2: Add the checkbox to the view**

Identity uses the per-section ownership pattern: the field binds bidirectionally to `view.custom.state.editDraft.identity.crtEnabled`. **Seed `crtEnabled` in the custom-block default shape** — an input bound to a nested path with no pre-populated key renders a validation border and literal `"null"` on first paint. `bidirectional: true` goes INSIDE the binding's `config`.

Label it **"Controlled Run Tag (CRT)"** with helper text *"Every LOT of this part minted while this is on is tagged CRT and cannot advance until Quality clears it."*

- [ ] **Step 3: Verify**

```bash
python -c "import json,io;raw=io.open('ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Identity/view.json','rb').read();json.loads(raw.decode('utf-8'));print('valid, BOM=%s'%(raw[:3]==b'\xef\xbb\xbf'))"
```

Then `./scan.ps1` and confirm the checkbox saves and reloads at `http://localhost:8088/data/perspective/client/MPP_Config/items`.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Identity/view.json sql/migrations/repeatable/
git commit -m "feat(crt): CrtEnabled checkbox on Item Master Identity"
```

---

### Task 9: Lot Detail — the CRT badge and the elevation-gated toggle

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/LotDetail/view.json`

**Interfaces:**
- Consumes: `BlueRidge.Lots.Lot.setCrt` / `clearCrt` (Task 7); `Lots.Lot_Get` already returns `CrtActive`.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Add the badge**

A label on the LOT header, `position.display` bound to `coalesce({view.custom.lot.CrtActive}, false)`, text `CRT`, styled with the existing warn/bad token classes used by the hold badge. Use `position.display`, not `meta.visible` — the latter still occupies flex space.

- [ ] **Step 2: Add the toggle button**

At the bottom of the view. `props.text` bound to an expression:

```
if(coalesce({view.custom.lot.CrtActive}, false), "Disable CRT", "Enable CRT")
```

`onActionPerformed` routes through the existing elevation pattern with a new `CrtToggle` action code — mirror `Views/ShopFloor/SortCageWorkflow`'s `doMigrate`, which does exactly this: validate first, then `BlueRidge.Common.Session.requireElevation`, with a page-scoped replay handler that re-enters the action once elevation is open.

The replayed handler body:

```python
	lot = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.lot) or {}
	lid = lot.get("Id")
	if not lid:
		return
	if lot.get("CrtActive"):
		res = BlueRidge.Lots.Lot.clearCrt(lid, self.session.custom.appUserId)
		BlueRidge.Common.Ui.notifyResult(res, "CRT cleared")
	else:
		res = BlueRidge.Lots.Lot.setCrt(lid, self.session.custom.appUserId)
		BlueRidge.Common.Ui.notifyResult(res, "CRT applied")
	if res and res.get("Status"):
		self.load()
```

Register `CrtToggle` in `Common/Session`'s `_ELEVATED_REPLAY_MESSAGES` map alongside the existing entries.

- [ ] **Step 3: Verify**

`./scan.ps1`, then load a LOT and confirm by **computed style** (not DOM presence — the accessibility tree lists text inside `display:none` subtrees) that the badge appears only for a CRT LOT and the button text flips. Note: with `_ELEVATION_USER_SOURCE = "Active Directory"` the gate will DENY on the dev gateway — see Global Constraints for the two workarounds.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/LotDetail/view.json ignition/projects/Core/ignition/script-python/BlueRidge/Common/Session/code.py
git commit -m "feat(crt): CRT badge and elevation-gated toggle on Lot Detail"
```

---

### Task 10: The creation popup and the blocking popup

**Files:**
- Modify: `ignition/projects/MPP/.../Views/ShopFloor/DieCastBody/view.json` (bulk open submit), `.../MachiningOutSplit/view.json`, `.../AssemblySerialized/view.json`, `.../AssemblyNonSerialized/view.json`
- Create: `ignition/projects/MPP/.../Components/Popups/CrtNotice/{view.json,resource.json}`

**Interfaces:**
- Consumes: the `{Status, Message, NewId}` rows the mint procs already return.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Build the notice popup**

One reusable view taking `params.title`, `params.body` and `params.lotNames` (a comma-joined string — repeater params serialise dates and lists unpredictably, so pass a prepared string). Single OK button. Plant-floor `pf-*` styling, 44px touch target. Needs BOTH `view.json` and `resource.json` or the gateway never sees it.

- [ ] **Step 2: Raise it after a mint**

In each minting screen's submit handler, after a successful result, collect the LOT names that came back CRT-active and — **only if there is at least one** — open the popup once:

```python
	crtNames = [r.get("lotName") for r in (results or []) if r.get("crtActive")]
	if crtNames:
		system.perspective.openPopup("mpp-crt-notice",
			"BlueRidge/Components/Popups/CrtNotice",
			params={"title": "Marked CRT",
			        "body": "%d of %d LOTs are marked CRT and cannot advance until Quality clears them."
			                % (len(crtNames), len(results or [])),
			        "lotNames": ", ".join(crtNames)},
			modal=True, showCloseIcon=False)
```

**One popup per submit, never per LOT** (D9) — bulk basket open mints one LOT per cavity, and per-LOT dialogs train operators to dismiss them reflexively.

- [ ] **Step 3: Raise it on a block**

At each blocking terminal, the proc's rejection `Message` already names the LOT and the reason. Surface it through the same popup rather than a toast so it cannot be missed:

```python
	if res and not res.get("Status") and "CRT" in (res.get("Message") or ""):
		system.perspective.openPopup("mpp-crt-notice",
			"BlueRidge/Components/Popups/CrtNotice",
			params={"title": "LOT is marked CRT", "body": res.get("Message"), "lotNames": ""},
			modal=True, showCloseIcon=False)
	else:
		BlueRidge.Common.Ui.notifyResult(res, "…")
```

- [ ] **Step 4: Verify**

`./scan.ps1`, then confirm both popups render. **The proc is authoritative** — verify the block still holds if the popup is bypassed, by calling the proc directly with a CRT LOT.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/
git commit -m "feat(crt): creation notice and blocking popup

One notice per SUBMIT listing the CRT LOTs minted (D9), not one per LOT.
The blocking popup surfaces the proc's own rejection message; the proc
remains authoritative if a screen forgets to check."
```

---

## Deployment note

`MPP_MES_Dev` runs behind the repo — it was four migrations and a batch of procs stale as recently as 2026-08-19. After Task 1, apply the new migration and redeploy the repeatables to Dev before expecting any of this to work in a session:

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -i sql/migrations/versioned/00NN_crt_part_scoped.sql
```

**The `-I` flag is required** — filtered indexes and several DDL forms need `QUOTED_IDENTIFIER ON`, and `sqlcmd` defaults it OFF. Without it you get `Msg 1934` and a half-applied migration.
