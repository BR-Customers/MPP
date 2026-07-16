# PLC Integration — Plan 2: Ignition UDTs + Simulator + Sim Panel

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. **This is Ignition file-authoring** — validation is `scan.ps1` + Designer smoke, not a SQL test runner. New tag/view/NQ files are safe to author on disk; *edits to existing* views go through Designer (file-edit boundary).

**Goal:** Stand up the 4 PLC UDT definitions, the `MPP_Sim` Programmable Device Simulator, one UDT instance per active device, a Sim Panel for scenario validation, and Named Queries exposing the Plan 1 procs — so the handshake watchers (Plan 3) have tags to bind and a simulator to test against without hardware.

**Architecture:** 4 functional UDT definitions parameterized by `{OpcServer}`/`{Device}`/`{BasePath}` (spec §3.1/§3.4). Instances point `{Device}=MPP_Sim` in dev (a simulator device on the Ignition OPC-UA Server carrying writeable tags matching each member). Same definitions repoint to real devices at commissioning by swapping parameters. NQs live in Core.

**Tech Stack:** Ignition 8.3 (tags exported as JSON, Perspective views as `view.json`, Named Queries as folder+`query.sql`+`resource.json`, gateway scripts as Jython). Repo↔gateway sync via `scan.ps1`.

**Spec:** `docs/superpowers/specs/2026-07-10-plc-udt-terminal-mapping-design.md` — §3.2 (types), §3.3 (member catalog), §3.4 (JSON format), §5.1/§5.3 (write gating / obsolescence), §7 (sim). **Reference format samples:** `reference/ignition_udt_samples/` (`SampleUDT.json`, `SampleUDTInstance.json`, `ProgrammableDeviceSimulator_sample.csv`). **Device list:** `reference/legacy_mes_extract/emmd_automation/integration_manifest.csv` + `device_rollup.tsv` + `tag_catalog.tsv`.

## Global Constraints

