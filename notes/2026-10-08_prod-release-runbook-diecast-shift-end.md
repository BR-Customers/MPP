# Prod release runbook -- die cast shift end: baskets released by count, and the reading always recorded

**Release commit:** `fe4cf41e` on `jacques/working` -- the commit the archives were built and verified from.
**Previous release:** `0647dc97` (executed 2026-10-07 08:39 ET from `3a39e5f5`). Prod is at SQL **`0108`**,
107 migrations. The one-function release of 2026-10-07 16:32 (`81b0fa21`) was **rolled back** on 2026-10-08
and reverted in git (`caa6b458`), so prod's die cast SQL is identical to `0647dc97` again
(confirmed: `v3.0 - rolled back`).
**Rehearsed against:** `MPP_MES_ProdSimWM` -- at prod's state (107 applied, highest `0108`,
`Workorder.ufn_CavityCreditedWithoutReading` absent). Preview + Rehearse clean, rollback verified; it is still
at prod's state. A full **Execute** was run against `MPP_MES_ProdSimWM2`; the SQL rollback file in section 7
was then run against it and verified (`breakdown OLD / record OLD / credit OLD`).
**SQL suite:** 4393 / 4394, exit 1. The one failure, `0070_Cutover_EntryRoute/030_CastDate_fifo.sql`
("arrival order is the inverse of cast order"), compares the timestamps of two LOTs created back to back; it
passed on two immediate re-runs (99/99) and does not touch this code. Die cast + reconciliation suites:
703 / 703.

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint's first
> hashed line is the raw HEAD sha, so **any** commit changes it -- a docs-only commit included -- and
> Execute refuses. Re-preview and use the new fingerprint.
>
> **Two separate tests. Do not collapse them.** A docs-only commit invalidates the **fingerprint** but leaves
> the **archives** valid:
> ```powershell
> git diff --stat fe4cf41e..HEAD -- ignition/ sql/migrations/
> ```
> Expect **no output**. Anything listed means the archives are stale -- rebuild, then re-preview.

> **Read this before deciding to ship.** What has and has not been proven:
>
> 1. **Seen on the Dev screen** (Machine 11, a cavity with two baskets released by count, 515 pc): the row
>    showing shots, "515 pc already released...", the variance and its reason box; the negative case in amber;
>    scrap typed on the earlier basket reducing the cavity's variance; the totals bar; the Open basket button
>    present on that row only.
> 2. **Submit was NOT pressed on the Dev screen** -- it would have credited Dev's ten hand-built baskets. The
>    write is proven by the SQL suite and by running the screen's own submit script outside Ignition.
>    **Section 6.3 is the first real submit.**
> 3. **Machine 304's numbers were not seen on a screen** (the test browser registers as a Die Cast 1
>    terminal). They were run through the real screen scripts: reading 367, 42 die-wide, 359 released ->
>    PARTS 325, GOOD 359, UNACCOUNTED -34.
> 4. **The Open basket button was not clicked.** It calls the same handler the basketless-cavity button
>    already uses (switches to Lot Management with a "Scan the LTT" toast).
> 5. **A blast-radius audit of every proc that reads die cast credit rows was done by reading code**, not by
>    running it. Its findings are in section 3.

---

## 1. What this ships

Operators release baskets by typing the pieces, with no counter reading -- and on most presses they open the
basket in the MES at the moment they release it, so at shift end there is usually **no open basket at all**.
Two things were wrong on the Reconcile Shift tab because of that:

- **A cavity whose baskets were all released contributed nothing.** PARTS, GOOD and UNACCOUNTED read 0 for
  the shift, and Submit had nowhere to store the shift-end reading, so the shift stayed "Released, no
  shift-end number". (Machine 304, 10-07 Third Shift.)
- **An open basket was offered the whole reading again**, on top of what had already been released.
  (Machine 11, 10-07 First Shift: 515 released per cavity, then 1,038 offered where 523 was cast.)

After this release:

- The shot count is **untouched** -- SHOTS and PARTS always say what the counter says.
- **"Already released this shift" is its own figure**, shown on the row that carries the cavity, counted in
  GOOD, and taken off what an open basket is offered.
