# Cutover Destination Picker — Design & Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Let the cutover operator choose where scanned stock is counted in — the line (default), the Warehouse, or either Trim Storage — instead of always depositing at the line.

**Architecture:** A per-row `IsCutoverDestination` flag marks valid destinations. A read proc returns the line first plus every flagged location, disambiguating colliding names in SQL. The Ignition layer gains a dropdown; `loadSession` already carries `destinationLocationId` / `destinationName`, so it only learns to accept an operator-chosen value instead of always deriving one.

**Tech Stack:** SQL Server 2022 (versioned + repeatable migrations, `test.Assert_*`), Ignition 8.3 Perspective (Jython 2.7, named queries, `view.json`).

**Design combined into this document** — decisions in § Decisions below, per the "hustle" instruction. There is no separate spec file.

## Global Constraints

- **Branch:** `jacques/working`. **Stage explicit paths only** — never `git add -u` / `-A`. The tree holds ~420 gateway-churn files plus another person's in-flight die-roster work.
- **Never stage** `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/CutoverScan/resource.json` — its manifest wrongly gained a gitignored `thumbnail.png`.
- Omit any `Co-Authored-By` trailer. Retry once on `index.lock`.
- **Tests target a throwaway DB.** Never `MPP_MES_Dev`, never `Reset-DevDatabase.ps1` against it.
- `sqlcmd` needs `-C`. After any Ignition file write, run `.\scan.ps1`.
- Read procs: no OUTPUT params, one result set (FDS-11-011). No magic integers — resolve by `Code`.
- `bidirectional: true` goes **inside** a binding's `config`, not beside it.
- `style.flexWrap` is **inert** on `ia.container.flex` — use `props.wrap`.

---

## Decisions

1. **The destination list is the line (default) + `WHSE` + `TRIM1-STORE` + `TRIM2-STORE`.** Not all seven `IsStockLocation = 1` rows — that would add Shipping IN/OUT and two inspection points nobody asked for.
2. **The flag lives on `Location`, not `LocationTypeDefinition`.** `0081` put `IsStockLocation` on the *type*; that cannot work here, because `WHSE` and `Shipping IN` are both `SupportArea`. The discriminator is the row, not the type.
3. **Latched per session**, in the setup form beside Line / Part / Machine, changed through the **Change** button.
4. **Shown in the latched header**, because depositing 2,000 pieces into the wrong store is an expensive silent error.
5. **`Lots.Lot_Create` is not touched.** It already takes `@CurrentLocationId`, and `0081` already skips the eligibility gate at stock locations. All three destinations are `IsStockLocation = 1`.
6. **Colliding names are qualified in SQL, not Python.** Both trim stores are named `Trim Storage`; a window function prefixes the parent only when a name repeats, so `Warehouse` stays clean.

---

## Task 1: Migration 0083 + the destination read proc

**Files:**
- Create: `sql/migrations/versioned/0083_location_is_cutover_destination.sql`
- Create: `sql/migrations/repeatable/R__Location_Location_ListCutoverDestinationsForLine.sql`
- Create: `sql/tests/0070_Cutover_EntryRoute/080_CutoverDestinations.sql`
- Create: `sql/seeds/033_seed_cutover_destinations.sql` — **required**, see note below

**Interfaces:**
- Produces: `Location.Location.IsCutoverDestination BIT NOT NULL DEFAULT 0`, and
  `Location.Location_ListCutoverDestinationsForLine @LineLocationId BIGINT = NULL` returning
  **`Id BIGINT, Code NVARCHAR(100), Name NVARCHAR(200), ParentName NVARCHAR(200), IsDefault BIT, DisplayName NVARCHAR(400)`**,
  line first then flagged destinations. Task 2 wraps it.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0070_Cutover_EntryRoute/080_CutoverDestinations.sql`:

```sql
-- =============================================
-- File:         0070_Cutover_EntryRoute/080_CutoverDestinations.sql
-- Description:  Where the cutover operator may count stock in.
--
--               The line itself is always offered and is the default (today's
--               behaviour, unchanged if the operator ignores the control).
--               Beyond it, only locations flagged IsCutoverDestination -- the
--               warehouse and the two trim stores -- NOT every
--               IsStockLocation row, which would also offer Shipping IN/OUT
--               and two inspection points.
--
--               The flag is per-ROW, not per-type: WHSE and Shipping IN are
--               both SupportArea, so the type cannot discriminate.
--
--               Both trim stores are named 'Trim Storage'. The proc qualifies
--               a colliding name with its parent and leaves a unique name
--               alone, so the operator never sees the same label twice.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/080_CutoverDestinations.sql';
GO

DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');

CREATE TABLE #D (Id BIGINT, Code NVARCHAR(100), Name NVARCHAR(200),
                 ParentName NVARCHAR(200), IsDefault BIT, DisplayName NVARCHAR(400));

INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = @Line;

-- (1) The line is offered, exactly once, and is the default.
DECLARE @a1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D WHERE Id = @Line);
EXEC test.Assert_IsEqual @TestName = N'[Dest] the line is offered exactly once',
    @Expected = N'1', @Actual = @a1;

DECLARE @a2 NVARCHAR(10) = (SELECT CAST(IsDefault AS NVARCHAR(10)) FROM #D WHERE Id = @Line);
EXEC test.Assert_IsEqual @TestName = N'[Dest] the line is the default',
    @Expected = N'1', @Actual = @a2;

-- (2) The line sorts first -- it is what the operator wants nine times in ten.
DECLARE @a3 NVARCHAR(20) = (SELECT TOP 1 CAST(Id AS NVARCHAR(20)) FROM #D);
DECLARE @a3e NVARCHAR(20) = CAST(@Line AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Dest] the line sorts first',
    @Expected = @a3e, @Actual = @a3;

-- (3) The three flagged destinations are offered.
DECLARE @a4 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D
                            WHERE Code IN (N'WHSE', N'TRIM1-STORE', N'TRIM2-STORE'));
EXEC test.Assert_IsEqual @TestName = N'[Dest] warehouse and both trim stores are offered',
    @Expected = N'3', @Actual = @a4;

-- (4) Shipping and inspection are NOT offered, though they are IsStockLocation.
DECLARE @a5 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D
                            WHERE Code IN (N'SHIPIN', N'SHIPOUT', N'INSP-SORT'));
EXEC test.Assert_IsEqual @TestName = N'[Dest] shipping and inspection are not offered',
    @Expected = N'0', @Actual = @a5;

