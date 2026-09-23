# Handoff -- Die cast shift reconciliation (2026-09-23)

**For the next agent.** Design and plan are done and committed. Nothing is built yet.
Start at Task 1 of the plan and work down. This note is the orientation; the plan is the work.

## Read these, in order

| | |
|---|---|
| Spec | `docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md` -- **read §14 (amendments) first**; where it disagrees with earlier sections, §14 wins |
| Plan | `docs/superpowers/plans/2026-09-22-diecast-shift-reconciliation-sql.md` -- 16 tasks, 90 steps, full SQL in every step |
| Mockup | `mockup/diecast_shift_reconciliation_mock.html` (published: https://claude.ai/artifact/QM5eCcAYPWwT8Gn4bVMek4) -- the screen, clickable, on real prod data. Plan 2 builds this; read it for intent |
| Evidence | `sql/scratch/2026-09-21_diecast_on_record_window.sql` + `Run-DieCastOnRecord.ps1` (read-only, safe on prod) |
| Origin | `notes/2026-09-17_shift-reconciliation-backfill-trim-followup.md` |

Commits so far: `738a1b9b` spec, `de724f1c` mockup, `909eb242` asset-number wording,
`836dea20` Actual-not-Sheet wording, `ee2162ce` LTT entry + evidence correction,
`4c903d2f` review items settled, `74c38d9b` the plan.

## What this is, in one paragraph

Building 2's 3rd shift on 09-16 could not enter LOTs; the paperwork was complete and the MES
had no way to take a past shift. A week of prod records held against the press sheets showed
three failures, not one: a shift missing entirely, a shift **filed against the wrong shift**,
and numbers that disagree while the entry exists. A team lead reconciles one past
`(Shift, Press, Die)` against its press sheet and fixes all three.

## The five rules that drive every decision

1. **The production record is always written and must be right. The LOT count follows trim.**
   An Open LOT is credited; a released LOT nothing downstream has counted is credited *and*
   corrected; a LOT trim has already counted keeps its count and still gets its production
   recorded. Jacques: *"If trim has already done their accounting, our entry needs to be
   accurate for shot count, more so than parts in that lot."* Firm lock, no override on this
   screen.
2. **Corrections are compensating rows, never edits.** A reduction is a negative contribution
   carrying a `ReconciliationId`; the CHECK lets only a reconciliation write one.
3. **The reading is declared by an anchor** written at save. It floors both watermarks and
   handles up and down with one mechanism. Reconciliation credits carry no reading.
4. **LTT = the ticket number, LOT = the record.** Never "tag", never "basket" in new text. A die
   is its name, then `Asset # <Tools.Tool.Code>`. The typed column is **Actual**, never "Sheet".
5. **Team leads succeed by default.** Every critical decision is named on screen and confirmed
   before it is written; only reductions need an extra tick. Blocking checks are the sheet's own
   arithmetic, so a failure is always a typo.

## Before you touch code

- **Migration number:** the plan says `0097`. `0096` (trim partial) was committed by another
  session on 2026-09-22. Re-check `sql/migrations/versioned/` and rename throughout if taken.
- **Shared working tree.** Other sessions commit here. Stage explicit paths; never `git add -u`
  or `-A`. Branch is `jacques/working`. No `Co-Authored-By` trailer.
- **Tests:** `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "<filter>"`.
  The runner **resets its target database** -- never point it at `MPP_MES_Dev`, and not at the
  shared `MPP_MES_Test` either. Exit 1 with 0 failures means a file's sqlcmd errored.
- **Task 3 records a full-suite baseline before any live proc is touched.** Do not skip it: it
  is the only way to tell a refactor regression from a pre-existing failure. (PROJECT_STATUS
  2026-09-17 notes four `0022` die-cast files that error in fixture setup on a fresh test DB --
  check whether they still do.)

## The risky half, and why it is shaped that way

Tasks 4-9 lift five write blocks out of four **live** procs into workers that return no result
set and own no transaction (the `Oee.ShiftOverride_Restamp` pattern), plus one new restamp
worker. The live procs keep every validation and call the workers; the new Save has its own
validations and calls the same workers inside one transaction.

This exists because a status-row proc cannot `EXEC` another (the INSERT-EXEC rule), and Jacques
asked for one Save that lands completely or not at all. Two of the live guards -- *the die must
be mounted now* and *a reading may not go behind the watermark* -- are exactly what a past shift
cannot satisfy, which is why they stay in the live wrappers.

**Behaviour must not change.** Each of those tasks ends by re-running the die cast suites against
the Task 3 baseline. If one drifts, stop there rather than pressing on.

## Two things the plan discovered that are easy to undo by accident

- **Backfilled rows are stamped one second before the shift's end**, not at it. Shift windows are
  `[start, end)`; a row stamped at the end resolves into the *next* shift.
- **`Oee.ShiftOverride_Restamp` must skip rows a reconciliation wrote or moved.** It re-derives a
  row's shift from `EventAt`, and a re-filed entry keeps its real `EventAt` (09-17 09:35 for the
  night shift). Without the exclusion, the next override on that press silently undoes the team
  lead's decision. Task 9 adds it and proves it in the existing `0062` test.

## Done means

- The new `0097_DieCast_Reconciliation` suite green, and the full suite at the Task 3 baseline.
- Applied to `MPP_MES_Dev` (apply, never reset -- it is Jacques's working database), and a live
  open/release on the die cast screen still works.
- **Task 15 is the real acceptance test:** replay the 09-17 Machine 11 press sheet on a ProdSim
  copy of prod and confirm the record comes out as the paper says -- 11,436 to the night shift,
  12,960 to 1st, 8,532 to 2nd, LOTs 10628131-134 at 2,868 each, the eight already through trim
  unchanged, die life up 1,127. A mismatch there is the design being wrong, not the test.

## After this plan

Plan 2 -- the Ignition screen at `/shop-floor/die-cast/reconcile`, its Core named queries and
entity script, the AD sign-in that opens it, and the "Shifts not reconciled" dashboard tile.
Scope is listed at the end of the SQL plan. Then the full release contract
(`prod-release-context-pack/`): preview, rehearsal, fingerprint-guarded execute, scoped exports
from git, published runbook.

Trim needs the same capability later; the header / reason / move / confirmation shape was
designed to be copied (`notes/2026-09-17_shift-reconciliation-backfill-trim-followup.md`).

## Open, not decided

- Machine 202 has recorded **no shift-end number all week** -- every LOT released with a count
  and no reading. Jacques: operator failure, not something to build around; the dashboard tile
  surfaces it. Known consequence recorded in spec §9: when a shift-end number is finally entered,
  the breakdown proposes the whole shift again, because the proposal reads a watermark those
  reading-less releases never moved.
- `Tools.ToolCavity.ItemId` becoming NOT NULL, and `RejectEvent.ItemId` after it (0084 §11).
