# IND570 Scale UDT over Modbus TCP — Design Spec

**Date:** 2026-08-27
**Status:** Draft — awaiting Jacques review
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor) — Machining & Assembly checkweigh validation. Replaces the legacy OmniServer ASCII scale link with a native Ignition Modbus TCP connection.
**Supersedes / corrects:** FDS-10-006 (OmniServer scale reads — tag pattern `OmniServer/[LineName].[ScaleName].NET_NetWeightValue`). Related: FDS-06-014 (`ByWeight` tray closure), `notes/2026-08-12_mpp-opc-consolidation-assessment.md` §4a.
**Source of protocol truth:** `reference/IND570_PLC_Interface_Manual.md` (METTLER TOLEDO doc 30205335 rev 12, 01/2023), Chapter 5 + Appendix B + Appendix C.

---

## 1. Motivation

Seven weigh-check scales on the Machining and Assembly lines reach the legacy MES through **OmniServer**, a custom-protocol ASCII bridge that Ignition has no equivalent for. The 2026-08-12 OPC consolidation assessment listed these seven as the main blocker to retiring third-party OPC servers, on the assumption that the scale protocol was proprietary serial and would have to be reimplemented.

That assumption is now obsolete. The terminals are **METTLER TOLEDO IND570** indicators carrying the **EtherNet/IP – Modbus TCP** combo option card. Modbus TCP is a first-class Ignition driver, so these scales can connect **natively, with no third-party OPC server and no custom protocol code** — which removes OmniServer from the plant entirely and changes the recommendation in that assessment from "Option B: consolidate to KEPServerEX" to "connect directly."

This spec defines the UDT, the two data flows, and the one schema change needed to drive it.

### 1.1 What changes from the legacy design

The legacy integration had two independent flows, and that shape is preserved. Only the direction of the second one reverses.

| | Legacy (OmniServer) | New (Modbus TCP) |
|---|---|---|
| **Setpoint download** | MES stages `TRG_TargetWeightValue` / `TRG_TargetWeightUOM` / `TRG_ToleranceWeightValue`, then pulses `TRG_SendMessage` | MES writes each value + its command code in sequence; the command **is** the commit. No send-message pulse exists. |
| **Weight read** | Scale **pushes** unsolicited on operator PRINT press; OmniServer parses and asserts `NET_DataReady`; MES reads then zeroes the item cache | Value is **continuously present** in the polled register. Ignition **pulls**. No trigger, no clear-down. |
| **Pass/fail** | `NET_TargetWeightMetFlag` — device-computed boolean | Scale Status word bits 0/2/4 — device-computed **three-state** Under / OK / Over |

The clear-down block that zeroed `NET_DataReady`, `NET_NetWeightValue`, `NET_NetWeightUOM` and `NET_TargetWeightMetFlag` (legacy EM steps 0130–0144) has no counterpart and is not needed. It existed only because OmniServer's item cache had to be invalidated between unsolicited pushes.

---

## 2. Decisions locked (from brainstorming)

1. **Scope is Machining + Assembly checkweigh validation only.** Target weight is used for nothing else. Trim Shop weight-based piece-count estimation (FDS-06-005) stays a manual operator entry against an unconnected scale, exactly as FRS §2.2.3 describes it today. No Work Order scale-weight auto-finish mode.
2. **No capture latch.** The button handler reads the live tags, gates on stability, and passes the values straight into the stored proc. No memory tags hold a captured reading, no completion flag, no reset. The tag tree stays a pure device mirror; MES state lives in SQL.
3. **Two message slots (Option B).** Slot 1 is permanently parked reporting net weight; slot 2 is a command scratchpad used for setpoint loads, so a setpoint change never interrupts the live reading.
4. **Tolerance is a single symmetric value** on `Parts.ContainerConfig`, pushed to the terminal as both the + and the − tolerance.
5. **UOM is a UDT default (`lb`), not a database column.** `ContainerConfig.TargetWeight` stays a bare decimal. The terminal's own primary units are verified at commissioning rather than pushed at runtime.
6. **Fill-570 is not licensed** on any of the seven terminals (confirmed with MPP 2026-08-27), so the standard target-control command set (110 / 131 / 112 / 114) applies. The Fill-570 alternates (170 / 173 / 174 / 119) are out of scope.
7. **Verdict drives the transaction; weight rides along.** The tray closes on the device's OK bit per FDS-06-014. The reading is recorded on the same `ProductionEvent` as evidence — see §7.2.

