# PLC Integration — Commissioning Runbook & Designer Handoff

Companion to the three PLC-integration plans (Plan 1 SQL foundation, Plan 2 UDTs/
sim/NQs/Sim-Panel, Plan 3 watchers/onStartup/config). Spec:
`docs/superpowers/specs/2026-07-10-plc-udt-terminal-mapping-design.md`.

**State as of 2026-07-14:** all three plans are built and committed on
`jacques/working`. The SQL layer is green (full reset applies 39 migrations + 349
repeatables clean; 0039 audit-seed test 2/2). The Ignition layer (UDTs, sim, NQs,
Sim Panel, watchers, dispatch, entity wrappers, `/plc-devices` editor) is
file-authored + scanned. **Nothing below has been hardware-smoked** — the watchers
are dormant until the Designer Tag Change scripts wire them (Step B), then they run
against `MPP_Sim` (Step C), then against real devices (Step D).

---

## A. Owed Designer edits (existing views — file-edit boundary)

These four are Designer edits (existing views / gateway config), not file authoring:

### A1. Declare the session prop `custom.plcDevices`
`MPP` session-props → add `custom.plcDevices` with default `[]` (list). Needed
because `onStartup` writes it (there is no `setSessionProps` API — assign directly).

### A2. Extend `onStartup` to resolve the terminal's devices
In `MPP/.../startup/onStartup.py`, after the existing terminal resolution:
```python
termId = self.session.custom.terminal.terminalLocationId  # already resolved
self.session.custom.plcDevices = BlueRidge.Location.TerminalPlcDevice.getByTerminal(termId)
```

### A3. Add the `Item.PlcId` field to Item Master → Identity
In the Item Master Identity section view: add a numeric input bound bidirectionally
to `editDraft.identity.plcId` (seed the empty-shape default per
`feedback_ignition_bidi_nested_path_init`). Save routes through the existing Item
update, or call `BlueRidge.Parts.Item.setPlcId(itemId, plcId)` directly. This is the
per-part vision/recipe code the tray watcher validates against.

### A4. Wire the durable edge triggers (project Tag Change scripts)
For each UDT instance's **trigger** members, add a **project** Tag Change script
(Designer → Project → Scripting → Tag Change) — durable across gateway restart.
One line each:
```python
BlueRidge.Workorder.PlcWatcher.dispatch(str(event.tagPath), event.previousValue, event.currentValue)
```
Trigger members per type:
- **ScaleStation:** `NET_DataReady`
- **SerializedMipStation:** `DataReady`, `PartComplete`
- **NonSerializedMipStation:** `DataReady`
- **TrayInspectionStation:** `TrayLocked`, `InspectionComplete`

`dispatch` rising-edge-guards, resolves the instance's terminal + device type
(`TerminalPlcDevice_GetByInstancePath`), and routes to the right watcher. Tip: a
single tag-change script can target `[MPP]PlcDevices/*/<member>` if the provider
supports wildcard change scripts; otherwise one per instance member.

---

## B. Seed at least one mapping (so dispatch resolves)

Open `/plc-devices` (Config Tool) → pick a terminal → **+ Add mapping**: choose the
device type, enter the DeviceCode, pick the `[MPP]PlcDevices/<device>` instance
path, set SortOrder → Save. (Or insert a `Location.TerminalPlcDevice` row directly
for a quick test.) `dispatch` ignores edges on unmapped instances.

---

## C. Simulator acceptance pass (no hardware)

With A + B done, run every Sim Panel scenario (`/dev/sim/plc`, Plan 2 §7.1) against
the live watchers on `MPP_Sim`. Pick a device, fire its triggers, watch the instance
members change + the DB react; mark Passed/Failed on the tracker. This is the
acceptance gate.

Most-concrete flows to verify first (they call real procs end-to-end):
- **SerializedMip:** queue a LOT at the terminal, fire `DataReady` → `SerializedPart_Mint`
  runs, `PartValid` written; duplicate serial → `PartValid=False` + alarm (gated).
