# 6MA CH camera PLC: the real ladder, and the SlcPassPulse protocol

**2026-09-11.** Supersedes the 6MA parts of
[2026-09-10_6ma-ch-camera-plc-host-interface.md](2026-09-10_6ma-ch-camera-plc-host-interface.md).

## What happened

The 6MA CH ByVision cell ran all night with its tags live in Ignition, and the MES booked
nothing. The 2026-09-10 handshake (`SlcTray`) was built from **MPPMACH.RSS** on a
data-file-layout match, because we did not have the 6MA program. MPP has now supplied it:
`reference/6MA_PLC Logic` (RSLogix 500 project, processor name **6MA**, last saved
2026-06-26). The decoded listing is `reference/6MA_PLC_Logic_decoded.txt`, produced by
`reference/scripts/decode_rslogix500_rss.py` (no RSLogix needed).

It is a different program:

| | MPPMACH (what SlcTray was built on) | 6MA (the real cell) |
|---|---|---|
| PLC / vision IP | 172.17.20.30 / 172.17.20.32 (the RPY Line 2 vision IP, so probably `RPY_CH`) | **172.17.21.213** / 172.17.21.215 |
| HOST ladder file | 5 rungs: "TRAY IS LOCKED…", "SEND DONE TO HOST" | 7 rungs: one "PASSED TO HOST COMPUTER" pulse + an ASCII batch report |
| Tell-tale | `C5:10.PRE` = 32767 | `C5:10.PRE` = **48** |

Confirmed live on 2026-09-11: device `6MA CH Camera` = 172.17.21.213, `C5:10.PRE` = 48,
`L9:2` (total trays) incrementing.

## What the SlcTray members actually do on 6MA

| Member (09-10 map) | Address | 6MA ladder | Effect on SlcTray |
|---|---|---|---|
| `TrayLocked` | N7:0 | HOST 0: MOV 1 every scan while started (B3:0/0) and not in rabbit test (B3:9/0). HOST 1 zeroes it for one scan after both exits clear. | Never makes a per-tray edge. Only a gateway-start replay fired it. |
| `OkToContinue` | N7:1 | Only `EQU N7:1 = 1 → CTU C5:2`. MAIN 42 zeroes it when no tray. **The camera trigger (MAIN 24) does not read it.** | The cell never waited for the MES, which is why trays kept running. |
| `InspectionComplete` | N7:30 | MAIN 31 MOVs 1 on a result; MAIN 37 (`XIC I:0.0/0`) MOVs 0 **in the same scan** because the tray is still present. | Unobservable. It never rose. |
| `PartDisposition01` | N7:10 | MAIN 32/33: 1 on the rising edge of B3:2/0 (tray good), 0 after T4:9 (1 s base, preset 3). Good trays only. | The one usable per-tray signal. |
| `PartDisposition02..18` | N7:11..27 | **No rung writes them.** | Always 0, so the verdict would have read "mixed". |
| `PartNumber` | N7:2 | VISION 0: when it differs from N16:2, copy it and change the vision program (MSG MG11:2). | Correct. |
| `ContainerName` | L9:5 | MAIN 4: copied to L19:1, sent to vision as the pallet serial (MG11:10). | Correct (display-only, unwritten). |

Also worth knowing:

- **The per-part N17 words are fake.** MSG MG11:5 (read per-part results from vision)
  needs B3:1/9, and nothing sets it. MAIN 2/3 fill N17:0..46 with 0 (no tray) or 1 (vision
  PASS input I:0.0/5). This cell is **tray-level pass/fail only**.
- **Master trays / rabbit test.** B3:9/0 (RABBIT TEST IN PROGRESS) and the MASTER TRAY #1-5
  buttons (B3:25/11..15 → N16:2 = 11..15) are HMI-driven. A master tray that passes vision
  still sets B3:2/0 and pulses N7:10, because nothing on that path checks B3:9/0.
- Counters: L9:0 good, L9:1 bad, L9:2 total (VISION 8-11, per vision pulse, rabbit
  included), L9:9 life (per trigger). HMI "clear counts" (B3:7/0) zeroes L9:0/L9:1.

## SlcPassPulse (TrayInspectionWatcher)

The PLC runs the cell by itself and reports only passes, so the MES follows it and cannot
hold a tray. `SlcTray` is left as it was: it describes MPPMACH and may yet fit `RPY_CH`.

| Edge | MES action |
|---|---|
| `TrayLocked` ↑ (= **I:0.0/0**, tray present, ~4 s before the camera fires) | Resolve the finished good; write its `Item.PlcId` to `PartNumber` **only if it differs**. Logged, never alarmed. Replay-safe. |
| `InspectionComplete` ↑ (= **N7:10**, good tray) | Read `VisionPartNumber` (= **N16:2**, the program vision is running). Equal to the FG's PlcId → `plcCompleteTray(…, "ByVision")`. Different → **not booked**, warning toast (master tray / HMI override / changeover), then recipe sync. Unreadable → not booked, error toast. Not replay-safe. |

The MES writes nothing else: no OkToContinue, no trigger resets.

