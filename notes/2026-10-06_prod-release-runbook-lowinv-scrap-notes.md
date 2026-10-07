# Prod release runbook -- low-inventory lock, Record Scrap by part, LOT notes, LOT Search fixes, Designer saves

**Release commit:** `e0426405` on `jacques/working` -- the commit the archives were built and verified from.
**Previous release:** `44ea9f82` (2026-10-06 16:17, container label Code 128; executed from `d3735225`). Prod is at
SQL **`0106`**, 105 migrations. The last Ignition import was the Pack-Out release (`20334b41`); nothing under
`ignition/` changed between that and `44ea9f82`.
**Rehearsed against:** `MPP_MES_ProdSimEP` -- at prod's state (105 applied, highest `0106`, `Lots.LotNote` and
`Workorder.Assembly_GetTraysRemaining` absent). Preview + Rehearse clean, rollback verified; it is still at
prod's state. A full **Execute** was run against a second sim, `MPP_MES_ProdSimNX` (built from a worktree at
`44ea9f82`), to cover the backup, the post-commit step and section 6.1.
**SQL suite:** 4355 assertions / 4355 passed / 0 failed, exit 0, on `MPP_MES_Test_NX`.

> **Read this before deciding to ship.** Three things in this release have never been proven end to end:
>
> 1. **The low-inventory lock opens by itself, on page load, on every non-serialized Assembly OUT screen whose
>    selected part is 3 trays or fewer from running out of a purchased part.** On Dev (which carries prod's
>    configuration but no stock) the check in Step 4 lists *every* line as "would lock". What it lists on prod
>    depends on how much purchased stock is checked in at each line right now, and only prod can answer that.
>    **Step 4 exists so you see that list before the screens change.**
> 2. **The supervisor release on the banner has never been pressed.** It needs an AD credential and none was
>    available on Dev. If it does not work, a locked terminal can only be cleared by adding stock -- or by the
>    switch in section 7.
> 3. **Your Designer saves were committed as saved and not reviewed for behaviour** (section 3.5).

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint's first
> hashed line is the raw `HEAD` sha, so any commit changes it -- a docs-only commit included -- and Execute
> refuses. Re-preview and use the new fingerprint.
>
> **Two separate tests. Do not collapse them.** A docs commit invalidates the fingerprint but not the archives:
> ```bash
> git diff --stat e0426405..HEAD -- ignition/ sql/
> ```
> Expect **no output**. Anything listed means the archives are stale -- rebuild them, then re-preview.

---

## 1. What this ships

Five pieces of work, built by separate sessions on 2026-10-06, plus Designer saves.

**Assembly OUT low-inventory lock (non-serialized screens only).** When the selected finished good is 3 trays
or fewer from running out of a purchased part, a full-screen red banner covers the terminal, names the part
and how many trays are left, and embeds the add-inventory form. Adding stock clears it. A **Supervisor
release** button (AD sign-in) lifts it until stock at the line next changes -- so it comes back after the next
tray if the part is still short. While the banner is up a `System` / `Low Inventory` downtime event runs at the
line's downtime unit.

**Record Scrap picks a part, not a LOT.** The Record Scrap popup on the Machining and Assembly terminals now
lists the parts on hand at the line. The quantity is charged to that part's LOTs oldest first, spilling into
the next LOT, closing a LOT that reaches zero. If the quantity is more than is on hand it asks
"Inventory is X parts short. Submit Y instead?".

**LOT Detail gains a Notes tab.** Anyone signed in can add a note to a LOT. Notes cannot be edited or deleted.
Each one stores who, which terminal, and what the LOT looked like at that moment.

**LOT Search fixes.** The search box no longer shows the word `null`; the grid shows the part description
(and searches it); finished-good LOTs are hidden unless *Hide finished goods* is unticked; Export CSV works.

**Designer saves.** Numeric entry fields lose their spinner arrows (die cast entry, die cast reconcile, Trim,
cutover scan, two Config Tool rows). Layout and input tweaks to the downtime screens, Die Mount, PIN entry,
cutover scan, Assembly OUT. Session time zone id `America/Indianapolis` -> `America/New_York`.

