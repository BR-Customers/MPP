# Prod release runbook -- stored-procedure review bundle (`0118` + `0120`-`0133`)

> **IF THE DIGI SCALE RELEASE RAN FIRST (`0134`, `notes/2026-11-19_prod-release-runbook-digi-scale-feed.md`).**
> Jacques decided on 2026-11-19 to ship it ahead of this one. Prod is then at **117 migrations, highest `0134`**, and
> every migration below is "pending below the high-water mark", which the deploy script BLOCKs unless told otherwise.
> Add this to **every** Preview / Rehearse / Execute command in this runbook:
> ```
> -AllowOutOfOrder 0118,0120,0121,0122,0123,0124,0127,0128,0129,0130,0133
> ```
> Then expect `[3]` to read `117 applied, highest 0134`, one `WARN ... out of order, ALLOWED by -AllowOutOfOrder` per
> migration (11), and the plan to carry an `ALLOW|...` line (so the fingerprint differs from the one below). The
> migrations are independent of `0134` (index changes on other tables), so the order does not matter to them. A
> listed number that is not pending is a BLOCK. Everything else in this runbook stands. Not rehearsed in this order;
> rehearse against a sim built at the Digi release's commit with that release executed, as the Digi runbook did.

**Release commit:** `177f0b7a` on `main` -- the last commit that changes `sql/` or `ignition/` (PR 34 merge). `HEAD`
will be this note's commit or later; see the drift rule below.
**Previous release:** `96651770` (2026-11-04 bundle, executed Thursday 2026-11-05). Prod is expected at 116 migrations,
highest `0117`.
**Supersedes:** `notes/2026-11-10_prod-release-runbook-queue-read-deadlock-fix.md`. That release (`0118` alone) was never
run; `0118` ships here, unchanged, together with everything the stored-procedure review merged on 2026-11-16.
**Rehearsed against:** `MPP_MES_ProdSimSP`, built at `96651770` (116 migrations, highest `0117`, `IX_Lot_NotClosed_*`
absent). Preview + Rehearse clean; rollback verified clean. A real Execute on a second sim (`MPP_MES_ProdSimSP2`)
confirmed the backup, the post-commit step and the section 6 values.
**Run from `main`, not `jacques/working`.** `jacques/working` is behind `main` (it has no commits of its own) and does
not carry this release.

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint's first hashed line
> is the raw HEAD sha, so **any** commit changes it -- a docs-only commit included -- and Execute refuses. Re-preview and
> use the new fingerprint.
>
> **Two separate tests, two separate answers.** A docs-only commit invalidates the **fingerprint** but leaves the
> **archives** valid, because they are built from git over `ignition/`:
> ```bash
> git diff --stat 177f0b7a..HEAD -- ignition/ sql/
> ```
> Expect **no output**. If anything is listed, the archives are stale -- rebuild them (section 5), then re-preview.

## 1. What this ships

The plant-floor and report reads that were scanning whole tables now look up only the rows they need. **Operators see
no difference on any screen except LOT Search** (below): same rows, same order, same columns. The reads get much cheaper:
the queue reads behind the 2026-11-10 Assembly OUT freeze go from ~500,000 to ~200 page reads on a 5.5M-LOT bench;
a scale press from 14,176 to 94 LOT reads; the Shift-End Summary from 102,560 to 2,549; the downtime header poll from
3,710 to 149; opening a die-cast basket from 3,723 to 3.

**One visible change -- LOT Search (PR 18).** A partial search now looks at the **last 90 days** unless the operator
ticks *Search older than 90 days*. An exact LOT name still finds the LOT at any age. The count reads "100+" when there
are more than the 100 rows shown, instead of an exact total. Supervisors who search old LOTs by fragment will need the
tick box.

| Migration | Adds |
|---|---|
| `0118_lot_open_lot_indexes` | `IX_Lot_NotClosed_Location`, `IX_Lot_NotClosed_Item` on `Lots.Lot` (filtered `LotStatusId <> 4`; refuses to run if Id 4 is not Closed) |
| `0120_shippinglabel_failed_banner_index` | `IX_ShippingLabel_FailedUnacked` (print-failure banner, 5 s poll) |
| `0121_container_rework_filling_index` | `IX_Container_ReworkFilling` (filtered status 7; refuses to run if Id 7 is not ReworkFilling) |
| `0122_lot_diecast_by_terminal_index` | `IX_Lot_DieCastByTerminal` (die-cast activity log) |
| `0123_lot_vendor_lot_index` | `IX_Lot_VendorLotNumber` (supplier-lot check at check-in) |
| `0124_containertray_closedat_index` | `IX_ContainerTray_ClosedAt` (scale-station shift tally) |
| `0127_downtimeevent_location_shift_index` | `IX_DowntimeEvent_Location_Shift` (downtime header poll) |
| `0128_lot_tool_not_closed_index` | `IX_Lot_Tool_NotClosed` (per-die open-basket reads) |
| `0129_rejectevent_item_recordedat_index` | `IX_RejectEvent_ItemRecordedAt` on the **partitioned** `Workorder.RejectEvent`, aligned on `ps_MonthlyUtc` |
| `0130_lot_tool_cavity_index` | `IX_Lot_ToolCavity_Status` (per-cavity open-basket guards) |
| `0133_shippinglabel_aimshipperid_index` | `IX_ShippingLabel_AimShipperId` (Global Trace shipper lookup) |

