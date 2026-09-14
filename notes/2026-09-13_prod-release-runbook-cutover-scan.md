# Prod release runbook: 2026-09-13 (Inventory Cutover Scan — SQL + Ignition)

**Prod baseline:** `d4c29e75` — the state prod SQL has been at since 2026-09-11, and
prod Ignition since the 2026-09-12 Config Tool release (`b7bc870e`, which touched no
SQL, so both converge for SQL purposes). **This release:** `515db6c6`.

This is a **SQL + Ignition** release: 2 versioned migrations, 12 repeatables, and 68
Ignition resources across three projects. Unlike the last two releases there IS a
database change, so the full preview → rehearse → execute path applies and a backup is
taken.

**Nothing may be committed between the preview you read and the execute.** The plan
fingerprint includes HEAD; Execute refuses if anything moved.

---

## What ships

### SQL

| Migration | What it does |
|---|---|
| `0080_cutover_entry_route_and_cast_date` | `Lots.Lot.EntryRouteSequence`, `Lots.Lot.CastDate`, `Location.Location.DefaultStockLocationId`. All nullable, no backfill, metadata-only ALTERs. |
| `0081_location_is_stock_location` | `Location.LocationTypeDefinition.IsStockLocation` (BIT, default 0), set 1 for `InventoryLocation`, `SupportArea`, `InspectionStation`, `InspectionLine`. |

12 repeatables — 6 new, 6 changed:

```
NEW      R__Lots_ufn_NextPendingRouteStep.sql
NEW      R__Location_Location_GetStockDestination.sql
NEW      R__Location_Location_ListProductionLines.sql
NEW      R__Parts_RouteStep_GetSequenceForItemRole.sql
NEW      R__Tools_Tool_ListForItem.sql
NEW      R__Tools_ToolCavity_ListForItemTool.sql
CHANGED  R__Lots_Lot_Create.sql
CHANGED  R__Lots_Lot_GetComponentsAtCell.sql
CHANGED  R__Lots_Lot_GetTrimStorageQueueForLine.sql
CHANGED  R__Lots_Lot_GetWipQueueByLocation.sql
CHANGED  R__Lots_Lot_MoveToValidated.sql
CHANGED  R__Workorder_MachiningOut_Mint.sql
```

`R__Descriptions_ExtendedProperties.sql` runs **after** the commit, outside the
transaction, so it never holds locks on every table.

**The five CHANGED read/mint procs are the behaviour-neutral Phase A extraction.**
Seven copy-pasted pending-step CTEs were replaced by one `Lots.ufn_NextPendingRouteStep`.
Proven neutral by diffing the full test suite before and after, line by line — identical.
The drift between those copies produced wrong QUANTITIES rather than errors, which is why
it was worth doing.

`Lot_Create` carries two real behaviour changes:
- **`Item.MaxLotSize` is now INFORMATIONAL** — an over-size basket creates successfully
  with a note appended to `Message`. `Item.MaxParts` and the consumption-point
  `ItemLocation.MaxQuantity` still reject; they cap what may accumulate at a location,
  which is a real physical constraint.
- **The item-eligibility gate is skipped at a STOCK location** (`IsStockLocation = 1`).
  Eligibility answers "may this part be WORKED here" and storage carries no eligibility
  rows, so every part read as ineligible at the warehouse. Production destinations are
  untouched and still reject.

### Ignition

| Archive | Resources |
|---|---|
| `Core_cutover-scan_2026-09-13_2352.zip` | 43 — `BlueRidge.Cutover.Scan`, `BlueRidge.Common.Barcode`, `Common.Util`, `Common.Session`, 30+ named queries and entity wrappers |
| `MPP_cutover-scan_2026-09-13_2352.zip` | 19 — the cutover screen (breakpoint host + Phone/Tablet/Desktop), `AppHeader*`, `TerminalSelector`, `TrimBody`, Die Cast/Trim How-To popups, the barcode session event |
| `MPP_Config_cutover-scan_2026-09-13_2352.zip` | 6 — `PlantHierarchy`, `Tools`, `ItemMaster`, `DieRanks`, `LocationTypeEditor`, `Assignments` |

