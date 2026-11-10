# Prod release runbook -- queue-read deadlock fix (`0118`)

**Release commit:** `36bf2274` on `jacques/working` -- the last commit that changes `sql/`. (`HEAD` will be
this note's commit or later; see the drift rule below.)
**Previous release:** `96651770` (2026-11-04 bundle, executed Thursday 2026-11-05).
**Rehearsed against:** `MPP_MES_ProdSimDL`, built at `96651770` -- prod's expected state (116 migrations,
highest `0117`, `IX_Lot_NotClosed_*` absent). Preview + Rehearse clean; a real Execute on a second sim
(`MPP_MES_ProdSimDL2`) confirmed the backup, post-commit and section 6 values.
**Why:** the 2026-11-10 incident (`notes/2026-11-10_prod-incident-assembly-out-deadlock.md`): Assembly OUT
stopped recording trays for 83 minutes.

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint's first
> hashed line is the raw HEAD sha, so **any** commit changes it -- a docs-only commit included -- and Execute
> refuses. Re-preview and use the new fingerprint.
>
> **This release has no Ignition half**, so the only drift test is:
> ```bash
> git diff --stat 36bf2274..HEAD -- ignition/ sql/
> ```
> Expect only `sql/scratch/2026-11-10_queue_read_snapshot.sql` (the read-only check in section 4, not
> deployed). Anything else listed means this runbook no longer describes the release -- stop.

## 1. What this ships

The two plant-floor queue reads stop scanning the whole LOT table. The Machining IN list
(`Lot_GetTrimStorageQueueForLine`) and the WIP queues used at Trim, Machining OUT and Assembly
(`Lot_GetWipQueueByLocation`) now look up only the open LOTs for their line or location, through two new
small indexes. **Operators see no difference**: same LOTs, same order, same columns. The reads get much
cheaper: on a 5.5-million-LOT bench, 10-13 s and ~500,000 page reads became ~150-220 page reads.

That removes what caused the 2026-11-10 freeze. Those reads were locking whole pages of the LOT table in
parallel, and one of them deadlocked with an Assembly OUT tray close in a way SQL Server could not detect.

| SQL object | Change |
|---|---|
| `0118_lot_open_lot_indexes` | NEW migration: `IX_Lot_NotClosed_Location`, `IX_Lot_NotClosed_Item` on `Lots.Lot`, filtered `LotStatusId <> 4` |
| `Lots.Lot_GetWipQueueByLocation` | v3.2 -> v3.3 (same parameters, same result shape) |
| `Lots.Lot_GetTrimStorageQueueForLine` | v2.0 -> v2.1 (same parameters, same result shape) |

**Ignition: nothing.** No view, script or named query changed. There are no exports for this release, and
no Gateway step.

In the range but shipping nothing: the incident note, the Data Model (v3.11.2), test `0118/010`, and
`sql/scratch/2026-11-10_queue_read_snapshot.sql`.

## 2. What the database change is

| | |
|---|---|
| Migrations | 1 -- `0118_lot_open_lot_indexes` |
| Repeatables | 2 changed, 0 new |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only, unchanged) |
| Rehearsal lock window | 0.2 s (sim) |

Two filtered indexes over the **open** LOTs only (prod 2026-11-10: 2,400 of 41,174), built inside the release
transaction. Each scans `Lots.Lot` once (41k rows, well under a second) and holds ~2,400 rows. No column
change, no backfill, no data change.

`0118` refuses to run if `Lots.LotStatusCode` Id 4 is not `Closed`, because the index filter is that literal.
It is 4 on every environment (seeded fixed in `0004`).

## 3. Risk

**Low.** Two read procs and two additive indexes.

- **Same rows, same order:** proven on the 5.5M-LOT bench (71 cases, 0 differences, content and position).
  Test suite 5,623 / 5,623. Scrap-status LOTs, which the older `IX_Lot_Active` would have dropped, are still
  listed (pinned by test `0118/010`).
- **Nothing refuses anything new.** No mutation proc changed. The tray close itself is untouched.
- **Write cost:** every insert or status change on `Lots.Lot` now maintains two more small indexes.
  Negligible at plant rates.
- **MAXDOP stays at 1** (set by hand during the incident). This release does not touch it; see section 7.

## 4. Deploy

Run from **`C:\Users\JacquesPotgieter\Documents\Dev\MPP`** on `jacques/working`.

```powershell
$env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
```

### Step 0 -- Snapshot the queues (read-only)

```powershell
sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -I -C -W -i sql\scratch\2026-11-10_queue_read_snapshot.sql -o dist\queue_snapshot_before.txt
```

Writes one row per line and read (rows returned plus a checksum) and a final `TotalRows / TotalChecksum` line.
Keep the file; Step 4 compares against it. With MAXDOP 1 the old reads are slow, so expect this to take some
seconds per line.

### Step 1 -- Preview (read-only)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect (from the sim):

