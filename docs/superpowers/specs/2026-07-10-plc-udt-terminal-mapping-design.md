# PLC UDT Structure + Terminal Device Mapping — Design

**Date:** 2026-07-10
**Author:** Jacques Potgieter (with Claude)
**Status:** Draft — awaiting review
**Spec type:** Design (brainstorming output). Next step: implementation plan (writing-plans).

---

## 1. Context & Problem

The legacy Flexware MES drove PLC/scale/vision integration through two layers on `EXCSRV05`:

1. **EMMD** (`em` schema) — an OPC choreography engine. Each machine `Event` watches an OPC item (e.g. `DataReady`) and runs an ordered list of `Action`s (OPC reads/writes + VBScript) — the handshake sequence.
2. **`Flexware.MES.EMInterface.MESCore`** — a COM object the scripts call for the actual MES transaction (`ProcessContainerAtEndOfLine`, `ProcessSerializedItemAtEndOfLine`, `CompleteSerializedContainer`, `ProcessTrayInspectionComplete`), plus a `SendMessage` bus.

The new MES (Ignition Perspective + SQL Server) replaces **both**: the Ignition **gateway watcher** takes EMMD's choreography role, and our **stored procedures** take MESCore's transaction role (many already exist — `Assembly_CompleteTray`, `SerializedPart_Mint`, `TrimOut_Record`, etc.).

Legacy connected via OPC-DA bridges (**TOPServer**, **OmniServer**). Ignition connects **OPC UA straight to the PLCs**, so that DA split is a legacy artifact, not a design constraint. The legacy config still gives us the authoritative **logical tag inventory**, **per-station member sets**, and **handshake sequences**.

**Goal of this design:** define the Ignition **UDT structure** for PLC-integrated stations, the mechanism that **maps a terminal to its PLC device instance(s)**, a **simulation layer** so the handshake logic is testable without hardware, and the **watcher architecture** that replays the handshakes against our procs.

### Source data (this session)

- `reference/seed_data/opc_tags.csv` (161 tags, FRS App C) + a full re-pull of the EMMD automation config via `sql/scratch/emmd_extract_udt_tag_map.sql` (grids `#U1..#U4`) and `emmd_extract_automation_config.sql` (`#H..#N`, incl. 143 VBScript bodies).
- RSLogix 500 PDFs (`PLC/RSS PDFs and Guide for Claude/` — MPPMACH, MPP_COG, SORTCAGE) confirm the ladder-level handshake vocabulary.
- FDS §10 (PLC/OPC integration, MVP) + FDS-10-013 (Cell PLC LocationAttribute precedent) + `5GO_AP4_Automation_Touchpoint_Agreement.pdf`.

---

## 2. Decisions (resolved during brainstorming)

| # | Decision | Choice | Rationale |
|---|---|---|---|
| D1 | Which location tier carries the device pointer | **Terminal** (`LocationTypeDefinition` DefId 7) | The active operator **session** owns its acceptance handshake; the terminal is already resolved in `onStartup` → `session.custom.terminal`, so zero extra resolution. |
| D2 | UDT granularity | **One UDT definition per functional pattern** (4 defs), parameterized by `{DeviceName}` + `{BasePath}`; ~22 instances (one per device) | Ignition device connections are a **separate layer** from tag UDTs (Gateway → OPC Connections vs Tag Provider → UDTs). A UDT definition is purely functional — the `{DeviceName}` parameter substitutes into every member's OPC item path at runtime, so one definition services *any* device that speaks the pattern. Verified against Ignition 8.3 UDT-parameters docs. |
| D3 | Terminal→device multiplicity | **Many** (a terminal can bind several devices) | 5G0 front uses MIP `5G0_A1` **and** scale `5G0_Front_Scale` on one line. Requires a 1-to-many child mapping, not flat attributes. |
| D4 | Build scope | **Build it** (UDT defs + SQL + onStartup + watchers) **plus a simulation layer** | Real PLCs unreachable in dev; sim makes the handshake logic testable. |
| D5 | PLC integer part-code ↔ Item mapping | **Item attribute, scoped to `ItemLocation`** (per line) | Codes are line-local (see §6). `ItemLocation` (Item×Location) already exists for eligibility. |

---

## 3. UDT Architecture

### 3.1 The Ignition model: UDTs are functional; devices are a separate layer

Two orthogonal layers per Ignition 8.3:

- **Device layer** — Gateway → OPC Connections. Each PLC / scale / OPC-UA-server is a named "device". Ignition addresses tags as `[DeviceName]path/inside/device.tagname`.
- **Tag layer (UDTs)** — Definitions are per functional pattern (Scale, SerializedMip, NonSerializedMip, TrayInspection). Members' OPC item paths reference **parameters** in `{ParamName}` syntax, substituted at runtime. **One definition services any device that speaks the pattern.**

**Three UDT parameters** (set on each instance at creation in the `MPP` tag provider — the DB does NOT store these; verified parameterizable incl. `opcServer`):

