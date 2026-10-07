# Prod release runbook -- die cast: a basket released without a reading is no longer credited twice

**Release commit:** `81b0fa21` on `jacques/working` -- the one commit that changes anything deployable.
**Previous release:** executed 2026-10-07 08:39 ET from `3a39e5f5` (deployables identical to `0647dc97`:
low-inventory lock, supplier-lot warning, Record Scrap by part, LOT notes). Prod is at SQL **`0108`**,
107 migrations. Backup from that run: `MPP_MES_Prod_pre-release_0106_20261007_083905.bak`.
**Rehearsed against:** `MPP_MES_ProdSimWM`, built from a worktree at `0647dc97` -- prod's state (107 applied,
highest `0108`, the watermark function at v3.0). Preview + Rehearse clean, rollback verified; it is still at
prod's state. A full **Execute** was run against a second sim, `MPP_MES_ProdSimWM2`, to cover the backup and
the post-commit step; the rollback in section 7 was then run against it and verified.
**SQL suite:** 4380 assertions / 4380 passed / 0 failed, exit 0, on `MPP_MES_Test_WM` (the previous release's
4362 plus 18 new).

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint's first
> hashed line is the raw HEAD sha, so **any** commit changes it -- a docs-only commit included -- and
> Execute refuses. Re-preview and use the new fingerprint.
>
> **There are no Ignition archives in this release**, so the only staleness test is:
> ```powershell
> git diff --stat 81b0fa21..HEAD -- ignition/ sql/migrations/
> ```
> Expect **no output**. Anything listed means this runbook no longer describes what would deploy.

> **Read this before deciding to ship.** What has and has not been proven:
>
> 1. **The arithmetic is proven in SQL only.** The new suite replays the prod case (515 released without a
>    reading, then reading 1,092 with 54 die-wide shots -> 523 proposed, not 1,038) through the real procs.
>    **Nobody has watched the Reconcile Shift tab show the smaller number.** No screen changed, the screen
>    reads the proposal straight from the proc, and Dev has the new function -- but section 6.2 is the first
>    time it is seen on a terminal.
> 2. **A reading smaller than what a cavity is already credited now proposes 0.** That is the "looks like a
>    dead binding" symptom the 2026-08-19 rule was written to remove. It comes back only in that one case.
>    Section 3 says when it happens and what the operator does.
> 3. **It does not repair anything already recorded.** Machine 11's 10-07 First Shift still carries 1,038 on
>    each of the three open baskets where 523 was cast. Correct those through the reconciliation form.

---

## 1. What this ships

Operators release a basket mid-shift by typing the pieces, with no press counter reading. Until now that
credit was invisible when the shift-end number was entered, so the next basket on that cavity was offered
the whole counter reading -- the same castings counted twice. On 2026-10-07, Machine 11
(6MA IN 1&5 EX 1&5 - F): three baskets released with 515 each, then the shift-end entry at reading 1,092
credited 1,038 to each successor basket. 523 was right. Nothing on the screen flagged it, because the shot
count the variance is measured against was wrong by the same amount.

After this release, pieces credited without a reading count against the cavity. The shift-end entry and the
Release dialog both offer what is left.

### SQL

| Object | | What changes |
|---|---|---|
| `Workorder.ufn_CavityShotWatermark` | CHANGED (v3.0 -> v4.0) | A cavity is credited through the last reading on record **plus pieces credited without a reading since**. Only live credits count; rows written by the reconciliation form do not. |

