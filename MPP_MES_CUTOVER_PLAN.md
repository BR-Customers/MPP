# MPP MES Cutover Plan

**Purpose:** A working checklist for cutting over from the legacy SparkMES-lineage
system (`MES` + `EMMD` DBs on `EXCSRV05`) to the new Ignition Perspective +
SQL Server 2022 MES. Work through it top-to-bottom; fill in the **DECISION** boxes
first, since they determine which data-migration items apply.

> **Scope note:** "Data Migration" is a **CONDITIONAL** scope item in
> `reference/MPP_Scope_Matrix.xlsx` — build only if MPP approves. This plan
> assumes it may be in scope; if MPP chooses a clean cutover, most of Tier 1
> drops out.

---

## 0. Context (what already exists — so this doc stands alone)

- **Legacy source:** `MES` db (parts/BOM/genealogy/lots) + `EMMD` db (OPC/handshake
  engine) on `EXCSRV05`. See memory `project_mpp_legacy_source_system` and
  `docs/superpowers/specs/2026-07-08-legacy-master-data-mapping-and-golden-thread-seed-design.md`.
- **Read-only extract scripts:** `sql/scratch/emmd_discovery.sql`,
  `emmd_extract_master_data.sql` (run vs `MES`), `emmd_extract_automation_config.sql`
  (run vs `EMMD`).
- **Master/reference data already pulled** to `reference/legacy_mes_extract/*.csv`
  (materials, bom, bom_components, workcell_material, code_tables,
  production/work orders, locations, customers, identifier_formats,
  label_templates + schema catalogs).
- **New-model config already built:** plant locations (`sql/seeds/011`), item /
  BOM / route seeds, and the golden-thread validation seed
  (`sql/scratch/seed_jp_validation.sql`).
- **External (non-legacy) prerequisites:** tracked in `MPP_MES_SEEDING_REGISTRY.md`
  (S-01..S-11). **S-08 DieRankCompatibility is the one true go-live blocker.**

---

## 1. Cutover strategy — DECIDE FIRST

The single decision that drives everything below.

- [ ] **DECISION D1 — Cutover model:**
  - **Clean cutover** — pick a shutdown window, drain WIP to finished/shipped on
    the legacy system, go live fresh. Plant starts minting new LOTs on day 1.
    *No Tier-1 live-WIP migration needed.* Simplest, lowest risk. **← recommended if operations can absorb a drain.**
  - **Hot cutover** — plant keeps running across the switch; parts already
    in-process must stay tracked. *Requires all of Tier 1.* Higher risk/effort.

  **Chosen model: ______________   Target window/date: ______________**

- [ ] **DECISION D2 — Historical genealogy** (Honda recall traceability):
  - **Read-only archive** — keep legacy `MES` DB queryable for pre-cutover
    genealogy; new system holds only post-cutover genealogy. **← recommended (39M+ rows).**
  - **Migrate** — load historical `LotBomComponent` / `SerializedItemBomComponent`
    into the new genealogy tables.

  **Chosen approach: ______________**

- [ ] **DECISION D3 — Traceability lookback horizon:** how far back must genealogy
  be queryable, and by whom (Quality, Honda audit)? **______________**

- [ ] **DECISION D4 — Window & coordination:** plant shutdown window agreed with
  MPP ops + Honda EDI (AIM) contacts; rollback window length agreed.
  **______________**

---

## 2. Pre-cutover prerequisites (config staged before the window)

Everything here is done ahead of time and dry-run-verified on `MPP_MES_Test`.

- [ ] **P1 — Migrations applied** to the production `MPP_MES` DB (all versioned +
  repeatable migrations, current through `0036`).
- [ ] **P2 — Plant location tree loaded** (`sql/seeds/011_seed_locations_mpp_plant.sql`).
- [ ] **P3 — Master/reference config loaded** — items, BOMs, routes, operation
  templates, container configs, quality specs. (Derive from
  `reference/legacy_mes_extract/` per the mapping spec; the golden-thread seed is
  the pattern.)