-- (5) A colliding name is qualified by its parent.
DECLARE @a6 NVARCHAR(400) = (SELECT DisplayName FROM #D WHERE Code = N'TRIM1-STORE');
EXEC test.Assert_IsEqual @TestName = N'[Dest] colliding name is qualified by its parent',
    @Expected = N'Trim Shop 1 - Trim Storage', @Actual = @a6;

-- (6) A unique name is left alone -- no needless 'Madison Facility - Warehouse'.
DECLARE @a7 NVARCHAR(400) = (SELECT DisplayName FROM #D WHERE Code = N'WHSE');
EXEC test.Assert_IsEqual @TestName = N'[Dest] a unique name is not qualified',
    @Expected = N'Warehouse', @Actual = @a7;

-- (7) A deprecated destination drops out.
UPDATE Location.Location SET DeprecatedAt = SYSUTCDATETIME() WHERE Code = N'TRIM2-STORE';
DELETE FROM #D;
INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = @Line;
DECLARE @a8 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D WHERE Code = N'TRIM2-STORE');
EXEC test.Assert_IsEqual @TestName = N'[Dest] a deprecated destination drops out',
    @Expected = N'0', @Actual = @a8;
UPDATE Location.Location SET DeprecatedAt = NULL WHERE Code = N'TRIM2-STORE';

-- (8) With TRIM2 gone, TRIM1's name no longer collides -- and un-qualifies.
--     Guards the window function against being a static prefix.
UPDATE Location.Location SET DeprecatedAt = SYSUTCDATETIME() WHERE Code = N'TRIM2-STORE';
DELETE FROM #D;
INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = @Line;
DECLARE @a9 NVARCHAR(400) = (SELECT DisplayName FROM #D WHERE Code = N'TRIM1-STORE');
EXEC test.Assert_IsEqual @TestName = N'[Dest] name qualification is dynamic, not a fixed prefix',
    @Expected = N'Trim Storage', @Actual = @a9;
UPDATE Location.Location SET DeprecatedAt = NULL WHERE Code = N'TRIM2-STORE';

-- (9) A NULL line still lists the destinations, with no line row.
DELETE FROM #D;
INSERT INTO #D EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = NULL;
DECLARE @a10 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D);
EXEC test.Assert_IsEqual @TestName = N'[Dest] NULL line lists the three destinations only',
    @Expected = N'3', @Actual = @a10;

DROP TABLE #D;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it, confirm it fails**

```bash
cd sql/tests && powershell -NoProfile -File Run-Tests.ps1 -Filter "0070" -DatabaseName <assigned DB>
```

Expect `Could not find stored procedure 'Location.Location_ListCutoverDestinationsForLine'`, exit 1.

- [ ] **Step 3: Write migration 0083**

Create `sql/migrations/versioned/0083_location_is_cutover_destination.sql`:

```sql
-- ============================================================
-- Migration:   0083_location_is_cutover_destination.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-14
-- Description: Location.Location.IsCutoverDestination -- "may the inventory
--              cutover scan count stock IN here?"
--
--              WHY A NEW FLAG. 0081 added IsStockLocation ("can physical stock
--              rest here?") and that is a DIFFERENT question. Seven locations
--              answer yes to it, including Shipping IN, Shipping OUT and two
--              inspection points. The cutover screen offers three: the
--              warehouse and the two trim stores.
--
--              WHY ON Location, NOT LocationTypeDefinition. 0081's flag is
--              per-TYPE, and that cannot work here: WHSE and SHIPIN are both
--              SupportArea, so the type does not discriminate. The answer is a
--              property of the individual location. Do not "tidy" this onto the
--              definition table -- it would re-admit shipping.
--
--              The line the operator selected is ALWAYS offered and is the
--              default; it is not flagged here, it is unioned in by
--              Location_ListCutoverDestinationsForLine.
-- ============================================================

-- ---- 1. The column ----
IF COL_LENGTH('Location.Location', 'IsCutoverDestination') IS NULL
    ALTER TABLE Location.Location
        ADD IsCutoverDestination BIT NOT NULL
            CONSTRAINT DF_Location_IsCutoverDestination DEFAULT 0;
GO

-- ---- 2. Which locations they are. Idempotent: re-running re-asserts the set. ----
UPDATE Location.Location
   SET IsCutoverDestination = 1
 WHERE Code IN (N'WHSE', N'TRIM1-STORE', N'TRIM2-STORE')
   AND IsCutoverDestination <> 1;

UPDATE Location.Location
   SET IsCutoverDestination = 0
 WHERE Code NOT IN (N'WHSE', N'TRIM1-STORE', N'TRIM2-STORE')
   AND IsCutoverDestination <> 0;
GO

-- ---- 3. Report, so a bad seed is visible at deploy ----
DECLARE @Dests NVARCHAR(500) = (
    SELECT STUFF((SELECT N', ' + Code FROM Location.Location
                  WHERE IsCutoverDestination = 1 AND DeprecatedAt IS NULL
                  ORDER BY Code FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''));
PRINT 'Cutover destinations: ' + ISNULL(@Dests, N'(none)');
GO

-- ---- 4. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0083_location_is_cutover_destination')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0083_location_is_cutover_destination',
            N'Location.Location.IsCutoverDestination (BIT, default 0), set for WHSE / TRIM1-STORE / TRIM2-STORE. Per-ROW, not per-type: WHSE and SHIPIN are both SupportArea. Drives the cutover scan destination picker; the selected line is always offered as the default and is not flagged.');
GO
PRINT 'Migration 0083 (location_is_cutover_destination) applied.';
GO
```

- [ ] **Step 4: Write the proc**

Create `sql/migrations/repeatable/R__Location_Location_ListCutoverDestinationsForLine.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Location_Location_ListCutoverDestinationsForLine.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-14
-- Version:     1.0
-- Description: Where the inventory cutover scan may count stock in.
--
--              The selected LINE is always offered, sorts first, and is flagged
--              IsDefault -- depositing at the line is today's behaviour and
--              stays the default if the operator ignores the control. Beyond
--              it, the locations flagged Location.IsCutoverDestination (0083):
--              the warehouse and the two trim stores.
--
--              NOT every IsStockLocation row. That flag answers "can stock rest
--              here", which is also true of Shipping IN/OUT and two inspection
--              points -- four destinations nobody asked to offer.
--
--              DISPLAYNAME. Both trim stores are named 'Trim Storage'. The
--              window function qualifies a name with its parent ONLY when that
--              name repeats in the result, so the operator never sees the same
--              label twice and 'Warehouse' is not padded to
--              'Madison Facility - Warehouse'. It is dynamic: deprecate one
--              trim store and the other un-qualifies.
--
--              Read proc: no @Status/@Message, no OUTPUT params, one result
--              set; empty means nothing is configured (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Location_ListCutoverDestinationsForLine
    @LineLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH cand AS (
        -- The line itself: always offered, always first, always the default.
        SELECT l.Id, l.Code, l.Name, p.Name AS ParentName,
               CAST(1 AS BIT) AS IsDefault, 0 AS SortRank
        FROM Location.Location l
        LEFT JOIN Location.Location p ON p.Id = l.ParentLocationId
        WHERE l.Id = @LineLocationId
          AND l.DeprecatedAt IS NULL

        UNION ALL

        -- The configured destinations. Excludes the line so it cannot appear
        -- twice if someone also flags it.
        SELECT l.Id, l.Code, l.Name, p.Name AS ParentName,
               CAST(0 AS BIT) AS IsDefault, 1 AS SortRank
        FROM Location.Location l
        LEFT JOIN Location.Location p ON p.Id = l.ParentLocationId
        WHERE l.IsCutoverDestination = 1
          AND l.DeprecatedAt IS NULL
          AND l.Id <> ISNULL(@LineLocationId, -1)
    )
    SELECT
        Id,
        Code,
        Name,
        ParentName,
        IsDefault,
        CASE WHEN COUNT(*) OVER (PARTITION BY Name) > 1
             THEN ISNULL(ParentName + N' - ', N'') + Name
             ELSE Name END AS DisplayName
    FROM cand
    ORDER BY SortRank, Name, Code;
END;
GO
```

- [ ] **Step 5: Run the tests, confirm they pass**

```bash
cd sql/tests && powershell -NoProfile -File Run-Tests.ps1 -Filter "0070" -DatabaseName <assigned DB>
```

All nine `[Dest]` assertions pass; the rest of `0070` still passes.

- [ ] **Step 6: Full suite**

```bash
cd sql/tests && powershell -NoProfile -File Run-Tests.ps1 -DatabaseName <assigned DB>
```

Expect 3523 + 10 = **3533 passed, 0 failed, exit 0**. A new `NOT NULL DEFAULT 0` column on `Location.Location` touches a widely-joined table; the full suite is the check that nothing selected `*` and broke.

> **The migration alone is not enough on a fresh database.** `Reset-DevDatabase.ps1`
> runs versioned migrations at step `[4/6]` and seeds at `[6/7]`, and `WHSE` /
> `TRIM1-STORE` / `TRIM2-STORE` are created by `sql/seeds/011_seed_locations_mpp_plant.sql`
> — a **seed**. So `0083`'s `UPDATE` matches zero rows on a rebuilt database. (`0081`
> escaped this only because its flag sits on `LocationTypeDefinition`, which migration
> `0002` seeds inline.) A companion `sql/seeds/033_seed_cutover_destinations.sql` carries
> the same idempotent `UPDATE` pair: the seed is the source of truth for new databases,
> the migration is the patch for already-seeded ones — the same split
> `0071_insp_sort_terminal_default_screen.sql` documents. Both files must say why the
> duplication exists so neither is "tidied" away.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/versioned/0083_location_is_cutover_destination.sql sql/migrations/repeatable/R__Location_Location_ListCutoverDestinationsForLine.sql sql/tests/0070_Cutover_EntryRoute/080_CutoverDestinations.sql
git commit -m "feat(sql): 0083 IsCutoverDestination -- where cutover may count stock in"
```

---

## Task 2: Named query, wrapper, and `loadSession`

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/location/CutoverDestination_ListForLine/query.sql` + `resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Cutover/Scan/code.py`

