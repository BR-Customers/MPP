# OEE-Enabled Locations and Availability Roll-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make any location an opt-in downtime/OEE unit via a flag, so one production line can be split into per-station units (6MA: Machining, Assembly A, Assembly B), and roll station availability up to the line as a plain mean.

**Architecture:** A new `Location.Location.IsOeeEnabled` column replaces the hard-coded "self-scoping" equipment rule in `Oee.ufn_ResolveDowntimeScope` / `Oee.ufn_ResolveOeeEquipment`. A migration backfills the flag from the current rule so day one is a no-op. `Oee.DowntimeScope_ListForTerminal` lists flagged locations in the terminal's zone subtree. `Oee.Shift_GetAvailability` is rewritten: leaves merge their own downtime with every flagged ancestor's downtime by time union, planned downtime shrinks the base, and a location with flagged children reports the mean of those children.

**Tech Stack:** SQL Server 2022 (T-SQL migrations + repeatable procs/functions), sqlcmd test harness, Ignition 8.3 Perspective (Jython script modules, Named Queries, Designer-edited views).

**Spec:** `docs/superpowers/specs/2026-09-16-oee-enabled-locations-and-rollup-design.md`

## Global Constraints

- **No `OUTPUT` parameters** (FDS-11-011). Read procs: one result set, empty = not found. Mutation procs: local `@Status` / `@Message` / `@NewId`, every exit path ends `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;`.
- **`RAISERROR` (not `THROW`)** in CATCH blocks, with a nested TRY/CATCH around the failure log.
- **`EXEC` parameters must be literals or `@variables`** — never inline `CAST` / arithmetic / `CASE`.
- **Schema-qualify every DB reference.** `UpperCamelCase` tables and columns. `NVARCHAR` never `VARCHAR`. `DATETIME2(3)`. `DECIMAL` never `FLOAT`.
- **ASCII-only** in all SQL string literals (seed values, messages, PRINT text). `sqlcmd` reads files in the Windows codepage, so an em-dash becomes mojibake.
- **Timestamps stored UTC, displayed Eastern.** `Oee.DowntimeEvent.StartedAt` is UTC; `Oee.Shift.ActualStart`, `Oee.ShiftSchedule.StartTime` and `Oee.ShiftOverride.StartTime` are LOCAL Eastern wall clock (OI-38). Convert at the comparison boundary with `AT TIME ZONE`.
- **No business logic in Python.** Rules (which locations may be flagged, what rolls up) live in SQL.
- **Repeatable functions get no deferred name resolution** (Msg 4121) and deploy in filename order, so a function must sort before any function that calls it. `R__Oee_ufn_OeeAncestors.sql` < `R__Oee_ufn_ResolveDowntimeScope.sql` (O < R) — this ordering is required, do not rename.
- **Existing Perspective views are edited in Designer, never as files.** New Named Queries and Python script modules are file edits followed by `.\scan.ps1`.
- **Commit to `jacques/working`.** Stage explicit paths; never `git add -u` / `-A`. No `Co-Authored-By: Claude` trailer.
- **Test command:** `cd sql\tests; .\Run-Tests.ps1` (resets and runs against the throwaway `MPP_MES_Test`; never point it at `MPP_MES_Dev`). Filter with `-Filter "<substring>"`.

---

## File Structure

**New files**

| Path | Responsibility |
|---|---|
| `sql/migrations/versioned/0090_location_is_oee_enabled.sql` | The column + one-time rule backfill |
| `sql/seeds/034_seed_oee_enabled_backfill.sql` | Same rule for fresh builds (seeds run after migrations) |
| `sql/migrations/repeatable/R__Oee_ufn_OeeAncestors.sql` | Flagged strict ancestors of a location |
| `sql/migrations/repeatable/R__Location_ufn_CanBeOeeEnabled.sql` | May this location *type* be flagged? |
| `sql/migrations/repeatable/R__Location_LocationTypeDefinition_GetOeeEligibility.sql` | Read proc wrapping the above, for the Config Tool |
| `ignition/projects/Core/ignition/named-query/location/LocationTypeDefinition_GetOeeEligibility/{query.sql,resource.json}` | NQ for the eligibility read |
| `sql/tests/helpers/0090_fixture_oee_locations.sql` | `test.OeeFixture_Build` / `test.OeeFixture_Teardown` |
| `sql/tests/0090_Oee_EnabledLocations/010_flag_backfill.sql` | Backfill correctness |
| `sql/tests/0090_Oee_EnabledLocations/020_resolution.sql` | The two functions + equipment set |
| `sql/tests/0090_Oee_EnabledLocations/030_rollup_availability.sql` | Roll-up maths |
| `sql/tests/0090_Oee_EnabledLocations/050_rollup_edge_cases.sql` | Zero-base child, nested roll-ups |
| `sql/tests/0090_Oee_EnabledLocations/040_write_validation.sql` | Downtime writers reject unflagged |
| `sql/tests/0003_Location/070_Location_IsOeeEnabled.sql` | Flag write path + guard |

**Modified files**

| Path | Change |
|---|---|
| `sql/migrations/repeatable/R__Oee_ufn_ResolveDowntimeScope.sql` | Nearest flagged ancestor-or-self |
| `sql/migrations/repeatable/R__Oee_ufn_ResolveOeeEquipment.sql` | Flagged filter |
| `sql/migrations/repeatable/R__Oee_DowntimeScope_ListForTerminal.sql` | Flagged subtree + new default rule |
| `sql/migrations/repeatable/R__Oee_DowntimeEvent_{Start,RecordHistorical,RecordApproximate}.sql` | Reject unflagged location |
| `sql/migrations/repeatable/R__Oee_Shift_GetAvailability.sql` | Rewrite (union merge, base shrink, roll-up) |
| `sql/migrations/repeatable/R__Location_Location_{Get,SaveAll}.sql` | Carry the flag |
| `ignition/projects/Core/ignition/named-query/location/Location_SaveAll/{query.sql,resource.json}` | `isOeeEnabled` parameter |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py` | Flag in `getOne` / `emptyMeta` / `metaFromLocation` / `handleSaveAll`; new `canBeOeeEnabled` |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/ShiftOverride/code.py` | New keys in `_EMPTY_AVAILABILITY` |
| `MPP_MES_DATA_MODEL.md` + `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql` | Document the column |
| `sql/tests/0026_PlantFloor_Downtime_Shift/*.sql`, `sql/tests/0059_Oee_ShiftOverride/030_availability.sql` | Fixtures pick flagged locations; new result columns |
| Designer: `MPP_Config` → `BlueRidge/Views/Location/PlantHierarchy` | The checkbox |

---

## Task 1: The flag column and its backfill

**Files:**
- Create: `sql/migrations/versioned/0090_location_is_oee_enabled.sql`
- Create: `sql/seeds/034_seed_oee_enabled_backfill.sql`
- Create: `sql/tests/0090_Oee_EnabledLocations/010_flag_backfill.sql`
- Modify: `MPP_MES_DATA_MODEL.md` (Location table, line ~235)

**Interfaces:**
- Consumes: nothing.
- Produces: `Location.Location.IsOeeEnabled BIT NOT NULL DEFAULT 0`, flagged for exactly the set the pre-change `Oee.ufn_ResolveOeeEquipment()` returned.

**Why the rule is inlined rather than calling the function:** `Reset-DevDatabase` runs versioned migrations *before* repeatables, so on a fresh database `Oee.ufn_ResolveOeeEquipment` does not exist yet when 0090 runs. The migration therefore carries its own copy of the rule. On a fresh database the backfill also matches zero rows (locations are seeded later), which is why the seed in step 3 repeats it.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0090_Oee_EnabledLocations/010_flag_backfill.sql`:

```sql
-- =============================================
-- File:         0090_Oee_EnabledLocations/010_flag_backfill.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Location.Location.IsOeeEnabled exists, defaults to 0, and the
--               0090 backfill (repeated by seed 034 on a fresh build) flagged
--               exactly the set the pre-change equipment rule returned:
--               active, Cell/WorkCenter tier, not a device or store, and no
--               WorkCenter ancestor above it.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0090_Oee_EnabledLocations/010_flag_backfill.sql';
GO

-- =============================================
-- Test 1: the column exists and the migration is recorded.
-- =============================================
DECLARE @col NVARCHAR(10) = CASE WHEN COL_LENGTH(N'Location.Location', N'IsOeeEnabled') IS NULL
                                 THEN N'missing' ELSE N'present' END;
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] Location.IsOeeEnabled column exists',
     @Expected = N'present', @Actual = @col;

DECLARE @mig NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM dbo.SchemaVersion
                                              WHERE MigrationId = N'0090_location_is_oee_enabled')
                                 THEN N'yes' ELSE N'no' END;
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] migration 0090 recorded in SchemaVersion',
     @Expected = N'yes', @Actual = @mig;
GO

-- =============================================
-- Test 2: the flagged set equals the pre-change rule, computed independently
-- here (nearest-WorkCenter-ancestor walk, device/store exclusions).
-- =============================================
;WITH Tree AS (
    SELECT l.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN l.Id END AS BIGINT) AS NearestWorkCenterId
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE l.ParentLocationId IS NULL
    UNION ALL
    SELECT c.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN c.Id ELSE t.NearestWorkCenterId END AS BIGINT)
    FROM Location.Location c
    INNER JOIN Tree t                              ON c.ParentLocationId = t.Id
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = c.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
)
SELECT l.Id
INTO #Expected
FROM Location.Location l
INNER JOIN Tree t                              ON t.Id   = l.Id
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
WHERE l.DeprecatedAt IS NULL
  AND lt.Code IN (N'WorkCenter', N'Cell')
  AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Receiving', N'Scale')
  AND COALESCE(t.NearestWorkCenterId, l.Id) = l.Id
OPTION (MAXRECURSION 20);

DECLARE @missing INT = (SELECT COUNT(*) FROM #Expected e
                        WHERE NOT EXISTS (SELECT 1 FROM Location.Location l
                                          WHERE l.Id = e.Id AND l.IsOeeEnabled = 1));
DECLARE @extra INT = (SELECT COUNT(*) FROM Location.Location l
                      WHERE l.IsOeeEnabled = 1
                        AND NOT EXISTS (SELECT 1 FROM #Expected e WHERE e.Id = l.Id));
DECLARE @missingTxt NVARCHAR(10) = CAST(@missing AS NVARCHAR(10));
DECLARE @extraTxt   NVARCHAR(10) = CAST(@extra AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] every location the old rule admitted is flagged',
     @Expected = N'0', @Actual = @missingTxt;
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] nothing outside the old rule is flagged',
     @Expected = N'0', @Actual = @extraTxt;

DECLARE @anyFlagged INT = (SELECT COUNT(*) FROM Location.Location WHERE IsOeeEnabled = 1);
DECLARE @anyTxt NVARCHAR(10) = CASE WHEN @anyFlagged > 0 THEN N'yes' ELSE N'no' END;
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] the backfill flagged something (seed 034 ran)',
     @Expected = N'yes', @Actual = @anyTxt;
DROP TABLE #Expected;
GO

-- =============================================
-- Test 3: devices, stores, hierarchy tiers and deprecated rows are never flagged.
-- =============================================
DECLARE @badDef INT = (SELECT COUNT(*) FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    WHERE l.IsOeeEnabled = 1
      AND ltd.Code IN (N'Terminal', N'Printer', N'InventoryLocation', N'Scale', N'Receiving'));
DECLARE @badDefTxt NVARCHAR(10) = CAST(@badDef AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] no terminal / printer / store / scale is flagged',
     @Expected = N'0', @Actual = @badDefTxt;

DECLARE @badTier INT = (SELECT COUNT(*) FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE l.IsOeeEnabled = 1 AND lt.Code NOT IN (N'WorkCenter', N'Cell'));
DECLARE @badTierTxt NVARCHAR(10) = CAST(@badTier AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] no Enterprise / Site / Area row is flagged',
     @Expected = N'0', @Actual = @badTierTxt;

DECLARE @badDep INT = (SELECT COUNT(*) FROM Location.Location WHERE IsOeeEnabled = 1 AND DeprecatedAt IS NOT NULL);
DECLARE @badDepTxt NVARCHAR(10) = CAST(@badDep AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] no deprecated location is flagged',
     @Expected = N'0', @Actual = @badDepTxt;
GO

-- =============================================
-- Test 4: a new location defaults to unflagged.
-- =============================================
DECLARE @Site BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE lt.Code = N'Site' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @AreaDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionArea');
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (@AreaDef, @Site, N'OEE Default Probe', N'ZZ-OEEDFLT', N'010_flag_backfill fixture', 998);
DECLARE @dflt NVARCHAR(10) = (SELECT CAST(IsOeeEnabled AS NVARCHAR(10)) FROM Location.Location WHERE Code = N'ZZ-OEEDFLT');
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] a newly inserted location defaults to unflagged',
     @Expected = N'0', @Actual = @dflt;
DELETE FROM Location.Location WHERE Code = N'ZZ-OEEDFLT';
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "0090_Oee"
```

Expected: FAIL on `[OeeFlag] Location.IsOeeEnabled column exists` (Actual `missing`), and the file errors once it reaches `l.IsOeeEnabled` with `Invalid column name 'IsOeeEnabled'`.

- [ ] **Step 3: Write the migration**

Create `sql/migrations/versioned/0090_location_is_oee_enabled.sql`:

```sql
-- ============================================================
-- Migration:   0090_location_is_oee_enabled.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-17
-- Description: Location.Location.IsOeeEnabled -- "is this location a downtime
--              and OEE unit?" -- the opt-in flag that replaces the implicit
--              self-scoping rule in Oee.ufn_ResolveDowntimeScope /
--              Oee.ufn_ResolveOeeEquipment.
--
--              WHY. Downtime resolves UP to the nearest WorkCenter, so a cell
--              under a Machining & Assembly line can never be a downtime unit.
--              6MA Cam Holder Line 1 needs three units under the line
--              (Machining, Assembly A, Assembly B) plus the line itself, and
--              the location model must not be restructured to get them.
--              Spec: docs/superpowers/specs/2026-09-16-oee-enabled-locations-
--              and-rollup-design.md.
--
--              ON THE INSTANCE, NOT THE TYPE. Unlike IsStockLocation (0081),
--              which answers a question about a KIND of location, this is
--              per-location opt-in: two Assembly Stations on different lines
--              may differ.
--
--              BACKFILL. Flags exactly what the pre-change rule admitted, so
--              day one is a no-op: every active die cast / trim machine and
--              every line stays a downtime unit and every dropdown is
--              unchanged. The rule is INLINED rather than calling
--              Oee.ufn_ResolveOeeEquipment because Reset-DevDatabase runs
--              versioned migrations BEFORE repeatables -- the function does
--              not exist yet on a fresh build. On a fresh build the backfill
--              also matches nothing (locations are seeded afterwards), which
--              is why sql/seeds/034_seed_oee_enabled_backfill.sql repeats it.
--
--              Scale is excluded here although the old rule admitted it: a
--              bench scale is not equipment a shift runs on. No Scale row
--              exists under any Area in prod (2026-09-17 extract), so this
--              changes nothing today.
--
--              Idempotent-guarded; the backfill carries its OWN guard because
--              a batch-level RETURN only exits the first batch, and re-running
--              the backfill would re-flag a location an operator had turned
--              off. ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0090_location_is_oee_enabled')
BEGIN PRINT 'Migration 0090 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. The column ----
IF COL_LENGTH('Location.Location', 'IsOeeEnabled') IS NULL
    ALTER TABLE Location.Location
        ADD IsOeeEnabled BIT NOT NULL
            CONSTRAINT DF_Location_IsOeeEnabled DEFAULT 0;
GO

-- ---- 2. Backfill from the pre-change rule (first application only) ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0090_location_is_oee_enabled')
BEGIN
    ;WITH Tree AS (
        SELECT l.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN l.Id END AS BIGINT) AS NearestWorkCenterId
        FROM Location.Location l
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
        WHERE l.ParentLocationId IS NULL
        UNION ALL
        SELECT c.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN c.Id ELSE t.NearestWorkCenterId END AS BIGINT)
        FROM Location.Location c
        INNER JOIN Tree t                              ON c.ParentLocationId = t.Id
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = c.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    )
    UPDATE l
       SET l.IsOeeEnabled = 1
    FROM Location.Location l
    INNER JOIN Tree t                              ON t.Id   = l.Id
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE l.DeprecatedAt IS NULL
      AND l.IsOeeEnabled = 0
      AND lt.Code IN (N'WorkCenter', N'Cell')
      AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Receiving', N'Scale')
      AND COALESCE(t.NearestWorkCenterId, l.Id) = l.Id
    OPTION (MAXRECURSION 20);
END
GO

-- ---- 3. Report, so a surprising flag set is visible at deploy time ----
DECLARE @Flagged INT = (SELECT COUNT(*) FROM Location.Location WHERE IsOeeEnabled = 1);
PRINT 'OEE-enabled locations after backfill: ' + CAST(@Flagged AS NVARCHAR(10));

DECLARE @Nested NVARCHAR(500) = (
    SELECT STUFF((SELECT N', ' + p.Code
                  FROM Location.Location p
                  WHERE p.IsOeeEnabled = 1 AND p.DeprecatedAt IS NULL
                    AND EXISTS (SELECT 1 FROM Location.Location c
                                WHERE c.ParentLocationId = p.Id
                                  AND c.IsOeeEnabled = 1 AND c.DeprecatedAt IS NULL)
                  ORDER BY p.Code FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''));
PRINT 'Flagged locations that already have a flagged child (become roll-ups): ' + ISNULL(@Nested, N'(none)');
GO

-- ---- 4. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0090_location_is_oee_enabled')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0090_location_is_oee_enabled',
            N'Location.Location.IsOeeEnabled (BIT, default 0) + backfill from the pre-change self-scoping equipment rule. The flag is now the definition of a downtime / OEE unit, so a cell under a production line can be one (6MA Machining / Assembly A / Assembly B).');
