# Prod release runbook -- Digi One SP scale feed

**Release commit:** `56e68d2f` on **`release/2026-11-19-digi-scale-feed`**, cut from prod's last release `96651770` (the 2026-11-04 bundle, executed 2026-11-05). **Run every command from that branch.** It carries only this change: the same code as PR BR-Customers/MPP#36, **without** the stored-procedure review (`0118`, `0120`-`0133`), which stays on `main` and ships later (Jacques, 2026-11-19).
**Previous release:** `96651770`. Prod is expected at **116 migrations, highest `0117`**.
**Rehearsed against:** `MPP_MES_ProdSimDigiRel`, built at `96651770`: 116 migrations, highest `0117`, `Workorder.ScalePendingPress` absent. A full Execute ran on a second sim, `MPP_MES_ProdSimDigiRel2`.
**The SP review after this one:** add `-AllowOutOfOrder 0118,0120,0121,0122,0123,0124,0127,0128,0129,0130,0133` to its commands (note at the top of its runbook). Proven on `MPP_MES_ProdSimDigiRel2` after this release's Execute: without the list, 11 out-of-order BLOCKs; with it, clear with 11 WARNs, and the rehearsal applied 11 migrations + 22 procs and rolled back (0.3 s).
**Spec:** `docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md`. **Findings:** `notes/2026-11-19_digi-one-sp-scale-capture.md`.

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint's first hashed line is the raw HEAD sha, so **any** commit changes it, a docs-only commit included, and Execute refuses. Re-preview and use the new fingerprint.
>
> **Two separate tests, two separate answers.** A docs-only commit invalidates the **fingerprint** but leaves the **archives** valid:
> ```bash
> git diff --stat 56e68d2f..HEAD -- ignition/ sql/
> ```
> Expect **no output**. Anything listed means the archives are stale: rebuild them, then re-preview.

---

## 1. What this ships

An Assembly Out By Weight scale can now be read through a **Digi One SP** on the IND570's serial port, as well as through EPrint. The scale's own TaskExpert program sends one record per **good** press:

```
(NET)15.5<UOM>LB<TWM>1<Part>TEST3
```

