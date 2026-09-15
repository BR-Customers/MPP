# Scoping a release

Deciding what ships, and being honest about what it does. This is the half of the job the tooling cannot do for you.

---

## 1. Find the previous release

Releases are identified by the commit the archives were built from, and every runbook records both its own and its predecessor's. The most recent file in `notes/` matching `*prod-release-runbook*` is your baseline:

```bash
ls notes/*prod-release-runbook* | tail -3
```

Open the newest one and read its header block. It names **Release commit** (what prod now has) and **Rehearsed against** (the migration state prod is at). That commit is your `<prev>`.

Do not trust this blindly. Confirm it against prod in the preview: `[3]` prints how many migrations are applied and the highest. If that disagrees with the last runbook, something was deployed outside the process, or the runbook's Outcome section was never filled in. **Reconcile before you continue.**

---

## 2. What changed

```bash
git diff --stat <prev>..HEAD -- ignition/ sql/
git log --oneline <prev>..HEAD
```

Split the result into three piles:

| Pile | Path | Ships how |
|---|---|---|
| **Versioned migrations** | `sql/migrations/versioned/NNNN_*.sql` | Run once, in order, recorded in `dbo.SchemaVersion`. |
| **Repeatables** | `sql/migrations/repeatable/R__*.sql` | `CREATE OR ALTER`. Applied only when the target's text differs. |
| **Ignition resources** | `ignition/projects/<Project>/...` | Scoped export zips, imported at the Designer. |

Everything else — `docs/`, `notes/`, `sql/tests/`, `reference/` — ships nothing. Say so explicitly in the runbook so nobody goes looking for it.

> **The deploy script decides repeatables by comparing text on the target, not by reading commit history.** A proc you did not touch can still appear as `CHANGED` if prod's copy was hand-patched, or if an earlier release never went out. That is information, not an error — but it means the release is bigger than your commit range says, and you must read the per-object diffs before continuing.

### Migrations must be contiguous

A pending migration numbered **below** the applied high-water mark is a `BLOCK`. This happens when two branches both claim a number, or when a migration is authored while an earlier one is still undeployed. Fix the numbering in the repo, do not argue with the gate.

### Deletions cannot ride along

An import adds and replaces; it never removes. If the range deleted an Ignition resource, `Build-ChangeExport.ps1` prints it in red and the person at the Designer must delete it by hand. Put that in the runbook as its own numbered step — it is the step most likely to be skipped.

---

## 3. Working-tree hygiene, before you build anything

**Designer saves pickle live data into resources.** On 2026-09-13 an uncommitted `session-props/props.json` in the working tree carried real Dev session values a Designer save had baked in — `itemId 10199`, `lineLocationId 172`, a populated `cavityOptions`. Shipping it would have made every prod session boot with a phantom cutover session pointing at Dev ids. It was caught because the archives are built from git and someone read the diff.

Before scoping, look at what is uncommitted:

```bash
git status --porcelain -- ignition/ sql/
git diff --stat -- ignition/
```

The shared Dev Gateway and Dev database are used by other worktrees and other people. Uncommitted changes under `ignition/projects` may not be yours. Inspect before assuming.

---

## 4. Assess the risk honestly

This is the section most likely to be wrong, because "additive, low risk" is the comfortable thing to write. Run these four tests before you write that sentence.

### Test 1 — Does anything now *refuse* what it used to allow?

This is the class that generates day-one phone calls. A proc that gains a validation is additive in the schema sense and a behaviour regression in the plant sense.

Worked example (die mount, 2026-09-14): `Tools.ToolAssignment_Release` began refusing while the die holds an open basket. The Config Tool's `CellMountCard` calls the same proc and inherited the refusal — deliberately. But **in a live plant, open baskets are the normal state**, so a supervisor who could previously release a mount at any time now often cannot. Not a defect; the point of the change. Absolutely something the guide must say in plain language, with the way out (Release a basket with pieces, or Void an empty one — neither needs elevation).

If your release contains a new `RAISERROR` / rejection path in an existing proc, write a pre-flight query that counts how many rows are in the newly-refused state **right now**, and put the number in the runbook.

### Test 2 — Is any of it shared code?

`BlueRidge.Common.*` and anything under `Common/` has a blast radius wider than the feature. The 2026-09-14 replay fix touched `Common.Session`, which every elevated action routes through — `DowntimeReason`, `DowntimeEdit`, `DowntimeVoid`, `SortCageMigrate`, `CrtToggle`. A repair is still a change. **Post-deploy verification must prove one surface that is not the feature still works.**

### Test 3 — Is the schema change really metadata-only?

A nullable column added to an unpartitioned header table is a metadata operation: no rebuild, no lock beyond the transaction's own. A `NOT NULL` column, a backfill, a new index on a large table, or a dropped column is not. Say which you have, and why.

Dropped columns get their own automatic gate: the preview scans every surviving module for references to the dropped name and BLOCKs if one would break. Trust it, but note that after a drop commits, **rollback means restoring from the backup**, not re-running something.

### Test 4 — Does the old Ignition keep working against the new SQL?

If yes, the SQL step and the import step are independent and there is no rush between them. Say so — it materially changes how the window feels. If no, the two steps are one atomic operation from the plant's point of view and the window must be quiet.

---

## 5. What the runbook needs from this stage

By the end of scoping you should be able to state, in one table each:

- the migrations, by number and one-line effect
- the repeatables, marked `NEW` / `CHANGED`
- the Ignition resources, by project, marked `NEW` / `MOD`, plus anything deleted
- the expected preview counts (from the local rehearsal — see `05_local_rehearsal.md`)
- the risk, in the terms of the four tests above
- what is in the range but ships nothing

Carry that straight into `07_writing_the_runbook.md`.
