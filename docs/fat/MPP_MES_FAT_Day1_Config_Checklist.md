# MPP MES — Pre-Commissioning / Day-One FAT Configuration Checklist

Everything that must be **configured, connected, and verified** before the FAT test cases
(`MPP_MES_FAT_practice.xlsx`) or on-site commissioning can run. This is *"is the system set up"*;
the workbook is *"does each function pass."* Work top-down — later phases depend on earlier ones.

> **Inputs folded in:** PLC commissioning-readiness map + gap brief (`notes/2026-08-11_plc-*.md`),
> the OPC device↔terminal mapping, `reference/MPP_Terminal_Printer_Inventory.xlsx`, the location
> reconciliation pipeline (`sql/seeds/gen_locations_mpp.js`), and `MPP_MES_SEEDING_REGISTRY.md`.
> Legacy IDs in the inventory doc are **not authoritative** — content only.

**Environment under test** (fill at witnessing):

| | Value |
|---|---|
| Ignition Gateway version / license | |
| Modules (Perspective, Reporting, OPC-UA) | |
| SQL Server / database | |
| Git commit / build tag | |
| Location model source | `MPP_MES_Site` → generated `011_seed_locations_mpp_plant.sql` |
| Date(s) / witnesses | |

Legend: ☐ to do · ✅ done/verified · ⚠️ confirm on-site · 🚩 open gap · ▣ this-session data provided

---

## Phase 1 — Infrastructure & connectivity

- **☐ 1.1 Ignition Gateway** — installed, licensed; Perspective + **Reporting** + OPC-UA modules active; gateway reachable at its URL; project(s) `Core` / `MPP` / `MPP_Config` present and healthy.
- **☐ 1.2 Database connection** — SQL Server 2022 reachable; Ignition datasource configured (prod: a managed `ignition` login with least-privilege — EXECUTE on app schemas, SELECT/INSERT/UPDATE on NQ tables, **no db_owner**; password in gateway config, not repo). Test query succeeds.
- **☐ 1.3 Active Directory** — gateway joined / AD IdP configured (see Phase 3).
- **☐ 1.4 OPC servers reachable** — **OmniServer** (scales), **TOPServer.V5** (PLCs: Pro-face LT3300 / MicroLogix1400 / EtherNet-IP), **Cognex** vision controllers. Each OPC connection Green in the gateway; UDT instances repointed from `MPP_Sim` → the real servers (see Phase 5).
- **☐ 1.5 Printers on the network** — Zebra printers reachable at their `Endpoint` (IP:9100 or share path); test print from each (Phase 4).
- **☐ 1.6 AIM (Honda EDI) endpoint** — the AIM HTTP interface configured with the **prod** endpoint (not the dev stub); GetNextNumber / UpdateAim / PlaceOnHold / ReleaseFromHold reachable; `InterfaceLog` records calls.

---

## Phase 2 — Database schema & deployment

- **☐ 2.1 Migrations applied** — all versioned migrations run; `dbo.SchemaVersion` current (no gaps — the 0017–0019 ledger reconcile is in).
- **☐ 2.2 Repeatable procs deployed** — all `R__*.sql` objects present (deploy is by re-running repeatables; verify count vs `sql/migrations/repeatable`).
- **☐ 2.3 Seed scripts loaded** — `sql/seeds/*` applied (locations, items, routes, op templates, defect/downtime codes, AIM pool).
- **☐ 2.4 Timezone** — server/session confirms UTC-store / Eastern-display behavior on a sample read proc.

---

## Phase 3 — Active Directory & user provisioning

- **☐ 3.1 Identity provider** — Ignition project auth wired to AD (this is platform auth, not MES-code — FAT-USR-070/160 close here). Security levels / roles mapped: **Admin / Engineer / Quality / Supervisor / Operator**.
- **☐ 3.2 Interactive (AD) users** — engineering/quality/supervisor accounts resolve via AD; role mapping verified.
- **☐ 3.3 Operator AppUsers** — shop-floor operators loaded with **Initials** (AdAccount NULL, no Ignition role); initials resolve at a terminal; **deprecated initials rejected** at presence sign-in (FAT-USR-090).
- **☐ 3.4 Per-action AD elevation** — supervisor-elevated actions (hold release, nav-lock, die-cast tool config) prompt for AD credentials and gate correctly.
- **☐ 3.5 `AppUser` ↔ AD-name mapping** — the elevation two-layer (user-source password + AppUser AD-name) is populated for each elevatable user.

---

## Phase 4 — Location model (terminals · IPs · printers · closure)

The MES resolves each terminal by the **IP it connects from** → `DefaultScreen`. Base tree is
generated (`011_seed_locations_mpp_plant.sql`) from `MPP_MES_Site`.

