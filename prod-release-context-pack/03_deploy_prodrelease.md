# `Deploy-ProdRelease.ps1`

The tool that implements deliverables 1–3. One script, three modes, `sql/scripts/Deploy-ProdRelease.ps1`.

It brings a live database up to the current checkout in **one transaction**, after a read-only preview. It applies versioned migrations not yet recorded in `dbo.SchemaVersion`, and **only** the repeatables whose definition on the target differs from the checkout. No seeds. Nothing else. It does not touch Ignition.

---

## The three modes

| Mode | What it does | Writes anything? |
|---|---|---|
| `Preview` (default) | Works out exactly what would change, runs every pre-flight gate against live data, writes a report and the deploy script it *would* run, prints a plan fingerprint. | No. |
| `Rehearse` | Runs the real deploy script inside a transaction against live data, verifies it, then `ROLLBACK`. Takes the same locks as Execute for the same few seconds. | No — but it holds plant locks briefly. |
| `Execute` | `COPY_ONLY` backup + `VERIFYONLY`, then the deploy script, committed only if every step and check passes. | Yes. |

```bash
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fp>
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute  -ExpectedPlan <fp>
```

### The password never goes on a command line

Either let the script prompt (masked, when `-Username` is given), or set it first:

```powershell
$env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
```

`sqlcmd` reads `SQLCMDPASSWORD` itself, so it never prompts into a captured stream — that hang is why `Update-Prod.ps1` was replaced. The script restores whatever the variable held when it exits.

---

## Reading the output, section by section

### `[1] Checkout`
Prints branch and short `HEAD`. **BLOCKs** if `sql/migrations` has uncommitted changes — only committed code deploys.

### `[2] Connection`
Login, server, version, edition, `sysadmin` flag; then the database's state and recovery model. Throws if the database does not exist or has no `dbo.SchemaVersion`.

### `[3] Versioned migrations`
How many are applied, the highest, the five most recent, then the pending list.

- pending below the high-water mark → **BLOCK** (out of order)
- recorded in the database but absent from the checkout → **WARN** (orphan)
- a pending migration containing `BEGIN TRAN` / `COMMIT` / `ROLLBACK` / `ALTER DATABASE` / `BACKUP` / `RECONFIGURE` → **BLOCK**, it cannot run inside the release transaction

### `[4] Repeatables — target definitions vs this checkout`
Prints `N identical, N changed, N new on the target` and lists the non-identical ones. For every `CHANGED` object it writes three files into the report's `diffs/` folder: `.target.sql`, `.repo.sql`, and a `.diff`. **Read them whenever the count is larger than you expected.**

Also here: objects on the target with no file in the checkout (**WARN**, left untouched), and the dropped-column scan — any surviving module still naming a column this release drops is a **BLOCK**.

Ordering is by tier: functions, then views, then procs, then triggers.

### `[5] Pre-flight gates`
Release-specific checks against live data. See `04_preflight_gates.md` — these are hand-written per migration, and are the part you may have to add to.

### `[6] Live activity`
Open transactions on the target. A long-running one is a **WARN**: it will block the deploy's locks.

### `[7] Backups`
Recent backup history and the instance's default backup path.

### `[8] Plan`
The fingerprint, and the plan it covers:

```
HEAD|<short sha>
M|<migration file>|<sha256 of its normalised text>
R|<repeatable file>|<sha256 of its normalised text>
```

SHA-256 of those lines, first 12 hex characters. Also writes `plan.txt` and `deploy.sql` — the exact script that would run. **Read `deploy.sql` at least once**, so the transaction is not a black box.

### Verdict
- any **BLOCK** → prints them, writes nothing, `exit 2`
- nothing pending and nothing changed → `already matches this checkout. Nothing to do.`, `exit 0`
- otherwise → `Clear to deploy. N warning(s) to read above.` and the two next commands

### `[9] Backup` (Execute only)
`BACKUP DATABASE ... WITH COPY_ONLY, CHECKSUM, INIT, COMPRESSION` then `RESTORE VERIFYONLY ... WITH CHECKSUM`. Path is written to `backup.txt` in the report folder. **Note it in the runbook's Outcome.** `COPY_ONLY` means the regular backup chain is undisturbed.

### `[10] Running the release transaction`
Streams the `==` step markers, timing, and exit code; the full log goes to `deploy.log`. On a non-zero exit: `FAILED -- the transaction was rolled back; <db> is unchanged.`

Rehearse ends here with `REHEARSAL PASSED and was rolled back. Lock window: N.Ns.`

### `[11] After commit` (Execute only)
`R__Descriptions_ExtendedProperties.sql` runs **after** the commit, outside the transaction, so it never holds locks on every table. A failure there is a **WARN** — it is documentation only and the release stands.

Then two proofs: every repo migration is recorded, and every applied repeatable now matches the repo byte-for-byte. Both should be green. A drift WARN here means something re-created an object between the commit and the check.

Ends with: `Import the Ignition exports NOW -- Core first.`

---

## The fingerprint

It covers `HEAD` **and** the target's own state, because the plan is a function of both. Consequences:

- Prod's fingerprint will differ from your local rehearsal's. Use the one **your** preview printed.
- Any commit between preview and Execute changes it. That is the guard working.
- A different target changes it. Pointing at the wrong database cannot be papered over.

```
ABORT: plan is <a> but -ExpectedPlan is <b> -- the target or the checkout changed since the preview.
```

Re-preview, read the new plan, use the new fingerprint. Do not reach for `-Force`: it skips the typed confirmation, not the gates, and it *requires* `-ExpectedPlan` anyway.

---

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Preview clear / rehearsal passed / execute committed / nothing to do |
| 1 | Aborted at the confirmation prompt, or the transaction failed and rolled back |
| 2 | BLOCKed by a pre-flight finding — nothing written |
| 3 | `-ExpectedPlan` mismatch — nothing written |

## Confirmation prompts

Execute asks you to type the **database name**. Rehearse asks you to type `REHEARSE` (case-sensitive). Both are skipped by `-Force`, which requires `-ExpectedPlan`.

## The report folder

`dist\deploy-reports\<Db>_<Mode>_<stamp>\`:

| File | Contents |
|---|---|
| `summary.txt` | Everything printed to the console |
| `plan.txt` | The fingerprinted plan lines |
| `deploy.sql` | The exact script that would run / did run |
| `findings.csv` | Every BLOCK / WARN / INFO |
| `diffs/` | Per-object `.target.sql`, `.repo.sql`, `.diff` |
| `deploy.log` | Full `sqlcmd` output (Rehearse / Execute) |
| `backup.txt` | The `.bak` path (Execute) |

Not in git. Keep the folder name in the runbook's Outcome so the run can be found again.
