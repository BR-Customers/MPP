# Prod release runbook -- everything pending: super-lot (all six pieces), the Assembly Out scale station, multi-reason scrap, and the Ignition held back since 2026-10-07

**Release commit:** `9d45ca07` on `jacques/working` -- the commit the SQL plan and the archives were built and
verified from. (`HEAD` will be the commit of this note or later; see the drift rule below.)
**Previous releases:** SQL -- the die cast shift-end release `846f636d`, executed 2026-10-08 09:00 ET (prod's
`DieCastShiftOutput_Record` / `DieCastCredit_Write` / `DieCast_GetShiftOutputBreakdown` /
`ufn_CavityCreditedWithoutReading` all carry that timestamp). Prod is at SQL **`0108`**, 107 migrations
(confirmed 2026-10-21 by query). Ignition -- **not on record**: the 2026-10-07 bundle (`0647dc97`) was imported;
whether the AIM serial fix (`6023e7f9`) and the die cast shift-end archives (`846f636d`) were imported is
not written down. **So the archives are built from `0647dc97`**, the last import known for certain: a superset,
which re-imports those two releases' resources if they are already there (harmless -- same bytes).
**Rehearsed against:** `MPP_MES_ProdSimSL`, built from a worktree at `846f636d` with no demo seed -- prod's state
(107 applied, highest `0108`, `Workorder.ufn_CavityCreditedWithoutReading` present, `Quality.ControlledRun`
and `Audit.InterfaceLog.LocationId` absent). Preview + Rehearse clean, rollback verified, it is still at prod's
state. A full **Execute** ran against a second sim, `MPP_MES_ProdSimSL2`, to cover the backup, the post-commit
step and section 6.9.
**SQL suite:** **5,301 / 5,301 passed, 0 failed, exit 0** on the merged tree (`MPP_MES_CRTest_Merge`, merge
`6e2c44d4`). The commits after it change only `sql/scripts/Deploy-ProdRelease.ps1` (gates) and docs.

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint's first
> hashed line is the raw HEAD sha, so **any** commit changes it -- a docs-only commit included -- and Execute
> refuses. Re-preview and use the new fingerprint.
>
> **Two separate tests. Do not collapse them.** A docs-only commit invalidates the **fingerprint** but leaves
> the **archives** valid:
> ```powershell
> git diff --stat 9d45ca07..HEAD -- ignition/ sql/
> ```
> Expect **no output**. Anything listed means the archives or the SQL plan are stale -- rebuild, then re-preview.

> **Read this before deciding to ship.** What has and has not been proven:
>
> 1. **SQL:** full suite green on the merged tree; preview, rehearsal (1.7 s) and a real Execute (1.5 s) on
>    sims at prod's state.
> 2. **Super-lot screens, walked on Dev at 1920x1080 (2026-10-21):** super-lot page opened by run number, its
>    History tab, Close blocked with SQL's reason, Print report; LOT Detail chip + Super-lots tab (member and
>    never-a-member LOTs) + History showing audit rows; dashboard tile; Reports > Super-lot rendering every
>    section through Ignition's JDBC; Track & Trace (LOT and container, super-lot marker); Genealogy viewer
>    (node tap opens LOT Detail); **the CRT clear behind the supervisor sign-in with the amber super-lot
>    note**, and **a signed super-lot release** with `admin1` -- which wrote "Released, signed ADM1" onto the
>    LOT's 20-year history. No script errors in `wrapper.log`.
> 3. **Not walked by anyone:** the Repack popup and its line pick, Return to vendor (mark / confirm / cancel),
>    a trim rework end to end, the New super-lot wizard past step 1, a deviation signature. All are covered by
>    the SQL suite; the screens are not.
> 4. **Not proven on any gateway:** the AIM post format change (`6023e7f9`) -- the first prod post after the
>    import is its test, exactly as its own runbook said. The Assembly Out scale station has run on Dev against
>    the simulated EPrint page and the office scale test, not on a production line.
> 5. **Prod's `page-config`, Core `stylesheet` and MPP `session-props` were not compared with the repo.** Each
>    ships as one whole resource; a hand edit made on the prod Gateway since 2026-10-07 is overwritten.

