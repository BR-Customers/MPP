# Prod release runbook: 2026-09-11 (6MA CH parallel run + station boxes)

This release ships everything on `jacques/working` that prod does not have yet. On the
SQL side that is migrations **0078** (open boxes belong to a station; committed this
afternoon, never deployed) and **0079** (terminal `SuppressAimAndLabel`), plus the three
procs that changed with them. On the Ignition side it is 6 Core resources and 1 MPP view.
When it is done, the 6MA CH camera cell books trays in the MES while legacy stays the
system of record: no PLC writes, no AIM serials, no Honda labels from the MES.

Background: `notes/2026-09-11_6ma-ch-real-ladder-slcpasspulse.md` (why, and the address
map) and the 2026-09-11 (late afternoon) entry in `PROJECT_STATUS.md`.

**Risk: low.** Both migrations are additive: a nullable column, a filtered index and one
attribute-definition row. Every changed proc behaves exactly as before for a caller that
does not use the new behaviour: `Container_Complete` changes only on a terminal with the
attribute set, and `Assembly_CompleteTray` / `Container_GetOpenByCell` keep the old
line-wide rule when no terminal is passed. **The Ignition currently on prod keeps working
against the new SQL**, so there is no rush between the SQL step and the imports. Do it
in a quiet window anyway.

---

## What ships

| Layer | Item | Effect |
|---|---|---|
| SQL | `0078_container_station` | `Lots.Container.StationLocationId` (nullable FK) + filtered index |
| SQL | `0079_terminal_suppress_aim_label` | Terminal attribute `SuppressAimAndLabel` (BIT, default 0) |
| SQL | `Lots.Container_Complete` v1.2 | Suppressed terminal: complete + close FG LOTs, no AIM claim, no label row |
| SQL | `Workorder.Assembly_CompleteTray` v1.4 | Box resolved per station (0078) |
| SQL | `Lots.Container_GetOpenByCell` v1.1 | Optional station / closure-method filters (0078) |
| Core | `Workorder/TrayInspectionWatcher` | New `SlcPassPulse` protocol + `DisableWriteback` |
| Core | `Workorder/PlcWatcher` | Comment only |
| Core | `Workorder/Assembly` | Station boxes (0078) + clean return on a suppressed completion |
| Core | `Lots/Container`, `Location/PrinterFgAssignment`, NQ `lots/Container_ListOpenForStation` | Station boxes (0078) |
| MPP | `ShopFloor/AssemblyNonSerialized` | Part dropdown drives the box; "Open boxes:" line (0078) |

Zips (built from git, verified structurally and byte-identical to HEAD):
`dist\ignition-exports\Core_6ma-parallel-run_2026-09-11_1409.zip`,
`dist\ignition-exports\MPP_6ma-parallel-run_2026-09-11_1409.zip`,
checklist `6ma-parallel-run_2026-09-11_1409_CONTENTS.txt`.

**Already proven locally.** A database at prod's exact state (`52705ece`, migration
`0077`) ran Preview → Rehearse → Execute with the real script. Preview: 2 pending, 3
changed, no gates. Rehearsal: 0.4 s lock window. Execute: committed, all 3 procs
byte-identical, and the re-preview said "Nothing to do". Report:
`dist\deploy-reports\MPP_MES_ProdSim0077_*`.

---

## 0. Before the window

1. **Run from `jacques/working` at this runbook's commit, and do not commit between preview
   and execute.** The plan fingerprint includes HEAD; a commit in between makes Execute
   refuse (harmless: re-preview and use the new fingerprint).

2. **Password into a masked env var** (never on a command line):

   ```powershell
   $env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
   ```

3. **Preview (read-only):**

   ```powershell
   .\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition
   ```

   **Expect exactly:**
   - `[3]` Database 77 applied, highest `0077`. **Pending (2):** `0078_container_station.sql`,
     `0079_terminal_suppress_aim_label.sql`
   - `[4]` **3 changed, 0 new:** `R__Lots_Container_Complete.sql`,
     `R__Lots_Container_GetOpenByCell.sql`, `R__Workorder_Assembly_CompleteTray.sql`
   - `[5]` No gates fired. Verdict: **Clear to deploy.**
   - A plan fingerprint. Copy it.

   **Stop if it differs.** More changed procs means prod has drifted from the repo: read
   the per-proc diffs in the report folder before going on. A missing `0077` means you
   are pointed at the wrong database.