GO
PRINT 'Migration 0090 (location_is_oee_enabled) applied.';
GO
```

- [ ] **Step 4: Write the seed that repeats the rule on fresh builds**

Create `sql/seeds/034_seed_oee_enabled_backfill.sql`:

```sql
-- ============================================================
-- Seed:        034_seed_oee_enabled_backfill.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-17
-- Description: Sets Location.Location.IsOeeEnabled for a FRESH build.
--
--              Reset-DevDatabase runs versioned migrations, THEN repeatables,
--              THEN seeds -- so migration 0090's backfill runs against an
--              empty Location table and flags nothing. This applies the same
--              rule after 011_seed_locations_mpp_plant.sql has built the
--              plant. Mirror of 0090 section 2; keep the two in step.
--
--              Guarded on "nothing is flagged yet" so re-running the seeds
--              against a database where someone has since un-flagged a
--              location does not resurrect it.
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE IsOeeEnabled = 1)
BEGIN
    ;WITH Tree AS (
        SELECT l.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN l.Id END AS BIGINT) AS NearestWorkCenterId
        FROM Location.Location l
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
        WHERE l.ParentLocationId IS NULL
        UNION ALL
        SELECT c.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN c.Id ELSE t.NearestWorkCenterId END AS BIGINT)
        FROM Location.Location c
        INNER JOIN Tree t                              ON c.ParentLocationId = t.Id
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = c.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    )
    UPDATE l
       SET l.IsOeeEnabled = 1
    FROM Location.Location l
    INNER JOIN Tree t                              ON t.Id   = l.Id
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE l.DeprecatedAt IS NULL
      AND l.IsOeeEnabled = 0
      AND lt.Code IN (N'WorkCenter', N'Cell')
      AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Receiving', N'Scale')
      AND COALESCE(t.NearestWorkCenterId, l.Id) = l.Id
    OPTION (MAXRECURSION 20);
END
GO

DECLARE @Flagged INT = (SELECT COUNT(*) FROM Location.Location WHERE IsOeeEnabled = 1);
PRINT 'Seed 034: OEE-enabled locations = ' + CAST(@Flagged AS NVARCHAR(10));
GO
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "0090_Oee"
```

Expected: PASS on all eight assertions in `010_flag_backfill.sql`, `0 failure(s)`.

- [ ] **Step 6: Document the column**

In `MPP_MES_DATA_MODEL.md`, in the `### Location` table (the row list ending with `CoupledDownstreamCellLocationId`), append:

```markdown
| IsOeeEnabled | BIT | NOT NULL, DEFAULT 0 | **The definition of a downtime / OEE unit.** When 1, this location appears in the plant-floor downtime location dropdown (`Oee.DowntimeScope_ListForTerminal`), accepts `Oee.DowntimeEvent` rows, and gets an availability figure from `Oee.Shift_GetAvailability`. Opt-in per location, settable only on Cell / WorkCenter tier rows whose definition is not a device or store (`Location.ufn_CanBeOeeEnabled`). A flagged location with flagged descendants reports the MEAN of those descendants instead of its own figure, and its downtime counts against every one of them — this is what lets one line (6MA Cam Holder) carry per-station units (Machining, Assembly A, Assembly B) with no change to the location hierarchy. Migration `0090_location_is_oee_enabled`; backfilled from the pre-change self-scoping rule so no existing unit changed. |
```

- [ ] **Step 7: Regenerate the extended properties**

```bash
node sql/scripts/gen_extended_properties.js
```

Expected: rewrites `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql`; `git diff --stat` shows that one file changed.

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/versioned/0090_location_is_oee_enabled.sql sql/seeds/034_seed_oee_enabled_backfill.sql sql/tests/0090_Oee_EnabledLocations/010_flag_backfill.sql MPP_MES_DATA_MODEL.md sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql && git commit -m "feat(oee): Location.IsOeeEnabled flag + backfill from the current equipment rule"
```

---

## Task 2: Resolution — the flag becomes the rule

**Files:**
- Create: `sql/migrations/repeatable/R__Oee_ufn_OeeAncestors.sql`
- Create: `sql/tests/helpers/0090_fixture_oee_locations.sql`
- Create: `sql/tests/0090_Oee_EnabledLocations/020_resolution.sql`
- Modify: `sql/migrations/repeatable/R__Oee_ufn_ResolveDowntimeScope.sql`
- Modify: `sql/migrations/repeatable/R__Oee_ufn_ResolveOeeEquipment.sql`

**Interfaces:**
- Consumes: `Location.Location.IsOeeEnabled` (Task 1).
- Produces:
  - `Oee.ufn_OeeAncestors(@LocationId BIGINT)` → inline TVF, columns `AncestorLocationId BIGINT, Distance INT`; flagged, non-deprecated strict ancestors, nearest first by `Distance`.
  - `Oee.ufn_ResolveDowntimeScope(@CellLocationId BIGINT)` → `BIGINT`; unchanged signature, new rule.
  - `Oee.ufn_ResolveOeeEquipment()` → inline TVF, unchanged columns `LocationId, Code, Name, TierCode, DefinitionCode, ParentName, SortOrder`.
  - `test.OeeFixture_Build` / `test.OeeFixture_Teardown` — the shared `ZZ-OEE%` location fixture used by Tasks 2, 4 and 6.

- [ ] **Step 1: Write the shared test fixture helper**

Create `sql/tests/helpers/0090_fixture_oee_locations.sql`:

```sql
-- =============================================
-- Helper: test.OeeFixture_Build / test.OeeFixture_Teardown
-- A synthetic plant branch for the OEE-flag tests, covering every shape the
-- rules have to handle. All codes start ZZ-OEE so teardown is a prefix sweep.
--
--   ZZ-OEE            Area
--     ZZ-OEE-L        ProductionLine   FLAGGED   (a split line)
--       ZZ-OEE-L-T1   Terminal
--       ZZ-OEE-L-MI   CNCMachine       FLAGGED
--       ZZ-OEE-L-A    AssemblyStation  FLAGGED
--       ZZ-OEE-L-B    AssemblyStation  FLAGGED
--     ZZ-OEE-P        ProductionLine   FLAGGED   (a plain line)
--       ZZ-OEE-P-T1   Terminal
--   ZZ-OEE-DC         Area                       (a press shop)
--     ZZ-OEE-DC-M1    DieCastMachine   FLAGGED
--       ZZ-OEE-DC-M1-T1 Terminal                 (dedicated terminal)
--     ZZ-OEE-DC-M2    DieCastMachine   FLAGGED
--     ZZ-OEE-DC-M3    DieCastMachine   FLAGGED but DEPRECATED
--     ZZ-OEE-DC-T1    Terminal                   (shared terminal)
--   ZZ-OEE-E          Area                       (a shop with no equipment)
--     ZZ-OEE-E-T1     Terminal
--     ZZ-OEE-E-STORE  InventoryLocation
--
-- Rows are inserted directly (not through Location_SaveAll) so the fixture can
-- create the deprecated-but-flagged press that no write path would allow.
-- =============================================
IF OBJECT_ID(N'test.OeeFixture_Teardown', N'P') IS NOT NULL DROP PROCEDURE test.OeeFixture_Teardown;
GO
CREATE PROCEDURE test.OeeFixture_Teardown
AS
BEGIN
    SET NOCOUNT ON;

    DELETE ol
    FROM Audit.OperationLog ol
    INNER JOIN Oee.DowntimeEvent de ON de.Id = ol.EntityId
    INNER JOIN Location.Location l  ON l.Id  = de.LocationId
    WHERE l.Code LIKE N'ZZ-OEE%'
      AND ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent');

    DELETE de FROM Oee.DowntimeEvent de
    INNER JOIN Location.Location l ON l.Id = de.LocationId
    WHERE l.Code LIKE N'ZZ-OEE%';

    DELETE so FROM Oee.ShiftOverride so
    INNER JOIN Location.Location l ON l.Id = so.LocationId
    WHERE l.Code LIKE N'ZZ-OEE%';

    DELETE la FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId
    WHERE l.Code LIKE N'ZZ-OEE%';

    -- Leaf-first: each pass deletes the rows that have no children left.
    WHILE EXISTS (SELECT 1 FROM Location.Location WHERE Code LIKE N'ZZ-OEE%')
    BEGIN
        DELETE l
        FROM Location.Location l
        WHERE l.Code LIKE N'ZZ-OEE%'
          AND NOT EXISTS (SELECT 1 FROM Location.Location c WHERE c.ParentLocationId = l.Id);
        IF @@ROWCOUNT = 0 BREAK;   -- something else references a row; stop rather than spin
    END
END
GO

IF OBJECT_ID(N'test.OeeFixture_Build', N'P') IS NOT NULL DROP PROCEDURE test.OeeFixture_Build;
GO
CREATE PROCEDURE test.OeeFixture_Build
AS
BEGIN
    SET NOCOUNT ON;
    EXEC test.OeeFixture_Teardown;

    DECLARE @Site BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
        WHERE lt.Code = N'Site' AND l.DeprecatedAt IS NULL ORDER BY l.Id);

    DECLARE @Spec TABLE (
        Lvl INT, DefCode NVARCHAR(50), ParentCode NVARCHAR(50), Name NVARCHAR(200),
        Code NVARCHAR(50), SortOrder INT, Flag BIT, Deprecated BIT);

    INSERT INTO @Spec (Lvl, DefCode, ParentCode, Name, Code, SortOrder, Flag, Deprecated) VALUES
        (1, N'ProductionArea',    NULL,              N'OEE Test Assembly',    N'ZZ-OEE',          990, 0, 0),
        (1, N'ProductionArea',    NULL,              N'OEE Test Die Cast',    N'ZZ-OEE-DC',       991, 0, 0),
        (1, N'ProductionArea',    NULL,              N'OEE Test Empty Shop',  N'ZZ-OEE-E',        992, 0, 0),
        (2, N'ProductionLine',    N'ZZ-OEE',         N'OEE Split Line',       N'ZZ-OEE-L',          1, 1, 0),
        (2, N'ProductionLine',    N'ZZ-OEE',         N'OEE Plain Line',       N'ZZ-OEE-P',          2, 1, 0),
        (2, N'DieCastMachine',    N'ZZ-OEE-DC',      N'OEE Press 1',          N'ZZ-OEE-DC-M1',      1, 1, 0),
        (2, N'DieCastMachine',    N'ZZ-OEE-DC',      N'OEE Press 2',          N'ZZ-OEE-DC-M2',      2, 1, 0),
        (2, N'DieCastMachine',    N'ZZ-OEE-DC',      N'OEE Press 3 Retired',  N'ZZ-OEE-DC-M3',      3, 1, 1),
        (2, N'Terminal',          N'ZZ-OEE-DC',      N'Terminal',             N'ZZ-OEE-DC-T1',      9, 0, 0),
        (2, N'Terminal',          N'ZZ-OEE-E',       N'Terminal',             N'ZZ-OEE-E-T1',       1, 0, 0),
        (2, N'InventoryLocation', N'ZZ-OEE-E',       N'Storage',              N'ZZ-OEE-E-STORE',    2, 0, 0),
        (3, N'Terminal',          N'ZZ-OEE-L',       N'Assembly Out',         N'ZZ-OEE-L-T1',       1, 0, 0),
        (3, N'CNCMachine',        N'ZZ-OEE-L',       N'Machining',            N'ZZ-OEE-L-MI',       2, 1, 0),
        (3, N'AssemblyStation',   N'ZZ-OEE-L',       N'Assembly A',           N'ZZ-OEE-L-A',        3, 1, 0),
        (3, N'AssemblyStation',   N'ZZ-OEE-L',       N'Assembly B',           N'ZZ-OEE-L-B',        4, 1, 0),
        (3, N'Terminal',          N'ZZ-OEE-P',       N'Assembly Out',         N'ZZ-OEE-P-T1',       1, 0, 0),
        (3, N'Terminal',          N'ZZ-OEE-DC-M1',   N'Terminal',             N'ZZ-OEE-DC-M1-T1',   1, 0, 0);

    DECLARE @Lvl INT = 1;
    WHILE @Lvl <= 3
    BEGIN
        INSERT INTO Location.Location
            (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, IsOeeEnabled, DeprecatedAt)
        SELECT d.Id,
               COALESCE(p.Id, @Site),
               s.Name, s.Code, N'OEE test fixture', s.SortOrder, s.Flag,
               CASE WHEN s.Deprecated = 1 THEN SYSUTCDATETIME() END
        FROM @Spec s
        INNER JOIN Location.LocationTypeDefinition d ON d.Code = s.DefCode
        LEFT  JOIN Location.Location p               ON p.Code = s.ParentCode AND p.DeprecatedAt IS NULL
        WHERE s.Lvl = @Lvl;
        SET @Lvl = @Lvl + 1;
    END
END
GO
```

- [ ] **Step 2: Write the failing test**

Create `sql/tests/0090_Oee_EnabledLocations/020_resolution.sql`:

```sql
-- =============================================
-- File:         0090_Oee_EnabledLocations/020_resolution.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Oee.ufn_OeeAncestors, Oee.ufn_ResolveDowntimeScope and
--               Oee.ufn_ResolveOeeEquipment once the flag is the rule.
--               Uses test.OeeFixture_Build (see helpers/0090_fixture_oee_locations.sql).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0090_Oee_EnabledLocations/020_resolution.sql';
GO

EXEC test.OeeFixture_Build;
GO

-- =============================================
-- Test 1: ufn_OeeAncestors returns flagged ancestors only, nearest first.
-- =============================================
DECLARE @A   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DECLARE @L   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @T1  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');

DECLARE @ancA NVARCHAR(50) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_OeeAncestors(@A));
EXEC test.Assert_IsEqual @TestName = N'[OeeAnc] a station has exactly one flagged ancestor (its line)',
     @Expected = N'1', @Actual = @ancA;

DECLARE @ancACode NVARCHAR(50) = (SELECT TOP 1 l.Code FROM Oee.ufn_OeeAncestors(@A) a
                                  INNER JOIN Location.Location l ON l.Id = a.AncestorLocationId
                                  ORDER BY a.Distance);
EXEC test.Assert_IsEqual @TestName = N'[OeeAnc] that ancestor is the line',
     @Expected = N'ZZ-OEE-L', @Actual = @ancACode;

DECLARE @ancL NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_OeeAncestors(@L));
EXEC test.Assert_IsEqual @TestName = N'[OeeAnc] the line itself has no flagged ancestor (the Area is not flagged)',
     @Expected = N'0', @Actual = @ancL;

DECLARE @ancT NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_OeeAncestors(@T1));
EXEC test.Assert_IsEqual @TestName = N'[OeeAnc] a terminal on the line sees the line as its flagged ancestor',
     @Expected = N'1', @Actual = @ancT;
GO

-- =============================================
-- Test 2: ResolveDowntimeScope -- self when flagged, else nearest flagged
-- ancestor, else itself.
-- =============================================
DECLARE @L    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @A    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DECLARE @T1   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');
DECLARE @M1   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-M1');
DECLARE @M1T  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-M1-T1');
DECLARE @ET   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-E-T1');

DECLARE @rT1 NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = Oee.ufn_ResolveDowntimeScope(@T1));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] a terminal on a split line resolves to the line',
     @Expected = N'ZZ-OEE-L', @Actual = @rT1;

DECLARE @rA NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = Oee.ufn_ResolveDowntimeScope(@A));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] a FLAGGED station resolves to ITSELF, not up to the line',
     @Expected = N'ZZ-OEE-L-A', @Actual = @rA;

DECLARE @rL NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = Oee.ufn_ResolveDowntimeScope(@L));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] the line resolves to itself',
     @Expected = N'ZZ-OEE-L', @Actual = @rL;

DECLARE @rM1T NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = Oee.ufn_ResolveDowntimeScope(@M1T));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] a dedicated press terminal resolves to its press',
     @Expected = N'ZZ-OEE-DC-M1', @Actual = @rM1T;

DECLARE @rET NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = Oee.ufn_ResolveDowntimeScope(@ET));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] a terminal with no flagged ancestor falls back to itself',
     @Expected = N'ZZ-OEE-E-T1', @Actual = @rET;

DECLARE @rNull BIGINT = Oee.ufn_ResolveDowntimeScope(NULL);
EXEC test.Assert_IsNull @TestName = N'[DtScope] NULL in -> NULL out', @Value = @rNull;
GO

-- =============================================
-- Test 3: ufn_ResolveOeeEquipment is exactly the flagged, active set.
-- =============================================
DECLARE @inSet NVARCHAR(200) = (
    SELECT STUFF((SELECT N',' + e.Code FROM Oee.ufn_ResolveOeeEquipment() e
                  WHERE e.Code LIKE N'ZZ-OEE%'
                  ORDER BY e.Code FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''));
EXEC test.Assert_IsEqual @TestName = N'[OeeEquip] the fixture contributes exactly its flagged active rows',
     @Expected = N'ZZ-OEE-DC-M1,ZZ-OEE-DC-M2,ZZ-OEE-L,ZZ-OEE-L-A,ZZ-OEE-L-B,ZZ-OEE-L-MI,ZZ-OEE-P',
     @Actual = @inSet;
GO

-- =============================================
-- Test 4: un-flagging removes a row from the equipment set immediately.
-- =============================================
UPDATE Location.Location SET IsOeeEnabled = 0 WHERE Code = N'ZZ-OEE-L-B';
DECLARE @afterUnflag NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_ResolveOeeEquipment()
                                     WHERE Code = N'ZZ-OEE-L-B');
EXEC test.Assert_IsEqual @TestName = N'[OeeEquip] un-flagged station leaves the equipment set',
     @Expected = N'0', @Actual = @afterUnflag;

DECLARE @B BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-B');
DECLARE @rB NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = Oee.ufn_ResolveDowntimeScope(@B));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] an un-flagged station resolves back up to its line',
     @Expected = N'ZZ-OEE-L', @Actual = @rB;
UPDATE Location.Location SET IsOeeEnabled = 1 WHERE Code = N'ZZ-OEE-L-B';
GO

