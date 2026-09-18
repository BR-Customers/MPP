# Prod release handoff -- OEE-enabled locations (migration 0090)

**Written:** 2026-09-18, for the agent who builds and runs the prod release.
**Branch:** `jacques/working`, HEAD `17c06c0f` when written.
**Feature commits (all 2026-09-17):** `055fc905` (0090 + backfill), `9fd65ce5`, `edad0ab6`, `eed1dd9c`, `18ca680d`, `dd63f36f`, `dc180daf` (the new downtime refusal), `caded832`, `36bbb744`, `7a2734b7`, `667875e8` (Plant Hierarchy checkbox), `412d0914`, `b68519c7`, `59317a43`, `5282245c`, `06a1a20e`. Merged by `b51adc4f`, `4aeb4092`, `4c34ef77`, `47d21b1f`, `cc6d4b17`, `38a6776b`, `3120ebc2`; none of those merges changed a file beyond what the branch commits did.
**Spec / plan:** `docs/superpowers/specs/2026-09-16-oee-enabled-locations-and-rollup-design.md`, `docs/superpowers/plans/2026-09-17-oee-enabled-locations-and-rollup.md`.
**Release shape:** Jacques decided that everything from prod's baselines to HEAD ships as **one combined release**. Prod SQL is at `192c77c1` (migration `0089`), and prod's last Ignition import was the `aec53015` release (2026-09-16). This note covers only the OEE part of that bundle. Its gates and verification go into the combined runbook alongside the other handoffs.

This note is the scoping input for `prod-release-context-pack/07_writing_the_runbook.md`. It is **not** the runbook. The five deliverables in `01_the_release_contract.md` are still owed. The plan's Task 9 said to write `notes/2026-09-17_oee-enabled-locations-release-handoff.md`, but that file was never written. This note replaces it and carries its gate queries, with fixes.

---

## 0. Check these first

1. **Prod's baseline.** Confirm in the preview's `[3]` that prod is at `0089` and that `0090` is pending. For the combined release, `0090 0091 0093 0094 0095` should all be pending. There is no `0092` in the repo. The attribution handoff has already asked Jacques whether that gap is deliberate. A gap isn't a contiguity BLOCK, because nothing pending sits below the high-water mark.
2. **Run the pre-flight gates in § 3 against prod and show Jacques the output before the window.** The spec's prod claims (every trim machine flagged, every recent downtime on a flagged location, no line under a line) were checked against a **2026-09-17 extract**. `Deploy-ProdRelease.ps1` has **no 0090 gate**: its `[5]` section only has gates up to `0089`. Either run the § 3 queries by hand from SSMS, or add them to `[5]` under `$pendingIds -contains "0090_location_is_oee_enabled"`. Jacques decides which (see § 7, question 3).
3. **RESOLVED 2026-09-18 in `c8a18322`** (all 8 downtime-popup call sites now pass the acting user; see § 6.1). Original finding, kept for the record: **The Downtime Manager in the bundled release does not pass `appUserId`. This looks like a gap in `df99b8d5`, not in the OEE work, but it lands on the OEE screens.** Details are in § 6.1. Confirm or dismiss it before the window, because post-deploy verification step 4 would hit it live.

---

## 1. What it does, in plant terms

"Which things can downtime be logged against?" is now **a checkbox on each location**, not a rule hidden in a SQL function. That checkbox is `Location.Location.IsOeeEnabled`, labelled *OEE / downtime enabled* on the Config Tool's Plant Hierarchy editor.

**Day one should look like nothing happened.** Migration `0090` ticks exactly the locations that the old rule already treated as equipment: every active die cast machine, every active trim machine and every production / inspection line. So:

- **Downtime Manager dropdowns stay the same.** A shared die cast terminal still lists its presses. A trim terminal still lists its trim machines. An M&A terminal still has its line preselected.
- **Every existing downtime unit keeps its own availability figure.**

What is new:

- **The checkbox.** Only lines and equipment cells can be ticked. The checkbox is greyed out for terminals, printers, scales, stores, areas and the site. SQL refuses the tick on those types anyway, and it also refuses to **untick** a location that has an open downtime event ("Cannot turn off OEE / downtime for `<code>`: it has an open downtime event. End it first.").
- **A line can be split into stations.** This is the real purpose, and it happens after the release (6MA Cam Holder Line 1 first). You create station cells under the line and tick them. The Downtime Manager at that line then lists the line **plus** its stations, with nothing preselected. The line's availability becomes the unweighted mean of its stations, and downtime logged against the line counts against every station.
- **Planned downtime no longer counts against availability.** A downtime reason with `IsExcused` set (such as lunch or breaks) now shrinks the base instead of counting as lost time. **No screen shows availability today**: the only reader is `BlueRidge.Oee.ShiftOverride.availability`, and no view calls it. So no number anyone looks at changes.
- **The downtime writers now refuse a location that isn't ticked** (§ 3, Test 1).

---

## 2. Scope

