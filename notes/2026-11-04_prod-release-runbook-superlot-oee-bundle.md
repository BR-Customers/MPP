# Prod release runbook -- everything pending: super-lot (all six pieces), scale station, multi-reason scrap, die cast default presses, AIM failures in the Failure Log, held-LOT ship block, and the OEE dashboard

**Release commit:** `96651770` on `jacques/working` -- the commit the SQL plan and the Ignition archives were built
and verified from. (`HEAD` will be the commit of this note or later; see the drift rule below.)
**Supersedes:** the 2026-10-21 bundle (`notes/2026-10-21_prod-release-runbook-superlot-scale-bundle.md`,
release commit `9d45ca07`), which was **packaged but never run** -- its Outcome section is blank. Everything it
carried is in this release, unchanged, plus the work merged since. Do not use its archives.
**Previous release (what prod has):** SQL -- the die cast shift-end release `846f636d`, executed 2026-10-08.
Prod is at SQL **`0108`**, 107 migrations (confirmed 2026-10-21 by query; this runbook's Step 1 re-confirms it).
Ignition -- the last import known for certain is the 2026-10-07 bundle `0647dc97`, so **the archives are built
over `0647dc97..96651770`**: a superset, harmless where a later import already landed (same bytes).
**Rehearsed against:** `MPP_MES_ProdSimSL`, built from a worktree at `846f636d` with no demo seed -- prod's state
(107 applied, highest `0108`, `Quality.ControlledRun` and `Lots.Lot.ShiftId` absent). Preview + Rehearse clean
(1.6 s lock window), rollback verified, it is still at prod's state. A full **Execute** ran on a second sim,
`MPP_MES_ProdSimOEE` (same build; the demo seed died after writing 3 LOTs and 2 tools), to cover the backup, the
post-commit step and section 6.10.
**SQL suite:** **5,611 / 5,611 passed, 0 failed, exit 0** on a clean private database (`MPP_MES_Test_Rel1104`,
at `351ff61c`; the commits after it change only `Deploy-ProdRelease.ps1` gates and the first-fill scratch script).
**OEE first fill:** rehearsed and run armed on a restored copy of `MPP_MES_Dev` with its OEE stamps and summary
stripped (141 closed shifts, 118,577 LOTs): rehearsal 1 s, armed 18 s, a second armed run changes nothing.

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint's first
> hashed line is the raw HEAD sha, so **any** commit changes it -- a docs-only commit included -- and Execute
> refuses. Re-preview and use the new fingerprint.
>
> **Two separate tests. Do not collapse them.** A docs-only commit invalidates the **fingerprint** but leaves
> the **archives** valid:
> ```powershell
> git diff --stat 96651770..HEAD -- ignition/ sql/
> ```
> Expect **no output**. Anything listed means the archives or the SQL plan are stale -- rebuild, then re-preview.

> **Read this before deciding to ship.** What has and has not been proven:
>
> 1. **SQL:** full suite green; preview, rehearsal (1.6 s) and a real Execute (1.2 s) on sims at prod's state;
>    the OEE first fill end to end on Dev-sized data.
> 2. **Walked on the Dev gateway:** the super-lot screens (2026-10-21, see that runbook), the Super-lot PDF and
>    release signature card after their fix (2026-10-29), the OEE Site / Area / Unit pages, the Supervisor
>    Dashboard Shift Availability tile and the OEE Summary report (2026-11-03), and **the OEE Unit-page Edit
>    end to end (2026-11-04):** Edit -> supervisor sign-in -> the replayed editor -> save -> "Downtime updated",
>    the page refreshed (66 -> 65 min), the stored shift row recomputed (25 -> 24 min), the audit row credited to
>    the signed-in supervisor.
> 3. **Not walked by anyone:** the Repack popup and its line pick, Return to vendor, a trim rework end to end,
>    the New super-lot wizard past step 1, a deviation signature (all covered by the SQL suite).
> 4. **Not proven on any gateway:** the AIM failure-log write from Python (`AimPost` / `AimPoolGateway` ->
>    `Audit.FailureLog`): on Dev the AIM timers never fired in the test window. The SQL writers are tested.
>    The AIM post format change (`6023e7f9`) -- the first prod post after the import is its test, as before.
>    The Assembly Out scale station has run on Dev against the simulated EPrint page, not a production line.
> 5. **Prod's `page-config`, Core `stylesheet` and MPP `session-props` were not compared with the repo.** Each
>    ships as one whole resource; a hand edit made on the prod Gateway since 2026-10-07 is overwritten. Same for
>    **`MachiningIn`**: `PROJECT_STATUS.md` (2026-09-18) records a **prod-only sizing tweak** on that view, and
>    this import replaces the view (multi-reason scrap, `27eabc7c`). Export prod's copy first (section 5).

---

## 1. What this ships

**OEE dashboard (new).** Availability and quality for every shift, rolled up site -> area -> unit:
`/shop-floor/oee` (plant KPIs and one card per area), `/shop-floor/oee/area/<diecast|trim|ma>` and
`/shop-floor/oee/unit/<locationId>` (gauges, breakdown, downtime Pareto, scrap, the shift's downtime entries
with a supervisor-gated Edit). Shift / Day / Week zoom. Performance and OEE are "coming in a future
deployment" cards. The Supervisor Dashboard's **Shift Availability** tile goes live (plant availability of the
last completed shift; tap opens the dashboard). A new **OEE Summary** PDF report on the Reports page. Per-shift
figures are computed once and stored (`Oee.ShiftSummary`), kept current by two gateway timers and by the
shift-close hook. The menu gains an OEE entry.