- [ ] **P4 — External seed items received + loaded** — walk `MPP_MES_SEEDING_REGISTRY.md`;
  confirm every item is Loaded(Dev) → Verified(Cutover). **Blocker: S-08
  DieRankCompatibility.**
- [ ] **P5 — OPC / PLC integration rebuilt** in Ignition (Gateway scripts + OPC
  from TOPServer/OmniServer/Cognex; MIP handshakes). Cross-checked against
  `emmd_extract_automation_config.sql` output (the legacy `Event`/`Action`/`Script`
  logic) and the opc_tags seed.
- [ ] **P6 — Security** configured (AD groups + Ignition roles; initials-based
  operator attribution). *Not migrated from legacy `RolePrivilege`.*
- [ ] **P7 — Label templates + printers** configured (ZPL templates, Zebra
  printer endpoints; printer→cell mapping). See `label_templates.csv` and
  legacy `LabelPrinter` / `offsite.LabelPrintingConfiguration` for the mapping.
- [ ] **P8 — Honda AIM (EDI) interface** connected/tested for shipping IDs + hold
  notifications.
- [ ] **P9 — Full migration dry-run** executed end-to-end on `MPP_MES_Test`;
  reconciliation (§5) passes.

---

## 3. Data-migration items (by tier)

`X` = required. Extract scripts to be written under `sql/scratch/` and dry-run on
`MPP_MES_Test` before the window.