4. **Rehearse** (applies to prod's real data inside a transaction, verifies, rolls back;
   holds locks for about 1 s):

   ```powershell
   .\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -Mode Rehearse -ExpectedPlan <fingerprint>
   ```

   Must end: `REHEARSAL PASSED and was rolled back.`

5. Have the Designer open on the prod Gateway, logged in, with the two zips to hand.

---

## 1. SQL: Execute

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -Mode Execute -ExpectedPlan <fingerprint>
```

It takes a COPY_ONLY backup + VERIFYONLY first, then one transaction. It refuses if
the plan changed since your preview, and any failure rolls the whole release back. It must
end with `COMMITTED`, "Every repo migration is recorded", and "All 3 applied repeatable(s)
now match the repo byte-for-byte". Note the backup path from step `[9]`.

## 2. Ignition: import (Core first)

Designer **File → Import**, one zip at a time, accepting overwrite for the listed
resources:

1. `Core_6ma-parallel-run_2026-09-11_1409.zip`
2. `MPP_6ma-parallel-run_2026-09-11_1409.zip`

**Do not** use the Gateway web page's project import. These are partial exports, not
whole projects. After the import, **reload every open terminal (F5)** (lesson from this
morning's downtime release).

At this point the 6MA CH watcher is still on its old `SlcTray` mapping. That mapping is
dormant on this PLC, so nothing changes on the line yet.

## 3. Arm the parallel run, in this order

The order matters: the switches that stop writes and stop AIM/labels go on **before** the
members that make the watcher act.

1. **Config Tool → Plant Hierarchy → `MA2-6MACH-AOUT3` (Assembly Out) → tick
   `SuppressAimAndLabel` → Save.** From now on a box that fills at the camera cell
   completes without an AIM serial or a label.
2. **Designer → Tag Browser → `[MPP]PlcDevices/6MA_CH`** (instance of
   `TrayInspectionStation`):
   1. Confirm the UDT definition has **`DisableWriteback`** (Boolean, Memory). You have
      added it already.
   2. `DisableWriteback` = **true**.
   3. `Protocol` = **`SlcPassPulse`** (exact spelling; an unknown value alarms on every
      edge).
   4. `VisionPartNumber` OPC Item Path → `ns=1;s=[6MA CH Camera]N16:2`
   5. `InspectionComplete` OPC Item Path → `ns=1;s=[6MA CH Camera]N7:10`
   6. `TrayLocked` OPC Item Path → the tray-present input **I:0.0/0**. Browse it in the
      OPC browser (`I` file, word 0, bit 0) rather than typing it. **Watch it go true when
      a tray arrives** before you move on.
   7. Leave `PartNumber` (N7:2) and `ContainerName` (L9:5) as they are. `OkToContinue`
      and `PartDisposition01..18` are no longer read or written; leave them or clear them.
   8. Save.

## 4. Verify (first 15 minutes)

- **Quick look:** `VisionPartNumber` reads **2**, the same as `Item.PlcId` on
  `1223A-6MA -J000`. `InspectionComplete` flips to true for 2-3 s on each good tray.
- **Audit Browser → InterfaceLog, system `PLC:6MA_CH`:** one **"ByVision tray close"** per
  good tray. Nothing is logged at tray arrival while the recipes agree.
- **Read-only check** (SSMS, or):

  ```powershell
  sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -i sql\scratch\2026-09-11_6ma_parallel_run_check.sql -C -W -s "|"
  ```

  Sections 1-3 must say `OK`. Section 2 must show `MA2-6MACH-AOUT3` as
  **OK - parallel run**. Section 6b counts good trays booked, mismatches and suppressed
  writes.
- **After 24 good trays** the first box completes. Re-run the check. Section 4 must show it
  **Complete** with `LabelRows 0`, no `AimSerial`, and **OK - suppressed**. Section 5 must say
  **OK - none**. No label comes out of P - 037.
- **METTs A/B (0078 smoke, ByCount screen):** the part dropdown selects the box, the
  "Open boxes:" line lists that station's boxes with their fill, and Complete Tray books
  into the selected part's box.

### What the log lines mean

| InterfaceLog `PLC:6MA_CH` | Meaning | Action |
|---|---|---|
| `ByVision tray close` | Good tray booked | none |
| `Tray passed -> NOT booked (vision program mismatch)` + warning toast | Vision ran another program: master tray / rabbit test, HMI part override, or a changeover | expected during rabbit tests; otherwise check `Item.PlcId` vs N16:2 |
| `PartNumber write suppressed (DisableWriteback)` | The MES recipe differs from what legacy wrote to N7:2 | legacy and MES disagree on the part; find out why |
| `Tray passed -> NOT booked (no finished good)` | No ByVision pack-out / eligible FG / box | configuration |
| `... (vision program unreadable)` | N16:2 bad quality | check the `VisionPartNumber` path |
| `ByVision tray close` with a failure | Booking refused (e.g. components missing at `MA2-6MACH`) | MES inventory is not fed; the operator gets an error toast per tray |

**The MES needs component LOTs at `MA2-6MACH`** (the ten castings + dowel pins per
`1223A-6MA` tray). Without them every good tray raises an error toast at the terminal.

## 5. Rollback

- **Before COMMIT:** automatic; nothing to do.
- **Disarm the watcher without touching anything else:** set `InspectionComplete` back to
  `N7:30`. It never rises on this ladder, so nothing more is booked.
- **Re-enable AIM + label at the terminal:** untick `SuppressAimAndLabel`.
- **SQL after COMMIT:** almost never needed. The changes are additive and inert without the
  attribute. The full restore is `RESTORE DATABASE` from the step `[9]` backup, followed by
  re-importing the previous Core/MPP resources. Forward-fixing is better.

## 6. Cutover (end of the parallel run, later)

1. Disconnect legacy (TOPServer `6MA_CH.MicroLogix1400`) from the PLC. Two hosts must
   never both write N7:2.
2. `DisableWriteback` = false on `6MA_CH`.
3. Untick `SuppressAimAndLabel` on `MA2-6MACH-AOUT3`, but only once AIM is live on
   company 99 and P - 037's `Endpoint` is set. See "Owed before AIM goes live" in
   `PROJECT_STATUS.md`.
4. Boxes completed during the parallel run stay MES-only records: no serial, no label, no
   Shipping Dock reprint. Legacy shipped them.

---

## Outcome

**SQL live on prod 2026-09-12 14:49 ET.** Prod was at `0077`; preview and rehearsal both
showed exactly the expected plan (pending `0078` + `0079`; 452 identical / 3 changed / 0
new; no gates; no warnings) — identical to the local rehearsal on `MPP_MES_ProdSim0077`.
Plan fingerprint `72073b5da24f`. Rehearsal passed and rolled back with a 2.8 s lock window
against live data (1 open basket, 1 running shift). Execute: backup
`...\MSSQL16.MSSQLSERVER\MSSQL\Backup\MPP_MES_Prod_pre-release_0077_20260912_144959.bak`
(COPY_ONLY, verified), transaction **committed in 2.9 s**, extended properties applied,
every migration recorded and all 3 procs byte-identical to the repo.
Report: `dist\deploy-reports\MPP_MES_Prod_Execute_20260912_144959\`.

> One Execute was refused first because the fingerprint was mistyped by one character
> (`7273b5da24f` for `72073b5da24f`). The guard aborted before the backup and before the
> transaction — nothing was written. Copy the fingerprint, don't retype it.

**Ignition imported 2026-09-12** (Core then MPP, from
`dist\ignition-exports\*_6ma-parallel-run_2026-09-11_1409.zip`). Prod SQL and Ignition are
both at `d4c29e75`. The 6MA CH watcher is still on its old `SlcTray` mapping, which is
dormant on this PLC, so the line is unchanged until the arming steps in section 3.

_(still to fill in: arming, first tray booked, first suppressed box)_