### Gateway changes (6MA_CH instance only, `[MPP]PlcDevices/6MA_CH`)

| Member | Was | Now |
|---|---|---|
| `Protocol` (memory) | `SlcTray` | **`SlcPassPulse`** |
| `DisableWriteback` (memory, new UDT member) | — | **true** while legacy runs in parallel |
| `TrayLocked` | N7:0 | **I:0.0/0** (tray present). Take the address from the OPC browser: `I` file, word 0, bit 0. |
| `InspectionComplete` | N7:30 | **N7:10** |
| `VisionPartNumber` | unmapped | **N16:2** |
| `PartNumber` | N7:2 | unchanged |
| `ContainerName` | L9:5 | unchanged |
| `OkToContinue`, `PartDisposition01..18` | N7:1, N7:10..27 | not read or written any more; leave them or unmap them |

The only UDT definition change is the `DisableWriteback` member (below). There is no
tag-change-script change: `TrayDataReady` already subscribes `6MA_CH/TrayLocked` and
`/InspectionComplete`. Import the Core script modules
`BlueRidge/Workorder/TrayInspectionWatcher` and `BlueRidge/Workorder/PlcWatcher`.

### Parallel run beside the legacy app: `DisableWriteback`

The legacy host (TOPServer → `6MA_CH.MicroLogix1400`) still writes N7:1, N7:2 and L9:5 on
every tray. The MES writes only N7:2, and only when it differs from the MES's recipe. They
agree today (2 = 2), so nothing fights. At a changeover, though, the two hosts would
alternate N7:2 and the vision program with it.

`TrayInspectionStation` now carries a **`DisableWriteback`** memory member (Boolean,
default false). When it is true, the watcher reads and books as normal but writes nothing to
the PLC. Each skipped write is logged to InterfaceLog as `<member> write suppressed
(DisableWriteback)` with the value the MES would have written. On 6MA a suppressed
`PartNumber` write therefore means **legacy and the MES disagree on the recipe**. The
program check still protects the booking: a tray inspected on another program is not booked.
A missing member reads as false, so other instances are unaffected.

For the parallel run: add `DisableWriteback` (Boolean, memory) to the UDT on the gateway,
then set it **true on `6MA_CH`**. Set it back to false when legacy is disconnected.

### Parallel run: `SuppressAimAndLabel` (terminal attribute, Migration 0079)

`DisableWriteback` stops PLC writes but not container completion. When the MES box fills
(24 trays), `plcCompleteTray` auto-completes it, and `Lots.Container_Complete` used to claim
an AIM serial and write the Honda shipping label in the same transaction. With legacy still
labelling, that is a second serial and a second label for one physical box. With an empty
pool, the completion was refused instead, and every later tray was rejected as "Container is
full".

**Migration 0079** adds a terminal (LTD 7) attribute **`SuppressAimAndLabel`** (BIT,
default 0). **`Container_Complete` v1.2** reads it from `@TerminalLocationId`. When it is
true, the proc skips the empty-pool check, the AIM claim and the `ShippingLabel` row. It
still marks the box Complete, closes its finished-good LOTs, and audits
`Container #N · AIM + label suppressed · Completed`. It returns NULL `ShippingLabelId` /
`AimShipperId`, so `Container.complete` neither prints nor posts. The operator "Complete
(box)" card (`Assembly.completeBoxToPrinter`) now returns cleanly on a NULL label instead of
dispatching nothing. Test `0028/055` covers three cases: empty pool, an unconsumed pool row
left untouched, and attribute 0 = the normal claim + label.

**For the parallel run:** Config Tool → Plant Hierarchy → `MA2-6MACH-AOUT3` → tick
`SuppressAimAndLabel`. Untick it at cutover. Boxes completed while it is set are MES records
only: no serial, no label, nothing owed to AIM, no Shipping Dock reprint. Legacy remains the
system of record for them. They are identifiable in the audit (`AIM + label suppressed`) and
as Complete containers with no `ShippingLabel` row.

### Verify on the first trays

- Tray arrives: nothing logged while the recipe already matches (N7:2 = 2 = PlcId).
- Good tray: InterfaceLog `PLC:6MA_CH` "ByVision tray close", one LOT per good tray. The
  bookings should track the `L9:0` delta.
- Failed tray: nothing (the PLC never signals it to the host). Watch `L9:1` if needed.
- A master-tray test: "Tray passed -> NOT booked (vision program mismatch)" per master tray.

### Residual risks

- A tray whose 2-3 s pulse overlaps a gateway restart is dropped (logged "initial value …
  not replayed"). `L9:0` can reconcile.
- A rabbit test run on the production program (no master-tray button, N16:2 stays 2)
  would book. Not guarded; ask MPP how their rabbit test is run.
- Failed trays are invisible to the MES. If the operator should hear about them, add a
  member on B3:2/1 (tray bad → bad side), or on an `L9:1` increase.
- The legacy host wrote N7:1 about 6.6k times (C5:2), so its `TrayLocked` alias pointed
  somewhere that did give per-tray edges. The TOPServer project for
  `6MA_CH.MicroLogix1400` would say where. Not needed for SlcPassPulse.