EXEC test.OeeFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "0090_Oee"
```

Expected: `020_resolution.sql` fails — `Invalid object name 'Oee.ufn_OeeAncestors'`, and `[DtScope] a FLAGGED station resolves to ITSELF` returns `ZZ-OEE-L` because the old walk-up rule is still in place.

- [ ] **Step 4: Write `ufn_OeeAncestors`**

Create `sql/migrations/repeatable/R__Oee_ufn_OeeAncestors.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Oee_ufn_OeeAncestors.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.0
-- Description: The OEE-enabled STRICT ancestors of a location, nearest first
--              (Distance 1 = parent). Two callers:
--                * Oee.ufn_ResolveDowntimeScope -- nearest flagged ancestor.
--                * Oee.Shift_GetAvailability -- downtime logged against a
--                  flagged ancestor counts against every station under it
--                  ("if the line is down, all stations are impacted").
--              Deprecated ancestors are skipped but do NOT stop the walk, so a
--              station under a deprecated intermediate still finds its line.
--
--              NAME IS ORDER-SENSITIVE. Repeatables deploy in filename order
--              and a FUNCTION gets no deferred name resolution (Msg 4121), so
--              this file must sort BEFORE R__Oee_ufn_ResolveDowntimeScope.sql,
--              which calls it ("OeeAncestors" < "ResolveDowntimeScope").
--
--              Read-only inline TVF: no OUTPUT params, no audit, no status row.
--
-- Parameters:
--   @LocationId BIGINT - the location to walk up from. NULL -> empty set.
--
-- Result set:
--   AncestorLocationId BIGINT, Distance INT
--
-- Dependencies:
--   Tables: Location.Location
--
-- Change Log:
--   2026-09-17 - 1.0 - Initial version (OEE-enabled locations spec).
-- ============================================================
CREATE OR ALTER FUNCTION Oee.ufn_OeeAncestors (@LocationId BIGINT)
RETURNS TABLE
AS
RETURN
(
    WITH Up AS (
        SELECT l.ParentLocationId AS AncestorId, 1 AS Distance
        FROM Location.Location l
        WHERE l.Id = @LocationId
          AND l.ParentLocationId IS NOT NULL
        UNION ALL
        SELECT p.ParentLocationId, u.Distance + 1
        FROM Up u
        INNER JOIN Location.Location p ON p.Id = u.AncestorId
        WHERE p.ParentLocationId IS NOT NULL
    )
    SELECT u.AncestorId AS AncestorLocationId,
           u.Distance
    FROM Up u
    INNER JOIN Location.Location a ON a.Id = u.AncestorId
    WHERE a.IsOeeEnabled = 1
      AND a.DeprecatedAt IS NULL
);
GO
```

- [ ] **Step 5: Rewrite `ufn_ResolveDowntimeScope`**

Replace the whole of `sql/migrations/repeatable/R__Oee_ufn_ResolveDowntimeScope.sql` with:

```sql
-- ============================================================
-- Repeatable:  R__Oee_ufn_ResolveDowntimeScope.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-17
-- Version:     2.0
-- Description: Resolves a location to the downtime "unit" it belongs to: the
--              nearest OEE-ENABLED location at or above it.
--
--              v2.0 (OEE-enabled locations spec, 2026-09-16): the rule is now
--              the Location.IsOeeEnabled flag, not "walk up to the nearest
--              WorkCenter". The old rule made it impossible for a cell under a
--              production line to be a downtime unit, because it always
--              resolved up to the line -- which is exactly what 6MA Cam Holder
--              Line 1 needs (Machining / Assembly A / Assembly B under the
--              line). Behaviour is unchanged wherever the backfill flagged
--              what the old rule admitted: a terminal still resolves to its
--              line, a press still resolves to itself.
--
--              Nothing flagged at or above -> the location itself (preserves
--              the old fallback, which the Downtime Manager relies on for an
--              unregistered terminal). NULL in -> NULL out.
--
--              This function no longer DEFINES equipment -- the flag does (see
--              Oee.ufn_ResolveOeeEquipment). Its remaining job is the Downtime
--              Manager's default selection.
--
-- Parameters:
--   @CellLocationId BIGINT - any location (terminal, cell, line).
--
-- Returns:
--   BIGINT - the resolved downtime unit's Location.Id, or NULL for NULL input.
--
-- Dependencies:
--   Tables: Location.Location
--   Funcs:  Oee.ufn_OeeAncestors  (deploys first -- see that file's header)
--
-- Change Log:
--   2026-07-21 - 1.0 - Initial version (nearest WorkCenter ancestor).
--   2026-09-17 - 2.0 - Nearest OEE-enabled location at or above.
-- ============================================================
CREATE OR ALTER FUNCTION Oee.ufn_ResolveDowntimeScope (@CellLocationId BIGINT)
RETURNS BIGINT
AS
BEGIN
    IF @CellLocationId IS NULL RETURN NULL;

    -- A flagged location is its own unit.
    IF EXISTS (SELECT 1 FROM Location.Location
               WHERE Id = @CellLocationId AND IsOeeEnabled = 1 AND DeprecatedAt IS NULL)
        RETURN @CellLocationId;

    DECLARE @Anc BIGINT =
        (SELECT TOP 1 a.AncestorLocationId
         FROM Oee.ufn_OeeAncestors(@CellLocationId) a
         ORDER BY a.Distance);

    RETURN COALESCE(@Anc, @CellLocationId);
END
GO
```

- [ ] **Step 6: Rewrite `ufn_ResolveOeeEquipment`**

In `sql/migrations/repeatable/R__Oee_ufn_ResolveOeeEquipment.sql`, replace the header's Description block and the `WHERE` clause. The body becomes:

```sql
CREATE OR ALTER FUNCTION Oee.ufn_ResolveOeeEquipment ()
RETURNS TABLE
AS
RETURN
(
    SELECT
        l.Id        AS LocationId,
        l.Code,
        l.Name,
        lt.Code     AS TierCode,
        ltd.Code    AS DefinitionCode,
        p.Name      AS ParentName,
        l.SortOrder
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType           lt  ON lt.Id  = ltd.LocationTypeId
    LEFT  JOIN Location.Location               p   ON p.Id   = l.ParentLocationId
    WHERE l.DeprecatedAt IS NULL
      AND l.IsOeeEnabled = 1
);
GO
```

and the header's Description becomes:

```
-- Description: THE definition of "a piece of equipment" for OEE purposes --
--              the set of Location.Location rows that downtime is logged
--              against and that an OEE figure can be computed for.
--
--              v2.0 (OEE-enabled locations spec, 2026-09-16): one condition --
--              Location.IsOeeEnabled = 1, active. The old self-scoping test
--              (ufn_ResolveDowntimeScope(Id) = Id) plus the tier and
--              device/store exclusions are gone: they are now enforced once,
--              at the write path, by Location.ufn_CanBeOeeEnabled, so the set
--              is data an engineer can see and change in the Config Tool
--              rather than a rule buried in a function.
--
--              Migration 0090 backfilled the flag from the old rule, so this
--              returns the same set it did before the change until someone
--              flags something new.
--
--              Single source of truth: Oee.ShiftOverride_ListEquipment (the
--              picker), Oee.ShiftOverride_Create (the validation) and
--              Oee.Shift_GetAvailability all read this function.
--
--              Read-only inline TVF: no OUTPUT params, no audit, no status row.
--              No longer calls ufn_ResolveDowntimeScope, so the filename
--              ordering constraint that used to apply here is gone.
```

Add to its Change Log: `--   2026-09-17 - 2.0 - Flag-driven (Location.IsOeeEnabled).`

- [ ] **Step 7: Run the test to verify it passes**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "0090_Oee"
```

Expected: PASS on every assertion in `010_flag_backfill.sql` and `020_resolution.sql`, `0 failure(s)`.

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Oee_ufn_OeeAncestors.sql sql/migrations/repeatable/R__Oee_ufn_ResolveDowntimeScope.sql sql/migrations/repeatable/R__Oee_ufn_ResolveOeeEquipment.sql sql/tests/helpers/0090_fixture_oee_locations.sql sql/tests/0090_Oee_EnabledLocations/020_resolution.sql && git commit -m "feat(oee): the IsOeeEnabled flag is the equipment rule (resolver + equipment set)"
```

---

## Task 3: The write path — flag a location from the Config Tool (SQL side)

**Files:**
- Create: `sql/migrations/repeatable/R__Location_ufn_CanBeOeeEnabled.sql`
- Create: `sql/migrations/repeatable/R__Location_LocationTypeDefinition_GetOeeEligibility.sql`
- Create: `sql/tests/0003_Location/070_Location_IsOeeEnabled.sql`
- Modify: `sql/migrations/repeatable/R__Location_Location_SaveAll.sql`
- Modify: `sql/migrations/repeatable/R__Location_Location_Get.sql`

**Interfaces:**
- Consumes: `Location.Location.IsOeeEnabled` (Task 1).
- Produces:
  - `Location.ufn_CanBeOeeEnabled(@LocationTypeDefinitionId BIGINT)` → `BIT`.
  - `Location.LocationTypeDefinition_GetOeeEligibility @LocationTypeDefinitionId BIGINT` → one row `LocationTypeDefinitionId, CanBeOeeEnabled BIT` (empty set = definition not found).
  - `Location.Location_SaveAll` gains `@IsOeeEnabled BIT = NULL` (NULL = default 0 on create, unchanged on update).
  - `Location.Location_Get` result set gains `IsOeeEnabled` as its **last** column.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0003_Location/070_Location_IsOeeEnabled.sql`:

```sql
-- =============================================
-- File:         0003_Location/070_Location_IsOeeEnabled.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  The Config Tool write path for Location.IsOeeEnabled:
--               Location_SaveAll carries it, the type guard
--               (Location.ufn_CanBeOeeEnabled) refuses a device / store /
--               hierarchy tier, Location_Get returns it, and
--               LocationTypeDefinition_GetOeeEligibility answers the
--               checkbox-enabled question for the editor.
--               Fixture codes use the ZZ-LOCF prefix (NOT ZZ-OEE, which the
--               shared OEE fixture teardown sweeps).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0003_Location/070_Location_IsOeeEnabled.sql';
GO

-- ---- fixture: a parent Area, resolved dynamically ----
IF OBJECT_ID(N'tempdb..#LocF') IS NOT NULL DROP TABLE #LocF;
CREATE TABLE #LocF (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);

DECLARE @Area BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    WHERE ltd.Code = N'ProductionArea' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @Site BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE lt.Code = N'Site' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
INSERT INTO #LocF (Tag, Val) VALUES (N'AREA', @Area), (N'SITE', @Site);
EXEC test.Assert_IsNotNull @TestName = N'[OeeSave] fixture: a ProductionArea exists', @Value = @Area;
GO

-- =============================================
-- Test 1: create a press with the flag ON.
-- =============================================
DECLARE @Area BIGINT = (SELECT Val FROM #LocF WHERE Tag = N'AREA');
DECLARE @PressDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @r1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r1 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Area, @LocationTypeDefinitionId = @PressDef,
    @Name = N'OEE Flag Press', @Code = N'ZZ-LOCF-M1', @AppUserId = 1, @IsOeeEnabled = 1;

DECLARE @s1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r1);
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] create with the flag on succeeds',
     @Expected = N'1', @Actual = @s1;
DECLARE @f1 NVARCHAR(10) = (SELECT CAST(IsOeeEnabled AS NVARCHAR(10)) FROM Location.Location WHERE Code = N'ZZ-LOCF-M1');
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] the created row is flagged',
     @Expected = N'1', @Actual = @f1;
GO

-- =============================================
-- Test 2: create with the parameter omitted -> unflagged.
-- =============================================
DECLARE @Area BIGINT = (SELECT Val FROM #LocF WHERE Tag = N'AREA');
DECLARE @PressDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r2 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Area, @LocationTypeDefinitionId = @PressDef,
    @Name = N'OEE Flag Press 2', @Code = N'ZZ-LOCF-M2', @AppUserId = 1;
DECLARE @f2 NVARCHAR(10) = (SELECT CAST(IsOeeEnabled AS NVARCHAR(10)) FROM Location.Location WHERE Code = N'ZZ-LOCF-M2');
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] create without the parameter leaves it unflagged',
     @Expected = N'0', @Actual = @f2;
GO

-- =============================================
-- Test 3: the type guard -- a Terminal cannot be flagged. The guard must fire
-- BEFORE the required-attribute check, or this rejection would be masked by
-- Terminal's required HasBarcodeScanner attribute.
-- =============================================
DECLARE @Area BIGINT = (SELECT Val FROM #LocF WHERE Tag = N'AREA');
DECLARE @TermDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'Terminal');
DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r3 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Area, @LocationTypeDefinitionId = @TermDef,
    @Name = N'OEE Flag Terminal', @Code = N'ZZ-LOCF-T1', @AppUserId = 1, @IsOeeEnabled = 1;
DECLARE @s3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r3);
DECLARE @m3 NVARCHAR(500) = (SELECT Message FROM @r3);
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] a Terminal cannot be OEE-enabled',
     @Expected = N'0', @Actual = @s3;
EXEC test.Assert_Contains @TestName = N'[OeeSave] the rejection names the OEE flag',
     @Actual = @m3, @Expected = N'OEE';
GO

-- =============================================
-- Test 4: an Area cannot be flagged either (wrong tier).
-- =============================================
DECLARE @Site BIGINT = (SELECT Val FROM #LocF WHERE Tag = N'SITE');
DECLARE @AreaDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionArea');
DECLARE @r4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r4 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Site, @LocationTypeDefinitionId = @AreaDef,
    @Name = N'OEE Flag Area', @Code = N'ZZ-LOCF-A1', @AppUserId = 1, @IsOeeEnabled = 1;
DECLARE @s4 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r4);
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] an Area cannot be OEE-enabled',
     @Expected = N'0', @Actual = @s4;
GO

-- =============================================
-- Test 5: update turns the flag off; omitting the parameter leaves it alone.
-- =============================================
DECLARE @Area BIGINT = (SELECT Val FROM #LocF WHERE Tag = N'AREA');
DECLARE @PressDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @M1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-LOCF-M1');

DECLARE @r5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r5 EXEC Location.Location_SaveAll
    @Id = @M1, @ParentLocationId = @Area, @LocationTypeDefinitionId = @PressDef,
    @Name = N'OEE Flag Press', @Code = N'ZZ-LOCF-M1', @AppUserId = 1, @IsOeeEnabled = 0;
DECLARE @f5 NVARCHAR(10) = (SELECT CAST(IsOeeEnabled AS NVARCHAR(10)) FROM Location.Location WHERE Id = @M1);
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] update can turn the flag off',
     @Expected = N'0', @Actual = @f5;

UPDATE Location.Location SET IsOeeEnabled = 1 WHERE Id = @M1;
DECLARE @r5b TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r5b EXEC Location.Location_SaveAll
    @Id = @M1, @ParentLocationId = @Area, @LocationTypeDefinitionId = @PressDef,
    @Name = N'OEE Flag Press Renamed', @Code = N'ZZ-LOCF-M1', @AppUserId = 1;
DECLARE @f5b NVARCHAR(10) = (SELECT CAST(IsOeeEnabled AS NVARCHAR(10)) FROM Location.Location WHERE Id = @M1);
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] update without the parameter preserves the flag',
     @Expected = N'1', @Actual = @f5b;
GO

-- =============================================
-- Test 6: Location_Get returns the flag (last column).
-- =============================================
DECLARE @M1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-LOCF-M1');
DECLARE @g TABLE (Id BIGINT, LocationTypeDefinitionId BIGINT, ParentLocationId BIGINT,
    Name NVARCHAR(200), Code NVARCHAR(50), Description NVARCHAR(500), SortOrder INT,
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    LocationTypeDefinitionName NVARCHAR(100), LocationTypeDefinitionIcon NVARCHAR(100),
    LocationTypeName NVARCHAR(100), IsOeeEnabled BIT);
INSERT INTO @g EXEC Location.Location_Get @Id = @M1;
DECLARE @g1 NVARCHAR(10) = (SELECT CAST(IsOeeEnabled AS NVARCHAR(10)) FROM @g);
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] Location_Get returns IsOeeEnabled',
     @Expected = N'1', @Actual = @g1;
GO

-- =============================================
-- Test 7: the eligibility read proc that drives the editor checkbox.
-- =============================================
DECLARE @e TABLE (LocationTypeDefinitionId BIGINT, CanBeOeeEnabled BIT);
DECLARE @PressDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @LineDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionLine');
DECLARE @TermDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'Terminal');
DECLARE @AreaDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionArea');

DELETE FROM @e; INSERT INTO @e EXEC Location.LocationTypeDefinition_GetOeeEligibility @LocationTypeDefinitionId = @PressDef;
DECLARE @e1 NVARCHAR(10) = (SELECT CAST(CanBeOeeEnabled AS NVARCHAR(10)) FROM @e);
EXEC test.Assert_IsEqual @TestName = N'[OeeElig] a die cast machine is eligible', @Expected = N'1', @Actual = @e1;

DELETE FROM @e; INSERT INTO @e EXEC Location.LocationTypeDefinition_GetOeeEligibility @LocationTypeDefinitionId = @LineDef;
DECLARE @e2 NVARCHAR(10) = (SELECT CAST(CanBeOeeEnabled AS NVARCHAR(10)) FROM @e);
EXEC test.Assert_IsEqual @TestName = N'[OeeElig] a production line is eligible', @Expected = N'1', @Actual = @e2;

DELETE FROM @e; INSERT INTO @e EXEC Location.LocationTypeDefinition_GetOeeEligibility @LocationTypeDefinitionId = @TermDef;
DECLARE @e3 NVARCHAR(10) = (SELECT CAST(CanBeOeeEnabled AS NVARCHAR(10)) FROM @e);
EXEC test.Assert_IsEqual @TestName = N'[OeeElig] a terminal is not eligible', @Expected = N'0', @Actual = @e3;

DELETE FROM @e; INSERT INTO @e EXEC Location.LocationTypeDefinition_GetOeeEligibility @LocationTypeDefinitionId = @AreaDef;
DECLARE @e4 NVARCHAR(10) = (SELECT CAST(CanBeOeeEnabled AS NVARCHAR(10)) FROM @e);
EXEC test.Assert_IsEqual @TestName = N'[OeeElig] an area is not eligible', @Expected = N'0', @Actual = @e4;

DELETE FROM @e; INSERT INTO @e EXEC Location.LocationTypeDefinition_GetOeeEligibility @LocationTypeDefinitionId = -1;
DECLARE @e5 INT = (SELECT COUNT(*) FROM @e);
EXEC test.Assert_RowCount @TestName = N'[OeeElig] unknown definition -> empty result set',
     @ExpectedCount = 0, @ActualCount = @e5;
GO

-- ---- cleanup ----
DELETE la FROM Location.LocationAttribute la
INNER JOIN Location.Location l ON l.Id = la.LocationId WHERE l.Code LIKE N'ZZ-LOCF%';
DELETE FROM Location.Location WHERE Code LIKE N'ZZ-LOCF%';
IF OBJECT_ID(N'tempdb..#LocF') IS NOT NULL DROP TABLE #LocF;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "070_Location_IsOeeEnabled"
```

Expected: fails immediately — `Location.Location_SaveAll has too many arguments specified` (the `@IsOeeEnabled` parameter does not exist yet).

- [ ] **Step 3: Write the eligibility function**

Create `sql/migrations/repeatable/R__Location_ufn_CanBeOeeEnabled.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Location_ufn_CanBeOeeEnabled.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.0
-- Description: May a location of this TYPE be marked IsOeeEnabled?
--
--              Two conditions, both necessary:
--                (1) Cell or WorkCenter tier. An Area, Site or Enterprise row
--                    is a grouping, not a thing a shift runs on; flagging one
--                    would scope downtime across a whole shop or plant.
--                (2) Not a device or a store. A terminal is an operator IO
--                    device, a printer and a scale are peripherals, and a rack
--                    is a store -- none of them "go down".
--
--              This is the rule the old Oee.ufn_ResolveOeeEquipment carried
--              inline; it now lives at the WRITE path so the equipment set can
--              be a plain flag lookup.
--
--              Deprecated definitions still answer truthfully -- the caller
--              (Location_SaveAll) rejects a deprecated definition separately
--              with its own message.
--
-- Parameters:
--   @LocationTypeDefinitionId BIGINT - the definition to test. Unknown -> 0.
--
-- Returns:
--   BIT - 1 eligible, 0 not.
--
-- Dependencies:
--   Tables: Location.LocationTypeDefinition, Location.LocationType
--
-- Change Log:
--   2026-09-17 - 1.0 - Initial version (OEE-enabled locations spec).
-- ============================================================
CREATE OR ALTER FUNCTION Location.ufn_CanBeOeeEnabled (@LocationTypeDefinitionId BIGINT)
RETURNS BIT
AS
BEGIN
    IF @LocationTypeDefinitionId IS NULL RETURN 0;

    DECLARE @Ok BIT = 0;

    SELECT @Ok = CASE
            WHEN lt.Code IN (N'WorkCenter', N'Cell')
             AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Receiving', N'Scale')
            THEN 1 ELSE 0 END
    FROM Location.LocationTypeDefinition ltd
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE ltd.Id = @LocationTypeDefinitionId;

    RETURN ISNULL(@Ok, 0);
END
GO
```

- [ ] **Step 4: Write the eligibility read proc**

Create `sql/migrations/repeatable/R__Location_LocationTypeDefinition_GetOeeEligibility.sql`:

```sql
-- =============================================
-- Procedure:   Location.LocationTypeDefinition_GetOeeEligibility
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.0
--
-- Description:
--   May a location of this type be OEE / downtime enabled? Drives the
--   enabled-state of the "OEE / downtime enabled" checkbox on the Plant
--   Hierarchy editor, so the screen asks SQL the same question
--   Location.Location_SaveAll enforces instead of restating the rule in
--   Python.
--
--   Read proc: one result set, no status row, no OUTPUT params (FDS-11-011).
--   Empty result set = definition not found.
--
-- Parameters (input):
--   @LocationTypeDefinitionId BIGINT - the definition to test. Required.
--
-- Result set (zero or one row):
--   LocationTypeDefinitionId, CanBeOeeEnabled (BIT)
--
-- Dependencies:
--   Tables: Location.LocationTypeDefinition
--   Funcs:  Location.ufn_CanBeOeeEnabled
--
-- Change Log:
--   2026-09-17 - 1.0 - Initial version (OEE-enabled locations spec).
-- =============================================
CREATE OR ALTER PROCEDURE Location.LocationTypeDefinition_GetOeeEligibility
    @LocationTypeDefinitionId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ltd.Id                                          AS LocationTypeDefinitionId,
           Location.ufn_CanBeOeeEnabled(ltd.Id)            AS CanBeOeeEnabled
    FROM Location.LocationTypeDefinition ltd
    WHERE ltd.Id = @LocationTypeDefinitionId;
END;
GO
```

- [ ] **Step 5: Add the flag to `Location_Get`**

In `sql/migrations/repeatable/R__Location_Location_Get.sql`, add `IsOeeEnabled` as the **last** selected column (appending keeps existing `INSERT … EXEC` callers' column order valid up to the new column):

```sql
        ltd.Name   AS LocationTypeDefinitionName,
        ltd.Icon   AS LocationTypeDefinitionIcon,
        lt.Name    AS LocationTypeName,
        l.IsOeeEnabled
```

and bump the header: `-- Version:     2.1` plus Change Log line `--   2026-09-17 - 2.1 - IsOeeEnabled (OEE-enabled locations spec).`

- [ ] **Step 6: Thread the flag through `Location_SaveAll`**

Five edits to `sql/migrations/repeatable/R__Location_Location_SaveAll.sql`:

1. Signature — add the parameter last:

```sql
    @AttributeValuesJson      NVARCHAR(MAX)   = N'[]',
    @IsOeeEnabled             BIT             = NULL
```

2. `@Params` — add it to the failure snapshot:

```sql
                @SortOrder                AS SortOrder,
                @IsOeeEnabled             AS IsOeeEnabled,
                JSON_QUERY(ISNULL(@AttributeValuesJson, N'[]')) AS AttributeValues
```

3. The guard — immediately after the `IF @DefHierarchyLevel IS NULL` block (before parent resolution and before attribute parsing, so a Terminal's required-attribute check cannot mask it):

```sql
        -- ====================
        -- OEE / downtime unit eligibility (spec 2026-09-16 sec 3.1)
        -- ====================
        IF @IsOeeEnabled = 1 AND Location.ufn_CanBeOeeEnabled(@LocationTypeDefinitionId) = 0
        BEGIN
            SET @Message = N'This location type cannot be OEE / downtime enabled (only lines and equipment cells can).';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = @Id,
                @LogEventTypeCode    = @EventCode,
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
```

4. Create branch — the INSERT:

```sql
            INSERT INTO Location.Location
                (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, IsOeeEnabled, CreatedAt)
            VALUES
                (@LocationTypeDefinitionId, @ParentLocationId, @Name, @Code, @Description, @SortOrder, ISNULL(@IsOeeEnabled, 0), SYSUTCDATETIME());
```

5. Update branch — the UPDATE, plus both audit snapshots:

```sql
            UPDATE Location.Location
            SET Name         = @Name,
                Code         = @Code,
                Description  = @Description,
                SortOrder    = COALESCE(@SortOrder, SortOrder),
                IsOeeEnabled = COALESCE(@IsOeeEnabled, IsOeeEnabled)
            WHERE Id = @Id;
```

In **both** the `@OldValue` and `@NewValue` snapshots, extend the inner Location select:

```sql
                    (SELECT Id, ParentLocationId, LocationTypeDefinitionId,
                            Code, Name, Description, SortOrder, IsOeeEnabled
                     FROM Location.Location WHERE Id = @Id
                     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS Location,
```

Header: bump to `-- Version:     1.1`, document `@IsOeeEnabled BIT = NULL - OEE / downtime unit flag. NULL = 0 on create, unchanged on update.` in the Parameters block, and add `--   2026-09-17 - 1.1 - @IsOeeEnabled + type guard (OEE-enabled locations spec).` to the Change Log.

- [ ] **Step 7: Run the test to verify it passes**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "070_Location_IsOeeEnabled"
```

Expected: PASS on all 14 assertions, `0 failure(s)`.

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Location_ufn_CanBeOeeEnabled.sql sql/migrations/repeatable/R__Location_LocationTypeDefinition_GetOeeEligibility.sql sql/migrations/repeatable/R__Location_Location_SaveAll.sql sql/migrations/repeatable/R__Location_Location_Get.sql sql/tests/0003_Location/070_Location_IsOeeEnabled.sql && git commit -m "feat(oee): Location_SaveAll carries IsOeeEnabled, guarded by location type"
```

---

## Task 4: The downtime location dropdown

**Files:**
- Modify: `sql/migrations/repeatable/R__Oee_DowntimeScope_ListForTerminal.sql` (full rewrite of the body)
- Rewrite: `sql/tests/0026_PlantFloor_Downtime_Shift/120_DowntimeScope_ListForTerminal.sql`

**Interfaces:**
- Consumes: `Oee.ufn_OeeAncestors`, `Oee.ufn_ResolveDowntimeScope` (Task 2); `test.OeeFixture_Build` (Task 2).
- Produces: `Oee.DowntimeScope_ListForTerminal @TerminalLocationId BIGINT, @ActiveCellLocationId BIGINT = NULL` → unchanged result columns `ScopeLocationId, Code, Name, Kind, IsDefault`, now ordered by tree position (a line before its stations).

- [ ] **Step 1: Write the failing test**

Replace the entire contents of `sql/tests/0026_PlantFloor_Downtime_Shift/120_DowntimeScope_ListForTerminal.sql` with:

```sql
-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/120_DowntimeScope_ListForTerminal.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-09
-- Rewritten:    2026-09-17 (OEE-enabled locations spec)
-- Description:  Oee.DowntimeScope_ListForTerminal -- the downtime units an
--               operator at a terminal may log against, and which one the
--               Downtime Manager preselects.
--
--               The rule is now one sentence: the OEE-ENABLED locations in the
--               terminal's zone subtree, the zone included. Asserted per shape:
--                 * shared area terminal (die cast)  -> one row per flagged press
--                 * dedicated machine terminal       -> that machine
--                 * plain line terminal              -> the line
--                 * SPLIT line terminal (6MA shape)  -> the line + its stations,
--                                                       in tree order
--                 * area with nothing flagged        -> empty
--                 * fallback terminal (Site zone)    -> empty
--               Plus the three default rules: single row defaults to itself;
--               an active cell that is a LEAF unit preselects; an active cell
--               that is a ROLL-UP (a line with stations) preselects NOTHING,
--               because defaulting to the line would charge a side-A jam to
--               every station on the line.
--
--               All fixtures come from test.OeeFixture_Build -- structural, no
--               dependency on plant-seed codes (Dev's trim shop and prod's
--               disagree until Dev is re-synced).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/120_DowntimeScope_ListForTerminal.sql';
GO

EXEC test.OeeFixture_Build;
GO

IF OBJECT_ID(N'tempdb..#ScOut') IS NOT NULL DROP TABLE #ScOut;
CREATE TABLE #ScOut (
    ScopeLocationId BIGINT        NULL,
    Code            NVARCHAR(50)  NULL,
    Name            NVARCHAR(200) NULL,
    Kind            NVARCHAR(100) NULL,
    IsDefault       BIT           NULL
);
GO

-- =============================================
-- Test 1: shared area terminal -> one row per ACTIVE flagged press, no default.
-- =============================================
DECLARE @DcT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-T1');
DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @DcT;

DECLARE @c1 NVARCHAR(200) = (SELECT STUFF((SELECT N',' + Code FROM #ScOut ORDER BY Code
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] shared area terminal lists its flagged presses, deprecated excluded',
     @Expected = N'ZZ-OEE-DC-M1,ZZ-OEE-DC-M2', @Actual = @c1;

DECLARE @d1 INT = (SELECT COUNT(*) FROM #ScOut WHERE IsDefault = 1);
EXEC test.Assert_RowCount @TestName = N'[DtScope] more than one option and no active cell -> no default',
     @ExpectedCount = 0, @ActualCount = @d1;
GO

-- =============================================
-- Test 2: an active cell inside the list preselects exactly that row.
-- =============================================
DECLARE @DcT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-T1');
DECLARE @M2  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-M2');
DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @DcT, @ActiveCellLocationId = @M2;
DECLARE @d2 NVARCHAR(50) = (SELECT Code FROM #ScOut WHERE IsDefault = 1);
EXEC test.Assert_IsEqual @TestName = N'[DtScope] the active press is preselected',
     @Expected = N'ZZ-OEE-DC-M2', @Actual = @d2;
GO

-- =============================================
-- Test 3: an active cell OUTSIDE the list leaves no default.
-- =============================================
DECLARE @DcT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-T1');
DECLARE @A   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @DcT, @ActiveCellLocationId = @A;
DECLARE @d3 INT = (SELECT COUNT(*) FROM #ScOut WHERE IsDefault = 1);
EXEC test.Assert_RowCount @TestName = N'[DtScope] an active cell outside the list gives no default',
     @ExpectedCount = 0, @ActualCount = @d3;
GO

-- =============================================
-- Test 4: dedicated machine terminal -> that machine, preselected.
-- =============================================
DECLARE @M1T BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-M1-T1');
DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @M1T;
DECLARE @c4 NVARCHAR(200) = (SELECT STUFF((SELECT N',' + Code FROM #ScOut ORDER BY Code
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''));
DECLARE @d4 NVARCHAR(10) = (SELECT CAST(IsDefault AS NVARCHAR(10)) FROM #ScOut);
EXEC test.Assert_IsEqual @TestName = N'[DtScope] dedicated terminal lists only its machine',
     @Expected = N'ZZ-OEE-DC-M1', @Actual = @c4;
EXEC test.Assert_IsEqual @TestName = N'[DtScope] a single option is preselected',
     @Expected = N'1', @Actual = @d4;
GO

-- =============================================
-- Test 5: plain line terminal -> the line, preselected (today's M&A behaviour).
-- =============================================
DECLARE @PT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-P-T1');
DECLARE @P  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-P');
DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @PT, @ActiveCellLocationId = @P;
DECLARE @c5 NVARCHAR(200) = (SELECT STUFF((SELECT N',' + Code FROM #ScOut ORDER BY Code
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''));
DECLARE @d5 NVARCHAR(10) = (SELECT CAST(IsDefault AS NVARCHAR(10)) FROM #ScOut);
EXEC test.Assert_IsEqual @TestName = N'[DtScope] an unsplit line terminal still lists just the line',
     @Expected = N'ZZ-OEE-P', @Actual = @c5;
EXEC test.Assert_IsEqual @TestName = N'[DtScope] and preselects it',
     @Expected = N'1', @Actual = @d5;
GO

-- =============================================
-- Test 6: SPLIT line terminal -> line + stations in TREE order, no default
-- even though the session cell is the line (it is a roll-up).
-- =============================================
DECLARE @LT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');
DECLARE @L  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @LT, @ActiveCellLocationId = @L;

-- Tree order is assertable because the proc returns rows in it; capture with a
-- row number over the natural order by inserting into an ordered temp table.
DECLARE @c6 NVARCHAR(400) = (SELECT STUFF((SELECT N',' + Code FROM #ScOut
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] split line lists the line then its stations, in tree order',
     @Expected = N'ZZ-OEE-L,ZZ-OEE-L-MI,ZZ-OEE-L-A,ZZ-OEE-L-B', @Actual = @c6;

DECLARE @d6 INT = (SELECT COUNT(*) FROM #ScOut WHERE IsDefault = 1);
EXEC test.Assert_RowCount @TestName = N'[DtScope] a roll-up active cell preselects NOTHING (a side jam must not be charged to the line)',
     @ExpectedCount = 0, @ActualCount = @d6;
GO

-- =============================================
-- Test 7: an active cell that is a LEAF station preselects.
-- =============================================
DECLARE @LT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');
DECLARE @A  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @LT, @ActiveCellLocationId = @A;
DECLARE @d7 NVARCHAR(50) = (SELECT Code FROM #ScOut WHERE IsDefault = 1);
EXEC test.Assert_IsEqual @TestName = N'[DtScope] an active station preselects itself',
     @Expected = N'ZZ-OEE-L-A', @Actual = @d7;
GO

-- =============================================
-- Test 8: un-flagging a station removes it from the list the moment it is off.
-- =============================================
UPDATE Location.Location SET IsOeeEnabled = 0 WHERE Code = N'ZZ-OEE-L-B';
DECLARE @LT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');
DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @LT;
DECLARE @c8 NVARCHAR(400) = (SELECT STUFF((SELECT N',' + Code FROM #ScOut
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] an un-flagged station leaves the dropdown',
     @Expected = N'ZZ-OEE-L,ZZ-OEE-L-MI,ZZ-OEE-L-A', @Actual = @c8;
UPDATE Location.Location SET IsOeeEnabled = 1 WHERE Code = N'ZZ-OEE-L-B';
GO

-- =============================================
-- Test 9: an area with nothing flagged, the fallback terminal, an unknown id
-- and NULL all return an empty set.
-- =============================================
DECLARE @ET BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-E-T1');
DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @ET;
DECLARE @c9 INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] an area with no flagged equipment returns nothing',
     @ExpectedCount = 0, @ActualCount = @c9;

DECLARE @Fb BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'FALLBACK-TERMINAL');
DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @Fb;
DECLARE @c9b INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] the fallback terminal (Site zone) returns nothing',
     @ExpectedCount = 0, @ActualCount = @c9b;

DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = -1;
DECLARE @c9c INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] an unknown terminal returns nothing',
     @ExpectedCount = 0, @ActualCount = @c9c;

DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = NULL;
DECLARE @c9d INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] NULL terminal returns nothing',
     @ExpectedCount = 0, @ActualCount = @c9d;
GO

-- ---- cleanup ----
IF OBJECT_ID(N'tempdb..#ScOut') IS NOT NULL DROP TABLE #ScOut;
EXEC test.OeeFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "120_DowntimeScope"
```

Expected: FAIL on Test 6 (`[DtScope] split line lists the line then its stations` returns just `ZZ-OEE-L`, because the WorkCenter branch still collapses to the zone) and on Test 6's default assertion (the line is preselected).

- [ ] **Step 3: Rewrite the proc body**

In `sql/migrations/repeatable/R__Oee_DowntimeScope_ListForTerminal.sql`, replace everything from `CREATE OR ALTER PROCEDURE` to the final `GO` with:

```sql
CREATE OR ALTER PROCEDURE Oee.DowntimeScope_ListForTerminal
    @TerminalLocationId   BIGINT,
    @ActiveCellLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Options TABLE (
        ScopeLocationId      BIGINT        NOT NULL PRIMARY KEY,
        Code                 NVARCHAR(50)  NULL,
        Name                 NVARCHAR(200) NULL,
        Kind                 NVARCHAR(100) NULL,
        SortPath             NVARCHAR(400) NULL,
        HasFlaggedDescendant BIT           NOT NULL DEFAULT 0
    );

    -- ---- the terminal's zone (immediate parent) + that zone's tier ----
    DECLARE @ZoneId   BIGINT,
            @ZoneTier NVARCHAR(50);

    SELECT @ZoneId   = p.Id,
           @ZoneTier = plt.Code
    FROM Location.Location t
    INNER JOIN Location.Location p                  ON p.Id    = t.ParentLocationId
    INNER JOIN Location.LocationTypeDefinition pltd ON pltd.Id = p.LocationTypeDefinitionId
    INNER JOIN Location.LocationType plt            ON plt.Id  = pltd.LocationTypeId
    WHERE t.Id = @TerminalLocationId
      AND t.DeprecatedAt IS NULL
      AND p.DeprecatedAt IS NULL;

    -- Site / Enterprise zones (the fallback terminal) deliberately return
    -- NOTHING: the subtree is the whole plant, and scoping downtime plant-wide
    -- is never what the operator meant. The UI asks them to pick a terminal.
    IF @ZoneId IS NOT NULL AND @ZoneTier IN (N'Area', N'WorkCenter', N'Cell')
    BEGIN
        ;WITH Sub AS (
            SELECT l.Id,
                   CAST(RIGHT(N'0000' + CAST(l.SortOrder AS NVARCHAR(10)), 4) AS NVARCHAR(400)) AS SortPath
            FROM Location.Location l
            WHERE l.Id = @ZoneId
            UNION ALL
            SELECT c.Id,
                   CAST(s.SortPath + N'.' + RIGHT(N'0000' + CAST(c.SortOrder AS NVARCHAR(10)), 4) AS NVARCHAR(400))
            FROM Location.Location c
            INNER JOIN Sub s ON c.ParentLocationId = s.Id
            WHERE c.DeprecatedAt IS NULL
        )
        INSERT INTO @Options (ScopeLocationId, Code, Name, Kind, SortPath)
        SELECT l.Id, l.Code, l.Name, ltd.Name, s.SortPath
        FROM Sub s
        INNER JOIN Location.Location l                 ON l.Id    = s.Id
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id  = l.LocationTypeDefinitionId
        WHERE l.IsOeeEnabled = 1
          AND l.DeprecatedAt IS NULL
        OPTION (MAXRECURSION 8);  -- ISA-95 depth below an Area is <= 4 in any real plant; fail fast on a corrupt parent cycle
    END

    -- ---- which options are roll-ups (something flagged sits under them) ----
    UPDATE o
       SET HasFlaggedDescendant = 1
    FROM @Options o
    WHERE EXISTS (
        SELECT 1
        FROM @Options d
        CROSS APPLY Oee.ufn_OeeAncestors(d.ScopeLocationId) a
        WHERE a.AncestorLocationId = o.ScopeLocationId);

    -- ---- default selection ----
    -- 1. exactly one option -> that one.
    -- 2. the operator's active location, but ONLY when it is a leaf unit.
    --    On a split line the session cell IS the line, and preselecting the
    --    line would turn a side-A jam into a whole-line stop charged to every
    --    station (spec sec 3.4).
    -- 3. otherwise nothing -- the operator chooses.
    DECLARE @ActiveScope BIGINT = Oee.ufn_ResolveDowntimeScope(@ActiveCellLocationId);
    DECLARE @DefaultId   BIGINT = NULL;

    IF (SELECT COUNT(*) FROM @Options) = 1
        SET @DefaultId = (SELECT ScopeLocationId FROM @Options);
    ELSE IF @ActiveScope IS NOT NULL
         AND EXISTS (SELECT 1 FROM @Options
                     WHERE ScopeLocationId = @ActiveScope AND HasFlaggedDescendant = 0)
        SET @DefaultId = @ActiveScope;

    SELECT o.ScopeLocationId,
           o.Code,
           o.Name,
           o.Kind,
           CAST(CASE WHEN o.ScopeLocationId = @DefaultId THEN 1 ELSE 0 END AS BIT) AS IsDefault
    FROM @Options o
    ORDER BY o.SortPath, o.Code;
END;
GO
```

Replace the header's Description with:

```
-- Description:
--   The downtime "units" an operator standing at @TerminalLocationId may log
--   against, and which one the Downtime Manager should preselect.
--
--   v2.0 (OEE-enabled locations spec, 2026-09-16): one rule, no tier
--   branching -- the OEE-ENABLED locations in the terminal's ZONE subtree,
--   the zone itself included, in tree order. What each terminal sees is now
--   a consequence of the data:
--
--     Shared die cast / trim terminal (Area zone) -> the flagged machines.
--     Dedicated machine terminal (Cell zone)      -> that machine.
--     Unsplit M&A line terminal (WorkCenter zone) -> the line.
--     SPLIT line terminal                         -> the line AND its flagged
--                                                    stations (6MA: Machining,
--                                                    Assembly A, Assembly B).
--     Fallback / unregistered terminal (Site)     -> nothing, deliberately.
--
--   An Area with no flagged equipment now returns NOTHING, where v1.0 returned
--   the Area itself. Both prod trim shops carry active flagged machines
--   (2026-09-17 extract), so this does not arise in prod; an Area cannot be
--   flagged, by design.
--
--   Read proc: one result set, no status row, no OUTPUT params (FDS-11-011).
```

and add to the Change Log: `--   2026-09-17 - 2.0 - Flag-driven subtree + leaf-only preselection.`

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "120_DowntimeScope"
```

Expected: PASS on all 15 assertions, `0 failure(s)`.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Oee_DowntimeScope_ListForTerminal.sql sql/tests/0026_PlantFloor_Downtime_Shift/120_DowntimeScope_ListForTerminal.sql && git commit -m "feat(oee): downtime dropdown lists flagged units in the terminal's zone subtree"
```

---

## Task 5: Only a flagged location can take downtime

**Files:**
- Modify: `sql/migrations/repeatable/R__Oee_DowntimeEvent_Start.sql`
- Modify: `sql/migrations/repeatable/R__Oee_DowntimeEvent_RecordHistorical.sql`
- Modify: `sql/migrations/repeatable/R__Oee_DowntimeEvent_RecordApproximate.sql`
- Modify: `sql/tests/0026_PlantFloor_Downtime_Shift/{010,020,030,040,060,070,080,110}*.sql` (fixtures only)
- Create: `sql/tests/0090_Oee_EnabledLocations/040_write_validation.sql`

**Interfaces:**
- Consumes: `Location.Location.IsOeeEnabled` (Task 1), `test.OeeFixture_Build` (Task 2).
- Produces: all three writers reject an unflagged location with `Status = 0` and message `<Code> is not enabled for downtime.`

**Scope note:** Downtime Entry (`/shop-floor/downtime`) and End of Shift (`/shop-floor/end-of-shift`) are being retired separately (spec D11) and are **not** touched here. While Downtime Entry remains deployed, its dropdown (every Cell-tier location, terminals included) will hit this rejection. `Oee.EndOfShiftEntry_Submit` INSERTs directly and is unaffected.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0090_Oee_EnabledLocations/040_write_validation.sql`:

```sql
-- =============================================
-- File:         0090_Oee_EnabledLocations/040_write_validation.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Oee.DowntimeEvent_Start / _RecordHistorical / _RecordApproximate
--               accept a flagged location and refuse an unflagged one. The
--               refusal is what keeps downtime off terminals, stores and areas
--               now that the flag -- not the hierarchy -- decides.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0090_Oee_EnabledLocations/040_write_validation.sql';
GO

EXEC test.OeeFixture_Build;
GO

-- =============================================
-- Test 1: Start accepts a flagged station.
-- =============================================
DECLARE @A   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @r1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r1 EXEC Oee.DowntimeEvent_Start @LocationId = @A, @DowntimeSourceCodeId = @Src, @AppUserId = 1;
DECLARE @s1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r1);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] Start accepts a flagged station',
     @Expected = N'1', @Actual = @s1;
GO

-- =============================================
-- Test 2: Start refuses the terminal on that same line.
-- =============================================
DECLARE @T   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');
DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r2 EXEC Oee.DowntimeEvent_Start @LocationId = @T, @DowntimeSourceCodeId = @Src, @AppUserId = 1;
DECLARE @s2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r2);
DECLARE @m2 NVARCHAR(500) = (SELECT Message FROM @r2);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] Start refuses an unflagged terminal',
     @Expected = N'0', @Actual = @s2;