- **Every cavity with a basket is in the totals**, through one carrier row per cavity: its open basket, or its
  most recent basket when all are released.
- **Scrap typed on any basket row of a cavity** counts against that cavity.
- **Submit always records the shift-end reading** and the variance reason, even with no basket open.
- **Open basket** is offered on the row of an all-released cavity, so castings sitting in a basket at the
  press can be booked instead of explained.
- The "x N cavities" beside die-wide scrap counts cavities, not basket rows.

**The floor practice this is built for** (Jacques, 2026-10-08): open the basket before shift close and leave
it open; the shift-end entry credits what is left to it. Opening and closing a short basket at shift change
is the mistake being coached out.

### SQL

| Object | | What changes |
|---|---|---|
| `Workorder.ufn_CavityCreditedWithoutReading` | NEW | Pieces credited to a cavity without a reading since its last reading. Live credits only. |
| `Workorder.DieCast_GetShiftOutputBreakdown` | CHANGED v3.2 | Two columns appended: `CreditedWithoutReading`, `IsCavityCarrier`. An open basket's proposal is net of the former. `NewShots` / `CreditedThrough` unchanged. |
| `Workorder.DieCastShiftOutput_Record` | CHANGED v3.3 | With a reading, writes a zero-piece row where nothing was credited, so the reading and any variance reason are stored. No validation changed. |
| `Workorder.DieCastCredit_Write` | CHANGED v1.2 | New `@OmitCavity` (default 0; every existing caller unchanged). |

### Ignition -- two archives, in `dist\ignition-exports\`

| Archive | Resources |
|---|---|
| `Core_diecast-shift-end_2026-10-08_0844.zip` | MOD `ignition/script-python/BlueRidge/Workorder/DieCast` |
| `MPP_diecast-shift-end_2026-10-08_0844.zip` | MOD `.../Components/PlantFloor/DieCastEntry/CavityLotRow`, MOD `.../Views/ShopFloor/DieCastBody` |

`MPP_Config` has no changed resources and is not part of this release. Nothing was deleted.

### In the range but shipping nothing

`sql/tests/` (new suite `0022/120`, four updated assertions in `0045/030`), `sql/scratch/2026-10-0[78]_*`,
`notes/`, the reconciliation spec, and the `81b0fa21` / `caa6b458` pair, which cancel out.

---

## 2. What the database change is

| | |
|---|---|
| Migrations | 0 |
| Repeatables | 4 -- 1 new, 3 changed |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window | 0.1s on the sim |

One new function and three `CREATE OR ALTER PROCEDURE`. No table, column, index or existing row is touched.

**The one new kind of row.** Shift-end Submit can now write a `Workorder.DieCastContribution` row with
`PieceDelta = 0` carrying the reading. It is written only when the reading is new or a variance reason is
attached, with the LOT left alone (`@ApplyToLot = 0`). On a cavity whose baskets are all released the row
carries no cavity, so that cavity's counter position does not move and the next basket still gets the
castings made since the last release.

---

## 3. Risk

**Test 1 -- does anything now refuse what it used to allow?** One thing, by design: **Submit asks for a
variance reason on a cavity whose baskets are all released and whose numbers do not close.** Before, such a
cavity was not in the arithmetic at all. From prod's last eleven shifts (exposure query, 2026-10-08): 3 to 9
cavities per shift have pieces released by count, and almost none has a basket open at shift end. Until the
coaching takes hold, **expect a reason to be asked on most single-cavity presses at each shift end.** The way
out is on the row: Open basket, scan the LTT on Lot Management, come back and Compute -- the leftover goes
into that basket and the variance clears. Or pick a reason; `Unknown` with a note always works.

Where prod already has a shift-end reading, released pieces never exceeded it (0 cavities in eleven shifts),
so a **negative** unaccounted should be uncommon. It is shown in amber when it happens.

**Test 2 -- shared code?** `Workorder.DieCastCredit_Write` is the one writer of credit rows, shared with
`Lots.DieCastLot_Release` and the reconciliation form. Its only change is a new optional parameter; callers
that do not pass it behave exactly as before. Section 6.5 exercises a release, which is not this feature.

