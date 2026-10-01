# Prod release runbook -- 2026-10-01 die cast reconciliation + Zebra bundle (0096-0102)

**Release commit:** the commit that adds this file, on `jacques/working`. Run everything from that checkout.
**Previous release:** `e3e0aa25` (2026-09-18 bundle, `0090`-`0095`). Prod is at SQL **`0095`**, 94 migrations applied.
**Rehearsed against:** `MPP_MES_ProdSim`, built at `e3e0aa25` -- prod's exact migration state (94 applied,
highest `0095`; `Workorder.ProductionEvent.ShiftId`, `Workorder.DieCastContribution.ShiftAttributionSourceId`
and `Lots.ShippingLabel.LastPrintErrorCondition` all absent). Preview + Rehearse both clean, rollback verified.
**Archives built from:** `1dc270e2`, verified against git.
**SQL suite:** 4219 assertions / 4219 passed / 0 failed / exit 0, zero `ERROR running` lines.

> ## STOP -- read section 3 before scheduling this
>
> This release contains the **die cast shift reconciliation** (`0097`-`0099`), whose acceptance replay has
> **never been run** and whose screen **no human has clicked through**. It also needs **the presses idle**.
> It is prepared, not cleared. Section 3.0 is the precondition list.

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint covers HEAD;
> Execute refuses if anything moved. HEAD being this runbook or a later docs-only commit is fine and expected.
> What matters is that **no deployable moved after the archives were built**:
>
> ```bash
> git diff --stat 1dc270e2..HEAD -- ignition/ sql/migrations/
> ```
>
> Expect **no output**. Anything listed means the archives are stale -- rebuild and re-preview.

---

## 1. What this ships

Three unrelated bodies of work that have accumulated behind one migration sequence. They cannot be split:
migrations deploy contiguously, and a pending migration below the applied high-water mark is a hard `BLOCK`.

**For a die cast team lead.** A new screen reconciles one past shift x press x die against its paper press
sheet -- adds production never entered, re-files entries filed against the wrong shift, and closes numeric
gaps as compensating rows, in one save, one transaction, one audited reconciliation.

**For a trim operator.** A partial trim can be checkpointed at shift end, so a basket that spans a shift
boundary is credited to the shift that actually ran it.

**For anyone at a terminal.** Three things that have been silently broken for six weeks start working: the
Line Inventory panel live-refreshes again, PLC alarms reach the operator, and a shipping label that fails to
print now says so -- a banner naming the fault and a one-time dialog saying what to do about it.

**For whoever configures printers.** A printer can be `ConnectionKind = UsbBridge` and store no endpoint; it
derives from its parent Terminal's `IpAddress` plus port 9100.

### SQL -- 7 migrations

| # | Effect | Cost |
|---|---|---|
| `0096` | `Workorder.ProductionEvent.ShiftId` (nullable FK) -- trim partial checkpoint | metadata-only |
| `0097` | Die cast shift reconciliation tables + reasons | additive |
| `0098` | `CK_RejectEvent_QuantityNonNeg` `WITH CHECK` | **validates every row, whole-table `Sch-M`** |
| `0099` | `DieCastContribution.ShiftAttributionSourceId` `NOT NULL DEFAULT` | **table rewrite on Standard Edition, whole-table `Sch-M`** |
| `0100` | `Location.SessionPolicy.ElevationMaxSeconds` | metadata-only |
| `0101` | Printer `ConnectionKind = UsbBridge`; `Endpoint.IsRequired` 1 -> 0 | seed/attribute only |
| `0102` | `Lots.ShippingLabel.LastPrintErrorCondition` (nullable) | metadata-only |

`0092` remains a deliberate numbering gap.

### SQL -- repeatables

