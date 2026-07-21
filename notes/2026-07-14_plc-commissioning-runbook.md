# PLC Integration — Commissioning Runbook & Designer Handoff

Companion to the three PLC-integration plans (Plan 1 SQL foundation, Plan 2 UDTs/
sim/NQs/Sim-Panel, Plan 3 watchers/onStartup/config). Spec:
`docs/superpowers/specs/2026-07-10-plc-udt-terminal-mapping-design.md`.

**State as of 2026-07-14:** all three plans are built and committed on
`jacques/working`. The SQL layer is green (full reset applies 39 migrations + 349
repeatables clean; 0039 audit-seed test 2/2). The Ignition layer (UDTs, sim, NQs,
Sim Panel, watchers, dispatch, entity wrappers, `/plc-devices` editor) is
file-authored + scanned. **Nothing below has been hardware-smoked** — the watchers
are dormant until the Designer Tag Change scripts wire them (Step A4), then they run
against `MPP_Sim` (Step C), then against real devices (Step D).

> **Update 2026-07-21:** **A4 is DONE** — the gateway Tag Change script
> `TrayDataReady` exists in the MPP project (`MPP/ignition/tag-change/TrayDataReady/`,
> created by `admin` 2026-07-14, `enabled`, scope G) with the correct
> `PlcWatcher.dispatch` body and the **33 explicit trigger paths** (not a folder
> wildcard). **Step B for 59B is DONE** — a `TerminalPlcDevice` mapping row was
> seeded (terminal 158 `MA2-59B-AOUT1` → ScaleStation → `[MPP]PlcDevices/59B_1_FP_1`).
> The ByVision + ByWeight tray CLOSE is now wired (see Section E, was a
> commissioning fill-in): both route through `Assembly.plcCompleteTray` → the same
> `Assembly_CompleteTray` proc the operator uses. So the 59B ByWeight chain is live
> and ready for the Sim acceptance pass (Step C) — no Designer work outstanding for
> 59B. The `/plc-devices` editor is now linked in the Config Tool nav (System).

---

## A. Wiring edits

**A1–A3 are DONE in files** (committed `06117aaa`; Designer was closed). **A4 is the
one remaining Designer step.** A1–A3 recorded here for reference.

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

### A4. Wire the durable edge triggers (gateway Tag Change script) — ✅ DONE 2026-07-14

**Status: complete.** The script `TrayDataReady` exists at
`ignition/projects/MPP/ignition/tag-change/TrayDataReady/` (`enabled`, scope `G`,
`changeTypes` = ValueChange/QualityChange/TimestampChange). Its body is the
`PlcWatcher.dispatch` one-liner and its `paths` are the **33 explicit trigger
tags** below — the surgical allow-list, not a folder wildcard. No further Designer
work is needed for the tag-change wiring. The rest of this section is retained as
reference for how it was set up / how to extend it.

This step stays in Designer: the gateway Tag Change script's tag-path binding
depends on your actual imported tag paths, and the 8.3 gateway tag-change resource
schema isn't safely hand-authored. It's a 2-minute point-and-click.

**Prefer the explicit-path allow-list over the folder wildcard** (what
`TrayDataReady` uses): list the 33 boolean trigger members one per line so the
script fires ONLY on real handshake edges, never on weight-value ticks or other
members. `[MPP]PlcDevices/*` would also work (dispatch no-ops on non-triggers) but
over-subscribes.

**Simplest (recommended): one folder-watch script.** Add a **gateway** Tag Change
script (Designer → Project → Scripting → Gateway Event Scripts → Tag Change) on the
**whole folder** `[MPP]PlcDevices` (recursive). Body (one line):
```python
BlueRidge.Workorder.PlcWatcher.dispatch(str(event.tagPath), event.previousValue, event.currentValue)
```
Why one folder-watch script is safe: `dispatch` rising-edge-guards and routes by
device type; each watcher's `handleEdge` ignores any member that isn't one of its
triggers. So firing on non-trigger members is harmless (a cheap no-op) — you don't
need to enumerate members. `dispatch` resolves the instance's terminal + type via
`TerminalPlcDevice_GetByInstancePath` (so a mapping row must exist — Step B).

**Alternative: list the trigger paths explicitly.** If you'd rather bind exact
paths, the 33 trigger-member paths are in `ignition/tags/plc_trigger_tag_paths.txt`
(regenerate if devices change). Trigger members per type:
- **ScaleStation:** `NET_DataReady`
- **SerializedMipStation:** `DataReady`, `PartComplete`
- **NonSerializedMipStation:** `DataReady`
- **TrayInspectionStation:** `TrayLocked`, `InspectionComplete`

Adjust the `[MPP]` provider prefix if you imported into a differently-named provider
(and update `PROVIDER` in `BlueRidge.Sim` + `_INSTANCE_ROOT` in
`BlueRidge.Location.TerminalPlcDevice` to match).

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
