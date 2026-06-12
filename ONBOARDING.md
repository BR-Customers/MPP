# MPP MES — New Developer Onboarding

How to get a fresh Windows laptop set up to develop on the MPP MES project: clone from
GitHub, work on your own branch, run the SQL dev database, and edit the Ignition
Perspective projects through the live Gateway — the same setup the rest of the team uses.

> **Audience:** a developer joining the project who needs a full local dev environment
> (SQL + Ignition + repo). Work top to bottom the first time. After setup, the
> **[Daily workflow](#9-daily-workflow)** section is the part you'll come back to.

---

## 0. The shape of the setup (read this first)

Three things run on your machine and the repo ties them together:

| Piece | What it is | Source of truth |
|---|---|---|
| **Git repo** | `…\Dev\MPP` working copy cloned from GitHub | GitHub (`origin`) |
| **SQL Server 2022** | `MPP_MES_Dev` database, rebuilt from `/sql` migrations | The `/sql` folder in the repo |
| **Ignition Gateway 8.3** | Runs the Perspective projects (`Core`, `MPP`, `MPP_Config`) | The `ignition/projects/` folder in the repo |

The key idea: **the repo is the single source of truth.** The Gateway does *not* keep its
own copy of the projects — its project folders are **directory junctions** that point back
into your repo working copy. You edit files in the repo (or pull them from GitHub), tell the
Gateway to re-scan, and it reads them through the junction. What you commit is exactly what
the Gateway runs. (Full rationale: `ignition-context-pack/09_repo_gateway_sync.md`.)

---

## 1. Install prerequisites

Install these before touching the repo. Versions are what the team runs today.

| Software | Why | Notes |
|---|---|---|
| **Git for Windows** | Clone, branch, commit | `winget install Git.Git` |
| **SQL Server 2022** (Developer or Express) | Hosts `MPP_MES_Dev` | During setup **enable Mixed Mode authentication** (SQL + Windows). Required — the dev `ignition` SQL login won't work otherwise. |
| **`sqlcmd`** | Runs `.sql` files from the reset/test scripts | Ships with SQL Server / SSMS. Confirm with `sqlcmd -?`. |
| **SSMS or Azure Data Studio** | A SQL client for poking at the DB | Either is fine. |
| **`SqlServer` PowerShell module** | Used by the dev reset script | One-time: `Install-Module SqlServer -Scope CurrentUser` |
| **Ignition 8.3** | The Gateway + Designer | Download from Inductive Automation; install the Gateway as a Windows service (default path `C:\Program Files\Inductive Automation\Ignition`). |
| **Node.js (LTS)** | Doc generation + the docs portal (`npm`) | Only needed if you'll regenerate Word docs / run the portal. Then `npm install` in the repo root. |
| **VS Code** (or your editor) | Editing files, SQL, Python, JSON | Optional but recommended. |

> SQL Server **Mixed Mode** is the single most common setup miss. If you forget it, you can
> flip it later in SSMS: *Server Properties → Security → SQL Server and Windows Authentication
> mode*, then restart the SQL service.

---

## 2. GitHub access + clone

1. **Get repo access.** The repo is private at **`https://github.com/Jacques-BRA/MPP.git`**.
   Jacques must add your GitHub account as a **collaborator** (GitHub → repo → Settings →
   Collaborators) before you can clone or push. *(Jacques: do this first — nothing below
   works without it.)*

2. **Authenticate git.** Easiest is to install [GitHub CLI](https://cli.github.com/)
   (`winget install GitHub.cli`) and run `gh auth login` — it sets up credential storage so
   `git push` just works over HTTPS.

3. **Clone** into your dev folder (pick any path you like — it does **not** have to match
   anyone else's):

   ```powershell
   cd C:\Users\<you>\Documents\Dev
   git clone https://github.com/Jacques-BRA/MPP.git
   cd MPP
   ```

4. **Set your git identity** for this repo:

   ```powershell
   git config user.name  "Your Name"
   git config user.email "you@braemail.us"
   ```

---

## 3. Create your branch

We do **not** commit to `main`. Each developer works on their own branch and merges to
`main` deliberately. The team convention is `<firstname>/<purpose>` — e.g. `jacques/working`,
`hunter/explore`. Create yours off `main`:

```powershell
git checkout main
git pull
git checkout -b <yourname>/working
git push -u origin <yourname>/working
```

From now on, all your work lands on `<yourname>/working`.

> **Commit rule the team enforces** (see [§10](#10-conventions-cheat-sheet)):
> stage **explicit paths only** (never `git add -A`/`-u`) — concurrent work + auto-push
> can otherwise sweep stray files into the wrong commit.

---

## 4. Build the SQL dev database

The whole database is rebuildable from the `/sql` migrations — you never hand-craft it.

1. Confirm SQL Server is running and reachable (`localhost` default instance is assumed).

2. From the repo root, run the reset script:

   ```powershell
   .\sql\scripts\Reset-DevDatabase.ps1
   ```

   For a named instance: `.\sql\scripts\Reset-DevDatabase.ps1 -ServerInstance ".\SQL2022"`

   This drops and recreates `MPP_MES_Dev`, creates the dev `ignition` SQL login
   (password `ignition`, `db_owner` — **dev-only**), creates `dbo.SchemaVersion`, then runs
   all versioned migrations → repeatables → seeds in order. It auto-discovers files, so
   there's no list to maintain.

3. **Run the test suite** to confirm a clean build:

   ```powershell
   .\sql\tests\Run-Tests.ps1
   ```

   You should see all tests passing (the suite is ~1200 assertions and currently green). If
   `Run-Tests` exits 1 with **0 failures**, a test *file* threw (often an FK violation in
   fixture cleanup) — that's a known signature, not a broken DB.

> **Dev-only login warning:** the `ignition`/`ignition` login with `db_owner` exists *only*
> because `DROP DATABASE` wipes DB users on every reset. Never run this script — or that
> login — against staging/prod. Prod provisioning is manual and least-privilege (see the
> PROD NOTICE block in `sql_version_control_guide.md`).

---

## 5. Set up the Ignition Gateway + project junctions

This is the step that's specific to our repo↔Gateway model. Do it once.

### 5a. Install + start the Gateway

Install Ignition 8.3, start the Gateway service, and open **`http://localhost:8088`**.
Complete the initial admin setup (commissioning) and sign in.

### 5b. Junction the project folders into the repo

The Gateway must read the three active projects — **`Core`** (the inheritable parent holding
the `BlueRidge.*` script library + all Named Queries), **`MPP`** (plant-floor project), and
**`MPP_Config`** (config tool) — *through junctions* that point at your repo working copy.

There's a helper at the repo root, **`link-projects.ps1`**, but ⚠️ **it needs two edits for a
fresh machine** before you run it:

1. **Fix the `$repo` path** — it's hardcoded to Jacques's clone path. Change it to *your*
   clone's `ignition\projects` folder.
2. **Add `MPP_Config`** to the project loop — the script currently links only `Core` and
   `MPP` (on Jacques's machine `MPP_Config` was linked by hand before the script existed; on
   your fresh machine it isn't).

The loop line should read:

```powershell
$repo = "C:\Users\<you>\Documents\Dev\MPP\ignition\projects"   # <- your path
...
foreach ($name in @("Core", "MPP", "MPP_Config")) {            # <- add MPP_Config
```

Then run it **from an elevated (Administrator) PowerShell** — creating junctions under
`C:\Program Files\...` requires elevation:

```powershell
# Admin PowerShell, in the repo root
.\link-projects.ps1
```

It's non-destructive and idempotent: any pre-existing *real* Gateway folder is renamed to
`<name>.realbak-<timestamp>` (not deleted) before the junction is made, and already-junctioned
folders are skipped. If the Gateway has a folder locked, disable that project in the Gateway
web UI (or stop the Ignition service), re-run, then re-enable.

Verify each one is a junction, not a real folder:

```powershell
Get-Item "C:\Program Files\Inductive Automation\Ignition\data\projects\Core" -Force |
    Select-Object LinkType, Target
# LinkType = Junction, Target = your repo path
```

> **Why junctions and not copies:** one source of truth, no elevation needed for every edit
> (only this one-time link), and version control captures exactly what runs. A project you
> create fresh in Designer is a **real** folder, not a junction — symptom: you edit the repo,
> scan, and nothing changes. If that happens, re-run `link-projects.ps1` to convert it.

### 5c. Create your Gateway API token (for `scan.ps1`)

After any file change in a linked project you run `.\scan.ps1` to tell the Gateway to re-read
from disk. It authenticates with a per-developer Gateway API key:

1. In the Gateway web UI: **Config → Security → API Keys → Create new API Key**, scoped to
   cover `POST /data/api/v1/scan/projects`.
2. Copy the token (shown **only once**) and save it to:

   ```
   %USERPROFILE%\Documents\git-sync-api-key.txt
   ```

   Contents: the token only — no quotes, no trailing newline. This file lives **outside** the
   repo and is gitignored; `scan.ps1` auto-resolves the path so the same checked-in script
   works for every developer.

3. Test it:

   ```powershell
   .\scan.ps1
   ```

   A successful scan prints the scan response + post-scan state. A **403** usually means the
   `Content-Type` header or the key's scan scope is missing; **401** means a bad/missing token.

### 5d. Point the Gateway at your dev database

In the Gateway web UI: **Config → Databases → Connections → Create new Database Connection**:

- **Driver:** Microsoft SQL Server
- **Connect URL:** `jdbc:sqlserver://localhost;databaseName=MPP_MES_Dev;encrypt=true;trustServerCertificate=true`
- **Username / Password:** `ignition` / `ignition` (the dev login the reset script created)

Name the connection to match whatever the project's Named Queries expect (check an existing
NQ's datasource, or ask the team, before inventing a name). Test the connection — it should
go *Valid*.

---

## 6. Install Designer + open a project

1. From the Gateway home page, launch the **Designer Launcher**, add your Gateway
   (`localhost:8088`), and open the **`MPP_Config`** (or `MPP`) project.
2. Confirm views render and Named Queries resolve. Because `Core` is the inheritable parent,
   the child projects only see the shared scripts/NQs if `Core` is also linked (you did that
   in 5b).

> **Inherited Named Queries need a Gateway restart**, not just a scan, to register. All NQs
> live in `Core` only; siblings can't see each other's NQs. If a child project can't find an
> inherited NQ right after linking, **restart the Gateway service** once.

---

## 7. Verify the whole stack

You're set up correctly when all of these pass:

- [ ] `git status` shows you on `<yourname>/working`, clean.
- [ ] `.\sql\tests\Run-Tests.ps1` → all green.
- [ ] `.\scan.ps1` → returns a scan result (not 401/403).
- [ ] All three Gateway project folders report `LinkType = Junction`.
- [ ] The Gateway database connection to `MPP_MES_Dev` is *Valid*.
- [ ] Designer opens `MPP_Config`, views render, a Named Query previews data.

---

## 8. (Optional) Doc generation toolchain

Only if you'll touch the Word docs / docs portal:

```powershell
npm install                 # installs docx/xlsx + portal deps from package.json
# Regenerate a Word doc (needs pandoc installed):
pandoc MPP_MES_FDS.md -o MPP_MES_FDS.docx --reference-doc=reference.docx
node style_docx_tables.js MPP_MES_FDS.docx
```

---

## 9. Daily workflow

Once set up, the loop is small:

1. **Start of session:** `git pull` on your branch. If the pull changed Ignition project
   files (someone else's committed work), run `.\scan.ps1` so the Gateway/Designer pick them
   up. If it changed SQL migrations, re-run `Reset-DevDatabase.ps1`.
2. **Edit:**
   - **SQL** → add a versioned migration (`NNNN_*.sql`) or edit a repeatable (`R__*.sql`) in
     your editor/SSMS, then `Reset-DevDatabase.ps1` to rebuild, then `Run-Tests.ps1`.
   - **Ignition** → do all view / component / Named Query / script / stylesheet work **in
     Designer**. Because the Gateway project folders are junctions into your repo, Designer
     saves write straight into your working copy — the changed files are right there to
     commit. You generally only need `.\scan.ps1` when files changed on disk *outside*
     Designer (e.g. after a `git pull`).
3. **Commit:** stage **explicit paths**, write the message, push to your branch. (Tip:
   `git diff --stat` a `view.json` before staging — Designer can pickle live runtime data
   into a view and bloat the diff; revert that noise before committing.)
4. **Merge:** open a PR to `main` (or merge deliberately) when a unit of work is done and
   tests pass.

---

## 10. Conventions cheat-sheet

The handful of rules that bite newcomers. Fuller detail lives in **`CLAUDE.md`** (the
canonical project-conventions file — named for the AI-agent workflow, but it's the
human-readable source of truth for SQL/Ignition/doc conventions) and the
`ignition-context-pack/` (vendor-neutral Ignition 8.3 reference, useful regardless of tooling).

| Area | Rule |
|---|---|
| **Branch** | Work on `<yourname>/working`. Never commit straight to `main`. |
| **Staging** | Stage **explicit file paths**. Never `git add -A` / `git add -u` — concurrent work + auto-push can sweep stray files into the wrong commit. |
| **Ignition local sync** | Only ever run `.\scan.ps1` locally. `pull.ps1` is for the *deploy box* (git-reset based) — don't run it on your laptop. |
| **Ignition edits → Designer** | Do all view/NQ/script work in Designer, not by hand-editing JSON. Designer's GSON serialization + in-memory cache fight on-disk edits (and emit unicode-escaped JSON that's painful to diff). If you ever *do* hand-edit a file, don't do it while Designer has that view open. |
| **Named Queries** | All NQs live in `Core`. After adding/moving an NQ, **restart the Gateway** (scan alone won't register inherited NQs). |
| **SQL** | UpperCamelCase identifiers, `Schema.Entity_Verb` procs, migrations are immutable once applied (fix-forward with a new migration), `CREATE OR ALTER` for repeatables. See `sql_best_practices_mes.md` + `sql_version_control_guide.md`. |
| **Project docs** | Read order is in `CLAUDE.md` (the Document Map table). **`PROJECT_STATUS.md`** holds current state, active blockers, and what's in flight — read it before starting work. (`README.md` is stale — predates the build; use `CLAUDE.md` + `PROJECT_STATUS.md`.) |

---

## 11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Repo edits don't show in Designer after a scan | That project folder is a **real** Gateway folder, not a junction. Re-run `link-projects.ps1` (Admin) to convert it. |
| `Access is denied` creating junctions | Not in an elevated shell. Re-run `link-projects.ps1` from an **Administrator** PowerShell. |
| `scan.ps1` → **403** | Missing `Content-Type: application/json` on the POST, or the API key lacks the scan scope. |
| `scan.ps1` → **401** | Bad/missing token in `…\Documents\git-sync-api-key.txt`. |
| `Reset-DevDatabase.ps1` fails to create the `ignition` login | SQL Server isn't in **Mixed Mode**. Enable it in SSMS, restart the SQL service, re-run. |
| `Run-Tests.ps1` exits 1 with **0 failures** | A test file threw (often FK cleanup ordering), not an assertion failure. Also: a reset/Ignition race can stick `MPP_MES_Dev` in SINGLE_USER — KILL the session from `master`, then `SET MULTI_USER`. |
| Child project can't find an inherited Named Query | `Core` not linked, or the Gateway needs a **restart** to register inherited NQs. |
| New view shows blank/error after scan | Malformed `view.json` (trailing comma / UTF-8 BOM). Fix the file, scan, reopen the view. |
| Designer "Files vs Gateway" conflict dialog | You file-edited a view Designer had open. Avoid editing open views as files; prefer Designer for existing views. |

---

*Questions that aren't covered here usually are in `ignition-context-pack/09_repo_gateway_sync.md`
(sync model), `sql_version_control_guide.md` (DB workflow), or `CLAUDE.md` (conventions).*
