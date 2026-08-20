# MPP MES — Seeding Registry

**Document:** FDS-MPP-MES-SEED-001
**Version:** 1.0 — Initial draft
**Date:** 2026-04-27
**Prepared By:** Blue Ridge Automation
**Prepared For:** Madison Precision Products, Inc. (Madison, IN)

This registry tracks every seed-data item the MES requires from sources **external to Blue Ridge** (MPP IT, MPP Quality, MPP Engineering, Honda AIM, vendor exports). Internal code-table seeds baked into migrations are NOT tracked here — those ship with the SQL.

> **Seeding items are NOT blockers for design or SQL build work.** Schemas, procs, and screens proceed in parallel; this registry exists so we collect the data alongside the build and load it during the cutover phase. An item is only a "blocker" if a downstream design decision genuinely requires its content (rare — flagged explicitly per item below).

---

## Revision History

| Version | Date | Author | Change Summary |
|---|---|---|---|
| 1.0 | 2026-04-27 | Blue Ridge Automation | Initial registry. Catalogues 11 external-source seed items extracted from CLAUDE.md "MPP-owed" + "MPP data loads" sections. Establishes the registry as the single source of truth for seed-data tracking, removing seed items from the "blocking specific downstream work" framing in CLAUDE.md. |
| 1.1 | 2026-08-18 | Blue Ridge Automation | Adds **S-12 — Macola part-number list** (workbook `MACOLA NUMBERS FOR INVENTORYupdate 6-15-26.xlsx`, received 2026-06-15, partially loaded to Dev). Records the governing rule that a Macola number comes only from a column headed `MACOLA #`, the finished-good gap it exposes, and the reconciliation outcome. Cross-references added to S-05 (Parts master) and S-06 (BOM export), both of which this workbook partially satisfies. |
| 1.2 | 2026-08-20 | Blue Ridge Automation | Adds **S-13 — Label template ZPL bodies**. Dev carries MPP's real LOT-ticket layouts, loaded out-of-band; no migration or seed reproduces them, so a fresh deploy ships migration 0021's placeholder. Records the CRT `{CrtMark}` interaction (D8) and why a blanket `{LotName}` replace is unsafe — the Master and Void templates carry a `{LotName}` inside a `^BC` barcode field. |
| 1.3 | 2026-08-20 | Blue Ridge Automation | Narrows **S-13** to what was actually captured. A byte-exact comparison of the four Dev bodies against the migrations showed only the **Primary** layout is unreproduced; Container is a verbatim copy of migration `0054`, and Master/Void are migration `0021`'s placeholder plus `0063`'s `{CrtMark}` patch. Seed `032` is scoped to Primary so it cannot outrank those migrations; Status, Blocking, and "What is owed" updated to match. |
| 1.4 | 2026-08-20 | Blue Ridge Automation | Rewrites the CRT interaction in **S-13**. The `{CrtMark}` inline token is withdrawn: a CRT LOT now prints its normal ticket unchanged plus a SEPARATE `CrtBanner` label (migration `0065`). MPP's label layouts are no longer edited by the CRT feature at all, so the `{CrtMark}` placement decision is no longer owed and the barcode hazard is no longer a CRT concern — the hazard note is retained because it still governs any future edit to those templates. |

---

## Status Legend

| Badge | Meaning |
|---|---|
| ⬜ **Owed** | File / list / decision not yet received from external source. |
| 🟡 **Received** | Delivered to Blue Ridge; not yet loaded into dev. |
| ✅ **Loaded (Dev)** | Loaded into dev SQL DB; queryable; tests passing where applicable. |
| 🔵 **Verified (Cutover)** | Loaded into production-equivalent + validated by the responsible MPP stakeholder. |

---

## Summary