`0119` is reserved for container-as-LOT (PR 16, not merged); `0125`, `0126`, `0131`, `0132` were never used. The gaps
are harmless.

**22 repeatables, all CHANGED, none new:** `Lot_GetWipQueueByLocation` v3.3, `Lot_GetTrimStorageQueueForLine` v2.1,
`Lot_GetComponentsAtCell` v1.2, `Lot_GetInspectionQueueByLocation` v1.1, `Lot_GetLineInventoryByPart` v1.4,
`Lot_GetLineInventorySummary` v2.1, `Lot_GetCellLineQuantity` v1.1, `Lot_GetScrappablePartsByLocation` v1.1,
`Lot_GetOpenByTool` v2.2, `Lot_Search` / `Lot_SearchAdvanced` v2.0, `Assembly_GetTraysRemaining` v1.1,
`Item_ListEligibleFinishedGoodsRanked` v1.2, `ItemLocation_ListConsumptionForLine` v1.2,
`ufn_ScaleStationEligibleParts` v1.2, `ScaleStation_GetShiftTally` v1.2, `DieCast_GetShiftOutputBreakdown` v3.3,
`ToolAssignment_GetCellContext` v1.2, `Oee.DowntimeEvent_GetByScope` v1.2, `Oee.Lot_GetInProcessByLocation` v1.1,
`Quality.Reject_SearchDetail` v1.2, `Audit.FailureLog_List` v3.2. Every PR is linked in
`notes/2026-11-13_sp-review-log.md`.

| Ignition | Resource | |
|---|---|---|
| Core | `named-query/lots/Lot_Search`, `named-query/lots/Lot_SearchAdvanced` | MOD (new `includeOlder` parameter) |
| Core | `script-python/BlueRidge/Lots/Lot` | MOD (shared module; only the search functions changed) |
| MPP | `Views/ShopFloor/LotSearch` | MOD (the older-than-90-days tick box, "100+" count) |
| MPP_Config | -- | no changed resources, not part of this release |

In the range but shipping nothing: tests under `sql/tests/`, `notes/` (review log, handoff, this runbook),
`sql/scratch/`.

## 2. What the database change is

| | |
|---|---|
| Migrations | 11 -- all index-only (12 indexes), no column change, no data change, no backfill |
| Repeatables | 22 changed, 0 new |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window | 0.4 s (sim, empty tables) |

Twelve nonclustered indexes, each built inside the release transaction by one scan of its table. On prod the biggest
are the six on `Lots.Lot` (~41k rows on 2026-11-10) and the one on `Workorder.RejectEvent` (partitioned; built per
partition, aligned so partition `TRUNCATE` still works). Expect the prod lock window to be a few seconds, not 0.4 s;
the rehearsal measures it.

## 3. Risk

**Low-to-moderate**, from the four tests in `prod-release-context-pack/02_scoping_a_release.md`:

1. **Does anything refuse what it used to allow?** No proc gained a rejection. The one behaviour change is LOT Search's
   90-day default (section 1). No write path changed: the three die-cast write procs (`DieCastLot_Open`,
   `DieCastScrap_Write`, `ToolCavity_Deprecate`) only gain an index that serves their reads.
2. **Shared code?** Yes: `BlueRidge.Lots.Lot` (Core script). Only its search functions changed, but section 6 checks
   a non-search surface that uses the module.
3. **Metadata-only?** No: twelve index builds. Each is offline on Standard edition, so writes to that table wait while
   it builds. All are inside the one transaction, behind the `TABLOCKX` freeze, so the plant waits seconds, once.
   Every new `Lots.Lot` index leaves out `PieceCount`, so die-cast cavity credits (the hottest write) never touch them.