EXEC test.Assert_Contains @TestName = N'[DtWrite] the refusal says the location is not enabled for downtime',
     @Actual = @m2, @Expected = N'not enabled for downtime';

DECLARE @leaked INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE LocationId = @T);
EXEC test.Assert_RowCount @TestName = N'[DtWrite] the refused Start wrote no event',
     @ExpectedCount = 0, @ActualCount = @leaked;
GO

-- =============================================
-- Test 3: RecordHistorical refuses an unflagged location, accepts a flagged one.
-- =============================================
DECLARE @T  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');
DECLARE @MI BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
DECLARE @St DATETIME2(3) = DATEADD(HOUR, -3, SYSDATETIME());
DECLARE @En DATETIME2(3) = DATEADD(HOUR, -2, SYSDATETIME());

DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r3 EXEC Oee.DowntimeEvent_RecordHistorical
    @ScopeLocationId = @T, @StartedAtEt = @St, @EndedAtEt = @En, @AppUserId = 1;
DECLARE @s3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r3);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] RecordHistorical refuses an unflagged location',
     @Expected = N'0', @Actual = @s3;

DECLARE @r3b TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r3b EXEC Oee.DowntimeEvent_RecordHistorical
    @ScopeLocationId = @MI, @StartedAtEt = @St, @EndedAtEt = @En, @AppUserId = 1;
