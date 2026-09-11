# 6MA CH camera PLC — host interface + the SlcTray handshake

> **Wrong for 6MA — superseded 2026-09-11.** The real 6MA program (`reference/6MA_PLC Logic`,
> PLC 172.17.21.213) is not MPPMACH (PLC 172.17.20.30). On 6MA, N7:0 never makes a per-tray
> edge, N7:1 does not gate the camera, N7:30 is unobservable, and N7:11..27 are never written,
> so `SlcTray` booked nothing. 6MA_CH now uses **`SlcPassPulse`**. See
> [2026-09-11_6ma-ch-real-ladder-slcpasspulse.md](2026-09-11_6ma-ch-real-ladder-slcpasspulse.md).
> What follows is still an accurate reading of the MPPMACH ladder.

**2026-09-10.** First run of 6MA Cam Holder Assembly Out (`MA2-6MACH-AOUT3`, ByVision)
against its real PLC, the night before production. The PLC is wired **straight to
Ignition's Allen-Bradley driver** (device `6MA CH Camera`), not through TOPServer, so
the friendly member names the legacy integration relied on (`TrayLocked`,
`OkToContinue`, …) do not exist. They were TOPServer aliases over SLC data-table
words, and the UDT members had to be re-pointed at those words by hand.

## Where the address map came from

We do not hold the 6MA CH `.RSS`. The browsed data-file list of `6MA CH Camera`
(B3, C5, F14, F8, I, L9, L19, L100, L101, N7, N16, N17, N20, O, R6, S2, ST10, ST99, T4)
matches the **`MPPMACH`** ladder export (`PLC/RSS PDFs and Guide for Claude/MPPMACH.pdf`)
almost exactly. `MPP_COG` lacks L9/L19/F14/ST99/L101; `SORTCAGE` shares the file
layout but assigns its N7 words differently. MPPMACH carries a small ladder file,
**"LAD 4 - HOST"**, which is the MES interface. The map below is MPPMACH's.

**It is a structural match, not a confirmed one.** The first live trays are the
confirmation (see "Verify on the first trays").

## Address map (MPPMACH symbol table + ladder)

| UDT member | Address | Owner | Behaviour in the ladder |
|---|---|---|---|
| `TrayLocked` | `N7:0` | PLC | HOST rung 0 MOVs 1 **every scan** while the tray is locked; HOST rung 2 clears it after the tray is gone. |
| `OkToContinue` | `N7:1` | MES writes 1 | MAIN rung 27: `N7:1 = 1` → one-shot → trigger memory. **The camera does not fire without it.** The PLC MOVs 0 back itself (rung 54, tray exit; rung 66, reset all). |
| `PartNumber` | `N7:2` | MES | Recipe. When it differs from `N16:2` (program number loaded in the vision controller), the PLC copies it across and changes program. Symbol text: "1 green tray / 2 blue tray". The value left from the last legacy run was **2**, which became `Item.PlcId` on `1223A-6MA -J000`. |
| `InspectionComplete` | `N7:30` | PLC | "Send done to host". Rung 38 MOVs 1 on both pass and fail; rung 50 clears it once the tray is absent and the conveyor has stopped. |
| `PartDisposition01..18` | `N7:10..27` | PLC | **The tray verdict, not per-part results.** See below. |
| (not in the UDT) | `N7:28` | PLC | Same verdict value as `N7:10..27`. |
| `ContainerName` | `L9:5` | MES | "Serial number from host", forwarded to the vision system as the pallet serial (`L19:1`, `MG11:10`). Display-only in our design, never written. |
| `VisionPartNumber` | — | — | No equivalent. Stays unmapped (Error quality is expected). |

### The verdict polarity is the opposite of the labels

The symbols read **"PART# n BAD TO HOST"**, but the logic says otherwise:

- rung 5: tray-present one-shot → MOV **0** into `N7:10..28` (clear);
- rung 6: `FAIL FROM VISION` (`I:0/6`) + `T4:4` done → MOV **0** into every word;
- rung 9: `PASS FROM VISION` (`I:0/5`) + `T4:4` done → MOV **1** into every word (and counts `C5:10`).

So all 19 words are written identically from the camera's discrete pass/fail:
**1 = PASS, 0 = FAIL.** Rungs 6/9 are evaluated before rung 38 (which sets `N7:30`) on
the same `T4:4` done bit, so the verdict is in place when `InspectionComplete` rises.
`C5:10` (pass count ≈ 14.5k) sitting next to the trigger count `C5:2` (≈ 14.2k) shows
rung 9 fires in practice — i.e. the pass input is still high at `T4:4` done.

## Why the existing watcher could not drive this PLC

`TrayInspectionWatcher` was written for the vision SKU-ID cells:

1. **It reset `TrayLocked`** to ack the edge. Here that writes `N7:0 = 0`; the PLC
   re-asserts 1 next scan; each bounce is a new rising edge — an edge storm.
2. **It wrote `OkToContinue` only after a vision match on `InspectionComplete`.** This
   PLC will not inspect until it gets `OkToContinue`, so `InspectionComplete` never
   comes — deadlock.