| ID | Item | Target | Status | Owner | Blocking? |
|---|---|---|---|---|---|
| S-01 | Plant equipment master | `Location.Location` (Cell-tier) | 🟡 Received | MPP Eng. for tier mapping | No |
| S-02 | Downtime reason codes | `Oee.DowntimeReasonCode` | 🟡 Received | MPP Eng. for DC/MS/TS→Area mapping | No |
| S-03 | Defect codes | `Quality.DefectCode` | 🟡 Received | MPP Quality for Area mapping | No |
| S-04 | OPC tag catalog | Ignition OPC config (not SQL) | 🟡 Received | MPP Eng. for endpoint validation | No |
| S-05 | Parts master list | `Parts.Item` | ⬜ Owed | MPP IT (export from Macola/Flexware) | No |
| S-06 | Flexware BOM export | `Parts.Bom` + `Parts.BomLine` | ⬜ Owed | MPP IT (OI-13 — two-pull) | No |
| S-07 | Die rank list | `Tools.DieRank` | ⬜ Owed | MPP Quality | No |
| S-08 | Die rank compatibility matrix | `Tools.DieRankCompatibility` | ⬜ Owed | MPP Quality | **Yes** — gates cross-die merges (FDS-05-027) without supervisor override |
| S-09 | Label-type seed validation | `Lots.LabelTypeCode` (already seeded with Blue Ridge guesses) | ⬜ Owed | MPP Shipping | No |
| S-10 | Identifier sequence baselines | `Lots.IdentifierSequence.LastValue` | ⬜ Owed | MPP IT (snapshot at cutover) | **Cutover-only** — not blocking dev |
| S-11 | AIM pool config tuning | `Lots.AimPoolConfig` (defaults already seeded 50/30/20/10) | 🟡 Received (defaults) | MPP for post-deploy tuning | No |
| S-12 | Macola part-number list | `Parts.Item.MacolaPartNumber` (+ partial `Parts.BomLine`) | 🟡 Received (partial) | MPP IT / Materials — FG Macola numbers still missing | No |
| S-13 | Label template ZPL bodies | `Lots.LabelTemplate.ZplBody` | 🟡 Received (partial — Primary seeded; Master/Void still placeholders) | MPP — to supply the real Master/Void layouts for version control | No |

**Counts:** 6 ⬜ Owed · 6 🟡 Received · 0 ✅ Loaded (Dev) · 0 🔵 Verified (Cutover)

**True blockers:** 1 (S-08 die rank compatibility — and even this has a supervisor-override workaround until populated).

---

## Per-Item Detail

### S-01 — Plant Equipment Master (Machines)

**Status:** 🟡 Received
**Source:** `reference/seed_data/machines.csv` (209 rows extracted from FRS Appendix B by Blue Ridge)
**Target:** `Location.Location` rows (Cell tier) + `Location.LocationAttribute` values for tonnage / cycle time / etc.
**Owner:** MPP Engineering — for tier mapping (DeptCode → AreaLocationId) and verification that the 2024 FRS extract still reflects today's plant.
**Blocking:** No — schema, procs, and screens proceed without this. Plant model exercises against 12 dev sample rows in `sql/seeds/seed_locations.sql`.

**File format:** CSV — columns: `MachId`, `MachNo`, `MachDesc`, `Tonnage`, `DeptDesc`, `MinPerShift`, `RefCycleTime`, `DeptCode`, `ProcId`, `ProcDesc`. Full column docs in `reference/seed_data/README.md`.

**Mapping owed from MPP Engineering:**
- `DeptCode` (DC, MS, TR, AS) → `AreaLocationId` (the actual `Location.Id` of each Area row).
- Confirmation that the 209-row FRS list is current — flag any decommissioned / new equipment since 2024.
- Validation that each row's `LocationTypeDefinition` (DieCastMachine vs CNCMachine vs TrimPress vs AssemblyStation, derived from `ProcDesc`) is correct.

**Loading procedure:** Bulk-load proc not yet written. Follows the `Oee.DowntimeReasonCode_BulkLoadFromSeed` JSON-fed pattern (S-02) — caller supplies a `@DeptCodeToAreaIdMap` JSON; proc inserts `Location.Location` rows + `Location.LocationAttribute` values per the FRS columns; deterministic Code generation `{DeptCode}-{MachNo}`.

**Acceptance criteria:**
1. All 209 rows (or MPP-revised count) load without error.
2. Each row's parent `AreaLocationId` matches the MPP-supplied mapping.
3. `LocationAttribute` rows for `Tonnage`, `RefCycleTime`, `MinPerShift` are present where the CSV has non-empty values.
4. `Location.LocationTypeDefinitionId` matches the CSV's `ProcDesc`.

---

### S-02 — Downtime Reason Codes

**Status:** 🟡 Received
**Source:** `reference/seed_data/downtime_reason_codes.csv` (353 rows extracted from FRS Appendix D — DC=86, MS=239, TS=25)
**Target:** `Oee.DowntimeReasonCode`
**Owner:** MPP Engineering — for DC/MS/TS → Area mapping and per-row `DowntimeReasonType` backfill where the CSV has missing TypeDesc.
**Blocking:** No — `Oee.DowntimeEvent` capture works against an empty DowntimeReasonCode set; reasons can be assigned later. OEE reporting requires this loaded before go-live.

