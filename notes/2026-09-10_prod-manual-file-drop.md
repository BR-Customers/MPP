# Prod manual file drop — 2026-09-10

Surgical alternative to a project export/import. Prod is live and carrying real
LOTs, so this changes only the 25 files that actually differ.

**Baseline:** prod's Ignition projects came from the `2026-09-09_1106` export set,
which was built from commit `add7dae6`. Confirmed by byte-comparing the shipped
`Core_2026-09-09_1106.zip` against that commit's tree (400 entries, the single
difference being a `resource.json` the builder legitimately rewrites on the way
into the archive). So the delta below is `add7dae6..HEAD`.

**Not in this list, deliberately:** the 86 `resource.json` manifests repaired in
`421402da`. Prod does not need them. The export builder already rewrote manifests
on the way into the zip, so prod's imported tree declares `["view.json"]` and has
no `thumbnail.png` — it is already consistent. Copying those would be churn.

---

## 1. SQL first

Prod is at `0071`; this ships `0072` + `0073` plus repeatables. Preview already
confirmed exactly 2 pending, both above the watermark.

```
BACKUP DATABASE MPP_MES_Prod
  TO DISK='...\MSSQL\Backup\MPP_MES_Prod_pre0072_20260910.bak'
  WITH INIT, CHECKSUM
```

```
.\sql\scripts\Update-Prod.ps1 -ServerInstance 172.17.10.148 -Username Ignition -Password '<pw>'
```

Watch for `0073 backfill: N row(s)`. **N will NOT be 0 on prod** — it reconstructs
a shot-counter reading for every existing contribution on the real LOTs, which is
what establishes their watermarks. Low tens is expected; thousands is not.

SQL must land before the files: the new views call procs that do not exist yet.

---

## 2. Files — 25 of them

Source is this repo at `ignition/projects/<P>/…`; destination is prod's
`<install>\data\projects\<P>\…` at the identical relative path.

### Core — 9 content files + 5 manifests

| Action | Path under `Core/` |
|---|---|
| replace | `ignition/named-query/lots/DieCastLot_Release/query.sql` |
| replace | `ignition/named-query/lots/DieCastLot_Release/resource.json` |
| **new folder** | `ignition/named-query/oee/DowntimeScope_ListForTerminal/` → `query.sql` + `resource.json` |
| replace | `ignition/named-query/workorder/DieCastShiftOutput_Record/query.sql` |
| replace | `ignition/named-query/workorder/DieCastShiftOutput_Record/resource.json` |
| **new folder** | `ignition/named-query/workorder/DieCast_GetReleasePreview/` → `query.sql` + `resource.json` |
| replace | `ignition/named-query/workorder/DieCast_GetShiftOutputBreakdown/query.sql` |
| replace | `ignition/named-query/workorder/DieCast_GetShiftOutputBreakdown/resource.json` |
| replace | `ignition/script-python/BlueRidge/Lots/Lot/code.py` |
| replace | `ignition/script-python/BlueRidge/Oee/Downtime/code.py` |
| replace | `ignition/script-python/BlueRidge/Parts/Tool/code.py` |
| replace | `ignition/script-python/BlueRidge/Workorder/DieCast/code.py` |

The three `resource.json` on existing named queries are **not optional** — they
declare the new `counterReading` / `cellLocationId` parameters. Ship the
`query.sql` without them and the NQ rejects the call.

### MPP — 11 views + 1 new manifest

All under `com.inductiveautomation.perspective/views/BlueRidge/`:

| Action | Path |
|---|---|
| replace | `Components/PlantFloor/DieCastEntry/BulkOpenRow/view.json` |
| replace | `Components/PlantFloor/DieCastEntry/CavityLotRow/view.json` |
| replace | `Components/PlantFloor/DieCastEntry/OpenBasketRow/view.json` |
| replace | `Components/PlantFloor/DieCastEntry/ScrapLineRow/view.json` |
| replace | `Components/PlantFloor/ElevationModal/view.json` |
| **new folder** | `Components/Popups/DieCastRelease/` → `view.json` + `resource.json` |
| replace | `Components/Popups/DieCastLotReleaseHowTo/view.json` |
| replace | `Components/Popups/DieCastOpenHowTo/view.json` |
| replace | `Components/Popups/DieCastShiftOutputHowTo/view.json` |
| replace | `Components/Popups/DowntimeManager/view.json` |
| replace | `Views/ShopFloor/AppHeader/view.json` |
| replace | `Views/ShopFloor/DieCastBody/view.json` |

### MPP_Config — 2 views

| Action | Path under `com.inductiveautomation.perspective/views/BlueRidge/` |
|---|---|
| replace | `Components/Parts/Tools/Cavities/view.json` |
| replace | `Components/Parts/Tools/_Tools/CavityRow/view.json` |

---

## 3. Three rules for the new folders

1. **A resource folder without `resource.json` is invisible to the scanner.** The
   view renders "View Not Found"; the named query logs "Named query not found".
   Copy both files, every time.
2. **Do not create `thumbnail.png`.** The new `DieCastRelease/resource.json`
   declares `["view.json"]` only. A manifest naming a file that is not there is
   what stopped the Designer opening MPP and MPP_Config this morning.
3. **Do not copy a `__pycache__` folder into a script-python folder.** A script
   resource is a LEAF of `code.py` + `resource.json`; a child folder makes the
   Gateway render it as a folder and `BlueRidge.Common.Util` stops resolving.

---

## 4. Register the files

Project scan on prod — same call `scan.ps1` makes locally:

```
POST http://<prod-gateway>:8088/data/api/v1/scan/projects
     X-Ignition-API-Token: <token>
     Content-Type: application/json          <-- omitting this returns 403
     {}
```

No Gateway restart needed; a scan is enough for views, named queries and scripts.

---

## 5. Verify before anyone touches a terminal

Run from the repo, pointed at prod's project store (works over a UNC path or
locally on the prod box):

```
python tools/verify_project_tree.py "\\<prod-host>\c$\Program Files\Inductive Automation\Ignition\data\projects\Core"
```

…and the same for `MPP` and `MPP_Config`. All three must print `ok`. It checks
every manifest against what is actually on disk, that every script resource is a
leaf, and that nothing has content without a manifest — the three ways this tree
has broken so far.

Then, on the prod Gateway's own log, confirm a scan produces **zero**
`ResourceCollectionFileTree` / `NoSuchFileException` lines.

---

## 6. First thing to click

Die Cast terminal → **Lot Release** → `Release` on any open basket. The dialog
must show three boxes reading *on the basket now / this release adds / basket
closes at*, and the middle one must move as the counter reading is typed. That
one action exercises the new popup, the new read proc, the new named query and
the release write path together.