### SQL

| File | | Effect |
|---|---|---|
| `0107_lot_note.sql` | migration | New table `Lots.LotNote` + one index. |
| `0108_downtime_reason_low_inventory.sql` | migration | One row in `Oee.DowntimeReasonCode`: `MA-LOWINV`, 'Low Inventory'. |
| `R__Lots_LotNote_Add.sql` | NEW | Writes a note; reads the LOT snapshot itself. |
| `R__Lots_LotNote_ListByLot.sql` | NEW | Read. |
| `R__Lots_Lot_GetScrappablePartsByLocation.sql` | NEW | Read: the Record Scrap part list. |
| `R__Workorder_RejectEvent_RecordByPartFifo.sql` | NEW | The FIFO scrap mutation. |
| `R__Workorder_Assembly_GetTraysRemaining.sql` | NEW | Read: the calc behind the lock. |
| `R__Lots_Lot_SearchAdvanced.sql` | CHANGED (v1.3) | + `ItemDescription` column, + `@ExcludeFinishedGoods BIT = 0` as the last parameter. |

### Ignition -- three archives, in `dist\ignition-exports\`

| Archive | Resources |
|---|---|
| `Core_lowinv-scrap-notes_2026-10-06_2343.zip` | 12 (6 new, 6 modified) |
| `MPP_lowinv-scrap-notes_2026-10-06_2343.zip` | 29 (3 new, 26 modified) |
| `MPP_Config_lowinv-scrap-notes_2026-10-06_2343.zip` | 2 (both modified) |

The per-resource list is in section 5. **Nothing was deleted in the range; there are no hand deletions.**

### In the range but shipping nothing

`sql/tests/`, `sql/scratch/` (two read-only check scripts, one of which Step 4 uses),
`sql/scripts/Invoke-LineConsumptionCheck.ps1`, `docs/`, `notes/`, `PROJECT_STATUS.md`.

---

## 2. What the database change is

| | |
|---|---|
| Migrations | 2 -- `0107_lot_note`, `0108_downtime_reason_low_inventory` |
| Repeatables | 6 -- 5 new, 1 changed |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window (local) | 0.2 s |

A new empty table, one inserted code-table row, five new procs and one proc gaining a defaulted parameter. No
existing table is altered, no column is dropped, nothing is backfilled. `0108` throws (and the release rolls
back) if `Parts.OperationCategory 'MachiningAssembly'` or `Oee.DowntimeSourceCode 'System'` is missing; the
rehearsal proves that against prod's rows.

---

## 3. Risk

**3.1 Does anything now refuse what it used to allow? YES -- the lock.** An Assembly OUT operator who could
keep packing down to the last tray is stopped at 3 trays left, by a banner that cannot be dismissed. That is
the point of the change. The ways out, in the operator's words: **add the box** on the banner, or **get a
supervisor to release it**. The banner locks the *screen*, not the line -- trays closed by a scale or camera
keep closing behind it.

Record Scrap also refuses differently: asking for more than is on hand records **nothing** and offers the
smaller quantity instead. Held LOTs are skipped.

**3.2 Is any of it shared code? YES.**

- `BlueRidge.Common.Session` -- one new entry in the elevation replay table. Every elevated action routes
  through this module. Section 6.5 proves one that is not the lock.
- **Core stylesheet** -- one resource. Ships whole; the diff against the last release is 66 added lines
  (`psc-pf-lock-*`) and nothing else.
- **MPP `session-props`** and **`page-config`** -- one resource each for the whole project. Their diffs against
  the last release are exactly: a new `custom.selectedFinishedGoodItemId`, the time zone id, and
  `lockEnabled: true` on one dock. If anyone changed either on the prod Gateway directly, this import
  overwrites it.
- `BlueRidge.Lots.Lot` and `Lots.Lot_SearchAdvanced` -- LOT Search is the only caller in the repo.

**3.3 Is the schema change metadata-only?** Yes. `CREATE TABLE` and one `INSERT`.