---

## 3. Protocol facts established from the manual

These are the load-bearing findings. Each replaced an open question or a guess.

### 3.1 Register map — Floating Point format

Per §5.4.4 and Table 5-3. Read and write areas occupy one holding-register space, **offset by exactly 1024**.

| Slot | Read (from IND570) | Write (to IND570) |
|---|---|---|
| — | — | `401025` Reserved |
| 1 | `400001` Command Response · `400002-3` FP Value · `400004` Scale Status | `401026` Command · `401027-8` FP Load Value |
| 2 | `400005` Command Response · `400006-7` FP Value · `400008` Scale Status | `401029` Command · `401030-1` FP Load Value |
| 3 | `400009` · `400010-11` · `400012` | `401032` · `401033-4` |
| 4 | `400013` · `400014-15` · `400016` | `401035` · `401036-7` |

Four input words and three output words per slot.

> **Addressing.** Mettler's `4000xx` / `4010xx` are Modicon display convention — the manual flags them as *"PLC processor memory-dependent"* twice. The real register numbers are **1** and **1025**, so in Ignition these are `HR1` and `HR1026`, **not** `HR400001`. Combined with the one-based/zero-based device setting this is the most likely cause of a garbage first read. See §8.1 for the two checks that catch it immediately.

### 3.2 Scale Status word (4th word of each slot)

| Bit | Meaning | Bit | Meaning |
|---|---|---|---|
| 0 | Target 1 — **Under** (over/under mode) | 8 | Enter Key pressed |
| 1 | Comparator 1 | 9-11 | Hardware inputs 0.1.1 – 0.1.3 |
| 2 | Target 2 — **OK** (over/under mode) | 12 | **Motion** — 1 = scale in motion |
| 3 | Comparator 2 | 13 | Net mode (a tare has been taken) |
| 4 | Target 3 — **Over** (over/under mode) | 14 | **Data Integrity 2** |
| 5 | **Always = 1** | 15 | **Data OK** |

Note 5 on Table B-1 defines bits 0/2/4 by target mode: in **material transfer** mode they are Feed / Fast Feed / Tolerance OK; in **over/under** mode they are Under / OK / Over. We use over/under, which yields a three-state verdict rather than the legacy single boolean.

Note 12: Data OK goes to `0` during power-up, during terminal setup, and when the scale is over capacity or under zero.

### 3.3 Command Response word (1st word of each slot)

| Bits | Meaning |
|---|---|
| 8-12 | **FP Indicator** — self-describes what the FP value currently holds |
| 13 | **Data Integrity 1** |
| 14-15 | **Command Acknowledge** — rotates 1 → 2 → 3 → 1 per accepted command; `0` when the command word is `0` |

FP Indicator values that matter to us (Table B-2): `0` gross · `1` net · `2` tare · `29` last error code · `30` command received successfully, no response · `31` **invalid command**.

**Data integrity pair.** Note 2: word 1 bit 13 and word 4 bit 14 are both set for one update, then both cleared for the next, alternating on every update as long as the link is healthy. **Both must have the same polarity** for the slot's data to be coherent.

### 3.4 Commands used (standard target control, no Fill-570)