### Versioned migrations
| Migration | Effect |
|---|---|
| `0090_location_is_oee_enabled` | `ALTER TABLE Location.Location ADD IsOeeEnabled BIT NOT NULL CONSTRAINT DF_Location_IsOeeEnabled DEFAULT 0`, then a backfill `UPDATE` that sets 1 on the old rule's equipment set. It prints the flagged count and any flagged-parent / flagged-child pairs, then records itself in `dbo.SchemaVersion`. |

**The backfill rule, exactly.** It walks the tree from every root (`ParentLocationId IS NULL`) and carries each row's *nearest WorkCenter at or above it*, deprecated rows included, which matches the old `ufn_ResolveDowntimeScope` v1.0. It then flags a row when all of these hold:

- it is active (`DeprecatedAt IS NULL`);
- its tier is `WorkCenter` or `Cell`;
- its definition is not `Terminal`, `Printer`, `InventoryLocation`, `Receiving` or `Scale`;
- it **is its own nearest WorkCenter, or has none above it**.

That is the old `Oee.ufn_ResolveOeeEquipment` v1.0 inlined, with **one deliberate difference: `Scale` is excluded** (the old rule would have admitted a Scale not under a line). Consequences:

- Lines are flagged.
- A die cast or trim machine under an Area is flagged.
- **A cell under a line is not flagged.** That covers M&A stations and `66B - Ins` (an InspectionStation under `66B-TC`).
- A line nested under another line **is** flagged, which makes the outer line a roll-up. `AO-OP` under `MA2-6FBCHOP` was exactly that case and was fixed in prod on 2026-09-17. See Gate D.

**Transaction and lock notes:**

- 0090 contains no `BEGIN TRAN`, `COMMIT`, `ROLLBACK`, `ALTER DATABASE`, `BACKUP` or `RECONFIGURE`, so the transaction-hostile gate won't fire.
- The file is ASCII only, with LF line endings.
- **Not metadata-only.** A `NOT NULL` + `DEFAULT` column add is metadata-only on Enterprise. CLAUDE.md says prod is Standard, where the add may rewrite the table. It is followed by a real `UPDATE` in any case. `Location.Location` holds a few hundred rows (Dev has 171 active), so either way this takes well under a second. The ALTER does take a **schema-modification lock on `Location.Location` until commit**, and nearly every screen and proc reads that table, so for the lock window plant reads of it wait. The precedent is `0083_location_is_cutover_destination`: the same shape (a `BIT NOT NULL` default on `Location.Location` plus a backfill), rehearsed at a 0.3 s lock window.

**Idempotency.** Each batch has its own guard:

- The column add is guarded on `COL_LENGTH`.
- The backfill is guarded on "0090 not yet in `SchemaVersion`", so a re-run never re-ticks a location someone unticked.
- The `SchemaVersion` insert is guarded too.
- The top-of-file `RETURN` exits only the first batch; the header says so.
- The report batch prints on every run and changes nothing.

`sql/seeds/034_seed_oee_enabled_backfill.sql` repeats the backfill for fresh builds. **It doesn't ship**, because `Deploy-ProdRelease.ps1` runs no seeds. Prod gets the migration's backfill, which is correct because prod's locations already exist.

### Repeatables (the OEE part; state relative to `192c77c1`)
| Object | File | State | Effect |
|---|---|---|---|
| `Oee.ufn_OeeAncestors` | `R__Oee_ufn_OeeAncestors.sql` | **NEW** | Inline TVF: the flagged strict ancestors of a location, walking past deprecated intermediates. |
| `Location.ufn_CanBeOeeEnabled` | `R__Location_ufn_CanBeOeeEnabled.sql` | **NEW** | The type guard (Cell/WorkCenter, not a device or store). |
| `Location.LocationTypeDefinition_GetOeeEligibility` | `R__Location_LocationTypeDefinition_GetOeeEligibility.sql` | **NEW** | Read proc behind the checkbox's enabled state. |
| `Oee.ufn_ResolveDowntimeScope` | `R__Oee_ufn_ResolveDowntimeScope.sql` | CHANGED v1.0 -> v2.0 | Nearest **flagged** location at or above; if there's none, the location itself (the old fallback). |
| `Oee.ufn_ResolveOeeEquipment` | `R__Oee_ufn_ResolveOeeEquipment.sql` | CHANGED v1.0 -> v2.0 | Returns the flagged, active locations. Also read by the unchanged `ShiftOverride_ListEquipment` / `ShiftOverride_Create`. |
| `Oee.DowntimeScope_ListForTerminal` | `R__Oee_DowntimeScope_ListForTerminal.sql` | CHANGED v1.0 -> v2.0 | Returns the flagged locations in the terminal's zone subtree, the zone included, in tree order. The default is the single row if there is only one, else the active cell's unit **only if it is a leaf**. |
| `Oee.DowntimeEvent_Start` | `R__Oee_DowntimeEvent_Start.sql` | CHANGED -> v1.2 | **Refuses** a location that isn't flagged. |
| `Oee.DowntimeEvent_RecordHistorical` | `R__Oee_DowntimeEvent_RecordHistorical.sql` | CHANGED -> v1.2 | **Refuses** a location that isn't flagged. |
| `Oee.DowntimeEvent_RecordApproximate` | `R__Oee_DowntimeEvent_RecordApproximate.sql` | CHANGED -> v1.2 | **Refuses** a location that isn't flagged. |
| `Oee.Shift_GetAvailability` | `R__Oee_Shift_GetAvailability.sql` | CHANGED -> v2.0.1 | Roll-up, planned time shrinking the base, and a minute-grid merge. Same parameters. The result set gains `PlannedDowntimeMinutes`, `UnplannedDowntimeMinutes`, `BaseMinutes`, `IsRollup` and `ParentLocationId`. |
| `Location.Location_Get` | `R__Location_Location_Get.sql` | CHANGED -> v2.1 | Adds the `IsOeeEnabled` column. |
| `Location.Location_SaveAll` | `R__Location_Location_SaveAll.sql` | CHANGED -> v1.3 | Optional `@IsOeeEnabled BIT = NULL`: NULL means 0 on create and **unchanged** on update. Adds the type guard, the "open downtime blocks untick" refusal, and `IsOeeEnabled` in the audit JSON. |
| `R__Descriptions_ExtendedProperties.sql` | -- | post-commit | Adds the `IsOeeEnabled` column description. Documentation only. **Four other undeployed commits also changed this file** (`0a629690` tool shot count, `cf001c27` 0091, `bca73704` 0094, `67947b9d` line-inventory docs). |