Built **from git at HEAD**, not the working tree. All three re-opened and verified
independently: root `project.json`, forward slashes only, no `thumbnail.png` or
`__pycache__`, every manifest promise kept, every `script-python` resource holding only
`code.py` + `resource.json`, and **every payload byte-identical to `HEAD`**. 9 manifests
were rewritten only to drop `thumbnail.png`. No resources were deleted in this range, so
there is nothing to remove by hand in the Designer.

---

## Behaviour changes worth knowing before someone reports them

**1. Gateway logging is much quieter.** `BlueRidge.Common.Util.log()` now defaults to
`debug` instead of `info`. There were ~430 call sites, nearly all function-entry traces,
and at INFO they buried the log. Handled-exception paths were promoted to `warn`, so real
faults still surface. **To get a module's traces back:** Gateway → Status → Diagnostics →
Logs, set e.g. `BlueRidge.Lots.Lot` to DEBUG. Per-module, no redeploy.

**2. `resetTerminal` now lands on the terminal selector** for an unregistered or fallback
terminal, instead of `/shop-floor` — which is not a route in `page-config` and rendered
"View Not Found". Registered terminals still go to their own `DefaultScreen`.

**3. The Inventory Cutover Scan screen is reachable from the Terminal Selector.** See the
risk note below.

---

## 0. Before the window

- Pick a moment with no die-cast entry in flight. The transaction's lock window measured
  **0.5 s** in rehearsal, and it runs at `DEADLOCK_PRIORITY LOW` with a lock timeout — the
  plant wins a deadlock and the release aborts cleanly rather than queueing the plant
  behind it.
- Execute takes a `COPY_ONLY` backup with `VERIFYONLY` before it touches anything. Confirm
  the instance backup path has room.

## 1. Preview (read-only — run it and READ it)

```
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

**What it should print** (verified against `MPP_MES_ProdSim`, built from `d4c29e75` — an
exact prod baseline, `SchemaVersion` = 79, highest `0079`):

```
[3] Pending (2):
      + 0080_cutover_entry_route_and_cast_date.sql
      + 0081_location_is_stock_location.sql
[4] 449 identical, 6 changed, 6 new on the target.
[5] Pre-flight gates -- No gates fired.
[8] 2 migration(s), 12 repeatable(s) in one transaction;
    then R__Descriptions_ExtendedProperties.sql after commit.