| Dec | Command | Needs FP value | Used by |
|---|---|---|---|
| 11 | Report net weight | no | Slot 1, parked permanently |
| 110 | Set target value | yes | Flow A step 1 |
| 131 | Set (+) tolerance value | yes | Flow A step 2 |
| 112 | Set (−) tolerance value | yes | Flow A step 3 |
| 114 | Start target comparison | no | Flow A step 4 |
| 115 | Abort target comparison | no | error recovery |
| 117 | Target use net weight | no | commissioning only |
| 122 | Disable target latching | no | commissioning only |
| 30 | Report primary units | no | commissioning verification |

Note 6 on Table B-4: for any command taking an FP value, *"if the command is successful the returned floating point value will equal the value sent to the indicator."* The echo **is** the acknowledgement — there is no separate commit step for the value itself. Activation is separate and is command 114.

> **Command 0 reports GROSS.** Note 1: *"A command of '0' without rotation setup will report the scale gross weight."* After a terminal power cycle the command register is `0`, so slot 1 silently begins returning well-formed, plausible, **wrong** numbers. This is the single most dangerous failure mode in the integration and it is invisible without the FP Indicator check — see §5.3.

### 3.5 Byte order

Appendix C.2 lists **Double Word Swap** as *"compatible with the Modicon Quantum PLC for Modbus TCP networks."* This is the vendor's own Modbus TCP recommendation, not community folklore. Word Swap (the terminal default) targets RSLogix 5000; Byte Swap targets S7 Profibus; Standard targets PLC-5.

### 3.6 Constraints worth recording

- **Shared Data is unavailable over Modbus TCP.** Note 9 is explicit: *"Shared data is not available with the AB-RIO, DeviceNet and Modbus TCP."* Command 160 (Apply scale setup) therefore does not function, and the IND570 Shared Data Reference (doc 30205337) does not apply to this path.
- **A slot reports one value at a time.** Simultaneous gross + net + tare would require three parked slots. We need only net.
- **Rotation is rejected.** Commands 40–48 can cycle multiple fields through one slot, but note 1 requires *"scan time 30 milliseconds or less"* to keep up. Not appropriate for an Ignition poll. Dedicated slots instead.
- **Over/under mode is a terminal setup parameter**, not a PLC command. There is no command in Table B-4 to select target mode; Tom sets it on the front panel.

---

## 4. The UDT

**Name:** `IND570_Scale`
**Parameters:** `DeviceName` (string) · `WeightUom` (string, default `lb`)

```
IND570_Scale
│
├── Weight
│   ├── Net              Float4   [{DeviceName}]HRF2
│   ├── InMotion         Bool     [{DeviceName}]HR4.12
│   ├── IsValid          Bool     [{DeviceName}]HR4.15
│   ├── SourceIsNet      Bool     expr — FP Indicator == 1
│   └── Uom              String   memory, default {WeightUom}
│
├── Trigger                                                rev 2 - physical button
│   ├── EnterKey         Bool     [{DeviceName}]HR4.8   latched; cleared by cmd 75
│   ├── Input1           Bool     [{DeviceName}]HR4.9
│   ├── Input2           Bool     [{DeviceName}]HR4.10
│   └── Input3           Bool     [{DeviceName}]HR4.11
│
├── Verdict
│   ├── Under            Bool     [{DeviceName}]HR4.0
│   ├── Ok               Bool     [{DeviceName}]HR4.2
│   ├── Over             Bool     [{DeviceName}]HR4.4
│   └── State            String   expr — Under / Ok / Over / Unknown
│
├── Setpoint
│   ├── Target           Float4   memory  ← ContainerConfig.TargetWeight
│   ├── Tolerance        Float4   memory  ← ContainerConfig.ToleranceWeight
│   ├── Apply            Bool     memory  fires the Flow A sequence
│   ├── ActiveTarget     Float4   memory  echo-confirmed
│   └── State            String   memory  Idle / Loading / Active / Failed
│
└── Protocol
    ├── Live
    │   ├── Command          Int2   [{DeviceName}]HR1026   write — park 11
    │   ├── CommandResponse  Int2   [{DeviceName}]HR1
    │   ├── FpIndicator      Int2   expr — bits 8-12 of CommandResponse
    │   ├── Status           Int2   [{DeviceName}]HR4
    │   ├── Integrity1       Bool   [{DeviceName}]HR1.13
    │   └── Integrity2       Bool   [{DeviceName}]HR4.14
    └── Command
        ├── Command          Int2   [{DeviceName}]HR1029   write
        ├── LoadValue        Float4 [{DeviceName}]HRF1030  write
        ├── CommandResponse  Int2   [{DeviceName}]HR5
        ├── FpIndicator      Int2   expr — bits 8-12 of CommandResponse
        ├── CommandAck       Int2   expr — bits 14-15 of CommandResponse
        └── EchoValue        Float4 [{DeviceName}]HRF6
```

