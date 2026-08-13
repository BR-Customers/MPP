# PLC / OPC Commissioning-Readiness Map — 2026-08-11

Full plant-floor PLC interaction surface for the MPP MES, scored line-by-line for
commissioning readiness. Built from five parallel source analyses:

- **OPC tag catalog** — `reference/seed_data/opc_tags.csv` (161 items) + FRS Appendix C, cross-checked against the legacy EMMD automation-config pulls (`sql/scratch/emmd_extract_automation_config.sql`, `emmd_extract_udt_tag_map.sql`).
- **Three RSLogix 500 ladder exports** — `PLC/RSS PDFs and Guide for Claude/` : `MPPMACH.pdf` (machine-shop end-of-line vision sortation), `MPP_COG.pdf` (Cognex vision cell), `SORTCAGE.pdf` (sort-cage re-inspection).
- **Current MES watcher code** — the 10 Ignition gateway modules under `BlueRidge/Workorder`, `Oee`, `Lots`, `Location`.
- **Requirements axis** — FDS §10 (FDS-10-001…013) + FAT PLC items.

> **Scope note.** The `5GO_AP4 Automation Touchpoint Agreement` is the handshake *template for one serialized line* — the FDS itself (Appendix E) says it is "extended to all integrated assembly lines." This map treats the **OPC catalog as the authority** for which lines/stations actually exist. **All catalogued OPC touchpoints are in Machine-Shop / Assembly (MS/AS). There are ZERO Die-Cast OPC touchpoints in Appendix C** — DC shot integration, if in scope, comes from a different source (OEE / Tag Historian), not this surface.

---

## 1. Architecture at a glance

Two OPC-DA servers, **22 device instances, 161 items**, published to Ignition:

| Server | Role | Drivers | Devices | Items |
|---|---|---|---|---|
| `OmniServer` | Bench/inline **scales** (weigh-check) | OmniServer serial topics | 7 | 71 |
| `TOPServer.V5` | **PLC / HMI** touchpoints | Pro-face LT3300, AB MicroLogix 1400, EtherNet/IP (5G0) | 15 | 90 |