For the OEE part, `[4]` should show **3 NEW and 9 CHANGED**. None of these 12 files was touched by any other undeployed commit. The rest of the bundle's `[4]` list belongs to other features:

- **Cutover:** `Location_ListCutoverSources`, `Location_ListCutoverDestinationsForLine`, `Item_ListForCutoverLocation`.
- **Line inventory:** `Lot_GetLineInventory*`, `ItemLocation_*`, `Item_Get` / `Item_Update`.
- **Assembly OUT reprint:** `ShippingLabel_ListRecentByCell`.
- **Tool shot count:** `Tool_CorrectShotCount`.
- **Attribution:** `AppUser_GetActiveByAdAccount`.
- **Die-cast shift-output breakdown:** `DieCast_GetShiftOutputBreakdown`.
- **0095:** the deleted `Assembly_GetComponentProjection`.

**Function ordering.** Repeatables deploy as functions, then procs, each tier in filename order. `R__Oee_ufn_OeeAncestors` sorts before `R__Oee_ufn_ResolveDowntimeScope`, which calls it; a function gets no deferred name resolution. Both run after the migrations in `deploy.sql`, so the column exists when they compile.

### Ignition resources (the OEE part)
| Project | Resource | State | Also changed by another undeployed commit (`192c77c1..HEAD`) |
|---|---|---|---|
| Core | `named-query/location/LocationTypeDefinition_GetOeeEligibility` | NEW | -- |
| Core | `named-query/location/Location_SaveAll` | MOD (`isOeeEnabled`, sqlType 6) | -- |
| Core | `script-python/BlueRidge/Location/Location` | MOD | **`1da26dfb` (cutover location-first), `df99b8d5` (attribution)** |
| Core | `script-python/BlueRidge/Oee/Downtime` | MOD (`getScopeForPick`) | **`df99b8d5`** |
| Core | `script-python/BlueRidge/Oee/ShiftOverride` | MOD (availability shape) | **`df99b8d5`** |
| MPP | `views/BlueRidge/Components/Popups/DowntimeManager` | MOD (`pickScope`) | -- |
| MPP | `views/BlueRidge/Views/ShopFloor/AppHeaderLarge` | MOD (the header downtime badge resolves from the session cell) | **`ea4f05eb` (line inventory: removes the `lowInventoryWarning` handler)** |
| MPP_Config | `views/BlueRidge/Views/Location/PlantHierarchy` | MOD (checkbox) | **`df99b8d5`** |

The plan's resource list (Task 9) predates `412d0914` and **leaves out the two MPP views**. This table is the correct one. There are no deletions. Import **Core first**.

The working tree has uncommitted `resource.json` rewrites on several of these, which are Gateway manifest churn. `Build-ChangeExport.ps1` builds from git, so they don't ship, but don't `git add` them in passing.

Because five of the eight resources are shared with other features, **the OEE Ignition half can't be shipped or rolled back on its own.** Each export carries a file's whole content at the release commit. This matches the attribution handoff's § 4.

### Ships nothing
- `sql/seeds/034_seed_oee_enabled_backfill.sql`.
- `sql/tests/0090_Oee_EnabledLocations/*`, `sql/tests/helpers/0090_fixture_oee_locations.sql`, `sql/tests/0003_Location/070_Location_IsOeeEnabled.sql`, the fixture edits to `sql/tests/0026_PlantFloor_Downtime_Shift/*` and `sql/tests/0059_Oee_ShiftOverride/030_availability.sql`.
- `MPP_MES_DATA_MODEL.md`, the plan and spec, and `notes/`.

---

## 3. Risk -- the four tests

### Test 1: does anything now refuse what it used to allow? **Yes.**