3. **It compared `VisionPartNumber`**, which this PLC has no word for → read as None →
   line stop on every tray, nothing booked.

The legacy EMMD extract agrees with the ladder: for `6MA_CH` it marks `TrayLocked` /
`InspectionComplete` as triggers only (never written) and writes `PartNumber`,
`ContainerName` and `OkToContinue` in a "Set In-Process Container" step **after
TrayLocked** (`reference/legacy_mes_extract/emmd_automation/station_chain.tsv`).

## The fix — a per-instance `Protocol`

`TrayInspectionStation` gains a memory member **`Protocol`**:

- blank / `SkuVerify` (default): the original behaviour, for the `*_OilPan` vision cells.
- **`SlcTray`**: this PLC's host interface.

`SlcTray` handshake:

| Edge | MES action |
|---|---|
| `TrayLocked` ↑ | Resolve the finished good (open container's item, else the recommended FG), write its `Item.PlcId` to `PartNumber`, **then** `OkToContinue = 1`. Two separate writes, each checked; a failed write alarms and stops. No trigger write. |
| `InspectionComplete` ↑ | Read `PartDisposition01..18`. All 1 → `plcCompleteTray(…, "ByVision")`. All 0 → PLC already rejected the tray; log + warning toast, **nothing booked** (a reworked tray is re-inspected later and would otherwise count twice). Mixed / unreadable → alarm, nothing booked. No trigger write. |

Failure behaviour is **fail-closed at tray lock**: if there is no `PlcId`, no ByVision
pack-out, or no eligible finished good, the MES does not send `OkToContinue`, so the
tray stays locked and the operator gets a toast saying why.

Two changes apply to both protocols:

- **Recipe source.** The expected recipe is now the **finished good's** `Item.PlcId`,
  not the Item of the oldest open LOT on the line. On the cam-holder line that LOT is
  whichever of ten castings or dowel pins arrived first.
- **Replay guard** (`PlcWatcher.dispatch`). The tag-change script fires on subscription
  (gateway restart, script reload, project scan) with `previousValue = None`, which used
  to pass as a rising edge. Now an already-high trigger is routed **only** when its
  handler is replay-safe (`_REPLAY_SAFE`: `TrayInspectionStation.TrayLocked`). A
  replayed `InspectionComplete` would book the tray twice; a replayed `TrayLocked` just
  re-sends recipe + go-ahead, and without it a tray locked across a restart would wait
  forever for an `OkToContinue` nobody sends.

## Commissioning checklist (prod)

1. `Item.PlcId = 2` on `1223A-6MA -J000` — **done on prod 2026-09-10** by Jacques
   (Config Tool → Items → Identity → "PLC / Vision Recipe ID").
2. `6MA_CH` instance is a `TrayInspectionStation`, members re-pointed to the addresses
   above — **done**. `VisionPartNumber` stays unmapped.
3. Add the memory member **`Protocol` (String)** to the `TrayInspectionStation` UDT
   definition, then set it to **`SlcTray` on the `6MA_CH` instance only**. The repo
   UDT (`ignition/tags/udt/TrayInspectionStation.json`) carries it with default
   `SkuVerify`, but the generator's `defaultValue` is evidently not applied on import
   (`WriteDisplayEnabled` imported as `null`), so set the instance value explicitly. A
   null `Protocol` means SkuVerify.
4. Import the two Core script modules (`BlueRidge/Workorder/TrayInspectionWatcher`,
   `BlueRidge/Workorder/PlcWatcher`).
5. The `TrayDataReady` tag-change script already lists
   `[MPP]PlcDevices/6MA_CH/TrayLocked` and `/InspectionComplete`; the instance must live
   at exactly that path. `TerminalPlcDevice` must map `6MA_CH` → `MA2-6MACH-AOUT3`.
6. Line readiness for the tray close: ByVision pack-out on `1223A-6MA` (Dev: 4 per tray,
   24 trays per container), component LOTs for every BOM line (`12231..12245-6MA`,
   dowel pins `90701-5A2-A000` ×2 and `90701-5RO-3000` ×18) at `MA2-6MACH`. A full
   container auto-completes (AIM claim + label on `P - 037`).
7. Legacy EMMD/TOPServer must not also be connected to this PLC — two hosts writing
   `N7:1` / `N7:2`.

## Verify on the first trays

- Tray locks → Audit Browser → InterfaceLog shows `PLC:6MA_CH` "Tray locked -> recipe +
  ok to inspect"; `OkToContinue` goes true; the camera fires.
- A good tray → `PartDisposition01..18` all true when `InspectionComplete` rises;
  InterfaceLog "ByVision tray close" with the minted LOT.
- **If a tray that physically went to the GOOD side logs "tray FAILED (not booked)"**,
  the polarity is inverted on this PLC versus MPPMACH — stop and flip the pass test in
  `_slcOnInspectionComplete`. A mixed pattern logs "verdict unreadable" with the bits
  (`1`/`0`/`-`) in the payload.
- Two things to watch but not act on: `TrayLocked` should NOT flicker (the MES never
  writes it now); `OkToContinue` should drop back to false by itself when the tray
  leaves.