### 4.1 Why the tree is shaped this way

Message-slot numbering is an **addressing** fact and is confined to the OPC item paths. Nothing a screen or a script binds to is named after a slot. The folders divide by audience instead: `Weight`, `Verdict` and `Setpoint` are what views and business logic touch; `Protocol` is plumbing that only the sequencing script reads.

Read/write was considered as the top-level axis and rejected — a setpoint load is a write (the value) *and* a read (the echo that confirms it), so splitting on direction puts the two halves of one handshake in different folders. Direction is already carried by each tag's own permissions.

`Setpoint.Target` (requested) and `Setpoint.ActiveTarget` (echo-confirmed) are deliberately distinct. The gap between them is the only way to detect a setpoint load that silently failed.

`InMotion` is mapped directly rather than exposing a derived `IsStable`, keeping one tag per bit. Consumers write the negation.

### 4.2 Bit addressing

Ignition's Modbus driver supports bit extraction from a holding register with a `.N` suffix, 0-indexed — `[Device]HR1024.0` is the first bit, `[Device]HR1024.10` the eleventh. This is a software-side mask over a normal FC03 word read (Modbus has no wire-level bit read for holding registers), but the driver handles it, so every single-bit status flag is a plain OPC tag rather than an expression over a raw word.

### 4.3 Multi-bit decodes

Three fields span more than one bit and cannot be `.N`-addressed, so they are expression tags over the raw word using `getBit(number, position)` — zero-indexed with the LSB at position 0, which matches Mettler's bit numbering directly.

**`Protocol/*/FpIndicator`** — bits 8-12, the self-describing "what is this value" field:

```
getBit({[.]Protocol/Live/CommandResponse},  8) * 1  +
getBit({[.]Protocol/Live/CommandResponse},  9) * 2  +
getBit({[.]Protocol/Live/CommandResponse}, 10) * 4  +
getBit({[.]Protocol/Live/CommandResponse}, 11) * 8  +
getBit({[.]Protocol/Live/CommandResponse}, 12) * 16
```

**`Protocol/Command/CommandAck`** — bits 14-15, the rotating acknowledgement:

```
getBit({[.]Protocol/Command/CommandResponse}, 14) * 1 +
getBit({[.]Protocol/Command/CommandResponse}, 15) * 2
```

**`Weight/SourceIsNet`** then reduces to a comparison against the decoded value:

```
{[.]Protocol/Live/FpIndicator} = 1
```

Decoding once and consuming many times keeps the gross/net guard (§5.3) and the invalid-command check (§6.3) reading the same field rather than repeating a five-term expression at each use site.

> Expression syntax is C-style (`=`, `&&`, `!`) — not Python keywords, which fail silently as falsy. The UDT-relative reference form `{[.]Path/To/Member}` should be confirmed in the Designer on the first instance; nested-UDT relative references are a known rough edge in Ignition and the fallback is an absolute path built from the `DeviceName` parameter.

---

## 5. Flow B — Capture (dual-trigger)