| Now refuses | Message | Who can hit it |
|---|---|---|
| `Oee.DowntimeEvent_Start` on an unflagged location | "`<Code>` is not enabled for downtime." | (a) **The Downtime Manager: never.** Its dropdown lists only flagged locations. (b) **Downtime Entry (legacy)** (`/shop-floor/downtime`, still in the AppMenu as "Downtime Entry (legacy)"). Its dropdown is *every* Cell-tier location, terminals and printers included. After the release only presses and trim machines work there; everything else is refused. (c) The PLC watcher `BlueRidge.Oee.DowntimePlc`: its `_WATCH` list is empty today, so nothing is affected. Commissioning must use flagged cells. |
| `Oee.DowntimeEvent_RecordHistorical` / `_RecordApproximate` on an unflagged location | same | Only the Downtime Editor (Add Past Event), which takes its scope from the Manager's dropdown, so it can't reach an unflagged location. |
| `Location.Location_SaveAll` with the tick on an ineligible type | "This location type cannot be OEE / downtime enabled (only lines and equipment cells can)." | Only the new checkbox, which is greyed out for those types. |
| `Location.Location_SaveAll` untick with open downtime | "Cannot turn off OEE / downtime for `<code>`: it has an open downtime event. End it first." | Only the new checkbox. |
| `Oee.ShiftOverride_Create` on a `Scale` | the existing "not equipment" message | Theoretical. Gate E shows whether any override would drop out. |

**Not refused, but worth knowing:** End of Shift (`/shop-floor/end-of-shift` -> `Oee.EndOfShiftEntry_Submit`) inserts `DowntimeEvent` rows directly and **was not given the check**, on purpose (spec D11). It still writes against unflagged cells, and those rows never count toward availability. They didn't count before either.

**Would downtime entry break on day one?** Three pre-flight queries answer that against prod. The file below has them all in one batch. It runs **before** the deploy: it needs neither the new column nor the new functions. It is read-only; the only writes are to a `#temp` table. Running it through `Deploy-ProdRelease.ps1`'s `Q` helper or SSMS works as-is. From `sqlcmd`, pass `-I`, because it needs QUOTED_IDENTIFIER.

