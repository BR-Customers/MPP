# OPC Server Consolidation — Device Compatibility Assessment

**Prepared by:** Blue Ridge Automation · **For:** Madison Precision Products · **Date:** 2026-08-12
**Subject:** Can the new MES reach all plant-floor devices through Ignition's built-in OPC-UA server, allowing TOP Server and OmniServer to be removed?

---

## 1. Purpose

The new MES (Ignition) currently reaches shop-floor devices through **two third-party OPC servers**:

- **TOP Server** (Software Toolbox) — the PLCs and HMIs (assembly cells, vision cells, container/sort stations).
- **OmniServer** (Software Toolbox) — the weigh-check scales.

MPP has asked whether both can be eliminated by having Ignition talk to the devices directly through its **built-in OPC-UA server and drivers**. This document states which devices can move to Ignition natively, which cannot, what information we need from MPP, and our recommendation.

**Key point up front:** "Ignition's built-in OPC-UA server" is really a question of **device drivers** — Ignition's OPC-UA server publishes whatever its drivers can connect to. So the question is whether Ignition's native driver set covers each device.

---

## 2. Bottom line

- **Most of the automation moves natively.** The **9 Allen-Bradley MicroLogix 1400 PLCs** (vision, tray disposition, sort) are directly supported by Ignition's native Allen-Bradley driver — no third-party server needed for these.
- **11 devices cannot be brought into Ignition natively:** the **7 weigh scales** (custom serial protocol) and the **4 Pro-face LT3300 HMI cells** (no Ignition driver).
- **2 devices need a quick confirmation** — the 5G0 serialized cells (generic EtherNet/IP).
- Because of the scales and the Pro-face HMIs, a **"pure Ignition, zero third-party OPC server" outcome is not achievable without custom development.** The cleaner path is to **consolidate the two servers into one** (Section 5).

---

## 3. Devices that MOVE to Ignition natively (good news)

Allen-Bradley MicroLogix 1400 — Ignition's native AB driver speaks EtherNet/IP with the same data-file addressing these PLCs already use:

| Device | Line / station |
|---|---|
| `5J6_OilPan`, `5K8_64A_OilPan`, `6C2_6MA_OilPan` | Vision inspection cells |
| `6B2_CH`, `6FB_CH`, `6MA_CH`, `RPY_CH` | Container / tray-disposition |
| `Sort_OilPan`, `Sort_Totes` | Sort cage |

**No OPC server needed for these — they connect straight to Ignition.**

---

## 4. Devices that CANNOT be brought into Ignition natively

### 4a. Weigh scales — currently on OmniServer (7 devices)

| Device | Line / station |
|---|---|
| `59B_1_FP_1` | 59B Cam Holder — Fuel Pump scale |
| `5PA_1_FP_1` | 5PA Fuel Pump scale |
| `6B2_1_FP_1` | RPY 6B2 Line 2 scale |
| `RPY_1_FP_1` | Fuel Pump (RPY 66V) scale |
| `RPY_1_CB_1` | RPY Comp Bracket scale |
| `5G0_Front_Scale` | 5G0 Front assembly scale |
| `5G0_Rear_Scale` | 5G0 Rear assembly scale |

**Why not:** these use a **custom serial/ASCII protocol** (OmniServer's specialty). Ignition has no generic scale or custom-protocol driver. In addition, the **target-vs-tolerance pass/fail decision is computed in the OmniServer protocol layer today** — the MES reads a "target met" flag rather than calculating it — so that logic would also have to be reproduced.

### 4b. Pro-face LT3300 HMI cells — currently on TOP Server (4 devices)

| Device | Line / station |
|---|---|
| `5A2_L1_CamHolder` | 5A2 Line 1 — Cam Holder assembly |
| `5A2_L1_FuelPump` | 5A2 Line 1 — Fuel Pump assembly |
| `5A2_L2_CamHolder` | 5A2 Line 2 — Cam Holder assembly |
| `5A2_L2_FuelPump` | 5A2 Line 2 — Fuel Pump assembly |

**Why not:** these are **Pro-face LT3300** touch panels. Ignition has **no native Pro-face driver**. (TOP Server / Kepware does — which is why they work today.)

### 4c. 5G0 serialized cells — EtherNet/IP (2 devices) — CONFIRM

| Device | Line / station |
|---|---|
| `5G0_A1` | 5G0 Front — serialized assembly cell |
| `5G0_A2` | 5G0 Rear — serialized assembly cell |

**Why "confirm":** catalogued as generic EtherNet/IP nodes. **If** these are Allen-Bradley (ControlLogix / CompactLogix / EtherNet-IP), Ignition's native driver covers them and they move like the MicroLogix PLCs. We need the PLC make/model to confirm.

---

## 5. Options & recommendation

### Option A — Ignition only (remove both servers)
Move the Allen-Bradley PLCs to Ignition's native drivers, and **reimplement the scale protocol inside Ignition** (raw TCP/serial driver + gateway scripting, including the pass/fail comparison). Pro-face works **only if** the LT3300 also exposes Modbus TCP.

- **Pros:** no third-party OPC licensing or support; single vendor (Ignition); one address space.
- **Cons:** the scale integration becomes **custom software that Blue Ridge builds and maintains**; the Pro-face cells are blocked unless they speak Modbus.

### Option B — Consolidate to a single OPC server (recommended)
Replace **both** TOP Server and OmniServer with **one modern OPC server — KEPServerEX (PTC Kepware)** — using its native drivers for the Allen-Bradley PLCs and Pro-face HMIs, **plus its User-Configurable (U-CON) driver for the custom scale protocol** (U-CON is the direct equivalent of OmniServer's protocol builder). Ignition connects to it over OPC-UA.

- **Pros:** two servers become **one**; keeps native Pro-face support and the custom-scale capability **without custom Ignition code**; modern and well-supported.
- **Cons:** still one third-party OPC server (licensed).
- **Note:** TOP Server is itself built on Kepware technology, so this is not a large platform change — the real gain is **collapsing two servers into one** and absorbing the scales via U-CON, eliminating OmniServer.

### Recommendation
If the goal is **fewer moving parts and better supportability**, **Option B (a single KEPServerEX with U-CON)** is the pragmatic path — it removes OmniServer and the two-server split with the least custom development, and keeps every device on a supported driver. **Option A (full Ignition-only)** is achievable but trades a server license for scale-protocol code that Blue Ridge would then own; it is worth it only if removing **all** third-party OPC is a hard requirement and the scales prove simple.

---

## 6. What we need from MPP to finalize

| # | Device group | Information requested |
|---|---|---|
| 1 | Weigh scales (7) | Make/model, connection type (RS-232 serial / Ethernet / serial-to-Ethernet converter), the data protocol, and **whether the scale itself outputs a pass/fail** or OmniServer computes it |
| 2 | Pro-face LT3300 (4) | Does the LT3300 expose **Modbus TCP**, or only the Pro-face protocol? |
| 3 | 5G0 cells (2) | PLC make/model for 5G0 Front and 5G0 Rear |

With these three answers we can size each option precisely and confirm whether "Ignition-only" is viable or a single-server consolidation is the right call.