4. **Does the old Ignition keep working on the new SQL?** Yes. `Lot_Search` keeps its `TotalCount` column, adds
   `HasMore`, and `@IncludeOlder` defaults to 0; every other proc keeps its parameters and result shape. The SQL step
   and the import are independent; no rush between them.

Evidence: full suite on `main` **5,813 / 5,813**, exit 0. Every PR was reviewed against the original proc and tested
merged onto `main` before approval; same rows, same order was checked with order-sensitive checksums on loaded
throwaway databases.

## 4. Deploy

Make a clean checkout of `main` (your `jacques/working` tree is not on this release):

```powershell
git -C C:\Users\JacquesPotgieter\Documents\Dev\MPP fetch origin
git -C C:\Users\JacquesPotgieter\Documents\Dev\MPP worktree add --detach C:\wt\release origin/main
Set-Location C:\wt\release
git diff --stat 177f0b7a..HEAD -- ignition/ sql/
```

The last command must print nothing (section header).

```powershell
$env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
```

### Step 0 -- Snapshot the queues (read-only)

```powershell
sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -I -C -W -i sql\scratch\2026-11-10_queue_read_snapshot.sql -o C:\wt\queue_snapshot_before.txt
```

One row per line and queue read, then `TotalRows / TotalChecksum`. Keep the file for Step 4.

### Step 1 -- Preview (read-only)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect (verbatim from the sim):

```
[3] Versioned migrations
  Database: 116 applied, highest 0117.
  Pending (11):
    + 0118_lot_open_lot_indexes.sql
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

[4] Repeatables -- target definitions vs this checkout
  590 identical, 22 changed, 0 new on the target.

[5] Pre-flight gates (read-only, against live data)
  No gates fired.

[8] Plan
  11 migration(s), 22 repeatable(s) in one transaction; then R__Descriptions_ExtendedProperties.sql after commit.
  Plan fingerprint: <12 hex>

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

The sim printed `e8755740d96a` at `HEAD 177f0b7a`. Yours will differ because `HEAD` includes this note.

**If it differs:**
- *Not 116 applied / highest not `0117`* -- the 2026-11-04 bundle is not fully on prod, or something was deployed
  outside the process. Stop and reconcile.
- *Pending is not exactly these 11* -- stop.
- *More than 22 CHANGED, or any NEW* -- prod carries a hand-patched object. Read the per-object diffs in the report's
  `diffs` folder before going on.
- *`[WARN] activity`* -- a transaction is open on prod. Wait for it.
- *Fingerprint* -- **use the one YOUR preview printed. Copy it, do not retype it.**

### Step 2 -- Rehearse (applies, verifies, rolls back)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE`. Expect 33 step markers (`[1]`-`[11]` the migrations in the order above, `[12]`-`[33]` the
repeatables), then:

```
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept
  REHEARSAL PASSED and was rolled back. Lock window: <n>s.
```

Note the lock window in section 8; a few seconds is expected. **If the rehearsal fails, stop** -- it failed against
prod's actual rows. Nothing was kept. `0118` or `0121` refusing (status Id 4 not Closed / Id 7 not ReworkFilling) means
prod's code tables differ from every other environment; do not edit the migration, reconcile first.

### Step 3 -- Execute

Quiet moment preferred (between baskets, not at shift change).

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <fingerprint>
```

Type `MPP_MES_Prod`. Expect (verbatim from `MPP_MES_ProdSimSP2`):

```
[9] Backup
  BACKUP DATABASE -> ...\MPP_MES_Prod_pre-release_0117_<stamp>.bak (COPY_ONLY, CHECKSUM)
  Backup written and verified.
[10] Running the release transaction
    ...33 step markers...
    == checks passed
    == COMMITTED
[11] After commit
  R__Descriptions_ExtendedProperties.sql applied.
  Every repo migration is recorded.
  All 22 applied repeatable(s) now match the repo byte-for-byte.