**3.4 Does the old Ignition keep working against the new SQL? Yes.** The old `Lot_SearchAdvanced` query omits
the new parameter and gets the default; the extra column is ignored. Everything else is new and uncalled.
**So the SQL step and the imports are independent -- and Step 4 sits between them on purpose.** The reverse is
not true: new views against old SQL fail, so SQL first.

**3.5 The Designer saves.** Committed as saved. What I checked by reading the diffs, and what I could not:

- `Popups/DieMount` and `Popups/DowntimeManager` lost the stored defaults for properties that are filled by a
  binding (`custom.context`, `custom.picker`, `custom.scopeOptions`). The bindings are intact and return a
  full shape, so the popups should work; the risk is a red Component Error flash for the instant before the
  binding answers. **Not observed either way** -- section 6.6.
- `Popups/DowntimeEditor` now stores `durationOnly = true`. Its startup script sets it to `False` before
  anything reads it, so the stored value does not matter.
- `_CutoverScan/Phone` and `/Tablet` were saved with Dev location id 149 baked into the setup draft. **Stripped
  before commit** (both null again). Tablet's remaining diff is Designer dropping default props and reordering
  keys; Phone's is one style class off the cast-date picker.
- The eleven spinner edits add `spinner.enabled = false` and nothing else.
- Time zone id: both names are US Eastern today. Not exercised.

---

## 4. Deploy

Run from the repo root. Have the Designer open on the prod Gateway with the three zips to hand first.

```powershell
$env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
```

### Step 1 -- Preview (read-only)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect (`[2]`, `[6]`, `[7]` show prod's own values):

```
[3] Versioned migrations
  Database: 105 applied, highest 0106.
  Pending (2):
    + 0107_lot_note.sql
    + 0108_downtime_reason_low_inventory.sql

[4] Repeatables -- target definitions vs this checkout
  500 identical, 1 changed, 5 new on the target.
    NEW      R__Lots_Lot_GetScrappablePartsByLocation.sql
    CHANGED  R__Lots_Lot_SearchAdvanced.sql
    NEW      R__Lots_LotNote_Add.sql
    NEW      R__Lots_LotNote_ListByLot.sql
    NEW      R__Workorder_Assembly_GetTraysRemaining.sql
    NEW      R__Workorder_RejectEvent_RecordByPartFifo.sql

[5] Pre-flight gates (read-only, against live data)
  No gates fired.

[8] Plan
  2 migration(s), 6 repeatable(s) in one transaction; then R__Descriptions_ExtendedProperties.sql after commit.
  Plan fingerprint: <copy this>

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

**Read `[2]` every time** -- it is the only line that names the database.

**If it differs:**

- *Pending shows anything other than `0107` and `0108`* -- prod is not at `0106`. Stop and reconcile.
- *Any other CHANGED or NEW repeatable* -- prod has drifted from git, or an earlier release never went out.
  Read the report's `diffs` folder before continuing.
- *A gate fires, or a WARN in `[6]`* -- stop; read the finding. A long open transaction will block the locks.

Copy the fingerprint; do not retype it. The local sim printed `d159ada6f3a5` at `e0426405`; yours will differ
because the commit of this note moved `HEAD`.

### Step 2 -- Rehearse

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE`. Expect:

```
[10] Running the release transaction
    == transaction open
    == [1] migration 0107_lot_note
    Migration 0107: Lots.LotNote created.
    Migration 0107 (lot_note) applied.
    == [2] migration 0108_downtime_reason_low_inventory
    Migration 0108: DowntimeReasonCode MA-LOWINV added.
    Migration 0108 (downtime_reason_low_inventory) applied.
    == [3] R__Lots_Lot_GetScrappablePartsByLocation.sql
    == [4] R__Lots_Lot_SearchAdvanced.sql
    == [5] R__Lots_LotNote_Add.sql
    == [6] R__Lots_LotNote_ListByLot.sql
    == [7] R__Workorder_Assembly_GetTraysRemaining.sql
    == [8] R__Workorder_RejectEvent_RecordByPartFifo.sql
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept

  REHEARSAL PASSED and was rolled back. Lock window: 0.2s.
```

