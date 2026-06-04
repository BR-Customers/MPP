# MPP Location Model — Reconciled Seed Tree (DRAFT FOR VALIDATION)

**Status:** 🔶 Draft — most open items resolved; a few refinements remain (see bottom). Ready to convert to a seed once validated.
**Sources:** `mpp_plant_regions_2026-05-21 (1).json` + `mpp_plant_regions_2026-06-02.json` (plant-layout-mapper exports).
**Target model:** `Location.Location` (adjacency-list) over the 5-tier `LocationType` (Enterprise → Site → Area → WorkCenter → Cell) with `LocationTypeDefinition` kinds (`Terminal`, `DieCastMachine`, `Printer`, `InventoryLocation`, …).

> Indentation = `ParentLocationId`. `[Kind]` = `LocationTypeDefinition`. ⚠ = open item (bottom table).

---

## Reconciliation decisions applied

1. **Building tier dropped** — Areas are the top operational tier under Site.
2. **Two Trim Shops**; **two Machining & Assembly rooms** (M&A 1 = 05-21 file, M&A 2 = 06-02 file + RPY 6b2 line2).
3. **Die Cast Areas → `DieCastMachine` Cells directly** (no WorkCenter). DC1=11, DC2=3, DC3=5, DC4=3.
4. **Type tags normalized**; mapper machines → `DieCastMachine`, "Terminal" regions → `Terminal`.
5. **Sub-line Cells = Terminals** only. Per Jacques: line-side storage, "machining cell", and "D station" comments are **ignored** (not Locations).
6. **Storage** — three Areas: Warehouse, Shipping IN, Shipping OUT.
7. **Printer model (FDS-10-008):** every `Terminal` carries **one `Printer` Cell-kind child** by default, code = `<terminal-code>-P1`. Multi-printer stations (N printers under one terminal, cavity-indexed) are flagged — ⚠6.

---

## Printer convention

Each terminal in the tables below has exactly **one `Printer` child** unless flagged. Printer code = terminal code + `-P1` (e.g., `MA2-6MACH-AOUT1` → printer `MA2-6MACH-AOUT1-P1`). `Endpoint` attribute (IP:port / queue) is filled at deployment.

---

## Areas + non-M&A Locations

**Die-cast terminals (per MPP, 2026-06):** one Terminal **shared across two machines** (pair terminals), not one per area. `DC<n>-T01` serves M01+M02, `-T02` serves M03+M04, etc.; an odd last machine gets its own. Each pair terminal + one Printer. *(Interpreted as the die-cast terminal model — pair terminals replace the single area terminal. Say if you also want a separate area-wide terminal.)*

| Area | Code | Cells (kind) | Pair terminals (+ Printer each) |
|---|---|---|---|
| Die Cast 1 | `DC1` | M01…M11 `DC1-M01`…`-M11` [DieCastMachine] ×11 | `DC1-T01`(M01,M02) … `-T05`(M09,M10), `-T06`(M11) — 6 |
| Die Cast 2 | `DC2` | M01…M03 [DieCastMachine] ×3 | `DC2-T01`(M01,M02), `-T02`(M03) — 2 |
| Die Cast 3 | `DC3` | M01…M05 [DieCastMachine] ×5 | `DC3-T01`(M01,M02), `-T02`(M03,M04), `-T03`(M05) — 3  (tablets? ⚠5) |
| Die Cast 4 | `DC4` | M01…M03 [DieCastMachine] ×3 | `DC4-T01`(M01,M02), `-T02`(M03) — 2 |
| Trim Shop 1 | `TRIM1` | — (area-level) | `TRIM1-T1` [Terminal] + `-P1` |
| Trim Shop 2 | `TRIM2` | — (area-level) | `TRIM2-T1` [Terminal] + `-P1` |
| Warehouse | `WHSE` | — (⚠7) | — |
| Shipping IN | `SHIPIN` | — (⚠7) | — |
| Shipping OUT | `SHIPOUT` | — (⚠7) | — |

---

## Machining & Assembly 1 — terminal seed (`MA1`)

*16 terminals; each + one `Printer` child. Line-side storage / machining-cell / D-station ignored per Jacques.*

| WorkCenter | Code | Terminals (role → code) |
|---|---|---|
| Comp bracket | `MA1-COMPBR` | Machining IN `…-MIN`, Assembly OUT `…-AOUT` |
| 6MD | `MA1-6MD` | Machining IN `…-MIN`, Assembly OUT `…-AOUT` |
| Fuel Pump (RPY 66v) | `MA1-FPRPY` | Machining IN `…-MIN`, Machining OUT `…-MOUT`, Assembly Finished `…-AFIN` |
| Fuel Pump (6na 6vj) | `MA1-FP6NA` | Machining IN `…-MIN`, Machining OUT `…-MOUT`, Assembly Finished `…-AFIN` |
| 5GO Rear | `MA1-5GOR` | Machining IN `…-MIN`, Machining OUT `…-MOUT`, Assembly Serialized `…-ASER` |
| 5GO Front | `MA1-5GOF` | Machining IN `…-MIN`, Machining OUT `…-MOUT`, Assembly Serialized `…-ASER` |

