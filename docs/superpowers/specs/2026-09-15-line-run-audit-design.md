# Line run audit — design

**Date:** 2026-09-15
**Status:** approved (Jacques, 2026-09-15)
**Trigger:** 2026-09-15, line `MA2-6MACH` (6MA Cam Holder Line 1) in Prod. Component
stock ran short during the day. Trays would not submit. Operators — second shift in
particular, who had not been trained on the screen — either did not see the failure or
carried on past it. Nothing escalated, so nobody knew until afterwards.

## What actually went wrong

`Workorder.Assembly_CompleteTray` behaved correctly. It has a component-shortage guard
(§7 advisory FIFO sum, plus an in-transaction *drained mid-consume* `RAISERROR`), it
refused the tray, and it wrote an `Audit.FailureLog` row each time. The defect is not in
the proc — it is that **a refusal is only ever shown as a dismissible toast and is never
escalated to anyone**.

The consequence is worse than a shortage. A refused tray means parts were physically
built and boxed while MES recorded nothing:

- no finished-good LOT, so the production is unrecorded;
- no `ConsumptionEvent`, so component stock in MES is now **overstated** by everything
  those trays would have consumed;
- no container / tray row, so physical boxes exist with no MES counterpart.

The audit therefore has to do two jobs: say what happened, and **quantify what is
missing**.

## Scope decision — inventory is a line-level pool

Component stock is held at the **line**, not at a station. Every terminal on
`MA2-6MACH` (`-MIN`, `-AOUT1`, `-AOUT2`, `-AOUT3`) draws from the same pool, so no
terminal can be short on its own and a per-station stock figure would be meaningless.

- **Part 4 (inventory) resolves stock at the line only.**
- **Station/terminal appears only in Part 3, as attribution** — who was clicking, where,
  and when.
- The failure-scoping rule **rolls every location key up to its owning Line** rather
  than matching a subtree, which is the honest expression of the same rule.

## Scoping mechanics (the two non-obvious bits)

**`Audit.FailureLog` carries no `LocationId`.** Scoping a failure to a line has to go
through `JSON_VALUE(AttemptedParameters, …)`. Every proc's `@Params` carries
`TerminalLocationId`; most also carry one of `CellLocationId`, `LineLocationId`,
`DestinationCellLocationId`, `SourceLocationId`, `CurrentLocationId`, `ToLocationId`,
`ProducedAtLocationId`. The rule: a failure belongs to the line if **any** location key
in its JSON resolves into the line's subtree, with a `LotId → Lot.CurrentLocationId`
fallback for procs that pass no location at all.

Note that `Assembly_CompleteTray`'s parameter is named `@CellLocationId` but in the
line-resident model it *is* the line id. The naming is historic; the value is the line.

**The shortage reason string already carries the numbers.** The message is
`Insufficient component stock at the line -- short: <PART> (need N, have M); …`, so the
exact per-component shortfall per attempt is parseable out of `FailureReason` — no
inference needed.

## Deliverables

| File | Role |
|---|---|
| `sql/scratch/2026-09-15_line_run_audit.sql` | Read-only, sectioned, `@LineCode` / `@Hours` parameterised. No writes, no transaction. |
| `sql/scripts/Invoke-LineRunAudit.ps1` | Runs it against a target DB and saves the output to `notes/` as incident evidence. Modelled on `Invoke-LabelReadiness.ps1`. |

The wrapper adds one safety check over its model: it **refuses to run** if the `.sql`
contains a write verb outside comments. It points at production; the guard is cheap.

Output lands in `notes/<date>_line-run-audit-<line>_<HHmm>.txt` — committed, because
this is evidence of a real incident, not a throwaway readiness check. The time suffix is
deliberate: the line is re-audited during an incident, and a run must never overwrite the
evidence from an hour earlier.

The `.sql` keeps its own `DECLARE` defaults so it stays runnable standalone in SSMS; the
wrapper rewrites those two lines in a temp copy rather than switching the file to
`sqlcmd -v` variables, which SSMS ignores unless SQLCMD mode is on. It fails loudly if
either substitution does not match exactly once — silently auditing the wrong line or the
wrong window is worse than not running.

## Section plan

Every section ends in a plain-English `Verdict` column, matching
`2026-09-11_6ma_parallel_run_check.sql`.

| Part | Sections |
|---|---|
| **0. Context** | Params + window in UTC *and* ET; line subtree; DB migration level; shifts overlapping the window; operators active at the line |
| **1. What got recorded** | LOTs created; movements in/out; operation checkpoints; trays closed + FG LOTs minted; containers opened/completed; rejects |
| **2. Part consumption** | The `ConsumptionEvent` ledger; roll-up per component; cross-check against `LotGenealogy` `RelationshipTypeId = 3` edges — a mismatch means a half-written consume |
| **3. Failures** *(headline)* | Every scoped failure chronologically in ET; by reason family; **by hour × family** (the shift pattern); by operator × station; attempt-burst / abandonment estimate; and whether it is still failing right now |
| **4. Inventory gap** | Per-component shortfall parsed from the reason strings; worst shortfall per component; current line stock vs one tray's need; per-part flow reconciliation; `PieceCount` ≠ `InventoryAvailable` divergence; stranded open LOTs |
| **5. Could it have worked** | Per FG the line runs: BOM published, BOM children eligible at the line, container config present. A red row here means the shortage was a *config* failure, not a stock failure |
| **6. Verdict roll-up** | Trays recorded vs attempts failed, estimated unrecorded parts, worst component / hour / station / operator, still-failing flag |

## The one inference, and how it is labelled

§3.5 estimates unrecorded production from failed attempts. It clusters consecutive
failures at the same station for the same part into **bursts** (a gap over
`@BurstGapMinutes` starts a new burst), counts one intended tray per burst, and reports
bursts that were never followed by a success.

This is an **estimate, not a count**, and it is wrong if an operator retried
successfully at a different station. The section is labelled as an estimate in its
header and its assumption is stated in the column names. It must not be read as a
Honda-grade production figure.

## Explicitly out of scope

**Fixing the escalation hole.** Nothing in MES escalates a repeated failure to a
supervisor, and this script does not change that — it only measures the damage. The fix
is a separate piece of work. A toast is the wrong instrument for it: it is dismissible
and has a TTL. The shapes that work are a blocking acknowledgement the operator cannot
walk past, or a line-stop. Jacques's own note is that the eventual full migration turns
on AIM shipping labels, which forces a response by making the box unshippable — but that
is a cutover-time answer, not one available during the parallel run.
