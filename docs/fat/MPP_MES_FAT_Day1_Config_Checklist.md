# MPP MES — Day-One FAT Configuration Checklist

Configuration + verification steps to perform **before / at the start of** a FAT or on-site
commissioning session — the setup that must be right before the FAT test cases
(`MPP_MES_FAT_practice.xlsx`) can be exercised. Distinct from the test cases themselves:
this is *"is the plant configured,"* the workbook is *"does each function pass."*

> **Sources folded in:** the PLC commissioning-readiness map + gap brief
> (`notes/2026-08-11_plc-*.md`), the OPC device↔terminal mapping, and the
> `reference/MPP_Terminal_Printer_Inventory.xlsx` terminal/printer inventory.
> Legacy IDs in that doc are **not authoritative** — used for content (IPs, hostnames,
> printer names) only.

**Environment under test** (fill at witnessing):

| | Value |
|---|---|
| Ignition Gateway version | |
| SQL Server / database | |
| Git commit / build tag | |
| Location model source | `MPP_MES_Site` (authoritative) → generated `011_seed_locations_mpp_plant.sql` |
| Date(s) | |

Legend: ☐ to do · ✅ confident (data-derived) · ⚠️ confirm on-site · 🚩 model gap to resolve

---

## §1 — Terminal registration & IP mapping

The MES resolves every shop-floor terminal by the **IP address it connects from**
(`Location.LocationAttribute` `IpAddress`, def 1 → `DefaultScreen`). Each terminal below must
resolve to the right screen/zone on-site. IPs pre-filled from the inventory doc where the
match is confident.

**☐ 1.1 — Confirm each terminal resolves by IP** (seed-ready, single clean IP → one terminal):

| Terminal (Location Code) | Role / Screen | Inventory IP | Status |
|---|---|---|---|
| `MA2-6MAOP-AOUT` | 6ma Oil Pan — Assembly Out | 172.17.20.115 | ✅ |
| `MA2-59B-MIN` | 59b Cam Holder — Machining In | 172.17.14.117 | ✅ |
| `MA2-64AOP-AOUT` | 64A Oil Pan — Assembly Out | 172.17.14.232 | ✅ |
| `MA2-6MACH-AOUT1` | 6MA Cam Holder — METTS Assembly A | 172.17.20.55 | ✅ |
| `MA2-6MACH-AOUT2` | 6MA Cam Holder — METTS Assembly B | 172.17.20.57 | ✅ |
| `MA2-6MACH-MIN` | 6MA Cam Holder — Machining In | 172.17.14.211 | ✅ |
| `MA2-6FBCHOP-MIN` | 6FB Small Parts — Machining In | 172.17.14.169 | ✅ |
| `MA2-RPYCAM2-AOUT1` | RPY Line 2 Set — Assembly Out | 172.17.20.162 | ✅ |

**☐ 1.2 — Resolve model gaps the match exposed** (🚩 — the inventory has more physical stations than the model has terminals):

| Inventory rows | Model terminal | Issue |
|---|---|---|
| 6FB **CH** AO (172.17.20.43) + 6FB **OP** AO (172.17.20.50) | one `MA2-6FBCHOP-AOUT` | two physical assembly-out stations, one terminal — split into two, or pick one? |
| RPY L1 CH Set AIN (172.17.20.126 **and** .124) | one `MA2-RPYCAM1-AIN` | two IPs → one terminal — is there a 2nd AIN station? |
| RPY L2 RS5 AIN (172.17.20.46) + RPY L2 CH/RS AIN (no IP) | one `MA2-RPYCAM2-AIN` | same |

**☐ 1.3 — Assign IPs to matched terminals that the doc left blank** (⚠️ — terminal identified, no IP in doc): `MA1-5GOF-ASER` (5G0 Front), `MA1-5GOR-ASER` (5G0 Rear), `MA1-COMPBR-MIN`, `MA1-COMPBR-AOUT`, plus the 5PA / 6MD / FPRPY / FP6NA machining terminals.

**☐ 1.4 — Unmapped / out-of-scope** (⚠️):
- **`5J6 OIL PAN`** (172.17.15.17 AO, 172.17.14.119 MIN) — **no 5J6 line exists in the model.** Add the line, or confirm 5J6 runs on an existing oil-pan line.
- **~14 `PASSTHROUGH` terminals** (`172.31.x` / `192.168.x` — 6MD/6A0/RJ2/64S/etc.) — appear to be non-MES stations. Confirm out-of-scope.
- **59B METTS** (172.17.15.58) — the 10-part / 10-printer station, see §2.2.

---

## §2 — Printer configuration

Printers attach to OUT-type terminals (`MOUT`/`AOUT`/`ASER`/`COMBINED`). The generator emits
one `-P1` child per OUT terminal. Most inventory printers are **network share** targets
(`\\FLXWAPSRV1\<name>`, port 9100) → `ConnectionKind = Hardwired`; a minority carry a model
(`GX420D`, `ZD621`) or a direct IP.

**☐ 2.1 — Set printer `Endpoint` / `Model` / `ConnectionKind`** from the inventory Printers tab where present (26 of 76 rows carry a model or IP; the rest are share-path only — record share path as `Endpoint`, `ConnectionKind=Hardwired`).

**☐ 2.2 — Build the 10 METTS 59B printers** 🚩 — Location `MA2-59B-AOUT1` (METTS Assembly Out) currently carries the placeholder **"add 10 printers"**; the inventory confirms **`59BL3 P1…P10` — one printer per part (10 parts)**, model `GX420D`, Ethernet. Extend the generator so this terminal emits `-P1…-P10` instead of a single `-P1`.

