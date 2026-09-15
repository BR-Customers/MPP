# Scoped Ignition exports

Deliverable 4: an archive containing **exactly** the resources the change touched, built from git, verified, and imported at the Designer in a fixed order.

> **Sibling reading.** `ignition-context-pack/11_project_exports.md` covers the archive *shape* — why `project.json` sits at the zip root, why a resource is a folder not a file, the manifest-must-match-payload rule, and the PS 5.1 one-element-array trap. This file covers *using the builder for a release*. Read that one if anything about the zip's structure is in question.

---

## Why scoped, never whole-project

The full-project builder (`build-project-exports.ps1`, repo root) ships 860 / 356 / 246 files. Importing a whole project into a live prod Gateway replaces far more than the thing you are shipping, and every unrelated resource in the archive is a chance to clobber something a person changed on the Gateway. A scoped archive carries only what a commit range touched.

---

## Building

```powershell
.\tools\Build-ChangeExport.ps1 -Since <prev-release-commit> -Label cutover-machine
```

`-Since` is the previous release's commit; `-Until` defaults to `HEAD`. The label goes in the filenames, so make it the release's short name. Output lands in `dist\ignition-exports\`:

```
Core_<label>_<date>_<time>.zip
MPP_<label>_<date>_<time>.zip
<label>_<date>_<time>_CONTENTS.txt
```

### It builds from git, not your working tree

The tree is extracted with `git archive` at `-Until` into a temp folder, and everything reads from there. This is not fussiness. The working copy under `ignition/projects` is junctioned into the live Dev Gateway, which rewrites manifests on scan, and concurrent sessions leave uncommitted edits there. `core.autocrlf=false` so the archive carries the committed bytes.

The consequence you must act on: **anything uncommitted does not ship.** Commit first, then build, then verify nothing moved after:

```bash
git diff --stat <release-commit>..HEAD -- ignition/ sql/
```

No output, or the archives are stale.

---

## What it does for you

**Maps files to resource folders.** A changed `view.json` drags its `resource.json` along, because the Gateway builds the resource from exactly the files the manifest names.

**Rewrites manifests that promise excluded files.** `thumbnail.png` is Gateway-regenerated and gitignored, so it is not shipped — which means the manifest must stop naming it. The rewrite happens **in memory**; the file on disk is untouched. Expect a line like `1 manifest(s) rewritten to drop an excluded file (thumbnail.png)`. This is deliberate and important: a manifest naming a file the archive does not contain is what produces the Designer's `NullPointerException: ... because "project" is null`, which kills the whole project, not just that resource.

**Skips manifest-only churn.** A resource whose only change in the range is its `resource.json` dropping `thumbnail.png` is dropped from the archive — the export rewrites manifests that way anyway, so shipping it would re-import an unchanged `view.json` over whatever is on the Gateway, for nothing.

**Verifies what it just wrote**, by re-opening the zip and throwing on: any backslash entry name, a missing root `project.json`, any `thumbnail.png`, any `__pycache__` or `.pyc`.

**Writes the import checklist.** `<label>_<stamp>_CONTENTS.txt` lists every shipped resource marked `NEW` / `MOD` with the commits that touched it. That is what the person at the Designer ticks off — put its contents in the runbook.

---

## What it cannot do

**Deletions.** An import adds and replaces; it never removes. The builder prints deleted paths in red:

```
DELETED in range -- an import cannot remove these; delete them in the Designer:
```

Those become a numbered step in the runbook, executed by hand. This is the single easiest step to skip.

**Non-resource changes.** Tag UDTs, Gateway settings, device connections, and anything under `data/` are not project resources and do not ride in these archives. If your release needs a tag member added or an OPC path repointed, that is a hand step in the runbook — see the 2026-09-11 runbook's arming section for a worked example of how much detail that deserves.

---

## Import order, and the rule above it

```
SQL first.
Then Core.
Then MPP.
Then MPP_Config.
```

**SQL first** because these views and named queries call procs and read columns that must already exist. A Gateway serving new views against an old schema fails silently — a blank field, no error.

**Core first** because `MPP` and `MPP_Config` both declare `"parent": "Core"` and will not resolve inherited resources without it. All named queries live in Core (siblings cannot see each other's), so a Core-only release is common and fine.

**Designer → File → Import**, one zip at a time, accepting overwrite for the listed resources. **Do not use the Gateway web page's project import** — these are partial exports, not whole projects.

**Then reload the open Perspective sessions.** F5 on each shop-floor workstation screen, not the Designer. A session left open across a project update can come back with stale bindings.

---

## Verifying before you ship

The archives are the one deliverable a reviewer cannot re-derive from the report folder, so check them:

```powershell
# entry count and names
[System.IO.Compression.ZipFile]::OpenRead((Resolve-Path .\dist\ignition-exports\Core_<label>_<stamp>.zip)).Entries | Select-Object FullName
```

Confirm against `CONTENTS.txt`, and confirm every listed resource is one your commit range actually touched. A resource you do not recognise means the range is wider than you think.