DONE
```

Write the backup path into section 8.

### Step 4 -- Snapshot again and compare

```powershell
sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -I -C -W -i sql\scratch\2026-11-10_queue_read_snapshot.sql -o C:\wt\queue_snapshot_after.txt
fc C:\wt\queue_snapshot_before.txt C:\wt\queue_snapshot_after.txt
```

Expect `FC: no differences encountered`. One differing line is most likely the plant moving a LOT between the runs;
many mean the new reads disagree with the old ones -- section 7.

## 5. Ignition imports (after the SQL; no rush, see section 3 test 4)

Archives, built from git with `tools/Build-ChangeExport.ps1 -Since 96651770 -Label sp-review` at `177f0b7a`, in
`C:\Users\JacquesPotgieter\Documents\Dev\MPP\dist\ignition-exports\`:

| Order | Archive | Resources |
|---|---|---|
| 1 | `Core_sp-review_2026-11-16_1606.zip` | 3: `named-query/lots/Lot_Search`, `named-query/lots/Lot_SearchAdvanced`, `script-python/BlueRidge/Lots/Lot` (all MOD) |
| 2 | `MPP_sp-review_2026-11-16_1606.zip` | 1: `Views/BlueRidge/Views/ShopFloor/LotSearch` (MOD) |

MPP_Config has no changed resources and is not part of this release. No deletions, no hand steps.

Designer -> File -> Import, Core first, accept overwrite. Not the Gateway web import. Then F5 every open shop-floor
screen.

## 6. Verification (most important first)

**6.1 The tray close.** Close one Assembly OUT tray and confirm it records. That is what froze on 2026-11-10.

**6.2 LOT Search -- the only visible change.** Search a partial LOT name: results are the last 90 days, count shows
"100+" when capped. Tick *Search older than 90 days*: older LOTs appear. Search an old LOT by its exact name without the
tick: it is found.

**6.3 A non-search use of `BlueRidge.Lots.Lot`** (shared module). Open a die-cast terminal: the right-rail activity log
and the open baskets list should load as before. Then open one LOT's details from any queue.

**6.4 The polled screens load instantly and look the same:** Machining IN, a WIP queue (Trim OUT / Machining OUT /
Assembly), the M&A Line Inventory sidebar, the scale station (press a box), the downtime header, the print-failure
banner.

**6.5 SQL** (values confirmed on `MPP_MES_ProdSimSP2` after a real Execute):

```sql
SELECT COUNT(*) AS Applied, MAX(MigrationId) AS Highest FROM dbo.SchemaVersion;   -- 127 | 0133_shippinglabel_aimshipperid_index
SELECT OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS TableName, i.name, ds.type_desc
FROM sys.indexes i JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
WHERE i.name IN ('IX_Lot_NotClosed_Location','IX_Lot_NotClosed_Item','IX_ShippingLabel_FailedUnacked',
  'IX_Container_ReworkFilling','IX_Lot_DieCastByTerminal','IX_Lot_VendorLotNumber','IX_ContainerTray_ClosedAt',
  'IX_DowntimeEvent_Location_Shift','IX_Lot_Tool_NotClosed','IX_RejectEvent_ItemRecordedAt',
  'IX_Lot_ToolCavity_Status','IX_ShippingLabel_AimShipperId')
ORDER BY 1, 2;
-- 12 rows; Workorder.RejectEvent / IX_RejectEvent_ItemRecordedAt is PARTITION_SCHEME, the other 11 ROWS_FILEGROUP
```

**6.6 Over the next shifts.** Watch the gateway log for SQL error **1205** (deadlock victim). None for several shifts is
the signal to consider reverting MAXDOP (section 7).

## 7. Rollback

- **Before COMMIT:** automatic. Any failure rolls the whole release back; prod is unchanged.
- **After COMMIT, if one screen shows wrong rows:** put that one proc back from the previous release; the indexes are
  harmless and can stay. Example for the WIP queue:
  ```powershell
  git show 96651770:sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql > C:\wt\rb_wip.sql
  sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -I -C -b -i C:\wt\rb_wip.sql
  ```
  Same pattern for any of the 22. **Exception, `Lot_Search` / `Lot_SearchAdvanced`:** the new named queries pass
  `@IncludeOlder`, which the old procs do not accept, so rolling back only the SQL breaks LOT Search. Restore both
  halves together: the old procs **and** the Core / MPP resources from git at `96651770`.
- **Full restore** from the Step 3 backup is not warranted: nothing here changes data.
- **MAXDOP** (set to 1 by hand during the 2026-11-10 incident) is not part of this release. Revert separately once 6.6
  has been quiet for several shifts: `ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 0;` in `MPP_MES_Prod`.
- **Ignition:** re-import the previous resources from git at `96651770` if needed.

## 8. Outcome -- filled in after the release

_(still to fill in)_

| | |
|---|---|
| Executed at (ET) | |
| Prod before | SQL `0117`, 116 migrations (expected) |
| Plan fingerprint | |
| Preview: pending / changed | |
| Gates fired | |
| Rehearsal lock window | |
| Backup path | |
| Report folder | |
| Queue snapshot before / after | |
| Ignition imports | |
| Notes | |

## 9. Follow-up this release creates

**PR 16 (container-as-LOT) must renumber `0119` before it ships.** Once prod has `0133` applied, a pending `0119` sits
below the high-water mark and the preview BLOCKs it as out of order. Renumber to `0134` or later.