### 4.1 Terminal IP registration
- **▣ ✅ Seed-ready IPs** (from inventory doc, applied via `_inventory_attributes.tsv`): `MA2-6MAOP-AOUT`=172.17.20.115 · `MA2-59B-MIN`=172.17.14.117 · `MA2-64AOP-AOUT`=172.17.14.232 · `MA2-6MACH-AOUT1`=172.17.20.55 · `MA2-6MACH-AOUT2`=172.17.20.57 · `MA2-6MACH-MIN`=172.17.14.211 · `MA2-6FBCHOP-MIN`=172.17.14.169 · `MA2-RPYCAM2-AOUT1`=172.17.20.162.
- **☐ ⚠️ Remaining terminal IPs** — assign IPs to the matched terminals the doc left blank (5G0 Front/Rear, compressor bracket, 5PA/6MD machining) and confirm every station resolves to the right screen on-site.
- **☐ ⚠️ Pass-through terminals** (`172.31.x` / `192.168.x`, ~14 rows: 6MD/6A0/RJ2/64S…) — confirm out-of-MES-scope.

### 4.2 Model gaps to confirm on the floor 🚩
- **☐ 6FB — floor walk says "6FB is just the small parts."** The inventory lists **two** assembly-out IPs on the 6FB line — CH/cam `172.17.20.43` and OP/oil-passage `172.17.20.50` — but the model has one `MA2-6FBCHOP-AOUT`. **Confirm:** is 6FB assembly-out a **single small-parts station** (the model is correct; the two IPs are one station / spare), or two distinct stations needing a split? *(Floor input: "just the small parts" → likely single — confirm and retire the extra IP.)*
- **☐ 5J6 Oil Pan** — no `5J6` line exists in the model (added this session — verify: see 4.4). Confirm 5J6 is its own line vs. runs on an existing oil-pan line.
- **☐ RPY-cam AIN** — RPY L1 CH-Set Assembly-In shows two IPs (`172.17.20.126` / `.124`) → one terminal. Confirm one vs two stations.

### 4.3 Printers
- **▣ ✅ 10 METTS printers** — `MA2-59B-AOUT1` emits `P1…P10` (one per part, `59BL3 P1..P10`, GX420D/Ethernet). Built via the generator `MULTI_PRINTER` rule; verified in Dev.
- **☐ Printer endpoints/models** — set `Endpoint` / `Model` / `ConnectionKind` from the inventory Printers tab (most are `\\FLXWAPSRV1\<name>` share → `Hardwired`; some GX420D/ZD621). Test print each.
- **☐ Hold/shipping printers** — `Shipping Hold 1`, `Zebra Hold 1/2` placement confirmed.

### 4.4 Closure & structure
- **☐ `CurrentClosureMethod`** (`ByCount`/`ByWeight`/`ByVision`) correct per assembly-out terminal; METTS = `ByCount` (no PLC vision/scale device).
- **☐ Terminal fallback** — unregistered-IP behavior returns the Fallback Terminal (subtitle "Madison Facility") — confirm real terminals never fall back.

---

## Phase 5 — PLC / OPC device connections