```sql
SET NOCOUNT ON;
-- Prelude: the set 0090 WILL flag (mirror of 0090 section 2).
IF OBJECT_ID('tempdb..#WillFlag') IS NOT NULL DROP TABLE #WillFlag;
;WITH Tree AS (
    SELECT l.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN l.Id END AS BIGINT) AS NearestWorkCenterId
    FROM Location.Location l
    JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE l.ParentLocationId IS NULL
    UNION ALL
    SELECT c.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN c.Id ELSE t.NearestWorkCenterId END AS BIGINT)
    FROM Location.Location c
    JOIN Tree t                              ON c.ParentLocationId = t.Id
    JOIN Location.LocationTypeDefinition ltd ON ltd.Id = c.LocationTypeDefinitionId
    JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
)
SELECT l.Id INTO #WillFlag
FROM Location.Location l
JOIN Tree t                              ON t.Id   = l.Id
JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
WHERE l.DeprecatedAt IS NULL
  AND lt.Code IN (N'WorkCenter', N'Cell')
  AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Receiving', N'Scale')
  AND COALESCE(t.NearestWorkCenterId, l.Id) = l.Id
OPTION (MAXRECURSION 20);

-- Gate A -- what the backfill will flag. Read it; its row count is what 0090 prints.
SELECT ltd.Code AS Definition, p.Code AS Parent, l.Code, l.Name
FROM #WillFlag w
JOIN Location.Location l                 ON l.Id   = w.Id
JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
LEFT JOIN Location.Location p            ON p.Id   = l.ParentLocationId
ORDER BY ltd.Code, p.Code, l.Code;

-- Gate B -- downtime (open, or started in the last 30 days) on a location that will NOT be
-- flagged. Expect 0 rows. A row = someone is logging there today and will be refused tomorrow
-- (or has an open event the Downtime Manager will no longer show).
SELECT l.Code, l.Name, ltd.Code AS Definition, COUNT(*) AS Events,
       SUM(CASE WHEN de.EndedAt IS NULL THEN 1 ELSE 0 END) AS StillOpen,
       MAX(de.StartedAt) AS LatestStartUtc
FROM Oee.DowntimeEvent de
JOIN Location.Location l                 ON l.Id   = de.LocationId
JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
WHERE de.VoidedAt IS NULL
  AND (de.EndedAt IS NULL OR de.StartedAt >= DATEADD(DAY, -30, SYSUTCDATETIME()))
  AND NOT EXISTS (SELECT 1 FROM #WillFlag w WHERE w.Id = de.LocationId)
GROUP BY l.Code, l.Name, ltd.Code
ORDER BY Events DESC;

-- Gate C -- per terminal, the Downtime Manager dropdown today (v1.0) vs after (v2.0).
-- Expect 0 LOST rows. A LOST row = that terminal loses a choice it has today; if it was the
-- only choice, the terminal can no longer log downtime at all. GAINED rows: read them.
;WITH Term AS (
    SELECT t.Id AS TerminalId, t.Code AS TerminalCode, p.Id AS ZoneId, p.Code AS ZoneCode, plt.Code AS ZoneTier
    FROM Location.Location t
    JOIN Location.LocationTypeDefinition tltd ON tltd.Id = t.LocationTypeDefinitionId
    JOIN Location.Location p                  ON p.Id    = t.ParentLocationId
    JOIN Location.LocationTypeDefinition pltd ON pltd.Id = p.LocationTypeDefinitionId
    JOIN Location.LocationType plt            ON plt.Id  = pltd.LocationTypeId
    WHERE tltd.Code = N'Terminal' AND t.DeprecatedAt IS NULL AND p.DeprecatedAt IS NULL
      AND plt.Code IN (N'Area', N'WorkCenter', N'Cell')
), Sub AS (
    SELECT tm.TerminalId, tm.ZoneId AS Id, 0 AS Depth FROM Term tm
    UNION ALL
    SELECT s.TerminalId, c.Id, s.Depth + 1
    FROM Sub s JOIN Location.Location c ON c.ParentLocationId = s.Id
    WHERE c.DeprecatedAt IS NULL
), OldAreaCells AS (          -- v1.0, Area zone: equipment cells beneath the area
    SELECT s.TerminalId, s.Id AS ScopeId
    FROM Sub s
    JOIN Term tm ON tm.TerminalId = s.TerminalId AND tm.ZoneTier = N'Area'
    JOIN Location.Location l                 ON l.Id   = s.Id
    JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE s.Depth > 0 AND lt.Code = N'Cell'
      AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Scale')
), OldOpt AS (                -- v1.0: those cells, else the zone itself
    SELECT TerminalId, ScopeId FROM OldAreaCells
    UNION
    SELECT tm.TerminalId, tm.ZoneId FROM Term tm
    WHERE NOT EXISTS (SELECT 1 FROM OldAreaCells o WHERE o.TerminalId = tm.TerminalId)
), NewOpt AS (                -- v2.0: flagged locations in the zone subtree, zone included
    SELECT s.TerminalId, s.Id AS ScopeId FROM Sub s
    WHERE EXISTS (SELECT 1 FROM #WillFlag w WHERE w.Id = s.Id)
), Diff AS (
    SELECT TerminalId, ScopeId, N'LOST' AS Change
    FROM (SELECT TerminalId, ScopeId FROM OldOpt EXCEPT SELECT TerminalId, ScopeId FROM NewOpt) x
    UNION ALL
    SELECT TerminalId, ScopeId, N'GAINED'
    FROM (SELECT TerminalId, ScopeId FROM NewOpt EXCEPT SELECT TerminalId, ScopeId FROM OldOpt) y
)
SELECT d.Change, tm.TerminalCode, tm.ZoneCode, tm.ZoneTier, l.Code AS ScopeCode, l.Name AS ScopeName
FROM Diff d
JOIN Term tm             ON tm.TerminalId = d.TerminalId
JOIN Location.Location l ON l.Id = d.ScopeId
ORDER BY d.Change DESC, tm.TerminalCode, l.Code
OPTION (MAXRECURSION 8);

-- Gate D -- a will-be-flagged location under a will-be-flagged ancestor, at ANY depth: the
-- ancestor stops reporting its own availability and reports the mean of its children on day
-- one, and its terminals lose their preselection. Expect 0 rows.
;WITH Up AS (
    SELECT w.Id AS DescId, l.ParentLocationId AS AncId
    FROM #WillFlag w JOIN Location.Location l ON l.Id = w.Id
    WHERE l.ParentLocationId IS NOT NULL
    UNION ALL
    SELECT u.DescId, p.ParentLocationId
    FROM Up u JOIN Location.Location p ON p.Id = u.AncId
    WHERE p.ParentLocationId IS NOT NULL
)
SELECT a.Code AS BecomesRollup, d.Code AS FlaggedDescendant
FROM Up u
JOIN #WillFlag wa        ON wa.Id = u.AncId
JOIN Location.Location a ON a.Id  = u.AncId
JOIN Location.Location d ON d.Id  = u.DescId
ORDER BY a.Code, d.Code
OPTION (MAXRECURSION 20);

-- Gate E -- live shift overrides on a location that will NOT be flagged (they drop out of
-- availability and out of the Shift Overrides equipment picker). Expect 0 rows.
SELECT l.Code, so.BusinessDate, so.StartTime, so.EndTime, so.Reason
FROM Oee.ShiftOverride so
JOIN Location.Location l ON l.Id = so.LocationId
WHERE so.DeprecatedAt IS NULL
  AND NOT EXISTS (SELECT 1 FROM #WillFlag w WHERE w.Id = so.LocationId);
```

**How the gates relate to the plan's.**

- Gate A is the plan's Gate 1.
- Gate B is the plan's Gate 3, rewritten to return only the problem rows, so "expect 0" can be read at a glance.
- **Gate C is new.** It is the question "will the plant floor's downtime entry break on day one", asked terminal by terminal. It catches the three ways a terminal can lose a choice:
  - an Area whose only "equipment" is unflagged, where v1.0 fell back to the Area itself;
  - a `Receiving` or non-equipment cell under an area, which v1.0 listed and v2.0 does not;
  - a dedicated terminal whose zone is a cell under a line.