**Rev 2.** MPP are keeping the physical button on the indicator, so capture has **two triggers and one handler**. Neither issues a command: slot 1 sits parked on command 11 and the terminal refreshes net weight every interface update cycle, so the reading is already present. The trigger only decides *when* to trust it.

| Trigger | Path |
|---|---|
| **Physical button** on the indicator | latches `HR4.8` (ENTER) or asserts `HR4.9-.11` (discrete input) -> gateway tag-change script -> `captureAndClose` |
| **On-screen button** | Perspective handler -> `captureAndClose` |

### 5.1 Sequence and timing

| # | Step | Time |
|---|---|---|
| 1 | Operator presses the button | t = 0 |
| 2 | IND570 latches `HR4.8` | < 30 ms, internal |
| 3 | Ignition polls `HR1`-`HR4` — one contiguous FC03, so status, weight and both integrity bits arrive **in the same read** | 0 – T_poll |
| 4 | Tag-change event -> `captureAndClose` | ~1 ms |
| 5 | Gate (§5.2) + read `Weight/Net`, `Verdict/State` from that same block | < 5 ms |
| 6 | Tray-close stored proc — mint FG LOT, consume BOM | 50 – 200 ms |
| 7 | Toast / screen update | < 50 ms |
| 8 | Command 75 clears the ENTER latch — **async, off the critical path** | — |

**Total = T_poll + ~250 ms**, so ~350 ms on the 100 ms tag group §6.5 requires. The screen button is identical minus step 3.

Because everything the gate reads lives in one contiguous register block, there is no tearing between "the button was pressed" and "the weight at that moment", and the integrity-bit pair confirms coherence.

Nothing is latched in tags and nothing is written except the acknowledgement. Two presses write two rows, which is correct — each is a distinct weighing.

### 5.1.1 Re-entrancy guard

Two triggers means a press can arrive while a capture is still running — a double-press, or a screen tap racing the physical button. `captureAndClose` SHALL be guarded per instance so a second invocation returns immediately rather than closing a second tray against one weighing. Acknowledge (command 75) **after** the proc returns, not before, so a press consumed by a failed capture is not silently swallowed.

### 5.1.2 Which bit is the button

**This is the highest-risk unknown in rev 2 and must be settled at commissioning.** The legacy behaviour was PRINT-driven, and PRINT emits a demand string out the *serial* port — which produces **nothing** over Modbus TCP.

| Button wired to | Over Modbus TCP | Verdict |
|---|---|---|
| **ENTER key** | latches `HR4.8` | ideal — no press can be missed |
| **Discrete input 0.1.1-0.1.3** | `HR4.9/.10/.11`, live state | usable, but a press shorter than the poll interval is invisible — needs a maintained contact or a fast group |
| **PRINT key** | nothing | **the button does nothing**; rewire to ENTER or a discrete input |

All four bits are in the UDT precisely so commissioning can press the button and watch which one moves.

### 5.2 The capture gate

All five must hold:

| Condition | Tag | Why |
|---|---|---|
| Scale settled | `!Weight.InMotion` | reading is meaningless mid-motion |
| Terminal healthy | `Weight.IsValid` | Data OK — false during setup, over-capacity, under-zero |
| Reading is net | `Weight.SourceIsNet` | guards the command-0-reports-gross trap |
| Data coherent | `Protocol.Live.Integrity1 == Integrity2` | both bits share polarity on a healthy link |
| Not already capturing | per-instance guard (§5.1.1) | a second trigger must not close a second tray against one weighing |
| Setpoint live | `Setpoint.State == Active` | a tray cannot be validated against a target the terminal is not enforcing (§6.4) |

The button is also disabled in the UI on the last condition, but the handler re-checks all five — the UI state is a courtesy, the gate is the contract.

### 5.3 `SourceIsNet` — guarding the gross/net trap

