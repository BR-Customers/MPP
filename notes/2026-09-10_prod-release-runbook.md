# Prod release runbook — 2026-09-10 (counter anchor, punch list, cavity alpha code)

Ships everything on `jacques/working` @ `50a35d19` that prod does not have:
migrations **0074** (counter anchor), **0075** (defect code 260), **0076**
(cavity alpha code, **drops two columns**), the procs that changed with them, and
45 Ignition resources. Prod is live — do it in a quiet window with die cast told.

Supersedes `Deploy-0074-CounterAnchor.ps1` and `Deploy-0076-CavityAlphaCode.ps1`
(and their `-Since 8c8a8f8c` export, which missed the anchor and punch-list views).

---

## 0. Before the window

- Password into a masked env var (never on a command line — it has already been
  exposed; rotate it after this release):

  ```powershell
  $env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
  ```

- **Preview (read-only)** — run it now, read it, fix anything it BLOCKs on:

  ```powershell
  .\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition
  ```

  It prints what prod is at, what is pending, which procs differ from the repo
  (with per-proc diffs in the report folder), the cavity letters 0076 will assign
  (`0076_cavity_letters.csv` — **eyeball these, they are permanent**), live
  sessions/open baskets, and a **plan fingerprint**. Report lands in
  `dist\deploy-reports\`.

  Expected BLOCKs if the cavity map is incomplete — fix them in the Tool
  Cavities editor (prod UI already allows mapping a scrapped cavity), re-preview:
  - a die with some cavities mapped and some not
  - a die that has made 2+ parts but has no map at all (would get die-wide a..l)
  - `Lots.Lot.CavityNumber` populated
  - any object on prod not in the repo that still names `CavityNumber`

- Have the Designer open on the prod Gateway, logged in, with the three zips to hand:
  `dist\ignition-exports\{Core,MPP,MPP_Config}_prod-release-2026-09-10_2026-09-10_2056.zip`
  and the checklist `prod-release-2026-09-10_2026-09-10_2056_CONTENTS.txt`.

## 1. Rehearse (optional but cheap)

Applies the whole release to prod's real data inside a transaction, verifies,
rolls back. Die-cast writes wait for ~1 s.

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -Mode Rehearse -ExpectedPlan <fingerprint>
```

## 2. The window — SQL, then Ignition immediately

**Why back to back:** the moment the SQL commits, prod's *current* Ignition
resources are wrong for it — `lots/Lot_Create` (Receiving Dock, Inventory
Manager) and `parts/ToolCavity_Create` fail outright, and die cast / LOT detail /
LOT search / inspection show blank cavity fields — until the Core and MPP
imports land. Target: under 5 minutes. Ask die cast not to open or release
baskets during it.

1. **SQL** (takes a COPY_ONLY backup + VERIFYONLY first, then one transaction):

   ```powershell
   .\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -Mode Execute -ExpectedPlan <fingerprint>
   ```

   Refuses if the plan changed since your preview. Any failure rolls the whole
   release back — prod stays exactly as it was. Must end with `COMMITTED`,
   "every repo migration is recorded", "applied repeatables match the repo".

2. **Ignition** — Designer **File → Import**, one zip at a time, **Core first**,
   then MPP, then MPP_Config. Accept overwrite for the listed resources.
   **Do not** use the Gateway web page's project import with these zips — they
   are partial (45 resources), not whole projects.

3. `Remove-Item Env:SQLCMDPASSWORD`

## 3. Smoke (first 10 minutes)

- Die Cast terminal: cavity dropdown shows letters (`a`, `b`…) with parts;
  open a basket; the counter context line shows "This die is at N for the shift";
  Release dialog shows its three boxes.
- Config Tool → Tools: "Asset Number" label, no die rank, cavities editor
  shows a Code column; add a cavity on a test die.
- Receiving Dock: create a LOT (proves `lots/Lot_Create`).
- Trim scrap reasons include **260 Scale Adjustment**.
- Gateway log: no `Named query not found`, no `NoSuchFileException`.

## 4. Rollback

- **Before COMMIT:** automatic — nothing to do.
- **After COMMIT:** 0076 dropped columns; the only way back is
  `RESTORE DATABASE` from the backup path printed in step [9] (also in
  `backup.txt` in the report folder), then re-import the 09-09 project set.
  Forward-fixing is almost always better.

## Outcome — executed 2026-09-10 22:14 ET

- Prod preview: `0073` (applied 10:36 that morning), 0074/0075/0076 pending, 432
  procs identical / 20 changed / 3 new — **zero drift** from the morning deploy.
  No BLOCK, no WARN. Plan identical to the one rehearsed on ProdSim.
- Rehearsal on prod passed and rolled back (10.2 s lock window — network
  round-trips; 0.8 s locally).
- A commit landed between rehearsal and execute (`7221d519`, a `Deploy-0076`
  script fix) and the fingerprint guard **refused** the old plan. `plan.txt`
  showed only the `HEAD|` line differed; re-run with `-ExpectedPlan 2a792727e976`.
- Execute: backup `...\MSSQL16.MSSQLSERVER\MSSQL\Backup\MPP_MES_Prod_pre-release_0073_20260910_221451.bak`
  (COPY_ONLY, verified), transaction **committed in 9.2 s**, extended properties
  applied, all 23 procs byte-identical to the repo. All 31 active cavities got
  exactly the previewed letters.
- Ignition zips imported (Core, MPP, MPP_Config).
- Report: `dist\deploy-reports\MPP_MES_Prod_Execute_20260910_221451\`.

## Verified before the run

Built `MPP_MES_ProdSim` from `ea85f0c6` (prod's morning state, `SchemaVersion`
shaped like prod's), loaded dies covering every gate case, open baskets with
counter readings, and a prod-only proc naming `CavityNumber`. Preview blocked on
all four bad cases and nothing else; after fixing: rehearsal passed and rolled
back (0.8 s lock window), execute backed up + committed (0.6 s), all 23 applied
procs byte-identical to the repo, die watermarks unchanged, re-preview "nothing
to do". Export zips verified byte-identical to HEAD (8 manifests rewritten only
to drop `thumbnail.png`).