**Interfaces:**
- Consumes: Task 1's proc.
- Produces: `BlueRidge.Location.Location.getCutoverDestinationDropdown(lineLocationId, _refreshToken=None)` → `[{"label": <DisplayName>, "value": <LocationId>}]`, line first.
  `BlueRidge.Cutover.Scan.loadSession(lineLocationId, itemId, entryRoleCode, machineLocationId, destinationLocationId, session)` — **`destinationLocationId` is a new SIXTH positional argument, before `session`.** Task 3 passes it.

- [ ] **Step 1: The named query**

`.../location/CutoverDestination_ListForLine/query.sql`:

```sql
EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId = :lineLocationId
```

`resource.json` — copy `location/DieCastMachine_ListForItem/resource.json` verbatim and change only the parameter `identifier` to `lineLocationId`. Keep `"type": "Query"`, `"sqlType": 3`, `"database": "MPP"`, scope `DG`.

- [ ] **Step 2: The wrapper**

Append to `BlueRidge/Location/Location/code.py`, after `getDieCastMachineDropdown`:

```python
def getCutoverDestinationDropdown(lineLocationId, _refreshToken=None):
    """Where the cutover operator may count stock in, shaped for
       ia.input.dropdown: [{label: 'Warehouse', value: <LocationId>}].
       The selected line comes back FIRST and is the default. Always a list.

       DisplayName is computed by the proc, which qualifies a name with its
       parent only when it collides -- both trim stores are called 'Trim
       Storage'. Do not re-derive the label here."""
    lineLocationId = _u(lineLocationId)
    try:
        rows = BlueRidge.Common.Db.execList(
            "location/CutoverDestination_ListForLine",
            {"lineLocationId": lineLocationId}) or []
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("getCutoverDestinationDropdown failed: %s" % str(e),
                                  level="warn")
        return []
    return [{"label": r.get("DisplayName") or r.get("Name") or r.get("Code") or "",
             "value": r.get("Id")} for r in rows]
```

