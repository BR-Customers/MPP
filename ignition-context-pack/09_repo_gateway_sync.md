# Repo ↔ Gateway sync for file-based projects

How a version-controlled Ignition 8.3 file-based project gets from the git repo into the running Gateway, and the daily edit loop. This is a *workflow* topic — it complements `01_project_layout.md` (what the files are) with *where they live relative to the Gateway and how changes propagate*.

## The model: repo is the source of truth; the Gateway junctions into it

- **Source of truth** = the git repo's `ignition/projects/<ProjectName>/` tree. You edit there and commit there.
- The Gateway runs file-based projects out of its own project store: `<install>/data/projects/<ProjectName>/`.
- The two are linked: each Gateway project folder is a **directory junction** (Windows) / **symlink** (Unix) pointing at the repo working copy. The Gateway reads project files *through* the link — there is no copy step and no second copy to drift.
- After writing files you tell the Gateway to re-read them with a **project scan** (an HTTP POST), not a restart.

```
repo:     ...\<repo>\ignition\projects\<ProjectName>\     <- edit + git here (source of truth)
                          ^
                          |  directory junction  (mklink /J)
gateway:  <install>\data\projects\<ProjectName>           <- Gateway reads here, through the link
```

**What you commit is what the Gateway runs.** No export/import, no "which copy is canonical."

## Why junctions instead of copying

- One source of truth. `git pull` and agent/tool file-writes land exactly where the Gateway reads.
- Version control captures precisely what runs.
- No write-permission dance: the Gateway's `data/projects/` is usually under a protected, service-owned path (e.g. `C:\Program Files\...`, owned by SYSTEM). A copy-in needs elevation *every time*; a junction needs elevation *once*, after which all edits happen in the user-writable repo.
- Generated/runtime files (`thumbnail.png` per view, `views/**/data.bin`) are gitignored and the Gateway regenerates them; they live under the junction target but stay untracked.

## One-time setup per project (requires elevation)

Because `data/projects/` is typically SYSTEM-owned, creating the junction needs an **Administrator** shell (a non-elevated process — including most agent tools — gets `Access is denied` and cannot even create or rename entries there).

Windows (Admin PowerShell / cmd):
```
mklink /J "<install>\data\projects\<ProjectName>" "<repo>\ignition\projects\<ProjectName>"
```
Unix:
```
ln -s "<repo>/ignition/projects/<ProjectName>" "<install>/data/projects/<ProjectName>"
```
Confirm it's a link, not a real folder:
```powershell
Get-Item "<install>\data\projects\<ProjectName>" -Force | Select-Object LinkType, Target
# LinkType = Junction, Target = the repo path
```

### Gotcha: a project created fresh in Designer is a REAL folder, not a junction

When you create a new project from the Designer/Gateway UI, the Gateway writes a **real** folder into its project store (SYSTEM-owned) — it is *not* linked to the repo. Symptom: you edit the repo + scan, and nothing changes in Designer, because the Gateway is reading its own real copy.

To bring such a project under the repo + sync loop (one-time, elevated):
1. Pull/copy the project's current contents into `ignition/projects/<ProjectName>/` in the repo and commit (the repo becomes the authoritative copy).
2. From an elevated shell, move the real Gateway folder aside (back it up — don't just delete) and replace it with a junction to the repo copy:
   ```
   move  "<install>\data\projects\<ProjectName>"  "<install>\data\projects\<ProjectName>.realbak"
   mklink /J "<install>\data\projects\<ProjectName>" "<repo>\ignition\projects\<ProjectName>"
   ```
3. Scan (below).

A reusable, idempotent helper that does exactly this (elevation check, backs up real folders to `<name>.realbak-<timestamp>`, skips already-linked folders) is **`link-projects.ps1`** at the repo root. Run it once from an Admin shell, then `scan.ps1` from a normal shell. If the Gateway has the folder locked, disable that project in the Gateway web UI (or stop the Ignition service), re-run, then re-enable.

### Inheritance + shared/parent projects

Junction the **parent** project too. A common layout is a shared `Core` project (`project.json` → `inheritable: true`, `parent: ""`) holding the script library, named queries, and styles, with feature projects setting `parent: "<Core>"`. The child sees the parent's resources only if the parent is also present (linked) in the Gateway store. Link parent and children the same way.

## Daily loop — write files, then scan

After any file write into a linked project (new view, named query, script, stylesheet, timer, etc.):

`scan.ps1` (repo root) POSTs the Gateway's project-scan endpoint:
```
POST http://<host>:8088/data/api/v1/scan/projects
Headers:  X-Ignition-API-Token: <token>     (REQUIRED)
          Content-Type: application/json     (REQUIRED on POST — omitting it returns 403 on 8.3.5)
Body:     {}
```
- **Token:** a Gateway API key (Config → Security → API Keys) scoped for `POST /data/api/v1/scan/projects`, stored **outside** the repo (e.g. `%USERPROFILE%\Documents\git-sync-api-key.txt`) and gitignored. `scan.ps1` auto-resolves that path so the same checked-in script works for every developer.
- The scan makes the Gateway re-read changed resources from disk; an open Designer picks most of them up **without a restart**.
- **Restart-only exceptions:** custom icon-library sprite *content* (see `08_custom_icon_libraries.md`) and some gateway-scoped config do not hot-reload on scan — restart the Gateway service.
- **Open-view caution:** file-editing a view that Designer currently has open invites a Files-vs-Gateway reconciliation conflict. Prefer file-authoring for **new** views, named queries, scripts, and stylesheets; edit **existing** views in Designer (see `07_conventions_and_antipatterns.md` and project-specific conventions).

## Deploy box — a different mechanism (git reset, not edit-in-place)

A production/deploy Gateway should **not** junction to a developer's working tree. The deploy pattern is a scheduled `pull.ps1` running *on the deploy box*: `git fetch` + `git reset --hard origin/<branch>` against a repo checkout the deploy Gateway reads from, then POST the same scan endpoint **only if `HEAD` moved**. That script carries machine-specific paths/branch and is independent of the local loop — locally you only ever run `scan.ps1`.

## Quick reference

| Action | Command |
|---|---|
| Link one project (Admin, one-time) | `mklink /J "<install>\data\projects\<P>" "<repo>\ignition\projects\<P>"` |
| Link all project folders (Admin, idempotent + backups) | `.\link-projects.ps1` |
| Register file changes with the Gateway | `.\scan.ps1` |
| Confirm a Gateway folder is linked | `Get-Item "<install>\data\projects\<P>" -Force \| Select LinkType, Target` |

## Failure modes

| Symptom | Cause / fix |
|---|---|
| Repo edits don't appear in Designer after a scan | That project folder is a REAL Gateway folder, not a junction. Convert it (one-time elevated step). |
| `Access is denied` creating/copying/renaming in `data/projects` | Not elevated, or the folder is SYSTEM-owned. Use an Admin shell and **junction** (don't copy) so future edits need no elevation. |
| Scan returns **403** | Missing `Content-Type: application/json` on the POST, or the API key lacks the scan scope. |
| Scan returns **401** | Bad/missing `X-Ignition-API-Token`. |
| Custom icon sprite change not visible after scan | Sprite content needs a Gateway service restart (scan doesn't reload it) — see `08_custom_icon_libraries.md`. |
| New view shows as a blank/error after scan | Malformed `view.json` (trailing comma, UTF-8 BOM) — fix the file, scan, reopen the view. |