DECLARE @s3b NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r3b);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] RecordHistorical accepts a flagged station',
     @Expected = N'1', @Actual = @s3b;
GO

-- =============================================
-- Test 4: RecordApproximate, same pair.
-- =============================================
DECLARE @Store BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-E-STORE');
DECLARE @B     BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-B');

DECLARE @r4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r4 EXEC Oee.DowntimeEvent_RecordApproximate
    @ScopeLocationId = @Store, @DurationMinutes = 15, @AppUserId = 1;
DECLARE @s4 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r4);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] RecordApproximate refuses a storage location',
     @Expected = N'0', @Actual = @s4;

DECLARE @r4b TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r4b EXEC Oee.DowntimeEvent_RecordApproximate
    @ScopeLocationId = @B, @DurationMinutes = 15, @AppUserId = 1;
DECLARE @s4b NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r4b);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] RecordApproximate accepts a flagged station',
     @Expected = N'1', @Actual = @s4b;
GO

-- =============================================
-- Test 5: a flagged but DEPRECATED machine is refused (the existing not-found
-- check fires first; the outcome is what matters).
-- =============================================
DECLARE @M3  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-M3');
DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @r5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r5 EXEC Oee.DowntimeEvent_Start @LocationId = @M3, @DowntimeSourceCodeId = @Src, @AppUserId = 1;
DECLARE @s5 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r5);
EXEC test.Assert_IsEqual @TestName = N'[DtWrite] a deprecated machine is refused',
     @Expected = N'0', @Actual = @s5;
GO

EXEC test.OeeFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "040_write_validation"
```

Expected: FAIL on `[DtWrite] Start refuses an unflagged terminal` (Status comes back `1`), on `[DtWrite] the refused Start wrote no event`, and on both record-proc refusal assertions.

- [ ] **Step 3: Add the check to `DowntimeEvent_Start`**

In `sql/migrations/repeatable/R__Oee_DowntimeEvent_Start.sql`, immediately after the `IF @LocCode IS NULL` block ("Location not found or deprecated.") and before the `DowntimeSourceCode` existence check, insert:

```sql
        -- ---- the location must be an OEE / downtime unit (spec 2026-09-16 sec 3.6) ----
        IF NOT EXISTS (SELECT 1 FROM Location.Location
                       WHERE Id = @LocationId AND IsOeeEnabled = 1)
        BEGIN
            SET @Message = @LocCode + N' is not enabled for downtime.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeEvent', @EntityId = NULL,
                @LogEventTypeCode = N'DowntimeStarted', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
```

Bump the header to `-- Version:     1.2` and add to its Description block:
`--              v1.2 (2026-09-17): rejects a location that is not OEE-enabled.`

- [ ] **Step 4: Add the same check to both record procs**

In `sql/migrations/repeatable/R__Oee_DowntimeEvent_RecordHistorical.sql`, immediately after its `IF @LocCode IS NULL` block:

```sql
        -- ---- the location must be an OEE / downtime unit (spec 2026-09-16 sec 3.6) ----
        IF NOT EXISTS (SELECT 1 FROM Location.Location
                       WHERE Id = @ScopeLocationId AND IsOeeEnabled = 1)
        BEGIN
            SET @Message = @LocCode + N' is not enabled for downtime.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=NULL,
                @LogEventTypeCode=N'DowntimeRecordedHistorical', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END
```

Put the identical block in the identical position in `sql/migrations/repeatable/R__Oee_DowntimeEvent_RecordApproximate.sql` (its neighbouring blocks also use `@LogEventTypeCode = N'DowntimeRecordedHistorical'` — match whatever the block directly above uses).

Bump both headers to `-- Version:     1.2` with the same Change Log line.

- [ ] **Step 5: Point the existing downtime-test fixtures at a flagged location**

Seven files pick their fixture cell as "the lowest-Id Cell-tier location", which is not guaranteed to be flagged. In each of

`010_DowntimeEvent_lifecycle.sql`, `020_DowntimeReasonCode_Assign.sql`,
`030_DowntimeEvent_PLC_pattern.sql`, `040_DowntimeEvent_warmup_shotcount.sql`,
`070_OpenEvents_span_boundary.sql`, `080_audit_shape.sql`,
`110_DowntimeEvent_approximate.sql`

(all under `sql/tests/0026_PlantFloor_Downtime_Shift/`), replace:

```sql
DECLARE @CellId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 4 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
```

with:

```sql
-- An OEE-enabled unit, not merely "the lowest-Id Cell": since the 2026-09-16
-- flag change only a flagged location accepts downtime.
DECLARE @CellId BIGINT = (SELECT TOP 1 e.LocationId FROM Oee.ufn_ResolveOeeEquipment() e
    WHERE e.DefinitionCode = N'DieCastMachine' ORDER BY e.LocationId);
```

In `060_ShiftEndSummary_reads.sql` the same location is also the LOT's cell, so instead add a flag filter to its existing fixture query:

```sql
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)   -- uncapped: fixture PieceCount 50 exceeds the 24-30 seed basket caps
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
  AND EXISTS (SELECT 1 FROM Oee.ufn_ResolveOeeEquipment() e WHERE e.LocationId = eil.LocationId)  -- must accept downtime (2026-09-16 flag change)
ORDER BY eil.LocationId;
```

- [ ] **Step 6: Run both suites to verify they pass**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "Downtime"
```

Expected: `0 failure(s)` across `0026_PlantFloor_Downtime_Shift`.

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "0090_Oee"
```

Expected: `0 failure(s)`, including all nine assertions in `040_write_validation.sql`.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Oee_DowntimeEvent_Start.sql sql/migrations/repeatable/R__Oee_DowntimeEvent_RecordHistorical.sql sql/migrations/repeatable/R__Oee_DowntimeEvent_RecordApproximate.sql sql/tests/0090_Oee_EnabledLocations/040_write_validation.sql sql/tests/0026_PlantFloor_Downtime_Shift && git commit -m "feat(oee): downtime writers reject a location that is not OEE-enabled"
```

---

## Task 6: The availability roll-up

**Files:**
- Modify: `sql/migrations/repeatable/R__Oee_Shift_GetAvailability.sql` (full rewrite of the body)
- Modify: `sql/tests/0059_Oee_ShiftOverride/030_availability.sql` (result-set shape only)
- Create: `sql/tests/0090_Oee_EnabledLocations/030_rollup_availability.sql`

**Interfaces:**
- Consumes: `Oee.ufn_ResolveOeeEquipment`, `Oee.ufn_OeeAncestors` (Task 2); `Oee.ufn_ShiftWindowForLocation(@LocationId, @ShiftScheduleId, @BusinessDate)` → `LocationId, ShiftScheduleId, ScheduleName, BusinessDate, StartLocal, EndLocal, DurationMinutes, IsOverridden, ShiftOverrideId, OverrideReason` (unchanged).
- Produces: `Oee.Shift_GetAvailability @ShiftId BIGINT, @LocationId BIGINT = NULL` → one row per OEE unit, columns **in this order**:

```
ShiftId, ShiftScheduleId, ScheduleName, BusinessDate,
LocationId, LocationCode, LocationName,
StartLocal, EndLocal, PlannedMinutes,
DowntimeMinutes, UnexcusedDowntimeMinutes, RunMinutes,
Availability, DowntimeEventCount, IsOverridden, ShiftOverrideId, OverrideReason,
PlannedDowntimeMinutes, UnplannedDowntimeMinutes, BaseMinutes, IsRollup, ParentLocationId
```