**If the rehearsal fails, stop.** Nothing was written. `Migration 0108: ... did not land` means prod has no
`MachiningAssembly` category or no `System` downtime source -- send me the message.

### Step 3 -- Execute

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <fingerprint>
```

Type `MPP_MES_Prod`. Expect:

```
[9] Backup
  BACKUP DATABASE -> ...\MPP_MES_Prod_pre-release_0106_<stamp>.bak (COPY_ONLY, CHECKSUM)
  Backup written and verified.

[10] Running the release transaction
    == transaction open
    ... steps [1] to [8] as in the rehearsal ...
    == checks passed
    == COMMITTED

[11] After commit
  R__Descriptions_ExtendedProperties.sql applied.
  Every repo migration is recorded.
  All 6 applied repeatable(s) now match the repo byte-for-byte.

DONE
```

- *`ABORT: plan is <a> but -ExpectedPlan is <b>`* -- something moved since the preview. Re-preview.
- *`FAILED -- the transaction was rolled back`* -- prod is unchanged. Read `deploy.log`.

**The plant sees no change yet.** The old screens run unchanged against the new SQL.

### Step 4 -- Which lines would lock? (read-only; do this BEFORE the imports)

```powershell
sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -C -W -s "|" -i sql\scratch\2026-10-06_low_inventory_lock_preflight.sql
```

It calls the real `Workorder.Assembly_GetTraysRemaining` for every finished good at every line, so it cannot
disagree with the banner. Two result sets:

1. One row per (line, finished good, closure method, purchased part), short ones first, marked `WOULD LOCK`.
2. Each line's downtime unit and whether it is OEE-enabled.

**How to read it.** It is deliberately over-inclusive: it lists serialized lines (which have no lock) and
parts nobody is running. A `WOULD LOCK` row matters only if that finished good is the one selected on a
**non-serialized Assembly OUT screen** at that line right now. On Dev every row says `WOULD LOCK` with
`Available = 0`, because Dev has no stock -- that is not a prediction for prod.

**Decide here:**

- *No row for a line that is running* -- continue.
- *A running line is listed* -- its terminal locks the moment the MPP import lands and the page reloads. Either
  check that part's stock in first, or have a supervisor standing by, or import MPP with the lock switched off
  (section 7) and turn it on later.
- *A line shows `*** NO ***` in the second result* -- the banner works there but writes no downtime event,
  silently. Not a reason to stop.

### Step 5 -- Imports

Section 5. Core, then MPP, then MPP_Config.

---

## 5. Ignition imports

**SQL first (done in Step 3). Core first.** Designer -> File -> Import, one zip at a time, accept overwrite for
the listed resources. Not the Gateway web page's project import -- these are partial exports. 14 manifests were
rewritten in the archives to stop naming `thumbnail.png`; that is expected.

**1. `Core_lowinv-scrap-notes_2026-10-06_2343.zip`** (12)

```
MOD  perspective/stylesheet
NEW  named-query/lots/Lot_GetScrappablePartsByLocation
MOD  named-query/lots/Lot_SearchAdvanced
NEW  named-query/lots/LotNote_Add
NEW  named-query/lots/LotNote_ListByLot
NEW  named-query/workorder/Assembly_GetTraysRemaining
NEW  named-query/workorder/RejectEvent_RecordByPartFifo
MOD  script-python/BlueRidge/Common/Session
MOD  script-python/BlueRidge/Lots/Lot
NEW  script-python/BlueRidge/Lots/LotNote
MOD  script-python/BlueRidge/Workorder/Assembly
MOD  script-python/BlueRidge/Workorder/RejectEvent
```

**2. `MPP_lowinv-scrap-notes_2026-10-06_2343.zip`** (29)

```
MOD  page-config
MOD  session-props
MOD  Components/PlantFloor/_DieCastReconcileSheet/LotLineRow
MOD  Components/PlantFloor/_DieCastReconcileSheet/RejectLineRow
MOD  Components/PlantFloor/AddLotBox
MOD  Components/PlantFloor/Cutover/CavityToggle
MOD  Components/PlantFloor/Cutover/SessionRow
MOD  Components/PlantFloor/DieCastEntry/CavityLotRow
MOD  Components/PlantFloor/DieCastEntry/DieWideLineRow
MOD  Components/PlantFloor/DieCastEntry/FieldInputRow
MOD  Components/PlantFloor/DieCastReconcileSheet
MOD  Components/PlantFloor/LineInventory
NEW  Components/PlantFloor/LotDetail/NoteRow
NEW  Components/Popups/_ScrapEntry/PartRow
MOD  Components/Popups/DieMount
MOD  Components/Popups/DowntimeEditor
MOD  Components/Popups/DowntimeManager
MOD  Components/Popups/InitialsEntry
NEW  Components/Popups/LowInventoryLock
MOD  Components/Popups/ScrapEntry
MOD  Components/Popups/ScrapEntryHowTo
MOD  Views/ShopFloor/_CutoverScan/Desktop
MOD  Views/ShopFloor/_CutoverScan/Phone
MOD  Views/ShopFloor/_CutoverScan/Tablet
MOD  Views/ShopFloor/AssemblyNonSerialized
MOD  Views/ShopFloor/DowntimeEntry
MOD  Views/ShopFloor/LotDetail
MOD  Views/ShopFloor/LotSearch
MOD  Views/ShopFloor/TrimBody
```

**3. `MPP_Config_lowinv-scrap-notes_2026-10-06_2343.zip`** (2)

```
MOD  Components/Parts/Tools/_Tools/AttributeRow
MOD  Components/Quality/QualitySpecAttributeRow
```

**4. Reload the open Perspective sessions** -- F5 on each shop-floor screen. Not optional: `session-props` and
`page-config` changed, and a session left open across the update can come back with stale bindings. **The lock
evaluates on this reload.**

No deletions, no tag changes, no Gateway settings.

---

## 6. Verification

Ordered by risk, not by feature.

### 6.1 SQL proof (confirmed on the sim Execute)

```sql
SELECT COUNT(*) AS Applied, MAX(MigrationId) AS Highest FROM dbo.SchemaVersion;
SELECT Code, Description, IsExcused FROM Oee.DowntimeReasonCode WHERE Code = N'MA-LOWINV';
SELECT COUNT(*) AS HasNewParam FROM sys.parameters
WHERE object_id = OBJECT_ID('Lots.Lot_SearchAdvanced') AND name = '@ExcludeFinishedGoods';
```

Expect `107` / `0108_downtime_reason_low_inventory`; one row `MA-LOWINV | Low Inventory | 0`; `1`.

### 6.2 The lock -- the part never seen on prod

On a non-serialized Assembly OUT terminal:

1. With plenty of stock: no banner. The screen behaves as before.
2. On a line Step 4 listed (or once a part drops to 3 trays): the red banner opens by itself, names the part
   and trays left. The Downtime screen shows an open `Low Inventory` event for the line.
3. Add a box through the form on the banner: the banner closes (or moves to the next short part) and the
   downtime event ends, with the part named in its remarks.

- *Banner on a line with stock* -- compare with Step 4's row for that line and part; send me both.
- *No banner where Step 4 said `WOULD LOCK`* -- check the selected part is the one listed, then F5. If still
  nothing, the Gateway log will have `getLowInventoryLock failed`.
- *Banner but no downtime event* -- Step 4's second result said so for that line, or another event was already
  open there (by design: one open event per unit).

### 6.3 Supervisor release -- **never run before this release. Do it deliberately, once.**

With the banner up, press **Supervisor release** and sign in with an AD account. Expect the banner to close
and stay closed until the next tray is completed or stock is added, then return if still short. The downtime
event keeps running (by design).

- *The AD prompt opens but the banner stays after sign-in* -- the replay did not reach the banner. The terminal
  is still usable by adding stock. Tell me; if it is blocking production use section 7's switch.

### 6.4 Record Scrap

On a Machining or Assembly terminal open Record Scrap: it lists parts, not LOTs. Scrap a small quantity of one
part; the oldest LOT of that part at the line drops by that amount (LOT Detail shows the reject). Then ask for
more than is on hand: expect the "parts short. Submit Y instead?" prompt, and **Go back** records nothing.

### 6.5 Something that is not the feature (shared `Common.Session`)

Do one existing elevated action -- edit a downtime event's reason in the Downtime Manager is the quickest.
The AD prompt opens, and after sign-in the edit goes through as it did before.

### 6.6 Designer saves

- Open **Die Mount** on a die cast terminal and the **Downtime Manager**: each opens with no red error box,
  even briefly. A flash that clears itself is the dropped-defaults case in 3.5 -- note it, it is cosmetic.
- A numeric field on the die cast entry screen and on Trim shows no spinner arrows and still takes a typed
  number.
- Cutover scan on a phone and a tablet opens at an empty setup (no line pre-selected).
- PIN sign-in still works.

### 6.7 LOT Search and Notes

LOT Search: the box is empty, the grid shows descriptions, finished goods are hidden until the checkbox is
unticked, Export CSV saves a file and toasts the row count. LOT Detail -> Notes: add a note; it appears at the
top with your initials. **Type, then tap Add note without tapping elsewhere first** -- that order was not
provable in the test browser.

---

## 7. Rollback

**Before COMMIT:** automatic.

**The lock has a switch, and it is the first thing to reach for.** In the Designer, MPP project ->
Perspective -> Page Configuration -> `/shop-floor/assembly-nonserialized` -> the docked `LineInventory` view ->
remove the `lockEnabled` parameter (or set it false), save, F5 the terminals. The watcher then never evaluates:
no banner, no downtime events. Everything else in the release stays. End any open `Low Inventory` event in the
Downtime Manager.

**Ignition, anything else:** build the previous definitions and import them --

```powershell
.\tools\Build-ChangeExport.ps1 -Since e0426405 -Until 44ea9f82 -Label rollback
```

(reasoned from the builder, never used in anger -- read its `CONTENTS.txt` first). The six new Core resources
and three new MPP views are not removed by that and are harmless left in place.

**SQL:** leave it. The procs are uncalled without the views, `Lot_SearchAdvanced` v1.3 serves the old query,
`Lots.LotNote` sits empty, and the reason code is unused. Do not delete the reason code once an event
references it; deprecate it through `Oee.DowntimeReasonCode_Deprecate`. A database restore would discard
everything booked since the backup to undo nothing the plant can see.

---

## 8. Known limits (say these to the floor)

- The banner locks the screen, not the line. Scale- and camera-closed trays keep closing behind it.
- Serialized Assembly OUT has no lock.
- The 3-tray threshold is a constant in the proc.
- If a terminal's browser dies mid-lock, its downtime event stays open until that line next sees the shortage
  clear, or someone ends it by hand.
- Two stations on one line share one downtime event.
- LOT notes write no audit rows and do not appear on the History tab.
- Not exercised on Dev: the lock on By Weight / By Vision terminals; the lock on a no-BOM repack part through
  the gateway (SQL tests only); a completed add from the sidebar's own `+ LOT` popup after the `AddLotBox`
  change.

---

## 9. Outcome -- filled in after the release

_(still to fill in)_

| | |
|---|---|
| Executed at | |
| Prod before | SQL `0106`, 105 migrations |
| Plan fingerprint | |
| Backup path | |
| Preview `[4]` | |
| Live activity `[6]` | |
| Prod rehearsal lock window | |
| Report folder | |
| Step 4: lines listed `WOULD LOCK` that were running | |
| Step 4: lines with a non-OEE downtime unit | |
| 6.2 lock opened / cleared on | |
| 6.3 supervisor release | |
| 6.4 Record Scrap | |
| 6.5 other elevated action | |
| 6.6 Die Mount / Downtime Manager first paint | |

**What went differently from the plan:**

_(still to fill in)_