```
[3] Versioned migrations
  Database: 116 applied, highest 0117.
  Pending (1):
    + 0118_lot_open_lot_indexes.sql

[4] Repeatables -- target definitions vs this checkout
  610 identical, 2 changed, 0 new on the target.
    CHANGED  R__Lots_Lot_GetTrimStorageQueueForLine.sql
    CHANGED  R__Lots_Lot_GetWipQueueByLocation.sql

[5] Pre-flight gates (read-only, against live data)
  No gates fired.

[8] Plan
  1 migration(s), 2 repeatable(s) in one transaction; then R__Descriptions_ExtendedProperties.sql after commit.
  Plan fingerprint: <12 hex>

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

**If it differs:**
- *Pending is not exactly `0118`* -- prod is not at `0117`. Stop and reconcile.
- *Not 116 applied* -- the 2026-11-04 bundle is not fully on prod. Stop.
- *More than 2 CHANGED* -- prod carries a hand-patched proc or a change this runbook does not know of. Read
  the per-object diffs in the report's `diffs` folder before going on.
- *`[WARN] activity`* -- a transaction is open on prod. Wait for it. If it is a stuck queue read like the
  incident's, the incident note says how to clear it.
- *Fingerprint* -- **use the one YOUR preview printed. Copy it, do not retype it.**

### Step 2 -- Rehearse (applies, verifies, rolls back)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE` when asked. Expect:

```
    == transaction open
    == [1] migration 0118_lot_open_lot_indexes
    == [2] R__Lots_Lot_GetTrimStorageQueueForLine.sql
    == [3] R__Lots_Lot_GetWipQueueByLocation.sql
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept
  REHEARSAL PASSED and was rolled back. Lock window: 0.2s.
```

Prod's lock window will be a little longer (two index scans of 41k LOTs under live traffic). **If the rehearsal
fails, stop** -- it failed against prod's actual rows. Nothing was kept.

### Step 3 -- Execute

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <fingerprint>
```

Type `MPP_MES_Prod` when asked. Expect:

```
[9] Backup
  BACKUP DATABASE -> ...\MPP_MES_Prod_pre-release_0117_<stamp>.bak (COPY_ONLY, CHECKSUM)
  Backup written and verified.
[10] Running the release transaction
    == [1] migration 0118_lot_open_lot_indexes
    == [2] R__Lots_Lot_GetTrimStorageQueueForLine.sql
    == [3] R__Lots_Lot_GetWipQueueByLocation.sql
    == checks passed
    == COMMITTED
[11] After commit
  R__Descriptions_ExtendedProperties.sql applied.
  Every repo migration is recorded.
  All 2 applied repeatable(s) now match the repo byte-for-byte.
DONE
```

The closing line says to import the Ignition exports: **there are none for this release.** Write the backup path
into section 8.

### Step 4 -- Snapshot again and compare

```powershell
sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -I -C -W -i sql\scratch\2026-11-10_queue_read_snapshot.sql -o dist\queue_snapshot_after.txt
fc dist\queue_snapshot_before.txt dist\queue_snapshot_after.txt
```

Expect `FC: no differences encountered`, and this run to finish in about a second. A difference on one line is
most likely the plant moving a LOT between the two runs; check what that line did in between before treating it
as a fault. Differences on many lines mean the new reads disagree with the old ones: go to section 7.

## 5. Ignition

None. No resources changed, no imports, no hand steps, no session reload needed: the named queries call
the same procs with the same parameters.

## 6. Verification

**6.1 First, the screens.** Open Machining IN on one line and a WIP-queue screen (Trim OUT, Machining OUT or
Assembly). The lists should look exactly as before and load instantly. Then close one Assembly OUT tray and
confirm it records. That tray close is the operation that was frozen out on 2026-11-10.

**6.2 SQL (values confirmed on `MPP_MES_ProdSimDL2` after a real Execute):**

```sql
SELECT COUNT(*) AS Applied, MAX(MigrationId) AS Highest FROM dbo.SchemaVersion;   -- 117 | 0118_lot_open_lot_indexes
SELECT name, filter_definition FROM sys.indexes
WHERE object_id = OBJECT_ID('Lots.Lot') AND name LIKE 'IX_Lot_NotClosed%' ORDER BY name;
--   IX_Lot_NotClosed_Item      ([LotStatusId]<>(4))
--   IX_Lot_NotClosed_Location  ([LotStatusId]<>(4))
```

**6.3 Gateway.** On the `MPP` database connection's status page, active connections should sit well under the
pool max of 8, and Active Queries should show nothing older than a few seconds.

**6.4 Over the next shifts.** Watch the gateway log for SQL error **1205** (deadlock victim). With MAXDOP 1,
a repeat collision now fails one side in about 5 s instead of freezing. None for several shifts is the signal
to consider reverting MAXDOP (section 7).

## 7. Rollback

- **Before COMMIT:** automatic. Any failure rolls the whole release back; prod is unchanged.
- **After COMMIT, if a queue shows the wrong LOTs** (section 4 Step 4 or 6.1): put the old procs back from
  the previous release. The indexes are harmless and can stay.
  ```powershell
  git show 96651770:sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql      > dist\rb_wip.sql
  git show 96651770:sql/migrations/repeatable/R__Lots_Lot_GetTrimStorageQueueForLine.sql > dist\rb_trim.sql
  sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -I -C -b -i dist\rb_wip.sql,dist\rb_trim.sql
  ```
  That restores the scanning reads, so keep MAXDOP at 1 until a fixed version ships.
- **Full restore** from the Step 3 backup is not warranted for this release: nothing here changes data.
- **MAXDOP** is not part of this release. It reverts separately, once 6.4 has been quiet for several shifts:
  `ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 0;` in `MPP_MES_Prod`.

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
| Notes | |