**File format:** CSV — columns: `DeptCode`, `ReasonId`, `ReasonDesc`, `TypeDesc`, `IsExcused`. Full column docs in `reference/seed_data/README.md`.

**Mapping owed from MPP Engineering:**
- `DeptCode` (DC, MS, TS) → `AreaLocationId` (3 area Location IDs).
- Backfill `DowntimeReasonType` for any row where CSV `TypeDesc` is missing — engineering-level review can be done in dev via `_Update` calls on rows with NULL `DowntimeReasonTypeId`.

**Loading procedure:** `Oee.DowntimeReasonCode_BulkLoadFromSeed @ReasonsJson, @DcAreaId, @MsAreaId, @TsAreaId, @AppUserId` — built and tested in Phase 8. JSON-fed bulk load; deterministic Code generation `{DeptCode}-{NNNN}` (zero-padded `ReasonId`).

**Acceptance criteria:**
1. All 353 rows load (or MPP-revised count) without uniqueness violations on `Code`.
2. Rows with missing `TypeDesc` load with `DowntimeReasonTypeId = NULL`; engineering backfills via `_Update` before go-live.
3. The MPP-supplied DC/MS/TS → Area IDs match the actual Area rows in `Location.Location`.

---

### S-03 — Defect Codes

**Status:** 🟡 Received
**Source:** `reference/seed_data/defect_codes.csv` (153 rows extracted from FRS Appendix E)
**Target:** `Quality.DefectCode`
**Owner:** MPP Quality — for `AreaLocationId` mapping and confirmation that the FRS extract is current.
**Blocking:** No — non-conformance capture works against an empty DefectCode set.

**File format:** CSV — columns: `DefectId`, `DefectCode`, `DefectDesc`, `AreaCode`, `IsExcused` (or similar — see `reference/seed_data/README.md`).

**Mapping owed from MPP Quality:**
- `AreaCode` → `AreaLocationId`.
- Confirmation that the 2024 FRS list still reflects today's defect catalogue — flag adds / removes.

**Loading procedure:** Bulk-load proc not yet written. Follows the `DowntimeReasonCode_BulkLoadFromSeed` JSON pattern.

**Acceptance criteria:**
1. All 153 rows (or MPP-revised count) load.
2. `AreaLocationId` mapping matches the MPP-supplied Area IDs.

---

### S-04 — OPC Tag Catalog

**Status:** 🟡 Received
**Source:** `reference/seed_data/opc_tags.csv` (161 rows extracted from FRS Appendix C)
**Target:** Ignition OPC server configuration (NOT a SQL table). `OmniServer` for scales; `TOPServer` / `SWToolbox` for PLCs; Cognex for vision.
**Owner:** MPP Engineering — for endpoint IP / port validation and live-tag verification.
**Blocking:** No — Ignition OPC config can be assembled as Phase 7 progresses.

**File format:** CSV — columns: `ServerName`, `ServerPid`, `Direction`, `AccessPath`, `OpcItemId`. Full column docs in `reference/seed_data/README.md`.

**Validation owed from MPP Engineering:**
- Endpoint IP / port for each OPC server (cross-reference with `reference/NewInput/5GO-AP4 IPAddresses.xlsx`).
- Live verification that each tag is reachable and behaves per the FRS (read/write direction, value type, rate).

**Loading procedure:** Manual import into Ignition Designer at Arc 2 Phase 7 (OPC configuration phase).

**Acceptance criteria:**
1. Every `OpcItemId` resolves and reads/writes per the FRS spec on the live PLC/scale.

---

### S-05 — Parts Master List

**Status:** ⬜ Owed
**Source:** MPP IT export from Macola ERP and/or Flexware MES current parts table.
**Target:** `Parts.Item`
**Owner:** MPP IT — for the export.
**Blocking:** No — `Parts.Item_Create` / `_Update` procs work against an empty table; sample parts can be seeded for dev. Production cutover needs the full list before go-live.

**File format owed from MPP IT:** CSV or XLSX with at minimum: PartNumber, Description, MacolaPartNumber (optional), DefaultUomCode, UnitWeight (optional), WeightUomCode (optional), CountryOfOrigin (ISO 3166-1 alpha-2), MaxLotSize / PartsPerBasket (per-basket capacity), MaxParts (per-Location cap, optional), ItemType (Raw/Component/SubAssembly/FinishedGood). Format conversation with MPP IT pending.