Verdict: Clear to deploy. 0 warning(s).
```

**Prod's numbers will differ from the 449/6/6 above** if prod carries any proc the repo
does not, or a hand-patched definition. The script compares **text on the target**, not
commit history, so a larger CHANGED list is information, not an error — read the per-object
diffs it writes to `dist\deploy-reports\...\diffs` before continuing.

**Take the plan fingerprint from YOUR preview.** ProdSim printed `b4a7823cf904`; prod's
will almost certainly differ, because the fingerprint covers the target's own state. Use
the one your preview prints.

**If any gate BLOCKs, stop.** The gates run against live data and exist to catch exactly
the cases a dev database cannot show you.

## 2. Rehearse (applies for real, then rolls back)

```
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint from step 1>
```

Expect, as in rehearsal here:

```
== [1] migration 0080 ... == [2] migration 0081 ... == [3]..[14] repeatables
== verifying inside the transaction
== checks passed
== ROLLED BACK (rehearsal / preview script) -- nothing was kept
REHEARSAL PASSED and was rolled back. Lock window: 0.5s.
```

This proves the migrations and procs apply to **prod's actual rows**, which is the thing
ProdSim cannot prove.

## 3. Execute

```
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <same fingerprint>
```

Backup → deploy script → verify → COMMIT. Any error anywhere rolls the whole release back;
there is no partial state. Note the `.bak` path it prints.

## 4. Ignition: import (Core FIRST)

**Deploy the SQL first.** These views and named queries call procs and read columns that
must already exist. A gateway serving new views against an old schema fails in the worst
way available — a blank field with no error.

Designer **File → Import**, one zip at a time, accepting overwrite:

1. `Core_cutover-scan_2026-09-13_2352.zip`
2. `MPP_cutover-scan_2026-09-13_2352.zip`
3. `MPP_Config_cutover-scan_2026-09-13_2352.zip`

Core first — `MPP` and `MPP_Config` declare `parent: Core` and will not resolve inherited
resources without it. Checklist of every resource:
`dist\ignition-exports\cutover-scan_2026-09-13_2352_CONTENTS.txt`.

**After importing, confirm a `script-python` resource shows as a script, not a folder.**
That single check catches the `__pycache__` class of failure, which no amount of file
listing will.

## 5. Verify

- Re-run the preview: it should say **nothing to do**.
- Gateway log: quieter than before, and no new ERROR/WARN from `BlueRidge.*`.
- A shop-floor terminal loads its default screen and the operator bar works.
- Die Cast entry, Trim and Machining IN queues still list LOTs — these exercise the five
  behaviour-neutral read procs and are the real regression surface of this release.
- Terminal Selector → **Inventory Cutover Scan** opens and a session can be started.

## 6. Rollback

- **SQL:** restore the `COPY_ONLY` backup Execute took. The migrations are additive
  (three nullable columns plus one BIT with a default) so a restore is the clean path; a
  forward-fix is usually preferable to a restore once the plant has written rows.
- **Ignition:** re-import the previous archives, built from the prod baseline:

```
.\tools\Build-ChangeExport.ps1 -Since 515db6c6 -Until d4c29e75 -Label cutover-scan-rollback
```

---

## Risk: the cutover screen is new and only partly exercised

The Inventory Cutover Scan ships **reachable from the Terminal Selector**. As of this
release:

- **Exercised on real hardware:** session setup, cavity tiles, the cast-date stepper,
  camera barcode scanning (Perspective App only — the native action is a no-op in a
  browser), and **one real basket written end to end** (LOT `10627577`, 2016 pcs, correct
  `EntryRouteSequence` so it lands in the Machining IN queue rather than Trim).
- **NEVER exercised:** `addBox` (purchased part) and `voidEntry`. Both share the code path
  that the verified ones use, and `Lot_Create` is proven from SQL with these exact
  parameters, but nobody has completed either action.
- **Known blocked:** the PIN keypad is clipped below 375px, so an operator cannot sign in
  on a phone. Tablets and desktops are fine.

Nothing outside the cutover screen depends on it. If it should not be operator-reachable
yet, pull the `TerminalSelector` resource from the MPP archive and re-import the baseline
copy of that one view — the rest of the release is unaffected.

## Known data issue — NOT fixed in this release

The 2026-08-17 part seed carries two systematic barcode-transcription defects: **20 active
parts use a letter `O` where the label has a digit `0`**, and **8 of those also retain the
AIAG `P` data identifier** on the front of the part number (`P146125GO A000`). All 20 will
fail to scan at cutover — the barcode says `5G0`, the master says `5GO`. They carry 24 BOM
child lines, 2 BOM parents, 41 eligibility rows, 9 routes and **0 LOTs**.

19 of the 20 correct cleanly with no collision. The twentieth (`90701-5RO-3000`) collides
with the correctly-numbered `90701-5R0-3000`, which is a genuine duplicate needing a merge
decision. **If prod was seeded from the same list it has the same 20 defects, and that is a
cutover blocker.** Held out of this release deliberately.

---

## Verified before the run

Built `MPP_MES_ProdSim` from `d4c29e75` in a temp worktree — `SchemaVersion` = 79, highest
`0079`, both `Lots.Lot.EntryRouteSequence` and `LocationTypeDefinition.IsStockLocation`
confirmed **absent**, i.e. an exact prod baseline. Preview: 2 pending migrations, 6 changed
+ 6 new repeatables, no gates fired, clear to deploy. Rehearsal: all 14 steps applied,
checks passed, rolled back in a 0.5 s lock window; `SchemaVersion` back to 79 and
`IsStockLocation` absent afterwards, proving the rollback clean.

Full SQL test suite **3489/3489** on `MPP_MES_Test`, run both before and after the `0081`
change so the baseline was known-clean.

Export archives re-opened and verified byte-for-byte against `HEAD` (87 + 39 + 13 entries),
9 manifests rewritten only to drop `thumbnail.png`.

**Caught and excluded:** an uncommitted `session-props/props.json` in the working tree had
live session data pickled into it by a Designer save (`itemId 10199`, `lineLocationId 172`,
a populated `cavityOptions`). Shipping it would have made every prod session boot with a
phantom cutover session pointing at Dev ids. Restored to HEAD's empty defaults before the
archives were built; the archives carry the clean file.