- **`{OpcServer}`** — the Ignition OPC **server connection** name. Default `Ignition OPC UA Server` (hosts both the Programmable Device Simulator *and* the native AB/Mitsubishi driver devices); `TopServer` / `OmniServer` for the Phase-1 external OPC-UA connections. Bound on each OPC member as `"opcServer": {"bindType": "parameter", "binding": "{OpcServer}"}`.
- **`{Device}`** — the device name *within* that server (e.g. `MPP_Sim`, `5G0_A1`).
- **`{BasePath}`** — the address inside the device up to but not including the member.

Each OPC member's item path is a parameter binding, e.g. `ns=1;s=[{Device}]{BasePath}.PartSN` (mirrors the sample UDT's `ns=1;s=[{Device}]{BasePath}1`).

**Simulation uses Inductive Automation's Programmable Device Simulator** (the tool behind the sample `csv.csv`). We generate a simulator **program CSV** from the member catalog — one **writeable** tag per member per device (`Time Interval, Browse Path, Value Source, Data Type`; Value Source = a literal default = writeable) — and load it into a simulator device named `MPP_Sim` on the `Ignition OPC UA Server`. A UDT instance sets `{OpcServer}=Ignition OPC UA Server`, `{Device}=MPP_Sim` in dev; the **same definition** sets the real server/device in prod. No separate Sim UDT, no memory-tag mirror — one definition, parameters swap it, zero drift.

**Member catalog is the single source of truth** — the 4 UDT definitions *and* the simulator program CSV are generated from the §3.3 catalog, so member-set / datatype / direction cannot diverge between real and sim.

**Concrete count:** 4 UDT definitions, ~22 UDT instances (one per physical device — §6 + `integration_manifest.csv`), one `MPP_Sim` simulator device carrying the writeable tags for the devices we exercise without hardware.

### 3.2 The four UDT types

| UDT type | Active devices | Server family (legacy → new) |
|---|---|---|
| **ScaleStation** | 59B_1_FP_1, 5PA_1_FP_1, 6B2_1_FP_1, RPY_1_FP_1, RPY_1_CB_1, 5G0_Front_Scale, 5G0_Rear_Scale (7) | OmniServer (serial ASCII) → serial/UA bridge |
| **SerializedMipStation** | 5G0_A1, 5G0_A2 (2) | TOPServer → Mitsubishi |
| **NonSerializedMipStation** | 5A2_L1/L2 × CamHolder/FuelPump (4) | TOPServer → Pro-face LT3300 |
| **TrayInspectionStation** | 6B2_CH, 6MA_CH, 6FB_CH, RPY_CH, 5J6, 5K8_64A, 6C2_6MA, Sort_OilPan, Sort_Totes (9) | TOPServer → AB MicroLogix 1400 |

`5G0 Line 2 Backup` and `6MA-2` are `Active=0` in EMMD → excluded. `TrayInspectionStation` is one type with optional members (disposition / vision / sort are member-subset flavours); may be split three ways if preferred.

### 3.3 Member catalog (datatype / direction / trigger)

Directions: **R** = MES reads from PLC, **W** = MES writes to PLC, **trig** = watcher subscribes and acts on the **rising edge**. Datatypes derived from `#L` literals + `#N` casts (`CBool/CInt/CDbl/CStr`).

**ScaleStation** (full "FP" variant; 5G0 completion scales carry only the `NET_*` read subset)

| Member | Type | Dir | Notes |
|---|---|---|---|
| `NET_DataReady` | BOOL | R (trig `EQ 1`), W(clear) | weight-ready handshake |
| `NET_NetWeightValue` | REAL | R | |
| `NET_NetWeightUOM` | STRING | R | |
| `NET_TargetWeightMetFlag` | BOOL | R | tolerance-met |
| `NET_PartNumber` | STRING | R | 59B only |
| `TRG_TargetWeightValue` | REAL | W | scale wire wants zero-padded **string** (scripts 54/122) |
| `TRG_TargetWeightUOM` | STRING | W | |
| `TRG_ToleranceWeightValue` | REAL | W | zero-padded string on wire |
| `TRG_SendMessage` | BOOL | W (pulse) | commit target-weight change |

**SerializedMipStation**

| Member | Type | Dir | Notes |
|---|---|---|---|
| `DataReady` | BOOL | R (trig `EQ 1`), W(reset) | |
| `TransInProc` | BOOL | R/W | MES transaction ack |
| `PartSN` | STRING | R | min length 6; blank ⇒ auto-gen when interlock off |
| `PartComplete` | BOOL | R (trig `EQ 1`), W | part-add trigger |
| `HardwareInterlockEnforced` | BOOL | R | false ⇒ NoRead bypass (FDS-06-012) |
| `PartValid` | BOOL | W | validation result to PLC |
| `ContainerCount` | INT | R/W | |
| `ContainerCountRequest` | BOOL | W (trig `EQ 1`), reset | operator count request |
| `PartType` | INT | W | line-local type code (see §6) |
| `MESAlarmType` | INT | W | |
| `MESAlarmText` | STRING | W | |

**NonSerializedMipStation** (leaner; no serial/container/interlock)

| Member | Type | Dir |
|---|---|---|
| `DataReady` | BOOL | R (trig `EQ 1`), W(reset) |
| `TransInProc` | BOOL | W |
| `PartValid` | BOOL | W |
| `PartType` | INT | W |
| `MESAlarmType` | INT | W |
| `MESAlarmText` | STRING | W |