Nothing else is modified. Three procs call this function and pick the change up as they are:
`Workorder.DieCast_GetShiftOutputBreakdown` (the Reconcile Shift tab's per-cavity proposal and shot count),
`Workorder.DieCast_GetReleasePreview` (the Release dialog's "new shots"), and `Lots.DieCastLot_Release`
(the pieces derived when a reading **is** typed at release).

### Ignition

**None.** No view, script or named query changed. There is nothing to import and no terminal needs a reload.

### In the range but shipping nothing

- `sql/tests/` -- new suite `0022_PlantFloor_DieCast/120_ReadinglessRelease.sql`; four assertions in
  `0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql` that pinned the old rule, updated with dated notes.
- `docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md` -- section 9 marked superseded.
- `sql/scratch/2026-10-07_*.sql` -- the Machine 302 wrong-die correction scripts (already run by hand).
- This note.

---

## 2. What the database change is

| | |
|---|---|
| Migrations | 0 |
| Repeatables | 1 -- changed |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window | 0.1s on the sim |

One `CREATE OR ALTER FUNCTION`. No table, column, index or data is touched, so there is nothing to backfill
and nothing to lock beyond the function's own definition for the length of the transaction. The function
gains two small reads of `Workorder.DieCastContribution` on the same cavity + shift + press it already
reads; it runs a handful of times per screen load.

**Die life is not affected.** `Workorder.ufn_DieShotWatermark` is unchanged: a die's shot count still advances
only when a real reading is recorded, by (reading - die watermark).

---

## 3. Risk

**Test 1 -- does anything now refuse what it used to allow?** Nothing is refused. One thing is **offered
differently**, and it will be noticed:

- *Normal case.* A cavity that had a basket released without a reading this shift is offered less at shift
  end -- less by exactly the pieces already released. That is the fix.
- *The case to warn the floor about.* If the pieces typed at a reading-less release include castings from
  an **earlier shift** (a basket carried over a shift change that the earlier shift never settled), those
  pieces count against this shift's counter. The next basket on that cavity is offered low, down to **0**.
  Real example: Machine 302, LOT 10629856 -- 60 typed at 23:38 on third shift, 39 of them cast on second.
  **What the operator does:** type the real good count (the field is editable); if the screen then asks for
  a variance reason, `Unknown` with a note is always available. The reconciliation form is the repair.
  Before this release the same situation over-credited the basket by the whole release instead, silently.

Step 4 lists every cavity where the offer changes **right now**, so the number is known before the change.

**Test 2 -- shared code?** No. The function is called only by die cast procs. Nothing under `Common`.

**Test 3 -- schema?** None.

**Test 4 -- does the old Ignition keep working against the new SQL?** Yes; there is no new Ignition. The
function's signature and return type are unchanged.

**The shift in progress when this lands.** Entries already saved are untouched. For the open shift, any
basket released without a reading earlier in that shift starts counting from the moment of the Execute, so
that shift's end-of-shift offer is already the corrected one. No quiet window is needed.

**What it does not fix.** A release stamped to the **wrong shift** is counted against that wrong shift. That
is the Machine 202 problem (terminal left open across shift changes, releases filed under the earlier
shift), it is separate, and it is still open.

---

## 4. Deploy

Run from the repo root.

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
  506 identical, 1 changed, 0 new on the target.
    CHANGED  R__Workorder_ufn_CavityShotWatermark.sql

[5] Pre-flight gates (read-only, against live data)

[8] Plan
  0 migration(s), 1 repeatable(s) in one transaction; then R__Descriptions_ExtendedProperties.sql after commit.
  Plan fingerprint: <copy this>

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

**Read `[2]` every time** -- it is the only line that names the database.

**If it differs:**

- *Anything pending in `[3]`, or not 107 / `0108`* -- prod is not where this runbook assumes. Stop.
- *Any other CHANGED or NEW repeatable* -- prod has drifted from git. Read the report's `diffs` folder before
  continuing; this runbook no longer describes what you are about to do.
- *A gate fires, or a WARN in `[6]`* -- stop and read it. A long open transaction will block the lock.

Copy the fingerprint; do not retype it. The local sim printed `6e8f6ff314eb` at `48bf139f`; yours will
differ because the commit of this note moved `HEAD`.

### Step 2 -- Rehearse

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE`. Expect:

```
[10] Running the release transaction
    == transaction open
    == [1] R__Workorder_ufn_CavityShotWatermark.sql
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept

  REHEARSAL PASSED and was rolled back. Lock window: 0.1s.
```

**If the rehearsal fails, stop.** Nothing was written. Send me `deploy.log` from the report folder.

### Step 3 -- What changes right now? (read-only; do this BEFORE the Execute)

Every cavity in the shift in progress that has pieces credited without a reading. These are the cavities
whose next offer gets smaller. `CreditedThrough` shows the **old** function's answer here, because the
release is not applied yet.

```sql
SET NOCOUNT ON;
;WITH open_shift AS (SELECT TOP 1 Id, ActualStart FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC),
c AS (
    SELECT c.ToolCavityId, c.CellLocationId, c.ShiftId, c.Id, c.PieceDelta, c.ShotCounterReading, src.Code AS Src
    FROM Workorder.DieCastContribution c
    INNER JOIN open_shift s ON s.Id = c.ShiftId
    INNER JOIN Oee.ShiftAttributionSource src ON src.Id = c.ShiftAttributionSourceId
    WHERE c.ToolCavityId IS NOT NULL AND c.CellLocationId IS NOT NULL)
SELECT loc.Code AS Press, t.Name AS Die, i.PartNumber, tc.CavityCode AS Cavity,
       MAX(c.ShotCounterReading) AS LastReading,
       SUM(CASE WHEN c.ShotCounterReading IS NULL AND c.Src = N'Derived' THEN c.PieceDelta ELSE 0 END) AS ReadinglessPieces,
       Workorder.ufn_CavityShotWatermark(c.ToolCavityId, c.ShiftId, c.CellLocationId) AS CreditedThrough
FROM c
INNER JOIN Tools.ToolCavity tc   ON tc.Id  = c.ToolCavityId
INNER JOIN Tools.Tool t          ON t.Id   = tc.ToolId
LEFT  JOIN Parts.Item i          ON i.Id   = tc.ItemId
INNER JOIN Location.Location loc ON loc.Id = c.CellLocationId
GROUP BY loc.Code, t.Name, i.PartNumber, tc.CavityCode, c.ToolCavityId, c.ShiftId, c.CellLocationId
HAVING SUM(CASE WHEN c.ShotCounterReading IS NULL AND c.Src = N'Derived' THEN c.PieceDelta ELSE 0 END) > 0
ORDER BY loc.Code, i.PartNumber, tc.CavityCode;
```

How to read it:

- *No rows* -- nobody has released a basket without a reading this shift. Nothing changes until one does.
- *Rows with `LastReading` NULL* -- the ordinary case. After the Execute, `CreditedThrough` for that cavity
  becomes `ReadinglessPieces`, and the shift-end offer drops by that much.
- *Rows with a `LastReading`* -- only the reading-less pieces entered **after** that reading count. The query
  sums all of them, so `ReadinglessPieces` may overstate; section 6.1 shows the real figure afterwards.

Keep the result. It is the before picture for section 6.1.

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
    == [1] R__Workorder_ufn_CavityShotWatermark.sql
    == verifying inside the transaction
    == checks passed
    == COMMITTED

[11] After commit
  R__Descriptions_ExtendedProperties.sql applied.
  Every repo migration is recorded.
  All 1 applied repeatable(s) now match the repo byte-for-byte.

DONE
```

- *`ABORT: plan is <a> but -ExpectedPlan is <b>`* -- something moved since the preview. Re-preview.
- *`FAILED -- the transaction was rolled back`* -- prod is unchanged. Read `deploy.log`.

The script ends by saying `Import the Ignition exports NOW`. **There are none for this release.** You are done
with the deploy.

---

## 5. Ignition imports

**None.** Core, MPP and MPP_Config have no changed resources and are not part of this release.

---

## 6. Verification

### 6.1 The function is the new one, and the numbers moved (SQL)

```sql
SELECT CASE WHEN OBJECT_DEFINITION(OBJECT_ID('Workorder.ufn_CavityShotWatermark')) LIKE '%@Readingless%'
            THEN 'v4.0' ELSE 'v3.0' END AS WatermarkFunction;
```

Expect `v4.0`. Then re-run the Step 3 query. For every row whose `LastReading` was NULL, `CreditedThrough`
should now equal `ReadinglessPieces` where it was 0 before.

### 6.2 The screen -- the part nobody has seen. Do this first on a real press.

**This is the one hop that was never observed.** Everything up to the proc's result set is covered by the SQL
suite; no view changed; but the Reconcile Shift tab showing the smaller offer has not been watched.

1. Pick a press from the Step 3 list (or wait for the next basket released without a reading).
2. On that press's terminal, open **Reconcile Shift**, choose the shift in progress, type the current counter
   reading, press **Compute**. Do **not** submit unless it is actually shift end.
3. On the cavity that had the release: **Good** should be the reading, less die-wide shots, less the pieces
   already released. On a cavity that never rolled, it is still the reading less die-wide.
4. If Good on the rolled cavity still equals the full reading, the terminal is showing a stale result --
   press **Refresh** and Compute again. If it still does, tell me the press, die and reading.

### 6.3 The Release dialog

Open a basket's Release dialog on a cavity from the Step 3 list and type a counter reading. "New shots"
should be the reading less what the cavity is already credited through. Cancel out.

### 6.4 Something that is not the feature

On a press where every release this shift carried a reading (not in the Step 3 list), Compute at shift end
proposes exactly what it did yesterday. That is the proof that reading-based credits were left alone.

---

## 7. Rollback

**Before COMMIT:** automatic.

**After COMMIT:** put the previous function back. This was run against `MPP_MES_ProdSimWM2` and verified.

```powershell
cmd /c "git show 0647dc97:sql/migrations/repeatable/R__Workorder_ufn_CavityShotWatermark.sql > %TEMP%\ufn_CavityShotWatermark_v3.sql"
sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -I -C -b -i "$env:TEMP\ufn_CavityShotWatermark_v3.sql"
```

(`cmd /c` on purpose: a PowerShell `>` would write the file as UTF-16.) Then the 6.1 check should say `v3.0`.

Rolling back changes offers from that moment on and nothing already saved. It needs no restore; do not reach
for the backup for this release. Afterwards the repo and prod disagree on that one function, and the next
preview will list it as CHANGED -- revert `81b0fa21` in git as well, or expect it.

**Ignition:** nothing to roll back.

---

## 8. Known limits (say these to the floor)

- A basket released without a reading whose typed pieces include an earlier shift's castings makes the next
  basket's offer low, down to 0. Type the real count; use the reconciliation form to fix the split.
- A release filed under the wrong shift counts against that wrong shift (Machine 202, still open).
- Per-cavity scrap is not part of this. A reading-less release says how many good castings went in the
  basket; shots that made scrap between readings still show as variance at shift end, as before.
- Nothing already recorded is corrected. Machine 11, 10-07 First Shift, still needs its three open baskets
  fixed by hand.
- Entries made through the reconciliation form never move the watermark, before or after this release.

---

## 9. Outcome -- filled in after the release

_(still to fill in)_

| | |
|---|---|
| Executed at | |
| Prod before | SQL `0108`, 107 migrations |
| Plan fingerprint | |
| Backup path | |
| Preview `[4]` | |
| Live activity `[6]` | |
| Prod rehearsal lock window | |
| Report folder | |
| Step 3: cavities listed before | |
| 6.1 function version / CreditedThrough moved | |
| 6.2 Reconcile Shift offer seen on | |
| 6.3 Release dialog | |
| 6.4 press with readings unchanged | |
| Anything that went sideways | |
