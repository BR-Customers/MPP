# The release contract

What a production release is, what it always consists of, and the rules that do not bend.

> **The premise everything else follows from.** `MPP_MES_Prod` is a live plant. Madison Precision runs die cast around the clock for a Honda Tier 1 schedule. A release that goes wrong does not produce a failed build — it stops baskets being booked, stops labels printing, and stops trucks. Every rule below exists because the alternative was tried somewhere and cost something.

---

## The five deliverables

Every deployment into production ships as the same five things. Not four. A release missing any one of them is not ready, however small the change.

| # | Deliverable | What it is | What it prevents |
|---|---|---|---|
| 1 | **Preview** | Read-only. What would change, every pre-flight gate run against live data, a saved report, and a **plan fingerprint**. | Deploying something different from what you think you are deploying. |
| 2 | **Rehearsal** | The real deploy script against the real live data inside a transaction, verified, then rolled back. | "It worked on Dev." Dev has no open baskets, no running shift, no drift. |
| 3 | **Execute** | Verified `COPY_ONLY` backup first, then one transaction, guarded by `-ExpectedPlan <fingerprint>` from the preview that was actually read. | A release drifting between the decision and the act. |
| 4 | **Scoped project exports** | Only the resources the change touched, built **from git** and verified against `HEAD`. Core imports first. | Clobbering unrelated resources someone changed on the Gateway. |
| 5 | **An instruction guide** | Published as an Artifact — copyable commands, the output to expect, what to do when it differs, verification, rollback — and mirrored as `notes/<date>_prod-release-runbook-<slug>.md`. | The release living only in the head of whoever built it. |

Deliverables 1–3 are implemented by `sql/scripts/Deploy-ProdRelease.ps1` (see `03_deploy_prodrelease.md`). Deliverable 4 is `tools/Build-ChangeExport.ps1` (see `06_scoped_exports.md`). Deliverable 5 you write (see `07_writing_the_runbook.md`).

---

## The non-negotiables

**Preview, then rehearse, then execute. In that order, every time.** There is no "it's just a proc" path. The preview is cheap and read-only; skipping it saves ninety seconds and removes the only step that tells you prod is where you think it is.

**Nothing may be committed between the preview you read and the Execute.** The plan fingerprint covers `HEAD`. A commit in between — even a docs commit — changes the fingerprint and Execute refuses. This is not a bug to work around; it is the guard doing its job. Re-preview and use the new fingerprint.

**Copy the fingerprint. Do not retype it.** On 2026-09-12 an Execute was refused because one character was dropped (`7273b5da24f` for `72073b5da24f`). The guard aborted before the backup and before the transaction, so nothing was written — but it cost a window.

**Deploy only committed code.** The preview BLOCKs on a dirty `sql/migrations`. The export builder reads from `git archive`, never from the working tree. Both are deliberate: the working tree under `ignition/projects` is junctioned into the live Dev Gateway, which rewrites manifests on scan, and other sessions leave uncommitted edits there.

**SQL first, then Ignition. Core before MPP.** Views and named queries call procs and read columns that must already exist. A Gateway serving new views against an old schema fails in the worst way available — a blank field with no error.

**Go through the procs. Never a raw `UPDATE`.** Procs carry the validation and write the audit rows. A hand-written `UPDATE` against prod leaves a change nobody can explain six months later, and Honda traceability is the product.

**Never commit an armed script.** A remediation script with `@Commit = 1` lives in the working tree for the minutes it takes to run, and is reverted to `0` before it is committed. See `09_one_off_remediation.md`.

---

## What is not a release

A commit that touches only `docs/`, `notes/`, or `*.md` ships nothing. It is normal and expected for `HEAD` to be a docs commit at deploy time — what matters is not which commit `HEAD` is, but that **no deployable moved after the archives were built**:

```bash
git diff --stat <release-commit>..HEAD -- ignition/ sql/
```

Expect no output. Anything listed means the archives are stale — rebuild and re-preview.

---

## Who decides

The preview report is what the decision is made from. Whoever owns the window reads it, and Execute then refuses anything that changed after that reading. That is the whole point of the fingerprint: it turns "I reviewed this" into something the tooling can enforce rather than something everyone has to remember.

If a gate BLOCKs, the answer is not `-Force`. `-Force` skips the typed confirmation, not the gates — and it still requires `-ExpectedPlan`. There is no flag that deploys past a BLOCK, by design.

---

## Where the process is written down

| Source | What it holds |
|---|---|
| `CLAUDE.md` § Production deployments | The contract, in brief. Authoritative. |
| This pack | The contract, in full, with the judgment calls. |
| `notes/<date>_prod-release-runbook-*.md` | Every past release, including what actually happened. Read the two most recent before authoring a new one. |
| `dist/deploy-reports/` | Every preview, rehearsal and execute this machine has run. Not in git. |
