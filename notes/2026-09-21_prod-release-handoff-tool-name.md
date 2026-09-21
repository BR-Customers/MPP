# Prod release handoff -- Plant floor shows dies by NAME, never by tool code

**Written:** 2026-09-21, for the agent who builds and runs the prod release.
**Branch:** `jacques/working`.
**Feature commit:** `5f09108d` (SQL + Ignition). This note is committed separately, after it.
**Range:** `-Since e3e0aa25 -Until 5f09108d`. The trial build in § 2 used exactly this range.
**Previous release:** `e3e0aa25`, the 2026-09-18 bundle (`notes/2026-09-18_prod-release-runbook-bundle.md`).
- Its Outcome section is filled in: prod SQL is at `0095`, and all 28 repeatables matched the repo byte-for-byte after commit.
- Prod Ignition matched git at `e3e0aa25` for every shipped resource.

**Builds on:** nothing unreleased.
- For every file `5f09108d` touches, `git log e3e0aa25..5f09108d^ -- <file>` is empty.
- No other commit sits under the shipped files.

This note is scoping input for `prod-release-context-pack/07_writing_the_runbook.md`. It is **not** the runbook. The five deliverables in `01_the_release_contract.md` are still owed.

---

## 0. Check these first

1. **The range carries two other commits. Neither ships.**
   - `9fc8b621`: `sql/scripts/Export-ProdConfig.ps1`, `Import-ConfigSnapshot.ps1`, `tools/perspective-capture/fixture.sql`, `.gitignore`.
   - `738a1b9b`: a spec, `sql/scratch/2026-09-21_diecast_on_record_window.sql`, `sql/scratch/Run-DieCastOnRecord.ps1`.
   - Neither touches `sql/migrations` or `ignition/projects`.
2. **The working tree is dirty with other people's work. Do not ship it.** The archives build from git, so this matters only if someone hand-copies files.
   - Real uncommitted edits: `AssemblyNonSerialized/view.json`, `DieCastOverflow` / `DieCastOverflowRow`, `parts/ToolCavity_Create/query.sql`, both `session-props/props.json`, and MPP_Config `page-config`.
   - Line-ending-only churn: `CountPanel`, `ScrapPanel`, `InspectionEntry`.
   - Gateway re-signing churn: about 400 `resource.json` files.
   - None of it is part of this change.
3. **Not clicked through with a die mounted.**
   - The Die Cast screen needs a PIN sign-in before a cell can be picked, so the mounted state was never seen on Dev.
   - Seen live on Dev:
     - The LOT Search Die filter lists names, sorted.
     - Die Cast's empty state ("No die mounted", "No die") renders with no Component Error in all three spots.
   - Dev has no LOTs with a tool and no die cast production. That leaves the LOT Detail Tool tile, the LOT Search Die column and the Supervisor rows unseen with data.
   - Make them the first post-deploy checks (§ 5). Prod has all three kinds of data.
4. **Jacques's decision needed? No.** Scope was agreed in session: "the code is not known by anybody but the die manager. that code does not need to be in ANY screen on the plant floor app."

---

## 1. What it does, in plant terms

`Tools.Tool.Code` (`DMO124`, `DM0144`, `DMO-131`...) is known only to the die manager. Operators and supervisors know a die by its **name** (`6MA IN 1&5 EX 1&5 - D`, `64A Oil Pan-H`). Every plant-floor place that showed the code now shows `Tools.Tool.Name`:

| Screen | Before | After |
|---|---|---|
| Die Cast header line | `...SHARED TERMINAL . Tool DMO124` | `...SHARED TERMINAL . Tool 6MA IN 1&5 EX 1&5 - D` |
| Die Cast header pill | `DMO124` (monospace) | name. No longer monospace; capped at 360px, then `...` |
| Die Cast "Die" field | `DMO124` (monospace) | name (plain field font) |
| Die Cast -> Fix counter popup title | code | name |
| Die Mount popup: header, and the "which die to mount" dropdown | `DMO124 - 6MA ...` | name only |
| Die Cast Supervisor, DIE column | code, 100px | name, 160px, `...` on overflow |
| LOT Detail, Tool tile | code (monospace) | name |
| LOT Search, Die column and Die filter | code | name; the filter is sorted by name |

**Unchanged on purpose:**
- **The Config Tool** (Tool list, Tool editor, Plant Hierarchy Cell Mount Card). That is the die manager's screen and still shows the code.
- **Audit Description text.** `Lot_Create`, `DieCastCounterAnchor_Record`, and a lot-free `RejectEvent_Record` still write the code into `Audit.OperationLog` prose.
  - That text is shown only in the Config Tool's Audit Browser.
  - LOT Detail's history timeline (`Lots.Lot_GetAttributeHistory`) does not read it and never references the tool.