The first 18 are unchanged in name, order and type; the last five are new. Every `INSERT … EXEC` caller must declare all 23.

**The maths, in one place:**
- A **leaf** (no flagged location beneath it) takes its own downtime plus the downtime of every flagged ancestor, merged by time so an overlap counts once. A minute covered by any planned (`IsExcused = 1`) event is planned; the rest of the covered minutes are unplanned.
- `BaseMinutes = PlannedMinutes − PlannedDowntimeMinutes`; `Availability = (BaseMinutes − UnplannedDowntimeMinutes) / BaseMinutes`, floored at 0, NULL when `BaseMinutes = 0`.
- A **roll-up** reports the unweighted mean of its direct flagged children. Its own events are not counted again — they are already inside every child. Its minute columns describe its own events only, and `IsRollup = 1` marks the row so nothing sums them.
- Coverage is measured on a minute grid (each minute's midpoint). Whole-minute events — every event the UI can produce — are exact.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0090_Oee_EnabledLocations/030_rollup_availability.sql`:

```sql
-- =============================================
-- File:         0090_Oee_EnabledLocations/030_rollup_availability.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Oee.Shift_GetAvailability once a line is split into stations:
--                 * planned downtime SHRINKS the base (it no longer counts
--                   against availability, which is the 2026-09-16 fix);
--                 * downtime on the LINE counts against EVERY station under it;
--                 * the line reports the unweighted MEAN of its stations;
--                 * a line event overlapping a station event counts once;
--                 * planned overlapping unplanned counts as planned;
--                 * a child with a zero base is excluded from the mean;
--                 * roll-ups nest.
--
--               The worked example is the spec's: an 8-hour shift, a 30-minute
--               lunch on the line, 5 minutes on Machining, 40 on Assembly A.
--                 Machining   445/450 = 0.9889
--                 Assembly A  410/450 = 0.9111
--                 Assembly B  450/450 = 1.0000
--                 Line        mean    = 0.9667
--
--               Fixture times are mixed-basis ON PURPOSE (Oee.Shift.ActualStart
--               is LOCAL, Oee.DowntimeEvent.StartedAt is UTC) -- see
--               0059_Oee_ShiftOverride/030_availability.sql for the same
--               convention.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0090_Oee_EnabledLocations/030_rollup_availability.sql';
GO

EXEC test.OeeFixture_Build;
GO

-- ---- shift fixture: an 06:00-14:00 day shift on 2026-09-14 ----
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_RU_Day');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_RU_Day';
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_RU_Day', N'Day 06-14', '06:00:00', '14:00:00', 127, '2020-01-01', 1);
GO
DECLARE @Sched BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_RU_Day');
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2026-09-14T06:00:00', '2026-09-14T14:00:00', N'TEST_RU shift');
GO

-- ---- downtime fixture: lunch on the line, a Machining stop, an Assembly A jam ----
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RU_Day');
DECLARE @L   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @MI  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
DECLARE @A   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @Lunch BIGINT = (SELECT TOP 1 Id FROM Oee.DowntimeReasonCode WHERE Code = N'LUNCH');

INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES
 -- 11:00-11:30 LOCAL lunch, logged against the LINE -> planned, and it must
 -- reach all three stations.
 (@L, @Lunch, @Shift,
  CAST(CAST('2026-09-14T11:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T11:30:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_RU_lunch'),
 -- 08:00-08:05 Machining stop, no reason -> unplanned.
 (@MI, NULL, @Shift,
  CAST(CAST('2026-09-14T08:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T08:05:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_RU_mi'),
 -- 09:00-09:40 Assembly A jam -> unplanned.
 (@A, NULL, @Shift,
  CAST(CAST('2026-09-14T09:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T09:40:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_RU_a');
GO

-- Result-set shape, declared once per test (23 columns).
-- =============================================
-- Test 1: the worked example -- per-station figures.
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RU_Day');
DECLARE @av TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @av EXEC Oee.Shift_GetAvailability @ShiftId = @Shift;

DECLARE @miBase NVARCHAR(10) = (SELECT CAST(BaseMinutes AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] planned lunch shrinks the base: 480 - 30 = 450',
     @Expected = N'450', @Actual = @miBase;

DECLARE @miPl NVARCHAR(10) = (SELECT CAST(PlannedDowntimeMinutes AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] the line lunch reaches Machining as planned downtime',
     @Expected = N'30', @Actual = @miPl;

DECLARE @miUn NVARCHAR(10) = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] Machining carries its own 5 unplanned minutes',
     @Expected = N'5', @Actual = @miUn;

DECLARE @miAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] Machining availability 445/450 = 0.9889',
     @Expected = N'0.9889', @Actual = @miAv;

DECLARE @aAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] Assembly A availability 410/450 = 0.9111',
     @Expected = N'0.9111', @Actual = @aAv;

DECLARE @bAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-B');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] Assembly B, hit only by the lunch, is 1.0000',
     @Expected = N'1.0000', @Actual = @bAv;

DECLARE @bUn NVARCHAR(10) = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-B');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] a station takes no unplanned time from its siblings',
     @Expected = N'0', @Actual = @bUn;
GO

-- =============================================
-- Test 2: the line is the mean of its three stations, and is marked a roll-up.
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RU_Day');
DECLARE @av2 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @av2 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift;

DECLARE @lAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av2 WHERE LocationCode = N'ZZ-OEE-L');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] the line is the mean of 0.9889 / 0.9111 / 1.0000 = 0.9667',
     @Expected = N'0.9667', @Actual = @lAv;

DECLARE @lRu NVARCHAR(10) = (SELECT CAST(IsRollup AS NVARCHAR(10)) FROM @av2 WHERE LocationCode = N'ZZ-OEE-L');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] the line row is flagged IsRollup',
     @Expected = N'1', @Actual = @lRu;

DECLARE @aRu NVARCHAR(10) = (SELECT CAST(IsRollup AS NVARCHAR(10)) FROM @av2 WHERE LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] a station is not a roll-up',
     @Expected = N'0', @Actual = @aRu;

DECLARE @aPar NVARCHAR(50) = (SELECT p.Code FROM @av2 a INNER JOIN Location.Location p ON p.Id = a.ParentLocationId
                              WHERE a.LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] a station reports its line as ParentLocationId',
     @Expected = N'ZZ-OEE-L', @Actual = @aPar;

-- An unsplit line still reports its own figure, unchanged by any of this.
DECLARE @pAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av2 WHERE LocationCode = N'ZZ-OEE-P');
EXEC test.Assert_IsEqual @TestName = N'[Rollup] an unsplit line with no downtime is still 1.0000',
     @Expected = N'1.0000', @Actual = @pAv;
GO

-- =============================================
-- Test 3: a line event overlapping a station event counts ONCE, and planned
-- wins over unplanned on the minutes they share.
--   Assembly B: 10:00-10:30 unplanned (station) while the line is stopped
--   10:15-10:45 planned. Union = 10:00-10:45 = 45 minutes, of which the
--   30 planned minutes are planned and the remaining 15 unplanned.
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RU_Day');
DECLARE @L2  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @B2  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-B');
DECLARE @Src2 BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @Lunch2 BIGINT = (SELECT TOP 1 Id FROM Oee.DowntimeReasonCode WHERE Code = N'LUNCH');

INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES
 (@B2, NULL, @Shift,
  CAST(CAST('2026-09-14T10:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T10:30:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src2, N'TEST_RU_overlap_station'),
 (@L2, @Lunch2, @Shift,
  CAST(CAST('2026-09-14T10:15:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T10:45:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src2, N'TEST_RU_overlap_line');

DECLARE @av3 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @av3 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift, @LocationId = @B2;

DECLARE @bTot NVARCHAR(10) = (SELECT CAST(DowntimeMinutes AS NVARCHAR(10)) FROM @av3);
EXEC test.Assert_IsEqual @TestName = N'[Rollup] overlapping line + station events are merged (30 lunch + 45 union = 75, not 90)',
     @Expected = N'75', @Actual = @bTot;

DECLARE @bPl NVARCHAR(10) = (SELECT CAST(PlannedDowntimeMinutes AS NVARCHAR(10)) FROM @av3);
EXEC test.Assert_IsEqual @TestName = N'[Rollup] a minute covered by a planned event counts as planned (30 + 30)',
     @Expected = N'60', @Actual = @bPl;

DECLARE @bUn3 NVARCHAR(10) = (SELECT CAST(UnplannedDowntimeMinutes AS NVARCHAR(10)) FROM @av3);
EXEC test.Assert_IsEqual @TestName = N'[Rollup] only the 15 uncovered minutes stay unplanned',
     @Expected = N'15', @Actual = @bUn3;
GO

-- =============================================
-- Test 4: @LocationId filters to one row, and an unknown shift is empty.
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RU_Day');
DECLARE @L4 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @av4 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @av4 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift, @LocationId = @L4;
DECLARE @c4 INT = (SELECT COUNT(*) FROM @av4);
EXEC test.Assert_RowCount @TestName = N'[Rollup] @LocationId returns exactly one row -- a roll-up still resolves its children internally',
     @ExpectedCount = 1, @ActualCount = @c4;
DECLARE @l4Av NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av4);
EXEC test.Assert_IsNotNull @TestName = N'[Rollup] and it still carries the mean', @Value = @l4Av;

DELETE FROM @av4;
INSERT INTO @av4 EXEC Oee.Shift_GetAvailability @ShiftId = -1;
DECLARE @c4b INT = (SELECT COUNT(*) FROM @av4);
EXEC test.Assert_RowCount @TestName = N'[Rollup] unknown shift -> empty result set',
     @ExpectedCount = 0, @ActualCount = @c4b;
GO

-- ---- cleanup ----
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'TEST_RU_%';
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_RU_Day');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_RU_Day';
EXEC test.OeeFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "030_rollup_availability"
```

Expected: the `INSERT … EXEC` fails with `Column name or number of supplied values does not match table definition` — the proc still returns 18 columns.

- [ ] **Step 3: Rewrite the proc**

In `sql/migrations/repeatable/R__Oee_Shift_GetAvailability.sql`, replace everything from `CREATE OR ALTER PROCEDURE` to the closing `GO` with:

```sql
CREATE OR ALTER PROCEDURE Oee.Shift_GetAvailability
    @ShiftId    BIGINT,
    @LocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- ActualStart is LOCAL (OI-38) -- cast straight to DATE, no conversion.
    DECLARE @SchedId      BIGINT;
    DECLARE @BusinessDate DATE;
    SELECT @SchedId      = s.ShiftScheduleId,
           @BusinessDate = CAST(s.ActualStart AS DATE)
    FROM Oee.Shift s
    WHERE s.Id = @ShiftId;

    IF @SchedId IS NULL
        RETURN;   -- empty result set = shift not found (no invented 404)

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    -- ================================================================
    -- 1. Every OEE unit, its window, and its nearest flagged parent
    -- ================================================================
    CREATE TABLE #Unit (
        LocationId               BIGINT        NOT NULL PRIMARY KEY,
        Code                     NVARCHAR(50)  NULL,
        Name                     NVARCHAR(200) NULL,
        ParentName               NVARCHAR(200) NULL,
        SortOrder                INT           NULL,
        FlaggedParentId          BIGINT        NULL,
        IsRollup                 BIT           NOT NULL DEFAULT 0,
        ShiftScheduleId          BIGINT        NULL,
        ScheduleName             NVARCHAR(100) NULL,
        BusinessDate             DATE          NULL,
        StartLocal               DATETIME2(3)  NULL,
        EndLocal                 DATETIME2(3)  NULL,
        PlannedMinutes           INT           NULL,
        StartUtc                 DATETIME2(3)  NULL,
        EndUtc                   DATETIME2(3)  NULL,
        IsOverridden             BIT           NULL,
        ShiftOverrideId          BIGINT        NULL,
        OverrideReason           NVARCHAR(500) NULL,
        PlannedDowntimeMinutes   INT           NOT NULL DEFAULT 0,
        UnplannedDowntimeMinutes INT           NOT NULL DEFAULT 0,
        DowntimeEventCount       INT           NOT NULL DEFAULT 0,
        AvailabilityRaw          DECIMAL(9,6)  NULL,
        Done                     BIT           NOT NULL DEFAULT 0
    );

    INSERT INTO #Unit (LocationId, Code, Name, ParentName, SortOrder, FlaggedParentId,
                       ShiftScheduleId, ScheduleName, BusinessDate, StartLocal, EndLocal,
                       PlannedMinutes, StartUtc, EndUtc, IsOverridden, ShiftOverrideId, OverrideReason)
    SELECT e.LocationId, e.Code, e.Name, e.ParentName, e.SortOrder,
           (SELECT TOP 1 a.AncestorLocationId
            FROM Oee.ufn_OeeAncestors(e.LocationId) a
            ORDER BY a.Distance),
           w.ShiftScheduleId, w.ScheduleName, w.BusinessDate, w.StartLocal, w.EndLocal,
           w.DurationMinutes,
           -- Local window -> UTC for comparison against Oee.DowntimeEvent.StartedAt.
           -- AT TIME ZONE is DST-aware, so this conversion is exact.
           CAST(w.StartLocal AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
           CAST(w.EndLocal   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
           w.IsOverridden, w.ShiftOverrideId, w.OverrideReason
    FROM Oee.ufn_ResolveOeeEquipment() e
    CROSS APPLY Oee.ufn_ShiftWindowForLocation(e.LocationId, @SchedId, @BusinessDate) w;

    -- A unit with a flagged unit beneath it reports the MEAN of those units.
    UPDATE u
       SET IsRollup = 1
    FROM #Unit u
    WHERE EXISTS (SELECT 1 FROM #Unit c WHERE c.FlaggedParentId = u.LocationId);

    -- ================================================================
    -- 2. Which locations' downtime each unit counts
    --    Itself always; for a LEAF also every flagged ancestor -- "if the line
    --    is down, all stations are impacted" (spec D5). A roll-up counts only
    --    its own events: its children already carry them, and adding them to
    --    the mean's input would double-count.
    -- ================================================================
    CREATE TABLE #Src (
        LocationId       BIGINT NOT NULL,
        SourceLocationId BIGINT NOT NULL,
        PRIMARY KEY (LocationId, SourceLocationId)
    );

    INSERT INTO #Src (LocationId, SourceLocationId)
    SELECT u.LocationId, u.LocationId FROM #Unit u;

    INSERT INTO #Src (LocationId, SourceLocationId)
    SELECT u.LocationId, a.AncestorLocationId
    FROM #Unit u
    CROSS APPLY Oee.ufn_OeeAncestors(u.LocationId) a
    WHERE u.IsRollup = 0
      AND a.AncestorLocationId <> u.LocationId;

    -- ================================================================
    -- 3. Downtime intervals, clipped to each unit's own window
    -- ================================================================
    CREATE TABLE #Iv (
        LocationId BIGINT       NOT NULL,
        EventId    BIGINT       NOT NULL,
        S          DATETIME2(3) NOT NULL,
        E          DATETIME2(3) NOT NULL,
        IsPlanned  BIT          NOT NULL,
        INDEX IX_Iv (LocationId, S)
    );

    INSERT INTO #Iv (LocationId, EventId, S, E, IsPlanned)
    SELECT u.LocationId,
           de.Id,
           CASE WHEN de.StartedAt > u.StartUtc THEN de.StartedAt ELSE u.StartUtc END,
           CASE WHEN COALESCE(de.EndedAt, @Now) < u.EndUtc THEN COALESCE(de.EndedAt, @Now) ELSE u.EndUtc END,
           COALESCE(rc.IsExcused, CAST(0 AS BIT))
    FROM #Unit u
    INNER JOIN #Src s               ON s.LocationId = u.LocationId
    INNER JOIN Oee.DowntimeEvent de ON de.LocationId = s.SourceLocationId
    LEFT  JOIN Oee.DowntimeReasonCode rc ON rc.Id = de.DowntimeReasonCodeId
    WHERE de.VoidedAt IS NULL
      AND de.StartedAt < u.EndUtc
      AND COALESCE(de.EndedAt, @Now) > u.StartUtc;

    -- ================================================================
    -- 4. Merge by TIME, not by adding events up: two events that overlap cost
    --    the operator one stretch of clock, and a minute covered by anything
    --    PLANNED is planned. Measured on a minute grid (each minute's
    --    midpoint), which is exact for the whole-minute events the UI records.
    -- ================================================================
    ;WITH D(n) AS (
        SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) v(n)
    ),
    Tally(n) AS (
        SELECT a.n + 10*b.n + 100*c.n + 1000*d.n
        FROM D a CROSS JOIN D b CROSS JOIN D c CROSS JOIN D d   -- 0..9999 minutes: ~6.9 days, ample for any shift + override
    ),
    Slot AS (
        SELECT u.LocationId, DATEADD(SECOND, 30 + 60 * t.n, u.StartUtc) AS Mid
        FROM #Unit u
        INNER JOIN Tally t ON t.n < DATEDIFF(MINUTE, u.StartUtc, u.EndUtc)
        WHERE EXISTS (SELECT 1 FROM #Iv iv WHERE iv.LocationId = u.LocationId)
    ),
    Cover AS (
        SELECT s.LocationId, s.Mid, MAX(CAST(iv.IsPlanned AS INT)) AS AnyPlanned
        FROM Slot s
        INNER JOIN #Iv iv ON iv.LocationId = s.LocationId
                         AND iv.S <= s.Mid
                         AND iv.E >  s.Mid
        GROUP BY s.LocationId, s.Mid
    )
    UPDATE u
       SET PlannedDowntimeMinutes   = x.Planned,
           UnplannedDowntimeMinutes = x.Unplanned
    FROM #Unit u
    INNER JOIN (
        SELECT LocationId,
               SUM(CASE WHEN AnyPlanned = 1 THEN 1 ELSE 0 END) AS Planned,
               SUM(CASE WHEN AnyPlanned = 0 THEN 1 ELSE 0 END) AS Unplanned
        FROM Cover
        GROUP BY LocationId
    ) x ON x.LocationId = u.LocationId;

    UPDATE u
       SET DowntimeEventCount = c.Cnt
    FROM #Unit u
    INNER JOIN (SELECT LocationId, COUNT(DISTINCT EventId) AS Cnt FROM #Iv GROUP BY LocationId) c
        ON c.LocationId = u.LocationId;

    -- ================================================================
    -- 5. Leaf availability. PLANNED downtime shrinks the base (a lunch break
    --    is not a loss); UNPLANNED downtime comes off what is left.
    -- ================================================================
    UPDATE #Unit
       SET AvailabilityRaw =
               CASE
                   WHEN PlannedMinutes - PlannedDowntimeMinutes <= 0 THEN NULL
                   WHEN PlannedMinutes - PlannedDowntimeMinutes - UnplannedDowntimeMinutes <= 0 THEN 0
                   ELSE CAST(PlannedMinutes - PlannedDowntimeMinutes - UnplannedDowntimeMinutes AS DECIMAL(19,6))
                        / (PlannedMinutes - PlannedDowntimeMinutes)
               END,
           Done = 1
    WHERE IsRollup = 0;

    -- ================================================================
    -- 6. Roll-ups, deepest first: the unweighted mean of the flagged units
    --    directly beneath. AVG ignores NULL children (a zero base), and a
    --    roll-up whose children are all NULL stays NULL.
    -- ================================================================
    WHILE EXISTS (SELECT 1 FROM #Unit WHERE Done = 0)
    BEGIN
        UPDATE u
           SET AvailabilityRaw = c.AvgAvailability,
               Done            = 1
        FROM #Unit u
        CROSS APPLY (
            SELECT AVG(ch.AvailabilityRaw) AS AvgAvailability
            FROM #Unit ch
            WHERE ch.FlaggedParentId = u.LocationId
        ) c
        WHERE u.Done = 0
          AND NOT EXISTS (SELECT 1 FROM #Unit ch WHERE ch.FlaggedParentId = u.LocationId AND ch.Done = 0);

        IF @@ROWCOUNT = 0 BREAK;   -- defensive: a parent cycle would otherwise spin
    END

    -- ================================================================
    -- 7. Result
    -- ================================================================
    SELECT
        @ShiftId                  AS ShiftId,
        u.ShiftScheduleId,
        u.ScheduleName,
        u.BusinessDate,
        u.LocationId,
        u.Code                    AS LocationCode,
        u.Name                    AS LocationName,
        u.StartLocal,
        u.EndLocal,
        u.PlannedMinutes,
        u.PlannedDowntimeMinutes + u.UnplannedDowntimeMinutes AS DowntimeMinutes,
        u.UnplannedDowntimeMinutes AS UnexcusedDowntimeMinutes,
        CASE WHEN b.BaseMinutes - u.UnplannedDowntimeMinutes < 0
             THEN 0 ELSE b.BaseMinutes - u.UnplannedDowntimeMinutes END AS RunMinutes,
        CAST(u.AvailabilityRaw AS DECIMAL(5,4)) AS Availability,
        u.DowntimeEventCount,
        u.IsOverridden,
        u.ShiftOverrideId,
        u.OverrideReason,
        u.PlannedDowntimeMinutes,
        u.UnplannedDowntimeMinutes,
        b.BaseMinutes,
        u.IsRollup,
        u.FlaggedParentId         AS ParentLocationId
    FROM #Unit u
    CROSS APPLY (
        SELECT CASE WHEN u.PlannedMinutes - u.PlannedDowntimeMinutes < 0
                    THEN 0 ELSE u.PlannedMinutes - u.PlannedDowntimeMinutes END AS BaseMinutes
    ) b
    WHERE @LocationId IS NULL OR u.LocationId = @LocationId
    ORDER BY u.ParentName, u.SortOrder, u.Name;
END
GO
```

Replace the header's two "DELIBERATE CHOICES" with four, and bump the version:

```
-- Version:     2.0
--
--   v2.0 (OEE-enabled locations spec, 2026-09-16). FOUR DELIBERATE CHOICES:
--
--   1. PLANNED time comes from the SCHEDULE (+ override), never from
--      Oee.Shift.ActualStart/ActualEnd. The runtime row records when the
--      boundary engine actually noticed the shift; a gateway outage that
--      backfills late must not shrink the planned denominator.
--
--   2. DOWNTIME is matched by TIME OVERLAP with the resolved window, NOT by
--      de.ShiftId -- when equipment is extended past the global boundary, the
--      downtime it incurs in the extension carries the NEXT shift's ShiftId.
--      CONSEQUENCE (needs a product decision -- see the report): where an
--      extension overlaps the next shift's window, those minutes count toward
--      BOTH shifts' availability for that equipment.
--
--   3. PLANNED DOWNTIME SHRINKS THE BASE (v2.0 -- a behaviour change).
--      Availability was (scheduled - ALL downtime) / scheduled, so a 30-minute
--      lunch counted against the operator like a breakdown. It is now
--      (base - unplanned) / base with base = scheduled - planned, which is
--      standard OEE and what MPP means by "planned". Expect higher numbers
--      wherever breaks are logged. "Planned" = DowntimeReasonCode.IsExcused.
--
--   4. A UNIT INHERITS ITS FLAGGED ANCESTORS' DOWNTIME, AND A UNIT WITH
--      FLAGGED UNITS BENEATH IT REPORTS THEIR MEAN. This is what lets one
--      line carry per-station units: a line-wide stop hits every station, a
--      side-A jam hits only side A, and the line's figure is the average of
--      its stations -- the only number that matches the parts not made. No
--      capacity weighting: WIP buffers decouple the stations, so a fixed
--      weight would be wrong minute to minute (spec D6). Overlapping events
--      are merged by clock so one stretch of downtime is counted once, and a
--      minute covered by anything planned counts as planned.
--
--   MINUTE GRID. Coverage is measured at each minute's midpoint, which is
--   exact for whole-minute events (everything the UI records) and drops a
--   sub-minute event that spans no midpoint -- the same rounding the old
--   DATEDIFF(MINUTE, ...) had.
```

and add to the Change Log: `--   2026-09-17 - 2.0 - Base-shrinking availability + ancestor inheritance + mean roll-up.`

- [ ] **Step 3b: Cover the two edge cases the roll-up can get wrong**

Create `sql/tests/0090_Oee_EnabledLocations/050_rollup_edge_cases.sql`:

```sql
-- =============================================
-- File:         0090_Oee_EnabledLocations/050_rollup_edge_cases.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Two things the mean can get wrong:
--                 1. A child whose base is ZERO (planned downtime swallowed the
--                    whole window) has NO availability, and must be left OUT of
--                    the mean rather than dragging it to 0.
--                 2. Roll-ups NEST: a line under a line reports the mean of its
--                    own stations, and the outer line then averages that.
--               The nested shape is built here rather than in the shared
--               fixture because it is not how any real MPP line is modelled --
--               prod's one line-under-a-line (AO-OP) was a mis-typed terminal,
--               corrected 2026-09-17. The rule still has to hold.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0090_Oee_EnabledLocations/050_rollup_edge_cases.sql';
GO

EXEC test.OeeFixture_Build;
GO

-- ---- an inner line under ZZ-OEE-L, with one station of its own ----
DECLARE @L       BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @LineDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionLine');
DECLARE @AsmDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'AssemblyStation');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, IsOeeEnabled)
VALUES (@LineDef, @L, N'OEE Inner Line', N'ZZ-OEE-L-INNER', N'OEE test fixture', 5, 1);
DECLARE @Inner BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-INNER');
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, IsOeeEnabled)
VALUES (@AsmDef, @Inner, N'OEE Inner Station', N'ZZ-OEE-L-INNER-S', N'OEE test fixture', 1, 1);
GO

-- ---- shift + downtime fixture ----
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_RE_Day');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_RE_Day';
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_RE_Day', N'Day 06-14', '06:00:00', '14:00:00', 127, '2020-01-01', 1);
GO
DECLARE @Sched BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_RE_Day');
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2026-09-14T06:00:00', '2026-09-14T14:00:00', N'TEST_RE shift');
GO

-- Assembly A is planned-down for the ENTIRE 06:00-14:00 window -> base 0.
-- Machining takes a 48-minute unplanned stop -> 432/480 = 0.9000.
-- Assembly B and the inner branch run clean -> 1.0000.
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RE_Day');
DECLARE @A   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DECLARE @MI  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-MI');
DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @Lunch BIGINT = (SELECT TOP 1 Id FROM Oee.DowntimeReasonCode WHERE Code = N'LUNCH');

INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
VALUES
 (@A, @Lunch, @Shift,
  CAST(CAST('2026-09-14T06:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T14:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_RE_allplanned'),
 (@MI, NULL, @Shift,
  CAST(CAST('2026-09-14T08:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  CAST(CAST('2026-09-14T08:48:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
  @Src, N'TEST_RE_mi');
GO

-- =============================================
-- Test 1: a zero-base child reports NULL and is excluded from the mean.
--   Machining 0.9000, Assembly B 1.0000, inner line 1.0000, Assembly A NULL
--   -> outer line = (0.9 + 1.0 + 1.0) / 3 = 0.9667
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RE_Day');
DECLARE @av TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @av EXEC Oee.Shift_GetAvailability @ShiftId = @Shift;

DECLARE @aBase NVARCHAR(10) = (SELECT CAST(BaseMinutes AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] a wholly planned-down station has a zero base',
     @Expected = N'0', @Actual = @aBase;

DECLARE @aAv DECIMAL(5,4) = (SELECT Availability FROM @av WHERE LocationCode = N'ZZ-OEE-L-A');
EXEC test.Assert_IsNull @TestName = N'[RollupEdge] and no availability at all', @Value = @aAv;

DECLARE @miAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] Machining 432/480 = 0.9000',
     @Expected = N'0.9000', @Actual = @miAv;

DECLARE @lAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av WHERE LocationCode = N'ZZ-OEE-L');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] the NULL child is left out of the mean: (0.9 + 1.0 + 1.0) / 3 = 0.9667',
     @Expected = N'0.9667', @Actual = @lAv;
GO

-- =============================================
-- Test 2: roll-ups nest -- the inner line is itself a mean, and reports the
-- outer line as its parent.
-- =============================================
DECLARE @Shift BIGINT = (SELECT s.Id FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId WHERE ss.Name = N'TEST_RE_Day');
DECLARE @av2 TABLE (ShiftId BIGINT, ShiftScheduleId BIGINT, ScheduleName NVARCHAR(100), BusinessDate DATE,
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200),
    StartLocal DATETIME2(3), EndLocal DATETIME2(3), PlannedMinutes INT,
    DowntimeMinutes INT, UnexcusedDowntimeMinutes INT, RunMinutes INT,
    Availability DECIMAL(5,4), DowntimeEventCount INT, IsOverridden BIT,
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
INSERT INTO @av2 EXEC Oee.Shift_GetAvailability @ShiftId = @Shift;

DECLARE @innerRu NVARCHAR(10) = (SELECT CAST(IsRollup AS NVARCHAR(10)) FROM @av2 WHERE LocationCode = N'ZZ-OEE-L-INNER');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] the inner line is itself a roll-up',
     @Expected = N'1', @Actual = @innerRu;

DECLARE @innerAv NVARCHAR(10) = (SELECT CAST(Availability AS NVARCHAR(10)) FROM @av2 WHERE LocationCode = N'ZZ-OEE-L-INNER');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] the inner line reports its own station',
     @Expected = N'1.0000', @Actual = @innerAv;

DECLARE @innerPar NVARCHAR(50) = (SELECT p.Code FROM @av2 a INNER JOIN Location.Location p ON p.Id = a.ParentLocationId
                                  WHERE a.LocationCode = N'ZZ-OEE-L-INNER');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] and hangs off the outer line',
     @Expected = N'ZZ-OEE-L', @Actual = @innerPar;

DECLARE @sPar NVARCHAR(50) = (SELECT p.Code FROM @av2 a INNER JOIN Location.Location p ON p.Id = a.ParentLocationId
                              WHERE a.LocationCode = N'ZZ-OEE-L-INNER-S');
EXEC test.Assert_IsEqual @TestName = N'[RollupEdge] the inner station belongs to the INNER line, not the outer one',
     @Expected = N'ZZ-OEE-L-INNER', @Actual = @sPar;
GO

-- ---- cleanup ----
DELETE FROM Oee.DowntimeEvent WHERE Remarks LIKE N'TEST_RE_%';
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_RE_Day');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_RE_Day';
EXEC test.OeeFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
```

Run it:

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "050_rollup_edge_cases"
```

Expected: PASS on all eight assertions. A failure on `[RollupEdge] the NULL child is left out of the mean` means the roll-up is averaging NULLs as zero — `AVG` ignores NULL, so the likely cause is a `COALESCE` added somewhere in step 6 of the proc.

- [ ] **Step 4: Widen the existing availability test's result-set declarations**

`sql/tests/0059_Oee_ShiftOverride/030_availability.sql` declares the result shape eight times. Confirm the count first:

```bash
grep -c "ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500));" sql/tests/0059_Oee_ShiftOverride/030_availability.sql
```

Expected: `8`. Then replace every occurrence of

```sql
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500));
```

with

```sql
    ShiftOverrideId BIGINT, OverrideReason NVARCHAR(500),
    PlannedDowntimeMinutes INT, UnplannedDowntimeMinutes INT, BaseMinutes INT,
    IsRollup BIT, ParentLocationId BIGINT);
