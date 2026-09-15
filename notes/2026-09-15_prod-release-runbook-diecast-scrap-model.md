# Prod release runbook — Die Cast quantity + scrap model (and Die Mount)

**Date:** 2026-09-15
**Branch:** `jacques/working` — merged to `main`, both at `fd531161`
**Prod is currently at:** HEAD `c8822c4c`, migration `0083`
  (last Execute: `dist/deploy-reports/MPP_MES_Prod_Execute_20260914_180517`)
**Range shipping:** `c8822c4c..fd531161`

This carries **two** bodies of work, because the Die Mount release was prepared on
2026-09-14 and never executed:

- **Die Mount at the press** — `3616026e`, `bf377911`, `860d4d83`
- **Die Cast quantity + scrap model** — migration `0084` and everything after

---

## 0. Before you start

- **Do not commit anything between the preview and the execute.** The plan
  fingerprint includes HEAD; a commit invalidates it and Execute will refuse.
- `sql/scratch/` has five untracked files. They do **not** block — the checkout
  gate only inspects `sql/migrations`.
- Password: never on the command line. Let the script prompt (masked) when
  `-Username` is given.

---

## 1. What the SQL release applies

**One versioned migration:**

| | |
|---|---|
| `0084_diecast_cavity_scrap_attribution` | `RejectEvent.LotId` → nullable + 5 attribution columns; `DieCastContribution` gains `ToolCavityId` + variance disposition; `Workorder.DieCastVarianceReason` (5 rows); defect code `DC-999 Warmup` |

**Fourteen repeatables** (the script applies only those whose definition on the
target actually differs — it compares text, it does not trust commit history):

```
R__Workorder_ufn_CavityShotWatermark          R__Tools_ToolAssignment_GetCellContext
R__Workorder_RejectEvent_Record               R__Tools_ToolAssignment_Release
R__Workorder_DieCast_GetShiftOutputBreakdown  R__Tools_ToolCavity_Deprecate
R__Workorder_DieCastShiftOutput_Record        R__Tools_ToolCavity_SaveAll
R__Lots_DieCastLot_Release                    R__Tools_Tool_ListEligibleForCell
R__Quality_Reject_GetPartMatrix               R__Quality_Reject_GetPartMatrixByParty
R__Quality_Reject_GetPartMatrixDefects        R__Quality_Reject_SearchDetail
```

**`sql/seeds/030_seed_defect_codes.sql` also changed and is deliberately NOT
deployed.** The deploy script runs no seeds. `DC-999` reaches prod through
migration `0084` instead — that is the `0048`/`0067`/`0075` dual-delivery
pattern: a fresh reset runs migrations before seeds, an in-place upgrade never
re-runs seeds, so the code is written in both places and lands exactly once.

### The one step that can fail silently

`0084` makes `RejectEvent.LotId` nullable. `LotId` is the leading key of a
**clustered index on a partitioned table**, so the migration drops the FK, drops
`CIX_RejectEvent_LotRecordedAt`, alters the column, and **recreates the index
`ON ps_MonthlyUtc(RecordedAt)`**.

Recreating it on `PRIMARY` instead would break sliding-window `TRUNCATE`
retention (B2) — silently, surfacing only at the next partition maintenance run.
**Verify alignment after the execute** (§5). Prod carries ~67 reject rows, so the
rebuild is sub-second.

---

## 2. Preview — read-only, produces the fingerprint

```powershell
cd C:\Users\JacquesPotgieter\Documents\Dev\MPP
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition
```

**Expect:** `82 applied, highest 0083` on the database, **1 migration + ~14
repeatables** planned, zero `BLOCK` findings, and a **plan fingerprint** printed
at the end. Read the findings before going on.

**If it reports a BLOCK** — out-of-order pending migrations, a dirty
`sql/migrations` tree, or a failed pre-flight gate — stop and report it. Do not
`-Force` past a BLOCK.

Record the fingerprint. Everything below uses it.

---

## 3. Rehearsal — the real thing, rolled back

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -Mode Rehearse -ExpectedPlan <fingerprint>
```

This runs the actual deploy script against prod's real rows inside a
transaction, verifies it, then **rolls back**. It takes the same locks as
Execute for the same few seconds. This is what proves `0084`'s index rebuild
applies cleanly to prod's actual data.

**Expect:** the migration applies, every repeatable applies, verification
passes, `ROLLBACK`, and the database unchanged.

---

## 4. Execute — the only irreversible step

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -Mode Execute -ExpectedPlan <fingerprint>
```

Takes a `COPY_ONLY` backup (with `VERIFYONLY`) first, then applies everything in
**one transaction**. Any error anywhere rolls the entire release back — there is
no partial state. `R__Descriptions_ExtendedProperties` runs after the commit,
outside the transaction, so it never holds locks on every table.

Inside the transaction: `DEADLOCK_PRIORITY LOW` (the plant wins a deadlock) and
a lock timeout (abort cleanly rather than queue production behind the release).

---