**459 identical, 17 changed, 23 new.** New: `ufn_PrinterEndpoint`, `ufn_DieCastLotCountLock`,
`ufn_ShiftNeighbours`, `ufn_DieCastShiftStamp`, `DieCastLot_Mint`, `DieCastLot_ReleaseMove`,
`DieCastLot_ResolveLtt`, `Lot_ApplyPieceCountCorrection`, `DieCastCredit_Write`, `DieCastEntry_Restamp`,
`DieCastReconciliationReason_List`, `DieCastScrap_Write`, `DieCastShift_ListUnreconciled`, the eight
`DieCastShiftReconciliation_*`, `TrimCheckpoint_GetLatestForLot`, `TrimPartial_Record`.
Changed: `Location_SaveAll`, `Printer_GetById`, `PrinterFgAssignment_ListForStation`, `SessionPolicy_Get`,
`SessionPolicy_Update`, `Terminal_GetPrinter`, `DieCastLot_Open`, `DieCastLot_Release`, `Lot_Get`,
`Lot_RectifyPieceCount`, `Lot_SearchAdvanced`, `ShippingLabel_GetForBanner`, `ShippingLabel_MarkDispatch`,
`ShiftOverride_Restamp`, `DieCastCounterAnchorReason_List`, `DieCastShiftOutput_Record`, `TrimOut_Record`.

Post-commit, outside the transaction: `R__Descriptions_ExtendedProperties.sql` (documentation only; a failure
there is a WARN and the release stands).

### Ignition -- 66 resources, no deletions

| Archive | Resources | Entries |
|---|---|---|
| `Core_diecast-zebra-bundle_2026-10-01_1350.zip` | 36 | 73 |
| `MPP_diecast-zebra-bundle_2026-10-01_1350.zip` | 28 | 57 |
| `MPP_Config_diecast-zebra-bundle_2026-10-01_1350.zip` | 2 | 5 |

Full `NEW`/`MOD` list per project: `dist/ignition-exports/diecast-zebra-bundle_2026-10-01_1350_CONTENTS.txt`.
**No resources were deleted in this range**, so there is no by-hand deletion step.

### In the range but shipping nothing

`docs/`, `notes/`, `sql/tests/`, `sql/scripts/` (including `Deploy-ProdRelease.ps1`'s new gates -- tooling,
not a deployable), `reference/`, `zebraPrinter/` (the `MesZebraBridge` service deploys per-terminal at
commissioning, not through this release), `ignition-context-pack/`, `prod-release-context-pack/`.

---

## 2. What the database change is

| | |
|---|---|
| Migrations | 7 -- `0096` through `0102` |
| Repeatables | 40 -- 23 new, 17 changed |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window | **1.2 s on ProdSim -- see the warning below** |

**The ProdSim lock window is not a prediction.** `MPP_MES_ProdSim` is built from migrations and seeds, so it
holds **0 `RejectEvent` rows and 0 `DieCastContribution` rows**. The two expensive operations in this release
scale with exactly those counts, so 1.2 s is a floor, not an estimate. Prod's preview prints the real counts
in the `[5]` gates -- read them before you commit to a window. For reference, the 2026-09-18 release measured
0.4 s on ProdSim and **9.3 s** on prod with no table rewrite at all.

---

## 3. Risk

### 3.0 Preconditions -- this release is prepared, not cleared

| # | Must be true before scheduling | Why |
|---|---|---|
| 1 | The die cast reconciliation acceptance replay against the 2026-09-17 Machine 11 press sheet has been run | Every expected figure traces to a real production row, but **execution is owed**. Needs VPN + a credential, or a restored prod backup. |
| 2 | A human has clicked through the die cast reconciliation screen | Task 13's live smoke was cut off by the Perspective trial expiring. Everything past Scenario A is **source-verified only**. |
| 3 | A window with **the presses idle** is agreed | `0098` and `0099` both take whole-table `Sch-M` locks (below). |
| 4 | The preview's `[5]` gates are read, including the two new row counts | They are the only real estimate of the lock window. |

**Do not treat 1 and 2 as formalities.** `PROJECT_STATUS.md` records two open limitations that will surface on
a first real shift: a cavity `Blocked` today but running during the reconciled shift falls outside the cavity
set and produces a refusal the team lead **cannot satisfy**; and production's family dies repeat cavity
letters per part, which the reject-line span arithmetic has never met (the fixture die has two cavities).

### 3.1 Test 1 -- does anything now refuse what it used to allow?

**Yes, two.**

- **`Location.Location_SaveAll` v1.4 now refuses a `Networked` or `Hardwired` printer saved with a blank
  `Endpoint`.** `0101` relaxes the definition-level `IsRequired` flag to 0 so a `UsbBridge` printer can store
  nothing, and the requirement **moves into the proc**, which can see the sibling `ConnectionKind`. Net effect
  for a config user: unchanged for the three live `Networked` printers, newly permissive for `UsbBridge`. The
  trap this avoids is a Networked printer saving with no address and failing silently at dispatch.