```

and add a line to that file's header comment:

```
-- 2026-09-17: result set widened by five columns (PlannedDowntimeMinutes,
-- UnplannedDowntimeMinutes, BaseMinutes, IsRollup, ParentLocationId). These
-- fixtures use unexcused downtime only, so their availability figures are
-- unchanged by the base-shrinking formula.
```

- [ ] **Step 5: Run both availability suites to verify they pass**

```bash
cd sql/tests && powershell -File Run-Tests.ps1 -Filter "availability"
```

Expected: `0 failure(s)` for both `0059_Oee_ShiftOverride/030_availability.sql` (the existing six tests, unchanged figures) and `0090_Oee_EnabledLocations/030_rollup_availability.sql` (16 assertions).

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Oee_Shift_GetAvailability.sql sql/tests/0090_Oee_EnabledLocations/030_rollup_availability.sql sql/tests/0090_Oee_EnabledLocations/050_rollup_edge_cases.sql sql/tests/0059_Oee_ShiftOverride/030_availability.sql && git commit -m "feat(oee): availability roll-up -- ancestor inheritance, planned time shrinks the base, line = mean of stations"
```

---

## Task 7: The Ignition data layer (Named Queries + script modules)

**Files:**
- Modify: `ignition/projects/Core/ignition/named-query/location/Location_SaveAll/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/location/Location_SaveAll/resource.json`
- Create: `ignition/projects/Core/ignition/named-query/location/LocationTypeDefinition_GetOeeEligibility/query.sql`
- Create: `ignition/projects/Core/ignition/named-query/location/LocationTypeDefinition_GetOeeEligibility/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/ShiftOverride/code.py`

**Interfaces:**
- Consumes: `Location.Location_SaveAll` (`@IsOeeEnabled`), `Location.Location_Get` (`IsOeeEnabled`), `Location.LocationTypeDefinition_GetOeeEligibility` (Task 3); the widened `Oee.Shift_GetAvailability` result set (Task 6).
- Produces:
  - `BlueRidge.Location.Location.canBeOeeEnabled(locationTypeDefinitionId)` → `bool`.
  - `getOne(locationId)` result gains `"isOeeEnabled": bool`.
  - `emptyMeta(parentLocationId)` and `metaFromLocation(location)` both carry `"isOeeEnabled"`, so the editor's baseline and draft have identical shapes (a missing key on one side latches the dirty indicator).
  - `handleSaveAll` sends `isOeeEnabled`.

**Notes for whoever implements this:** all Named Queries live in the **Core** project — MPP and MPP_Config have none of their own and cannot see each other's. After writing the files run `.\scan.ps1` from the repo root; a new resource needs the scan (no gateway restart).

- [ ] **Step 1: Add the parameter to the `Location_SaveAll` NQ**

`ignition/projects/Core/ignition/named-query/location/Location_SaveAll/query.sql` becomes:

```sql
EXEC Location.Location_SaveAll
    @Id                       = :id,
    @ParentLocationId         = :parentLocationId,
    @LocationTypeDefinitionId = :locationTypeDefinitionId,
    @Name                     = :name,
    @Code                     = :code,
    @Description              = :description,
    @SortOrder                = :sortOrder,
    @AppUserId                = :appUserId,
    @AttributeValuesJson      = :attributeValuesJson,
    @IsOeeEnabled             = :isOeeEnabled
```

In its `resource.json`, append to the `parameters` array (sqlType 6 = Boolean, the type every other BIT parameter in the repo uses, e.g. `includeDescendants`):

```json
      {
        "type": "Parameter",
        "identifier": "isOeeEnabled",
        "sqlType": 6
      }
```

- [ ] **Step 2: Create the eligibility NQ**

`ignition/projects/Core/ignition/named-query/location/LocationTypeDefinition_GetOeeEligibility/query.sql`:

```sql
EXEC Location.LocationTypeDefinition_GetOeeEligibility
    @LocationTypeDefinitionId = :locationTypeDefinitionId
```

`ignition/projects/Core/ignition/named-query/location/LocationTypeDefinition_GetOeeEligibility/resource.json`:

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
      "timestamp": "2026-09-17T12:00:00Z"
    },
    "parameters": [
      {
        "type": "Parameter",
        "identifier": "locationTypeDefinitionId",
        "sqlType": 3
      }
    ]
  }
}
```

- [ ] **Step 3: Carry the flag through the Location script module**

Four edits plus one new function in `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py`.

In `getOne`, extend the returned dict (and its docstring's "Result keys" list) with the flag:

```python
        "icon":                     r.get("LocationTypeDefinitionIcon"),
        "deprecatedAt":             r.get("DeprecatedAt"),
        "isOeeEnabled":             bool(r.get("IsOeeEnabled")),
    }
