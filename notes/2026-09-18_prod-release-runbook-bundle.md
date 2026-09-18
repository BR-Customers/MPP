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

## 6. F5 every open terminal.

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

## Outcome
_(fill in after the window)_
