# Prod release runbook -- checkweigh tray close for IND570 scales over EPrint

**Release commit:** `5c482c49` on `jacques/working` -- the commit the archives were built and verified from.
**Previous release:** `392947f0` (2026-10-06 08:31, supplier lot; prod's Execute report reads "MPP_MES_Prod is
at this checkout (392947f0)"). Prod is at SQL **`0104`**, 103 migrations applied.
**Rehearsed against:** `MPP_MES_ProdSimEP`, built at `392947f0` -- prod's migration state (103 applied,
highest `0104`, no `ScaleStationEPrint` device type, no `Parts.ContainerConfig_JudgeWeight`). Preview +
Rehearse clean, rollback verified. A full **Execute** was then run against a second sim,
`MPP_MES_ProdSimEP2`, to cover the backup, the post-commit step and the section 6.4 proofs.
`MPP_MES_ProdSimEP` is still at prod's state.
**SQL suite:** 4252 assertions / 4252 passed / 0 failed, run at `5c482c49`.

> **Read this before deciding to ship.** The watcher in this release has **never run on a Gateway or
> against a real scale.** The SQL is proven by the suite and the watcher's logic by an off-Gateway harness
> with Ignition's calls stubbed, but two things are assumed, not observed: that an instance's
> `Message.OpcItemPath` property reads back resolved, and that `system.opc.readValue` returns the current
> message from the TCP driver. The release is **inert until a scale is switched on** (section 5.4), so
> importing it changes nothing on the floor. Switching the first scale on is the real test, and section 6.1
> is written around it. One real press on the Dev Gateway first would remove most of this uncertainty.

> **Assumption to confirm.** This runbook assumes this morning's Ignition imports
> (`supplier-lot_2026-10-06_0819`) were completed on the prod Gateway. The SQL side is on record; the
> imports are not, because that runbook's Outcome section is not filled in. None of the five resources
> below overlap with that import, so an incomplete one does not break this release, but it should be known.

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint's first
> hashed line is the raw `HEAD` sha, so any commit changes it -- a docs-only commit included -- and Execute
> refuses. Re-preview and use the new fingerprint.
>
> **Two separate tests.** A docs-only commit invalidates the fingerprint but leaves the archives valid:
> ```bash
> git diff --stat 5c482c49..HEAD -- ignition/ sql/
> ```
> Expect **no output**. Anything listed means the archives are stale: rebuild them, then re-preview.

---

## 1. What this ships

The IND570 scale terminals have no PLC option card, so the MES cannot read weight or an Under/OK/Over
verdict from them over Modbus. This release adds a second way to read a scale: the terminal prints its
weighment onto its Ethernet port (EPrint demand output), Ignition's TCP driver receives it, and the MES
judges the net weight itself against the part's target weight and tolerance.

For an operator at a scale that has been switched on:

- Pressing the scale's button with a tray on it closes the tray when the net weight is inside the part's
  window, exactly as the existing by-weight close does (same proc path, same genealogy, same container
  completion and label).
- Outside the window, nothing closes and a toast at that terminal says the tray is under or over weight
  and by what limits.
- A part with no by-weight target or tolerance, a scale in the wrong units, or a printout the MES cannot
  read each refuse the close with their own message.

**Nothing changes for any scale, terminal or operator until a scale is switched on by hand** (section 5.4).
The existing Modbus scale type and its watcher are untouched and sit beside the new one.

### SQL -- 1 migration, 1 repeatable

| File | | Effect |
|---|---|---|
| `0105_plcdevicetype_scalestation_eprint.sql` | NEW | One row in `Location.PlcDeviceType`: `ScaleStationEPrint`, closure method `ByWeight`. |
| `R__Parts_ContainerConfig_JudgeWeight.sql` | NEW | Read proc. Returns one row: `Ok` / `Under` / `Over` / `NoConfig` / `NoTolerance` / `NoWeight`, with a message and the limits. Both limits inclusive. |

### Ignition -- 5 resources, no deletions