**Mapping owed from MPP:**
- `ItemType` per row — likely derivable from MPP ERP categories.
- `CountryOfOrigin` per row — Honda compliance field (FDS-03-001).

**Loading procedure:** Bulk-load proc not yet written; format depends on what MPP IT exports.

**Acceptance criteria:**
1. Every part on MPP's master list loads as an `Item` row with non-empty `PartNumber` (UNIQUE), valid `UomId` FK, and correct `ItemType` FK.
2. `CountryOfOrigin` populated where MPP has the data.

**Partially satisfied by S-12.** The 2026-06-15 Macola workbook supplies the `MacolaPartNumber` field for 22 catalog components, and names ~40 further purchased parts (plus 4 raw-aluminum alloys) that are NOT in the current catalog. It does **not** supply `MacolaPartNumber` for any finished good. S-05 stays ⬜ Owed.

---

### S-06 — Flexware BOM Export (OI-13)

**Status:** ⬜ Owed
**Source:** MPP IT export from the live Flexware MES at IP `.919`.
**Target:** `Parts.Bom` + `Parts.BomLine`
**Owner:** MPP IT — for the export tooling and execution.
**Blocking:** No — Bom / BomLine schema and procs are built (Phase 6); empty-table operation is fine for non-BOM-driven flows. BOM-driven flows (Trim 1-line BOM consumption per FDS-05-033, Assembly material verification per FDS-06-011) need this loaded before go-live.

**Two-pull plan (per OI-13):**
1. **NOW** — one-shot pull for dev validation: load into dev DB, verify schema fit, exercise the `Bom_GetActiveForItem` flow on a representative sample. Catches export-format issues before cutover.
2. **At cutover** — fresh pull on cutover day to capture any BOM changes between dev validation and go-live.

**File format owed from MPP IT:** TBD — depends on what Flexware exports. Likely two CSVs (`bom_header.csv` + `bom_line.csv`) or a JSON tree. Format conversation pending.

**Loading procedure:** Bulk-load proc not yet written; written after MPP IT confirms export format.

**Acceptance criteria:**
1. Every Flexware BOM round-trips to `Parts.Bom` + `Parts.BomLine` without error.
2. Sample-part `Bom_GetActiveForItem` returns the expected component list.
3. Versioning: imported BOMs land as `Published` rows (not Draft) — they're already in active use at MPP.

**Coupling:** Requires S-05 (Parts master) to be loaded first — BomLine.ChildItemId FKs into Item.

**Partially satisfied by S-12.** The 2026-06-15 Macola workbook's `SUPPLY PARTS` sheet carries purchased-component-to-finished-good links with a `Pcs per part` quantity — 149 links in all, of which 21 resolve end-to-end against the loaded catalog (8 new lines emitted, 13 already present, 2 quantity conflicts pending MPP arbitration). It covers **purchased components only** — castings and machined sub-assemblies are absent — so it is not a substitute for the Flexware export. S-06 stays ⬜ Owed.

---

### S-07 — Die Rank List

**Status:** ⬜ Owed
**Source:** MPP Quality.
**Target:** `Tools.DieRank` (currently empty seed)
**Owner:** MPP Quality — for the canonical rank list.
**Blocking:** No — `Tools.Tool` rows can be created with `DieRankId = NULL`; rank assignment can be backfilled. Cross-die merges that require rank checks (S-08) are the only flow that needs this loaded.

**Format owed:** Simple list of rank codes + descriptions (e.g., `A`, `B`, `C` with descriptions).

**Loading procedure:** Manual `Tools.DieRank_Create` calls (~10 rows expected).

**Acceptance criteria:**
1. All MPP-defined ranks present as `Tools.DieRank` rows.

---

### S-08 — Die Rank Compatibility Matrix

**Status:** ⬜ Owed — **TRUE BLOCKER** (with supervisor-override workaround)
**Source:** MPP Quality.
**Target:** `Tools.DieRankCompatibility` (currently empty seed)
**Owner:** MPP Quality — owes the full pairwise compatibility matrix.
**Blocking:** **Yes** — `Lots.Lot_Merge` rejects cross-die merges until at least the relevant rank pair exists in the matrix. Supervisor AD elevation (FDS-04-007) provides an override path until populated, so the workaround is real but adds operator friction.

