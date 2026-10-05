# Local rehearsal — the ProdSim pattern

Before you touch prod, run the whole thing against a database built at **prod's exact migration state**. This is what lets the runbook say *"expect exactly this"* instead of *"expect something like this"* — and a runbook that cannot state its expected output is not a runbook, because the reader has no way to tell a normal run from a wrong one.

---

## The recipe

**1. Build a checkout at prod's commit.** Not your working tree — prod's state.

```bash
git worktree add ../mpp-prodsim <prod-release-commit>
```

**2. Build a database from it, under a throwaway name.**

```powershell
cd ..\mpp-prodsim
.\sql\scripts\Reset-DevDatabase.ps1 -DatabaseName MPP_MES_ProdSim -Force
```

> `Reset-DevDatabase.ps1` **drops and recreates** its target and creates a weak `ignition` login with `db_owner`. It is dev-only. Never point it at prod, and never at `MPP_MES_Dev` casually — that database is shared by every worktree on this machine and holds hand-built parts and die mounts that are not reproducible from seeds.

Pick a name nobody else is using. Concurrent worktrees share one SQL instance, and a collision destroys someone's work mid-session. `MPP_MES_ProdSim`, `MPP_MES_ProdSim0077`, `MPP_MES_Test_T7` are all real examples of this discipline.

**3. Prove the baseline is actually prod's.** Two independent checks — a count and an absence:

```sql
SELECT COUNT(*) AS Applied, MAX(MigrationId) AS Highest FROM dbo.SchemaVersion;
SELECT COL_LENGTH('Lots.Lot','ProducedAtLocationId');   -- must be NULL: the column this release adds
```

The count must match what prod's preview reports in `[3]`, and the thing your release *introduces* must be absent. A ProdSim that already has your column proves nothing.

**4. Preview and rehearse against it**, with the same commands you will use on prod, pointed at `-DatabaseName MPP_MES_ProdSim` and `-ServerInstance localhost`.

**5. Confirm the rollback was clean.** Re-run the two baseline checks from step 3. `SchemaVersion` back to its original count, your column absent again. This is the step that proves `Rehearse` really is non-destructive — worth doing once so you trust it on prod.

**6. Clean up.**

```bash
git worktree remove ../mpp-prodsim
```

---

## What to carry into the runbook

Copy the preview's numbers verbatim — pending list, `N identical, N changed, N new`, gates fired, the plan line, the verdict — and the rehearsal's step markers and lock window. Then add the two caveats that are always true:

> **Prod's numbers may differ from these** if prod carries any proc the repo does not, or a hand-patched definition. The script compares text on the target, not commit history, so a larger `CHANGED` list is information, not an error — read the per-object diffs before continuing.

> **Take the plan fingerprint from YOUR preview.** ProdSim's will match prod's whenever both are at the same state under the same `HEAD` — a match is corroboration, not a problem. What it will *not* do is tell you which database you are pointed at. See `03_deploy_prodrelease.md` § The fingerprint.

---

## What ProdSim proves, and what it cannot

| Proves | Cannot prove |
|---|---|
| The migrations and repeatables apply cleanly, in order, to a database at prod's state | That they apply to **prod's actual rows** — only the prod rehearsal proves that |
| The expected preview shape, so a deviation on prod is visible | Anything a gate reads from live plant data (open baskets, running shifts, unmapped cavities) |
| The rollback is clean | Lock contention against real plant traffic |

### Three legs a rehearsal structurally cannot reach

`Rehearse` rolls back, and it rolls back *before* `[9]` and `[11]`. So it never exercises:

1. **`[9]` the `COPY_ONLY` + `CHECKSUM` backup** — the one step standing between a bad release and a lost
   plant. No rehearsal has ever taken one.
2. **`[11]` the post-commit `R__Descriptions_ExtendedProperties.sql`** — it runs *outside* the transaction by
   design, so a rolled-back run skips it entirely.
3. **Every post-commit verification query in the runbook's section 6.5** — there is nothing committed to query.

**Run a real `Execute` against a SECOND throwaway sim to cover them.** Build it the same way under a different
name (`MPP_MES_ProdSim3`), preview it, then Execute for real. It costs one database build, and it converts the
runbook's section 6.5 from *expected* values into *confirmed* ones — so a deviation on prod becomes a signal
rather than an unknown.

**Keep the first sim at prod's state.** Executing against it consumes the baseline, and the live window then
has to rebuild it from a worktree before it can rehearse. That is the whole reason this is a second database
and not the same one.

2026-10-02 is what put this here: `is_not_trusted = 0` on `0098`'s `CK_RejectEvent_QuantityNonNeg` had been
*assumed* through two rehearsals and was first actually verified this way. It is the only proof that a
`WITH CHECK` constraint validated the existing rows instead of being accepted unvalidated — which is the
entire reason that migration takes a whole-table lock.

This is exactly why the prod rehearsal is not optional even after a perfect local one. The 2026-09-12 release matched its local rehearsal precisely and still rehearsed against prod first, with 1 open basket and 1 running shift — a 2.8 s lock window it could not have measured locally.

---

## The test suite is separate, and also required

`Run-Tests.ps1` DROPs and rebuilds its target from the versioned migrations and then all repeatables, so a full green run additionally proves the release applies **to a virgin database, in order** — not merely to one that already had it.

```powershell
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_T7
```

Use a suffixed name for the same collision reason. Two things to know about the result:

- **Exit 1 with 0 failures** means a test's `sqlcmd` errored rather than asserted — usually cleanup FK order. Investigate; do not shrug at a non-zero exit.
- **Run the full suite, not just your filter.** A filtered run tears down its own fixtures, which can make an assertion vacuous — case (4) of `0067_Lot_SearchAdvanced/060_cutover_machine.sql` passed by absence under `-Filter "0067"` and only bit under the full run.

Record the count in the runbook (`3523/3523, 0 failures`). It is the evidence behind the risk assessment.