Until `Location.TerminalPlcDevice` rows exist, all 33 wired PLC edges hit "no mapping → ignored"
and nothing routes (FAT-PLC-020 — **the #1 integration blocker**). Detail:
`notes/2026-08-11_plc-commissioning-readiness-map.md`.

- **▣ ✅ 5.1 Seed `TerminalPlcDevice`** — **built**: `sql/seeds/012_seed_terminal_plc_device.sql` (17 active + 5 deprecated; idempotent MERGE by instance path; corrects the stale manual 59B row off the METTS terminal). Applied to Dev; `getByInstancePath` resolves. At commissioning: re-run after the UDT→OPC repoint (5.4) and confirm each wired edge routes.
- **✅ 5.2 RPY device→line resolved** (2026-08-12) — `CB`/`CH`/`FP` are station codes: `RPY_1_FP_1` → `MA1-FPRPY-AOUT` (Fuel Pump, vision-through-scale) · `RPY_1_CB_1` → `MA1-COMPBR-AOUT` (**Comp Bracket** — note: terminal has no `ByWeight` closure, so the scale is a weigh-check not the primary closure) · `RPY_CH` → `MA2-RPYCAM1-AOUT1` (**Line 1** Cam Holders).
- **☐ 🚩 5.3 Unmapped devices** — `5A2 × 4` and `5J6_OilPan` have no model line (deprecated-flag or add the lines).
- **☐ 5.4 UDT→OPC binding** — repoint each `PlcDevices` UDT instance `Device`/`OpcServer` from `MPP_Sim` to the real OmniServer/TOPServer node; fix the `6FB_CH` driver-name typo (`Micrologix1400` vs `MicroLogix1400`); reproduce the `5G0_A1.5G0_A1.<member>` double-node path exactly.
- **☐ 5.5 Vision-through-scale validation** ⚠️ — `5PA - AO`, `MA1-FPRPY-AFIN`, `MA1-FP6NA-AFIN` are camera-through-scale (SITE desc "validate tags"). Confirm the PLC-side UDT (ScaleStation vs TrayInspection) and tag map; `FP6NA` has no named OPC scale — confirm its device.
- **☐ 5.6 Simulator/live acceptance** — record a MIP + vision + scale handshake pass (`/dev/sim/plc` or live).
- **☐ 5.7 Vision escalation scope** ⚠️ — confirm whether FDS-10-009/010/013 (consecutive-fail escalation, failure-type branching, ConfirmationMethod, dual-source) are **MVP or commissioning-phase** (all MES-side, currently unbuilt — gap brief specs P2–P4).

---

## Phase 6 — Part & process master data

- **☐ 6.1 Item Master** — all parts loaded; `PartNumber` matches the AIM/Honda part; `Description` set (drives the shipping label). Cross-check against `reference/MPP_Parts_Final.xlsx` / `MPP_Part_Data_Collection_COMPLETE.xlsx`.
- **☐ 6.2 ItemType → Area** — each item's type gates its allowed areas/routes (a FG can't take a die-cast route).
- **☐ 6.3 Container configs** — `IsSerialized` flag, `MaxParts` (per-location cap), `MaxLotSize` (basket), weight/UOM per item.
- **☐ 6.4 Routes published** — terminal-mint routes per part (Die Cast → Trim → Machining → Assembly), each ending at a ConsumeMint; **published** (not Draft), prior versions retained.
- **☐ 6.5 BOMs published** — parent/child BOMs published; as-built version surfaces on the LOT.
- **☐ 6.6 Operation templates published** — per role (DieCast/Trim/Machining/Assembly IN-OUT); Draft/Published lifecycle; resolver finds the active template by role for every routed part.
- **☐ 6.7 Quality specs published** — spec attributes + UoM per operation where inspection is required.
- **☐ 6.8 Eligibility** — line/part move-eligibility loaded so validated moves resolve against the terminal's parent zone; confirm each active part is eligible at its line's terminals (no false "Not eligible").
- **☐ 6.9 Die-rank compatibility** (Seeding Registry **S-08** — the one seed that blocks) — die-rank genealogy mapping loaded for the shipping-label DC part-level.
- **☐ 🚩 6.10 Die-cast press × part eligibility** (working session w/ MPP Engineering) — capture which physical die-cast presses may run each casting, **keyed by clamp tonnage**. Neither legacy system recorded this transactionally — the traceability MES collapses all casting into two cells (`5A2 Casting 1` / `5G0 Casting 1`, machine granularity is only the `Die Name` + `Cavity Name` LOT attributes), and the Productivity DB holds the ~27 numbered presses + tonnage but no machine→part link. **MPP Engineering knows the eligibility by tonnage** (part → allowable press set); sit with them on day one, capture the matrix, and load it as die-cast machine/part eligibility so the DieCast terminal queue + validated moves resolve the correct press set per part. Machine names/tonnages source from the PD roster (`reference/seed_data/machines.csv`: DieCast#1‑#77 @125‑1650T, VCM#501‑504, Hoffman DC, ACP, KensCorp).

---

## Phase 7 — Code tables & external seed data

- **☐ 7.1 Defect codes** — loaded, scoped by `OperationCategory` (die-cast / trim / machining-assembly filters correct).
- **☐ 7.2 Downtime reason codes** — 353/353 loaded, schema-correct.
- **☐ 7.3 Shift schedules** — shift instances/schedules seeded for the go-live window.
- **☐ 7.4 AIM shipper-ID pool** — configured + primed; empty-pool hard-fail posture confirmed (OI-33).
- **☐ 7.5 Label templates** — active `LabelTemplate` per type (LTT + Honda container, ported ZPL); `{Placeholder}` tokens resolve; ASCII-only; render-tested on the target printer.
- **☐ 7.6 Seeding Registry sweep** — walk `MPP_MES_SEEDING_REGISTRY.md` (S-01…S-11); every item Received → Loaded(Dev) → Verified(Cutover).

---

## Phase 8 — Reporting & pre-FAT smoke

- **☐ 8.1 Reports** — Reports landing page (`/shop-floor/reports`) reachable; the 6 reports render + Print-PDF on the gateway.
- **☐ 8.2 End-to-end smoke** — one LOT walked Die Cast → Trim → Machining → Assembly → container → ship, confirming genealogy, attribution (signed-in operator), and label prints — before running the FAT workbook.

---

## Sign-off

| Role | Name | Signature | Date |
|---|---|---|---|
| MPP — Acceptance | | | |
| MPP — Quality | | | |
| Blue Ridge — Lead | | | |

**Revision history**

| Rev | Date | Change |
|---|---|---|
| 0.1 | 2026-08-12 | Initial — terminal IP match, printers, PLC device mapping, vision-through-scale, closure. |
| 0.2 | 2026-08-12 | Expanded to full pre-commissioning scope: infrastructure/connectivity, DB & schema, Active Directory & users, part & process master data + eligibility, code tables & seed registry, reporting & smoke. Added 6FB "just small parts" floor-walk confirmation item. |
| 0.3 | 2026-08-12 | Added 6.10 die-cast press × part eligibility (tonnage-driven) — MPP Engineering working session to capture the machine→part mapping neither legacy system recorded. |