---

## 1. What this ships

**Super-lot / nonconformance (MPP's two change orders), all six pieces.** Quality can group LOTs and finished
containers into a super-lot (CRT on every member, a printed super-lot label, an optional rolling window that
tags new production of one part on one line), record per-member results (accepted, scrap, use-as-is under a
signed deviation, return to vendor), repack a container (old shipper serial voided, a new one claimed at
completion), send a LOT back through trim as a tracked rework, and release members with a signed statement.
Everything about it is visible on LOT Detail (chip, Super-lots tab, full history), Track & Trace, the
Genealogy viewer, the Supervisor Dashboard (Open super-lots, Parts to return) and a Super-lot PDF report.
Page: `/shop-floor/controlled-runs` (also `/shop-floor/controlled-runs/<RunNumber>`).
**Nothing changes on the floor until Quality opens a super-lot**, with three exceptions in section 3.

**Assembly Out By Weight: the scale station.** The By Weight Assembly Out screens show the scale station
(running part, press log, shift tally, recent boxes) and **lose the Weigh & Close button** -- a box closes from
the scale's EPrint press. Each press is logged to `Audit.InterfaceLog` with the terminal, part and LOT. The
IND570's own UNDER / OVER / OK flags are logged and compared with the MES verdict, never acted on.

**Also in the range:** multi-reason scrap entry (tiles) on the Machining and Assembly scrap popup;
Quality-screen elevation window values on the session policy; and the Ignition halves of the AIM serial fix
(`6023e7f9`) and the die cast shift-end + Terminal Onboarding release (`846f636d`) in case they were never
imported.

**Ships nothing:** `docs/`, `notes/`, `sql/tests/`, `mockup/`, `reference/`, the data model docs.

## 2. What the database change is

| | |
|---|---|
| Migrations | 6 -- `0109_controlled_run`, `0110_controlled_run_results_signoff`, `0111_container_rework`, `0112_rework_and_vendor_return`, `0113_interfacelog_context`, `0114_super_lot_visibility` |
| Repeatables | 99 -- 72 new, 27 changed |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window | 1.7 s (sim); Execute 1.5 s |

Why it is cheap: `0109`-`0112` create new tables and add columns to tables that are empty on prod
(`ControlledRunMember`) or add **nullable** columns to existing ones (`AimShipperIdPool` void columns,
`ContainerSerial.RemovedAt`) -- metadata-only. `0111` inserts two container statuses with fixed ids 6 and 7
(gated, see Step 1). `0113` adds three nullable FK columns to `Audit.InterfaceLog` (metadata-only) and a
**filtered** index that scans the table once inside the transaction and starts empty; its
`ScaleRunningItemId` attribute goes on location type definition 7 (gated: must be `Terminal`). `0114` adds
two columns to the small `Audit.LogEventType` code table (one `NOT NULL DEFAULT 0`), six event codes, and two
indexes on `Lots.ContainerSerialHistory`.

## 3. Risk

**Test 1 -- does anything now refuse what it used to allow?** Narrowly:
- **A supervisor override move back into Trim IN now starts a tracked rework.** The LOT's Trim steps re-arm,
  it reappears in the Trim queue, and its next Trim OUT closes the rework -- counted on its own, not as shift
  trim production. A rework left open blocks a super-lot release ("At trim rework"); a zero-scrap Trim OUT is
  the undo. Today such moves just move the LOT.
- `Lot_MoveToValidated` refuses an override user id that is not in `AppUser` ("Override user not found") --
  only reachable with a bad id from a script.
- Session policy update refuses Quality-window values outside 30-3600 s idle / ceiling up to 28,800 s.
- A container whose trays are on CRT through a super-lot is refused at the dock and its unposted AIM serial is
  held -- only once a super-lot exists.
- **Assembly Out By Weight loses Weigh & Close** (section 1). Anyone used to the button will look for it.

**Test 2 -- shared code.** `Common.Session` (every elevated action) and `ElevationModal` (every sign-in box)
changed: an optional note, default empty. `Lot_GetAttributeHistory` (every LOT's History tab) now also lists
the LOT's audit log. `Lot_MoveTo` / `_MoveToValidated` / `_Split` / `_Merge`, `Assembly_ScanIn`,
`MachiningIn_RecordPick`, `MachiningOut_Mint` changed (CRT refusal text names the super-lot; rework start).
Trace procs and `Container_ListShipped` (Shipping History) gained columns. Section 6.2 exercises a non-feature
elevated action.

**Test 3 -- schema.** Metadata-only except the `0113` filtered index (one scan of `Audit.InterfaceLog`; Step 1
prints its row count) and the `0114` indexes on a small table. No drops, no backfills.

**Test 4 -- old Ignition against the new SQL.** Every changed proc keeps its parameters (new ones optional, new
columns appended), so the current prod Ignition keeps working once the SQL lands. **SQL and the imports are
independent steps**; there is no rush between them -- but the scale station and every super-lot screen need
both.

## 4. Deploy

Run from **`C:\Users\JacquesPotgieter\Documents\Dev\MPP`** on `jacques/working`. The preview BLOCKs only on
uncommitted changes under `sql/migrations` (your uncommitted `page-config/resource.json`,
`ScaleEPrintMessage/resource.json` and the 10-08 runbook edits do not ship and do not block).

```powershell
$env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
```

### Step 1 -- Preview (read-only)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect (from the sim):

```
[3] Versioned migrations
  Database: 107 applied, highest 0108.
  Pending (6):
    + 0109_controlled_run.sql
    + 0110_controlled_run_results_signoff.sql
    + 0111_container_rework.sql
    + 0112_rework_and_vendor_return.sql
    + 0113_interfacelog_context.sql
    + 0114_super_lot_visibility.sql

[4] Repeatables -- target definitions vs this checkout
  481 identical, 27 changed, 72 new on the target.

[5] Pre-flight gates (read-only, against live data)
  [INFO] 0113: adds 3 nullable FK columns to Audit.InterfaceLog (metadata-only) and a filtered index that
         scans its <N> existing row(s) once inside the release transaction; the index starts empty.
  [INFO] 0114: adds two Audit.LogEventType columns + six codes, and two indexes on
         Lots.ContainerSerialHistory (<N> existing row(s)).

[8] Plan
  6 migration(s), 99 repeatable(s) in one transaction; then R__Descriptions_ExtendedProperties.sql after commit.
  Plan fingerprint: <12 hex>

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

**If it differs:**
- *Pending is not exactly `0109`-`0114`* -- prod is not at `0108`. Stop and reconcile.
- *More than 27 CHANGED* -- prod carries a hand-patched proc or a release this runbook does not know of.
  Read the per-object diffs in the report's `diffs` folder before going on. A larger list is information,
  not automatically an error, but this runbook then no longer describes what you are about to do.
- *`[BLOCK] 0111`* -- prod already uses container status id 6 or 7 for something else. Stop; the migration
  must be renumbered.
- *`[BLOCK] 0113`* -- location type definition 7 is not `Terminal` on prod. Stop; the migration must look the
  definition up by code.
- *`0113`'s InterfaceLog count is in the millions* -- the scan adds seconds to the lock window. Still safe;
  pick a quiet moment.
- *`[WARN] activity`* -- a transaction is open on prod. Wait for it, or the deploy waits on its locks.
- *Fingerprint* -- the sim printed one at this HEAD (see the guide); a match corroborates the state. **Use the
  one YOUR preview printed. Copy it, do not retype it.**

### Step 2 -- Rehearse (applies, verifies, rolls back)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE` when asked. Expect 105 step markers (`== [1] migration 0109_controlled_run` ...
`== [105] R__Workorder_TrimPartial_Record.sql`), then:

```
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept
  REHEARSAL PASSED and was rolled back. Lock window: 1.7s.
```

Prod's lock window will differ (live data). **If the rehearsal fails, stop** -- it failed against prod's actual
rows, the one thing the sims cannot simulate. Nothing was kept.

### Step 3 -- Execute

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <fingerprint>
```

Type `MPP_MES_Prod` when asked. Expect:

```
[9] Backup
  BACKUP DATABASE -> ...\MPP_MES_Prod_pre-release_0108_<stamp>.bak (COPY_ONLY, CHECKSUM)
  Backup written and verified.
[10] ... == COMMITTED
[11] After commit
  R__Descriptions_ExtendedProperties.sql applied.
  Every repo migration is recorded.
  All 99 applied repeatable(s) now match the repo byte-for-byte.
DONE
```

Write the backup path into section 9.

## 5. Ignition imports -- SQL first, then Core, then MPP

Designer -> File -> Import, one zip at a time, accept the overwrites. **Not** the Gateway web import.
Files in `dist\ignition-exports\` of the release checkout (built from git at `9d45ca07`, range `0647dc97..9d45ca07`):

1. `Core_superlot-scale-bundle_2026-10-21_2245.zip` -- **83 resources** (named queries for super-lot, rework,
   vendor return, scale station; scripts incl. `Common/Session`, `Lots/AimHttp` + `AimPost`,
   `Quality/ControlledRun`, `Workorder/ScaleStation`; the Core `stylesheet`).
2. `MPP_superlot-scale-bundle_2026-10-21_2245.zip` -- **68 resources** (the super-lot views and popups, LOT
   Detail, Track & Trace, Genealogy, Supervisor Dashboard, Reports page + the `Super-lot` report, both Assembly
   Out screens, Trim, Machining IN / OUT split, Die Cast, `ElevationModal`, `page-config`, `session-props`, the
   `ControlledRunSyncTimer` gateway timer).
3. **MPP_Config has no changed resources** and is not part of this release.

The full NEW / MOD checklist with commits is `superlot-scale-bundle_2026-10-21_2245_CONTENTS.txt`
(108 NEW, 43 MOD). Nothing was deleted in the range.

**Whole-resource overwrites to look at in the import dialog:** `page-config` (every MPP route; adds
`/shop-floor/controlled-runs/:runNumber`, the scale station dev routes, `/shop-floor/terminal-onboarding`),
Core `stylesheet`, MPP `session-props` (adds `elevationProfile`, `elevatedGrantedAt` and the Quality window
policy keys). If any of them is a surprise, stop and export prod's copy first.

**The `ControlledRunSyncTimer` ships DISABLED and stays disabled.** The rolling window still works (a super-lot
syncs when it is opened on screen and before it closes); enable the timer only as a separate decision.

**Then F5 every open shop-floor session** (not the Designer).

## 6. Verification -- ordered by risk

### 6.1 First AIM post after the import (never proven on any gateway)
Complete one container at an assembly line as normal. In the AIM owed-to list it must clear within a minute,
and `Audit.InterfaceLog` shows the post with the serial as `0` + its last 8 digits. *Not On File* or a stuck
post -> the AIM serial fix is wrong; roll back `Lots/AimHttp` from the ROLLBACK Core zip (section 7).

### 6.2 A sign-in that is NOT the feature (shared `Common.Session` + `ElevationModal`)
At a die cast terminal, Supervisor Access -> sign in. The box looks as before: no empty amber bar under the
prompt, and the Authenticate button is on screen.

### 6.3 Assembly Out By Weight
On a By Weight line: the scale station panel shows the running part, the last presses and the shift tally; a
press on the scale closes a box and prints its label. There is no Weigh & Close button (by design).

### 6.4 An ordinary LOT
LOT Detail on any recent LOT: the History tab shows the same lines as before plus any CRT / vendor return /
rework rows; the **Super-lots** tab reads *"This LOT has never been part of a super-lot."*; no red component
errors anywhere on the page.

### 6.5 Trim and Machining still move
One normal Trim OUT, and one Machining IN pick from trim storage, record as before.

### 6.6 The super-lot surfaces
`/shop-floor/controlled-runs` opens with no super-lots listed; the Supervisor Dashboard shows **Open super-lots
0 -- none open** and **Parts to return 0**; Reports lists **Super-lot**.

### 6.7 Scrap by tiles
On a Machining or Assembly scrap popup, two reasons entered as tiles save as two reject rows.

### 6.8 Shipping History report
Runs for last week in about the time it did before (its read gained three count columns).

### 6.9 SQL, after commit (values confirmed on `MPP_MES_ProdSimSL2`)

```sql
SELECT COUNT(*) AS Applied, MAX(MigrationId) AS Highest FROM dbo.SchemaVersion;              -- 113 | 0114_super_lot_visibility
SELECT COUNT(*) FROM Audit.LogEventType WHERE RepeatsLotTimeline = 1;                         -- 13
SELECT COUNT(*) FROM Audit.LogEventType WHERE Code LIKE N'ControlledRunLot%';                 -- 6
SELECT COUNT(*) FROM Lots.ContainerStatusCode;                                                -- 7
SELECT COUNT(*) FROM Location.LocationAttributeDefinition
 WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'ScaleRunningItemId' AND DeprecatedAt IS NULL;  -- 1
SELECT COL_LENGTH('Audit.InterfaceLog','LotId');                                              -- 8
SELECT name FROM sys.indexes WHERE object_id = OBJECT_ID('Lots.ContainerSerialHistory');      -- includes IX_CSH_OldContainer, IX_CSH_NewContainer
```

## 7. Rollback

- **Before COMMIT** (preview, rehearsal, a failed execute): nothing to do; the transaction rolled back.
- **After COMMIT, SQL:** the migrations only add, so leaving them is harmless. To put a proc back, its prod
  definition before the release is in the Execute report's `diffs\<object>.target.sql`; run that file against
  `MPP_MES_Prod`. A full restore from the COPY_ONLY backup loses every plant transaction since -- last resort.
- **Ignition:** import `Core_superlot-scale-bundle-ROLLBACK_2026-10-21_2245.zip` (23 resources) then
  `MPP_superlot-scale-bundle-ROLLBACK_2026-10-21_2245.zip` (22 resources): every MODIFIED resource back to its
  `0647dc97` version. The 108 NEW resources stay (an import cannot delete); they are unreachable once
  `page-config` and the screens are rolled back, except the named queries, which are harmless. To remove them,
  delete them by hand in the Designer (list: `superlot-scale-bundle-ROLLBACK_2026-10-21_2245_CONTENTS.txt`).
  F5 the sessions.

## 8. Not in this release

The super-lot follow-ons (BOM-component partial fill, AIM cancellation post for a voided posted serial, a
Quality AD role, the wizard's last-step password, line scrap by part across CRT and clean LOTs) and the
Assembly Out scale station's production-line proving.

## 9. Outcome -- filled in after the release

_(still to fill in)_

| | |
|---|---|
| Executed at (ET) | |
| Prod before | SQL `0108`, 107 migrations |
| Plan fingerprint | |
| Preview: changed / new | |
| Gates fired | |
| Rehearsal lock window | |
| Execute lock window | |
| Backup | |
| Report folders | |
| Core / MPP imported at | |
| 6.1 first AIM post | |
| 6.2 - 6.9 | |
| Anything sideways | |