- Gate D is the plan's Gate 2, moved **before** the deploy by walking `#WillFlag` instead of calling `Oee.ufn_OeeAncestors`, which doesn't exist on prod yet. 0090's own printed "nesting" line checks **direct** children only; Gate D checks every depth.
- **Gate E is new.**

**Suggested severities if they are coded into `[5]`:**

| Gate | Severity |
|---|---|
| B, any `StillOpen > 0` | BLOCK |
| B, other rows | WARN |
| C, any LOST | WARN, with the terminal list |
| D, any row | WARN (the spec says zero after the AO-OP fix) |
| E | WARN |
| A | INFO (the count) |

Jacques decides.

**On Dev (2026-09-18, read-only):**

- **A:** 44 rows (22 `DieCastMachine`, 21 `ProductionLine`, 1 `InspectionLine`). This equals Dev's actual flags exactly: 0 flagged-but-not-predicted, 0 predicted-but-not-flagged.
- **B:** 0 rows.
- **C:** `LOST` `TRIM1-T1`/`TRIM1`, `TRIM2-T1`/`TRIM2`, `TT-00` (a Dev test terminal under an unnamed test Area). `GAINED` `AO-OP` at `MA2-6FBCHOP-AOUT` and `-MIN`.
- **D:** `MA2-6FBCHOP` -> `AO-OP`.
- **E:** 0 rows.

C and D are exactly the two Dev-only drifts the spec names (spec § 3.1: trim presses deprecated in the Dev seed; `AO-OP` still a ProductionLine). **The spec says prod has neither.** The prod run is what confirms that.

### Test 2: is any of it shared code? **Yes.**
- **`BlueRidge.Location.Location` ships whole.** Its callers include the Config Tool Plant Hierarchy, the die-cast machine dropdown (`getDieCastMachineDropdown`) and the cutover screens. It carries the cutover and attribution changes too.
- **`BlueRidge.Oee.Downtime`** backs the Downtime Manager, the Downtime Editor, and the **header downtime badge on every shop-floor page** (`AppHeaderLarge`).
- **`AppHeaderLarge`** is on every shop-floor page. This release changes its badge binding from `getDefaultScopeIdForTerminal(terminal, cell)` to `resolveScope(session cell)`. Where the session cell is cleared (shared die cast before a press is picked, trim, fallback), both give no badge. On a dedicated screen both give the line or press.
- **`BlueRidge.Oee.ShiftOverride`** backs the Config Tool Shift Overrides screen.
- **In SQL, `Oee.ufn_ResolveOeeEquipment` changed underneath two procs that did not:** `ShiftOverride_ListEquipment` (the picker) and `ShiftOverride_Create` (the validation).

Post-deploy verification must exercise one surface that isn't the feature (§ 5, steps 6–7).

### Test 3: is the schema change metadata-only? **No, but it is small.** See § 2: a `NOT NULL` column plus a backfill `UPDATE` on a table of a few hundred rows, with a schema lock on `Location.Location` for the lock window. The 0083 precedent rehearsed at 0.3 s. No index or constraint beyond the default. Nothing is dropped, so rollback doesn't need the backup.

### Test 4: does old Ignition keep working against new SQL? **Yes. New Ignition against old SQL does not.**
- **Old Ignition, new SQL.**
  - The old `Location_SaveAll` NQ doesn't pass `@IsOeeEnabled`, so NULL means **unchanged** on update and **0 on create**. A location *created* in the Config Tool between the SQL step and the import is born unflagged; tick it afterwards.
  - `DowntimeScope_ListForTerminal`, `Shift_GetAvailability` and the three writers keep their parameters. `Location_Get` and `Shift_GetAvailability` only add columns, which callers read by name.
  - The old Downtime Manager feeds the operator's pick back in as the "active cell". Under the v2.0 default rule that still preselects the pick wherever it is a leaf, which is **every** unit on day one (Gate D = 0). It would misbehave only at a **split** line, and no line is split until after the release.
  - The legacy Downtime Entry refusals (Test 1) start the moment the SQL commits, whichever Ignition is loaded.
- **New Ignition, old SQL.**
  - The Plant Hierarchy checkbox calls `LocationTypeDefinition_GetOeeEligibility`, which doesn't exist yet.
  - Worse, **every Plant Hierarchy save fails**, because the new `Location_SaveAll` NQ passes `@IsOeeEnabled` to a proc that has no such parameter.
  - Downtime Manager and header are unaffected.
- **Deploy SQL first.** After that, the SQL and Ignition steps don't have to happen together, as far as the OEE part goes. The combined release has its own Test 4 constraints (the attribution handoff § 5).

### Rollback (the OEE part)
- **Before commit:** nothing to do.
- **After commit, SQL:**
  - Re-apply the 9 CHANGED repeatables from `192c77c1` (`git show 192c77c1:<file>`), in filename order. `R__Oee_ufn_ResolveDowntimeScope` must go before `R__Oee_ufn_ResolveOeeEquipment`, because v1.0 of the latter calls the former.
  - Optionally drop the 3 NEW objects. Nothing at v1.0 references them.
  - **Leave the column.** Old code ignores it, and dropping it means dropping `DF_Location_IsOeeEnabled` first for no benefit.