- **`Lots.Lot_RectifyPieceCount` and `Lot_Update`** both changed. Both already refused a `Closed` /
  `BlocksProduction` LOT and a no-op quantity; re-read their guards before chaining them.

### 3.2 Test 2 -- is any of it shared code?

**Yes, and this is the widest-blast-radius item in the release.**

- **`BlueRidge.Workorder.PlcWatcher.broadcastPageMessage`** is the gateway's only fan-out to operator screens
  and is shared by three features. It has delivered **nothing since 2026-08-20** (it filtered page ids through
  a UUID test; Perspective page ids are short hex). Fixing it means **Line Inventory live-refresh resumes and
  PLC alarm toasts start appearing** on screens nobody changed. Expected, correct, and new to every operator.
- **`Common.Session`** (elevation ceiling, `0100`) is on the path of every elevated action -- downtime reason,
  downtime edit, downtime void, sort-cage migrate, CRT toggle. Section 6 verifies one of these deliberately.
- **`Lots.Lot_Get` and `Lot_SearchAdvanced`** are read by most shop-floor surfaces.

### 3.3 Test 3 -- is the schema change metadata-only?

**No. Two of the seven are not, and both block the plant while they run.**

- **`0098`** adds `CK_RejectEvent_QuantityNonNeg` `WITH CHECK`, so SQL Server validates **every existing row**
  before trusting the constraint. The scan is **not partition-aware**: it reads every partition of
  `Workorder.RejectEvent` under a whole-table `Sch-M` lock, blocking every scrap write and reject report for
  its duration. `RejectEvent` is **not** in `Audit.PartitionRetention`, so it only grows -- this is as cheap
  as it will ever be.
- **`0099`** adds a `NOT NULL ... DEFAULT` column to `Workorder.DieCastContribution`. That is metadata-only on
  Enterprise and a **full table rewrite on Standard Edition**, which this instance is. Same lock; die cast
  entry and release block for the duration.

A new BLOCK gate catches the one way `0098` can burn a window: any `RejectEvent.Quantity < 0` fails the
`ALTER` and rolls the entire release back. The gate reports the count and writes the first five to
`rejectevent_negative_quantity.csv`.

`0102` is genuinely metadata-only -- nullable, no default, unpartitioned table.

### 3.4 Test 4 -- does the old Ignition keep working against the new SQL?

**Yes -- in that order only, and the order is load-bearing here beyond the usual reason.**

`ShippingLabel_MarkDispatch` gains `@ErrorCondition NVARCHAR(50) = NULL`. Because it is **optional with a
default**, prod's current Ignition keeps calling it successfully after the SQL lands. The reverse is not true:
if the Ignition archives were imported first, the new named query would pass a parameter the old proc does not
declare and **every dispatch outcome would fail to record**. SQL first is not a nicety in this release.

So the SQL step and the import step are independent, and there is no rush between them.

### 3.5 What operators will notice on day one