**TrayInspectionStation** (optional members marked ○)

| Member | Type | Dir | Notes |
|---|---|---|---|
| `TrayLocked` | BOOL | R (trig, data-change→edge) | write recipe/part on lock |
| `InspectionComplete` | BOOL | R (trig, data-change→edge) | bail if 0 |
| `PartNumber` | INT | W (R on 6FB) | type code / sort recipe |
| `VisionPartNumber` ○ | INT | R | vision-reported type code (validate vs active LOT) |
| `PartDisposition01..18` ○ | BOOL | R | per-slot pass/fail (disposition lines) |
| `OkToContinue` ○ | BOOL | W | release tray |
| `ContainerName` ○ | STRING | W | in-process container id to HMI |

Events fire on **data-change** and `SkipToAction("")` when the flag is 0 ⇒ watcher must act on the **rising edge** (durable-guard concern from the 2026-07-09 readiness note).

### 3.4 Ignition tag JSON format (from the reference `SampleUDT.json` / instance)

The generated UDT definitions follow the reference sample exactly:

- **Definition** — `{"name", "tagType": "UdtType", "parameters": {...}, "tags": [...]}`. Parameters are `{"<Name>": {"dataType": "String|Integer", "value": <default>}}`.
- **OPC member** — `{"name", "dataType": "<IgnitionType>", "valueSource": "opc", "opcServer": {"bindType":"parameter","binding":"{OpcServer}"}, "opcItemPath": {"bindType":"parameter","binding":"ns=1;s=[{Device}]{BasePath}.<Member>"}}`. (`=`/`;` serialize as `=` etc. — the Designer-unicode-escape gotcha; author with that in mind.)
- **`valueSource` values used:** `opc` (real/sim device tags), `memory` (local state — e.g. the `writeDisplayEnabled` flag, edge-guard latches), `expr` (derived/computed — e.g. a human-readable handshake-state string), `reference` (mirror a sibling via `"sourceTagPath": "[.]<Member>"`).
- **Ignition datatypes:** `Boolean`, `Int2`(Int16)/`Int4`(Int32)/`Int8`(Int64), `Float4`/`Float8`, `String`. Our catalog maps BOOL→`Boolean`, INT→`Int4`, REAL→`Float8`, STRING→`String`.
- **Expression tags** reference siblings as `{[.]<Member>}`, e.g. `round({[.]NetWeightValue},2)`; C-style operators only (per project expr-language memory — `!`/`&&`/`if(c,a,b)`, no Python keywords, no `\u` escapes in string literals).
- **Event scripts** (if any member needs onChange logic) — `"eventScripts":[{"eventid":"valueChanged","script":"\t<body>"}]`, **tab-indented** (Jython), using `system.tag.readBlocking`/`writeBlocking`.
- **Instance** — `{"name", "tagType": "UdtInstance", "typeId": "<DefName>", "parameters": {<overrides only>}, "tags": [{"name","tagType":"AtomicTag"} ...]}`. Instances list member names (values optional) and override only the parameters that differ.

Tag artifacts are committed under `ignition/tags/` and imported at deploy (Designer tag import / `system.tag.configure`) — they live outside the project export `scan.ps1` syncs (§8).

---

## 4. SQL Data Model

### 4.1 `Location.PlcDeviceType` (code table)

Fixed-seed lookup of the 4 UDT types. `Id, Code, Name, DeprecatedAt`. Codes: `ScaleStation`, `SerializedMipStation`, `NonSerializedMipStation`, `TrayInspectionStation`.

### 4.2 `Location.TerminalPlcDevice` (thin pointer: terminal → UDT instance, 1-to-many)

**The DB does not hold OPC addressing.** The UDT *instance* carries its own `{OpcServer}`/`{Device}`/`{BasePath}` parameters (set at instance creation in the `MPP` tag provider; Ignition builds the OPC item path from them, per the reference `SampleUDT.json`/instance). The DB's only job is to answer "which UDT instance(s) does this terminal drive" — a **pointer**, one row per device.

| Column | Type | Notes |
|---|---|---|
| `Id` | BIGINT IDENTITY PK | |
| `TerminalLocationId` | BIGINT FK → Location | the Terminal (DefId 7) |
| `PlcDeviceTypeId` | BIGINT FK → PlcDeviceType | UDT type — for UI grouping + which sim scenarios apply (stable metadata, not addressing) |
| `DeviceCode` | NVARCHAR(100) | short human label / per-terminal unique key, e.g. `5G0_A1` |
| `UdtInstancePath` | NVARCHAR(400) | **the pointer** — full tag path to the UDT instance in the `MPP` provider, e.g. `[MPP]PlcDevices/5G0_A1`. Stable sim↔prod (the instance is re-parameterized, not the pointer). |
| `SortOrder` | INT | display order per terminal |
| `CreatedAt/UpdatedAt/UpdatedByUserId/DeprecatedAt` | — | standard |