**Format owed:** Pairwise list `(RankA_Code, RankB_Code, CanMix BIT)`. Or symmetric matrix in xlsx.

**Loading procedure:** Manual `Tools.DieRankCompatibility_Create` calls per pair (or a small bulk-load proc if matrix is wide).

**Acceptance criteria:**
1. Every pair MPP Quality identifies as compatible has a row with `CanMix = 1`.
2. Default behavior for unlisted pairs: reject merge (proc enforces this).

**Depends on:** S-07 (DieRank list).

---

### S-09 — Label Type Code Validation

**Status:** ⬜ Owed (validation only — values already seeded by Blue Ridge)
**Source:** Blue Ridge proposed values from Honda shipping conventions: `Primary`, `Container`, `Master`, `Void`. Loaded via Phase 3 migration `0004_phase3_reference_lookups.sql`.
**Target:** `Lots.LabelTypeCode` (4 rows already in dev DB)
**Owner:** MPP Shipping — for confirmation / corrections.
**Blocking:** No — labels print against whatever's seeded; if values change, an update migration is trivial.

**Validation owed from MPP Shipping:**
- Confirm the four seeded values match Honda's terminology and operational vocabulary.
- Flag any additional types (e.g., `Repack`, `Reprint`) that should be seeded.

**Loading procedure:** Already loaded. Updates land as a small versioned migration if values change.

---

### S-13 — Label Template ZPL Bodies

**Status:** 🟡 Received (partial) — the **Primary** LTT layout is captured in `sql/seeds/032_seed_label_templates_mpp.sql`; **Master** and **Void** are still migration `0021` placeholders; **Container** is the real Honda label, owned by migration `0054`.
**Source:** MPP's real LOT Tracking Ticket layouts, hand-loaded into the dev database. The repo's own migration `0021` seeds only a **placeholder** ZPL body per label type.
**Target:** `Lots.LabelTemplate.ZplBody`
**Owner:** MPP — to hand over the remaining production ZPL so it can be version-controlled.
**Blocking:** No for build. **Partly for cutover fidelity** — a fresh `Deploy-Prod.ps1` now reproduces MPP's real Primary LTT (seed `032`) and the real Honda container label (migration `0054`), but still ships `0021`'s placeholder for Master and Void.

**Why this is here.** Verified 2026-08-20: `MPP_MES_Dev` template Id 1 (Primary LTT) carries a real plant layout with `{LocationName}` / `{ItemDescription}` fields that appears in no migration or seed. A fresh deploy produces migration `0021`'s placeholder instead. This is the same class of gap as the `Receiving` location type — real configuration living only in Dev.

**CRT interaction (feature `2026-08-19-crt-part-scoped`, decision D8 — REVISED 2026-08-20).** **The CRT feature no longer touches these templates at all.** A CRT LOT prints its normal LTT ticket **unchanged**, followed by a SEPARATE `CrtBanner` label carrying nothing but a large `CRT`. `Lots.LotLabel_Print` / `_Reprint` append the active `CrtBanner` template body to the rendered ZPL as a second `^XA..^XZ` document; the printer emits one label per document, so one print call yields two physical labels. Migration `0065_crt_banner_label.sql` adds that label type + template and strips the retired `{CrtMark}` token back out of the LTT bodies (superseding migration `0063`, which inserted it).

**What this removes from this item's ledger.** No `{CrtMark}` placement decision is owed for the Master and Void layouts, or for any revised layout MPP supplies later — there is nothing to place. `0063`'s WARNING about templates it could not patch is obsolete: a layout the CRT feature never edits cannot be "skipped".

**The barcode hazard is NOT withdrawn — it just no longer concerns CRT.** Every active LTT template carries **two** `{LotName}` occurrences, and in each one the second sits inside a **barcode** field. Anyone editing these templates for any future reason must anchor on the specific human-readable field, never on the bare token, or the edit lands in the barcode and corrupts the scanned LOT number.

> Note the barcode command differs by template: the Master and Void placeholders use `^BC` (Code 128), but MPP's real Primary layout uses **`^B3`** (Code 39). An earlier check here looked only for `^BC` and wrongly reported the Primary template as barcode-free.