- **Tag artifacts are new tracked files** under a new `ignition/tags/` tree (gateway tags live outside the project export `scan.ps1` syncs). Committed as exported tag JSON; imported at deploy via Designer tag import / `system.tag.configure`. Update `ignition-context-pack/09` to cover the tag-import step.
- **UDT JSON format = `reference/ignition_udt_samples/SampleUDT.json` exactly:** `{"name","tagType":"UdtType","parameters":{...},"tags":[...]}`; OPC members `{"valueSource":"opc","opcServer":{"bindType":"parameter","binding":"{OpcServer}"},"opcItemPath":{"bindType":"parameter","binding":"ns=1;s=[{Device}]{BasePath}.<Member>"},"dataType":"<IgnitionType>"}`; memory members `{"valueSource":"memory","dataType":...,"defaultValue":...}`. `=`/`;` serialize as `=`/`;` when Designer rewrites (author literal, don't fight it).
- **Ignition datatypes:** BOOL→`Boolean`, INT→`Int4`, REAL→`Float8`, STRING→`String` (per §3.4).
- **Members carry direction metadata only in documentation** — the UDT declares all members; the watcher (Plan 3) decides read vs write. HMI-display members get a sibling `WriteDisplayEnabled` **memory** member (spec §5.1).
- **NQs live ONLY in Core** (`ignition/projects/Core/ignition/named-query/<domain>/<Proc>/` with `query.sql` + `resource.json`); MPP/MPP_Config have none (memory `project_mpp_nq_core_topology`). Mutation-proc NQs need `attributes.type: "Query"` (memory `feedback_ignition_nq_type_for_status_row_procs`).
- **After authoring any Ignition resource: run `.\scan.ps1`** (memory `feedback_ignition_gateway_scan`); no gateway restart needed for NQs/tags.
- **Perspective view folders need BOTH `view.json` AND `resource.json`** (memory `feedback_ignition_view_needs_resource_json`).
- **ASCII-only** in all authored strings.

---

## File Structure

**Created (tags):**
- `ignition/tags/udt/ScaleStation.json`, `SerializedMipStation.json`, `NonSerializedMipStation.json`, `TrayInspectionStation.json` — the 4 UDT definitions.
- `ignition/tags/instances/PlcDevices.json` — the ~20 UDT instances (one per active device), all `{Device}=MPP_Sim` for dev.
- `ignition/tags/sim/MPP_Sim_program.csv` — the Programmable Device Simulator program (writeable tags per member per device).
- `ignition/tags/README.md` — how to import (Designer tag import order: defs → instances; simulator CSV load) + regeneration note.

**Created (Named Queries, Core):**
- `ignition/projects/Core/ignition/named-query/location/TerminalPlcDevice_Save/` (+`_GetByTerminal/`, `_Deprecate/`)
- `ignition/projects/Core/ignition/named-query/parts/Item_SetPlcId/` (+`Item_GetPlcId/`)
- `ignition/projects/Core/ignition/named-query/lots/SerializedPart_GetBySerial/`

**Created (Sim Panel view, MPP):**
- `ignition/projects/MPP/com.inductiveautomation.perspective/views/Dev/PlcSimulator/view.json` (+`resource.json`)
- row sub-views under `Components/PlantFloor/Sim/` if the scenario repeater needs them (Ignition can't nest a view under another view).

**Modified:**
- `ignition-context-pack/09_repo_gateway_sync.md` — add the tag-import step.

---

### Task 1: The 4 UDT definitions

**Files:** Create `ignition/tags/udt/{ScaleStation,SerializedMipStation,NonSerializedMipStation,TrayInspectionStation}.json`

**Interfaces produced:** 4 `UdtType` definitions, each with parameters `OpcServer` (String, default `Ignition OPC UA Server`), `Device` (String, default `MPP_Sim`), `BasePath` (String), and the members below. Each OPC member's `opcItemPath.binding = "ns=1;s=[{Device}]{BasePath}.<Member>"`.

**Member catalog (from spec §3.3 — datatype / valueSource):**

- **ScaleStation:** `NET_DataReady`(Boolean,opc), `NET_NetWeightValue`(Float8,opc), `NET_NetWeightUOM`(String,opc), `NET_TargetWeightMetFlag`(Boolean,opc), `NET_PartNumber`(String,opc — 59B only, keep in the def), `TRG_TargetWeightValue`(Float8,opc), `TRG_TargetWeightUOM`(String,opc), `TRG_ToleranceWeightValue`(Float8,opc), `TRG_SendMessage`(Boolean,opc).
- **SerializedMipStation:** `DataReady`(Boolean), `TransInProc`(Boolean), `PartSN`(String), `PartComplete`(Boolean), `HardwareInterlockEnforced`(Boolean), `PartValid`(Boolean), `ContainerCount`(Int4), `ContainerCountRequest`(Boolean), `PartType`(Int4), `MESAlarmType`(Int4), `MESAlarmText`(String) — all opc — plus `WriteDisplayEnabled`(Boolean, **memory**, defaultValue False).
- **NonSerializedMipStation:** `DataReady`(Boolean), `TransInProc`(Boolean), `PartValid`(Boolean), `PartType`(Int4), `MESAlarmType`(Int4), `MESAlarmText`(String) — all opc — plus `WriteDisplayEnabled`(Boolean, memory, False).
- **TrayInspectionStation:** `TrayLocked`(Boolean), `InspectionComplete`(Boolean), `PartNumber`(Int4), `VisionPartNumber`(Int4), `PartDisposition01`..`PartDisposition18`(Boolean ×18), `OkToContinue`(Boolean), `ContainerName`(String) — all opc — plus `WriteDisplayEnabled`(Boolean, memory, False).

- [ ] **Step 1:** Author `ScaleStation.json` from the `SampleUDT.json` shape — parameters block + one OPC member per catalog row. Verify the `opcItemPath.binding` uses `{Device}`/`{BasePath}` and `opcServer` binds `{OpcServer}`.
- [ ] **Step 2:** Author the other 3 defs the same way (include the `WriteDisplayEnabled` memory member on the 3 MIP/tray types).
- [ ] **Step 3:** `.\scan.ps1`; in Designer, import the 4 defs (Tag Browser → Import); confirm each shows its parameters + members with no red quality on the definition (instances resolve at Task 3).
- [ ] **Step 4:** Commit. `git add ignition/tags/udt/ && git commit -m "feat(plc): 4 PLC UDT definitions (Scale/SerializedMip/NonSerializedMip/TrayInspection)"`

---

### Task 2: `MPP_Sim` simulator program CSV

**Files:** Create `ignition/tags/sim/MPP_Sim_program.csv`

**Format** (`ProgrammableDeviceSimulator_sample.csv`): `Time Interval, Browse Path, Value Source, Data Type`. One **writeable** row per member per active device: `Value Source` = a literal default (`false` / `0` / `""` / `0.0`) which makes it writeable; `Browse Path` = `<DeviceCode>/<Member>`; `Data Type` per §3.4.

- [ ] **Step 1:** For each active device in `integration_manifest.csv`, emit one row per member of its UDT type (from Task 1 catalog). E.g. `5G0_A1/DataReady`, `5G0_A1/PartSN`, … ; `59B_1_FP_1/NET_NetWeightValue`, …
- [ ] **Step 2:** In Designer, add a **Programmable Device Simulator** device named `MPP_Sim` on the Ignition OPC-UA Server; load this CSV as its program. Confirm the tags browse under `[MPP_Sim]<DeviceCode>/<Member>`.
- [ ] **Step 3:** Commit. `git add ignition/tags/sim/ && git commit -m "feat(plc): MPP_Sim device-simulator program (writeable tags per member per device)"`

---

### Task 3: UDT instances (one per active device)

**Files:** Create `ignition/tags/instances/PlcDevices.json` (a folder of instances)

**Format** (`SampleUDTInstance.json`): `{"name":"<DeviceCode>","tagType":"UdtInstance","typeId":"<UDT type>","parameters":{"OpcServer":{"value":"Ignition OPC UA Server"},"Device":{"value":"MPP_Sim"},"BasePath":{"value":"<DeviceCode>"}}}`.

- [ ] **Step 1:** One instance per active device (map DeviceCode → UDT type via `integration_manifest.csv.DeviceType`). All `{Device}=MPP_Sim`, `{BasePath}=<DeviceCode>` (matching the sim CSV Browse Path prefix).
- [ ] **Step 2:** `.\scan.ps1`; Designer tag import; confirm each instance's OPC members resolve to `[MPP_Sim]<DeviceCode>/<Member>` with **Good** quality (write a value to a `MPP_Sim` tag, watch the instance member read it).
- [ ] **Step 3:** Commit. `git add ignition/tags/instances/ && git commit -m "feat(plc): UDT instances per active device (pointed at MPP_Sim)"`

> The DB `TerminalPlcDevice.UdtInstancePath` values (Plan 1) reference these instances, e.g. `[MPP]PlcDevices/5G0_A1` — confirm the provider/folder naming matches when seeding the mapping.

---

### Task 4: Named Queries for the Plan 1 procs

**Files:** Create the 6 NQ folders under `ignition/projects/Core/ignition/named-query/` (see File Structure).

Each folder: `query.sql` (`EXEC Schema.Proc @p = :param, ...`) + `resource.json` (copy an existing NQ's `resource.json`; `scope "DG"`, `database "MPP"`, `parameters[]` with correct `sqlType` ints — 3=BIGINT, 7/12=NVARCHAR, 4=INT; `files:["query.sql"]`). **Mutation-proc NQs** (`TerminalPlcDevice_Save/_Deprecate`, `Item_SetPlcId`) set `attributes.type: "Query"` (they return a status row).

- [ ] **Step 1:** Author the 3 `location/TerminalPlcDevice_*` NQs. `_GetByTerminal` is a read (type may be Query, params `terminalLocationId`).
- [ ] **Step 2:** Author `parts/Item_SetPlcId`, `parts/Item_GetPlcId`, `lots/SerializedPart_GetBySerial`.
- [ ] **Step 3:** `.\scan.ps1`; in Designer, run each NQ from the Named Query editor test panel with sample params against `MPP_MES_Dev` — confirm a status row / rowset returns (no "result set generated for update" error → confirms the `type: "Query"` fix).
- [ ] **Step 4:** Commit. `git add ignition/projects/Core/ignition/named-query/{location,parts,lots}/ && git commit -m "feat(plc): Core NQs for TerminalPlcDevice + Item.PlcId + SerializedPart_GetBySerial"`

---

### Task 5: Sim Panel view (`/dev/sim/plc`)

**Files:** Create `ignition/projects/MPP/.../views/Dev/PlcSimulator/{view.json,resource.json}` + any repeater row sub-view under `Components/PlantFloor/Sim/`. Add a route `/dev/sim/plc`.

**Layout (spec §7.1):** left rail device dropdown (the `PlcDevices/*` instances grouped by type); center per-type control panel that writes to the selected instance's members (→ the `MPP_Sim` writeable tags) — Scale: NetWeightValue input + MetFlag checkbox + [Fire NET_DataReady]; SerializedMip: PartSN input + HardwareInterlockEnforced toggle + [Fire DataReady]/[Fire PartComplete]/[Fire ContainerCountRequest]; NonSerializedMip: [Fire DataReady]; TrayInspection: VisionPartNumber input + 18-checkbox disposition grid + [Fire TrayLocked]/[Fire InspectionComplete]. Right rail **scenario tracker flex-repeater** bound to `view.custom.pendingScenarios` (`{title,expectedOutcome,deviceType}`), each row [Passed] (splice out) / [Failed] (splice out + append to `view.custom.failedScenarios`); header [Reset scenarios] (repopulate from `Sim.getScenariosForDeviceType(type)`) + [Copy failed list]. Scenario seeds table is in spec §7.1.

- [ ] **Step 1:** Author the view (new view → file-authoring is safe). Writes use `system.tag.writeBlocking` against the selected instance's member paths (dom-event scripts need `scope:"G"` — memory `feedback_ignition_popup_open_scope`; event bodies start with `\t` — memory `feedback_ignition_event_script_indent`).
- [ ] **Step 2:** Add the `Sim` entity script (`BlueRidge.Sim.getScenariosForDeviceType`) in Core with the §7.1 hard-coded scenarios.
- [ ] **Step 3:** `.\scan.ps1`; Designer smoke: open `/dev/sim/plc`, fire a couple of triggers, watch the instance members change, splice a scenario. (End-to-end watcher validation is Plan 3.)
- [ ] **Step 4:** Commit.

---

### Task 6: Tag-import doc + scan verify

- [ ] **Step 1:** Update `ignition-context-pack/09_repo_gateway_sync.md` with the tag-import step (defs → instances; simulator CSV load) and note `ignition/tags/` is import-managed, not scan-synced.
- [ ] **Step 2:** Final `.\scan.ps1`; confirm no scan errors. Commit.

---

## Downstream (Plan 3)
Watchers bind to the `PlcDevices/*` instances; `onStartup` resolves `TerminalPlcDevice_GetByTerminal` → `session.custom.plcDevices` (list of `udtInstancePath`); the Config-Tool editor writes the `TerminalPlcDevice` mapping + `Item.PlcId` via the Task-4 NQs. The Sim Panel scenarios become the watcher acceptance tests.

## Self-Review checklist (run before handoff)
- 4 UDT defs match §3.3 member sets + §3.4 format; `WriteDisplayEnabled` memory member on the 3 non-scale types.
- Sim CSV covers every member of every active device; Browse Path prefix = `{BasePath}` used by instances.
- Instances: type mapping correct; all point at `MPP_Sim`.
- NQs: mutation ones set `type:"Query"`; all in Core; params typed.
- Sim Panel: dom-event scripts `scope:"G"` + `\t`-indented; new view has `resource.json`.
