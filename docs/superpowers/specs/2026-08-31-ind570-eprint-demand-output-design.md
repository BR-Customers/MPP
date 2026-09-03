# IND570 Scale Integration over EPrint Demand Output — Design Spec

**Date:** 2026-08-31
**Status:** Draft — awaiting Jacques review. **Transport proven on the bench 2026-08-31**: EPrint publishing continuous frames into Ignition's TCP driver on `172.17.20.127:1702`. Demand output not yet validated; parse grammar in §5.2 is still written against the manual rather than captured bytes. Session record: `notes/2026-08-31_ind570-eprint-commissioning.md`.
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor) — Machining & Assembly checkweigh validation.
**Supersedes:** `docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md` (the Modbus TCP transport design). That spec's *scope*, *schema* and *tray-closure* decisions carry forward; its *transport* is withdrawn.
**Source of protocol truth:** `reference/IND570_User_Guide.txt` (METTLER TOLEDO doc 30205308 rev 07, 04/2017) — §3.8.5 Connections, §3.8.7 Network/Port, Appendix C Communications.

---

## 1. Why the transport changed

The Modbus TCP design assumed the seven terminals carried the **EtherNet/IP – Modbus TCP combo option card**. They do not. That assumption was never verified; it is now disproven.

**Evidence, in order of strength:**

1. **The terminal reports no PLC interface.** `Communication` expands to `Access/Security · Templates · Reports · Connections · Serial · Network · Reset`. There is no `PLC` node. Per PLC Interface Manual §4.8, *"When the IND570 terminal detects the presence of a EtherNet/IP Kit option board, the EtherNet/IP parameters are **enabled** in a Setup program block at Communication > PLC."* The branch appears on detection; it is absent.
2. **Port scan from the Ignition gateway** (`172.17.10.161` → `172.17.20.127`, two runs): 21, 80 and 1701 open in under 100 ms; **502 and 44818 silent for the full 2500 ms timeout**.
3. **The option board Tom photographed** carries `Bluetooth` / `WLAN` silkscreen and an `RF` status LED, and has no MAC-ID DIP switches. It is a communications board, not the Figure 4-1 fieldbus module.

The "Tom configured EtherNet/IP" report was a naming conflation: he set the terminal's **Ethernet IP address** at `Communication > Network > Ethernet`, which is unrelated to **EtherNet/IP** the ODVA protocol.

MPP's decision (2026-08-31) is to use the terminal's existing `Communication > Connections` mechanism over Ethernet rather than purchase and fit option cards.

---

## 2. Decisions locked

1. **Transport is EPrint demand output.** One connection, `Port = EPrint`, `Assignment = Demand Output`, read by Ignition's TCP driver.
2. **One stream only.** EPrint exists solely on the secondary Ethernet port, and there is one secondary port. The weighment record wins; there is no live-weight mirror in Perspective.
3. **The verdict moves to SQL.** Without the PLC card there is no device-computed Under/OK/Over. Tolerance is evaluated against `Parts.ContainerConfig.TargetWeight` / `.ToleranceWeight`, where both values already live.
4. **No setpoint download.** Flow A is withdrawn entirely — no command sequencer, no echo verification, no target push. Terminal-side target comparison is not used.
5. **Scope is unchanged** from the superseded spec: Machining + Assembly checkweigh validation only. Trim Shop stays manual (FRS §2.2.3, FDS-06-005). No Work Order scale-weight auto-finish.
6. **Tolerance remains a single symmetric value** on `ContainerConfig`. **UOM remains a constant (`lb`)**, verified at commissioning, not carried in the database.
7. **Parse the net line only.** See §5.

---

## 3. Protocol facts established from the User Guide

### 3.1 Port and assignment matrix (Table 3-10)

Confirmed against the terminal's own dropdown (Tom, 2026-08-31): **COM1, Ethernet 1, Ethernet 2, Ethernet 3, EPrint, Print Client, USB**.

| Port | Assignments relevant to us |
|---|---|
| `COM1` | ASCII Input, CTPZ Input, Reports, SICS, Shared Data Server, Remote Display, Continuous *, Demand Output, Totals Report |
| `Ethernet 1-3` | Continuous Extended / Output / Template, Demand Output, Totals Report, Reports |
| `EPrint` | Continuous Extended / Output / Template, Demand Output *(and per the mangled table region, possibly Totals Report / CTPZ / Reports)* |
| `Print Client` | Terminal connects **out** to a configured IP and TCP port (default 8000) |

### 3.2 EPrint is effectively mandatory

> *"EPrint offers a method to access the demand or continuous output data directly through the Ethernet port. **Shared Data Server login and commands are not required** to register for the data. The EPrint port is accessible only through the secondary port of the Ethernet interface."* (§3.8.5 notes)