**What is owed:**
- MPP's production ZPL for the **Master** and **Void** LTT layouts — the only two label types still running migration `0021`'s placeholder. Primary is seeded (`032`); Container is the real Honda label and is already migration-backed (`0054`); `CrtBanner` is Blue Ridge's own and is migration-backed (`0065`).
- MPP confirmation of the printed **CRT banner** — the ZPL assumes the ~800-dot (4in @ 203dpi) usable width the legacy `Container Hold` layout already implies. If MPP's LTT stock is narrower, or they want the word placed differently, it is a one-row `Lots.LabelTemplate` change with no proc edit.
- *(No longer owed: a `{CrtMark}` placement decision. The token is withdrawn — see the CRT interaction note above.)*

**Resolved 2026-08-20 (Primary only).** Hunter confirmed the Dev Primary body is the production label, so it is captured in `sql/seeds/032_seed_label_templates_mpp.sql` and a fresh `Deploy-Prod.ps1` reproduces it. The seed is deliberately scoped to Primary: a byte-exact comparison showed the Dev Container body is a verbatim copy of `0054`'s ZPL and the Dev Master/Void bodies are `0021`'s placeholder, so seeding them would only put an unconditional `UPDATE` ahead of the migrations that own them and silently revert any future revision.

**The seeded body is MPP's layout UNMODIFIED.** Seeds run after migrations, so an earlier revision of this seed had to carry the `{CrtMark}` token itself or migration `0063`'s patch would be undone on every deploy. With the token withdrawn (migration `0065`), the seed carries the original Lot line `^A0,64,48^FO100,100^FD{LotName}^FS` and Blue Ridge holds no edit of its own inside MPP's layout — which is the outcome worth preserving here: when MPP hands over a revised Primary, it can be dropped in verbatim. Status stays 🟡 until MPP confirms the printed result.

---

### S-10 — Identifier Sequence Baselines (Cutover Snapshot)

**Status:** ⬜ Owed (cutover-only — not blocking dev)
**Source:** Snapshot of Flexware live counter values for `Lot` (~1,710,932 baseline) and `SerializedItem` (~2,492 baseline) on cutover day.
**Target:** `Lots.IdentifierSequence.LastValue` for the two seeded rows (`Lot` `MESL{0:D7}`, `SerializedItem` `MESI{0:D7}`).
**Owner:** MPP IT — for the snapshot reading.
**Blocking:** No — dev DB seeds with `LastValue = 0`; the cutover migration overwrites with Flexware values to ensure ID continuity.

**Snapshot owed from MPP IT:** Two integer reads from Flexware on cutover day (delivered as a 2-row CSV or just two numbers in an email).

**Loading procedure:** Cutover migration: `UPDATE Lots.IdentifierSequence SET LastValue = @MppLotValue WHERE Code = 'Lot';` + same for SerializedItem.

**Acceptance criteria:**
1. First MES-issued `Lot` LotName = `MESL{Flexware_LastValue + 1:D7}` — no overlap, no gap.
2. Same for SerializedItem.

---

### S-11 — AIM Pool Configuration Tuning

**Status:** 🟡 Received (defaults seeded by Blue Ridge)
**Source:** Defaults shipped with Arc 2 Phase 7 migration: `TargetBufferDepth = 50, TopupThreshold = 30, AlarmWarningDepth = 20, AlarmCriticalDepth = 10`.
**Target:** `Lots.AimPoolConfig` (single-row table; one seeded row)
**Owner:** MPP — for post-deploy tuning based on observed peak container throughput vs AIM responsiveness.
**Blocking:** No.

**Tuning input owed from MPP (post-deploy):**
- Observed peak containers/hour across all dedicated Assembly terminals combined.
- Observed AIM `GetNextNumber` response time (mean + p99).
- Operational tolerance for AIM-outage windows (how long should production survive an AIM outage on the buffer alone).

**Loading procedure:** Configuration Tool exposes `Lots.AimPoolConfig_Update @TargetBufferDepth, @TopupThreshold, @AlarmWarningDepth, @AlarmCriticalDepth` (Admin-elevated per FDS-04-007).

---

### S-12 — Macola Part-Number List

**Status:** 🟡 Received (partial) — transformed, generated, and dry-run verified; not yet applied to Dev.
**Source:** `reference/MPP_Macola_Numbers_2026-06-15.xlsx` — MPP's workbook *"MACOLA NUMBERS FOR INVENTORYupdate 6-15-26.xlsx"*, received 2026-06-15.
**Target:** `Parts.Item.MacolaPartNumber` (column + filtered index `IX_Item_MacolaPartNumber` already exist — migration `0005_item_master_container_config.sql`; no migration needed). Secondary target `Parts.Bom` / `Parts.BomLine`.
**Owner:** MPP IT / Materials — for the finished-good Macola numbers, which this workbook does not contain.
**Blocking:** No — `MacolaPartNumber` is NULLable and nothing in the MES reads it today.

