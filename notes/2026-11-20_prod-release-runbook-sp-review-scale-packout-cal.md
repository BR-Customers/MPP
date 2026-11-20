# Prod release runbook -- SP review + learned scale codes + named pack-outs + container-as-LOT

**Release branch:** `release/2026-11-20-sp-review-scale-packout-cal`. **Run every command from that branch** (worktree `.claude\worktrees\release-1120`).
**Release commit (archives built and verified from):** `a8b11743`. HEAD is later only by the 0119 pre-flight gate (`sql/scripts`, ships nothing) and docs.
**Previous release:** `7847e6cf` on `release/2026-11-19-digi-scale-feed` (Digi scale feed, executed 2026-11-19 14:53 ET). Prod is expected at **117 migrations, highest `0134`**.
**Rehearsed against:** `MPP_MES_ProdSim1120`, built from `7847e6cf`: 117 migrations, highest `0134`, `Parts.PackOut` and `Lots.Container.LotId` absent. A full Execute ran on a second sim, `MPP_MES_ProdSim1120X`.

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint's first hashed line is the raw HEAD sha, so **any** commit changes it, a docs-only commit included, and Execute refuses. Re-preview and use the new fingerprint.
>
> **Two separate tests, two separate answers.** A docs-only commit invalidates the **fingerprint** but leaves the **archives** valid:
> ```bash
> git diff --stat a8b11743..HEAD -- ignition/
> ```
> Expect **no output** (the only later deployable is `sql/scripts/Deploy-ProdRelease.ps1`, the gate). Anything under `ignition/` means the archives are stale: rebuild them, then re-preview.

> **Every deploy command carries `-AllowOutOfOrder`.** Prod is at `0134` (the Digi release went first), so `0118`-`0133` sit below the high-water mark. Without the list the preview BLOCKs them.

---

## 1. What this ships

Five pieces of finished work, merged onto prod's state in this one release:

1. **Stored-procedure review (PRs #9-#35 on `main`, packaged 2026-11-16, never run).** The plant-floor and report reads that scanned whole tables now seek the rows they need -- including the queue reads behind the 2026-11-10 Assembly OUT freeze. Operators see no difference except **LOT Search**: a partial search covers the last 90 days unless *Search older than 90 days* is ticked; an exact LOT name still finds any LOT; the count reads "100+" past 100 rows. Plus **PR #17**: the OEE summary refresh fingerprints recent shifts one at a time.
2. **Learned scale part codes (PR #37, `0135`).** When a Digi scale sends a code that is no MES part number (prod terminal 215 sends `66V`), the operator's first pick teaches that terminal `code -> part`; later presses close with no tap. Config Tool **PLC Devices** lists learned codes with Remove.
3. **Named pack-outs (PR #38, `0136`).** A part can hold several **named** pack-outs per closure method (e.g. Cardboard vs Tote), one of them the default. Every **By Weight** station's **Pack-Out** button opens a popup with one button per pack-out: a tap makes it the one this station runs (refused while a box is open), **+ New** adds one, **Make default** / **Remove** are there. Tapping the default makes the station follow the default. Editing numbers saves a new version, so every box keeps the numbers it was opened on. The Config Tool Item Master **Container Config** tab is the same editor. Rework moves only between boxes of the same pack-out. **Release day: every existing config becomes its part's default pack-out (named after the method), so every station runs exactly what it runs today.**
4. **Container-as-LOT (PR #16, `0119`).** A finished-good LOT is now **one per container**, not one per tray (per-tray minting would exhaust the MESL range within a year). The first tray of a box mints the box's LOT; every later tray appends to it. Old tray-LOT boxes stay as history; a box open when the release lands becomes **mixed** (old trays keep their LOTs, the next tray mints the box's LOT) -- every reader handles all three shapes. Lot Detail shows a container LOT's trays.
5. **Digi follow-ups** already in prod's Digi code paths (review fixes on `feature/digi-scale-feed` after the release cut).

| SQL | |
|---|---|
| Migrations (14) | `0118`, `0120`-`0124`, `0127`-`0130`, `0133` (SP review: index-only), `0119_container_as_lot` (columns + indexes, no data rewrite), `0135_scale_part_code_map` (new table), `0136_named_pack_outs` (new tables, `ContainerConfig` += `PackOutId` / `VersionNumber` with backfill; drops `ContainerConfig_Create` / `_Update` / `_Deprecate` / `_GetByItem` / `_ListHistory`) |
| Repeatables | 74 -- 62 changed, 12 new |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |

| Ignition | NEW | MOD |
|---|---|---|
| Core (22) | view `Components/PackOutButton`; NQs `location/Terminal_SetPackOut`, `parts/PackOut_{Save,SetDefault,Deprecate,ListByItem}`, `workorder/ScalePartCode_{Resolve,ListForTerminal,Deprecate}`; script `Parts/PackOutPopup` | NQs `lots/Lot_Search`, `lots/Lot_SearchAdvanced`, `parts/ContainerConfig_GetByItemAndMethod`, `parts/ContainerConfig_JudgeWeight`, `workorder/Assembly_GetTraysRemaining`; scripts `Lots/Lot`, `Parts/ContainerConfig`, `Workorder/{Assembly,ScaleDigiWatcher,ScaleEPrintWatcher,ScaleStation,ScaleWatcher}` |
| MPP (9) | -- | `PlantFloor/{LineInventory,PrinterCard,ScaleStation}`, `Popups/{LowInventoryLock,PackOutEdit}`, `ShopFloor/{AssemblyNonSerialized,LotDetail,LotSearch}`, report `Lot Detail` |
| MPP_Config (4) | `Components/ScalePartCodeRow` | `ItemMaster/ContainerConfig`, `Popups/ItemContainerConfigHowTo`, `Views/Location/PlcDevices` |

In the range but shipping nothing: `sql/tests/`, `docs/`, `notes/`, `sql/scratch/`, `tools/` tests.

## 2. What the database change is

| | |
|---|---|
| Migrations | 14 (12 index-only; 0119 adds nullable columns + indexes; 0135 one table; 0136 two tables + backfill of every `ContainerConfig` row) |
| Repeatables | 74 (62 changed, 12 new) |
| Rehearsal lock window | 1.8 s on the sim (seed-sized tables) |

The cost is the index builds: six on `Lots.Lot` (`0118`, `0122`, `0123`, `0128`, `0130`, and `0119`'s FIFO pick index), one on the partitioned `Workorder.RejectEvent` (`0129`, aligned), and container / tray / label indexes. Each is one scan, offline on Standard edition, inside the one transaction behind the `TABLOCKX` freeze. **Expect the prod lock window to be several seconds, not 1.8 s** (the Digi release: sim 0.1 s, prod 2.8-3.4 s). `0136`'s backfill touches only `Parts.ContainerConfig` (a few hundred rows).

**Pre-empt in the preview:** five WARNs say `parts.containerconfig_create/_update/_deprecate/_getbyitem/_listhistory` exist on the target with no file -- `0136` drops them inside the transaction. Twelve WARNs are the allowed out-of-order migrations.

## 3. Risk

**Moderate.** From the four tests in `prod-release-context-pack/02_scoping_a_release.md`:

1. **Refuses what it used to allow?** Yes, three new refusals, all deliberate: a station cannot switch pack-out while a box is open ("Box #N is open (...) -- finish or close it before changing pack-out."); rework cannot move pieces between boxes of different pack-outs; rework cannot move pieces back into a container whose LOT already gave pieces to the donor (container-as-LOT genealogy-loop guard). LOT Search's 90-day default (section 1).
2. **Shared code?** Yes, heavily. `Workorder.Assembly_CompleteTray` -- **every** Assembly OUT tray -- changes for both container-as-LOT (mints/append the box LOT) and pack-outs (pack-out in force). It is the one write path both features touch; it passed both features' tests together (5,971 / 5,971) and both bench measurements, but it has not run on a gateway with a real line. Section 6 check 1 is therefore first.
3. **Metadata-only?** No: index builds (section 2) and the `0136` backfill.
4. **Old Ignition on new SQL?** **No -- import promptly after the SQL.** `0136` drops the five `ContainerConfig_*` procs the old Pack-Out popup and Item Master tab call, so between the commit and the Core import those two screens fail to save. Tray close, scale presses and every plant-floor read keep working on old Ignition (new parameters are optional; old result columns are kept). Do the imports right after Execute.

## 4. Deploy (SQL)

From the release worktree:

```powershell
cd C:\Users\JacquesPotgieter\Documents\Dev\MPP\.claude\worktrees\release-1120
git status -sb
```

Expect `## release/2026-11-20-sp-review-scale-packout-cal` and nothing under `sql/migrations`.

Set the password once (never on the command line):

```powershell
$env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
```

### Step 1 -- Preview (read-only)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -AllowOutOfOrder 0118,0119,0120,0121,0122,0123,0124,0127,0128,0129,0130,0133
```

Expect (from the sim):

```
[3] Versioned migrations
  Database: 117 applied, highest 0134.
  [WARN] migrations: out of order, ALLOWED by -AllowOutOfOrder: 0118_lot_open_lot_indexes.sql ...   (12 of these)
  Pending (14):
    + 0118_lot_open_lot_indexes.sql
    + 0119_container_as_lot.sql
    + 0120_shippinglabel_failed_banner_index.sql
    + 0121_container_rework_filling_index.sql
    + 0122_lot_diecast_by_terminal_index.sql
    + 0123_lot_vendor_lot_index.sql
    + 0124_containertray_closedat_index.sql
    + 0127_downtimeevent_location_shift_index.sql
    + 0128_lot_tool_not_closed_index.sql
    + 0129_rejectevent_item_recordedat_index.sql
    + 0130_lot_tool_cavity_index.sql
    + 0133_shippinglabel_aimshipperid_index.sql
    + 0135_scale_part_code_map.sql
    + 0136_named_pack_outs.sql
[4] Repeatables -- target definitions vs this checkout
  551 identical, 62 changed, 12 new on the target.
  [WARN] repeatables: object on the target with no file in this checkout: parts.containerconfig_create (left untouched)   (and _deprecate, _getbyitem, _listhistory, _update)
[5] Pre-flight gates
  [INFO or WARN] 0119: ... open box(es) already hold tray LOTs and will become MIXED ...   (lists them; sim: none)
  [INFO] 0136: turns N active pack-out config(s) into default named pack-outs ...
[8] Plan
  14 migration(s), 74 repeatable(s) in one transaction; then R__Descriptions_ExtendedProperties.sql after commit.
  Plan fingerprint: <12 hex>
Verdict
  Clear to deploy. 17 warning(s) to read above.   (18 if the 0119 gate lists open boxes)
```

The sim printed `8c8263220cfa` at `97cd5cdc`. Prod prints the same only if HEAD is still `97cd5cdc` and prod matches the sim; a match corroborates, a difference is not an error. **Use the fingerprint YOUR preview printed. Copy it, do not retype it.**

**If it differs:**
- *Not 117 applied / highest not `0134`* -- prod is not where this runbook assumes. Stop and reconcile.
- *Any pending migration missing, or an extra one* -- wrong branch or a missing commit. Run from `release/2026-11-20-sp-review-scale-packout-cal`.
- *More than 62 CHANGED or 12 NEW* -- prod has drifted from git (a hand-patched proc). Read the report's `diffs` folder before continuing.
- *`[5]` BLOCK "already exists but 0136 / 0135 is not recorded"* -- someone created those tables by hand. Stop.
- *`[5]` BLOCK "more than one ACTIVE ContainerConfig"* -- a part has two active configs for one method; deprecate the extra in Item Master first.
- *`[5]` 0119 WARN lists open boxes* -- normal; those boxes become mixed and every reader handles it. Deploy between boxes only if you prefer none.
- *`[6]` shows an open transaction* -- wait for it, or pick a quieter moment.

### Step 2 -- Rehearse (applies, verifies, rolls back)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -AllowOutOfOrder 0118,0119,0120,0121,0122,0123,0124,0127,0128,0129,0130,0133 -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE`. Expect:

```
    == transaction open
    == [1] migration 0118_lot_open_lot_indexes
    == [2] migration 0119_container_as_lot
    ... [3]-[13] the other migrations in number order
    == [14] migration 0136_named_pack_outs
    Migration 0136 (named_pack_outs) applied.
    == [15] R__Lots_ufn_ContainerForNextTray.sql
    ... [16]-[88] repeatables (functions, then procs)
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept
  REHEARSAL PASSED and was rolled back. Lock window: <n>s.
```

Expect a lock window of several seconds (index builds on live tables; sim 1.8 s). If the rehearsal fails, **stop**: it failed against prod's actual data, which local testing cannot simulate.

### Step 3 -- Execute

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -AllowOutOfOrder 0118,0119,0120,0121,0122,0123,0124,0127,0128,0129,0130,0133 -Mode Execute -ExpectedPlan <fingerprint>
```

Type `MPP_MES_Prod`. Expect `[9] Backup ... Backup written and verified.`, the same step markers ending `== COMMITTED`, then (as on `MPP_MES_ProdSim1120X`):

```
[11] After commit
  R__Descriptions_ExtendedProperties.sql applied.
  Every repo migration is recorded.
  All 74 applied repeatable(s) now match the repo byte-for-byte.
DONE
```

Note the backup path from `[9]` in section 8. **Go straight to section 5.**

## 5. Ignition imports -- right after the SQL; Core, then MPP, then MPP_Config

Designer -> File -> Import, one zip at a time, accept overwrite. **Not** the Gateway web page's project import. Archives in `C:\Users\JacquesPotgieter\Documents\Dev\MPP\.claude\worktrees\release-1120\dist\ignition-exports\`:

1. `Core_release-1120_2026-11-20_1433.zip` -- 22 resources (9 NEW, 13 MOD; list in section 1).
2. `MPP_release-1120_2026-11-20_1433.zip` -- 9 resources (all MOD).
3. `MPP_Config_release-1120_2026-11-20_1433.zip` -- 4 resources (1 NEW, 3 MOD).
4. **Delete by hand in the Designer (Core -> Named Queries -> parts):** `ContainerConfig_Create`, `ContainerConfig_Update`, `ContainerConfig_Deprecate`, `ContainerConfig_GetByItem`, `ContainerConfig_ListHistory`. Their procs are gone; nothing calls them after the import. (An import cannot delete; this is the step most easily skipped.)
5. F5 every open shop-floor screen (Assembly OUT, scale stations, LOT Search / Detail).

Checklist with commits per resource: `dist\ignition-exports\release-1120_2026-11-20_1433_CONTENTS.txt`.

## 6. Verification (most important first)

**Check 1 is the one hop never run on a gateway with a real line.** `Assembly_CompleteTray` carries both the container-LOT mint and the pack-out-in-force change. Both features' SQL suites pass together (5,971 assertions, 0 failures) and the pack-out station screens were walked on Dev, but no real tray has closed through the merged proc. **Do this first, on the first tray any non-serialized Assembly OUT closes after the release:**

```sql
SELECT TOP 3 c.Id AS ContainerId, c.LotId, l.LotName, l.PieceCount, c.ContainerConfigId, po.Name AS PackOut,
       t.TrayPosition, t.FinishedGoodLotId, t.ShiftId, t.MintedPieceCount
FROM Lots.ContainerTray t
JOIN Lots.Container c ON c.Id = t.ContainerId
LEFT JOIN Lots.Lot l ON l.Id = c.LotId
LEFT JOIN Parts.ContainerConfig cc ON cc.Id = c.ContainerConfigId
LEFT JOIN Parts.PackOut po ON po.Id = cc.PackOutId
ORDER BY t.Id DESC;
```

Expect: `LotId` set and `LotName` an MESL number, `PieceCount` = the trays' pieces so far, `FinishedGoodLotId` NULL on the new tray, `ShiftId` and `MintedPieceCount` set, `PackOut` = the method name (e.g. `By Weight`). A box open before the release shows older trays with `FinishedGoodLotId` set (mixed) -- expected.

2. **Schema landed** (expected values from `MPP_MES_ProdSim1120X`):
   ```sql
   SELECT COUNT(*) AS Applied, MAX(MigrationId) AS Highest FROM dbo.SchemaVersion;          -- 131, 0136_named_pack_outs
   SELECT (SELECT COUNT(*) FROM Parts.ContainerConfig WHERE PackOutId IS NULL) AS CfgNoHeader,   -- 0
          (SELECT COUNT(*) FROM Parts.PackOut WHERE IsDefault = 1 AND DeprecatedAt IS NULL) AS Defaults,  -- = the 0136 INFO count
          (SELECT COUNT(*) FROM sys.indexes WHERE name IN ('IX_Lot_NotClosed_Location','IX_Lot_NotClosed_Item','IX_ContainerTray_ClosedAt')) AS Ix,  -- 3
          (SELECT COUNT(*) FROM sys.procedures WHERE name LIKE 'ContainerConfig[_]Create%') AS OldCreate;  -- 0
   ```
3. **A scale press closes** at a By Weight station (terminal 215 / 66V if it is running): the tray closes, Press Log shows it, Audit.InterfaceLog shows the verdict row. The scale panel's target matches the part's pack-out.
4. **Pack-Out popup** at terminal 215: Pack-Out button -> one button "By Weight (default)", highlighted, with `6/tray x 1 - 15 lb +/- 1.35`. Do not create pack-outs on prod as a test.
5. **Complete a box -> label and AIM** (container-as-LOT changed `Container_Complete`, label data and AIM reads): the next completed box prints its label and its AIM shipper ID posts as before (Failure Log quiet).
6. **Assembly OUT queue / low-inventory banner** refresh normally (SP-review queue reads, `GetTraysRemaining` with terminal).
7. **LOT Search** (shared `BlueRidge.Lots.Lot` module): an exact old LOT name finds it; a fragment finds the last 90 days; the tick box widens it. **Lot Detail** on a container LOT shows its trays.
8. **Config Tool:** Item Master -> Container Config shows each part's pack-out as one button per method; PLC Devices shows a Learned scale codes list. (Not walked before release: needs an AD sign-in.)

## 7. Rollback

- **Before commit** (preview, rehearsal, or a failed execute): nothing to undo.
- **After commit, SQL:** fix forward. Every new column is nullable, every migration is additive except `0136`'s drop of the five retired procs. Restoring the `[9]` backup discards plant data written since -- only for a catastrophic failure.
- **Ignition:** import `Core_release-1120-ROLLBACK_2026-11-20_1434.zip` (17), `MPP_release-1120-ROLLBACK_2026-11-20_1434.zip` (9), `MPP_Config_release-1120-ROLLBACK_2026-11-20_1434.zip` (3): every MODIFIED resource back to prod's current version. Delete by hand the NEW ones (section 1 NEW column). **Caveat:** with the SQL left forward, the rolled-back Pack-Out popup and Item Master tab cannot save (their procs are dropped). Roll back Ignition only together with the SQL backup, or fix forward.

## 8. Outcome -- filled in after the release

_(still to fill in)_ -- date and time ET, prod's starting state, plan fingerprint, what the preview and rehearsal printed, lock window, backup path, report folder, imports, anything sideways.

## 9. Follow-up this release creates

- **MAXDOP stopgap:** prod database-scoped `MAXDOP = 1` (2026-11-10) can go back to `0` once several shifts show no error 1205 with the `0118` queue fix in place.
- **Merge order on GitHub:** this release is the merge of `main` + PR #36 + #37 + #38 + #17 + #16. Merge those PRs into `main` (or merge this release branch) so `main` matches prod.
- **Old ad-hoc scratch scripts** still insert into `Parts.ContainerConfig` without `PackOutId` (`sql/scratch/_aim_test_part.sql`, `_seed_byvision_byweight_lines.sql`, `2026-10-19_6maop_office_scale_test_setup.sql`); fix before reusing them.
- Review minors deferred from the pack-out PR (#38 body).