That clause is load-bearing. It implies the `Ethernet 1-3` ports deliver data *through* Shared Data registration — a login handshake Ignition's TCP driver cannot perform. EPrint is the only assignment that publishes a raw stream to an unauthenticated TCP client.

### 3.3 Ports

- **Primary port is fixed at 1701** and is the Shared Data Server (§3.8.7 Port). This is the port our scan found open; it accepted and immediately closed because we never sent a login.
- **Secondary port is user-defined.** It serves Shared Data *or* EPrint; once an EPrint connection exists in `Connections`, the secondary port is EPrint-only.
- **Primary and secondary run concurrently**, so EPrint does not displace whatever holds 1701 today.
- *"A change to the Secondary Port number may require a manual power cycle of the terminal before the change becomes active."*

### 3.4 Demand Output trigger

The `Trigger` field appears only for `Demand Output`. Options are **`Scale`** (the PRINT key) or **`Trigger 1/2/3`**, which bind *"a separate softkey, discrete input or a PLC command."*

This resolves the highest-risk unknown carried by the superseded spec (§8.3 Q0 — what the operator button is wired to). Whatever it is, it can be bound as a demand trigger; if it is not the PRINT key, `Trigger 1` plus a discrete input covers it.

### 3.5 Templates

- 10 templates, up to 1000 bytes each. One template per connection.
- **Templates 1, 2 and 5 carry factory default content.** Template 1 is three lines:

  ```
  XX.XX kg          <- gross
  XX.XX kg T        <- tare
  XX.XX kg N        <- net
  ```

- **Template editing requires the front panel or InSite SL.** *"The FTP server (both serial and Ethernet) can only read files from the terminal."* We cannot push a template over FTP.
- Checksum is a per-connection option, available for **continuous outputs only** — not applicable to demand output.

### 3.6 Consequence: one PRINT emits three lines

With the TCP driver delimiting on `\r\n`, a single PRINT press produces **three successive `Message` tag values**. This is the central parsing constraint and it drives §5.

---

## 4. Architecture

### 4.1 Terminal configuration (per scale)

| Setting | Path | Value |
|---|---|---|
| Secondary Port | `Communication > Network > Port` | `1702` (or a site-agreed number) |
| Connection | `Communication > Connections` → NEW | Port `EPrint`, Assignment `Demand Output` |
| Trigger | same screen | `Scale` — or `Trigger 1` if the operator button is a discrete input |
| Template | same screen | `Template 1` (factory default; see §5.3) |

A power cycle follows the secondary-port change.

### 4.2 Ignition configuration

- A **TCP driver device** per scale, addressed `<scale-ip>:<secondary-port>`.
- Message Delimiter Type **Character Based**. Delimiter **must be pinned from captured bytes, not assumed** — see the trap below.

> ⚠️ **Delimiter trap, learned the hard way 2026-08-31.**
>
> The MT Standard Continuous frame (Table C-6) is terminated by **`<CR>` (0x0D) alone — there is no LF**. An earlier draft of this spec said `\r\n`, carried across from the IND400/SICS work where CRLF *is* correct. Wrong frame format, wrong lesson. Ignition sits connected indefinitely waiting for a line feed that never arrives, and presents as `Last Receive Time` never updating.
>
> **Demand output is template-driven and its line terminator may differ from the continuous frame.** Capture the raw bytes and read the delimiter off them before setting this field.
>
> Second trap, same afternoon: the delimiter was typed **`/r` with a forward slash**. Two literal characters that never appear in the stream. Verify the slash direction.
- Field Count 1 — parse in script, not in the driver.
- Writeback **disabled**. Nothing in this design writes to the terminal.
- Inactivity Timeout: **0**. Demand output is silent between weighments, so a nonzero timeout would cycle the connection endlessly. Link health is covered in §6.2 instead.

### 4.3 Data flow

```
operator presses PRINT
      -> terminal emits Template 1 (3 lines) on the EPrint socket
      -> Ignition TCP driver Message tag fires 3x
      -> tag-change script: ignore gross and tare, act on the net line
      -> parse weight + uom
      -> resolve ContainerConfig for the terminal's current item
      -> compare against TargetWeight +/- ToleranceWeight   [SQL]
      -> in tolerance  -> Assembly_CompleteTray(terminalLocationId, "ByWeight")
         out of tolerance -> reject, toast, Audit.InterfaceLog row, no close
```

The tray-close path is unchanged — the same `Assembly_CompleteTray` call the ByCount button uses, so genealogy is identical.

---

## 5. Parse contract

