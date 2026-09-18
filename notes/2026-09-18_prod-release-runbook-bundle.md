# Prod release runbook -- 2026-09-18 bundle (0090-0095 + Ignition, incl. Hunter's branch)

**Release commit:** the commit that adds this file, on `jacques/working` (= `main`). Run everything
from that checkout. **Commit nothing between Preview and Execute** -- the fingerprint covers HEAD.
**Prod before:** SQL `0089` (`192c77c1`), Ignition = `aec53015` import + Hunter's direct 09-16
gateway edits + Jacques's direct Designer edits (all now in git; prod export `reference/*_20260918110*.zip`).
**Rehearsed:** ProdSim at `0089`, HEAD `4f0173cb`: 5 migrations + 28 repeatables, `checks passed`,
lock window **0.4 s**, rolled back clean. SQL tests 3840/3840. Dev smoke-tested (see bottom).
**Scoping notes:** `notes/2026-09-17_prod-release-handoff-*.md`, `notes/2026-09-18_*handoff*.md`.

---

## 0. Pre-flight (read-only, ~3 min) -- in SSMS or sqlcmd against MPP_MES_Prod

**G1 -- every Config Tool user is an active MES user with their exact AD login.** After this release
a Config Tool save by anyone NOT mapped is refused ("Signed in as 'x', which is not an active MES
user..."; a second "Action failed" toast follows -- nothing is written).
```sql
SELECT Id, Initials, DisplayName, AdAccount, DeprecatedAt
FROM Location.AppUser WHERE AdAccount IS NOT NULL ORDER BY AdAccount;
```
Pass: each Config Tool user has a row, `DeprecatedAt` NULL, `AdAccount` exactly equal to the name
the Config Tool shows them signed in as. Fix gaps on the Users screen first.

**G3 -- SYS exists:** `SELECT Id, Initials, DeprecatedAt FROM Location.AppUser WHERE Id = 1;` -> 1 row, active.

**OEE check batch (0090):**
```
sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -I -W -s "|" -i sql\scratch\2026-09-18_oee_preflight_gates.sql
```
| Result set | Expect | If not |
|---|---|---|
| A: what 0090 will flag | every die cast press, trim machine (Bowls, Blasters...), production/inspection line | read it |
| B: downtime (open / last 30 d) on locations that will NOT be flagged | **empty** | stop, tell Claude/Jacques |
| C: per-terminal Downtime Manager choices, before vs after | **no `LOST` rows** (ProdSim showed TRIM1/TRIM2 LOST -- a Dev-seed artefact; prod's trim shops have machines) | stop |
| D: flagged location under a flagged ancestor | empty | read it |
| E: live shift overrides on unflagged locations | empty | read it |

**Informational:** `SELECT Name FROM Lots.PrintReasonCode WHERE Code = N'ReprintDamaged';` (mojibake today; 0093 fixes it).

## 1. Preview
```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```
Expect (ProdSim printed this; prod may differ slightly -- read any extra CHANGED diff):
- `[3]` **5 pending:** `0090_location_is_oee_enabled`, `0091_line_inventory_sidebar`, `0093_printreasoncode_ascii_name`, `0094_retire_low_inventory_horizon`, `0095_retire_component_projection`. No `0092` -- deliberate.
- `[4]` ~15 CHANGED / 13 NEW. **On prod `Lots.ShippingLabel_GetLastForTerminal` and `Oee.DowntimeEvent_RequiresReasonGate` show CHANGED (or identical), not NEW** -- Hunter created them directly on 09-16.
- `[WARN] ... workorder.assembly_getcomponentprojection` -- expected, 0095 drops it.
- `Columns dropped: Parts.Item.LowInventoryHorizon` -- expected (added by 0091, dropped by 0094).
- `[5]` no gate fired. `[6]` note open baskets / running shifts. Verdict `Clear to deploy`.
- **Copy the Plan fingerprint -- paste it, never retype it.**

## 2. Rehearse
```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```
Expect `== checks passed`, `ROLLED BACK`, `REHEARSAL PASSED`, lock window about 1 s or less.

## 3. Execute (quiet moment)
```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <fingerprint>
```
Expect: verified COPY_ONLY backup, then `== COMMITTED`, then `Import the Ignition exports NOW -- Core first.`
From here until step 4 finishes, 6MA Assembly OUT's old inventory sidebar errors (0095 dropped its proc) -- tray closes still work. Go straight to step 4.

## 4. Ignition imports -- back to back, Designer File -> Import, in this order
From `dist\ignition-exports\` (built from git at `4f0173cb`, verified; checklist `rel-20260918_2026-09-18_1302_CONTENTS.txt`):
1. `Core_rel-20260918_2026-09-18_1302.zip` -> Core (63 resources)
2. `MPP_rel-20260918_2026-09-18_1302.zip` -> MPP (44)
3. `MPP_Config_rel-20260918_2026-09-18_1302.zip` -> MPP_Config (29)

Deliberately **not** in the archives: MPP_Config `global-props` and `session-permissions` (prod's
already set -- its datasource is `mpp`, Dev's is `MPP_MES_DB`; do not touch MPP_Config project
properties), and the AIM timers (prod has them **enabled**; leave them).

## 5. Delete by hand in the Designer (an import cannot delete)
- Core: named query `workorder/Assembly_GetComponentProjection`
- MPP: view `BlueRidge/Components/PlantFloor/ComponentProjectionRow`
- Optional leftovers: MPP view `BlueRidge/Components/PlantFloor/DieCastEntry/RejectPanel`, Core script `BlueRidge/temp` (empty).

## 6. Terminals
A Designer save pushes the change to open Perspective sessions on its own. F5 only a terminal that looks stale.

## 7. Verify (~5 min)
```sql
SELECT MAX(MigrationId) FROM dbo.SchemaVersion;                                   -- 0095_retire_component_projection
SELECT Name FROM Lots.PrintReasonCode WHERE Code = N'ReprintDamaged';             -- Reprint - Damaged
SELECT TOP 5 LoggedAt, UserId, LEFT(Description,80) FROM Audit.ConfigLog ORDER BY LoggedAt DESC;      -- after a Config Tool save: YOUR id, not 2
SELECT TOP 5 Id, LocationId, AppUserId, StartedAt FROM Oee.DowntimeEvent ORDER BY Id DESC;            -- after a floor downtime: the operator's id
```
Screens: a Config Tool save as yourself (Tools / Item Master); PIN in at a line -> Downtime -> Start,
reason, End (no supervisor prompt on the current shift); die cast Reconcile opens with **shift blank**,
Submit shows the confirm popup; an Assembly OUT screen shows the Line Inventory dock + footer
**Reprint Shipping Label** + header **Reprint**; Cutover opens on **Warehouse**; Trim OUT tiles wrap.
Gateway log: search `called with no appUserId` -> none.

## 8. Rollback
- **Ignition:** re-import prod's own full exports from this morning: `reference/Core_20260918110042.zip`,
  `reference/MPP_20260918110048.zip`, `reference/MPP_Config_20260918110052.zip` (Core first). This restores
  the DEV-user attribution and double toasts.
- **SQL:** the COPY_ONLY backup Execute took. Restoring loses everything written since -- last resort;
  with 0090-0095 metadata-only-ish, prefer fixing forward.

## Tell the floor
- Die cast: the reporting shift starts blank -- pick it; Submit asks you to confirm the shift.
- Assembly OUT: Reprint Shipping Label (footer, needs a supervisor) and Reprint (header, last label here).
- The legacy "Downtime Entry" menu screen now only accepts presses and trim machines -- use the Downtime button.

## Known, not in this release
1. Config Tool save by an unmapped user shows a second "Action failed" toast (nothing written).
2. Part type recategorization (MPP Cast / Components / Pass Through) -- next release.
3. Line Inventory dock errors on the Fallback Terminal before a location is chosen.
4. AssemblyNonSerialized header overflows at 1200 px wide (fine at 1400).

## Outcome -- executed 2026-09-18 13:23 ET

**SQL clean: `== COMMITTED`, sqlcmd exit 0 after 11.0 s; all 28 repeatables match the repo byte-for-byte; `R__Descriptions_ExtendedProperties` applied after commit. Ignition imported after two import slips (below); the 13:49 prod exports match git at `e3e0aa25` for every shipped resource.**

| | |
|---|---|
| Executed at | 2026-09-18 13:23 ET, from `jacques/working` @ `e3e0aa25` |
| Plan fingerprint | `f5e07bd04140` |
| Backup | `MPP_MES_Prod_pre-release_0089_20260918_132322.bak` (COPY_ONLY, CHECKSUM, verified) in the instance default backup path on MESDBSRV |
| Preview `[3]` | 5 pending: 0090, 0091, 0093, 0094, 0095 -- as expected |
| Preview `[4]` | 448 identical, 17 changed, 11 new. Hunter's two out-of-band procs (`Lots.ShippingLabel_GetLastForTerminal`, `Oee.DowntimeEvent_RequiresReasonGate`) showed CHANGED, not NEW -- as predicted |
| Warnings | `workorder.assembly_getcomponentprojection` (dropped by 0095); column drop `Parts.Item.LowInventoryHorizon` -- both expected |
| Gates `[5]` | none fired |
| Live activity | 12 open baskets, 1 running shift, last die cast entry 12:42 ET |
| Prod rehearsal | 13:13 ET, `checks passed`, rolled back. **Lock window 9.3 s** (ProdSim 0.4 s) -- whole-transaction time from the laptop under live plant traffic; Execute 11.0 s. No plant errors reported. |
| Report | `dist/deploy-reports/MPP_MES_Prod_Execute_20260918_132322/` |

**What went differently from the plan:**
- **Fingerprint typo on the first Execute** (13:17): `f55e07bd04140` for `f5e07bd04140`. The guard aborted before any backup or transaction. Paste the fingerprint; never retype it (same lesson as 2026-09-12 and 2026-09-17).
- **A full-project export was opened for import** (it listed Reports, Session Props, Global Props, Session Event Scripts). Caught at the import dialog; cancelled.
- **The MPP_Config archive was imported into Core.** Its 29 views landed in Core (harmless -- MPP_Config's own copies override -- but wrong). Removed by hand; Core again holds only NotifyHost, ConfirmDestructive, CrtNotice, Toast (verified in the 13:49 export). The correct archives then went into their own projects.
- **`Popups/PausedLotList/PausedLotRow` cannot be imported.** A view nested inside another view's folder: the Designer refuses ("Unable to create folder path, found non-folder in the way at .../Popups/PausedLotList"). That is why prod never had it. It was force-added with `-IncludeResource`; it was unticked at import and the MPP archive rebuilt without it (`MPP_rel-20260918-v2_*`). Prod is unchanged for it (still missing, as before). Follow-up: move it to a standalone path.

**Post-release verification (13:49 prod exports vs git `e3e0aa25`):** every shipped resource identical. Remaining differences, all expected: session-props client address (all three), `Hold_ListOpen` manifest formatting, AIM timers enabled on prod (intended), `MachiningIn` (Jacques's prod-only sizing tweak, not in this release), MPP_Config `global-props` (prod's own, not shipped), leftovers `DieCastEntry/RejectPanel` + Core `BlueRidge/temp`, `PausedLotRow` missing. **At 13:49 the two retired resources were still present** -- Core `workorder/Assembly_GetComponentProjection`, MPP `ComponentProjectionRow`; harmless (nothing references them), delete in the Designer.

**Config Tool attribution:** the tool requires AD login; an AD user with no matching `AppUser.AdAccount` is refused on save ("Not saved", then a second "Action failed" toast; nothing written). Set every Config Tool user's AD Account to the exact login name on the Users screen. On Dev, `JGP` (Id 22) was set to `admin` through `Location.AppUser_Update`.

**Release notes:** `notes/2026-09-18_release-notes-email.md`.

**Follow-ups (next release):**
1. Part-type recategorization: *MPP Cast* (code Component), *Components* (purchased; new code, the 33 current PassThrough items), *Pass Through* (the parts in `reference/MPP pass through parts.pdf`). Touches `Lot_GetLineInventorySummary`, `Item_ListForCutoverLocation`, `Item_Update` and ~4 Ignition spots (Item module, Item Master, Identity/BOMs, AttributeOptions).
2. Move `PausedLotRow` out of `PausedLotList`'s folder so it can ship.
3. Unmapped AD user: second "Action failed" toast (the view should stop after the attribution refusal).
4. Line Inventory dock / Tolerances error on the Fallback Terminal before a location is chosen (`Lot_GetLineInventorySummary` / `ItemLocation_ListConsumptionForLine` return no result set when the location has no line).
5. AssemblyNonSerialized header overflows at 1200 px (fine at 1400).
6. Flag the three 6MA Cam Holder Line 1 conveyors OEE-enabled (line stays flagged -> roll-up); check `Machining Conveyor`'s location type.