**Test 3 -- schema?** None.

**Test 4 -- does the old Ignition keep working against the new SQL?** It works, but **not cleanly**: with the
new procs and the old screens, an open basket on a cavity that released by count is offered the reduced
figure while the old screen still measures variance the old way, so it shows a variance equal to the
released pieces. **Do the two imports straight after the Execute, and do not run this across a shift
change.** (The new screens tolerate the old procs, which matters only for rollback.)

**What the audit found for shift reconciliation (the team-lead form).** No piece figure changes anywhere --
every reader sums pieces and a zero adds nothing. What the team lead will notice:

- A shift that gets its reading leaves "Released, no shift-end number" and the dashboard tile.
- That submit's entry card shows the reading and one more row or two.
- A reconciliation sheet opened before a live submit on the same shift is refused on save (as for any live
  write today).
- The form's die-life arithmetic starts from the recorded reading where it used to start from 0, which
  removes a double count.
- Moving such an entry to another shift carries its reading with it.

---

## 4. Deploy

Run from the repo root. Have the Designer open on the prod Gateway with the two zips to hand first.

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
  Database: 107 applied, highest 0108.
  No pending migrations.

[4] Repeatables -- target definitions vs this checkout
  504 identical, 3 changed, 1 new on the target.
    NEW      R__Workorder_ufn_CavityCreditedWithoutReading.sql
    CHANGED  R__Workorder_DieCast_GetShiftOutputBreakdown.sql
    CHANGED  R__Workorder_DieCastCredit_Write.sql
    CHANGED  R__Workorder_DieCastShiftOutput_Record.sql

[5] Pre-flight gates (read-only, against live data)

[8] Plan
  0 migration(s), 4 repeatable(s) in one transaction; then R__Descriptions_ExtendedProperties.sql after commit.
  Plan fingerprint: <copy this>

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

**Read `[2]` every time** -- it is the only line that names the database.

**If it differs:**

- *`R__Workorder_ufn_CavityShotWatermark.sql` listed as CHANGED* -- the rollback of 2026-10-08 did not hold
  and prod still has v4.0. **Stop.** That function zeroes the screen; run section 7's watermark file first.
- *Anything pending in `[3]`, or any other CHANGED / NEW repeatable* -- prod is not where this runbook
  assumes. Read the report's `diffs` folder before continuing.
- *A gate fires, or a WARN in `[6]`* -- stop and read it.

Copy the fingerprint; do not retype it. The local sim printed `18c62286990d` at `fe4cf41e`; yours will differ
because the commit of this note moved `HEAD`.

### Step 2 -- Rehearse

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE`. Expect:

```
[10] Running the release transaction
    == transaction open
    == [1] R__Workorder_ufn_CavityCreditedWithoutReading.sql
    == [2] R__Workorder_DieCast_GetShiftOutputBreakdown.sql
    == [3] R__Workorder_DieCastCredit_Write.sql
    == [4] R__Workorder_DieCastShiftOutput_Record.sql
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept

  REHEARSAL PASSED and was rolled back. Lock window: 0.1s.
```

**If the rehearsal fails, stop.** Nothing was written. Send me `deploy.log` from the report folder.

### Step 3 -- What changes right now? (read-only; already run once on 2026-10-08)

`sql\scratch\2026-10-08_shift_end_fix_exposure.sql`, in SSMS against `MPP_MES_Prod`. Section 3 of its output
lists, for the shift in progress, each cavity whose next Compute changes and how. Keep it for 6.2.

### Step 4 -- Execute

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <fingerprint>
```

Type `MPP_MES_Prod`. Expect:

```
[9] Backup
  BACKUP DATABASE -> ...\MPP_MES_Prod_pre-release_0108_<stamp>.bak (COPY_ONLY, CHECKSUM)
  Backup written and verified.

[10] Running the release transaction
    == transaction open
    ... steps [1] to [4] as in the rehearsal ...
    == checks passed
    == COMMITTED

[11] After commit
  R__Descriptions_ExtendedProperties.sql applied.
  Every repo migration is recorded.
  All 4 applied repeatable(s) now match the repo byte-for-byte.

DONE
```