**What moved out of the DB (and where it went):**
- OPC addressing (`{OpcServer}`/`{Device}`/`{BasePath}`) → the **UDT instance parameters** in the tag provider. Single source of truth; no duplication. Sim vs prod = re-parameterize the instance's `{Device}` (e.g. `MPP_Sim` → `5G0_A1`); the DB pointer never changes.
- `WriteDisplayEnabled` (HMI-display gating, §5.1) → a **memory-tag member on the UDT** (per-device config that lives with the device), not a DB column.
- `IsSimulated` → gone; sim state is an instance-parameter concern, not DB.

Rationale for a dedicated table over `LocationAttribute`: a terminal drives *many* devices (D3), so a 1-to-many child table is the right shape; and the pointer's a stable string, cleanly a column. Follows the typed-FK convention (`sql_best_practices_mes.md`).

Procs (mutation procs return `SELECT @Status,@Message,@NewId`; no OUTPUT params — FDS-11-011):
- `Location.TerminalPlcDevice_Save` (insert/update)
- `Location.TerminalPlcDevice_Deprecate`
- `Location.TerminalPlcDevice_GetByTerminal` (read; ET display where dated)

### 4.3 PLC ID ↔ Item, validated via the assembly-out FIFO queue (D5)

**PLC ID is a part-configuration attribute on the Item** — `Parts.Item.PlcId INT NULL` (the vision-recipe / PLC integer for that part). Stable per part (a part runs on its line), so it lives on the Item, not per-line.

**Validation is FIFO-derived** — the same shape as the BOM-derived validation the route-driven queues already do. The PLC session does NOT rely on a per-line code map; it reads its **assembly-out queue** (`Lots.Lot_GetWipQueueByLocation` — the route-driven FIFO from the 2026-07-07 terminal-mint work) to learn the **expected** LOT at that terminal, then reads that LOT's `Item.PlcId`:

- **Write path** (MES → PLC `PartNumber`/`PartType` recipe select): front-of-FIFO expected LOT → its Item → `Item.PlcId` → write to the PLC before inspection.
- **Read/validate path** (`VisionPartNumber` R on `InspectionComplete`): compare the vision-reported code against the expected LOT's `Item.PlcId`; mismatch ⇒ wrong-part alarm + line-stop (FDS-10-005/010).

SQL surface: `Parts.Item.PlcId` column + `Parts.Item_SetPlcId` / `Parts.Item_GetPlcId`. The FIFO read is the existing `Lots.Lot_GetWipQueueByLocation`; the watcher (Plan 3) combines front-of-queue → `Item_GetPlcId` → compare. **No per-line mapping table, no `ItemLocation` change.**

> Revised from an earlier `ItemLocation.PlcPartCode` (line-scoped) design. The legacy vision integers *look* line-local, but the line context comes from the **FIFO queue** (which part is expected at this terminal now), not a stored per-line code — so a part's PLC ID is a stable part property and belongs on the Item. `PlcId` is not globally unique (two parts on different lines may share an integer); that's fine, because FIFO already fixes the expected part and PlcId is the secondary recipe/confirmation check.

### 4.4 `onStartup` resolution

Extend `onStartup.py` after terminal/printer resolution: call `TerminalPlcDevice_GetByTerminal(terminalLocationId)` and populate `session.custom.plcDevices` = list of `{deviceCode, deviceType, udtInstancePath}`. Views/watchers bind directly to the `udtInstancePath` (the instance already carries its OPC params). (No business logic in Python — pure plumbing.)

---

## 5. Watcher Architecture

One gateway module per UDT type (extends the established `DowntimePlc` / `AssemblyPlc` `_WATCH` pattern). Each subscribes to its type's **trigger** members (rising edge) across all instances and replays the handshake against our procs.

**Legacy → new mapping (EMMD Action sequence → our proc):**

| Legacy MESCore call (script) | New proc |
|---|---|
| `ProcessContainerAtEndOfLine` (24/33/51/72/119) | `Workorder.Assembly_CompleteTray` (non-serialized FG mint) |
| `ProcessSerializedItemAtEndOfLine` (10/215/246) | `Lots.SerializedPart_Mint` (+ new validate surface, below) |
| `CompleteSerializedContainer` (210/241) | `Lots.Container_Complete` |
| `GetContainerQuantity` / `GetInProcessContainer` (9/202/229) | existing container reads |
| `ProcessTrayInspectionComplete` (254/292) | tray-inspection close (existing Assembly/Hold procs) |
| `GetInProcessContainerSortRecipe` (88/110) | sort-recipe read (Sort workflow) |

### 5.1 Write-tag audit — separating handshake from HMI-display carry-forward

The legacy write-tag set mixes two purposes; blindly copying it into the new system carries vestigial signals. Split by intent:

**Handshake / control (essential — MES must write to PLC):**
- `TransInProc` — MES transaction interlock; PLC uses it to know the MES is processing.
- `PartValid` — MES release signal; PLC uses this to route the part / release the tray.
- `DataReady` / `PartComplete` / `ContainerCountRequest` (reset only) — MES acknowledging consumed triggers.
- `OkToContinue` (tray inspection) — MES release signal.
- `PartNumber` (tray inspection) — drives vision-system recipe selection *inside the PLC* before `InspectionComplete` fires. **Control, not display.**
- `TRG_TargetWeightValue` / `TRG_TargetWeightUOM` / `TRG_ToleranceWeightValue` / `TRG_SendMessage` (scale) — MES configuring the scale hardware.