- **Ignition:** the new `Location_SaveAll` NQ must **also** go back, or Plant Hierarchy saves fail against the v1.0 proc ("too many arguments"). Since `Location/Location`, `Oee/*` and `PlantHierarchy` are shared with attribution and cutover, a partial OEE rollback isn't practical. It's the combined release's rollback.
- **No data to unwind.** Ticks set through the checkbox after the release are real, audited changes.

---

## 4. Rehearsal expectations

Rehearse at prod's exact state (`05_local_rehearsal.md`): a temp worktree at `192c77c1` plus `Reset-DevDatabase.ps1` under a **unique throwaway name**, not `MPP_MES_Test`. Then preview and rehearse from the release commit. Expected for the OEE part:

- **`[3]`:** `0090_location_is_oee_enabled` pending, among `0090 0091 0093 0094 0095`.
- **`[4]`:** 3 NEW + 9 CHANGED as in § 2, plus the other features' objects.
- **`[5]`:** nothing from 0090 unless the gates in § 3 have been coded in.
- **Rehearsal log:** 0090 prints `OEE-enabled locations after backfill: <N>`, where N is the Gate A row count (**the local rehearsal DB's** count, not prod's), and `Flagged locations that already have a flagged child (become roll-ups): <list>`. A ProdSim built from the seed at `192c77c1` will show `MA2-6FBCHOP` there (the Dev-only `AO-OP`). Against prod, expect `(none)`.
- **Lock window:** expect well under a second from 0090. The combined release's figure will be dominated by whichever migration is heaviest.

---

## 5. Post-deploy verification (prod)

1. **Flags match the gate.**
   ```sql
   SELECT COUNT(*) AS Flagged FROM Location.Location WHERE IsOeeEnabled = 1 AND DeprecatedAt IS NULL;   -- = Gate A row count
   SELECT COUNT(*) AS Equipment FROM Oee.ufn_ResolveOeeEquipment();                                      -- same number
   SELECT DISTINCT a_loc.Code AS FlaggedAncestor, d.Code AS FlaggedDescendant                            -- expect 0 rows
   FROM Location.Location d CROSS APPLY Oee.ufn_OeeAncestors(d.Id) a
   JOIN Location.Location a_loc ON a_loc.Id = a.AncestorLocationId
   WHERE d.IsOeeEnabled = 1 AND d.DeprecatedAt IS NULL;
   ```
2. **Dropdowns, per terminal kind (SQL, read-only).** Run `EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = <id>` for:
   - a shared die cast terminal (`DC1-T1`): every press under `DC1`, none `IsDefault`;
   - a trim terminal (`TRIM1-T1`, `TRIM2-T1`): the trim machines;
   - an M&A line terminal: one row, the line, `IsDefault = 1`.

   This should match Gate C: no LOST rows means these are the same lists as before.