**☐ 2.3 — Hold/shipping printers** — the doc lists `Shipping Hold 1`, `Zebra Hold 1/2` (Label type = Container Hold). Confirm placement.

---

## §3 — PLC device mapping (`TerminalPlcDevice` seed) — **the #1 blocker**

Until `Location.TerminalPlcDevice` rows exist, all 33 wired PLC trigger edges hit
"no mapping → ignored" and nothing routes (FAT-PLC-020). Seed one row per UDT instance
(`[MPP]PlcDevices/<name>`), resolving the terminal by Code. Detail + rationale:
`notes/2026-08-11_plc-commissioning-readiness-map.md` §3.1.

**☐ 3.1 — Seed the resolved device→terminal mappings** (device closure → the line's non-METTS assembly-out terminal; METTS `ByCount` terminals excluded):

| Device | → Terminal | Note |
|---|---|---|
| `5G0_A1`, `5G0_Front_Scale` | `MA1-5GOF-ASER` | serialized |
| `5G0_A2`, `5G0_Rear_Scale` | `MA1-5GOR-ASER` | serialized |
| `59B_1_FP_1` | `MA2-59B-AOUT2` | METTS `-AOUT1` excluded |
| `5K8_64A_OilPan` | `MA2-64AOP-AOUT` | |
| `6C2_6MA_OilPan` | `MA2-6MAOP-AOUT` | |
| `6FB_CH` | `MA2-6FBCHOP-AOUT` | (see §1.2 split) |
| `6MA_CH` | `MA2-6MACH-AOUT3` | METTS `-AOUT1/2` excluded |
| `5PA_1_FP_1` | `MA2-5PA` assembly-out | vision-through-scale (§4) |
| `RPY_1_FP_1` | `MA1-FPRPY` assembly-out | vision-through-scale (§4) |
| `6B2_1_FP_1`, `6B2_CH` | `MA2-RPY6B2` assembly-out | |
| `Sort_OilPan`, `Sort_Totes` | `INSP-SORT-T1` | sort cage (Dev-only) |

**☐ 3.2 — Confirm the RPY L1/L2 pick** ⚠️ — `RPY_1_CB_1`, `RPY_CH` → RPY Cam Line 1 (`MA2-RPYCAM1`) or Line 2 (`MA2-RPYCAM2`)?

**☐ 3.3 — Deprecated-flagged, no model line** 🚩 — `5A2_L1/L2 × CamHolder/FuelPump` (4) and `5J6_OilPan` have no Location line. Seed as deprecated/pending, or add the lines first (see §1.4).

**☐ 3.4 — Record a simulator acceptance pass** for the serialized MIP + vision + scale handshakes (`/dev/sim/plc` against `MPP_Sim`).

---

## §4 — Vision-through-scale validation ⚠️

Three assembly-out terminals are **camera-wired-through-a-scale** (confirmed in SITE
`Description`): `5PA - AO` ("Vision through scale, validate tags"), `MA1-FPRPY-AFIN`,
`MA1-FP6NA-AFIN`. Their closure is `ByVision` but the OPC device is a **ScaleStation** UDT.

- **☐ 4.1** — Confirm the PLC-side UDT actually used at each (ScaleStation serving vision vs a separate TrayInspection).
- **☐ 4.2** — Validate the tag map (the SITE note literally says "validate tags").
- **☐ 4.3** — Note: `MA1-FP6NA-AFIN` is flagged vision-through-scale but **no OPC scale device is named 6NA/6VJ** in the catalog — confirm its device.

---

## §5 — Closure method & changeover

- **☐ 5.1** — Verify `CurrentClosureMethod` (`ByCount` / `ByWeight` / `ByVision`) on each assembly-out terminal matches the line's actual mode.
- **☐ 5.2** — Confirm METTS terminals are `ByCount` (they do **not** take a PLC vision/scale device).
- **☐ 5.3** — `MPPMACH` "3-bad-trays-in-a-row" threshold: data-table preset reads `30`, symbol says `3` — confirm intended value.

---

## §6 — Broader day-one configuration (skeleton — extend as needed)

- **☐ 6.1 Users & attribution** — AppUsers loaded; operator initials; AD interactive users; supervisor-elevation roles.
- **☐ 6.2 Shifts & schedules** — shift instances / schedules seeded for the go-live window.
- **☐ 6.3 AIM shipper-ID pool** — pool configured + primed (prod endpoint, not dev stub).
- **☐ 6.4 Label templates** — active `LabelTemplate` per type (LTT + Honda container); ZPL validated on target printers.
- **☐ 6.5 Reporting** — Reports landing page reachable; the 6 reports render on the gateway.
- **☐ 6.6 Seed registry** — external seed items (die-rank compatibility, etc.) loaded per `MPP_MES_SEEDING_REGISTRY.md`.

---

## Sign-off

| Role | Name | Signature | Date |
|---|---|---|---|
| MPP — Acceptance | | | |
| Blue Ridge — Lead | | | |

**Revision history**

| Rev | Date | Change |
|---|---|---|
| 0.1 | 2026-08-12 | Initial — terminal IP match (§1), printer + 10-METTS-printer (§2), PLC device mapping (§3), vision-through-scale (§4), closure (§5) from the PLC/terminal/printer reconciliation. |