**HMI display carry-forward (vestigial with Perspective at the terminal — mark OPTIONAL in the UDT):**
- `PartType` — currently-running part on the local HMI screen.
- `MESAlarmText` / `MESAlarmType` — MES alarm text on the local HMI.
- `ContainerCount` (when written purely for display, not for handshake seeding).
- `ContainerName` (6B2 / 6MA cam-holder lines — displayed on the local HMI).

Rationale: the 5A2 lines use Pro-face LT3300 HMIs and the 5G0 lines use dedicated MIP HMIs — legacy MES had to write alarm/display state to the PLC because the operator's screen was the HMI. Under the new architecture, **Perspective is the operator surface** at every PLC-integrated station, so alarm/display state is rendered by Perspective from MES state directly.

**Concrete rule:** the UDT carries a `WriteDisplayEnabled` **memory-tag member** (per-instance config that lives with the device). Off by default; on only where the legacy HMI is retained. The watchers check the member before writing any HMI-display member.

### 5.2 Legacy business logic worth flagging (things we don't fully have eyes on)

From the `#N` script bodies — legacy behavior that isn't obvious from just the tag list:

1. **`SendMessage` internal message bus.** Every script broadcasts XML-payload messages like `59B_1_FP_1_NetWeightUpdate`, `6B2_CH_TrayLockSet`, `SORT_OP_InspectionComplete`. These are not PLC writes — they flow to `MESCore` consumers (label printers, downstream cell notifications, database loggers). **The full consumer set is buried in the legacy `Flexware.MES.EMInterface.dll`**, source not available. The new architecture replaces the bus with direct proc calls, but enumerate consumers before assuming nothing else listens.
2. **Container completion hardcoded at 60** in the 5G0 scripts (`If ContainerCount = 60 Then trigger completion`). Business rule, not a constant. Moves to `ContainerConfig` (data-driven closure).
3. **Sort recipes.** `GetInProcessContainerSortRecipe` returns an integer written as `PartNumber` to the sort PLC. Where is the mapping data today? Attribute on Item? Separate table? Confirm it survives.
4. **`HardwareInterlockEnable` (FDS) vs `HardwareInterlockEnforced` (EMMD).** FDS-10 says R/W (MES-controllable); EMMD only reads. Verify new-system semantics.
5. **`WatchDog`** (heartbeat, FDS-10-013) is **absent from the EMMD extract**. Either not implemented at Madison, or on a different plant. Confirm at commissioning.
6. **Auto-generated serial numbers** when `HardwareInterlockEnable=False` — legacy calls `ProcessSerializedItemAtEndOfLine(..., serialNumber="")` and MESCore internally generates a serial. Confirm `SerializedPart_Mint` handles the empty-`@SerialNumber` case with equivalent auto-generation.

### 5.3 Obsolete legacy mechanisms — noted, NOT built

Explicit "carried forward from the old system but not required by the new solution" list. These are **documented and deliberately skipped** — do not build them unless a listed condition holds.

**Tag members declared in the UDT but NOT written/consumed by default:**

| Member(s) | Legacy purpose | Why obsolete | Build? |
|---|---|---|---|
| `MESAlarmText`, `MESAlarmType` | Push alarm text to the PLC's local HMI | Perspective at the terminal renders alarms from MES state | **Skip** — gated by `WriteDisplayEnabled` (default 0) |
| `PartType` (write) | Show running part # on the HMI | Perspective shows it | **Skip** — gated |
| `ContainerName` (write, 6B2/6MA) | Show in-process container id on the HMI | Perspective shows it | **Skip** — gated |
| `ContainerCount` (write) + `ContainerCountRequest` | Physical button → MES writes count to HMI for display | Perspective shows live count; request/echo loop is dead weight | **Skip** the request handling + display write; count logic lives in procs |
| `NET_PartNumber` (read, 59B) | Scale-reported part # cross-checked vs active WO (legacy script 82 "Verify Part") | MES already knows the active LOT's Item; cross-check is optional | **Skip** unless MPP wants scale-part cross-validation |
| `TRG_TargetWeightUOM` (write) | Send target UOM to scale each change | If UOM is standardized system-wide, redundant | **Confirm** — skip if UOM never varies per part |

**Mechanisms NOT reimplemented:**

| Legacy mechanism | New-system replacement |
|---|---|
| `SendMessage` XML message bus (`*_NetWeightUpdate`, `*_TrayLockSet`, `*_InspectionComplete`) | Direct stored-proc calls from the watcher. **No message bus.** (Enumerate legacy consumers first — §5.2 item 1.) |
| Hardcoded `ContainerCount = 60` completion | Data-driven `ContainerConfig` closure |
| 5G0 "deactivate DataReady event so the scale triggers labels" dual-path hack | One completion path driven by our proc on the correct trigger |
| EMMD "message-handler" events (`050 Target Weight Change`, `150 Set In-Process Container`) | Part of the normal proc/handshake flow — not modelled as OPC events |
| EMMD engine scaffolding — `Initialize Local Variables`, `[BEGIN]/[END]`, `SkipToAction`, `Bail on reset` | Watcher control flow in Python; engine mechanics N/A |