| ID | Data | Legacy source table(s) | Clean | Hot | Target (new) | Extract script | Done |
|----|------|------------------------|:---:|:---:|--------------|----------------|:---:|
| **M1** | Identifier counters (next LTT / serial #) | `IdentifierFormat.LastCounterValue`, `NumberStorage` | X | X | Identifier sequence (`0020` foundation) | TODO | [ ] |
| **M2** | Active holds | `Lot` where `DispositionID`=HOLD + reason; AIM holds | X | X | `Quality.HoldEvent` + lot status | TODO | [ ] |
| **M3** | Open LOTs + die/cavity attrs | `Lot` (open), `LotAttributeValue` (Die/Cavity Name) | – | X | `Lots.Lot` + lot attributes | TODO | [ ] |
| **M4** | Open containers/baskets + contents | `Container`, `ContainerLot`, `ContainerSerializedItem` | – | X | `Lots.Container` / tray / serial | TODO | [ ] |
| **M5** | Line-side material allocations | `WorkCellMaterialLot` | – | X | new allocation/queue tables | TODO | [ ] |
| **M6** | Open sublots | `SubLot` | – | X | `Lots.SubLot` (or split model) | TODO | [ ] |
| **M7** | Open serialized parts | `SerializedItem` (open) | – | X | `Lots.SerializedPart` | TODO | [ ] |
| **M8** | In-flight genealogy (open assemblies) | `LotBomComponent`, `SerializedItemBomComponent` (open) | – | X | `Lots.LotGenealogy` + `LotGenealogyClosure` | TODO | [ ] |
| **M9** | Historical genealogy (recall) | `LotBomComponent(_Historical)`, `SerializedItemBomComponent`, `Lot_Historical`, `*Transaction` | per D2 | per D2 | archive DB **or** genealogy tables | TODO | [ ] |
| **M10** | Label printer→template→cell config | `LabelPrinter`, `LabelPrinterLabelTemplate`, `offsite.LabelPrintingConfiguration` | opt | opt | Location/printer defs | TODO | [ ] |

**Not migrated (rebuilt in the new system):** OPC/handshake config (`EMMD`
`Event`/`Action`/`Script`/OPC*), security (`ActiveDirectoryGroup`/`RolePrivilege`),
dashboards/UI config, `LblParts` (empty). See P5–P7.

---

## 4. Cutover runbook (day-of sequence)

### Phase A — T-minus (days before)
- [ ] Config load (§2) complete on production `MPP_MES`.
- [ ] Migration scripts (M1–M10 as applicable) finalized + dry-run-clean on Test.
- [ ] Go/No-Go review with MPP: prerequisites green, S-08 resolved, window confirmed.

### Phase B — Freeze (window start)
- [ ] Stop new LOT creation on legacy; operators finish/park in-flight work.
- [ ] (Hot only) Quiesce lines to a consistent state for the WIP snapshot.
- [ ] **Final extract** from legacy: M1 counters, M2 holds, and (hot) M3–M8 open state.
- [ ] Snapshot/backup legacy `MES` DB (becomes the D2 read-only archive if chosen).

### Phase C — Load
- [ ] Load M1 identifier counters → set new identifier sequences **above** the
  legacy last value (avoid collisions with field/Honda labels).
- [ ] Load M2 active holds.
- [ ] (Hot) Load M3–M8 open WIP, containers, allocations, serialized items,
  in-flight genealogy — in FK-safe order.

### Phase D — Verify (see §5)
- [ ] Reconciliation counts pass.
- [ ] Golden-thread spot-checks pass (a real part scans, routes, mints).
- [ ] Counters verified (new LTT/serial issues a non-colliding number).
- [ ] (Hot) Sample open LOTs resolve full genealogy + correct location/qty/state.

### Phase E — Go-live
- [ ] Point plant-floor terminals / Ignition sessions at the new system.
- [ ] Operators resume production; monitor first LOTs through each area.
- [ ] Confirm label printing + AIM shipping on the first real shipment.

### Phase F — Fallback (if verification fails within the window)
- [ ] Rollback criteria met? (define below) → revert terminals to legacy;
      legacy was never decommissioned during the window.
- [ ] Post-mortem; reschedule.

**Rollback criteria (fill in):** ________________________________________________

---

## 5. Verification & reconciliation

- [ ] **Counts:** for each migrated table, `legacy open-row count == new-row count`.
- [ ] **Identifier safety:** new next-number > legacy `LastCounterValue` for both
      MESL (lot) and MESI (serial).
- [ ] **Config integrity:** item / BOM / route counts match the mapped extract;
      every published route passes `Parts.RouteTemplate_Publish` legality.
- [ ] **Genealogy:** pick 3–5 recent finished LOTs; confirm full parent→child
      lineage resolves (in new system if migrated, or archive if D2=archive).
- [ ] **Holds:** every legacy open hold is present and blocking in the new system.
- [ ] **(Hot) WIP position:** sample open LOTs at each area show correct location,
      quantity, state, and staged allocations.
- [ ] **Dirty-data check:** confirm ASCII-only on migrated names/dunnage (legacy
      `ReturnableDunnageCode` mojibake `?????` cleaned, not carried over).

---

## 6. Open decisions register

| # | Decision | Owner | Status | Notes |
|---|----------|-------|--------|-------|
| D1 | Clean vs hot cutover | MPP + Blue Ridge | Open | Drives Tier-1 scope |
| D2 | Genealogy: archive vs migrate | MPP Quality | Open | 39M+ rows; archive recommended |
| D3 | Traceability lookback horizon | MPP Quality / Honda | Open | |
| D4 | Window + AIM coordination | MPP Ops | Open | |
| — | Identifier-sequence starting offset | Blue Ridge | Open | Must exceed legacy last value |
| — | Label printer config: migrate vs re-author | Blue Ridge | Open | M10 |

---

## 7. Revision History

| Version | Date | Author | Notes |
|---------|------|--------|-------|
| 0.1 (draft) | 2026-07-10 | Jacques + Claude | Initial cutover plan: strategy decisions, prerequisites, tiered data-migration items grounded in the legacy `MES` table inventory, day-of runbook, verification + rollback. |
