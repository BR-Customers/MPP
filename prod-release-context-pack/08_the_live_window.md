# The live window

Running it. The order, the stop conditions, and how to get out.

---

## Order of operations

```
1.  Confirm no deployable moved      git diff --stat <release>..HEAD -- ignition/ sql/
2.  Password into a masked env var
3.  Preview                          -> read it, copy the fingerprint
4.  Rehearse                         -ExpectedPlan <fp>   -> must end REHEARSAL PASSED
5.  Execute                          -ExpectedPlan <fp>   -> must end COMMITTED; note the .bak path
6.  Import Core zip                  Designer -> File -> Import
7.  Import MPP zip
8.  Import MPP_Config zip            (if the release has one)
9.  Hand steps                       deletions, tag edits, config-tool toggles
10. Reload open Perspective sessions F5 on each shop-floor screen
11. Verify                           section 6 of the runbook
12. Fill in the Outcome section
```

Have the Designer open on the prod Gateway, logged in, with the zips to hand **before** step 3. The gap between a committed SQL release and its imports should be minutes, not a coffee break.

### Quiet window

Rehearse and Execute both take `TABLOCKX` on `Lots.Lot`, `Tools.ToolCavity` and `Workorder.DieCastContribution`. Real windows have run 0.2 s to 2.9 s, so this is not an outage — but a shift change is still a better moment than the middle of a run, and if a migration backfills from shift data (`0073` did) the runbook will say to wait for one.

Step 10 is not optional. A session left open across a project update can come back with stale bindings — the lesson from the downtime release.

---

## Stop conditions

Stop and reconcile. Do not improvise forward.

| Signal | What it means |
|---|---|
| Any **BLOCK** in the preview | The release is unsafe *right now*. Nothing was written. Read the finding — it says what to do first. |
| Preview differs from the runbook | The runbook no longer describes what you are about to do. Read the per-object diffs in the report's `diffs/` folder. |
| More `CHANGED` repeatables than expected | Prod has drifted from git, or an earlier release never went out. Information, not automatically an error — but understand it before continuing. |
| A missing migration in `[3]` | You are pointed at the wrong database, or prod is behind where the runbook assumes. |
| `ABORT: plan is <a> but -ExpectedPlan is <b>` | Something moved between preview and now. Re-preview, read the new plan, use the new fingerprint. Never `-Force` past it. |
| Rehearsal fails | It failed against **prod's actual rows** — the one thing local testing cannot simulate. Nothing was written. Stop. |
| `sqlcmd exit <n>` during Execute | The transaction rolled back; the database is unchanged. Read `deploy.log`. |

"Stop" means stop, not "try again with a flag". The only legitimate retry is after you have changed something real — the repo, the plant's state, or which database you are pointed at.

---

## Rollback

### Before COMMIT

Automatic. Any error anywhere rolls the whole release back, and `[10]` prints `FAILED -- the transaction was rolled back; <db> is unchanged.` There is no partial state and nothing to undo. A rehearsal is this path by construction.

### After COMMIT

Almost never needed, and usually the wrong instinct. Most releases are additive and inert until something is switched on.

**Prefer forward-fixing.** Work out what is wrong, fix it in the repo, and ship it through the same five steps. A restore throws away every basket, shot and reject the plant has booked since the backup — on a running line that is minutes of real production, and the data is not reconstructable.

**The full restore** is `RESTORE DATABASE` from the `COPY_ONLY` backup taken at `[9]` (path in `backup.txt` and printed to the console), followed by re-importing the **previous** Core/MPP resources. Two things to know before you reach for it:

- It is the *only* option after a release that **dropped a column** — the confirmation prompt says so in red for exactly that reason.
- The Ignition half does not roll back with the database. Reverting SQL without reverting the imports leaves new views against an old schema, which is the failure mode that shows as a blank field with no error.

### Disarming without rolling back

Usually better than either. Most releases that change plant behaviour do so behind something switchable — a terminal attribute, a tag member, a configuration row. Turning that off returns the plant to its previous behaviour in seconds and leaves the deployed code in place.

The 2026-09-11 parallel run is the worked example: the rollback section is three lines, none of which is a restore — set `InspectionComplete` back to a tag that never rises, and untick `SuppressAimAndLabel`. **When your release has such a switch, say so in the runbook's rollback section by name and location.** Write it while you are building the change, not while it is going wrong.

### The Ignition half

An import cannot be undone by an import. To revert resources, build an archive from the **previous** release commit and import that:

```powershell
.\tools\Build-ChangeExport.ps1 -Since <this-release> -Until <previous-release> -Label rollback
```

> **Reasoned from the builder's source, never exercised on a real rollback.** The reversed range is a legitimate git diff and `-Until` controls which commit the bytes come from, so this should produce the previous definitions — but no release has needed it yet. Build it and read `CONTENTS.txt` before importing, rather than discovering its behaviour during an incident.

Resources the release *added* are not removed by that — delete them by hand in the Designer, the same way deletions ship forward.

---

## After it lands

Fill in the Outcome section the same day, while the numbers are still on screen: time ET, the fingerprint, what the preview and rehearsal printed, the lock window, the backup path, the report folder, and anything that surprised you. Then update `PROJECT_STATUS.md`.

The next person's runbook starts by reading yours. Its **Release commit** becomes their **Previous release**, and their whole scoping step depends on your Outcome section being true.
