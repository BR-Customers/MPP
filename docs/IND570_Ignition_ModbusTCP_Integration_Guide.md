**IND570 → Ignition Modbus TCP Integration Guide**

*Working session guide — first scale (of 7), configured live on a call*

For: Jacques (Ignition side) & Tom (terminal side, plant floor)

**Revision 2 — 2026-08-27.** The register map, command codes, byte order and status-bit layout are no longer open questions. They were extracted from the IND570 PLC Interface Manual and are stated outright below. What remains for the call is device configuration, connection, and verification. Design rationale lives in `docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md`.

# 0. Before the Call — What to Have Ready

- **Tom:** physical access to the terminal, and the ability to enter its Setup menu (may require a supervisor/calibration passcode — check ahead of time).

- **Jacques:** Ignition Gateway open to Config › OPC UA › Device Connections, ready to add a new Modbus TCP device.

- **Both:** a static IP address reserved for this terminal, plus subnet mask and gateway for that network segment. Get this from whoever manages the plant OT network before the call — don't let the terminal negotiate DHCP for a permanent scale connection.

- Confirm the option card installed is labeled **"EtherNet/IP – Modbus TCP."** It's one physical card that can run either protocol — we're choosing Modbus TCP in software, not swapping hardware.

- Pull up the [METTLER TOLEDO IND570 PLC Interface Manual (document #30205335)](https://www.mt.com/dam/product_organizations/industry/IndustrialTerminals/30205335_12_MAN_PLC_IND570_EN.pdf) — Chapter 5 is Modbus TCP, Appendix B is the floating-point data format, Appendix C.2 is byte order. **Tom should have this open on his own machine**; everything Jacques needs is already transcribed into sections 4 and 6 below.

- Blue Ridge side, the same manual is in the repo at `reference/IND570_PLC_Interface_Manual.md` — searchable text, page-anchored, greppable. Figures are not in the extract, so use the web PDF for wiring diagrams and screenshots.

> **Resolved since revision 1:** Fill-570 is **not licensed** on any of the seven terminals. That confirms the standard target-control command set (110 / 131 / 112 / 114). Had Fill been present, every one of those would have been illegal and replaced by 170 / 173 / 174 / 119.

# 1. The One Concept Worth Understanding First

A plain Modbus device usually just has memory holding the current value — read register X and it's always today's reading. The IND570 is close to that, but with one twist worth understanding before you touch anything.

Weight data is exchanged through **Message Slots**. Each slot is a small block of registers: one register you write a **command** into ("report net weight," "set target value"), and paired registers where the terminal writes back the answer.

The twist, and the part that trips people up: **the command is sticky.** Once you write "report net weight" into a slot's command register, that slot keeps reporting net weight, refreshed every interface update cycle, until you write something else. From the manual (Table B-5):

> As long as the PLC leaves the 11 (dec) in the command word, the IND570 terminal will update the net value every interface update cycle.

So this is **not** a request/response cycle per reading. You park the command once and then poll the data register like any ordinary Modbus device. Ignition does not need to re-write the command on every scan.

Two consequences that matter:

- **We use two slots.** Slot 1 is parked on net weight permanently. Slot 2 is a scratchpad for setpoint loads, so pushing a new target never interrupts the live reading.
- **A command register of `0` means gross weight.** Table B-4 note 1 is explicit about this, and a terminal power cycle clears the register. That means an unparked slot silently returns well-formed, plausible, *wrong* numbers. Section 5 covers how we detect it.

# 2. Switching the Terminal from EtherNet/IP to Modbus TCP (do this first)

The terminal is currently running EtherNet/IP. There's no hardware to swap — it's a combo card.

What the manual says: the Modbus TCP setup lives in **the same setup block as EtherNet/IP** (§5.6.1.1), and there is **no protocol selector documented anywhere** in that branch. The only Data Format fields are Format, Byte Order and Message Slots. That's consistent with the card serving both protocols concurrently on their separate ports (TCP 44818 for EtherNet/IP, TCP 502 for Modbus TCP) — but the manual never states it outright, so step 1 tests it cheaply rather than assuming.

1. **Try doing nothing first.** Leave the terminal in its current EtherNet/IP configuration and have Jacques attempt the Ignition Modbus TCP connection (section 4) against the existing IP on port 502. If it connects and responds, the card is already serving both — skip to section 3.2.

2. If that doesn't connect, Tom goes to **Setup › Communication › PLC Interface** and looks for a Protocol or Mode selector near the EtherNet/IP settings. If present, switch it to Modbus TCP.

3. If no selector appears anywhere, the terminal may need a **Master Reset** to re-detect the card and present the Modbus menus. Before doing this, write down the current EtherNet/IP settings (IP, subnet, gateway, format, byte order) — a master reset can clear existing PLC-interface configuration.

4. After a master reset, re-enter Setup and confirm the Modbus TCP branch appears. Re-enter network settings if cleared.

5. Record which path applied in the worksheet. All 7 scales are presumably in the same state, so whatever works here applies to the rest.

> **Ask before you switch:** is anything *still* an active EtherNet/IP client on these terminals? If both protocols serve the same discrete data map, an existing client and Ignition would be writing the same slot command registers and fighting over them. Worth knowing who, if anyone, is on the other end today.

> **Gotcha:** if a master reset turns out to be necessary, treat it as bigger than it sounds. Confirm with whoever maintains these terminals whether calibration, application config or discrete I/O assignments could be affected, before Tom triggers it on a scale that's in production.

# 3. Tom's Side — Configuring the IND570 Terminal

## 3.1 Network settings

*Setup › Communication › PLC Interface › EtherNet/IP-Modbus TCP*

1. Turn **DHCP Client off** — we want a fixed address.
2. Enter IP Address, Subnet Mask, Gateway Address.
3. Note the MAC Address shown (informational, can't be changed) in case IT needs it for a switch port or firewall rule.
4. Write the IP into the worksheet — Jacques needs it.

## 3.2 Data format settings

*Setup › Communication › PLC Interface › Data Format*

1. **Operating Mode:** leave at default, **Compatibility Mode**. (IND560 Emulation is only for drop-in replacement of an older IND560.)

2. **Format: Floating Point.** The terminal's native internal format; Integer/Divisions requires a conversion that introduces rounding error. Options are Integer (default), Divisions, Floating Point, Application.

3. **Byte Order: Double Word Swap.** [Appendix C.2](https://www.mt.com/dam/product_organizations/industry/IndustrialTerminals/30205335_12_MAN_PLC_IND570_EN.pdf) lists this as *"compatible with the Modicon Quantum PLC for Modbus TCP networks"* — it is the vendor's own recommendation for Modbus TCP specifically. (Word Swap, the terminal default, targets RSLogix 5000; Byte Swap targets S7 Profibus; Standard targets PLC-5.)

4. **Message Slots: 2.** Slot 1 for the live net weight, slot 2 as the command scratchpad.

> **Gotcha:** changing **Format** deletes any existing Message Slots. Set Format *before* Message Slots, not after.

## 3.3 Target mode — new in revision 2

*Setup › Application › Target*

Set the target comparison to **over/under mode** (not material transfer mode).

This determines what the pass/fail status bits mean. Manual Table B-1, note 5:

> When in the material transfer mode; bit 0 is Feed, bit 2 is Fast Feed and bit 4 is Tolerance Ok (within range). When in the over/under mode; bit 0 is Under, bit 2 is OK and bit 4 is Over.

Over/under gives us a three-state verdict — Under / OK / Over — which is strictly more useful than the single pass/fail boolean the legacy system had. Material transfer mode is for controlling a filling operation and doesn't apply here.

There is no PLC command to select target mode — it must be set on the front panel. This menu is documented in the [IND570 User's Guide](https://www.mt.com/dam/product_organizations/industry/IndustrialTerminals/30205308_R07_MAN_IND570_UG_EN.pdf), not the PLC Interface Manual, so that's the one to have open for this step.

# 4. The Register Map (settled — no longer read live)

Floating Point format, per [manual](https://www.mt.com/dam/product_organizations/industry/IndustrialTerminals/30205335_12_MAN_PLC_IND570_EN.pdf) §5.4.4 and Table 5-3. Read and write areas share one holding-register space, offset by exactly 1024.

| Slot | Read (from IND570) | Write (to IND570) |
|---|---|---|
| — | — | `401025` Reserved |
| **1** | `400001` Command Response · `400002-3` FP Value · `400004` Scale Status | `401026` Command · `401027-8` FP Load Value |
| **2** | `400005` Command Response · `400006-7` FP Value · `400008` Scale Status | `401029` Command · `401030-1` FP Load Value |
| 3 | `400009` · `400010-11` · `400012` | `401032` · `401033-4` |
| 4 | `400013` · `400014-15` · `400016` | `401035` · `401036-7` |

> **The single most important line in this guide.** Mettler's `4000xx` / `4010xx` are **Modicon display convention**, not register numbers. The manual footnotes them twice as *"PLC processor memory-dependent."* The actual register numbers are **1** and **1025** — so in Ignition these are `HR1` and `HR1026`, **not** `HR400001`. Get this wrong and everything reads garbage.

## 4.1 Scale Status word — `400004` for slot 1

| Bit | Meaning | Bit | Meaning |
|---|---|---|---|
| 0 | **Under** | 8 | Enter Key pressed |
| 1 | Comparator 1 | 9–11 | Hardware inputs |
| 2 | **OK** ← the verdict | 12 | **Motion** (1 = in motion) |
| 3 | Comparator 2 | 13 | Net mode |
| 4 | **Over** | 14 | **Data Integrity 2** |
| 5 | **Always = 1** | 15 | **Data OK** |

## 4.2 Command Response word — `400001` for slot 1

| Bits | Meaning |
|---|---|
| 8–12 | **FP Indicator** — self-describes what the FP value currently holds: `0` gross, `1` net, `2` tare, `30` command OK, `31` invalid command |
| 13 | **Data Integrity 1** |
| 14–15 | **Command Acknowledge** — rotates 1 → 2 → 3 → 1 per accepted command |

## 4.3 Commands we use

| Dec | Command | Needs FP value | When |
|---|---|---|---|
| 11 | Report net weight | no | parked in slot 1 permanently |
| 110 | Set target value | yes | per part change |
| 131 | Set (+) tolerance value | yes | per part change |
| 112 | Set (−) tolerance value | yes | per part change |
| 114 | Start target comparison | no | per part change, after the three loads |
| 115 | Abort target comparison | no | error recovery |
| 117 | Target use net weight | no | commissioning only |
| 122 | Disable target latching | no | commissioning only |
| 30 | Report primary units | no | commissioning verification |

For any command taking a value, the manual (Table B-4 note 6) says: *"If the command is successful the returned floating point value will equal the value sent to the indicator."* The echo **is** the acknowledgement — there is no separate "commit" or "send message" step, unlike the legacy OmniServer setup. Write the FP value into words 2–3 **first**, then the command into word 1.

# 5. Jacques's Side — Configuring Ignition

1. Config › OPC UA › Device Connections › Create new Device → **Modbus TCP**. ([Connecting to a Modbus Device](https://www.docs.inductiveautomation.com/docs/8.3/ignition-modules/opc-ua/opc-ua-drivers/modbus/connecting-to-modbus-device))
2. **Hostname:** the terminal IP from section 3.1. **Port:** 502.
3. **Addressing Mode:** one-based.
4. Leave word/byte order at defaults — only revisit if data comes back garbled.
5. Create the test tags below.

Ignition's Modbus driver supports single-bit extraction from a holding register with a `.N` suffix, zero-indexed (`[Device]HR1024.0` is the first bit) — see [Modbus Addressing](https://www.docs.inductiveautomation.com/docs/8.3/ignition-modules/opc-ua/opc-ua-drivers/modbus/modbus-addressing) for the full prefix table (`HR`, `HRF`, `HRUS`, `C`, `DI`, …). That matches Mettler's bit numbering directly, so status flags are plain OPC tags.

| Purpose | OPC address | Type |
|---|---|---|
| Net weight (slot 1) | `[dev]HRF2` | Float32 |
| Scale Status (slot 1) | `[dev]HR4` | Int16 |
| Verdict — OK | `[dev]HR4.2` | Boolean |
| Motion | `[dev]HR4.12` | Boolean |
| Data OK | `[dev]HR4.15` | Boolean |
| Command Response (slot 1) | `[dev]HR1` | Int16 |
| Command register (slot 1) | `[dev]HR1026` | Int16, writeable |
| Command register (slot 2) | `[dev]HR1029` | Int16, writeable |
| FP Load Value (slot 2) | `[dev]HRF1030` | Float32, writeable |

> **Gotcha:** a Float32 spans two consecutive 16-bit registers. Byte/word order between the two halves is the most common source of nonsense-looking numbers on this kind of integration. See section 7 before assuming something else is broken.

# 6. Live Test Sequence (do this together)

**Step 1 — validate addressing before trusting any value.** Two checks that fail loudly if the register base is wrong:

- `HR4.5` must read **1, always.** Table B-1 lists Scale Status bit 5 as "Always = 1." If it reads 0, the base is off — try toggling the one-based/zero-based setting.
- `HR1.13` and `HR4.14` must **toggle together every update.** Both are set for one update, both cleared for the next, continuously. Diverging polarity means the words aren't from the same slot or the poll is tearing.

**Step 2 — park the command.** Write `11` (decimal) into `HR1026`.

**Step 3 — confirm we're reading net, not gross.** Read `HR1` and check bits 8–12 decode to `1`. If they decode to `0`, the command didn't land and the terminal is reporting **gross weight** — which will look completely plausible and be entirely wrong.

**Step 4 — compare against the display.** Note the terminal's front-panel weight. Read `HRF2` in Ignition. They should match within the scale's displayed resolution.

**Step 5 — confirm it tracks.** Put weight on and take it off. The Ignition value should follow the display continuously, with no further writes from Ignition. If it only updates once and freezes, the command didn't stick.

**Step 6 — commissioning commands.** Through slot 2, send `117` (target use net weight), `122` (disable target latching), and `30` (report primary units). Confirm command 30 comes back reporting **pounds** — if a terminal reports anything else, fix it on the front panel rather than reinterpreting the number in software.

**Step 7 — one setpoint load.** Through slot 2, run the four-step sequence: FP value + `110`, FP value + `131`, FP value + `112`, then `114`. Wait for the Command Acknowledge (`HR5` bits 14–15) to rotate between each. Verify each echoed value in `HRF6` matches what was sent. Then put a known weight on the scale and confirm `HR4.0` / `HR4.2` / `HR4.4` move as Under / OK / Over.

# 7. Troubleshooting

| Symptom | Likely cause | What to try |
|---|---|---|
| No connection / device Faulted | IP mismatch, cable/port, or terminal not serving Modbus | Ping the terminal from the Gateway machine. Confirm subnet/gateway. Confirm section 2 outcome. |
| All registers read 0 or garbage | Register base wrong — `HR400001` instead of `HR1`, or wrong addressing mode | Run the section 6 step 1 checks. `HR4.5` reading 0 is the tell. |
| Weight is non-zero but obviously wrong (huge, negative, scrambled) | Byte/word order mismatch | Terminal Byte Order should be Double Word Swap. If still wrong, try each terminal option against toggling Ignition's word-order setting. |
| **Weight looks plausible but is consistently high** | **Reporting gross, not net** — command register is 0 after a power cycle | Check `HR1` bits 8–12 decode to `1`. Re-write `11` to `HR1026`. This must be re-parked on every reconnect. |
| Value close but missing decimal precision | Format is Integer/Divisions, not Floating Point | Confirm Format = Floating Point. Remember changing Format wipes Message Slots. |
| Value updates once then freezes | Command didn't stick in the register | Read `HR1026` back to confirm the write landed. Do **not** add a repeating write — the command is meant to be sticky. |
| Setpoint load rejected, FP Indicator reads `31` | Invalid command — the terminal has Fill-570 after all | Commands become 170 / 173 / 174 / 119. Re-verify the licensing question. |
| Verdict bits never change | Target comparison not started, or wrong target mode | Confirm `114` was sent and acknowledged. Confirm over/under mode (section 3.3). |

# 8. Reference Material

## Vendor documentation

- [**METTLER TOLEDO IND570 PLC Interface Manual**, document #30205335](https://www.mt.com/dam/product_organizations/industry/IndustrialTerminals/30205335_12_MAN_PLC_IND570_EN.pdf) — the authority for everything in sections 4 and 6. Chapter 5 (Modbus TCP), Appendix B (Floating Point Format — status bits, command table, worked handshake examples), Appendix C.2 (Byte Order).

- [**IND570 User's Guide**, document #30205308](https://www.mt.com/dam/product_organizations/industry/IndustrialTerminals/30205308_R07_MAN_IND570_UG_EN.pdf) — **Tom's reference for section 3.** The terminal-side setup menus live here, not in the PLC manual: Setup › Application › Target (including over/under vs material transfer mode), scale calibration, and the serial-port output modes. If a menu in section 3 doesn't look the way this guide describes it, check here first.

- [IND570 Quick Guide, document #30205355](https://www.mt.com/dam/product_organizations/industry/IndustrialTerminals/30205355_06_MAN_QG_IND570_ML_A4.pdf) — condensed front-panel reference, handy to have printed at the terminal.

## Ignition documentation

- [Modbus Addressing](https://www.docs.inductiveautomation.com/docs/8.3/ignition-modules/opc-ua/opc-ua-drivers/modbus/modbus-addressing) — the prefix table (`HR`, `HRF`, `HRUS`, `HRI`, `C`, `DI`, …) and the `.N` bit-suffix syntax used throughout section 5.

- [Connecting to a Modbus Device](https://www.docs.inductiveautomation.com/docs/8.3/ignition-modules/opc-ua/opc-ua-drivers/modbus/connecting-to-modbus-device) — device-connection settings, including the one-based/zero-based addressing option.

- [getBit expression function](https://www.docs.inductiveautomation.com/docs/8.1/appendix/expression-functions/logic/getBit) — used to decode the multi-bit FP Indicator and Command Acknowledge fields (section 4.2). Zero-indexed, LSB at position 0, matching Mettler's numbering.

- [Inductive Automation forum, "Metler Toledo IND570 Weight Data (float)"](https://forum.inductiveautomation.com/t/metler-toledo-ind570-weight-data-float/31892) — community precedent for this exact terminal on Ignition, including working byte-order and addressing combinations. Useful as a second opinion, but the manual is authoritative — the forum thread's register numbers were flagged by its own author as best guesses.

## Blue Ridge internal

- **`reference/IND570_PLC_Interface_Manual.md`** — in-repo searchable extract of the manual above, page-anchored and greppable. Figures are not in the extract; use the web PDF for wiring diagrams and screenshots.

- **`docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md`** — the UDT design, both data flows, the `ContainerConfig.ToleranceWeight` schema change, and why each decision was made.

- **`notes/2026-08-12_mpp-opc-consolidation-assessment.md`** — the earlier assessment that listed these 7 scales as un-migratable. Superseded: they connect to Ignition natively, and OmniServer can be retired entirely.

> **Not applicable:** the [IND570 Shared Data Reference, document #30205337](https://www.mt.com/dam/product_organizations/industry/IndustrialTerminals/30205337_R04_MAN_SDREF_IND570_EN.pdf). Manual Table B-4 note 9 states outright that *"Shared data is not available with the AB-RIO, DeviceNet and Modbus TCP."* Command 160 (Apply scale setup) also does not function over this path. Linked so nobody spends an afternoon working out why the `wt0101`-style variable names don't resolve.

# 9. Worksheet — Fill In As We Go (Terminal #1 of 7)

Everything the manual settled has been removed from this table. What's left is genuinely per-site. This becomes the template for scales 2–7 — each gets its own IP, but the Format / Byte Order / Message Slot / target-mode choices should stay identical across all seven.

| Setting | Value |
|---|---|
| Protocol path (concurrent / selector found / master reset needed) | |
| Anything still an active EtherNet/IP client? | |
| Terminal IP address | |
| Subnet mask | |
| Gateway address | |
| MAC address (informational) | |
| Ignition addressing mode that worked (0- or 1-based) | |
| `HR4.5` reads 1? | |
| Integrity bits toggle together? | |
| Primary units reported by command 30 | |
| Front-panel weight vs `HRF2` — match? | |
| Byte order confirmed working | |
| Target mode set to over/under? | |
| Notes / anything unusual | |