**Explicitly KEPT (look skippable, but are control-plane, not display):**
`PartNumber` write on tray-inspection lines (selects the **vision recipe** in the PLC before `InspectionComplete`); `OkToContinue`; scale `TRG_TargetWeightValue`/`TRG_ToleranceWeightValue`/`TRG_SendMessage`; `PartValid`; `TransInProc`; `DataReady`/`PartComplete` resets.

**Net effect on the member catalog (§3.3):** every member is still *declared* in the UDT (cheap, and keeps the sim/real contract complete), but the watchers only *write* the control-plane members by default; display members are inert unless `WriteDisplayEnabled=1`. Nothing above is built as active behavior in MVP.

**Handshake archetypes** (from `#U4` + `#N`):

- **Scale:** on `NET_DataReady↑` → read weight/UOM/metFlag → clear them → record weight (proc) → if metFlag, close/label. Target-weight change: write `TRG_*` (zero-padded) + pulse `TRG_SendMessage`.
- **Serialized MIP (5G0):** on `DataReady↑`/`PartComplete↑` → set `TransInProc` → read `PartSN`+`HardwareInterlockEnforced` → validate (len≥6; blank auto-gen if interlock off) → `SerializedPart_Mint` → `PartValid` + `ContainerCount` + `PartType` → reset `TransInProc`/`PartComplete`. Container close is **scale-coupled** (legacy hardcodes count 60 → our `ContainerConfig` closure).
- **Non-serialized MIP (5A2):** on `DataReady↑` → `Assembly_CompleteTray` → `PartValid` + `PartType` + alarms → reset.
- **Tray inspection:** on `TrayLocked↑` → read the **assembly-out FIFO queue** (`Lot_GetWipQueueByLocation`) → front-of-queue expected LOT → write its `Item.PlcId` as `PartNumber` (recipe select) + `ContainerName`/`OkToContinue`; on `InspectionComplete↑` → read `VisionPartNumber`/`PartDisposition*` → validate the vision code against the **expected LOT's `Item.PlcId`** (§4.3) → close tray.

**New validate surface** (readiness-note gap): `Lots.SerializedPart_GetBySerial` + optional `@SerialNumber` on `SerializedPart_Mint` (FDS-10-002/003). Serial rules: min length 6; `HardwareInterlockEnforced=false` ⇒ accept `NoRead`/auto-gen (FDS-06-012).

**Attribution/robustness:** centralize `systemAppUserId()` + seed a verified system `AppUser`; pass `terminalLocationId` from the watcher; durable edge guard (project Tag Change events, not module memory) so state survives gateway restart; every handshake logged to `Audit.InterfaceLog` / failures to `Audit.FailureLog` (FDS-01-014).

---

## 6. Device Connections — driver reality (verified 2026-07-10)

Verified against Ignition 8.3 driver docs:

| Family | Devices | Native Ignition driver? | Path forward |
|---|---|---|---|
| **Allen-Bradley MicroLogix 1400** | 9 (6B2_CH, 6MA_CH, 6FB_CH, RPY_CH, 5J6, 5K8_64A, 6C2_6MA, Sort_OilPan, Sort_Totes) | ✅ **Yes** — AB Ethernet driver, MicroLogix 1100/1400 fully supported | Direct Ignition device connection possible |
| **Mitsubishi PLC** | 2 (5G0_A1, 5G0_A2) | ✅ **Yes** — Mitsubishi TCP Driver (iQ-R / iQ-F / Q / L series) | Direct Ignition device connection possible *(confirm series at commissioning)* |
| **Pro-face LT3300 HMI/PLC** | 4 (5A2 CamHolder/FuelPump × L1/L2) | ⚠️ **No native driver** | Connect via TopServer (already deployed as OPC-UA server) |
| **Serial ASCII scales via OmniServer** | 7 (59B, 5PA, 6B2, RPY_FP, RPY_CB, 5G0_Front, 5G0_Rear) | ⚠️ **No native ASCII-pattern driver** | Keep OmniServer as OPC-UA server (already deployed); Ignition connects as OPC-UA client |

### 6.1 Migration strategy (staged — day-one working, cutover-friendly)