## Machining & Assembly 2 — terminal seed (`MA2`)

*40 terminals; each + one `Printer` child.*

| WorkCenter | Code | Terminals (role → code) |
|---|---|---|
| RPY 6b2 line2 | `MA2-RPY6B2` | Machining IN `…-MIN`, Machining OUT (sublot/split) `…-MOUT`, Assembly IN `…-AIN`, Assembly Finished `…-AFIN` |
| RPY Line 2 Cam holders | `MA2-RPYCAM2` | Machining IN Side A (cav 1,2,3,4,6) `…-MIN-A`, Machining IN Side B (cav 5) `…-MIN-B`, Machining OUT Side A `…-MOUT-A`, Machining OUT Side B `…-MOUT-B`, Assembly IN (shared) `…-AIN`, Assembly OUT 1/2/3 `…-AOUT1/2/3` |
| RPY Line 1 CH | `MA2-RPYCAM1` | *mirror of RPY Line 2* — `…-MIN-A`, `…-MIN-B`, `…-MOUT-A`, `…-MOUT-B`, `…-AIN`, `…-AOUT1/2/3` |
| 5PA Fuel Pump | `MA2-5PA` | Machining IN 1/2/3 `…-MIN1/2/3` |
| 6ma oil pan | `MA2-6MAOP` | Machining IN `…-MIN`, Assembly OUT `…-AOUT` |
| v6 oil pan | `MA2-V6OP` | Machining IN `…-MIN`, Assembly OUT `…-AOUT` |
| COS | `MA2-COS` | Machining OUT (offsite-origin) `…-MOUT` |
| 6F9-TC | `MA2-6F9TC` | Machining OUT (offsite-origin) `…-MOUT` |
| 59b Cam holder | `MA2-59B` | Machining IN `…-MIN`, Assembly OUT 1/2 `…-AOUT1/2` (1 active, customer-dependent) |
| 6FB CH/OP | `MA2-6FBCHOP` | Machining IN `…-MIN`, Assembly OUT `…-AOUT` |
| 64A Oil Pan | `MA2-64AOP` | Machining IN `…-MIN`, Assembly OUT `…-AOUT` |
| 6MA CH | `MA2-6MACH` | Machining IN `…-MIN`, Assembly OUT 1/2/3 `…-AOUT1/2/3` (customer-dependent) — multi-printer? ⚠6 |

---

## Open items — remaining

| # | Item | Question / default |
|---|---|---|
| ⚠1 | RPY 6b2 line2 room | ✅ M&A 2. |
| ⚠2 | Die Cast machine counts | ✅ DC1=11, DC2=3, DC3=5, DC4=3. |
| ⚠3 | RPY Line 2 Cam holders | ✅ 6-cavity (1,2,3,4,6 / 5) → 8 terminals. |
| ⚠3b | RPY Line 1 CH | ✅ Mirrors RPY Line 2 (8 terminals). |
| ⚠4 | machining cell / D station / line-side storage | ✅ Ignored — not Locations. |
| ⚠5 | Tablets (DC2/DC3) | **Default:** fold into the shared `DC*-T1` terminal; not seeded separately. Seed each tablet as its own `Terminal` if you want per-tablet attribution. |
| ⚠6 | Multi-printer-per-terminal stations | The N-printers-under-one-terminal (cavity-indexed) case from the printer design — which terminal(s) physically have it? (6MA CH's 3 assembly-outs are separate *terminals*, 1 printer each by default — confirm if any is the per-box multi-printer case.) |
| ⚠7 | Storage granularity | **Default:** Warehouse / Shipping IN / Shipping OUT as bare Areas (lots reference via `CurrentLocationId`). Add an `InventoryLocation` Cell under each if you want a Cell-tier handle. |
| ⚠8 | Code scheme | Proposed above (`<AREA>-<WC>-<ROLE>`, printer `+-P1`). Approve or adjust. |

---

## Tally (validated tree)

- **Areas:** 11 (4 Die Cast, 2 Trim, 2 M&A, 3 Storage)
- **WorkCenters:** 18 (6 in M&A 1, 12 in M&A 2)
- **`DieCastMachine` Cells:** 22 (DC1=11, DC2=3, DC3=5, DC4=3)
- **Terminals:** 62 → M&A 1 = 16, M&A 2 = 40, Die Cast = 4, Trim = 2
- **`Printer` Cells:** 62 (one per terminal; +N where ⚠6 resolves to multi-printer)
- **Total Locations:** ~11 + 18 + 22 + 62 + 62 ≈ **175** (excluding Enterprise/Site)