- Print failures become **visible** -- a banner plus a one-time dialog per label. They were silent before.
- PLC alarm toasts appear. Only three call sites can fire today ("Label not printed", warning, 8 s; "Scale
  setpoint load failed" x2, error, persists until clicked). The other 17 are behind `_WATCH = []` and stay
  dark until PLC commissioning.
- The Line Inventory panel starts updating by itself again.

---

## 4. Deploy

### Step 1 -- Preview (read-only, writes nothing)

```powershell
$env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect, section by section (ProdSim's values; prod's `[5]` counts will be real numbers, not zeros):

```
[3] Versioned migrations
  Pending (7):
    + 0096_trim_partial_checkpoint.sql
    + 0097_diecast_shift_reconciliation.sql
    + 0098_rejectevent_quantity_nonneg.sql
    + 0099_diecast_shift_attribution_source.sql
    + 0100_session_policy_elevation_max.sql
    + 0101_printer_usbbridge_connectionkind.sql
    + 0102_shippinglabel_print_error_condition.sql

[4] Repeatables -- target definitions vs this checkout
  459 identical, 17 changed, 23 new on the target.

[5] Pre-flight gates (read-only, against live data)
  [WARN] 0098: validates <N> Workorder.RejectEvent row(s) under a whole-table Sch-M lock ...
  [WARN] 0099: rewrites Workorder.DieCastContribution (<N> row(s)) ...
  [INFO] 0102: adds Lots.ShippingLabel.LastPrintErrorCondition (nullable, metadata-only). <N> label(s) ...

  Clear to deploy. 2 warning(s) to read above.
```

**If it differs from the above:**

- *Pending is not exactly `0096`-`0102`* -- prod is not where this runbook assumes. **Stop and reconcile**
  against `notes/2026-09-18_prod-release-runbook-bundle.md`'s Outcome before continuing.
- *More than 17 changed repeatables* -- prod has drifted from git, or a commit landed that was never deployed.
  The script compares **text on the target**, not commit history. Per-object diffs are in the report's
  `diffs/` folder. A larger list is information, not automatically an error, but this runbook no longer
  describes what you are about to do.
- *`[5] 0098` BLOCKs on negative quantities* -- **stop.** `0098` aborts on exactly this and the release rolls
  back. **There is no reversal path through a proc**: `RejectEvent_Record`, `TrimOut_Record`,
  `TrimPartial_Record` and `MachiningOut_Mint` all refuse `Quantity <= 0`, so no live path can have written
  them. Establish what did, then correct or attribute them. The offenders are in the report's
  `rejectevent_negative_quantity.csv`.
- *The `0098` / `0099` row counts are large* -- this is the window estimate. Re-check the presses are idle.
- *`[6]` shows open baskets or a running shift* -- the die-cast tables are frozen with `TABLOCKX` for the
  whole transaction. That is survivable but it is exactly what makes the lock window matter.
- *Any gate BLOCKs* -- stop. `-Force` skips the typed confirmation, not the gates. There is no flag that
  deploys past a BLOCK.

**Copy the plan fingerprint. Do not retype it.** A dropped character aborted a window on 2026-09-12 and again
on 2026-09-18. ProdSim's was `ef6e2f8b766a`; **prod's will differ**, because the fingerprint covers the
target's own state as well as HEAD. Use the one your preview printed.

### Step 2 -- Rehearse (runs the real script on live data, then rolls back)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint-from-step-1>
```

Expect 47 step markers, then:

```
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept
  REHEARSAL PASSED and was rolled back. Lock window: N.Ns.
```

**Note the lock window.** ProdSim was 1.2 s with empty tables; prod's is the number that matters, and it is
roughly what Execute will take.

**If the rehearsal fails, stop.** It failed against prod's actual rows, which is the one thing no amount of
local testing simulates. Nothing was written.

### Step 3 -- Execute

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <same-fingerprint>
```

Type the database name when prompted. `[9]` takes a `COPY_ONLY` + `CHECKSUM` backup and verifies it before
anything is written -- **record the path from `backup.txt` in section 8**. `[10]` runs the transaction. `[11]`
runs the extended-properties documentation outside it, then proves every migration is recorded and every
repeatable matches the repo byte-for-byte.

Ends with: `Import the Ignition exports NOW -- Core first.`

---

## 5. Ignition imports

**SQL first (done above). Then Core, then MPP, then MPP_Config.** Core first because `MPP` and `MPP_Config`
both declare `"parent": "Core"` and will not resolve inherited resources without it -- and every named query
lives in Core.

**Designer -> File -> Import**, one zip at a time, accepting overwrite for the listed resources.
**Do not use the Gateway web page's project import** -- these are partial exports, not whole projects.

1. `Core_diecast-zebra-bundle_2026-10-01_1350.zip` -- 36 resources
2. `MPP_diecast-zebra-bundle_2026-10-01_1350.zip` -- 28 resources
3. `MPP_Config_diecast-zebra-bundle_2026-10-01_1350.zip` -- 2 resources (`Views/Audit/Users`,
   `Views/Location/PlantHierarchy`)

Tick each resource off against `diecast-zebra-bundle_2026-10-01_1350_CONTENTS.txt`.

**Two import slips from 2026-09-18 that cost time -- do not repeat them:**

- A **full-project** export was opened by mistake (it listed Reports, Session Props, Global Props, Session
  Event Scripts). If the import dialog lists any of those, it is the wrong file. Cancel.
- The **MPP_Config archive was imported into Core**, landing its views in the wrong project. Check the target
  project in the dialog before confirming each one.

4. **Reload every open Perspective session.** F5 on each shop-floor workstation screen -- not the Designer. A
   session left open across a project update can come back with stale bindings. This matters more than usual
   here: the print-failure banner keeps per-session state, and the broadcast fix only reaches a session whose
   page has re-registered its handlers.

**No resources were deleted in this range**, so there is no by-hand deletion step.

---

## 6. Verification

Ordered by risk, not by the order things were built.

### 6.1 First -- the two things that were never proven end-to-end

**(a) The die cast reconciliation screen has never been driven by a human, and its acceptance replay has never
been run.** The SQL suite covers the procedures (4219 assertions) and Task 10's real save is in the database,
but the 2026-09-30 smoke was cut off by the Perspective trial and everything past Scenario A is
**source-verified only**. Reconcile one real past shift end to end and confirm the header row, the
`DieCastContribution` rows tagged `ShiftAttributionSourceId = Reconciled`, the `DieCastCounterAnchor` reason
`ShiftReconciliation`, and the `Audit.OperationLog` row (**not** `ConfigLog`).

**(b) The print-failure path was verified on a Dev screen, not prod hardware.** On a terminal with a printer,
force a failure (stop the `MesZebraBridge` service, or point the terminal at a dead address) and confirm the
banner names the fault and the dialog appears **once**, not every five seconds.

### 6.2 Shared code -- prove a surface that is NOT the feature

`Common.Session` is on every elevated action's path. Do one elevated action that has nothing to do with this
release -- **void a downtime event** -- and confirm the credential prompt appears, the action completes, and
the audit row names the approver.

### 6.3 The broadcast fix

Open a shop-floor screen with the Line Inventory panel and close a tray from another terminal. The panel
should update **without a refresh**. This is the six-week-dead path; if it still does not update, the import
did not take or the sessions were not reloaded.

### 6.4 Printer endpoint derivation (`0101`)

On Plant Hierarchy, open a `UsbBridge` printer with no stored endpoint and press **Test printer**. It should
report the queue the bridge is bound to, having derived `<terminal IpAddress>:9100`. A `Networked` printer
must still resolve from its stored endpoint.

### 6.5 Quick SQL proofs

```sql
SELECT COUNT(*) AS Applied, MAX(MigrationId) AS Highest FROM dbo.SchemaVersion;   -- 101 / 0102_shippinglabel_print_error_condition
SELECT COL_LENGTH('Lots.ShippingLabel','LastPrintErrorCondition');                -- not NULL
SELECT COL_LENGTH('Workorder.DieCastContribution','ShiftAttributionSourceId');    -- not NULL
SELECT name, is_not_trusted FROM sys.check_constraints WHERE name = 'CK_RejectEvent_QuantityNonNeg'; -- is_not_trusted = 0
```

---

## 7. Rollback

**Before the commit** -- automatic. Any failed step, a moved die watermark, or a lock timeout aborts the
transaction and `MPP_MES_Prod` is unchanged. Nothing to do.

**After the commit** -- `0098` and `0099` are **not** cheaply reversible: one validates a constraint across
the table and the other rewrites it. Rollback means **restoring the `COPY_ONLY` backup from `[9]`**, which
loses every row written since. For anything short of data corruption, **prefer fixing forward** -- the
repeatables are all `CREATE OR ALTER` and can be re-applied from an earlier commit.

**The Ignition half rolls back independently of SQL.** Re-import the previous release's archives
(`dist/ignition-exports/*_2026-09-18_*`) over the top, Core first, then reload sessions. Because the new proc
parameter is optional, prod's **old** Ignition works fine against the **new** schema -- so reverting only the
Ignition half is a safe, complete, and fast mitigation if a screen misbehaves. Reach for this before
considering a database restore.

---

## 8. Outcome -- filled in after the release

_(still to fill in)_

| | |
|---|---|
| Executed at | |
| Prod before | SQL `0095`, 94 migrations |
| Plan fingerprint | |
| Backup path | |
| Preview `[3]` | |
| Preview `[4]` | |
| Gates `[5]` | |
| Live activity `[6]` | |
| Prod rehearsal lock window | |
| Execute duration | |
| Report folder | |

**What went differently from the plan:**

_(still to fill in)_