**Phase 1 — connect to existing servers as OPC-UA clients** (recommended for MVP):
- TopServer is Kepware `SWToolbox.TOPServer.V5` — natively hosts an OPC-UA server. Add it as a Gateway → OPC Connections → Servers → **OPC-UA client** connection (typical endpoint `opc.tcp://<topserver-host>:49320`; trust certificates in TopServer's OPC UA Configuration Manager → Trusted Clients).
- OmniServer likewise exposes an OPC-UA server for Ignition to consume.
- **Result: zero PLC-side rework; all 22 devices reachable through 2 OPC-UA client connections.** TopServer and OmniServer stay under IT ownership as they are today; we don't have to maintain them.
- UDT instance params: `{OpcServer}` = `TopServer` / `OmniServer`; `{Device}` + `{BasePath}` = the node path inside that server.

**Phase 2 (optional, post-cutover) — migrate to direct Ignition drivers where native support exists:**
- 9 AB MicroLogix → Ignition Allen-Bradley Ethernet driver → 9 individual device connections; eliminates TopServer dependency for those devices.
- 2 Mitsubishi → Ignition Mitsubishi TCP Driver → 2 individual device connections; eliminates TopServer dependency for 5G0.
- Pro-face (4) and scales (7) stay via TopServer/OmniServer — no native driver exists.

**Why §3.1's parameterization makes this seamless:** flip `{OpcServer}` from `TopServer` to `Ignition OPC UA Server` and `{Device}` to the native device name on the 11 migrated instances; nothing else in the definition changes.

**Item-path is uniform — point at a device connection.** At the tag level, a UDT OPC member just references a **device connection by name** via `{Device}` (modeled exactly on the Programmable Device Simulator). The member's `opcItemPath` is the parameter-bound string `ns=1;s=[{Device}]{BasePath}.<Member>`; `{OpcServer}` names the connection, `{Device}` the device within it. Whether that device is the simulator, a native-driver PLC, or a PLC reached through TopServer/OmniServer, the UDT member is identical — only the parameter *values* differ per instance. The exact namespace string for a given connection is a trivial commissioning fill-in, not a design concern.

### 6.2 Integration tracking

`reference/legacy_mes_extract/emmd_automation/integration_manifest.csv` tracks all 22 devices with:

`DeviceCode, DeviceType, Line, LegacyServer, LegacyBasePath, IgnitionNativeDriver, MigrationStrategy, IgnitionOpcServer, IgnitionDeviceName, ValidatedConnected, ValidatedHandshake, Notes` (the last two feed the UDT `{OpcServer}`/`{Device}` params).

Two validation columns (`ValidatedConnected` — OPC connection green in Ignition; `ValidatedHandshake` — a live trigger successfully round-tripped through the watcher) start at `0` and get flipped to `1` as commissioning progresses. The CSV is the checkoff sheet.

---

## 7. Simulation Layer & Harness

Simulation uses **Inductive Automation's Programmable Device Simulator** — no custom mirror, no separate Sim UDT.

- **`MPP_Sim` simulator device** on the `Ignition OPC UA Server`, loaded with a **program CSV** generated from the member catalog (§3.3): one row per member per simulated device — `Time Interval=0, Browse Path=<device>/<member>, Value Source=<writeable literal default>, Data Type=<Ignition type>` (writeable = a plain literal like `false`/`0`/`""`, exactly as in the sample `csv.csv`'s `Writeable/*` rows). Writeable tags are read **and** written over OPC, so the harness can set PLC-side signals and read back what the MES wrote.
- **UDT instances point at the sim**: `{OpcServer}=Ignition OPC UA Server`, `{Device}=MPP_Sim`, `{BasePath}=<device>`. The **same UDT definition** the watchers bind to in production; only the parameters differ. Watcher + app code is identical dev vs prod.
- **Harness** drives the `MPP_Sim` tags through the real handshake sequences: assert `DataReady`/`TrayLocked`, feed a `PartSN`/`VisionPartNumber`, pulse `PartComplete`, and read back what the MES wrote (`PartValid`, `ContainerCount`, alarms). End-to-end watcher tests with **no hardware**.
- Sim scenarios cover: happy path, invalid SN (<6), NoRead bypass (interlock off), vision mismatch (wrong `VisionPartNumber`), container-full closure, disposition fail.

### 7.1 Sim Panel with scenario tracker (flex repeater)

Perspective view `Sim/PlcSimulator` at `/dev/sim/plc`. Layout:

- **Left rail — device selector**: dropdown of the `MPP_Sim` UDT instances grouped by type.
- **Center — device control panel**: buttons/inputs specific to the selected UDT type that write to the instance's members (→ the `MPP_Sim` writeable tags). Examples:
  - Scale: input `NetWeightValue` + checkbox `MetFlag` + [Fire NET_DataReady] button.
  - SerializedMip: input `PartSN`, toggle `HardwareInterlockEnforced`, [Fire DataReady], [Fire PartComplete], [Fire ContainerCountRequest] buttons.
  - NonSerializedMip: [Fire DataReady] button.
  - TrayInspection: input `VisionPartNumber`, 18-checkbox grid `PartDisposition01..18`, [Fire TrayLocked], [Fire InspectionComplete] buttons.
- **Right rail — scenario tracker (flex repeater)** bound to `view.custom.pendingScenarios` (a list of `{title, expectedOutcome, deviceType}` dicts). Each row shows:
  - Scenario title
  - Expected outcome text
  - **[Passed]** button → removes the row from the array (visual check-off)
  - **[Failed]** button → removes the row and appends `{title, timestamp, note}` to `view.custom.failedScenarios` for follow-up
- **Header buttons**: [Reset scenarios] (repopulates from `Sim.getScenariosForDeviceType(type)`), [Copy failed list].

**Scenario seeds** (Python module `Sim.py.getScenariosForDeviceType(type)` — hard-coded, no persistence needed):

| UDT type | Scenarios |
|---|---|
| **ScaleStation** | Target-weight set + `TRG_SendMessage` echo; DataReady rising edge with `MetFlag=False` → weight recorded no close; same with `MetFlag=True` → container close + label; UOM mismatch handled; simultaneous scale + MIP DataReady on 5G0 → correct ordering |
| **SerializedMipStation** | Happy path valid PartSN (≥6) → `PartValid=True`, count increments; invalid PartSN (<6) → `PartValid=False`, alarm text set; `HardwareInterlockEnforced=False` → auto-generated SN accepted; duplicate SN rejected; `ContainerCountRequest` rising edge → count written back; container reaches configured limit → `Container_Complete` fires |
| **NonSerializedMipStation** | Happy path — `Assembly_CompleteTray` mints FG LOT + `PartValid=True`; BOM shortage → alarm; tray container full → new container opens |
| **TrayInspectionStation** | `TrayLocked` → `PartNumber` written for vision recipe; `InspectionComplete` all-pass disposition → container adds; some-fail disposition → per-slot pass/fail recorded, passes only added; `VisionPartNumber` mismatches active LOT Item → line-stop; disposition read while `InspectionComplete=0` → bail (edge-guard test) |

State is transient (view-scoped custom props); [Reset scenarios] repopulates. Failed scenarios accumulate for the session — enough state for a debug pass without a database table.

---

## 8. Versioning of UDT / Tag Artifacts

Gateway **tags live outside the project export** that `scan.ps1` syncs. The tag artifacts are therefore **new tracked files** under `ignition/tags/`: the **4 UDT definition** JSONs, the **UDT-instance** JSONs, and the **`MPP_Sim` simulator program CSV** — imported at deploy via Designer tag import / `system.tag.configure` (definitions/instances) and the simulator device's CSV load (sim). The repo↔gateway sync doc (`ignition-context-pack/09`) is updated to cover the tag-import step. All three are **generated from the one §3.3 member catalog**, so real UDTs and the sim device cannot drift.

---

## 9. Build Phasing (for the implementation plan)

1. **Member catalog + UDT defs** — encode the §3.3 catalog once; generate **4 UDT definitions** (the JSON format of §3.4) + the **`MPP_Sim` simulator program CSV**; commit tag JSON + CSV under `ignition/tags/`.
2. **Sim device + harness** — load `MPP_Sim` into a Programmable Device Simulator on the Ignition OPC UA Server; instantiate the UDTs against it (`{Device}=MPP_Sim`); prove parameter-swing (same definition binds sim now, real device later).
3. **SQL** — `PlcDeviceType` seed + `TerminalPlcDevice` thin-pointer table/procs (TDD); `Item.PlcId` + set/get procs; `SerializedPart_GetBySerial` + mint validate surface. (Plan `docs/superpowers/plans/2026-07-13-plc-integration-sql-foundation.md`.)
4. **onStartup** — resolve `session.custom.plcDevices`.
5. **Watchers** — one per type, edge-subscribed, mapped to procs; tray-inspection does FIFO validation (`Lot_GetWipQueueByLocation` → expected LOT → `Item_GetPlcId` → compare); test end-to-end against the simulator.
6. **Config-Tool editor** — Terminal→device mapping surface (per-terminal list editor; ConfirmUnsaved pattern) + the `PlcId` field on the Item Master Identity surface.
7. **Manifest + commissioning doc** — device-connection manifest with endpoint/driver fill-ins; tag-namespace + InterfaceLog conventions.

Live PLC binding, real endpoints/drivers, and hardware smoke are **commissioning** (gated on plant network + the Pro-face/Mitsubishi/scale driver decisions).

---

## 10. Scope / FDS crosswalk

MVP per FDS §10 (FDS-10-001..013), FDS-01-008/009/014, FDS-06-005/010/012/013/014. Advances the 2026-07-09 readiness-note recommendations (move `_WATCH` config to location attributes; add serial validate surface; centralize system user; durable edge guard). Vision line-stop/escalation (FDS-10-005/009/010) and AIM are separate follow-ups.

## 11. Open items / follow-ups

- ✅ **Resolved this rev:** driver strategy (native AB + Mitsubishi; TopServer/OmniServer via OPC-UA client for Pro-face + scales — §6); sim/real parameter swing (Programmable Device Simulator + parameterized `{OpcServer}`/`{Device}` — §3.1, §7); UDT JSON format (§3.4); obsolete-mechanism audit (§5.3).
- **OI (endpoints):** pull TopServer `.opf` + OmniServer config for per-device IP/port + the exact external-server OPC-UA node-id template (§6.1 nuance) to fill the manifest.
- **Confirm (business logic — §5.2):** legacy `SendMessage` consumer set (buried in Flexware DLL); sort-recipe mapping location; `HardwareInterlockEnable` vs `Enforced` semantics; `WatchDog` presence at Madison; auto-gen-SN semantics for `SerializedPart_Mint`.
- **Confirm:** whether MPP wants `TrayInspectionStation` split 3 ways; A4 serial etch-vs-completion ordering (deferred) as it affects `SerializedPart_Mint`. (`Item.PlcId` model resolved §4.3 — FIFO-validated, per-part.)
- **Confirm (skip list — §5.3):** `NET_PartNumber` scale cross-check and `TRG_TargetWeightUOM` — keep only if MPP confirms they're needed.

## 12. Testing

- SQL: TDD suites for the new table/procs + `Item.PlcId` set/get (INSERT-EXEC pattern).
- Watchers: end-to-end against the simulator harness (§7) — all scenarios green with no hardware.
- No live-PLC assertion in CI; commissioning smoke is manual.
