# Writing the instruction guide

Deliverable 5, and the only one a person reads while the plant is running. Everything else is a tool or a report; this is the thing that has to work at 6am for someone who did not build the change.

**Published as an Artifact** (copyable commands, expected output, what to do when it differs, verification, rollback) **and mirrored** as `notes/<date>_prod-release-runbook-<slug>.md` so it is in git with the code it describes.

---

## The standard the guide is held to

Not "a description of the change". Three specific properties:

1. **Every command is copyable and complete.** Full paths, all flags, the real server address. Someone should never have to reconstruct a command from prose.
2. **Every command is followed by the output to expect**, verbatim, from the local rehearsal — and by what it means if the output differs. A reader who cannot tell a normal run from a wrong one has no way to stop.
3. **It says what to do when something goes wrong**, before it goes wrong.

---

## Anatomy

Distilled from the runbooks in `notes/` (2026-09-10 through 2026-09-14). Sections are numbered in the file so they can be referred to over the phone.

### Header block

```markdown
# Prod release runbook — <short name>

**Release commit:** `e0cc9577` on `jacques/working` — the commit the archives were built and verified from.
**Previous release:** `515db6c6` (2026-09-13, inventory cutover scan).
**Rehearsed against:** `MPP_MES_ProdSim`, a database built at `515db6c6` — prod's exact
migration state (81 migrations, highest `0081`, `Lots.Lot.ProducedAtLocationId` absent).
```

Then the commit-drift rule, stated where it cannot be missed:

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint covers HEAD; Execute refuses if anything moved.
>
> HEAD will be this runbook, or a later docs-only commit — that is fine and expected. What matters is not which commit HEAD is, but that **no deployable moved after the archives were built**:
> ```bash
> git diff --stat e0cc9577..HEAD -- ignition/ sql/
> ```
> Expect **no output**. If anything is listed, the archives are stale — rebuild and re-preview.

### 1. What this ships

Prose first — what changes for the person using the system, not the file list. Then the tables from `02_scoping_a_release.md`: SQL objects, Ignition resources by project, what is in the range but ships nothing.

### 2. What the database change is

| | |
|---|---|
| Migrations | 1 — `0082_lot_produced_at_location` |
| Repeatables | 3 — 1 new, 2 changed |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window | 0.2s |

Then one paragraph on *why it is cheap or why it is not*: nullable column on an unpartitioned header table, metadata-only, no index, no backfill, existing rows keep `NULL` and that is correct because their machine was never captured.

**Pre-empt anything in the preview that will surprise the reader.** If `R__Descriptions_ExtendedProperties.sql` carries a +309/−54 documentation catch-up from earlier commits, say so here — otherwise it reads as scope creep at exactly the wrong moment.

### 3. Risk

Write this from the four tests in `02_scoping_a_release.md`, and be willing to write something other than "low". If a proc now refuses what it used to allow, say who will hit it, how often, and what the way out is — in the words the supervisor will use, not the proc's name.

### 4. Deploy

Three steps, each: command, expected output, what a deviation means.

```markdown
### Step 1 — Preview (read-only)

<command>

Expect, section by section:

<verbatim block from the local rehearsal>

**If it differs from the above:**

- *Pending shows more than `0082`* — prod is behind where this runbook assumes. Stop and reconcile.
- *More than 3 changed repeatables* — prod has drifted from git, or a commit landed that was never
  deployed. Per-object diffs are in the report's `diffs` folder; read them. A larger CHANGED list is
  information, not automatically an error, but it means this runbook no longer describes what you
  are about to do.
- *Any gate fires* — stop. Gates read live plant data; a BLOCK means the release is unsafe right now.
```

Then Rehearse (with its step markers and lock window, and *"if the rehearsal fails, stop — it failed against prod's actual data, which is the one thing local testing cannot simulate"*), then Execute.

### 5. Ignition imports

Restate **SQL first, Core first**, the archive names with their resource counts, and the `NEW`/`MOD` list per project from `CONTENTS.txt`. Name any project with no changed resources explicitly (`MPP_Config has no changed resources and is not part of this release`) so its absence is not read as an omission. Deletions and hand steps get their own numbered entries.

### 6. Verification

Concrete checks with the expected result, ordered by risk — **not** by the order the features were built.

Put first whatever was never proven end-to-end. The 2026-09-14 runbook is the model:

> **This is the one hop that was never verified before shipping.** Everything up to `Lot_Create` is covered by the SQL suite (3523 assertions, 0 failures) and the UI was verified live, but the browser used for testing cannot commit the LTT and piece-count text fields, so the UI→database write is inferred rather than observed. **Do this check first.**

That paragraph is worth more than the rest of the section. Naming your own coverage gap is how the reader knows which checks are ceremony and which are real.

If the release touched shared code, one check here must exercise a surface that is **not** the feature.

### 7. Rollback

Before commit, during commit, after commit, and the Ignition half. See `08_the_live_window.md`.

### 8. Outcome — filled in after

Left as `_(still to fill in)_` until the release runs, then completed with: date and time ET, prod's starting migration state, the plan fingerprint, what the preview and rehearsal actually printed, the lock window, the backup path, the report folder, and anything that went sideways.

Write the sideways parts down. The retyped-fingerprint abort is in the 2026-09-12 runbook as a blockquote, and it is why `03_deploy_prodrelease.md` now says *copy, do not retype*.

---

## Publishing

Artifact for the person running it — readable on a phone at the press. `notes/<date>_prod-release-runbook-<slug>.md` for git. Same content; the note is the record, the Artifact is the instrument.

Commit the note **before** the preview, so it is part of the release commit range rather than a change that invalidates your fingerprint later.