| Project | | Resource |
|---|---|---|
| Core | NEW | `named-query/parts/ContainerConfig_JudgeWeight` |
| Core | NEW | `script-python/BlueRidge/Workorder/ScaleEPrintWatcher` |
| Core | MOD | `script-python/BlueRidge/Workorder/PlcWatcher` -- one added function, `dispatchMessage` |
| Core | MOD | `script-python/BlueRidge/Parts/ContainerConfig` -- one added function, `judgeWeight` |
| MPP | NEW | `tag-change/ScaleEPrintMessage` -- ships with an **empty** path list |

`MPP_Config` has no changed resources and is not part of this release.

### Not in the archives -- a separate hand import

`ignition/tags/udt/ScaleStationEPrint.json`, the tag UDT. Gateway tags are not project resources. It is
only needed when a scale is switched on (section 5.4).

### In the range but shipping nothing

`sql/tests/` (one new file, one count assertion updated), `ignition/tags/generate_tags.py`,
`ignition/tags/README.md`, `ignition/tags/plc_trigger_tag_paths.txt`, and `notes/`.

---

## 2. What the database change is

| | |
|---|---|
| Migrations | 1 -- `0105_plcdevicetype_scalestation_eprint` |
| Repeatables | 1 new -- `R__Parts_ContainerConfig_JudgeWeight.sql` |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window | 0.1 s (local sim) |

One row inserted into a five-row code table and one new stored procedure. No table, column or index is
created or altered, and no existing row is touched. No release-specific gate was written: the migration
gives the same result whatever state the plant is in.

---

## 3. Risk

### 3.1 Does anything now refuse what it used to allow? -- no

Nothing existing gains a validation. The new refusals (under weight, over weight, missing tolerance) apply
only to a scale that has been mapped to the new type, and no scale is.

### 3.2 Is any of it shared code? -- YES

- **`BlueRidge.Workorder.PlcWatcher`** is the entry point for every PLC-driven close in the plant: the
  camera tray cells, the serialized and non-serialized MIP stations, and the Modbus scales. The change is
  one added function; no existing function is edited. It is still a re-import of the module every one of
  those routes through. Section 6.2 proves a camera cell still books.
- **`BlueRidge.Parts.ContainerConfig`** backs the Item Master Container Config tab and the assembly-out
  pack-out header. Same shape of change: one added function.

### 3.3 Is the schema change metadata-only? -- there is no schema change

One `INSERT` of one row. The visible side effect: **Config Tool -> PLC Devices** reads its device-type list
from this table, so **"Scale Station (EPrint)"** appears as a choice there as soon as the SQL commits.

### 3.4 Does the old Ignition keep working against the new SQL? -- yes, and the reverse

- **New SQL, old Ignition:** nothing calls the new proc; the new type row is just a dropdown entry.
- **New Ignition, old SQL:** the new named query is called only by the new watcher, which only runs for a
  mapped scale. Harmless, but do SQL first anyway.

The SQL step and the imports are independent. There is no rush between them.

### 3.5 What operators will notice on day one

Nothing, until a scale is switched on.

---

## 4. Deploy

Run everything from the repo root of the release checkout.

Password into a masked variable first (it never goes on a command line):

```powershell
$env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
```

### Step 1 -- Preview (read-only, writes nothing)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect (from the local sim; `[2]`, `[6]` and `[7]` will show prod's own values):