**TOPServer is doing the heavy lifting** — it aliases SLC-style data-table files (`N7:x`, `L9:x`) from the MicroLogix PLCs into friendly UDT member names (`PartDisposition01`, `OkToContinue`, …). This matters: a *direct* Ignition-OPC-UA-to-PLC path would need the correct SLC/PLC-family EtherNet/IP driver (Ignition's **Logix** driver will NOT map `N7:x`/`L9:x`) — but the current integration goes **through TOPServer**, which already handles it. Keep that seam.

**MES side — two trigger mechanisms coexist:**
- **Edge / tag-change dispatch (LIVE, built):** a project Tag-Change script → `PlcWatcher.dispatch()` → per-type `*Watcher.handleEdge()`. Wired to **33 trigger paths** (`PlcWatcher/resource.json:16-50`, enabled). This is the real, simulator-validated path.
- **Gateway-timer / poll (SKELETON):** `handleTimerEvent()` → `*.tickWatcher()`, all no-ops because their `_WATCH` config lists are empty. Retired/stub.

---

## 2. Handshake families (the reusable UDT types)

Four member-signature families repeat across every station — mint these as UDTs (the legacy EMMD `#U3` roll-up groups devices by exactly this signature; the 143 EMMD script bodies are the per-station handshake logic the watchers replay).

| Family | Stations | Key members | MES watcher | Status |
|---|---|---|---|---|
| **A — Scale weigh-check** | 7 OmniServer scales | `TRG_TargetWeightValue/Tolerance/UOM`, `TRG_SendMessage` (W); `NET_NetWeightValue/UOM/TargetWeightMetFlag`, `NET_DataReady` (R) | `ScaleWatcher` | **COMPLETE (gate); weight NOT persisted** |
| **B — Serialized MIP** | `5G0_A1/A2` (full R+W); `5A2_L1/L2 × CamHolder/FuelPump` (write-only subset) | `PartSN` (R), `PartValid`/`PartType`/`DataReady` (W), `PartComplete`/`TransInProc` (R+W), `HardwareInterlockEnforced` (R), `ContainerCount`, `MESAlarmText/Type` (W) | `SerializedMipWatcher` (5G0); `NonSerializedMipWatcher` (5A2) | **5G0 COMPLETE · 5A2 STUB** |
| **C — Vision SKU-verify** | `5J6/5K8_64A/6C2_6MA _OilPanAssy` (MicroLogix1400) | `PartNumber` (W, expected SKU), `VisionPartNumber` (R, camera SKU) | `TrayInspectionWatcher` | **COMPLETE (single-cycle line-stop)** |
| **D — Container / tray disposition** | `6B2_CH` (18 slots), `6MA_CH`, `6FB_CH`, `RPY_CH`, `Sort_*` | `PartDisposition01..NN` (R), `ContainerName`/`OkToContinue`/`PartNumber` (W) | `TrayInspectionWatcher` reads `OkToContinue`; **PartDisposition slots NOT read** | **PARTIAL** |

---

## 3. Station & tag inventory + readiness

### 3.1 Built tag instances (`[MPP]PlcDevices/`) — device ↔ production line

The repo tag export (`ignition/tags/instances/PlcDevices.json` + the 4 UDT defs in `ignition/tags/udt/`) contains **22 instances that match the OPC catalog's 22 devices 1:1**. They use **4 UDT types**, mapping onto the handshake families with one consolidation:

| UDT type | OPC family | Members (role fingerprint) |
|---|---|---|
| `ScaleStation` | **A** scale | `NET_DataReady/NetWeightValue/UOM/TargetWeightMetFlag/PartNumber` + `TRG_TargetWeightValue/UOM/ToleranceWeightValue/SendMessage` |
| `SerializedMipStation` | **B** full MIP | `DataReady, TransInProc, PartSN, PartComplete, HardwareInterlockEnforced, PartValid, ContainerCount(+Request), PartType, MESAlarmType/Text` |
| `NonSerializedMipStation` | **B** write-only subset | `DataReady, TransInProc, PartValid, PartType, MESAlarmType/Text` — **no `PartSN`/`PartComplete` read-back** (confirms catalog's "5A2 write-only") |
| `TrayInspectionStation` | **C + D merged** | `TrayLocked, InspectionComplete, PartNumber, VisionPartNumber` *(C)* **+** `PartDisposition01..18, OkToContinue, ContainerName` *(D)* |

> **Note the C+D merge.** The build collapsed vision-SKU-verify (C) and container/tray-disposition (D) into one `TrayInspectionStation` superset UDT — which is why `TrayInspectionWatcher` reads `VisionPartNumber` but not the `PartDisposition` slots: each physical station only populates its relevant subset. (This is the structural root of gap **P3** / the unread disposition slots.)

All 22 instances currently bind `Device=MPP_Sim` / `OpcServer=Ignition OPC UA Server` (the simulator). At commissioning these repoint to `TOPServer.V5` / `OmniServer`.

**Device ↔ production-line matching** (grouped by Honda part-program line):

| Production line | Device path (`[MPP]PlcDevices/…`) | UDT / family | OPC catalog name | Wired edge member |
|---|---|---|---|---|
| **59B** | `59B_1_FP_1` | Scale / A | `59B_1_FP_1` | `NET_DataReady` |
| **5PA** | `5PA_1_FP_1` | Scale / A | `5PA_1_FP_1` | `NET_DataReady` |
| **5A2** (Cam Holder + Fuel Pump, L1/L2) | `5A2_L1_CamHolder`, `5A2_L1_FuelPump`, `5A2_L2_CamHolder`, `5A2_L2_FuelPump` | NonSerMip / B-subset | `5A2_L1_CamHolderAssy.ProfaceLT_3300` (etc.) | `DataReady` ×4 |
| **5G0** (Assembly Front/Rear, serialized — MachNo 2653/2642) | `5G0_A1`, `5G0_A2` | SerMip / B | `5G0_A1`, `5G0_A2` | `DataReady` + `PartComplete` |
| | `5G0_Front_Scale`, `5G0_Rear_Scale` | Scale / A | same | `NET_DataReady` |
| **5J6** | `5J6_OilPan` | TrayInsp / C | `5J6_OilPanAssy.MicroLogix1400` | `TrayLocked` + `InspectionComplete` |
| **5K8** (variant 64A) | `5K8_64A_OilPan` | TrayInsp / C | `5K8_64A_OilPanAssy.MicroLogix1400` | `TrayLocked` + `InspectionComplete` |
| **6B2** | `6B2_1_FP_1` | Scale / A | `6B2_1_FP_1` | `NET_DataReady` |
| | `6B2_CH` (18-slot tray) | TrayInsp / D | `6B2_CH.MicroLogix1400` | `TrayLocked` + `InspectionComplete` |
| **6C2 / 6MA** | `6C2_6MA_OilPan` | TrayInsp / C | `6C2_6MA_OilPanAssy.MicroLogix1400` | `TrayLocked` + `InspectionComplete` |
| | `6MA_CH` | TrayInsp / D | `6MA_CH.MicroLogix1400` | `TrayLocked` + `InspectionComplete` |
| **6FB** | `6FB_CH` | TrayInsp / D | `6FB_CH.MicroLogix1400` ⚠ | `TrayLocked` + `InspectionComplete` |
| **RPY** | `RPY_1_FP_1`, `RPY_1_CB_1` | Scale / A | same (RPY has 2 scales: FP + CB) | `NET_DataReady` |
| | `RPY_CH` | TrayInsp / D | `RPY_CH.MicroLogix1400` | `TrayLocked` + `InspectionComplete` |
| **Sort** (sortation) | `Sort_OilPan`, `Sort_Totes` | TrayInsp / D | `Sort_OilPan/Totes.MicroLogix1400` | `TrayLocked` + `InspectionComplete` |

**33 wired edges total** (7 scales + 2×2 serialized + 4 non-serialized + 9×2 tray) — matches `PlcWatcher`'s 33 trigger paths (`plc_trigger_tag_paths.txt`) exactly.

**Naming reconciliations (tag ↔ OPC catalog):**
1. Tag `BasePath` **drops the `Assy` suffix and the driver name** — catalog `5A2_L1_CamHolderAssy.ProfaceLT_3300` / `5J6_OilPanAssy.MicroLogix1400` → tags `5A2_L1_CamHolder` / `5J6_OilPan`. The driver moved into the `Device` binding (now `MPP_Sim`).
2. `6FB_CH` carries the catalog's **driver-name typo** (`Micrologix1400` vs `MicroLogix1400` on different members) — verify at commissioning (§5.2).

**Ladder programs → likely devices (structural match, confirm via each PLC's IP↔device binding at commissioning):**
- `MPPMACH` (18-part tray, good/bad sortation) → **`6B2_CH`** — the only device with 18 `PartDisposition` slots.
- `SORTCAGE` (sort-cage re-inspection) → **`Sort_OilPan` / `Sort_Totes`**.
- `MPP_COG` (whole-tray Cognex vision) → one of the **`*_OilPan`** vision cells (`5J6` / `5K8_64A` / `6C2_6MA`).

> **This table is the source for the P1 `TerminalPlcDevice` seed** (§5.1 / gap-brief Spec P1): each row → one seed insert (terminal + device type + instance path `[MPP]PlcDevices/<name>`). The only missing column is the **terminal** each device maps to.

### 3.2 Station readiness

Legend: 🟢 built + sim-validated · 🟡 built but blocked (seed/config) · 🟠 stub / partial · 🔴 unbuilt · ⚪ commissioning/hardware witness only

| Line / station | Family | Driver | MES watcher | Readiness | Blocker |
|---|---|---|---|---|---|
| `5G0_A1`, `5G0_A2` (Fronts/Rears serialized assy) | B | EtherNet/IP | `SerializedMipWatcher` | 🟡 | **No `TerminalPlcDevice` seed row** (§5.1); ContainerCount write-back deferred |
| `5A2_L1/L2 × CamHolder/FuelPump` (4 cells) | B (W-only subset) | Pro-face LT3300 | `NonSerializedMipWatcher` | 🟠 | `_resolveLineConfig()` returns `None` → completion mint never runs; **catalog shows write-only, read-back absent** — confirm true MIP |
| `5J6/5K8_64A/6C2_6MA _OilPanAssy` (vision) | C | MicroLogix1400 | `TrayInspectionWatcher` | 🟡 | seed row; single-cycle only (no escalation/branching) |
| `6B2_CH` (18-slot tray) | D | MicroLogix1400 | `TrayInspectionWatcher` | 🟠 | 18 `PartDisposition` slots defined in UDT but **never read** in code |
| `6MA_CH`, `6FB_CH`, `RPY_CH` (container) | D | MicroLogix1400 | (edge dispatch) | 🟡 | seed row; **`6FB_CH` driver-name typo** (`Micrologix1400` vs `MicroLogix1400`) → two nodes |
| `Sort_OilPan`, `Sort_Totes` | D (SKU only) | MicroLogix1400 | — | 🟠 | sort-cage serial migration is MES-side & unbuilt (§ gap brief) |
| 7 OmniServer scales | A | OmniServer | `ScaleWatcher` | 🟡 | raw-weight not persisted (log-only); 5G0 scales lack `TRG_*` |

### Deep-dive: the three ladder programs we hold

| | `MPPMACH` (172.17.20.30) | `MPP_COG` (PLC .2 / vision ctrl .4) | `SORTCAGE` (172.17.20.39) |
|---|---|---|---|
| **What it is** | Machine-shop **end-of-line vision sortation** — 18-part tray, good/bad conveyor | Cognex **vision cell** — whole-tray pass/fail sequencer | **Sort-cage** vision re-inspection, bidirectional conveyor |
| **Serial** | Tray-level (`L9:5` from host → camera). No per-part serial. | None (whole-tray, no identity) | **Vestigial** — `L9:5`/`N19:x` declared, **never referenced in ladder** |
| **Per-part results** | `N7:10..27` = Part #1–18 BAD flags; `N7:28` tray-color bad | `N17:4/0..2` read but **never branched on** | `N17:2..34` per-part read; disposition on **overall** only |
| **Consecutive-fail counter** | **YES** — `C5:1` "3 bad trays in a row" → latches `B3:0/11`, stacklight (⚠ preset `30` vs symbol `3`) | **NONE** — `C5:0` allocated but dead, no `CTU` | **NONE** |
| **Escalation / supervisor gate** | None (HMI reset) | None | None |
| **Failure-type branching** | None (uniform bad) | None (uniform fail) | None (binary good/bad) |
| **Barcode / dual-source** | None | None (no scanner in I/O) | None (no scanner) |
| **Line-stop** | tray-level via `C5:1`; master `B3:0/0` manual | infeed-stopper per bad tray; master HMI manual | conveyor-reverse "return"; no line-stop |
| **Label / print / void / AIM** | None | None | **None** (exhaustive grep: zero PRINT/LABEL/VOID/AIM) |
| **MES host seam** | Write `L9:5`+`N7:1`; read `N7:0/30`, `N7:10..28`, `L9:0/1/2`. **`N7:30`=results-ready.** | Drive `N7:1 OK-TO-TRIGGER`+`N7:2 recipe`; read `N17:1/0` PASS / `N17:1/1` FAIL, strobe `N17:1/3` | Write `N7:2` recipe; read done/good + `L9:0/1/2` counts |

**Cross-reference:** `MPPMACH`'s 18-part tray disposition (`N7:10..27`) is the ladder-level reality behind OPC **family D**'s `PartDisposition01..18` on the `_CH` MicroLogix1400 devices — TOPServer aliases the SLC file to the friendly members.

---

## 4. The consistent finding across all three PLCs

**The PLCs provide raw per-cycle verdicts and nothing more.** None of them implement the "intelligence" the FDS requires:

- **Consecutive-fail escalation (FDS-10-009):** only `MPPMACH` counts at all, and it's *tray-level, HMI-reset, no supervisor gate* — NOT the per-cell-per-part 10-fail-with-supervisor-elevation model. The MES cannot lean on PLC counters.
- **Failure-type branching (FDS-10-010):** absent everywhere — every PLC collapses all causes to one undifferentiated fail. The only place finer data *could* surface (`MPP_COG` `N17:4/x`, `MPPMACH` per-part words) is read but never classified.
- **Dual-source confirmation (FDS-10-013):** no barcode scanner exists in any vision PLC's I/O — vision-only verdicts. Any "vision AND barcode must agree" is entirely MES-side.

➡ **All of FDS-10-009 / -010 / -013 (= FAT PLC-120/130/220/230) live in the MES.** See the gap design brief.

---

## 5. Top commissioning blockers (ranked)

### 5.1 `TerminalPlcDevice` mapping rows are UNSEEDED — the #1 blocker
Migration `0038_plc_integration_foundation.sql` seeds the 4 `PlcDeviceType` rows but there are **zero `INSERT INTO Location.TerminalPlcDevice` statements anywhere in `sql/`**. Rows are only inserted live via the editor. Until they exist, **all 33 wired trigger paths hit the "no TerminalPlcDevice mapping → edge ignored" branch** (`PlcWatcher/code.py:164-168`) and *nothing routes*. This is FAT-PLC-020's unmet precondition and it gates the entire surface. **Fix:** a seed migration mapping each of the ~24 UDT instances → its terminal (mirror `011_seed_locations`).

### 5.2 Driver / addressing confirmations
- **`6FB_CH` driver-name typo** — `Micrologix1400` (on `OkToContinue`) vs `MicroLogix1400` (on `PartNumber`) resolve to two different OPC nodes. One device, two spellings — a literal break.
- **`5G0_A1.5G0_A1.<member>` double-node browse path** must be reproduced exactly in the OPC-UA address space or item resolution fails.
- **`5A2_*` catalogued write-only** — the PartSN/PartComplete read-back a full MIP needs is absent from Appendix C. Confirm these Pro-face cells are true serialized MIP vs MES→HMI command-only.
- **Transport per PLC** — `MPPMACH`/`SORTCAGE` are MicroLogix 1400 SLC-file devices; confirm DF1 channels 0/2 aren't a second master contending with the host `N7`/`L9` block.

### 5.3 Config that doesn't exist yet
- **Line→FG/PieceCount config** for non-serialized lines (`_resolveLineConfig` returns `None`) — source undecided (Item attribute vs per-line row vs active WO).
- **`ConfirmationMethod` LocationAttributeDefinition** (FDS-10-013 / PLC-220) — 0 files in `sql/`.
- **`LineStopConsecutiveFailThreshold` LocationAttribute** (FDS-10-009 / PLC-120) — no definition anywhere.
- **Poll `_WATCH` lists empty** — `DowntimePlc` tick logic is complete and only needs its `_WATCH` populated (populate → it runs); `AssemblyPlc` needs both config and a real `_handlePiece` (superseded by the edge serialized watcher).

---

## 6. FAT PLC item status (post-analysis)

| FAT | Requirement | State | Path to green |
|---|---|---|---|
| PLC-020 | serialized MIP touch points | 🟡 code done, **seed missing** | seed `TerminalPlcDevice` rows |
| PLC-030 | serialized MIP transaction flow | 🟢 complete | record sim acceptance |
| PLC-040/090/100/110/190 | MIP/vision/scale flows | ⚪ built, sim-validated | live/HW witness |
| PLC-120 | 10-consecutive-fail escalation | 🔴 unbuilt (MES-side) | Spec P2 |
| PLC-130 | failure-type branching | 🔴 unbuilt (MES-side) | Spec P3 |
| PLC-220 | `ConfirmationMethod` attribute | 🔴 unbuilt (unseeded) | Spec P4 |
| PLC-230 | dual-source agreement gate | 🔴 unbuilt | Spec P4 |

**Net readiness:** the edge-dispatch spine + serialized MIP (5G0) + vision line-stop + scale gate are **built and simulator-validated**. The surface is blocked at deployment by **one missing seed** (§5.1) plus addressing confirmations. Four "advanced" behaviors (PLC-120/130/220/230) are genuinely unbuilt and MES-side. See `2026-08-11_plc-gap-design-brief.md`.
