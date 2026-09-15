# MPP production release context pack

Everything needed to author **and** execute a production release of the MPP MES — the Ignition Perspective + SQL Server 2022 system running at Madison Precision Products.

This is the standing reference for the process. It is not a runbook: a runbook describes one release, and lives in `notes/`. This pack describes how to produce one, run it, and know when to stop.

> **The premise the whole process rests on.** `MPP_MES_Prod` is a live plant running a Honda Tier 1 schedule. A release that goes wrong does not produce a failed build — it stops baskets being booked and trucks being loaded. Every rule in this pack exists because the alternative was tried and cost something.

## What's inside

| File | Topic |
|---|---|
| `01_the_release_contract.md` | The five deliverables and why each exists. The non-negotiables: preview → rehearsal → execute, fingerprint-guarded, nothing committed in between, procs not raw SQL, never commit an armed script. What is *not* a release. |
| `02_scoping_a_release.md` | Finding the previous release, splitting the range into versioned / repeatable / Ignition, working-tree hygiene (Designer pickles live data into resources), and the four tests that stop you writing "low risk" when it isn't. |
| `03_deploy_prodrelease.md` | `Deploy-ProdRelease.ps1`: three modes, password handling, what sections `[1]`–`[11]` print and what to do about each, the plan fingerprint, exit codes, the report folder. |
| `04_preflight_gates.md` | BLOCK vs WARN. The always-on structural gates. The release-specific gates in `[5]` — hand-written per migration, **including ones you may have to write** — how to write one and when to prune. The transaction's own guards: the `TABLOCKX` freeze, `DEADLOCK_PRIORITY LOW`, the die-watermark equality check. |
| `05_local_rehearsal.md` | The ProdSim pattern: a temp worktree at prod's commit + a throwaway database, so the runbook can state what the preview *should* print. What it proves and what only the prod rehearsal can. The test-suite run alongside it. |
| `06_scoped_exports.md` | `Build-ChangeExport.ps1`: built from git not the working tree, self-verifying, manifest rewriting, what it cannot ship (deletions, tags, Gateway config), and import order — SQL first, Core first. |
| `07_writing_the_runbook.md` | The anatomy of the instruction guide, distilled from seven real releases: header block, what-ships tables, verbatim expected output with "if it differs" branches, honest risk, verification ordered by risk, rollback, and the Outcome section filled in afterwards. |
| `08_the_live_window.md` | Running it: the twelve-step order, the stop conditions in a table, and rollback — before commit (automatic), after commit (restore, and why forward-fixing is usually better), disarming instead, and the Ignition half. |
| `09_one_off_remediation.md` | The smaller shape for repairing live data: `@Commit = 0` **runs and rolls back**, never skips; go through the procs; never commit an armed script. The reference script's structure, and when a "remediation" is actually a release. |

Read `01` and `02` before your first release. The rest are reference — open the one you are standing in.

## How to use it

**Authoring a release, in order:** `02` (scope and risk) → `05` (local rehearsal) → `06` (build the exports) → `07` (write the guide).

**Running one:** `08` for the order and the stop conditions, `03` for what the output means, `04` when a gate fires.

**Repairing a row:** `09`, and nothing else in this pack.

### For an agent session

Point the agent at this folder and let it fetch on demand — the same pattern `CLAUDE.md` uses for `ignition-context-pack/`. Name the relevant file in the prompt rather than hoping it infers:

- *"Scope the release since `<commit>`"* — "follow `02_scoping_a_release.md`, including the four risk tests. Do not write 'low risk' without running them."
- *"Write the runbook"* — "follow the anatomy in `07_writing_the_runbook.md`. Expected output must be verbatim from the local rehearsal, with an 'if it differs' branch for each section."
- *"Add a gate for migration `00NN`"* — "follow `04_preflight_gates.md`. The gate answers a question only live plant data can answer, and its detail string says what to do about it."

## Related reading in this repo

| Source | What it holds |
|---|---|
| `CLAUDE.md` § Production deployments | The contract in brief. Authoritative; this pack expands it. |
| `ignition-context-pack/11_project_exports.md` | The export **archive shape** — why a resource is a folder, the manifest-must-match-payload rule, the PS 5.1 array trap. `06` here covers using the builder; that file covers the zip. |
| `notes/*prod-release-runbook*.md` | Every past release, including what actually happened. Read the two most recent before authoring one. |
| `sql_version_control_guide.md` | How changes flow through environments: migrations, `SchemaVersion`, the dev iteration loop. |
| `sql_best_practices_mes.md` | What the SQL itself must look like, including the audit Description convention. |

## Out of scope

- Writing the code being released — see `CLAUDE.md` and `ignition-context-pack/`
- Dev environment setup, seeding, and the test suite's internals — see `sql_version_control_guide.md`
- Gateway installation, module licensing, device/OPC configuration
- PLC commissioning — see `notes/2026-07-14_plc-commissioning-runbook.md`

## Keeping it current

The scripts are the authority; this pack describes them. When `Deploy-ProdRelease.ps1` or `Build-ChangeExport.ps1` changes behaviour, update the matching file in the same commit — a stale process document is worse than none, because it is trusted.

When a release teaches something the hard way, write it in here as well as in that release's Outcome section. The retyped-fingerprint abort, the pickled `session-props`, and the stale-session reload all arrived that way.