3. **Plant Hierarchy (Config Tool, look only, don't save):**
   - A die cast press: the checkbox is **enabled and ticked**.
   - A line: **enabled and ticked**.
   - A terminal, a printer or an Area: **greyed out and unticked**.
   - The detail row isn't clipped (`59317a43`).
4. **Downtime Manager on a terminal (the one hop not proven end to end since the attribution fix; see § 6.1).**
   - At a die cast shared terminal, open the Manager. The press list appears; pick a press and it stays picked (`412d0914`).
   - If Jacques wants a live write: Start and then End a downtime event on a press, then check that `Oee.DowntimeEvent` has the row with the operator's `AppUserId`, and **Void it**. If End or Void are refused with "Required parameter missing (… AppUserId)", that's § 6.1.
5. **Availability read.** Before the deploy, save the output of `EXEC Oee.Shift_GetAvailability @ShiftId = <last closed shift id>`. After the deploy, run it again. Expect:
   - one row per flagged unit, `IsRollup = 0` on every row, and the new columns present;
   - units with no excused downtime in that shift: `Availability` within about a minute's worth of the old figure (minute-grid rounding, header note);
   - units with excused downtime: a **higher** figure (planned time now shrinks the base).

   Nothing on screen shows this number.
6. **Shared-module checks (Test 2):**
   - A die cast terminal's **machine dropdown** lists presses (`Location.getDieCastMachineDropdown`).
   - A shop-floor page that isn't about downtime (Machining IN, say) renders its header, with no Component Error on the downtime badge.
7. **Config Tool Shift Overrides:** the equipment picker lists the same presses and lines as before (`ufn_ResolveOeeEquipment` changed underneath it).

---

## 6. Observations and caveats for Jacques

### 6.1 The Downtime Manager and Downtime Editor pass no `appUserId` (bundle-level, from `df99b8d5`)

> **Resolved 2026-09-18 in `c8a18322`.** DowntimeManager (Start, End, reason, Void) and DowntimeEditor (past event x2, reason, times) now pass `appUserId=BlueRidge.Common.Session.currentAppUserId(self.session)`. A caller scan over every view, script and timer found no other missing site. The analysis below describes HEAD before that commit.
**What I saw:** at HEAD, `Components/Popups/DowntimeManager` calls:
- `DE.start(sid)`
- `DE.end(payload["downtimeEventId"])`
- `D.updateReason(...)`
- `D.void(...)`

and `Components/Popups/DowntimeEditor` calls:
- `D.recordHistorical(...)`
- `D.recordApproximate(...)`
- `D.updateReason(...)`
- `D.updateTimes(...)`

**None of them passes `appUserId`.** After `df99b8d5`, those entity functions call `Common.Util.requireAppUserId(appUserId)`, which returns None and logs an ERROR. Neither popup is in `df99b8d5`'s file list; that commit updated the legacy `DowntimeEntry` view instead.

**What I think it means:**
- `DowntimeEvent_End`, `_UpdateReason`, `_UpdateTimes`, `_Void`, `_RecordHistorical` and `_RecordApproximate` all reject a NULL `@AppUserId`. So after the combined release, **ending, voiding, re-reasoning, editing and back-filling downtime from the Manager would be refused**.
- `DowntimeEvent_Start` has no NULL-user guard (the attribution handoff lists it in § 10), so a Start would probably go through with no user recorded. I didn't establish whether it gets recorded or fails later at the audit write.
- On prod today these calls fall back to the DEV user, which is the bug `df99b8d5` fixes. So this would be a new failure introduced by the combined release, not an existing one.

**This isn't an OEE defect,** but it lands on the OEE screens in this bundle. The attribution handoff says "every caller now supplies one", and this looks like two callers that don't. **Confirm before the window.** I didn't change anything.

### 6.2 Other points
1. **The legacy Downtime Entry is still reachable** (AppMenu -> "Downtime Entry (legacy)"). After the release it refuses everything except presses and trim machines. This is the spec's own open item 7.2 ("retirement sequencing"). Gate B shows whether anyone uses it for anything else. Should it be retired or hidden in this release, or left as is, with the refusals stated in the runbook?
2. **End of Shift still writes downtime against unflagged cells**, unguarded, on purpose (spec D11). Those rows don't count toward availability. Acceptable until it is retired?
3. **New locations are born unflagged.** Before the release, a new active press created under a die cast Area became a downtime unit automatically. After the release, it doesn't appear in any Downtime Manager until someone ticks *OEE / downtime enabled*. That's by design (D10), and it's worth one line in the guide and a word to whoever at MPP adds machines.
4. **Unticking a line is not "OEE off".** It removes the line from its terminals' Downtime Manager entirely (spec § 3.8). The untick is refused only while an event is open.
5. **A Plant Hierarchy editor open through the import.** After the import, `handleSaveAll` always sends an explicit `isOeeEnabled` (never NULL). If a Config Tool session still held a draft loaded *before* the import, with no `isOeeEnabled` key, its next save would send False and untick that location. That's unlikely, and it needs someone mid-edit during the window. Asking Config Tool users to reload after the import removes it.
6. **Plan Task 9 was not completed.** The release handoff it names was never written (this note stands in for it). The durable rule it says to add to `CLAUDE.md` ("Downtime and OEE units are opt-in per location") isn't there either.

---

## 7. Evidence

- **SQL tests covering the feature (not run for this note; the parent session runs the full suite):**

  | Area | Test file | Assertions |
  |---|---|---|
  | Backfill | `sql/tests/0090_Oee_EnabledLocations/010_flag_backfill.sql` | 9 |
  | Resolution | `020_resolution.sql` | 17 |
  | Roll-up | `030_rollup_availability.sql` | 19 |
  | Writer refusals | `040_write_validation.sql` | 9 |
  | Roll-up edge cases | `050_rollup_edge_cases.sql` | 9 |
  | Save guard and untick refusal | `sql/tests/0003_Location/070_Location_IsOeeEnabled.sql` | 26 |
  | Downtime regression | `sql/tests/0026_PlantFloor_Downtime_Shift/010–120` | fixtures now flag their machines |
  | Availability regression | `sql/tests/0059_Oee_ShiftOverride/030_availability.sql` | -- |

  The assertion counts are `Assert_` call sites. The `010` backfill test compares the flags against a copy of the same rule, not against the v1.0 function's output. The Dev checks below fill that gap for the dropdown.
- **Dev, read-only (2026-09-18, `MPP_MES_Dev` at `0095`):**
  - 171 active locations, 44 flagged, equal to the backfill prediction.
  - The Gate C simulation was checked against the real procs on all 68 Dev terminals. It matches v2.0 `DowntimeScope_ListForTerminal` row for row (84 rows). It matches the v1.0 text from `192c77c1`, run as a temp procedure, row for row (85 rows).
  - `Oee.Shift_GetAvailability` for the last closed shift returns the widened shape. `AO-OP` carries `ParentLocationId` = `MA2-6FBCHOP` (the Dev drift).
  - Dev holds 5 downtime events, none open.
- **No writes** were made to any database, and no scans or commits were run.
