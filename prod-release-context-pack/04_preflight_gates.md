# Pre-flight gates and the transaction's own guards

Two layers protect a release. The **gates** run before anything is written, read-only, against live data. The **in-transaction guards** run inside the deploy transaction and refuse to commit if an invariant moved. Both live in `Deploy-ProdRelease.ps1`.

---

## Severities

| Severity | Effect |
|---|---|
| `BLOCK` | The run stops at the verdict. Nothing is written. `exit 2`. No flag overrides it. |
| `WARN` | Printed, counted in the verdict, written to `findings.csv`. You decide. |
| `INFO` | Recorded only. |

A WARN is not decoration. `Clear to deploy. 3 warning(s) to read above.` means read them.

---

## The always-on structural gates

These fire on any release, regardless of what it contains.

| Gate | Severity | Fires when |
|---|---|---|
| `checkout` | BLOCK | `sql/migrations` has uncommitted changes |
| `migrations` (out of order) | BLOCK | a pending migration numbers below the applied high-water mark |
| `migrations` (transaction-hostile) | BLOCK | a pending migration contains `BEGIN TRAN`, `COMMIT`, `ROLLBACK`, `ALTER DATABASE`, `BACKUP`, `RECONFIGURE` |
| `migrations` (orphan) | WARN | recorded in `dbo.SchemaVersion` but absent from the checkout |
| `repeatables` (orphan) | WARN | an object exists on the target with no file in the checkout — left untouched |
| `dropped-column` | BLOCK | a module that survives the deploy still references a column this release drops |
| `activity` | WARN | a session has a transaction open on the target that will block the deploy's locks |
| `backup` | WARN | `-SkipBackup` on an Execute |

### The dropped-column gate deserves a note

It checks **every** module, taking the repo text for objects this deploy re-creates and the live definition for everything else. So it correctly allows a proc that is being updated in the same release to stop referencing the column, while still catching one that is not.

---

## Release-specific gates — these are hand-written, and they are your job

Section `[5]` is not generic. It is a block of PowerShell that knows about specific migration numbers, keyed off `$pendingIds`. Today it carries gates for `0072`–`0076`, written when those were pending:

- `0076` BLOCKs if `0072` is also pending — `0076` letters cavities using the map `0072` creates, so in one run every map is empty and family dies get die-wide letters, **permanently**
- `0076` BLOCKs on a `(die, part)` group of more than 26 cavities — there is no 27th letter
- `0076` BLOCKs on a die partially mapped, or a multi-part die with no map at all
- `0076` BLOCKs if `Lots.Lot.CavityNumber` still holds values
- `0073` WARNs on contributions inside a shift still running — the backfill sets their watermark from `PieceDelta`, so deploy at a shift change if you can
- `0075` BLOCKs if `Parts.OperationCategory 'Trim'` is missing

Read those as worked examples, because they show what a good gate is: **a query against live plant data that a dev database cannot answer.** Not "does the column exist" — the migration checks that. "Is the plant currently in a state where this migration produces a wrong answer that we can never undo."

### Writing one

Add it inside `[5]`, guarded by the migration id:

```powershell
if ($pendingIds -contains "00NN_my_migration") {
    $n = S "SELECT COUNT(*) FROM <table> WHERE <the condition that makes this unsafe>"
    if ($n -gt 0) { Finding "BLOCK" "00NN" "$n row(s) in <state> -- <what goes wrong and what to do first>" }
}
```

`Finding <severity> <gate> <detail>`; `S <sql>` returns a scalar; `Q <sql>` returns rows. The detail string is read by a person at 6am — say what is wrong **and** what to do about it, as those examples do.

Ask yourself: *does this migration produce a different, irreversible result depending on the plant's current state?* If yes, that state is a gate. If the answer is only "it might fail", the migration's own checks cover it — the transaction rolls back and nothing is lost.

### Pruning

A gate for a migration that was deployed months ago never fires again — `$pendingIds` will not contain it. It is dead weight, but it is also the record of why that migration was dangerous. **Leave gates in place for as long as any environment might still be below that migration; prune a block only once every environment is past it,** and say so in the commit message. Do not prune one because it is noisy in the source.

There is one piece of the same pattern outside `[5]`: the typed-confirmation prompt adds a red line for `0076` because it drops two columns, and `[11]` writes a cavity-letter CSV after that migration commits. When you prune, check for those too.

---

## The transaction's own guards

Everything the deploy script does is wrapped by these, and they are why a failed release leaves no partial state.

**Session settings.** `SET XACT_ABORT ON`, `DEADLOCK_PRIORITY LOW`, `LOCK_TIMEOUT <n>` (default 30 s). The plant wins a deadlock, and the deploy aborts cleanly rather than queueing the plant behind it.

**A deliberate freeze.** Immediately after `BEGIN TRANSACTION`:

```sql
SELECT TOP 0 1 FROM Lots.Lot                       WITH (TABLOCKX, HOLDLOCK);
SELECT TOP 0 1 FROM Tools.ToolCavity               WITH (TABLOCKX, HOLDLOCK);
SELECT TOP 0 1 FROM Workorder.DieCastContribution  WITH (TABLOCKX, HOLDLOCK);
```

Plant writes to the three die-cast tables wait for the seconds this takes, rather than landing between steps. If the locks cannot be taken within `LOCK_TIMEOUT`, the release aborts before changing anything. **This is why rehearsal and execute want a quiet window and why the runbook reports the lock window in seconds** — real releases have run 0.2 s to 2.9 s.

**Watermarks before and after.** Every `(ToolId, ShiftId, CellLocationId)` die-shot watermark is captured into `#DeployWm` at the start. Before commit, any that moved raises `A die watermark changed during the deploy -- refusing to commit`. Die-cast counting is the part of the system where a silent shift is most expensive and least visible.

**Per-step assertions.** After each migration: the transaction is still open (`@@TRANCOUNT <> 1` raises), and the migration recorded itself in `dbo.SchemaVersion`. After each repeatable: the transaction is still open. Before commit: `OBJECT_ID` exists for every object the release claimed to create.

**Then, and only then**, `COMMIT` — or `ROLLBACK` in Preview and Rehearse, which is what makes a rehearsal a genuine rehearsal rather than a syntax check.

---

## What the gates cannot tell you

They read the database. They do not know whether the *Ignition* half is consistent with the SQL half, whether a proc's new refusal will annoy a supervisor, or whether the part list was seeded. Those are `02_scoping_a_release.md`'s job and yours.