Bump the module `# Version:` and add a change-log line.

- [ ] **Step 3: `loadSession` accepts the choice**

In `BlueRidge/Cutover/Scan/code.py`, change the signature to add `destinationLocationId` **before** `session`:

```python
def loadSession(lineLocationId, itemId, entryRoleCode, machineLocationId,
                destinationLocationId, session):
```

Unwrap it beside the others:

```python
    destinationLocationId = _u(destinationLocationId)
```

The existing `dest = BlueRidge.Location.Location.getStockDestinationOrEmpty(lineLocationId)`
line stays as the fallback. Immediately after it, insert:

```python
    # The operator's pick wins; the per-line default is the fallback. Resolved
    # against the SAME list the dropdown offered, so the label cannot drift and
    # a line change cannot leave a stale destination selected.
    destId = dest.get("DestinationLocationId")
    destName = dest.get("DestinationName") or ""
    if destinationLocationId is not None:
        for opt in BlueRidge.Location.Location.getCutoverDestinationDropdown(lineLocationId):
            if opt.get("value") == destinationLocationId:
                destId, destName = destinationLocationId, opt.get("label") or ""
                break
```

Then in the `st["session"] = {...}` dict, replace the two destination entries with:

```python
        "destinationLocationId": destId,
        "destinationName": destName,
```

Bump the module `# Version:` and add a change-log line.

- [ ] **Step 4: Scan and verify**

```bash
powershell -NoProfile -File scan.ps1
sqlcmd -S localhost -d MPP_MES_Dev -E -C -i sql/migrations/versioned/0083_location_is_cutover_destination.sql
sqlcmd -S localhost -d MPP_MES_Dev -E -C -i sql/migrations/repeatable/R__Location_Location_ListCutoverDestinationsForLine.sql
sqlcmd -S localhost -d MPP_MES_Dev -E -C -W -s"|" -Q "SET NOCOUNT ON; DECLARE @L BIGINT=(SELECT Id FROM Location.Location WHERE Code='MA1-5GOF'); EXEC Location.Location_ListCutoverDestinationsForLine @LineLocationId=@L;"
```

Expect four rows: the line first with `IsDefault = 1`, then `Trim Shop 1 - Trim Storage`, `Trim Shop 2 - Trim Storage`, `Warehouse`.

Applying the migration and proc to `MPP_MES_Dev` is required — the gateway reads that database, and Task 3's views will call this proc. **Apply those two files only. Never reset `MPP_MES_Dev`.**

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/location/CutoverDestination_ListForLine ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Cutover/Scan/code.py
git commit -m "feat(cutover): operator-chosen stock destination through to loadSession"
```

---

## Task 3: The dropdown and the header cell

**Files:**
- Modify: `.../views/BlueRidge/Views/ShopFloor/_CutoverScan/{Desktop,Tablet,Phone}/view.json`

**Interfaces:**
- Consumes: Task 2's wrapper and `loadSession`'s sixth argument.

**These are existing views.** File-edit them with a byte-safe Python script doing exact string replacement; the Phone view writes `=` as `=` inside script strings, so anchor on escape-free text. Verify each file re-parses as JSON. Designer must be reloaded afterwards.

- [ ] **Step 1: `setupDraft` gains the key**

In each view's `custom.setupDraft` default (near line 9), add beside `machineLocationId`:

```json
      "destinationLocationId": null