- *`ABORT: plan is <a> but -ExpectedPlan is <b>`* -- something moved since the preview. Re-preview.
- *`FAILED -- the transaction was rolled back`* -- prod is unchanged. Read `deploy.log`.

**Go straight to the imports.** Until they are in, the old screens show a variance on any open basket whose
cavity released by count this shift.

### Step 5 -- Imports

Section 5. Core, then MPP.

---

## 5. Ignition imports

**SQL first (done in Step 4). Core first.** Designer -> File -> Import, one zip at a time, accepting overwrite
for the listed resources. Do **not** use the Gateway web page's project import.

1. `Core_diecast-shift-end_2026-10-08_0844.zip` -- 1 resource:
   `MOD ignition/script-python/BlueRidge/Workorder/DieCast`
2. `MPP_diecast-shift-end_2026-10-08_0844.zip` -- 2 resources:
   `MOD .../Components/PlantFloor/DieCastEntry/CavityLotRow`
   `MOD .../Views/ShopFloor/DieCastBody`
3. **F5 every die cast terminal.** A session left open across the update keeps the old rows.

`MPP_Config`: nothing.

---

## 6. Verification

### 6.1 SQL proof

```sql
SELECT CASE WHEN OBJECT_ID('Workorder.ufn_CavityCreditedWithoutReading') IS NOT NULL THEN 'fn ok' ELSE 'fn MISSING' END
     + ' / ' + CASE WHEN OBJECT_DEFINITION(OBJECT_ID('Workorder.DieCast_GetShiftOutputBreakdown')) LIKE '%IsCavityCarrier%' THEN 'breakdown NEW' ELSE 'breakdown OLD' END
     + ' / ' + CASE WHEN OBJECT_DEFINITION(OBJECT_ID('Workorder.DieCastShiftOutput_Record')) LIKE '%@ReadingWritten%' THEN 'record NEW' ELSE 'record OLD' END
     + ' / ' + CASE WHEN OBJECT_DEFINITION(OBJECT_ID('Workorder.DieCastCredit_Write')) LIKE '%@OmitCavity%' THEN 'credit NEW' ELSE 'credit OLD' END
     + ' / ' + CASE WHEN OBJECT_DEFINITION(OBJECT_ID('Workorder.ufn_CavityShotWatermark')) LIKE '%@Readingless%' THEN 'watermark v4.0 -- WRONG' ELSE 'watermark v3.0' END AS State;
```

Expect `fn ok / breakdown NEW / record NEW / credit NEW / watermark v3.0`.

### 6.2 The screen, read-only -- do this on a real press before anyone submits

On a press from Step 3's list (Machine 304 is the reference case): **Reconcile Shift**, choose the shift,
type the counter reading and the warm-up / test shots, **Compute**. Do not submit yet.

- The cavity's **last** basket row shows SHOTS (reading less die-wide), a line "N pc already released on this
  cavity this shift without a counter reading", and a VARIANCE. Earlier basket rows show `-` in both.
- **PARTS** is that shots figure per cavity with a basket; **GOOD** includes the released pieces;
  **UNACCOUNTED** is the sum of the variance column.
- "x N cavities" beside die-wide scrap is the number of cavities on the die.
- If any of that is still all zeros, the terminal has the old views: F5, Compute again. If it still is, tell
  me the press, die, shift and reading.

Machine 304, 10-07 Third Shift, 367 with 40 warm-up + 2 test shots should read PARTS 325, GOOD 359,
UNACCOUNTED -34.

### 6.3 The first real submit -- never done on a screen. Do it deliberately, once.

On that same press at shift end, with a variance showing: open the reason box on the row, pick a reason,
**Submit Shift Entry**. Then:

```sql
SELECT TOP 5 l.LotName, c.PieceDelta, c.ShotCounterReading, c.ToolCavityId, vr.Code AS Reason, c.VarianceNote,
       CAST(c.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS EventEt
FROM Workorder.DieCastContribution c
JOIN Lots.Lot l ON l.Id = c.LotId
LEFT JOIN Workorder.DieCastVarianceReason vr ON vr.Id = c.VarianceReasonId
WHERE c.PieceDelta = 0 AND c.ShotCounterReading IS NOT NULL
ORDER BY c.Id DESC;
```