**THE GOVERNING RULE.** A Macola number is only a value from a column literally headed **`MACOLA #`**. Exactly two sheets have one: `ALUMINUM` (C1) and `SUPPLY PARTS` (C1). The eight per-family sheets carry `RAW` / `TUMBLED BLASTED` / `MACHINED` / `FINISHED GOODS` columns holding values like `187-090` / `187-091` / `187-092` / `187-MET` / `186-AEP`. Those are MPP **per-stage inventory codes, not Macola numbers**, and must never be written to `Parts.Item.MacolaPartNumber`.

> ⚠️ **Pre-existing contamination.** Five catalog rows already carry a per-family `FINISHED GOODS` code in `MacolaPartNumber` — `1223A-59B-A000` = `186-AEP`, `1223A-RPY -A000` = `142-AEP`, `1223A-5BA -A000` = `141-HCM`, `1223A-6B2 -A000` = `630-AEP`, `1223A-6MA -J000` = `662-AEP`. They arrived via the `Macola #` column of `reference/MPP_Seed_Layout_Proposal.xlsx` → `sql/scratch/seed_mpp_parts.sql:40`. Under the governing rule these are **not** Macola numbers. The S-12 seed deliberately leaves them alone (it never overwrites a non-blank value); clearing them is a separate decision.

**Workbook structure (10 sheets):**

| Sheet | `MACOLA #`? | Shape |
|---|---|---|
| `ALUMINUM` | ✅ C1 | `Part Description \| Honda Part# \| MACOLA # \| Corresponding FG Assembly(s)`. 4 alloy rows (`ADC12`/`HD2BS`/`HD2G`/`NH41`, Macola 300/301/303/304), blank-line separated. "Honda Part#" holds an **alloy code**, not a Honda part number. |
| `SUPPLY PARTS` | ✅ C1 | Adds `Pcs per part`. Header band **repeats at rows 1, 38, 75, 112**. 62 anchor rows (each carries a `MACOLA #`), 87 blank-first-three-columns continuation rows that forward-fill; 20 continuations carry their own per-FG quantity override. One anchor (row 91, Macola 330) has no Honda part number at all. |
| 8 per-family sheets | ❌ none | `RAW \| TUMBLED BLASTED \| MACHINED \| FINISHED GOODS \| FG DUNNAGE INFO \| PART NAME \| CUSTOMER PART # \| CAST \| TUMB BLAST \| MACH \| FG`. **10 header bands across the 8 sheets** (`59B 6MA CH` r2+r14, `PASS THRU` r1+r19), so they must be parsed block-wise. Used for one purpose only: the `PART NAME` → `CUSTOMER PART #` lookup that turns `SUPPLY PARTS`' free-text FG names into part numbers. |

**Reconciliation outcome (against the 170-item Dev catalog):**

| Measure | Count |
|---|---|
| `MACOLA #` values in the workbook | 66 (ALUMINUM 4 + SUPPLY PARTS 62) |
| Landed on an item | 22 (all catalog components) |
| Held back on scope grounds | 4 (the ALUMINUM alloys — see below) |
| No catalog counterpart | 40 |
| Catalog items left with no Macola number | 143 |
| **Finished goods given a Macola number** | **0 of 38** |
| `SUPPLY PARTS` component→FG links | 149 |
| BOM lines resolved end to end | 21 (8 new, 13 already present) |
| BOM quantity conflicts (not emitted) | 2 |

**⚠️ Open with MPP — finished goods have no Macola number.** The only `MACOLA #` columns sit on raw material and purchased components. Under the governing rule, no finished good receives one. Ask MPP whether FG Macola numbers exist in another export (the Macola item master itself is the obvious candidate), or whether finished goods genuinely have none.