### 5.1 Act on the net line only

Template 1 emits gross, tare and net per press. **One PRINT produces exactly one line ending in `N`.** That line is therefore both the trigger and the value, and keying on it gives one weighment per press with no accumulation buffer, no correlation window, and no partial-weighment state.

Gross and tare lines are ignored. If tare capture is later wanted for the audit row, it is the line ending in `T` immediately preceding the net line — but that reintroduces correlation state and is deliberately out of scope here.

### 5.2 Grammar

Expected shape, whitespace-tolerant:

```
<numeric weight> <uom> N
```

Rules:

- Trim, collapse internal whitespace, split on spaces.
- Last token must be exactly `N`; anything else is not a net line and is discarded silently (this is how gross and tare lines are rejected).
- Second-to-last token is the UOM. Compare case-insensitively against the expected constant (`lb`). A mismatch is a **refusal**, not a conversion — an unexpected UOM means the terminal is configured differently from what commissioning verified, and silently converting would hide it.
- Remaining leading token is the weight. Must parse as a decimal; a negative or unparseable value is a refusal.
- Any line that fails these rules is logged at debug and dropped. The terminal also emits report and status text on some assignments, and the parser must never mistake prose for a weighment.

### 5.3 On authoring a custom template

Template 1's default content is sufficient and requires no floor work, which is why it is the locked choice. A single-line custom template would be marginally cleaner — one `Message` fire per press instead of three — but it buys little against the cost of a second terminal visit per scale, and §5.1 already reduces three lines to one meaningful event.

Revisit only if the default proves unparseable in commissioning, or if InSite SL is adopted for remote terminal configuration (which would make template edits cheap).

---

## 6. Error handling

### 6.1 Refusal paths

Every refusal writes an `Audit.InterfaceLog` row via `PlcWatcher.logInterface` and surfaces a toast at the terminal. No refusal closes a tray.

| Condition | Behaviour |
|---|---|
| Unparseable line | Debug log, drop. Not a refusal — most dropped lines are gross/tare. |
| UOM mismatch | Refuse. Commissioning drift, not an operator error. |
| No `ContainerConfig` for the item | Refuse with a configuration message naming the item. |
| `TargetWeight` or `ToleranceWeight` null | Refuse. A missing tolerance is a configuration error, never a zero — a zero-width window rejects every tray. |
| Weight outside tolerance | Refuse with Under/Over in the message. This is the normal checkweigh reject. |
| `Assembly_CompleteTray` returns failure | Refuse, raise MES alarm, surface the proc's own message. |

### 6.2 Link health

Demand output is silent between weighments, so silence is not evidence of a fault and the IND400 pack's stale-stream watchdog does not transfer. Health is the **TCP driver's own connection state**, watched by the existing device-connection handler.

Borrowed from the IND400 build: a state change is worth exactly one audit row, with hysteresis, not one per poll. A flapping link that logs six rows a minute is the flood the edge trigger exists to prevent.

### 6.3 Re-entrancy

The physical-button and screen-button race that `ScaleWatcher._inFlight` guards is **gone**. There is one trigger — the terminal's own PRINT — and no screen-initiated capture, because Ignition cannot ask for a weighment over this transport. The lock and the in-flight set can be removed.

---

## 7. Impact on the existing build

### 7.1 Removed

- **`BlueRidge.Workorder.Ind570`** in its entirety (351 lines): `parkLiveCommand`, `sendCommand`, `applySetpoint`, `applySetpointAsync`, `captureGate`, the `CMD` table, echo tolerance, ack rotation.
- **`ScaleStation` UDT register members**: `Protocol/*`, `Setpoint/*`, `Verdict/*`, `Trigger/*`, and the `HR`-bound `Weight/*` members.
- **`ScaleWatcher.loadSetpointForItem`**, `onDeviceReconnect`, `_ackTriggerLatch`, `onTriggerEdge`, the `_inFlight` guard.
- The `command 0 reports gross` power-cycle hazard, the FP-indicator check, the byte-order question, the register-base question, and the data-integrity pair check. All Modbus-specific; all moot.

### 7.2 Retained

- `Parts.ContainerConfig.ToleranceWeight` — schema, procs, tests, and the Item Master editor (Tasks 1 and 10). Now load-bearing rather than a value pushed to the device.
- `Workorder.Assembly_CompleteTray` and the `ByWeight` closure method.
- `PlcWatcher.logInterface` and `notifyAlarm`.
- `ScaleWatcher`'s overall shape: trigger arrives → gate → close tray → log.

### 7.3 Rewritten