**Super-lot / nonconformance (MPP's two change orders), all six pieces** -- exactly as described in the
2026-10-21 runbook section 1: group LOTs and finished containers into a super-lot (CRT on every member, label,
optional rolling window), per-member results, repack, trim rework, vendor return, signed release; visible on LOT
Detail, Track & Trace, Genealogy, the Supervisor Dashboard and a Super-lot PDF report.
Page `/shop-floor/controlled-runs`. **Nothing changes on the floor until Quality opens a super-lot**, with the
exceptions in section 3.

**Assembly Out By Weight: the scale station** -- the screen shows the scale station panel and **loses the
Weigh & Close button**; a box closes from the scale's EPrint press.

**Also:** multi-reason scrap tiles on the Machining and Assembly scrap popup; **die cast default presses** per
terminal (buttons for the terminal's usual presses, with Show all; a terminal with none configured shows every
press, as today; configured in the Config Tool Plant Hierarchy); **AIM failures land in the Failure Log** with
Location and LOT, and the Audit Browser `/failure-log` gains Location / LOT filters and columns; a **held LOT
packed in a container blocks the ship** (section 3); Config Tool unsaved-changes flags that misfired on
untouched editors; Reports Print PDF fixed; Quality elevation window values on the session policy; the Ignition
halves of the AIM serial fix and the die cast shift-end + Terminal Onboarding release, in case they were never
imported.

**Ships nothing:** `docs/`, `notes/`, `sql/tests/`, `mockup/`, `reference/`, `tools/sales-kit/`,
`sql/seeds_demo/`, the data model docs, and the Dev-only scratch `seed_oee_history.sql`, `clear_oee_seed.sql`,
`Measure-OeeDevVolume.ps1`.

## 2. What the database change is

| | |
|---|---|
| Migrations | 9 -- `0109`-`0114` (super-lot, rework, vendor return, InterfaceLog context, visibility), `0115_terminal_default_machines`, `0116_failurelog_location_lot`, `0117_oee_shift_summary` |
| Repeatables | 137 -- 104 new, 33 changed |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Then, by hand | `sql\scratch\2026-11-04_oee_first_fill.sql` (section 4, Step 4) |
| Lock window | Rehearsal 1.6 s, Execute 1.2 s (sims) |

Why it is cheap: `0109`-`0114` as in the 2026-10-21 runbook (new tables; nullable columns; two fixed-id container
statuses, gated). `0115` inserts one attribute definition on location type definition 7 (gated: must be
`Terminal`). `0116` adds two nullable columns to the partitioned `Audit.FailureLog` (metadata-only), two event
types, and two **partition-aligned filtered** indexes that scan the table once and start empty. `0117` adds two
**nullable** columns to `Lots.Lot` (metadata-only), a filtered index that scans `Lots.Lot` once and starts empty,
and two new tables. **No backfill runs inside the release transaction** -- the OEE first fill runs after the
commit, one short transaction per shift.

## 3. Risk

**Test 1 -- does anything now refuse what it used to allow?**
- **A container holding a held LOT is refused at the Shipping Dock** ("LOT `<name>` in this container is on
  hold (cannot ship)"). Today only a hold on the container itself refuses. Completing the container still
  works. The way out: release the LOT's hold, or pull the tray. **The preview's `[5]` counts the containers in
  that state right now** -- each one ships today and is refused after. MPP has not been told yet
  (`notes/2026-10-28_mpp-hold-shipping-and-status-matrix.md`: the email is drafted, not sent).
- **Availability numbers drop** on any screen that already shows them (Downtime Manager, die cast shift
  summary) where two end-of-shift downtime entries overlapped: availability is now the sum of entered
  durations by shift (D17), not a clock merge. That is the fix, not a regression -- say so if asked.
- **An old shift whose schedule was edited since now shows the window it actually ran**, not the schedule's
  current times.
- From the 2026-10-21 bundle, unchanged: a supervisor override move back into Trim IN starts a tracked rework;
  `Lot_MoveToValidated` refuses an unknown override user; the session policy refuses Quality-window values out
  of range; CRT containers held at the dock once a super-lot exists; **By Weight loses Weigh & Close**.

**Test 2 -- shared code.** `Common.Session` + `ElevationModal` (every sign-in box), `Lot_GetAttributeHistory`
(every LOT's History tab), the LOT move / split / merge procs, `Assembly_ScanIn`, `MachiningIn_RecordPick`,
`MachiningOut_Mint` and `Assembly_CompleteTray` (now also stamp `ShiftId` + `MintedPieceCount` on the LOT they
mint), `Oee.Shift` (`tickShiftBoundary` now refreshes the summary when it closes a shift -- never-throw),
`AimPost` / `AimHttp` / `AimPoolGateway` (now write failure rows), `Lots.Container` (`complete`,
`validateCrt`). Sections 6.2-6.5 exercise surfaces that are not the features.

**AIM failures, volume:** with AIM posting **on** (prod), every failed attempt writes one `Audit.FailureLog`
row. During an AIM outage the retry timer can write up to ~50 rows a minute until AIM comes back. Accepted
(2026-10-29); it is the point of the change.

**Test 3 -- schema.** Metadata-only plus three filtered-index scans (`Audit.InterfaceLog`, `Audit.FailureLog`,
`Lots.Lot`; Step 1 prints each count) and two small indexes. No drops, no backfill in the transaction.

**Test 4 -- old Ignition against the new SQL.** Checked on the preview's per-object diffs: no changed proc
loses a parameter or gains a required one; six gain optional parameters (`Audit_LogFailure`,
`Audit_LogInterfaceCall`, `FailureLog_List`, `Container_ListSerials`, `ContainerConfig_JudgeWeight`,
`RejectEvent_RecordByPartFifo`). **The current prod Ignition keeps working once the SQL lands**, so the SQL and
the imports are independent; there is no rush between them. Run the OEE first fill **before** the imports so the
dashboard has history the first time anyone opens it.

## 4. Deploy

Run from **`C:\Users\JacquesPotgieter\Documents\Dev\MPP`** on `jacques/working`. The preview BLOCKs only on
uncommitted changes under `sql/migrations`.

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
  Pending (9):
    + 0109_controlled_run.sql
    + 0110_controlled_run_results_signoff.sql
    + 0111_container_rework.sql
    + 0112_rework_and_vendor_return.sql
    + 0113_interfacelog_context.sql
    + 0114_super_lot_visibility.sql
    + 0115_terminal_default_machines.sql
    + 0116_failurelog_location_lot.sql
    + 0117_oee_shift_summary.sql

[4] Repeatables -- target definitions vs this checkout
  475 identical, 33 changed, 104 new on the target.

[5] Pre-flight gates (read-only, against live data)
  [INFO] 0113: ... scans its <N> existing row(s) once inside the release transaction; the index starts empty.
  [INFO] 0114: ... two indexes on Lots.ContainerSerialHistory (<N> existing row(s)).
  [INFO] 0116: ... two partition-aligned filtered indexes that scan its <N> existing row(s) once ...
  [INFO] 0117: ... a filtered index that scans its <N> existing LOT(s) once inside the release transaction.
         After the commit, the first fill recomputes <S> closed shift(s), the earliest starting <date> ET.
  [INFO] Container_Ship: Container_Ship v1.1 refuses a container holding a held LOT; no complete container
         is in that state now.

[8] Plan
  9 migration(s), 137 repeatable(s) in one transaction; then R__Descriptions_ExtendedProperties.sql after commit.
  Plan fingerprint: <12 hex>

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

**Write down `<S>` (closed shifts) from the `0117` line** -- Step 4 and 6.1 compare against it.

**If it differs:**
- *Pending is not exactly `0109`-`0117`* -- prod is not at `0108`. Stop and reconcile.
- *More than 33 CHANGED* -- prod carries a hand-patched proc or a release this runbook does not know of. Read
  the per-object diffs in the report's `diffs` folder before going on.
- *`[BLOCK] 0111` / `0113` / `0115`* -- a fixed id on prod is not what the migration assumes (container status
  6/7, or location type definition 7 not `Terminal`). Stop; the migration must be fixed in the repo.
- *`[WARN] Container_Ship` with a list* -- those complete containers hold a held LOT and **will be refused at
  the dock after the release**. Not a reason to stop: tell shipping and Quality which containers, before the
  truck. Release the LOT holds that should not be there.
- *An index-scan count in the millions* -- adds seconds to the lock window. Still safe; pick a quiet moment.
- *`[WARN] activity`* -- a transaction is open on prod. Wait for it.
- *Fingerprint* -- **use the one YOUR preview printed. Copy it, do not retype it.** The published guide carries
  the value the sim printed at the final HEAD; a match corroborates the state.

### Step 2 -- Rehearse (applies, verifies, rolls back)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE` when asked. Expect 146 step markers (`== [1] migration 0109_controlled_run` ...
`== [9] migration 0117_oee_shift_summary` ... `== [146] R__Workorder_TrimPartial_Record.sql`), then:

```
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept
  REHEARSAL PASSED and was rolled back. Lock window: 1.6s.
```

Prod's lock window will differ (live data, three index scans). **If the rehearsal fails, stop** -- it failed
against prod's actual rows, the one thing the sims cannot simulate. Nothing was kept.

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
  All 137 applied repeatable(s) now match the repo byte-for-byte.
DONE
```

Write the backup path into section 9.

### Step 4 -- OEE first fill (after the commit, before the imports)

`sql\scratch\2026-11-04_oee_first_fill.sql`: stamps the LOTs minted before `0117` with their shift
(`Lots.Lot_BackfillMintStamp`), computes the stored figures for every closed shift
(`Oee.ShiftSummary_RecomputeRange`), then records the configuration fingerprint
(`Oee.ShiftSummary_RefreshChanged`). Attributed to SYS (AppUser 1). Read the header before running it.

**4a -- rehearse (`@Commit = 0`, as committed).** Backfill runs and rolls back; the 3 latest closed shifts are
computed inside a transaction and rolled back.

```powershell
sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -C -b -W -i .\sql\scratch\2026-11-04_oee_first_fill.sql
```

Expect:

```
Database MPP_MES_Prod on <server> -- @Commit = 0
Before: closed shifts <S>, shifts already stored 0, LOTs already stamped 0
== 1. Lots.Lot_BackfillMintStamp (grid below: one row per candidate LOT)
<one row per M&A / Machining OUT LOT minted since go-live: LotId LotName ShiftId MintedPieceCount Outcome>
== 2. (rehearsal) RecomputeRange from <date> -- the latest closed shifts only, rolled back
   Status 1 -- <3-5> shift(s) computed. -- <s> s
   Stored rows written (before rollback): <n>
== 3. (rehearsal) RefreshChanged not rehearsed -- see the script header.
   Rolled back.
After: shifts stored 0 of <S> closed, LOTs stamped 0, fingerprint recorded no
```

**Read the Outcome column.** Prod records only the MA2-6MACH M&A line, so expect tens to a few hundred rows,
nearly all `Stamped`. `NoShift` (no shift covers the LOT's birth) and `NotReconstructable` (merged away, no
birth audit) stay NULL and out of "good" -- **a handful is expected; more than a few is a stop-and-ask.**
`Status 0` or an error in step 2 is a stop: nothing was kept.

**4b -- arm and run (`@Commit = 1`).** In the working tree only: open the file, change
`DECLARE @Commit BIT = 0;` to `= 1`, save, run the same command, then **set it back to 0 and do not commit it.**

```
Database MPP_MES_Prod on <server> -- @Commit = 1
Before: closed shifts <S>, shifts already stored 0, LOTs already stamped 0
== 1. Lots.Lot_BackfillMintStamp ...  (same grid)
== 2. Oee.ShiftSummary_RecomputeRange <first shift - 1 day> -> <tomorrow> (all history, committed shift by shift)
   Status 1 -- <S> shift(s) computed. -- <s> s
== 3. Oee.ShiftSummary_RefreshChanged (first run records the configuration fingerprint)
   Status 1 -- 0 shift(s) recomputed; 0 still stale.
After: shifts stored <S> of <S> closed, LOTs stamped <Stamped count>, fingerprint recorded yes
```

Time: Dev-sized history (141 shifts, far more production than prod) took 17 s; prod should be well under a
minute. Each shift commits on its own -- **a failure keeps what finished; fix and re-run** (it recomputes, never
doubles). Step 3 must say `0 shift(s) recomputed` -- anything else means the fingerprint was already recorded
(the shift-close hook got there first, harmless).

```powershell
git diff --stat -- sql/scratch/2026-11-04_oee_first_fill.sql
```

Expect **no output** after you set it back to 0.

## 5. Ignition imports -- SQL first, then Core, then MPP, then MPP_Config

**Before importing, export prod's `MPP` view `BlueRidge/Views/ShopFloor/MachiningIn`** (Designer -> right-click
-> Export) -- it carries a prod-only sizing tweak that this import replaces. Re-apply the tweak after if it is
still wanted, then pull it into git.

Designer -> File -> Import, one zip at a time, accept the overwrites. **Not** the Gateway web import. Files in
`dist\ignition-exports\` of the release checkout (built from git at `96651770`, range `0647dc97..96651770`):

1. `Core_superlot-oee-bundle_2026-11-04_1825.zip` -- **102 resources** (75 NEW, 27 MOD): named queries for
   super-lot, rework, vendor return, scale station, OEE dashboard (`oee/Dashboard_*`, `oee/ShiftSummary_*`),
   Failure Log; scripts incl. `Common/Session`, `Oee/Shift`, `Oee/Summary`, `Oee/Dashboard`, `Reports`,
   `Lots/AimHttp` + `AimPost` + `AimPoolGateway`, `Audit/FailureLog`, `Quality/ControlledRun`; the Core
   `stylesheet`.
2. `MPP_superlot-oee-bundle_2026-11-04_1825.zip` -- **94 resources** (72 NEW, 22 MOD): the OEE pages and
   components, the super-lot views and popups, LOT Detail, Track & Trace, Genealogy, Supervisor Dashboard,
   Reports page + the `OEE Summary` and `Super-lot` reports, both Assembly screens, Trim, Machining IN / OUT,
   Die Cast, `ElevationModal`, `AppMenu`, `page-config`, `session-props`, the timers `ControlledRunSyncTimer`,
   `OeeSummaryRefresh`, `OeeSummaryNightly`, the `ScaleEPrintMessage` tag-change script.
3. `MPP_Config_superlot-oee-bundle_2026-11-04_1825.zip` -- **17 resources** (2 NEW, 15 MOD): Failure Log
   browser + detail popup, Default machines editor + toggle, Plant Hierarchy, the Item Master sections, Tools,
   Operation Templates, Quality Specs (the unsaved-changes fixes).

Full NEW / MOD checklist with commits: `superlot-oee-bundle_2026-11-04_1825_CONTENTS.txt`.

**Whole-resource overwrites to look at in the import dialog:** `page-config` (adds `/shop-floor/oee`,
`/shop-floor/oee/area/:areaKey`, `/shop-floor/oee/unit/:locationId`, `/shop-floor/controlled-runs/:runNumber`,
the scale station dev routes, `/shop-floor/terminal-onboarding`), Core `stylesheet`, MPP `session-props`
(adds `oeePeriod`, `elevationProfile`, `elevatedGrantedAt`, the Quality window policy keys). If any is a
surprise, stop and export prod's copy first.

**Hand step -- delete two orphaned views** (an import cannot delete; they were moved to `Scrap/`):
MPP `BlueRidge/Components/PlantFloor/TrimEntry/ScrapCodeTile` and `.../TrimEntry/ScrapLineRow`. Nothing
references them after the import; harmless if left.

**Timers.** All three ship **disabled**.
- `OeeSummaryRefresh` (every 15 min) and `OeeSummaryNightly` (every 24 h from gateway start, not a time of
  day): **enable both now** (Designer -> MPP -> Scripting -> Gateway Events -> Timer -> Enabled; save). Only
  after Step 4 -- otherwise the first refresh tick records the fingerprint before history exists, which is
  harmless but leaves the dashboard empty until the nightly run. Prod then differs from git on these two
  resources on purpose, like the AIM timers.
- `ControlledRunSyncTimer` **stays disabled** (unchanged decision from 2026-10-21).

**Then F5 every open shop-floor session** (not the Designer).

## 6. Verification -- ordered by risk

### 6.1 The OEE dashboard has history (new; first time on prod data)
Open `/shop-floor/oee`. It opens on the last completed shift with plant Availability and Quality, and one card
per area (Die Cast, Trim, M&A). Step back a few shifts with `<`; switch to Week. Then:

```sql
SELECT COUNT(DISTINCT ShiftId) AS Stored FROM Oee.ShiftSummary;                    -- = <S> from Step 1 (or +1 if a shift closed since)
SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NOT NULL;                         -- the same number
SELECT ConfigFingerprint, CheckedAt FROM Oee.ShiftSummaryConfig;                   -- fingerprint set
```

Within the next shift change: the closed shift appears in `Oee.ShiftSummary` (the shift-close hook). Within
15 minutes of enabling the refresh timer: `CheckedAt` advances. A blank card or a red component error -> read
`wrapper.log` for `Oee`; the dashboard is read-only, nothing on the floor depends on it.

### 6.2 The first AIM post after the import, and a failure row
Complete one container at the assembly line as normal. In the AIM owed-to list it clears within a minute;
`Audit.InterfaceLog` shows the post with `LocationId` / `LotId` filled. **No new `Audit.FailureLog` row**
(`SELECT TOP 5 * FROM Audit.FailureLog ORDER BY Id DESC`). If AIM is having a bad day and a post fails, there
**is** a row: `AimPostFailed`, Location = the line, LOT = the tray LOT, `AttemptedParameters` showing
`<token>` in place of the token. *Not On File* or a stuck post -> roll back `Lots/AimHttp` from the ROLLBACK
Core zip (section 7).

### 6.3 A sign-in that is NOT the feature (shared `Common.Session` + `ElevationModal`)
At a die cast terminal, Supervisor Access -> sign in. The box looks as before; the Authenticate button is on
screen. Then on the OEE Unit page of that press, tap **Edit** on one downtime entry from the last shift: the
sign-in box opens (or, already elevated, the editor opens on that entry). **Cancel** -- save only a real
correction; this is prod data. (Save -> refresh -> stored-row recompute was walked on Dev 2026-11-04.)

### 6.4 The mint stamp on new production
After the next tray closes on MA2-6MACH:
```sql
SELECT TOP 3 LotName, ShiftId, MintedPieceCount, CreatedAt FROM Lots.Lot WHERE ShiftId IS NOT NULL ORDER BY Id DESC;
```
The newest tray LOT has a `ShiftId` and a `MintedPieceCount`.

### 6.5 Die cast and the line still move
Die cast terminal: the press buttons show as before (no default presses configured = every press). One basket
release, one Trim OUT, one Machining IN pick from trim storage record as before. Assembly Out By Weight: the
scale station panel shows the running part and shift tally; a press on the scale closes a box (no Weigh &
Close button, by design).

### 6.6 Shipping
Ship one ordinary container at the dock as normal -- it ships. (A container holding a held LOT is refused with
the LOT named; only test that if Step 1 listed one.)

### 6.7 An ordinary LOT
LOT Detail on any recent LOT: History tab as before plus any audit rows; **Super-lots** tab reads *"This LOT has
never been part of a super-lot."*; no red component errors.

### 6.8 Supervisor Dashboard + Reports
Supervisor Dashboard: **Shift Availability** shows a percentage and the last completed shift; **Open super-lots
0**, **Parts to return 0**. Reports lists **OEE Summary** (Period: Shift / Day / Week) and **Super-lot**; Print
PDF on OEE Summary for the last shift produces a PDF.

### 6.9 Config Tool (MPP_Config)
`/failure-log` opens with Location and LOT filters; Plant Hierarchy -> a die cast terminal shows a
**DefaultMachines** attribute (empty); opening and closing an untouched Item Master section does not ask about
unsaved changes.

### 6.10 SQL, after commit (values confirmed on `MPP_MES_ProdSimOEE`)

```sql
SELECT COUNT(*) AS Applied, MAX(MigrationId) AS Highest FROM dbo.SchemaVersion;              -- 116 | 0117_oee_shift_summary
SELECT COL_LENGTH('Lots.Lot','ShiftId'), COL_LENGTH('Lots.Lot','MintedPieceCount');          -- 8 | 4
SELECT COUNT(*) FROM Oee.ShiftSummaryConfig;                                                 -- 1
SELECT COUNT(*) FROM Location.LocationAttributeDefinition
 WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'DefaultMachines' AND DeprecatedAt IS NULL;  -- 1
SELECT COUNT(*) FROM Audit.LogEventType WHERE Code IN (N'AimPostFailed', N'AimSerialFetchFailed');  -- 2
SELECT COL_LENGTH('Audit.FailureLog','LotId');                                               -- 8
SELECT COUNT(*) FROM Audit.LogEventType WHERE RepeatsLotTimeline = 1;                         -- 13
SELECT COUNT(*) FROM Lots.ContainerStatusCode;                                                -- 7
SELECT name FROM sys.indexes WHERE object_id = OBJECT_ID('Lots.Lot') AND name = 'IX_Lot_ShiftId';  -- 1 row
```

## 7. Rollback

- **Before COMMIT** (preview, rehearsal, a failed execute): nothing to do; the transaction rolled back.
- **After COMMIT, SQL:** the migrations only add, so leaving them is harmless. To put a proc back, its prod
  definition before the release is in the Execute report's `diffs\<object>.target.sql`; run that file against
  `MPP_MES_Prod`. Reverting `Shift_GetAvailability` restores clock-merged availability; reverting the mint procs
  stops the stamp (stamped LOTs keep it; only OEE reads it). A full restore from the COPY_ONLY backup loses
  every plant transaction since -- last resort.
- **OEE first fill:** derived data. `DELETE FROM Oee.ShiftSummary` empties the dashboard; re-run the script to
  refill. The mint stamp is read by nothing but OEE.
- **OEE only, keep everything else:** disable `OeeSummaryRefresh` + `OeeSummaryNightly`; the pages can be hidden
  by removing their three routes from `page-config`.
- **Ignition:** import `Core_superlot-oee-bundle-ROLLBACK_2026-11-04_1826.zip` (27), then
  `MPP_superlot-oee-bundle-ROLLBACK_2026-11-04_1826.zip` (24), then
  `MPP_Config_superlot-oee-bundle-ROLLBACK_2026-11-04_1826.zip` (15): every MODIFIED resource back to its
  `0647dc97` version (the MPP one also restores the two `TrimEntry/` views). The NEW resources stay (an import
  cannot delete); they are unreachable once `page-config` and the screens are rolled back, except the named
  queries, which are harmless. List: `superlot-oee-bundle-ROLLBACK_2026-11-04_1826_CONTENTS.txt`. F5 the
  sessions.

## 8. Not in this release

The super-lot follow-ons (see the 2026-10-21 runbook section 8) and the 11 open questions from the first
super-lot gateway walk (`notes/2026-10-27_super-lot-gateway-walk-bugs.md`); OEE Performance and OEE (future
cards); the OEE deferred minors (a location added anywhere changes the configuration fingerprint, so the next
refresh tick recomputes stored history in the background; the nightly timer is a fixed 24 h delay, not a time
of day); the **minted SubAssembly wart** (CLAUDE.md -- prod has no Machining OUT terminal, so not reachable);
the AIM side notes (`aim-pool-alarm` message nobody listens to, the hold/release stubs, synchronous post on
Complete); part-type recategorization; DB volume work (container-as-LOT, LOT search, partitioning `Lots.Lot`)
-- the next branch.

## 9. Outcome -- filled in after the release

_(still to fill in)_

| | |
|---|---|
| Executed at (ET) | |
| Prod before | SQL `0108`, 107 migrations |
| Plan fingerprint | |
| Preview: changed / new | |
| Gates fired | |
| Held-LOT containers listed | |
| Rehearsal lock window | |
| Execute lock window | |
| Backup | |
| Report folders | |
| First fill: LOTs Stamped / NoShift / NotReconstructable | |
| First fill: shifts computed, time | |
| Core / MPP / MPP_Config imported at | |
| Timers enabled at | |
| Verification 6.1-6.10 | |