**Other open items for MPP:**
1. 40 `MACOLA #` rows name purchased parts absent from the MES catalog (o-rings, oil seals, thermostats, dowel pins for lines outside MVP scope). Confirm whether these should become `Parts.Item` rows. The seed deliberately creates none — inventing them would mint near-duplicates of existing catalog part numbers.
2. Near-miss part numbers, one side of which is a typo: `11222-64AA-A001` vs catalog `11222-64A-A001`; `90701-5A2A-A000` vs `90701-5A2-A000`; `19300-6C1-A010-M2` vs `19300-6CA-A010-M2`; `92900-06012-1B` vs both `92900-06012-0B` and `92900-06014-1B`.
3. The catalog's `P` prefix on seven 5G0 purchased parts (`P146125GO A000`, `P90002-5GO-A000`, …) has no counterpart in the workbook. Confirm the prefix rule before matching them.
4. Duplicate catalog rows for the same physical part: `90701-5R0-3000` (from `020_seed_items.sql`) and `90701-5RO-3000` (from the catalog seed) differ only by letter-O vs zero. Macola 313 is therefore ambiguous and was **not** assigned.
5. BOM quantity conflicts: `1223A-5BA -A000` ← `96211-09000` and `1223A-6B2 -A000` ← `96211-09000` are qty 2 in the workbook, qty 1 in the loaded catalog.

**Scope exclusion — the ALUMINUM sheet.** The four alloys (`ADC12` / `HD2BS` / `HD2G` / `NH41`, Macola 300 / 301 / 303 / 304) have no counterpart anywhere in the catalog: their Macola numbers can only land if the alloys exist as `Parts.Item` rows of ItemType `RawMaterial`. But **Traceability / Raw Material Tracking is FUTURE** — `MPP_Scope_Matrix.xlsx` row 21, "Not Included", excluded per FRS 3.9.1 — and the FUTURE rule is *schema supports it, but do NOT implement, populate, or test*. So `Parts.ItemType.RawMaterial` stays empty and these four Macola numbers are **not loaded**. Their SQL is emitted **commented out** in the seed, ready to un-comment if raw-material tracking is ever brought forward (the UoM assumption, `LB`, would need MPP confirmation at that point).

**Loading procedure:** Generated, not hand-written. `reference/scripts/build_macola_and_fg_bom_seed.py` reads the workbook plus `reference/MPP_Seed_Layout_Proposal.xlsx` (the catalog baseline — no DB connection needed) and emits `sql/scratch/seed_macola_and_fg_boms.sql` + `sql/scratch/macola_bom_reconciliation.csv`. Re-run it on any workbook revision; never hand-edit the SQL. The seed lives in `sql/scratch/` (not `sql/seeds/`) for the same reason `seed_mpp_parts.sql` does — open customer data questions — and is therefore picked up by neither `Reset-DevDatabase.ps1` nor `Deploy-Prod.ps1`.

**Other sheets:** `SERVICE`, `PASS THRU`, and `NEW MODEL` carry no `MACOLA #` column, so nothing is seeded on their behalf. They are read only as part of the `PART NAME` → `CUSTOMER PART #` lookup table, and no BOM parent in fact resolved through one. (Note for the record: `PASS THRU` is **not** out of scope — Scope Matrix row 3 puts pass-through receiving in MVP and row 20 puts pass-through tracking in MVP with a FUTURE full workflow. The only genuine scope exclusion this workbook hits is Raw Material Tracking, above.)

**Acceptance criteria:**
1. Every `MACOLA #` value in the workbook either lands on a `Parts.Item` row or appears in the reconciliation CSV with a reason.
2. No value from a `RAW` / `TUMBLED BLASTED` / `MACHINED` / `FINISHED GOODS` column ever reaches `Parts.Item.MacolaPartNumber`.
3. No existing non-blank `MacolaPartNumber` is overwritten.
4. Re-running the seed changes nothing (verified: second run inserts/updates 0 rows).
5. MPP answers the finished-good question, at which point this item can move toward ✅ Loaded (Dev).

---

## Adding a New Seeding Item

When a new external-data dependency surfaces:
1. Add a row to the **Summary** table with the next `S-NN` ID.
2. Add a per-item detail section below.
3. If the item is a true blocker (rare), flag it in both the summary table's "Blocking?" column and in CLAUDE.md's "Decision blockers" list.
4. Update the Revision History.

## Marking an Item Loaded

When MPP delivers data and it lands in dev:
1. Update the item's status badge to ✅ Loaded (Dev) in the summary table and the per-item section.
2. Capture the actual row count loaded vs the originally-quoted count.
3. Update the Revision History.

When the item is verified in a cutover-equivalent environment (post-Phase 0 customer validation workshop or equivalent):
1. Update the badge to 🔵 Verified (Cutover).
2. Capture the responsible MPP stakeholder + date of validation.
3. Update the Revision History.