- **`ScaleStation` UDT** becomes a thin TCP-driver mirror: a `Message` string member and a connection-state member. No register addressing.
- **`ScaleWatcher`** becomes a line parser plus the closure call.
- **`BlueRidge.Sim`** — `fireScale` and `setScaleTarget` still write the pre-Modbus `NET_*` / `TRG_*` members that were deleted when the UDT was rebuilt, so both are already broken against the current tree. They are rewritten here to inject a synthetic Template 1 three-line burst into the `Message` member, which also makes the parser testable without hardware.

### 7.4 Documentation

- FDS-10-006 (OmniServer scale reads) is superseded by this transport, not by the Modbus one.
- FDS-06-014 (`ByWeight` tray closure) changes meaning: the verdict is computed by the MES, not read from the device. The requirement text needs amending.
- `notes/2026-08-12_mpp-opc-consolidation-assessment.md` — the "connect directly, retire OmniServer" conclusion still holds, by a different mechanism.

---

## 8. Commissioning

### 8.1 Per-scale terminal setup (front panel, one visit)

1. `Communication > Network > Port` → **Secondary Port** = `1702`.
2. `Communication > Connections` → **NEW** → Port `EPrint`, Assignment `Demand Output`, Trigger `Scale`, Template `Template 1`.
3. **Power cycle the terminal.**
4. With a known weight on the platform, press **PRINT** twice.

### 8.2 Remote validation

`Test-IND570-EPrint.ps1` (repo root) connects to the secondary port and dumps every frame as text and hex, so delimiters and field order are read off the wire rather than assumed:

```
.\Test-IND570-EPrint.ps1 -IPAddress 172.17.20.127 -Port 1702
```

Expected: three frames per PRINT press, the third ending `N`. The hex dump settles whether lines are `\r\n` or `\r`-only terminated, which the TCP driver's delimiter must match exactly.

If the socket connects but nothing arrives, the connection is live and the **trigger** is wrong — `Scale` fires on PRINT; `Trigger 1/2/3` fire from a softkey or discrete input instead.

### 8.3 Verification before build

- Confirm terminal primary units are **lb** (§2.6).
- Confirm the operator's physical button is the PRINT key. If not, rebind to `Trigger 1` plus the discrete input.
- Capture one real frame's hex to fix the delimiter and grammar in §5.2.

---

## 9. Open questions

| # | Question | Blocks |
|---|---|---|
| 1 | What is currently in `Communication > Connections`? The list appeared empty, which does not explain how OmniServer receives data today. If OmniServer uses the secondary port, we contend for it. | EPrint availability |
| 2 | Can `CTPZ Input` bind to an Ethernet port? The spec sheet says *"Ethernet Inputs: ASCII commands for CTPZ… SICS"*, but Table 3-10's Ethernet rows show output assignments only. Would restore remote tare/zero as a phase 2. | nothing — out of scope here |
| 3 | Does Template 1 emit the net line when no tare is set? Assumed yes (the template is static). | §5.1 |
| 4 | Is `172.17.20.127` one of the seven production scales or a test head? IT called it "the test scale." | fleet rollout |
| 5 | Are all seven terminals the same variant and firmware? The chassis label reads `IND570TE`. | fleet rollout |

---

## 10. Out of scope

- Live weight display in Perspective — one EPrint stream, spent on the weighment record (§2.2).
- Remote tare, zero and print trigger — possible via CTPZ or Shared Data, deferred (open question 2).
- Setpoint download to the terminal, and terminal-side target comparison (§2.4).
- Shared Data Server access on port 1701 — the login handshake is out of reach of the TCP driver and no requirement needs it.
- Print Client (terminal-initiated push to Ignition). A viable alternative topology, not needed if EPrint works.
- Trim Shop scales — remain unconnected.
- Custom output templates (§5.3).

---

## 11. References

- `reference/IND570_User_Guide.pdf` / `.txt` — METTLER TOLEDO 30205308 rev 07.
- `reference/IND570_PLC_Interface_Manual.md` — 30205335 rev 12. Retained as the record of why the fieldbus path was abandoned.
- `docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md` — superseded transport.
- `Test-IND570-Link.ps1`, `Test-IND570-EPrint.ps1` — commissioning aids.
- Blue Ridge IND400 integration package (A. Amos, SCW) — reference implementation for ASCII-over-TCP into Ignition's TCP driver. Directly transferable: the `\r\n` delimiter finding, the one-audit-row-per-state-change hysteresis, and the caution that a subscription samples a stream rather than capturing it.

---

## Revision History

| Rev | Date | Author | Change |
|---|---|---|---|
| 1 | 2026-08-31 | Blue Ridge / Claude | Initial draft. Supersedes the Modbus TCP transport after the PLC option card was found absent. |