- **The LOT Search "Export CSV" download.** `Lot.exportCsv` dumps whole rows, so the CSV now carries both `ToolCode` and `ToolName` columns. It is a downloaded file, not a screen. Raise it with Jacques if the rule is meant to cover exports too.

---

## 2. Scope

### Versioned migrations
**None.** Prod stays at `0095`.

### Repeatables (both CHANGED, both additive)

| Object | Version | Change |
|---|---|---|
| `Lots.Lot_Get` | 1.1 -> 1.2 | + `t.Name AS ToolName`, directly after `ToolCode`. |
| `Lots.Lot_SearchAdvanced` | 1.1 -> 1.2 | + `t.Name AS ToolName`, directly after `ToolCode`. |

**Consumers of these two procs** (checked across `sql/migrations` + `ignition/projects` + report `data.bin`s):
- Consumers:
  - the two NQs `lots/Lot_Get` and `lots/Lot_SearchAdvanced`, each a thin `EXEC`;
  - `BlueRidge.Lots.Lot` (`execOne` / `execList`), which reads by column **name**.
- No proc captures either one via `INSERT ... EXEC`, and no report uses either.
- The only position-dependent consumers are SQL tests, which were widened in the same commit.

### Ignition resources (trial build 2026-09-21 19:34: `-Since e3e0aa25 -Until 5f09108d`)

| Project | Resource | State |
|---|---|---|
| Core | `ignition/script-python/BlueRidge/Lots/Lot` | MOD: `_EMPTY_LOT` + `ToolName`; `getDieOptions` labels by name, sorted |
| Core | `ignition/script-python/BlueRidge/Parts/Tool` | MOD: `getEligibleToolPicker` (Die Mount dropdown) labels by name only |
| Core | `ignition/script-python/BlueRidge/Workorder/DieCastSupervisor` | MOD: `mapPressInstances` `die` <- `ToolName` |
| MPP | `views/BlueRidge/Views/ShopFloor/DieCastBody` | MOD |
| MPP | `views/BlueRidge/Components/Popups/DieMount` | MOD |
| MPP | `views/BlueRidge/Views/ShopFloor/DieCastSupervisor` | MOD: header DIE 100 -> 160px (x2) |
| MPP | `views/BlueRidge/Components/PlantFloor/DieCastSupervisor/PressRow` | MOD |
| MPP | `views/BlueRidge/Views/ShopFloor/LotDetail` | MOD |
| MPP | `views/BlueRidge/Views/ShopFloor/LotSearch` | MOD |

**Expected builder output:**
```
Core           3 resource(s),   7 entries
MPP            6 resource(s),  13 entries
MPP_Config   no changed resources -- skipped
3 manifest(s) rewritten to drop an excluded file (thumbnail.png).
```

**The trial archives were verified:**
- They pass the `11_project_exports.md` structural checks.
- `activeTool.ToolCode` and `view.custom.lot.ToolCode` appear 0 times in the shipped files.
- **No deletions.**

Rebuild at the actual release commit.

### Ships nothing
- `sql/tests/**`: 6 files widened by one column, and 1 assertion extended.
- The two commits in § 0.1.
- This note.

---

## 3. Risk -- the four tests

**Test 1: does anything now refuse what it used to allow?** No. There are no new validations, no rejection paths, and no behaviour change. The change is display only.

**Test 2: is any of it shared code?** Partly.
- `BlueRidge.Lots.Lot` and `BlueRidge.Parts.Tool` are large, widely used modules. Only three functions changed, and all three are display-shaping.
- The `_EMPTY_LOT` shape gained a key. That is additive: callers read keys, and none iterates the shape.
- Post-deploy, prove one non-feature surface still works (§ 5, check 6).

**Test 3: is the schema change metadata-only?** Yes. There is no table change at all, only two `CREATE OR ALTER PROCEDURE`s. The expected lock window is the proc swap, well under a second (the 09-18 bundle was 9.3 s for 28 repeatables plus 5 migrations under live traffic).

**Test 4: does the old Ignition keep working against the new SQL?** **Yes.**
- The procs only gained a column, and every Ignition consumer reads by name.
- The SQL step and the import step are independent, with no rush between them.
- The reverse is *not* true:
  - New Ignition on old SQL shows a **blank** LOT Detail Tool tile and a blank LOT Search Die column. Those two procs don't return `ToolName` yet.
  - Die Cast, Die Mount and Supervisor would be fine: their procs (`ToolAssignment_ListActiveByCell`, `ToolAssignment_GetCellContext`, `DieCastSupervisor_GetShiftTotals`, `Tool_ListEligibleForCell`) already return `Name` / `ToolName` on prod today.