**The scale decides** (Jacques, 2026-11-19):
- **Good:** TWM=1 closes the tray. The MES still compares the weight with its own window; a disagreement is logged for supervisors and never blocks.
- **Part:** `<Part>` is matched to an MES part number. A different part than the one running switches the station's running part (audited). That switch is refused while another part's box is open: a box never mixes parts.
- **A part code that is no MES part:** if the part is already settled (open box, or an operator's override) the tray closes as that part and a warning is logged. Otherwise the press is **held**, and the scale station screen shows "Tray waiting: ... Choose the part" with one button per part that can run, plus Discard. The tap closes the tray. While a press is held, further presses at that scale are refused ("A tray is waiting for its part").

**Nothing changes for any scale today.** A head moves onto the Digi path only when it is commissioned (section 7). EPrint scales keep their watcher unchanged.

| SQL | |
|---|---|
| Migration | `0134_scale_digi_and_pending_press`: `PlcDeviceType` `ScaleStationDigi`; `Workorder.ScalePendingPressStatus` + `Workorder.ScalePendingPress`; three `Audit.LogEventType` rows |
| New procs | `Workorder.ScalePendingPress_Hold`, `_GetForTerminal`, `_Claim`, `_Release`, `_Complete`, `_Discard` |
| Changed procs | none |

| Ignition | NEW | MOD |
|---|---|---|
| Core (10) | NQs `workorder/ScalePendingPress_{Claim,Complete,Discard,GetForTerminal,Hold,Release}`; script `BlueRidge/Workorder/ScaleDigiWatcher` | scripts `BlueRidge/Sim`, `BlueRidge/Workorder/PlcWatcher`, `BlueRidge/Workorder/ScaleStation` |
| MPP (4) | views `Components/PlantFloor/ScaleStationPendingPress`, `ScaleStationPendingButton` | views `Components/PlantFloor/ScaleStation`, `Views/Dev/ScaleStationSim` |
| MPP_Config | no changed resources -- not part of this release | |

In the range but ships nothing: docs, `tools/test_scale_digi_watcher.py`, `sql/tests/0134_ScaleDigi/*`, `ignition/tags/instances/digiTest.json` (Dev tag instance; tags are not in the archives), the `Deploy-ProdRelease.ps1` gates.

## 2. What the database change is

| | |
|---|---|
| Migrations | 1 -- `0134_scale_digi_and_pending_press` |
| Repeatables | 6 -- all new, 0 changed |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only; adds the two new tables' descriptions) |
| Rehearsal lock window | 0.1 s |

Cheap: one row in a code table, two new empty tables, three event-type rows, six new procs. No existing table, row or proc changes.

## 3. Risk

**Low for this release; the risk is in commissioning.** No existing code path changes: `PlcWatcher.dispatchMessage` routes `ScaleStationEPrint` exactly as before and only adds a `ScaleStationDigi` branch. The `ScaleStation` screen gains a banner that is hidden unless a press is held, which cannot happen until a Digi head is commissioned.

When a head is commissioned, the new behaviour is real: a press whose part code is not an MES part number waits on screen for the operator. If a head's codes are free text (some target tables carry rows like `Inner Housing`), every press on those parts will need a tap. Section 7 step 4 finds that out before go-live.

SQL suite on the release branch: **5,638 / 5,638** on a fresh build (prod's state plus +27 in `0134_ScaleDigi`). On `main` with the SP review: 5,840 / 5,840. Python: 60 / 60 (`tools/test_scale_digi_watcher.py`); `tools/test_scale_eprint_watcher.py` passes unchanged.

## 4. Deploy (SQL)

Set the password once (never on the command line):

```powershell
$env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
```

### Step 1 -- Preview (read-only)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect (from the sim):

```
[3] Versioned migrations
  Database: 116 applied, highest 0117.
  Pending (1):
    + 0134_scale_digi_and_pending_press.sql
[4] Repeatables -- target definitions vs this checkout
  612 identical, 0 changed, 6 new on the target.
    NEW      R__Workorder_ScalePendingPress_{Claim,Complete,Discard,GetForTerminal,Hold,Release}.sql
[5] Pre-flight gates
  [INFO] 0134: adds PlcDeviceType ScaleStationDigi and the held-press tables; no existing row changes. N scale device mapping(s) exist today and are untouched ...
[8] Plan
  1 migration(s), 6 repeatable(s) in one transaction; then R__Descriptions_ExtendedProperties.sql after commit.
  Plan fingerprint: <12 hex>
Verdict
  Clear to deploy. 0 warning(s) to read above.
```

The sim printed `8a4279341879` at `56e68d2f`. Prod prints the same value only if HEAD is still `56e68d2f` and prod is at the sim's state; a match corroborates, a difference is not an error. **Use the fingerprint YOUR preview printed. Copy it, do not retype it.**

**If it differs:**
- *Pending shows more than `0134`* (e.g. `0118`) -- you are on the wrong branch. Run from `release/2026-11-19-digi-scale-feed`.
- *Not 116 applied / highest not `0117`* -- prod is not where this runbook assumes. Stop and reconcile.
- *More than 6 NEW or any CHANGED repeatable* -- prod has drifted from git, or something landed that was never deployed. Read the report's `diffs` folder before continuing.
- *`[5]` BLOCK "already exists but 0134 is not recorded"* -- someone created the tables by hand. Stop.
- *`[6]` shows an open transaction* -- wait for it, or pick a quieter moment.

### Step 2 -- Rehearse (applies, verifies, rolls back)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE`. Expect:

```
    == transaction open
    == [1] migration 0134_scale_digi_and_pending_press
    Migration 0134: PlcDeviceType ScaleStationDigi added.
    Migration 0134 (scale_digi_and_pending_press) applied.
    == [2] R__Workorder_ScalePendingPress_Claim.sql
    ... [3]-[7] the other five procs
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept
  REHEARSAL PASSED and was rolled back. Lock window: 0.1s.
```

If the rehearsal fails, **stop**: it failed against prod's actual data, which local testing cannot simulate.

### Step 3 -- Execute

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <fingerprint>
```

Type `MPP_MES_Prod`. Expect `[9] Backup ... Backup written and verified.`, the same step markers ending `== COMMITTED`, then:

```
[11] After commit
  R__Descriptions_ExtendedProperties.sql applied.
  Every repo migration is recorded.
  All 6 applied repeatable(s) now match the repo byte-for-byte.
DONE
```

Note the backup path from `[9]` in section 8.

## 5. Ignition imports -- SQL first, then Core, then MPP

Designer -> File -> Import, one zip at a time, accept overwrite. **Not** the Gateway web page's project import.

1. `dist\ignition-exports\Core_digi-scale-feed-rel_2026-11-19_1432.zip` -- 10 resources (6 NQs + ScaleDigiWatcher NEW; Sim, PlcWatcher, ScaleStation MOD).
2. `dist\ignition-exports\MPP_digi-scale-feed-rel_2026-11-19_1432.zip` -- 4 resources (ScaleStationPendingPress, ScaleStationPendingButton NEW; ScaleStation, Views/Dev/ScaleStationSim MOD).
3. MPP_Config: nothing.
4. F5 every open Assembly Out screen.

Checklist with commits per resource: `dist\ignition-exports\digi-scale-feed-rel_2026-11-19_1432_CONTENTS.txt` (built on the release branch).

## 6. Verification

1. **First, the one hop never verified before shipping: a real Digi press through the TCP driver into the watcher.** On Dev every press was simulated (the simulator hands the record to the same `ScaleDigiWatcher.handleMessage` a real press reaches; only the TCP receive and the `MessageBytes` OPC read were skipped). This is checked at commissioning (section 7, step 4), not at deploy.
2. SQL, against prod (confirmed on the executed sim):

```sql
SELECT COUNT(*) AS Applied, MAX(MigrationId) AS Highest FROM dbo.SchemaVersion;        -- 117, 0134_scale_digi_and_pending_press
SELECT Code, ClosureMethodCode FROM Location.PlcDeviceType WHERE Code = N'ScaleStationDigi';  -- ScaleStationDigi, ByWeight
SELECT STRING_AGG(CONCAT(Id, N'=', Code), N',') WITHIN GROUP (ORDER BY Id) FROM Workorder.ScalePendingPressStatus;  -- 1=Pending,2=Closed,3=Discarded
SELECT COUNT(*) FROM Workorder.ScalePendingPress;                                        -- 0
SELECT COUNT(*) FROM Audit.LogEventType WHERE Code LIKE N'ScalePress%';                 -- 3
SELECT COUNT(*) FROM sys.procedures WHERE name LIKE N'ScalePendingPress[_]%';           -- 6
```

3. **Not the feature:** open the Assembly Out screen on the 6MA oil pan line (the EPrint scale terminal). The scale station shows as before, with no banner. A ByCount line's Assembly Out screen closes a tray as before.

## 7. Commissioning a scale head onto the Digi (per head, after the release)

1. Digi One SP on the scale's serial port, raw TCP port 2101. **It accepts one client at a time**: close any PowerShell capture first.
2. Gateway: a TCP driver device for the Digi. **Character Based, delimiter `\r` (backslash r)**, Field Count 1, Inactivity Timeout 0, writeback off.
3. Designer, Tag Browser: import a UDT instance of `ScaleStationEPrint` (same three members) named for the head, `Device` = the TCP device name, `BasePath` = the port folder (`2101/`; confirm in the OPC browser). `ignition/tags/instances/digiTest.json` is the Dev example. Add the instance's `.../LastReceiveTime` path to the `ScaleEPrintMessage` gateway tag-change script's paths. Map the terminal:

```sql
DECLARE @T BIGINT = (SELECT Id FROM Location.PlcDeviceType WHERE Code = N'ScaleStationDigi');
EXEC Location.TerminalPlcDevice_Save @TerminalLocationId = <terminal>, @PlcDeviceTypeId = @T,
     @DeviceCode = N'<device>', @UdtInstancePath = N'[MPP]PlcDevices/<instance>', @SortOrder = 1, @AppUserId = <your AppUser Id>;
```

   If the terminal still maps an EPrint scale for the same head, deprecate that row (`Location.TerminalPlcDevice_Deprecate`) so one head is not read twice.
4. **One press per part in the head's target table.** For each, read the newest interface-log row:

```sql
SELECT TOP 5 LoggedAt, Description, ErrorCondition, LotId, RequestPayload
FROM Audit.InterfaceLog WHERE LocationId = <terminal> ORDER BY Id DESC;
```

   `"partSource":"Scale"` means the code matched a part number: good. `ScaleFlagsHeld` means it did not, so the operator will have to tap every press of that part. Fix the code at the scale (target table ID = the MES part number), or accept the tap for that part.
5. Each production head needs its own capture: a different `.cpt` may send a different record. A record the parser cannot read is refused and logged as `Scale weighment not understood` with the raw text.

## 8. Rollback

- **Before commit** (preview, rehearsal, or a failed execute): nothing to undo.
- **After commit, SQL:** leave it. Everything 0134 adds is inert until a head is mapped as `ScaleStationDigi`. Restoring the `[9]` backup would discard plant data written since; only for a catastrophic failure.
- **Ignition:** import `Core_digi-scale-feed-rel-ROLLBACK_2026-11-19_1432.zip` (3: Sim, PlcWatcher, ScaleStation) then `MPP_digi-scale-feed-rel-ROLLBACK_2026-11-19_1432.zip` (2: ScaleStation view, Views/Dev/ScaleStationSim). Imports cannot delete, so in the Designer delete by hand: Core NQs `workorder/ScalePendingPress_*` (6) and script `BlueRidge/Workorder/ScaleDigiWatcher`; MPP views `Components/PlantFloor/ScaleStationPendingPress` and `ScaleStationPendingButton`. Before doing that, deprecate any `ScaleStationDigi` terminal mapping (a mapped Digi with no watcher logs a warning per press and closes nothing).

## 9. Outcome -- filled in after the release

| | |
|---|---|
| Executed at (ET) | _(still to fill in)_ |
| Prod before | |
| Plan fingerprint | |
| Preview / rehearsal as expected? | |
| Lock window | |
| Backup path | |
| Report folder | |
| Imports | |
| Notes | |