```

In `emptyMeta`:

```python
        "description":              "",
        "sortOrder":                "",
        "isOeeEnabled":             False,
    }
```

In `metaFromLocation`:

```python
        "sortOrder":                _sortOrderForEditor(location.get("sortOrder")),
        "isOeeEnabled":             bool(location.get("isOeeEnabled")),
    }
```

In `handleSaveAll`, add the parameter to the `execMutation` map:

```python
            "appUserId":                userId,
            "attributeValuesJson":      attrsJson,
            "isOeeEnabled":             bool(meta.get("isOeeEnabled")),
        },
```

And add this function next to `eligibleTypes` (it is a thin wrapper — the rule itself is `Location.ufn_CanBeOeeEnabled`, in SQL):

```python
def canBeOeeEnabled(locationTypeDefinitionId):
    """May a location of this type be marked OEE / downtime enabled?

       Drives the enabled-state of the checkbox on Location Details. The rule
       lives in SQL (Location.ufn_CanBeOeeEnabled, read through
       Location.LocationTypeDefinition_GetOeeEligibility) so the screen and
       Location_SaveAll cannot drift apart -- only lines and equipment cells
       qualify; terminals, printers, scales, stores and hierarchy tiers do not.

       Args:
           locationTypeDefinitionId (long): the definition to test. None -> False.

       Returns:
           bool. Unknown definition -> False.
    """
    if locationTypeDefinitionId is None:
        return False
    row = BlueRidge.Common.Db.execOne(
        "location/LocationTypeDefinition_GetOeeEligibility",
        {"locationTypeDefinitionId": _u(locationTypeDefinitionId)},
    )
    if not row:
        return False
    return bool(row.get("CanBeOeeEnabled"))
```

- [ ] **Step 4: Widen the availability shape in the OEE script module**

In `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/ShiftOverride/code.py`, `_EMPTY_AVAILABILITY` must carry every key the widened result set returns, or a binding that traverses one of the new keys errors on the empty path:

```python
    "RunMinutes": 0, "Availability": None, "DowntimeEventCount": 0,
    "IsOverridden": False, "ShiftOverrideId": None, "OverrideReason": "",
    "PlannedDowntimeMinutes": 0, "UnplannedDowntimeMinutes": 0, "BaseMinutes": 0,
    "IsRollup": False, "ParentLocationId": None,
    "PlannedHoursText": "", "AvailabilityPct": "",
}
```

and in `_shapeAvailability`, after the existing `IsOverridden` coercion:

```python
    out["IsOverridden"] = bool(r.get("IsOverridden"))
    out["IsRollup"] = bool(r.get("IsRollup"))
    out["OverrideReason"] = r.get("OverrideReason") or ""
    return out
```

- [ ] **Step 5: Deploy the resources to the gateway**

```bash
powershell -File scan.ps1
```

Expected: the scan reports the changed/added resources and exits without error. A "Named query not found" in the gateway log afterwards means the new NQ folder is missing `resource.json` or was not scanned — check both files exist before moving on.

- [ ] **Step 6: Verify the eligibility read answers correctly**

There is no SQL test for the Python layer, so confirm the wiring from the Designer's script console (or any Perspective script action):

```python
import BlueRidge.Location.Location as L
print L.canBeOeeEnabled(8)    # DieCastMachine -> True
print L.canBeOeeEnabled(7)    # Terminal       -> False
print L.canBeOeeEnabled(None) # -> False
```

Expected: `True`, `False`, `False`. (Definition ids come from `Location.LocationTypeDefinition`; 7 = Terminal and 8 = DieCastMachine in the seeded set — confirm with `SELECT Id, Code FROM Location.LocationTypeDefinition` if unsure.)

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/location/Location_SaveAll ignition/projects/Core/ignition/named-query/location/LocationTypeDefinition_GetOeeEligibility ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Oee/ShiftOverride/code.py && git commit -m "feat(oee): Ignition data layer carries IsOeeEnabled and the widened availability shape"
```

---

## Task 8: The Config Tool checkbox (Designer)

**Files:**
- Designer only: `MPP_Config` → `BlueRidge/Views/Location/PlantHierarchy`

**Interfaces:**
- Consumes: `BlueRidge.Location.Location.canBeOeeEnabled` (Task 7); `view.custom.state.editDraft.isOeeEnabled`, which `metaFromLocation` / `emptyMeta` now seed (Task 7).
- Produces: an operator-visible way to flag a location — the last thing needed before a line can be split.

**This is an existing view, so it is edited in Designer, not as a file.** Designer's GSON serialization rewrites `=`, `'`, `<` and `>` as 6-character unicode escapes and its in-memory model fights on-disk edits, so a file edit here risks losing work.

- [ ] **Step 1: Pull the project into Designer**

Open the `MPP_Config` project in the Ignition Designer and confirm it has picked up the Task 7 scan (the script module `BlueRidge.Location.Location` should expose `canBeOeeEnabled`).

- [ ] **Step 2: Declare the custom-property default**

On the view root's `custom.state` object, add `isOeeEnabled: false` to **both** `selected` and `editDraft`, so both halves have the same shape before any load runs. Skipping this leaves the JSON-compare dirty indicator latched on the first selection.

The `custom.state` default becomes:

```json
{
  "editDraft": {
    "attributes": [], "code": "", "description": "", "id": null,
    "isOeeEnabled": false, "locationTypeDefinitionId": null,
    "name": "", "parentLocationId": null, "sortOrder": ""
  },
  "selected": {
    "attributes": [], "code": "", "description": "", "id": null,
    "isOeeEnabled": false, "locationTypeDefinitionId": null,
    "name": "", "parentLocationId": null, "sortOrder": ""
  }
}
```

- [ ] **Step 3: Add the checkbox to the Location Details panel**

Place an `ia.input.checkbox` below the Sort Order field, named `OeeEnabledCheck`:

- `props.text` = `OEE / downtime enabled`
- `props.selected` — **bidirectional** property binding to `view.custom.state.editDraft.isOeeEnabled`. The `bidirectional: true` flag goes *inside* the binding's `config` object; outside it, the binding silently stays one-way.
- `props.enabled` — expression binding:

```
runScript("BlueRidge.Location.Location.canBeOeeEnabled", 0, {view.custom.state.editDraft.locationTypeDefinitionId})
```

- Add a hint label beneath it: `Only production lines and equipment cells can be OEE enabled.`

- [ ] **Step 4: Save and verify in a live session**

Save the Designer project, then in the Config Tool at `/locations`:

1. Select a die cast machine → the checkbox is **enabled and ticked** (the migration flagged it).
2. Select a terminal → the checkbox is **disabled and clear**.
3. Select a production line → **enabled and ticked**.
4. Tick the flag on a cell that had it off, press Save → the toast says saved, and the dirty indicator **clears** (this is the state-shape check from Step 2).
5. Re-select another location and come back → the checkbox still reflects what was saved.
6. Confirm in SQL:

```sql
SELECT Code, Name, IsOeeEnabled FROM Location.Location WHERE Code = N'<the code you toggled>';
```

Expected: `IsOeeEnabled = 1`, and an `Audit.ConfigLog` row whose `NewValue` JSON contains `"IsOeeEnabled":1`.

- [ ] **Step 5: Check the tree's cell pickers did not change**

Adding station cells under a line makes them appear in `Location.Terminal_ListContextCells`, which feeds any screen where an operator picks a cell. M&A screens bind the cell to the zone (`Terminal.bindsCellToZone`), so nothing should show — **verify rather than assume** (spec section 4). With the Dev 6MA line still unsplit this is a no-op check today; re-run it in Task 9 after the verification line is split.

- [ ] **Step 6: Commit the Designer changes**

Designer writes the view to disk; commit exactly that file:

```bash
git status --short ignition/projects/MPP_Config
```

Confirm only `.../PlantHierarchy/view.json` changed (Designer can pickle live data into a view — if `git diff --stat` shows a large diff, inspect before committing), then:

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Location/PlantHierarchy/view.json && git commit -m "feat(oee): OEE / downtime enabled checkbox on the Plant Hierarchy editor"
```

---

## Task 9: End-to-end verification, docs, and the release gate

**Files:**
- Modify: `PROJECT_STATUS.md`
- Modify: `CLAUDE.md` (one new durable subsection)
- Create: `notes/2026-09-17_oee-enabled-locations-release-handoff.md`

**Interfaces:**
- Consumes: everything from Tasks 1 to 8.
- Produces: a verified split line in Dev, the prod preview-gate queries, and the durable rule written down where the next session will read it.

- [ ] **Step 1: Run the whole SQL suite**

```bash
cd sql/tests && powershell -File Run-Tests.ps1
```

Expected: `0 failure(s)`. An exit code of 1 with zero reported failures means a file's `sqlcmd` errored — usually a cleanup FK ordering problem — so read the output rather than trusting the summary line.

- [ ] **Step 2: Split a line in Dev and drive it through the UI**

Pick a Dev M&A line with a terminal (`MA2-6MACH` if Dev has been re-synced from prod, otherwise any line). In the Config Tool at `/locations`:

1. Create three cells under it: a CNC Machine named `Machining`, and two Assembly Stations named `Assembly A` / `Assembly B`. Use whatever codes the Jacques/Tom conventions settle on.
2. Tick **OEE / downtime enabled** on each, and Save.

Then at that line's terminal in the plant-floor app:

3. Open the Downtime Manager. Expect **four** options — the line, Machining, Assembly A, Assembly B — with **nothing preselected**.
4. Start downtime on Assembly A, and separately on Assembly B. Both must open: they are different locations, so the one-open-event-per-location rule does not collide.
5. Start downtime on the line while both are open. That must also be accepted.
6. End all three.

- [ ] **Step 3: Check the numbers the split produced**

```sql
DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC);
EXEC Oee.Shift_GetAvailability @ShiftId = @Shift;
```

Expected, for the line you split:
- one row per station plus one for the line;
- the stations carry `IsRollup = 0` and `ParentLocationId` = the line;
- the line carries `IsRollup = 1` and an `Availability` equal to the mean of its three stations;
- the downtime you logged **on the line** appears in every station's `PlannedDowntimeMinutes` / `UnplannedDowntimeMinutes`, not only in the line's own row.

Every other line, press and trim machine must be unchanged. Spot-check one press against the figure it reported before the change.

- [ ] **Step 4: Re-run the cell-picker check**

With the line now split, confirm the three new cells have not appeared anywhere an operator picks a cell (`Location.Terminal_ListContextCells` returns them, but M&A screens bind the cell to the zone). Open that line's Machining IN and Assembly OUT screens and confirm the cell context and the components sidebar are unchanged.

If they do appear, do **not** un-flag the cells — that would undo the feature. Raise it: the fix belongs in the picker's filter.

- [ ] **Step 5: Write the prod preview gate**

Create `notes/2026-09-17_oee-enabled-locations-release-handoff.md` with the two gate queries the release preview must print and Jacques must read before the window, plus what to expect:

````markdown
# OEE-enabled locations — release handoff

**Date:** 2026-09-17
**Spec:** `docs/superpowers/specs/2026-09-16-oee-enabled-locations-and-rollup-design.md`
**Migration:** `0090_location_is_oee_enabled`

## What ships

The `IsOeeEnabled` flag, the Config Tool checkbox, the flag-driven downtime
dropdown, the write-side check, and the availability roll-up. **No location is
split by this release** — the migration flags exactly what counts as equipment
today, so every dropdown and every availability figure stays as it is until
someone creates and flags station cells.

## Gate 1 — what the backfill will flag

```sql
;WITH Tree AS (
    SELECT l.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN l.Id END AS BIGINT) AS NearestWorkCenterId
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE l.ParentLocationId IS NULL
    UNION ALL
    SELECT c.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN c.Id ELSE t.NearestWorkCenterId END AS BIGINT)
    FROM Location.Location c
    INNER JOIN Tree t                              ON c.ParentLocationId = t.Id
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = c.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
)
SELECT l.Code, l.Name, ltd.Code AS Definition, p.Code AS ParentCode
FROM Location.Location l
INNER JOIN Tree t                              ON t.Id   = l.Id
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
LEFT  JOIN Location.Location p                 ON p.Id   = l.ParentLocationId
WHERE l.DeprecatedAt IS NULL
  AND lt.Code IN (N'WorkCenter', N'Cell')
  AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Receiving', N'Scale')
  AND COALESCE(t.NearestWorkCenterId, l.Id) = l.Id
ORDER BY p.Code, l.Code
OPTION (MAXRECURSION 20);
```

Expect every active die cast machine, the six trim machines (Bowl 1, Bowl 2,
WTB Blaster, Hangar Blaster A, Hangar Blaster B, 6MA Debur and Blast) and every
production / inspection line. Nothing else.

## Gate 2 — nothing becomes a roll-up on day one

```sql
SELECT p.Code AS FlaggedParent, c.Code AS FlaggedChild
FROM Location.Location p
INNER JOIN Location.Location c ON c.ParentLocationId = p.Id
WHERE p.DeprecatedAt IS NULL AND c.DeprecatedAt IS NULL
  AND p.IsOeeEnabled = 1 AND c.IsOeeEnabled = 1;
```

Expect **zero rows**. A row here means some location will stop reporting its own
availability and start reporting the mean of its children the moment this ships.
`AO-OP` under `MA2-6FBCHOP` was exactly that case and was corrected in prod on
2026-09-17 (it was a mis-typed Terminal).

## Gate 3 — recent downtime all lands on locations that will be flagged

```sql
SELECT l.Code, l.Name, COUNT(*) AS Events30d,
       SUM(CASE WHEN de.EndedAt IS NULL THEN 1 ELSE 0 END) AS StillOpen
FROM Oee.DowntimeEvent de
INNER JOIN Location.Location l ON l.Id = de.LocationId
WHERE de.StartedAt >= DATEADD(DAY, -30, SYSUTCDATETIME())
GROUP BY l.Code, l.Name
ORDER BY Events30d DESC;
```

Every row must appear in Gate 1's list. On 2026-09-17 that was true: `DC1-M11`,
`MA2-6MACH`, `DC3-M305`, `TRIM2-P01`, `T1-6MA-DB`, `DC1-M10`, `DC2-M202`.

## Known interaction

Downtime Entry (`/shop-floor/downtime`) offers every Cell-tier location,
terminals included. Once this ships, starting downtime from that screen against
anything unflagged is refused with "<Code> is not enabled for downtime." The
screen is slated for retirement; if it is still deployed, say so in the window
notes. End of Shift writes downtime directly and is unaffected.

## Ignition resources in this release

Core: `location/Location_SaveAll` (changed), `location/LocationTypeDefinition_GetOeeEligibility` (new),
`BlueRidge/Location/Location`, `BlueRidge/Oee/ShiftOverride`.
MPP_Config: `BlueRidge/Views/Location/PlantHierarchy`.
Build the scoped export from git with `tools/Build-ChangeExport.ps1`; Core imports first.
````

- [ ] **Step 6: Record the durable rule in CLAUDE.md**

Add this subsection to `CLAUDE.md` after the die-cast scrap subsection (it is a durable rule, not session state — volatile status goes in `PROJECT_STATUS.md`):

```markdown
### Downtime and OEE units are opt-in per location (2026-09-17)

`Location.Location.IsOeeEnabled` (migration `0090`) is **the** definition of a
downtime / OEE unit. It replaced the implicit "self-scoping" rule in
`Oee.ufn_ResolveDowntimeScope` / `ufn_ResolveOeeEquipment`, which made it
impossible for a cell under a production line to be a unit. Spec:
`docs/superpowers/specs/2026-09-16-oee-enabled-locations-and-rollup-design.md`.

- **The flag drives everything:** the downtime dropdown
  (`Oee.DowntimeScope_ListForTerminal` = flagged locations in the terminal's
  zone subtree), the equipment set, and who may take a `DowntimeEvent` (all
  three writers reject an unflagged location).
- **Settable only** on Cell / WorkCenter tier rows that are not a device or
  store — `Location.ufn_CanBeOeeEnabled`, enforced in `Location_SaveAll`.
  **Areas are deliberately not flaggable**, so there is no shop-level unit.
- **A line with flagged cells under it becomes a roll-up:** its downtime counts
  against every station beneath it, and its availability is the **unweighted
  mean** of those stations. No capacity weighting — WIP buffers decouple the
  stations, so a fixed weight is wrong minute to minute.
- **Planned downtime (`DowntimeReasonCode.IsExcused = 1`) shrinks the base**;
  unplanned downtime reduces availability. This changed in `Shift_GetAvailability`
  v2.0 — before it, a lunch break counted against the operator.
- **Splitting a line is a config act, not a deployment:** create the station
  cells, tick the flag. History does not shift — before the split every event
  was on the line, line downtime reaches every station, so each station
  reproduces the line's old figure and the mean of identical figures is that
  figure.
```

- [ ] **Step 7: Update `PROJECT_STATUS.md`**

Append to the recent-change narrative: what shipped, that no line is split yet, that splitting 6MA is a follow-up with MPP, and the two Dev-vs-prod drifts that clear on the prod re-sync (Dev's deprecated trim presses; Dev's `AO-OP` still typed as a line).

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md PROJECT_STATUS.md notes/2026-09-17_oee-enabled-locations-release-handoff.md && git commit -m "docs(oee): release handoff, durable rule, status"
```

---

## Sequencing notes

- **Tasks 1 → 2 → 3 are strictly ordered** (column, then the functions that read it, then the write path).
- **Tasks 4, 5 and 6 are independent of each other** once Task 2 lands, and can be worked in parallel by separate agents — they touch disjoint procs and disjoint test files.
- **Task 7 needs Tasks 3 and 6** (it consumes both new interfaces). **Task 8 needs Task 7.** **Task 9 needs everything.**
- After any SQL change, the repeatables must be redeployed before the Ignition layer is exercised: `Run-Tests.ps1` does this for the test DB; for `MPP_MES_Dev` use the deploy path in `sql_version_control_guide.md` rather than resetting (Dev carries hand-built config with no backups).
