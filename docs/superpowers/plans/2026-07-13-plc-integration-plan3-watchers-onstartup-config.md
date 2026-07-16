# PLC Integration — Plan 3: Watchers + onStartup + Config-Tool Editor

> **For agentic workers:** superpowers:subagent-driven-development or executing-plans. **Ignition file-authoring + gateway scripts** — validated end-to-end against the `MPP_Sim` simulator (Plan 2), not live PLCs. Live binding, real endpoints/drivers, and hardware smoke are **commissioning** (gated on plant network + the Pro-face/Mitsubishi/scale driver decisions). New scripts/views safe on disk; edits to existing views (onStartup, Item Master) via Designer per the file-edit boundary.

**Goal:** Replay each PLC device type's handshake against the MES stored procs — the Ignition gateway watchers take the legacy EMMD engine's role; the procs take `MESCore`'s. Resolve a terminal's devices at session start; add the Config-Tool surfaces to author the terminal→device mapping and `Item.PlcId`. Everything exercised via the Plan 2 Sim Panel with no hardware.

**Architecture:** One gateway watcher module per UDT type (Scale / SerializedMip / NonSerializedMip / TrayInspection), extending the established `DowntimePlc`/`AssemblyPlc` `_WATCH` pattern but edge-driven via **project Tag Change scripts** (durable across gateway restart — the 2026-07-09 readiness note's concern). `onStartup` resolves `TerminalPlcDevice_GetByTerminal` into `session.custom.plcDevices`. The tray-inspection watcher does **FIFO validation**: front of the assembly-out queue → expected LOT → `Item.PlcId` → compare the vision code.

**Tech Stack:** Ignition 8.3 gateway Jython (tag-change events + `system.tag.readBlocking`/`writeBlocking`), Perspective views, the Plan 1 procs via the Plan 2 Core NQs.

**Spec:** `2026-07-10-plc-udt-terminal-mapping-design.md` §4.3/4.4 (Item.PlcId + FIFO + onStartup), §5 (handshake archetypes + write-tag audit + legacy business logic §5.2 + obsolescence §5.3), §6 (drivers). **Depends on:** Plan 1 (procs), Plan 2 (UDT instances, `MPP_Sim`, NQs, Sim Panel).

## Global Constraints

- **No business logic in Python** (memory `feedback_no_business_logic_in_python`): matrices/thresholds/transitions live in SQL. Watchers are choreography + proc calls only.
- **Watchers edge-trigger on the rising edge** of trigger members (`DataReady`/`PartComplete`/`TrayLocked`/`InspectionComplete`/`NET_DataReady`) — legacy events fire on data-change then bail if 0 (spec §3.3). Use **project Tag Change scripts** on the instance trigger members (durable), not module-memory edge state.
- **Every handshake transaction logs to `Audit.InterfaceLog`; failures to `Audit.FailureLog`** (FDS-01-014) via the existing `Audit_LogInterfaceCall`.
- **Centralize `systemAppUserId()`** in `BlueRidge.Common.Util` + seed a verified system `AppUser`; watchers pass `terminalLocationId` (readiness-note gaps). No ad-hoc `_SYSTEM_APP_USER_ID = 1`.
- **HMI-display writes gated by the instance `WriteDisplayEnabled` member** (spec §5.1) — off by default; watcher checks before writing `MESAlarmText`/`MESAlarmType`/`PartType`/`ContainerName`/`ContainerCount`-as-display. Do NOT build the obsolete mechanisms in §5.3 (`SendMessage` bus, hardcoded count=60 → use `ContainerConfig`, message-handler events).
- **onStartup** resolves plumbing only; `session.custom.plcDevices` must be pre-declared in `session-props/props.json` (memory `feedback_ignition_setsessionprops_not_real`).
- **After authoring any Ignition resource: `.\scan.ps1`.** Existing-view edits (onStartup.py, Item Master Identity) via Designer (file-edit boundary).

---

## File Structure

**Created (Core gateway scripts / entity wrappers):**
- `.../Core/ignition/script-python/BlueRidge/Location/TerminalPlcDevice/code.py` — `getByTerminal/save/deprecate` (wrap the Plan 2 NQs).
- `.../BlueRidge/Workorder/PlcWatcher/code.py` — shared watcher helpers: edge-guard read, `systemAppUserId()` usage, InterfaceLog wrap, instance-member read/write by path.
- `.../BlueRidge/Workorder/ScaleWatcher/`, `SerializedMipWatcher/`, `NonSerializedMipWatcher/`, `TrayInspectionWatcher/` `code.py` — one per type; each `handleEdge(instancePath, terminalLocationId)`.
- `.../BlueRidge/Parts/Item/code.py` — extend with `getPlcId/setPlcId` (wrap NQs).
- `.../BlueRidge/Lots/SerializedPart/code.py` — `getBySerial` + `mint(itemId, lotId, serialNumber, appUserId, terminalLocationId)`.
- `.../BlueRidge/Common/Util/code.py` — add `systemAppUserId()`.

**Created (tag-change bindings):** project Tag Change scripts (Designer: Project → Scripting → Tag Change) on each instance's trigger members → dispatch to the matching watcher. (Documented; authored in Designer.)

**Created (Config-Tool):**
- `.../MPP_Config/.../views/PlcDevices/{view.json,resource.json}` + row sub-view — the terminal→device mapping editor.
- Route `/plc-devices`.

**Modified (Designer):**
- `.../MPP/.../startup/onStartup.py` — resolve `session.custom.plcDevices`.
- `.../MPP/.../session-props/props.json` — declare `custom.plcDevices` (list default `[]`).
- Item Master Identity section view — add the `PlcId` field (Int, bidi to `editDraft.identity.plcId`; seed the empty shape, memory `feedback_ignition_bidi_nested_path_init`) + save via `Item_SetPlcId`.
- **New Deps:** a `Lots.SerializedPart_GetBySerial`-backed validate + optional `@SerialNumber` mint are already in Plan 1; a system `AppUser` seed migration if none exists (`0038` — check first).

---

### Task 1: System user + `onStartup` device resolution

- [ ] **Step 1:** Confirm a verified system `AppUser` exists (Initials `SYS` bootstrap row from migration 0012). Add `BlueRidge.Common.Util.systemAppUserId()` returning its Id (single source; replaces `_SYSTEM_APP_USER_ID = 1`).
- [ ] **Step 2:** Declare `session.custom.plcDevices` (`[]`) in `MPP/session-props/props.json` (Designer).
- [ ] **Step 3:** Add `BlueRidge.Location.TerminalPlcDevice.getByTerminal(terminalLocationId)` (wrap the `location/TerminalPlcDevice_GetByTerminal` NQ → list of `{id,deviceCode,deviceType,udtInstancePath,sortOrder}`).
- [ ] **Step 4:** Extend `onStartup.py` (Designer): after terminal resolution, `session.custom.plcDevices = BlueRidge.Location.TerminalPlcDevice.getByTerminal(terminalLocationId)`.
- [ ] **Step 5:** `.\scan.ps1`; smoke: seed one `TerminalPlcDevice` row (via Task 5 editor or SQL) pointing at a `PlcDevices/*` instance, open a session on that terminal, confirm `session.custom.plcDevices` populates. Commit.

---

### Task 2: Shared watcher helpers + edge dispatch

- [ ] **Step 1:** `BlueRidge.Workorder.PlcWatcher`: helpers to (a) read/write an instance member by `udtInstancePath + memberName`; (b) rising-edge guard (compare previousValue→currentValue in the tag-change payload, act only on false→true); (c) `logInterface(procName, params, result)` → `Audit_LogInterfaceCall`; (d) resolve the terminal(s) that drive a given instance (reverse of `plcDevices`, or a `TerminalPlcDevice_GetByInstancePath` NQ — add if needed).
- [ ] **Step 2:** Author the tag-change dispatch pattern (Designer Tag Change script on trigger members): on rising edge, look up the instance's device type, call the matching `*Watcher.handleEdge(instancePath, terminalLocationId, memberName)`.
- [ ] **Step 3:** `.\scan.ps1`; unit-smoke a helper (write a `MPP_Sim` trigger tag high, confirm the dispatch fires once). Commit.

---

### Task 3: Scale + NonSerializedMip + SerializedMip watchers

Each `handleEdge` replays the spec §5 archetype against procs; gate HMI writes on `WriteDisplayEnabled`.

- [ ] **Step 1 — ScaleWatcher:** on `NET_DataReady↑` → read `NET_NetWeightValue`/`NET_NetWeightUOM`/`NET_TargetWeightMetFlag` → clear them → record the weight against the active LOT (existing weight/close proc; ByWeight closure via `ContainerConfig`) → if metFlag, close+label. Target-weight change: write `TRG_*` + pulse `TRG_SendMessage`. Test via Sim Panel scale scenarios.
- [ ] **Step 2 — NonSerializedMipWatcher:** on `DataReady↑` → set `TransInProc` → `Workorder.Assembly_CompleteTray` (mint FG LOT) → `PartValid` → reset `TransInProc`/`DataReady`. Alarm/PartType writes gated by `WriteDisplayEnabled`.
- [ ] **Step 3 — SerializedMipWatcher:** on `DataReady↑`/`PartComplete↑` → `TransInProc` → read `PartSN`+`HardwareInterlockEnforced` → validate (len≥6; if interlock off accept blank → `SerializedPart_Mint` auto-gens) → `SerializedPart_Mint(@SerialNumber=PartSN)` (dedup via `SerializedPart_GetBySerial`) → `PartValid`+`ContainerCount`+`PartType` → reset `TransInProc`/`PartComplete`. Scale-coupled completion + `ContainerCountRequest` handled per §5 (count-request/echo is display — skip per §5.3 unless MPP wants).
- [ ] **Step 4:** `.\scan.ps1`; drive each type's Sim Panel scenarios end-to-end; mark them Passed. Commit per watcher.

---

### Task 4: TrayInspection watcher (FIFO validation)

- [ ] **Step 1:** on `TrayLocked↑` → read the terminal's **assembly-out queue** via `Lots.Lot_GetWipQueueByLocation(locationId, operationTypeCode, includeDescendants)` → front LOT → its Item → `Parts.Item_GetPlcId(itemId)` → write that as `PartNumber` (vision recipe select) + `ContainerName`/`OkToContinue` (gated).
- [ ] **Step 2:** on `InspectionComplete↑` (bail if 0) → read `VisionPartNumber` (+ `PartDisposition01..18` where wired) → **validate** the vision code == expected LOT's `Item.PlcId`; mismatch → wrong-part alarm + line-stop (FDS-10-005/010, record the line-stop event); match → close the tray (existing tray-inspection close proc), passes-only added.
- [ ] **Step 3:** `.\scan.ps1`; Sim Panel tray scenarios: recipe write on lock, all-pass adds, disposition-fail records per-slot, vision mismatch → line-stop, edge-guard (disposition read while InspectionComplete=0 bails). Commit.

> The FIFO read `Lot_GetWipQueueByLocation` exists (2026-07-07). If it doesn't already return `Item.PlcId`, either add it to its SELECT (small proc edit + test) or resolve via `Item_GetPlcId` after reading the front LOT's ItemId — the latter needs no proc change.

---

### Task 5: Config-Tool editor — terminal→device mapping + Item.PlcId

- [ ] **Step 1 — Item.PlcId field:** add a numeric `PlcId` input to the Item Master **Identity** section (Designer edit; bidi to `editDraft.identity.plcId`, seed the empty-shape default). Save routes through the existing Item update path or a dedicated `Item_SetPlcId` call.
- [ ] **Step 2 — Mapping editor:** new `/plc-devices` view (file-authored). Pick a Terminal → list its `TerminalPlcDevice` rows (`TerminalPlcDevice_GetByTerminal`) → add/edit (type dropdown from `PlcDeviceType`, DeviceCode, `UdtInstancePath` picker of `PlcDevices/*` instances) via `TerminalPlcDevice_Save`; deprecate via `_Deprecate`. Up/down arrows for SortOrder (no drag). ConfirmUnsaved on dirty switch.
- [ ] **Step 3:** `.\scan.ps1`; Designer smoke both surfaces; confirm audit rows (`Item`/`TerminalPlcDevice`) render in `/audit`. Commit.

---

### Task 6: End-to-end simulator validation + commissioning doc

- [ ] **Step 1:** Run **all** Sim Panel scenarios (Plan 2 §7.1) against the live watchers on `MPP_Sim`; every scenario Passed or a real bug filed. This is the acceptance gate (no hardware).
- [ ] **Step 2:** Write a short **commissioning runbook** (`notes/` or `docs/`): per-device, add the Ignition OPC-UA connection (native AB/Mitsubishi, or TopServer/OmniServer OPC-UA client — spec §6), set the real device endpoint, flip the instance `{OpcServer}`/`{Device}` from `MPP_Sim` to the real device, tick `integration_manifest.csv` `ValidatedConnected`/`ValidatedHandshake`. Note the driver decisions still open (Pro-face, Mitsubishi series, scale serial).
- [ ] **Step 3:** Commit.

---

## Open items carried from the spec (§11)
- Driver strategy specifics (Pro-face LT3300, Mitsubishi series, OmniServer-scale) — commissioning.
- Real per-device endpoints (pull TopServer `.opf` / OmniServer config).
- `SendMessage` legacy consumer enumeration (§5.2) before assuming nothing else listens.
- Sort-recipe mapping source (§5.2); A4 serial etch-vs-completion ordering as it affects mint timing.

## Self-Review checklist
- Watchers call procs only (no business logic in Python); every transaction InterfaceLog'd.
- Edge triggers are rising-edge, durable (tag-change scripts, not module memory).
- HMI-display writes gated by `WriteDisplayEnabled`; obsolete §5.3 mechanisms NOT built.
- Tray FIFO validation reads the queue → Item.PlcId → compares; mismatch line-stops.
- onStartup resolves `plcDevices`; session prop declared. Config edits done in Designer; audits render.
- All Sim Panel scenarios pass end-to-end against `MPP_Sim`.