Expect one row for that cavity: `PieceDelta 0`, the reading, your reason, and `ToolCavityId` NULL (no basket
was open). The shift should leave "Released, no shift-end number" on the reconcile landing list.

### 6.4 An open basket

On a press where the basket was opened before shift close and left open: Compute. **Good** on the open basket
is the reading, less die-wide, less the pieces already released; VARIANCE is 0 before any scrap. Submit; the
basket's count goes up by that Good.

### 6.5 Something that is not the feature (the shared credit writer)

Release any basket from Lot Management by typing its count, as operators do now. It releases, the LOT's count
is what was typed, and it moves to the Warehouse exactly as before.

### 6.6 The reconciliation form

Open the reconcile landing list for that press. The shift from 6.3 shows the reading under SHIFT-END READING
and an "Entry recorded" status; opening it lists the same LOTs with the same Recorded figures as before.

---

## 7. Rollback

**Before COMMIT:** automatic.

**Ignition** -- import the previous versions (built and verified, never imported in anger):

1. `Core_diecast-shift-end-ROLLBACK_2026-10-08_0845.zip`
2. `MPP_diecast-shift-end-ROLLBACK_2026-10-08_0845.zip`
3. F5 the die cast terminals.

**SQL** -- re-create the three procs as the previous release had them. Run against `MPP_MES_ProdSimWM2` and
verified. In SSMS: open `sql\scratch\2026-10-08_ROLLBACK_diecast_shift_end.sql`, database `MPP_MES_Prod`,
Execute. Or:

```powershell
sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -I -C -b -i "sql\scratch\2026-10-08_ROLLBACK_diecast_shift_end.sql"
```

It prints nothing on success (and does not prompt while `SQLCMDPASSWORD` is still set in that terminal). Then
6.1 should read `fn ok / breakdown OLD / record OLD / credit OLD / watermark v3.0`. The new function is left in
place; nothing calls it.

**Order for a rollback: Ignition first, then SQL** -- the new screens tolerate the old procs; the old screens
show a spurious variance against the new ones.

Zero-piece reading rows already written stay. They are harmless to the old code (Lots.DieCastLot_Release has
written the same kind of row since September), and they are what tells the dashboard the shift has its number.
No restore is needed for this release.

**The watermark function, only if Step 1 says prod still has v4.0:**
`sql\scratch\2026-10-08_ROLLBACK_ufn_CavityShotWatermark_v3.sql`, same way.

---

## 8. Known limits (say these to the floor)

- Until baskets are opened before shift close, expect a variance -- and a reason, or Open basket -- on most
  single-cavity presses at each shift end.
- Open basket on the row takes you to Lot Management to scan the LTT; come back to Reconcile Shift and press
  Compute again. What you typed in a row before leaving is not kept.
- A release where a counter reading IS typed still ignores pieces released by count earlier in the shift.
- A release filed under the wrong shift counts against that wrong shift (Machine 202: terminal left open
  across shift changes). Still open.
- A released LOT's history gains an "Added 0 pc" line when the shift-end reading is stored on it.
- The part group header on the tab counts basket rows, not cavities ("3 cavities" for 2). It did before.
- Nothing already recorded is corrected: Machine 11's three baskets from 10-07 First Shift, and any entry
  submitted while v4.0 was live (2026-10-07 16:32 to the rollback), still need fixing by hand.

---

## 9. Outcome -- filled in after the release

_(still to fill in)_

| | |
|---|---|
| Executed at | |
| Prod before | SQL `0108`, 107 migrations, watermark v3.0 |
| Plan fingerprint | |
| Backup path | |
| Preview `[4]` | |
| Live activity `[6]` | |
| Prod rehearsal lock window | |
| Report folder | |
| Imports done at / terminals reloaded | |
| 6.1 state line | |
| 6.2 screen seen on | |
| 6.3 first submit: row written / shift status | |
| 6.4 open basket | |
| 6.5 release by count unchanged | |
| 6.6 reconciliation form | |
| Anything that went sideways | |