```
[2] Connection
  ... MPP_MES_Prod: ONLINE ...

[3] Versioned migrations
  Database: 103 applied, highest 0104. Most recent:
    0104_item_dc_part_level
    0103_container_label_serial_text_and_partext_barcode
    ...
  Pending (1):
    + 0105_plcdevicetype_scalestation_eprint.sql

[4] Repeatables -- target definitions vs this checkout
  499 identical, 0 changed, 1 new on the target.
    NEW      R__Parts_ContainerConfig_JudgeWeight.sql

[5] Pre-flight gates (read-only, against live data)
  No gates fired.

[8] Plan
  1 migration(s), 1 repeatable(s) in one transaction; then R__Descriptions_ExtendedProperties.sql after commit.
  Plan fingerprint: <copy this>

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

**Read `[2]` every time.** It is the only line that names the database you are pointed at.

**If it differs:**

- *More than one pending migration* -- prod is behind where this runbook assumes. Stop and reconcile.
- *Any changed repeatable* -- prod has drifted from git, or something was never deployed. This morning's
  Execute reported every repeatable matching, so a non-zero CHANGED count means something moved since
  08:31. Read the per-object diffs in the report's `diffs` folder before continuing.
- *"already matches this checkout"* -- the SQL is already there. Skip to section 5.
- *A WARN in `[6]`* -- a long transaction is open and will block the deploy's locks. Wait for it.

**Take the fingerprint from this preview.** The local sims both printed `4e0439be076e` at `5c482c49`; yours
will differ because this runbook was committed afterwards. Copy it, do not retype it.

### Step 2 -- Rehearse (runs the real script on live data, then rolls back)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE` when asked. Expect:

```
[10] Running the release transaction
    == transaction open
    == [1] migration 0105_plcdevicetype_scalestation_eprint
    Migration 0105: PlcDeviceType ScaleStationEPrint added.
    Migration 0105 (plcdevicetype_scalestation_eprint) applied.
    == [2] R__Parts_ContainerConfig_JudgeWeight.sql
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept

  REHEARSAL PASSED and was rolled back. Lock window: 0.1s.
```

The lock window on prod will be longer than 0.1 s with the plant running; earlier releases measured 0.2 s
to 2.9 s. **If the rehearsal fails, stop.** It failed against prod's real state and nothing was written.

### Step 3 -- Execute

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <fingerprint>
```

Type `MPP_MES_Prod` when asked. Expect:

```
[9] Backup
  BACKUP DATABASE -> ...\MPP_MES_Prod_pre-release_0104_<stamp>.bak (COPY_ONLY, CHECKSUM)
  Backup written and verified.

[10] Running the release transaction
    == transaction open
    == [1] migration 0105_plcdevicetype_scalestation_eprint
    Migration 0105: PlcDeviceType ScaleStationEPrint added.
    Migration 0105 (plcdevicetype_scalestation_eprint) applied.
    == [2] R__Parts_ContainerConfig_JudgeWeight.sql
    == verifying inside the transaction
    == checks passed
    == COMMITTED

[11] After commit
  R__Descriptions_ExtendedProperties.sql applied.
  Every repo migration is recorded.
  All 1 applied repeatable(s) now match the repo byte-for-byte.