## 5. Verify the SQL before touching Ignition

```sql
-- every index on the partitioned reject table must be ALIGNED
SELECT i.name, ds.name AS DataSpace
FROM sys.indexes i
JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
WHERE i.object_id = OBJECT_ID('Workorder.RejectEvent') AND i.index_id > 0;
```

**Every row's `DataSpace` must read `ps_MonthlyUtc`.** If any reads `PRIMARY`,
partition maintenance is broken — drop that index and recreate it with
`ON ps_MonthlyUtc(RecordedAt)` before going further.

```sql
SELECT COUNT(*) FROM Workorder.DieCastVarianceReason;              -- 5
SELECT Code, IsNonRejectScrap FROM Quality.DefectCode WHERE Code='DC-999';  -- 1
SELECT is_nullable FROM sys.columns
 WHERE object_id=OBJECT_ID('Workorder.RejectEvent') AND name='LotId';       -- 1
SELECT is_nullable FROM sys.columns
 WHERE object_id=OBJECT_ID('Workorder.DieCastContribution') AND name='LotId'; -- 0
```

That last one matters: `DieCastContribution.LotId` **stays NOT NULL**. It is what
stops a basketless cavity advancing its shot watermark. If it comes back `1`,
something applied that should not have.

---

## 6. Ignition imports — SQL first, Core first

Archives in `dist\ignition-exports\` (built from git, range `c8822c4c..HEAD`):

| Order | Archive | Resources |
|---|---|---|
| 1 | `Core_diecast-scrap-model_2026-09-15_0829.zip` | 7 — stylesheet, 3 NQs, 3 script modules |
| 2 | `MPP_diecast-scrap-model_2026-09-15_0829.zip` | 10 — DieCastBody, 4 DieCastEntry rows, DieCastRelease, DieMount, 3 How-To |
| 3 | `MPP_Config_diecast-scrap-model_2026-09-15_0829.zip` | 1 — Tools CavityRow |

**Core FIRST** — `MPP` and `MPP_Config` both declare `"parent": "Core"` and will
not resolve inherited resources without it.

Checklist of exact contents:
`dist\ignition-exports\diecast-scrap-model_2026-09-15_0829_CONTENTS.txt`

### One manual step an import cannot do

`Components/PlantFloor/DieCastEntry/RejectPanel` was **deleted**. An import adds
and replaces; it never removes. **Delete that view in the Designer** after
importing. It has been dead since the 2026-07-29 rebuild, so nothing references
it — but leaving it behind leaves a dead view in prod.

---

## 7. Smoke at a terminal

1. Die Cast screen → pick a press → **Lot Management** and **Reconcile Shift**
   are the only two tabs; no right-hand KPI rail; no die-life pill.
2. Switch the active cell → the die, the rows and the footer all change, and
   the Reconcile grid clears.
3. **Reconcile Shift → enter a counter reading → Compute → Submit.** Confirm a
   `DieCastContribution` row lands with the right `ShiftId` and `ToolCavityId`.
4. Release a basket entering a counted figure → basket closes at
   `on-basket + what you entered`.
5. Rejects — Part Matrix renders and shows die-cast scrap.

---

## 8. Rollback

The release is one transaction, so a failure during Execute leaves nothing
applied. If something is discovered **after** a successful commit, restore the
`COPY_ONLY` backup the Execute run took (path is in its `backup.txt`). The
Ignition side rolls back by re-importing the previous archives.

---

## 9. What is NOT verified — read this before you decide

**The reconcile submit path has never been run end to end.** `DieCastShiftOutput_Record`
v3.0's new paths — cavity-keyed lines, basketless scrap, the disposition gate,
die-wide fan-out across active cavities — are green in the SQL suite
(**3610/3610**) and were never exercised through the screen. `recomputeTotals`
was rewritten five times during smoke on 2026-09-15 and no version of it has
been through a Submit. Step 7.3 is therefore the **first** real exercise of the
feature this release exists for.

Verified live on Dev: basket release with a counted figure (`000000027`,
100 → 237), the cell-switch refresh, both tabs rendering, and the reject reports
showing a lot-free scrap row under the right part.

**Also outstanding, none of them blockers:**

- A release with **no counter reading** writes its contribution with
  `ShotCounterReading = NULL`, leaving that cavity's watermark at 0 — so the next
  basket on it is credited the full reading again. Observed on Dev
  (contribution `20087`). Decide whether a release should require a reading.
- `Tools.Tool.ShotCount` is not tracking production (100 on a die that has cast
  eleven baskets), and no die carries a `ShotLimit`. The die-life pill was
  removed for exactly this reason.
- The **−15% type scale is global** — it moves every MPP plant-floor screen, not
  just die cast. 466 hard-coded `fontSize` props across 117 views do not move
  with it; 102 of those sit at 18/20/22px, now above the new `base` (17).
- `Lots.Lot_GetShiftCavityTally` is now dead code (its rail is gone) and has not
  been retired. Harmless; scoped in `.superpowers/sdd/progress.md`.
