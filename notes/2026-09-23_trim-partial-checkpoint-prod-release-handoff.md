# Trim partial checkpoint at shift end -- prod release handoff (2026-09-23)

**For:** whoever assembles the production release. Everything below is built, reviewed and applied
to `MPP_MES_Dev` only. Nothing has gone near prod.

**Spec:** `docs/superpowers/specs/2026-09-22-trim-partial-shift-end-design.md`
**Plan:** `docs/superpowers/plans/2026-09-22-trim-partial-shift-end.md`
**Execution ledger:** `.superpowers/sdd/progress.md` (section "Trim Partial Checkpoint"), per-task
reports and review packages in `.superpowers/sdd/`.
**Process reference:** `prod-release-context-pack/` -- read `01_the_release_contract.md` first.

---

## 1. What this ships, in one paragraph

A trim operator can optionally press **Record partial trim - shift end**, pick the LOT on the press,
type the **total trimmed so far on that LOT**, and pick the shift the work belongs to. That writes
one cumulative `Workorder.ProductionEvent` checkpoint (the route's `TrimIn` template) and leaves the
LOT exactly where it is, so the FIFO queue is undisturbed. Trim OUT is unchanged for the operator.
Each shift's credit is the difference between consecutive **trim** checkpoints on the LOT
(700 then 253 on a 953-piece LOT, rather than 953 to whoever pressed Trim OUT). The blast presses
will use it; the tumblers never will, because their LOTs do not straddle a shift.

## 2. Commit range

Base `1dbf0c40` (the plan commit) .. head `39b14184`, branch `jacques/working`.

| Commit | What |
|---|---|
| `eb35fe95` | migration `0096` -- `ProductionEvent.ShiftId` + extended property + schema test |
| `fa91da7f` | Core NQs + `BlueRidge.Workorder.TrimPartial` **and** the `TrimPartial` popup (two tasks landed in one commit -- concurrent staging; contents are correct) |
| `0eb166ce` | `Workorder.TrimPartial_Record` + tests |
| `62acec1a` | test-only: 0096 fixture cleanup scoped to `TPC-` LOTs |
| `77e62cdc` | `Workorder.TrimCheckpoint_GetLatestForLot` + test |
| `250f058f` | `Workorder.TrimOut_Record` v1.5 + test |
| `26671c73` | test-only: `0024/050` D1 regression now uses a trim checkpoint |
| `af0a3f17` | `TrimBody` -- button + already-recorded line |
| `39b14184` | docs: data model v3.0 row + `PROJECT_STATUS` entry |

Unrelated commits by a concurrent session sit inside that range (`4c903d2f`, `4ef1855e`,
`1d5d9e82` -- training deck and the shift-reconciliation spec). **They are not part of this
release.** The database side is unaffected by them; for Ignition see §4, where the range happens to
touch only this feature's five resources.

## 3. Database change

**One pending migration: `0096_trim_partial_checkpoint.sql`.** Adds
`Workorder.ProductionEvent.ShiftId BIGINT NULL` + `FK_ProductionEvent_Shift` -> `Oee.Shift(Id)`, and
rewrites the `LogEventType` 34 description. Adding a nullable column is metadata-only, which matters
because `ProductionEvent` is born partitioned on `EventAt`. No backfill: every existing row keeps
`ShiftId` NULL, by design.

**Repeatables changed (re-applied by the deploy):**

- `R__Workorder_TrimPartial_Record.sql` -- new
- `R__Workorder_TrimCheckpoint_GetLatestForLot.sql` -- new
- `R__Workorder_TrimOut_Record.sql` -- v1.5 (three changes, §6)
- `R__Descriptions_ExtendedProperties.sql` -- the new column's description

**No seed changes.** The `TrimIn` / `TrimOut` operation templates already exist (seed `024`).

**Prod migration state must be checked first.** Dev was at `0095` before this. If prod sits below
that, the release either carries the intervening migrations or waits -- decide before writing the
preview. `0096` depends on `0084` (which added `RejectEvent.ShiftId`) and on `0024`
(`LogEventType` 34); both are old, but the preflight should prove it rather than assume.

## 4. Ignition resources -- scoped export

Build from git, never a whole project:

```powershell
.\tools\Build-ChangeExport.ps1 -Since 1dbf0c40 -Label trim-partial-checkpoint
```

Verified: the range touches exactly these five resource folders and nothing else, so the concurrent
session's commits contribute nothing to the archive. Confirm that again at build time
(`git diff --name-only 1dbf0c40 HEAD -- ignition/`) in case more lands on the branch first.

| Project | Resource |
|---|---|
| Core | `ignition/named-query/workorder/TrimPartial_Record` (new) |
| Core | `ignition/named-query/workorder/TrimCheckpoint_GetLatestForLot` (new) |
| Core | `ignition/script-python/BlueRidge/Workorder/TrimPartial` (new) |
| MPP | `com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/TrimPartial` (new) |
| MPP | `com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/TrimBody` (modified) |

**Import Core first** -- MPP inherits from it.

`TrimBody` is the only modified existing view. It was edited **as a file** (the user confirmed the
Designer was closed), spliced in the Designer's own format: 76 insertions, 0 deletions. Someone
should open it in the Designer once before the release and confirm it loads clean.

## 5. Pre-flight gates to write

1. **Prod is at `0095`** (or the release carries what is missing), and `0096` is the only pending
   migration this release applies.
2. **`Workorder.RejectEvent.ShiftId` exists** (migration `0084`) and **`Audit.LogEventType` 34
   `TrimCheckpointRecorded` exists** (migration `0024`). Both are prerequisites of `0096`'s writers.
3. **Every item that trims has a `TrimIn` step on its active published route.** The popup resolves
   its template by route role; an item whose route lacks `TrimIn` gives the operator a "template
   missing" toast and cannot record a partial. Query: items with a `TrimOut` route step but no
   `TrimIn` step on the same published route.
4. **`Oee.Shift` rows cover recent business dates at the trim shops.** See the open decision in §7 --
   this gate is what tells you whether Trim OUT's automatic shift stamp will resolve on the floor.
5. Standard: COPY_ONLY backup verified, plan fingerprint from the preview that was read, nothing
   committed between preview and execute.

## 6. What changed in `TrimOut_Record` (v1.5) -- the risk worth reading

Three changes, all behavioural:

1. The "count cannot decrease" guard now compares against the LOT's last **trim** checkpoint
   (`TrimIn` / `TrimOut` templates, `ShotCount IS NOT NULL`) instead of its last event of any
   operation. **Loosening:** a Trim OUT below a non-trim checkpoint is no longer rejected. Verified
   no live die cast writer puts a counter on a LOT (die cast credits go to `DieCastContribution`),
   so this is hardening rather than a regression.
2. When the LOT already carries a trim count, `@ShotCount` is **required**. The Trim OUT screen
   always sends a count, so no operator-visible change; it protects against a NULL wiping out the
   earlier shift's credit.
3. The checkpoint and its scrap rows now stamp `ShiftId` (resolved, not picked).

The existing test `0024/050` Test 3 was updated in `26671c73` for change 1: its setup checkpoint now
uses the `TrimIn` template, so it again exercises what its name claims.

## 7. Open decision -- settle before the Trim Shop report is built

**Trim OUT resolves its shift automatically and can legitimately get NULL.**
`Oee.ufn_ShiftIdForInstant` returns `ShiftId` NULL when no runtime `Oee.Shift` row covers that
business date on that equipment. The effect is asymmetric and silent: the partial files under the
shift the operator picked, while the closing credit files under no shift at all -- and that split is
the whole point of the feature. The tests cannot catch it; they assert equality against whatever the
resolver returns, NULL included.

The spec parked this at §3.3 ("Trim OUT could also force the picker"). Two ways out:

- make Trim OUT use the picker too (a UI + proc change, not in this release); or
- prove on prod that every trim-shop business date carries an `Oee.Shift` row -- the 60-second shift
  boundary ticker feeding `Oee.Shift_Reconcile` should guarantee it. Gate 4 above is that proof.

This does not block the release. It blocks trusting the numbers in a per-shift report.

## 8. Verification after execute

On a real trim LOT that takes a partial and then a Trim OUT:

```sql
SELECT pe.Id, oty.Code AS Op, pe.ShotCount, pe.ShiftId, ISNULL(ss.Name, '(none)') AS Shift, u.Initials,
       pe.ShotCount - ISNULL(LAG(pe.ShotCount) OVER (PARTITION BY pe.LotId ORDER BY pe.EventAt, pe.Id), 0) AS Credit
FROM Workorder.ProductionEvent pe
JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
JOIN Location.AppUser u         ON u.Id = pe.AppUserId
LEFT JOIN Oee.Shift s           ON s.Id = pe.ShiftId
LEFT JOIN Oee.ShiftSchedule ss  ON ss.Id = s.ShiftScheduleId
WHERE pe.LotId = <lotId> AND oty.Code IN ('TrimIn', 'TrimOut')
ORDER BY pe.EventAt, pe.Id;
```

Expect one row per checkpoint, each `Credit` the difference from the previous, and a non-NULL
`Shift` on the partial. Also confirm the audit line reads
`<LotName> · Trim · Partial <n> trimmed, <m> scrap (<shift>)`.

Screen-level: select a LOT at a trim station, confirm the button is enabled, the popup's shift
picker starts **empty** with Next disabled, the confirmation reads back the count and shift, and
after saving the LOT stays in the list with the "Already recorded: …" line under it.

## 9. Rollback

- **Ignition:** re-import the previous export of the five resources (or revert the commits and
  re-scan). The new NQs and the popup are additive; only `TrimBody` is a modified existing view.
- **Database:** the procs are `CREATE OR ALTER` -- re-apply them from the parent commit
  (`1dbf0c40`). `TrimOut_Record` v1.4 is the version to restore.
- **The migration:** dropping `FK_ProductionEvent_Shift` and the `ShiftId` column reverses the
  schema, but any partial already recorded keeps its `ProductionEvent` row and would lose its shift
  attribution. Prefer leaving the nullable column in place and reverting only the procs.

## 10. Evidence already in hand

- Full suite **3885/3885, exit 0** on a freshly built `MPP_MES_Test_Final` (all migrations + seeds).
- Per-task reviews approved Tasks 1-8; the final whole-branch review (`.superpowers/sdd/`) returned
  **ready to merge** with the §7 item as its only Important finding.
- End-to-end on `MPP_MES_Dev` through the real screens: partial 700 filed under Third Shift 09-22,
  Trim OUT 953 -> credits 700 / 253, `ShiftId` stamped on both, audit Descriptions correct.

## 11. Housekeeping before the release

- **Dev carries a smoke LOT: `TPC-SMOKE-1`** (item `12231-59B-0000`, 953 pcs, now in Trim Storage,
  two trim checkpoints). Delete it or leave it -- it is Dev only and must not be mistaken for plant
  data. It exists because the loopback terminal maps to `DC1-T1` (die cast), so the UI half of the
  smoke ran with the LOT parked at `DC1` and the Trim OUT itself was run through the proc at `TRIM1`.
- **Pre-existing bug, not from this work, do not bundle it silently:** `Lots.Lot_GetScrapSummary`
  double-counts trim scrap (`SUM(RejectEvent.Quantity) + MAX(ProductionEvent.ScrapCount)`, both
  written by the trim writers since Trim OUT v1.3). Queued as its own task.
- **Also outstanding, unrelated:** leaked `MESL`-named LOTs break full-suite runs for other suites
  (separate session, task `task_0d0df541`).
- Minor items the final review triaged as "leave": a dead `enter` branch in the popup's numpad
  handler; the "deprecated defect code" test case degrading to an unknown-id case (prod has no
  deprecated defect codes); no test coverage for a NULL `ShiftId` label; and a duplicated 7-line
  reset block in `TrimBody`.

## 12. The release still owes the five things

Preview (with fingerprint) -> rehearsal against live data inside a rolled-back transaction ->
execute guarded by `-ExpectedPlan` after a verified COPY_ONLY backup -> the scoped exports above ->
an instruction guide published as an Artifact and mirrored to `notes/`. Use
`sql/scripts/Deploy-ProdRelease.ps1` for 1-3 and rehearse locally first against a database built at
prod's exact migration state.