DONE
```

Note the `.bak` path for section 8.

- *`ABORT: plan is <a> but -ExpectedPlan is <b>`* -- something moved since the preview. Re-preview, read the
  new plan, use the new fingerprint. Never `-Force` past it.
- *`FAILED -- the transaction was rolled back`* -- prod is unchanged. Read `deploy.log`. Do not import.

---

## 5. Ignition imports

**Only after Step 3 prints `COMMITTED`.** Designer -> File -> Import, one zip at a time, accepting overwrite
for the listed resources. Do not use the Gateway web page's project import.

Archives, in `dist\ignition-exports\`, built from git at `5c482c49` and verified entry by entry against it
(all 12 entries byte-identical to `HEAD`):

1. **`Core_scale-eprint-watcher_2026-10-06_1153.zip`** -- 4 resources, 9 entries
   - NEW `ignition/named-query/parts/ContainerConfig_JudgeWeight`
   - MOD `ignition/script-python/BlueRidge/Parts/ContainerConfig`
   - MOD `ignition/script-python/BlueRidge/Workorder/PlcWatcher`
   - NEW `ignition/script-python/BlueRidge/Workorder/ScaleEPrintWatcher`
2. **`MPP_scale-eprint-watcher_2026-10-06_1153.zip`** -- 1 resource, 3 entries
   - NEW `ignition/tag-change/ScaleEPrintMessage`
3. **`MPP_Config`** -- nothing to import.

No deletions.

After the Core import, confirm in the Designer that `BlueRidge/Workorder/ScaleEPrintWatcher` shows as a
**script, not a folder**. This is the first release to import a tag-change script as a NEW resource through
a scoped archive; confirm `ScaleEPrintMessage` appears under MPP's Gateway Events -> Tag Change with no
tag paths.

Sessions do not need reloading for this release: no view, stylesheet or session property changed.

### 5.4 Hand steps -- switching ONE scale on (do NOT do this as part of the import)

These are separate from the release and can be done any time after it. **This is the first time this code
runs for real.** Do it on one scale, with someone at the terminal, at a moment when a wrong tray close can
be seen and corrected.

Before starting, on the scale terminal's front panel (see
`notes/2026-08-31_ind570-eprint-commissioning.md`): secondary port `1702`, one Connections row with Port
`EPrint`, Assignment `Demand Output`, the operator button's trigger, `Template 1`. **Clear any stored
tare** unless the tray's tare is meant to be there.

1. **TCP device.** Gateway Config -> OPC UA -> Device Connections: a TCP driver device at
   `<scale-ip>:1702`, Character Based, Field Count 1, Inactivity Timeout 0, writeback off. Press the scale
   button once and confirm `Message` shows the whole printout as one value ending in a line with ` N`.
   If one press produces three separate values, the delimiter is splitting the template and the watcher
   will refuse every press as "no net weight line" or act on fragments -- stop and fix the delimiter first.
2. **UDT.** Designer Tag Browser -> Import `ignition/tags/udt/ScaleStationEPrint.json` into the `MPP`
   provider's `_types_` folder.
3. **Instance.** Create an instance under `[MPP]PlcDevices/` named for the scale. Set `Device` to the TCP
   device's name; leave `BasePath` at `1702/` unless the port differs. Confirm `Message` and
   `LastReceiveTime` read Good. If `MessageBytes` shows a type error, it does not matter to the watcher.
4. **Part config.** In Item Master, give the part a **ByWeight** container config with **both** target
   weight and tolerance set.
5. **Mapping.** Config Tool -> PLC Devices: add the instance path against the scale's assembly-out
   terminal with device type **Scale Station (EPrint)**.
6. **Arm it last.** Designer -> MPP -> Gateway Events -> Tag Change -> `ScaleEPrintMessage`: add the one
   path `[MPP]PlcDevices/<device>/LastReceiveTime`. From this save onward a button press closes trays.

---

## 6. Verification

### 6.1 First -- the thing never seen working

**Before any scale is switched on**, prove the Gateway can reach the new SQL without closing anything.
Designer Script Console (Gateway scope is not needed; this is a read):

```python
print BlueRidge.Parts.ContainerConfig.judgeWeight(-1, "ByWeight", 1.0)
print BlueRidge.Workorder.ScaleEPrintWatcher.parse("  35.13 lb\r\n  16.93 lb T\r\n  18.20 lb N\r\n")
```

Expect a row with `Verdict` = `NoConfig`, then `{'ok': True, 'net': 18.2, 'netText': '18.20', 'uom': 'lb',
'cam': None}` (key order may differ). An `AttributeError` on `ScaleEPrintWatcher` means the Core import did
not land it as a script.

**Do not call `handleMessage` from the console on prod.** It runs the real close and will mint a tray.

**When the first scale is switched on** (section 5.4), with a tray on the scale that should pass:

1. Press the button once. Expect the tray to close at that terminal within a second or two.
2. Read what the watcher recorded:

```sql
SELECT TOP 5 CAST(LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS LoggedET,
       SystemName, Description, RequestPayload, ErrorDescription
FROM Audit.InterfaceLog
WHERE SystemName LIKE N'PLC:%' ORDER BY Id DESC;
```

Expect one `ByWeight tray close` row for the press, with `net=` matching the terminal's display and
`verdict=Ok low=... high=...`.

3. Press again with the **same** tray weight. Expect a second close. (Two identical printouts in a row is
   the case the receive-stamp trigger exists for.)
4. Press with a tray that is clearly light. Expect no close and an "UNDER weight" toast.

**What each wrong result means:**

- *Nothing happens and no InterfaceLog row* -- the tag-change script did not fire. Check the path in step 6
  of 5.4 and that `LastReceiveTime` actually changed.
- *"Scale weighment not read"* -- the direct device read failed. This is the unproven assumption named at
  the top. Remove the tag-change path (section 7) and report it; the fix is in `_readMessage`.
- *The logged `net=` is the PREVIOUS press's weight* -- same area, worse outcome: disarm immediately.
- *"The scale's printout has no net weight line"* -- the TCP delimiter is splitting the template.
- *A close on every press but the weight is always high* -- a stored tare is missing, or the wrong one.

### 6.2 Shared code -- prove a surface that is NOT the feature

`PlcWatcher` was re-imported. After the next camera-cell tray on any vision line, confirm it still booked:

```sql
SELECT TOP 5 CAST(LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS LoggedET,
       SystemName, Description, ErrorDescription
FROM Audit.InterfaceLog
WHERE SystemName LIKE N'PLC:%' ORDER BY Id DESC;
```

Expect rows newer than the import time, with the same descriptions as before it, once a PLC cell has
cycled. **If PLC cells are running and no new rows appear, or camera trays stop closing, treat it as this
release** and go to section 7.

For `Parts.ContainerConfig`: open **Item Master**, pick any finished good, open the **Container Config**
tab. It should load as before.

### 6.3 The feature without a scale

Config Tool -> PLC Devices: the device-type list includes **Scale Station (EPrint)**.

### 6.4 Quick SQL proofs (confirmed on `MPP_MES_ProdSimEP2` after a real Execute)

```sql
SELECT COUNT(*) AS Applied, MAX(MigrationId) AS Highest FROM dbo.SchemaVersion;
```

Expect `104`, `0105_plcdevicetype_scalestation_eprint`.

```sql
SELECT Code, Name, ClosureMethodCode FROM Location.PlcDeviceType ORDER BY Id;
```

Expect 5 rows, the last `ScaleStationEPrint | Scale Station (EPrint) | ByWeight`.

```sql
EXEC Parts.ContainerConfig_JudgeWeight @ItemId = -1, @ClosureMethod = N'ByWeight', @Weight = 1.0;
```

Expect one row, `Verdict` = `NoConfig`.

```sql
SELECT COUNT(*) AS MappingsOnNewType
FROM Location.TerminalPlcDevice d JOIN Location.PlcDeviceType t ON t.Id = d.PlcDeviceTypeId
WHERE t.Code = N'ScaleStationEPrint';
```

Expect `0` straight after the release. Anything else means a scale was already mapped.

---

## 7. Rollback

**Before COMMIT:** automatic. Any error rolls the transaction back and prod is unchanged.

**Disarming a scale -- use this first, it takes seconds.** Either one stops the watcher for that scale and
leaves everything else in place:

- Designer -> MPP -> Gateway Events -> Tag Change -> `ScaleEPrintMessage`: remove the scale's
  `LastReceiveTime` path and save; **or**
- Config Tool -> PLC Devices: deprecate the scale's mapping row.

The operator then closes trays by count as before.

**After COMMIT, SQL:** leave it. One unused device-type row and one uncalled proc. No restore is warranted.

**The Ignition half:** only if section 6.2 fails. Build the previous definitions and import Core:

```powershell
.\tools\Build-ChangeExport.ps1 -Since 5c482c49 -Until 392947f0 -Label scale-eprint-rollback
```

Read its `CONTENTS.txt` before importing; this reversed build has never been used in a real rollback. The
three NEW resources are not removed by it. They are inert without a tag path; delete them in the Designer
if you want them gone.

---

## 8. Outcome -- filled in after the release

_(still to fill in)_

| | |
|---|---|
| Executed at (ET) | |
| Prod before | SQL `0104`, 103 migrations |
| Plan fingerprint | |
| Backup path | |
| Preview `[4]` | |
| Live activity `[6]` | |
| Prod rehearsal lock window | |
| Report folder | |
| 6.1 console checks | |
| 6.2 camera cell still books | |
| First scale switched on (which, when) | |
| 6.1 press results (pass / same weight twice / light tray) | |

**What went differently from the plan:**

_(still to fill in)_