Command 0 reports gross weight (§3.4). A terminal power cycle clears the command register, so slot 1 resumes returning gross with no error raised anywhere — plausible numbers, wrong quantity, passing trays that should fail.

`Weight.SourceIsNet` tests the decoded FP Indicator (§4.3) for `1` — net weight. It reads `0` when the terminal has fallen back to gross.

Two consequences:

- **The command tag must be re-parked on every device reconnect**, not written once at commissioning. A gateway startup script plus a device-connection-state handler both write `11` to `Protocol.Live.Command`.
- `SourceIsNet` belongs in the capture gate, not merely on a diagnostics screen.

---

## 6. Flow A — Setpoint download

Runs when the part running on a line changes. Independent of the button, exactly as in the legacy design.

### 6.1 One-time commissioning commands

Sent once per terminal (and re-sent after a master reset), through slot 2:

| Cmd | Purpose |
|---|---|
| 117 | Target use **net** weight — otherwise comparison may run against gross |
| 122 | Disable target latching — verdict tracks live rather than latching on first satisfaction |
| 30 | Report primary units — **verify** the terminal's units match the UDT's `WeightUom` default |

Command 30 is a verification step, not a configuration one. There is no command to *set* the terminal's units, so if a terminal reports anything other than pounds, that terminal is reconfigured on its front panel — we never silently reinterpret the value.

### 6.2 Per-part sequence

Triggered by writing `Setpoint.Apply`. Four commands through slot 2, each waiting for the acknowledgement to rotate before the next is sent — the manual is explicit: *"The PLC should always wait to receive a command acknowledgment before sending the next command to the IND570 terminal."*

| Step | Write `LoadValue` | Write `Command` | Verify |
|---|---|---|---|
| 1 | `Setpoint.Target` | `110` | `CommandAck` rotated · `EchoValue == Target` |
| 2 | `Setpoint.Tolerance` | `131` | `CommandAck` rotated · `EchoValue == Tolerance` |
| 3 | `Setpoint.Tolerance` | `112` | `CommandAck` rotated · `EchoValue == Tolerance` |
| 4 | — | `114` | `CommandAck` rotated |

The FP value is written **before** the command in every step — Table B-6 establishes that ordering. On success, `Setpoint.ActiveTarget := Setpoint.Target` and `Setpoint.State := Active`.

### 6.3 Failure handling

| Symptom | Meaning | Action |
|---|---|---|
| `Protocol.Command.CommandAck` does not rotate within timeout | terminal not processing commands | `State := Failed`, alarm, leave prior target active |
| `Protocol.Command.FpIndicator` reads `31` | invalid command — likely a Fill-570 terminal | `State := Failed`, alarm; re-check §2 decision 6 |
| `EchoValue` differs from the value sent | value rejected, or mis-ordered bytes | `State := Failed`, alarm; check byte order (§3.5) |

A failed load **must not** leave a partially-applied window — a new target with stale tolerances is worse than an unchanged setpoint. On any step failure the sequence sends `115` (Abort target comparison) and leaves `ActiveTarget` at its previous value, so `Target != ActiveTarget` remains visible as the signal that the line is running on a stale setpoint.

### 6.5 Execution model and poll rate (rev 2)

Task 4 established that a synchronous `applySetpoint` blocks its caller for as long as the sequence runs, and Flow A was to be called from the item-dropdown handler — a session thread, on the operator's part-change click. Not acceptable. Four requirements:

1. **`Protocol/*` polls on a 100 ms tag group.** This is the dominant term and the whole problem. Ack observation costs one poll interval, so sequence time scales directly with it:

   | Tag group | Per command | Full 4-command sequence |
   |---|---|---|
   | 1000 ms (Ignition's usual default) | ~1050 ms | **~4.2 s** |
   | 250 ms | ~300 ms | ~1.2 s |
   | **100 ms** | ~150 ms | **~0.6 s** |
   | dead link @ 3 s timeouts | — | ~15 s |

2. **Dispatch asynchronously** per FDS-01-014, following `BlueRidge/Lots/ShippingDispatcher` — the only `system.util.invokeAsynchronous` in the project. `loadSetpointForItem` resolves the `ContainerConfig` read and its NULL checks synchronously (those are worth returning inline), then hands `applySetpoint` to the async worker and reports sequencer failure through `PlcWatcher.notifyAlarm`. This adds a `terminalLocationId` parameter.

3. **Per-command timeout 1.5 s, abort the sequence on first failure.** Worst case ~6 s, off-thread, with an alarm — rather than 15 s on a frozen screen.

4. **Skip when nothing changed.** If `ActiveTarget` already equals `Target` and the tolerance matches, do not re-push. Re-selecting the same part then costs nothing.

Normal case ~0.6 s, never on a session thread, and a dead scale alarms instead of freezing a screen.

### 6.4 Interlock with tray closure

While `Setpoint.State != Active`, the capture button is disabled. A tray cannot be validated against a target the terminal is not currently enforcing.

---

## 7. Data model changes

### 7.1 `Parts.ContainerConfig.ToleranceWeight` — new column

FDS-06-014 describes `ByWeight` closure as *"`TargetWeight` per tray (+ optional tolerance)"* but the tolerance never landed in the schema. `ContainerConfig` carries `TargetWeight DECIMAL(10,4) NULL` and nothing else. The legacy SparkMES column crosswalk in the FDS confirms the original system had one — `GroupTargetWeightTolerance`, listed as *"subsumed by OI-02 resolution when that closes."* It was not.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `ToleranceWeight` | `DECIMAL(10,4)` | NULL | Symmetric tolerance about `TargetWeight` for `ByWeight` closure, in the same (unstated) units as `TargetWeight`. Pushed to the scale as both the + and the − tolerance. Required when `ClosureMethod = 'ByWeight'`; ignored otherwise. |

Migration adds the column, extends `ContainerConfig_Insert` / `_Update` / read procs, and adds the field to the ContainerConfig editor. `TargetWeight` deliberately stays unit-less — units are the UDT's `WeightUom` default, verified per terminal at commissioning (§6.1).

This is a **spec gap, not merely a build task** — it needs an Open Items Register entry recording that FDS-06-014's parenthetical tolerance was never carried into the data model, and that it is now symmetric-only by decision.

### 7.2 `ProductionEvent.WeightValue` — populated, not added

The column and its `WeightUomId` companion already exist and FDS-06-004 already carries them as optional on the write proc. The tray-close proc populates both.

This is evidentiary, not functional — the tray closes on the device's OK bit per FDS-06-014, never on the weight. Recording the reading is what makes scale drift visible: a verdict-only record reads "fine" until it abruptly reads "broken," with no history to show the trend. It costs one decimal on a row already being written. **Reversible** — if MPP would rather not retain readings, the proc simply stops passing them and nothing else changes.

---

## 8. Commissioning

### 8.1 Two checks that validate addressing immediately

Before trusting any value:

- **`HR4.5` must read `1`, always.** Table B-1 lists Scale Status bit 5 as "Always = 1". Reading `0` means the register base is off.
- **`HR1.13` and `HR4.14` must toggle together every update.** Diverging polarity means the two words are not from the same slot, or the poll is tearing.

### 8.2 Sequence for terminal #1

1. Attempt the Modbus TCP connection against the terminal's existing IP on port 502 with no terminal changes — the combo card may already be serving both protocols on their separate ports (44818 / 502). The manual shows **no protocol selector anywhere** in the Modbus TCP setup, which supports this.
2. Terminal side: Format = Floating Point, Byte Order = Double Word Swap, Message Slots = 2, target mode = over/under. **Set Format before Message Slots** — changing Format deletes existing slots (§5.6.1.2.2).
3. Ignition side: Modbus TCP device, one-based addressing, defaults elsewhere.
4. Run the §8.1 checks.
5. Park `11` in `HR1026`; confirm `Weight.SourceIsNet` goes true and `Weight.Net` tracks the front-panel display.
6. Send the §6.1 commissioning commands; confirm command 30 reports pounds.
7. Run one Flow A load and confirm all four echoes.

### 8.3 Open for the call

| # | Question | Blocks |
|---|---|---|
| 0 | **What is the physical button wired to — ENTER key, a discrete input, or PRINT?** Press it and watch `HR4.8` / `HR4.9-.11`. If neither moves it is PRINT-wired and does nothing over Modbus. | the entire physical-button path (§5.1.2) |
| 1 | Does the combo card serve EtherNet/IP and Modbus TCP concurrently, or must it be switched? | connection method |
| 2 | Can all 4 message slots address the same local scale with independent commands? | Option B's two-slot split |
| 3 | Is anything **still** an active EtherNet/IP client on these terminals? If so it shares the same discrete data map and would contend for the slot command words. | slot allocation |
| 4 | One-based or zero-based addressing in practice | §8.1 resolves it in seconds |

Questions 1 and 2 have fallbacks that cost configuration time, not redesign: if the card must be switched, Tom switches it; if slots cannot share a scale, Flow A borrows slot 1 and re-parks `11` afterward.

---

## 9. Out of scope

- Trim Shop scales — remain unconnected, manual operator entry per FRS §2.2.3 and FDS-06-005.
- Work Order scale-weight auto-finish (FDS-06-028 scale-weight mode).
- `Lots.Lot.Weight` — not written by this flow.
- Fill-570 command set (170 / 173 / 174 / 119) — not licensed.
- Gross, tare, rate, and fine-resolution readings — one parked slot, net only.
- Asymmetric tolerance windows — device supports them, schema deliberately does not.

---

## 10. References

| Source | Relevance |
|---|---|
| [IND570 PLC Interface Manual #30205335](https://www.mt.com/dam/product_organizations/industry/IndustrialTerminals/30205335_12_MAN_PLC_IND570_EN.pdf) (in-repo extract: `reference/IND570_PLC_Interface_Manual.md`) | §5.4 register map · Appendix B floating point format, status bits, command table · Appendix C.2 byte order |
| [IND570 User's Guide #30205308](https://www.mt.com/dam/product_organizations/industry/IndustrialTerminals/30205308_R07_MAN_IND570_UG_EN.pdf) | Terminal-side setup menus — Setup › Application › Target (over/under mode), calibration, serial output modes. Not covered by the PLC manual. |
| [Ignition Modbus Addressing](https://www.docs.inductiveautomation.com/docs/8.3/ignition-modules/opc-ua/opc-ua-drivers/modbus/modbus-addressing) · [getBit](https://www.docs.inductiveautomation.com/docs/8.1/appendix/expression-functions/logic/getBit) | Address prefixes + the `.N` bit suffix (§4.2); the bit-decode function (§4.3) |
| `docs/IND570_Ignition_ModbusTCP_Integration_Guide.md` | Commissioning-call guide, generated from this spec's findings |
| `notes/2026-08-12_mpp-opc-consolidation-assessment.md` | §4a listed these seven scales as un-migratable; superseded by this spec |
| `reference/legacy_mes_extract/emmd_automation/` | `events.tsv`, `station_chain.tsv`, `tag_catalog.tsv` — the legacy `NET_*` / `TRG_*` flows this replaces |
| FDS-06-014 | `ByWeight` tray closure — the verdict is authoritative, not the running count |
| FDS-10-006 | OmniServer scale reads — superseded by this spec |

**Not applicable:** [IND570 Shared Data Reference #30205337](https://www.mt.com/dam/product_organizations/industry/IndustrialTerminals/30205337_R04_MAN_SDREF_IND570_EN.pdf). Shared Data is unavailable over Modbus TCP (§3.6).