```

A bound custom property with no default renders a Component Error.

- [ ] **Step 2: The dropdown**

Insert a new field container immediately after the `MachineField` container in each view, matching `MachineField`'s shape exactly — a `pf-field` flex column holding a `pf-field-label` label and the input:

```json
{
  "type": "ia.container.flex",
  "meta": { "name": "DestinationField" },
  "props": {
    "direction": "column",
    "style": { "gap": "6px", "classes": "pf-field" }
  },
  "children": [
    {
      "type": "ia.display.label",
      "meta": { "name": "DestinationFieldLabel" },
      "props": { "style": { "classes": "pf-field-label" }, "text": "Destination" }
    },
    {
      "type": "ia.input.dropdown",
      "meta": { "name": "DestinationDropdown" },
      "props": {
        "placeholder": "Pick where stock is counted in",
        "style": { "minHeight": "44px" }
      },
      "propConfig": {
        "props.options": {
          "binding": {
            "type": "expr",
            "config": {
              "expression": "runScript(\"BlueRidge.Location.Location.getCutoverDestinationDropdown\", 0, {view.custom.setupDraft.lineLocationId})"
            }
          }
        },
        "props.value": {
          "binding": {
            "type": "property",
            "config": {
              "path": "view.custom.setupDraft.destinationLocationId",
              "bidirectional": true
            }
          }
        }
      }
    }
  ],
  "position": { "shrink": 0 }
}
```

It cascades off `lineLocationId`, not `itemId` — destinations depend on the line, not the part.

- [ ] **Step 3: The header cell**

Insert a new KV cell into `LatchedKvRow` in each view, immediately after the `MachineKv` cell, copying `MachineKv`'s exact shape — a `flex` column, `position.shrink: 0`, a `pf-kpi-label` label reading `DESTINATION`, and a value label:

```json
{
  "type": "ia.display.label",
  "meta": { "name": "DestinationValue" },
  "props": { "style": { "classes": "pf-kpi-value-mono" } },
  "propConfig": {
    "props.text": {
      "binding": {
        "type": "property",
        "config": { "path": "session.custom.cutover.session.destinationName" }
      }
    }
  }
}
```

`LatchedKvRow` now carries `props.wrap: "wrap"` on Desktop and Tablet, so a sixth cell wraps rather than clipping. Phone's row has no `direction` prop and stacks vertically — nothing to do there.

- [ ] **Step 4: The two setup scripts**

The **Start / Apply** script must pass the new sixth argument:

```
BlueRidge.Cutover.Scan.loadSession(d.get("lineLocationId"), d.get("itemId"), d.get("entryRoleCode"), d.get("machineLocationId"), d.get("destinationLocationId"), self.session)
```

The **Change** script must reseed it:

```
"destinationLocationId": s.get("destinationLocationId")
```

- [ ] **Step 5: Scan and verify**

```bash
powershell -NoProfile -File scan.ps1
```

Then confirm all three parse:

```bash
for f in Desktop Tablet Phone; do python -c "import json,io; json.load(io.open('ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/_CutoverScan/$f/view.json', encoding='utf-8')); print('$f OK')"; done
```

Check the diff is small — large diffs mean Designer pickled runtime data:

```bash
git diff --stat ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/_CutoverScan/
```

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/_CutoverScan
git commit -m "feat(cutover): operator picks the stock destination; shown in the header"
```

---

## Verification (main session, live)

A Perspective session, on the 6MA Cam Holder line:

1. Destination defaults to the line; the dropdown offers the line, both trim stores (parent-qualified) and the Warehouse.
2. Pick **Warehouse**, start the session — the header's DESTINATION cell reads `Warehouse`.
3. Scan a basket, then confirm it landed at the warehouse, not the line:

```sql
SELECT TOP 1 l.Id, l.LotName, loc.Code, loc.Name
FROM Lots.Lot l JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
ORDER BY l.Id DESC;
```

4. Press **Change** — the destination is still selected.