- So: **SQL first**, as always.

**Operator-visible:** yes, deliberately. Die cast operators and supervisors will see names where codes were. Nothing to retrain, but tell the floor lead that the header and Die field changed.

---

## 4. Expected preview (`Deploy-ProdRelease.ps1`)

Not rehearsed on a ProdSim. There is no migration, and both objects are additive `CREATE OR ALTER`s, the same shape as the 09-16 release, which rehearsed on Dev. The release agent decides whether a ProdSim is warranted.

| Section | Expect |
|---|---|
| `[3]` migrations | 0 pending; highest applied `0095` |
| `[4]` repeatables | **2 CHANGED**: `Lots.Lot_Get`, `Lots.Lot_SearchAdvanced`. Everything else identical, 0 new. |
| `[5]` gates | none |

**If `[4]` lists anything beyond those two**, prod was hand-patched after 09-18, or something shipped outside the process.
- Read the per-object diffs before continuing.
- Hunter has edited prod directly before (09-16).

**On Dev the change is already applied and tested:**
- Both procs are applied to `MPP_MES_Dev`.
- `sys.dm_exec_describe_first_result_set` shows `ToolCode, ToolName, ToolCavityCode` in order.
- `sql/tests/Run-Tests.ps1` on a fresh `MPP_MES_Test` (reset from all migrations) gave **3840 / 3840 passed**. That includes `[SearchAdv] tooled LOT resolves ToolCode, ToolName and CavityCode`.

---

## 5. Post-deploy verification (prod has the data Dev lacks)

1. **Die Cast** (`/shop-floor/die-cast`, PIN sign-in, a press with a mounted die):
   - The header line, pill and Die field show the die's **name**.
   - A long name ends in `...` in the pill, and the header does not wrap or push the buttons off-screen.
2. **Fix counter** on that screen: the popup title shows the name.
3. **Die Mount popup:**
   - The header shows the mounted die's name.
   - The "mount a die" dropdown lists names only. **Do not mount or release anything to test it; just open the dropdown.**
4. **Die Cast Supervisor** (`/shop-floor/die-cast/supervisor`): the DIE column shows names, one line each, and the columns line up with the header.
5. **LOT Detail** for any die-cast LOT:
   - The Tool tile shows the name.
   - **LOT Search**: the Die column shows names, and the Die filter lists names alphabetically. Filtering by one still narrows the results.
6. **Non-feature surface** (Test 2): open LOT Detail for a *non*-cast LOT (received or assembly). The page loads, and the Tool tile stays hidden.
7. SQL spot-check:
   ```sql
   SELECT name FROM sys.dm_exec_describe_first_result_set(N'EXEC Lots.Lot_Get @LotId = 1', NULL, 0) WHERE name LIKE N'Tool%';
   -- expect ToolId, ToolCavityId, ToolCode, ToolName, ToolCavityCode
   ```

---

## 6. Rollback

- **SQL:** not needed on its own. The change is additive and old Ignition ignores the extra column. To revert anyway, re-apply the two procs at `e3e0aa25`:
  `git show e3e0aa25:sql/migrations/repeatable/R__Lots_Lot_Get.sql` (and `..._SearchAdvanced.sql`) through `sqlcmd`, via the normal Deploy path.
- **Ignition:** before importing, take a Designer export of the 9 resources in § 2 from prod. Re-importing that export is the rollback.
  - `Build-ChangeExport.ps1` cannot build an "as of `e3e0aa25`" archive. With `-Since e3e0aa25 -Until e3e0aa25 -IncludeResource ...` it stops with "Nothing changed". This was tried on 2026-09-21.
  - The in-git alternative is `git revert 5f09108d` on a new commit, shipped as its own scoped release.

---

## 7. Follow-ups noticed, not in this release

1. **LOT Search Die filter dropdown is narrow.** Long names are cut off in the open list (seen on Dev). Widen the dropdown or its menu.
2. **`DieCastRelease` passes the cavity name as the counter popup's `dieName`** (`"dieName": p.get("cavityName")`). This predates the change and never showed the code. The Release preview proc doesn't return the tool name, so fixing it needs `DieCast_GetReleasePreview` to add `ToolName`.
3. **`DieCastBody` `custom.activeTool`** has no default in the view's `custom` block. That breaks the pre-declare-bound-props rule. Its source always returns a fully-shaped dict, so the worst case is a first-paint flash.
4. **CSV export and audit prose still carry the tool code** (§ 1). They are deliberately out of scope pending Jacques.