- **TrayInspection:** fire `TrayLocked` → `PartNumber` written from the front LOT's
  `Item.PlcId`; fire `InspectionComplete` with a matching `VisionPartNumber` →
  `OkToContinue=True`; with a mismatch → line-stop (no release, `PlcLineStop` in
  `/audit` InterfaceLog, alarm gated).

---

## D. Per-device hardware commissioning

Per `integration_manifest.csv` (the checkoff sheet), for each of the 22 devices:
1. Add the OPC connection (spec §6): TopServer / OmniServer as **OPC-UA client**
   connections (Phase 1, zero PLC rework), or native AB-Ethernet / Mitsubishi-TCP
   drivers where supported (Phase 2, the 9 AB + 2 Mitsubishi).
2. On the device's UDT instance, flip the parameters from the sim to the real
   device: `{OpcServer}` → `TopServer`/`OmniServer`/`Ignition OPC UA Server`;
   `{Device}` → the real device name; `{BasePath}` → the real address base **incl.
   its trailing separator** (e.g. `5G0_A1.5G0_A1.`). Nothing else changes — same
   UDTs, same watchers. See `ignition/tags/README.md` for the `{BasePath}` scheme.
3. Round-trip one trigger through the watcher, then tick `ValidatedConnected` /
   `ValidatedHandshake` = 1 in the manifest.

---

## E. Open decisions / flagged commissioning fill-ins

The watchers are pure choreography; where the spec left a business decision open,
the code flags a hook rather than faking it (no business logic in Python):

- **NonSerializedMip FG/PieceCount** (`NonSerializedMipWatcher._resolveLineConfig`):
  which finished good a 5A2 line produces + the tray piece count. Source TBD (Item
  attribute? per-line config? active WO?). Returns None → edge is ack'd, completion
  skipped, until wired.
- **Scale weight persistence + completion coupling** (`ScaleWatcher._completeCoupledContainer`):
  no raw-weight-record proc (weight is captured in InterfaceLog); the 5G0 scale↔MIP
  container-completion coupling (legacy hardcoded count=60 → `ContainerConfig`
  closure) is line-specific. Returns None → skip until supplied.
- **Serialized min-length rule:** `len(PartSN) ≥ 6` when the interlock is enforced is
  NOT in `SerializedPart_Mint` (which does dedup + auto-gen). If MPP wants a hard
  gate, add it to the proc (spec §5.2 item 4 flags interlock semantics).
- **Tray-close bookkeeping:** on a vision match the tray is released; the tray-close
  (open-container resolution, tray position, passed-parts count from
  `PartDisposition01..18`) is line-specific — wire via `Container.getOpenByCell` +
  `Container.trayClose` at commissioning.
- **Line-stop policy:** a vision mismatch stops the line (tray left locked) + records
  a `PlcLineStop` event + alarm. Whether to also auto-place a formal `Quality.Hold`
  is a policy choice (left out to avoid an unrequested disruptive hold).
- Carried from spec §5.2/§11: `SendMessage` legacy consumer enumeration; sort-recipe
  mapping source; Mitsubishi series / Pro-face / OmniServer-scale driver specifics;
  `WatchDog` heartbeat (absent from the EMMD extract — confirm at Madison); A4
  serial etch-vs-completion ordering.

---

## F. What NOT to build (spec §5.3 — deliberately skipped)

`SendMessage` XML message bus (→ direct proc calls); hardcoded `ContainerCount=60`
(→ `ContainerConfig`); the 5G0 dual-path DataReady hack; EMMD engine scaffolding.
HMI-display members (`MESAlarmText/Type`, `PartType`, `ContainerName`,
`ContainerCount`-as-display) are declared but **written only when the instance's
`WriteDisplayEnabled` memory member is 1** (off by default — Perspective renders
these from MES state at the terminal).
