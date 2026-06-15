# Plant Floor (Arc 2) — Phase 0 Decision Log

**Started:** 2026-06-08
**Purpose:** Running record of Phase 0 (T001–T009) decisions as they are made, so the T009 sign-off (append to OIR + Data Model "Scaling Decisions" section + FDS-11 retention paragraph) is a mechanical roll-up. Track B (architecture, Blue Ridge-owned) decisions are signed off as recorded; Track A (customer-owned) items remain **OWED from MPP** until the customer confirms.

Legend: ✅ Decided · ⏳ Awaiting MPP · 🔓 Open

> **Migration numbering:** `0019` is consumed by `0019_location_coupled_downstream_cell.sql` (Arc-1 follow-on, FDS-06-008). Arc-2 Phase 1 is therefore **`0020_arc2_phase1_shop_floor_foundation.sql`** (matches task-list T010); the rest of Arc-2 shifts to `0021`–`0027`. (The validation report's "Arc-2 starts at 0019" is superseded by this.)

---

## T001 — Architecture Decision Workshop, Track B (OI-35 B2–B8) ✅ Decided 2026-06-08 (Jacques)

Blue Ridge-owned. These bake into migration `0020_arc2_phase1_shop_floor_foundation.sql`.

| OI-35 | Decision | Resolution | In `0020` CREATE? |
|---|---|---|---|
| **B2** | Monthly partitioning + sliding-window on the ~14 high-volume Arc-2 event tables | ✅ **Accepted** — partition function + scheme defined at CREATE | **Yes** |
| **B3** | Columnstore on aged (>90-day) partitions | ✅ **Deferred, design-compatible** — monthly partitioning chosen so columnstore can be added to cold partitions later with zero restructure; NOT built in MVP (revisit when an analytical query on aged data actually hurts) | No (compat only) |
| **B4** | Materialized closure table for `Lots.LotGenealogy` | ✅ **Accepted** — O(1) Honda genealogy vs recursive CTE at year 15 | **Yes** |
| **B5** | Materialize `TotalInProcess` / `InventoryAvailable` onto `Lots.Lot` | ✅ **Accepted** — `Lots.v_LotDerivedQuantities` ships as a diagnostic fallback view alongside (per validation C-8) | **Yes** |
| **B6** | `IdentifierSequence_Next` minting model | ✅ **Row-locked table** (NOT SQL `SEQUENCE`) — gap-free, format-controlled, reseedable, 9,999,999 rollover, MESL/MESI cutover continuity. **⚠️ Cutover seed starts at ~3,000,000 due to integration constraints** (exact per-sequence seed values finalized at T007/OI-31; floor ≈ 3M). | Yes (table) |
| **B7** | Split `Audit.OperationLog` → 7-yr general `OperationLog` + 20-yr `Lots.LotEventLog` | ✅ **Accepted** — bulk ops logging ages out at 7yr; Honda-relevant lot events retain 20yr | **Yes** |
| **B8** | Filtered indexes on hot subsets | ✅ **Accepted — include known ones at CREATE** (active/non-deprecated rows, open holds, in-process lots); add more reactively as query plans emerge | **Yes (known)** |

**Cross-references created by these decisions:**
- B6 ~3M seed → feeds **T007** (identifier-sequence cutover / OI-31 / S-10) and the FDS-16-003 cutover-seed values. The +10K-over-Flexware rule in FDS-16-003 is superseded/constrained by the ~3M integration floor — reconcile at T007.
- B5 → confirms `v_LotDerivedQuantities` is a fallback view, not the primary path (validation C-8).
- B2/B7 → the Phase-1 partition list must NOT include `HoldEvent`/`DowntimeEvent` unless their CREATE is pulled into Phase 1 (validation C-4) — pin at T009.

---

## T002 — Customer Validation Gate, Track A (A1–A9) ✅ Gate cleared for build 2026-06-08 (Jacques) · MPP confirmations owed in parallel

**Key posture decision:** Phase 1 SQL (migration `0020`, T010+) **proceeds on the assumed-defaults below**; hard MPP confirmations are collected in parallel and reconciled before cutover (per the seeding-registry "deployment-time prerequisite" philosophy). **Only S-08 DieRankCompatibility is a true build blocker** (has a supervisor-override workaround). Track A is therefore NOT a hard gate on Phase 1 start.

| A-item | Assumed default (build on this) | Status |
|---|---|---|
| **A1** identifier cutover | Seed **≈3,000,000** (integration constraint); MESL/MESI format continuity; row-locked sequence (B6). Exact per-sequence seeds + rollout shape (Ben) at T007. | ⏳ MPP/Ben confirm at T007 |
| **A2** WorkOrder BIT-flags | Ship documented set (Camera, Scale, GroupTargetWeight+tol+UOM, RecipeNumber, TrayQuantity, ReturnableDunnage, Customer); dead flags don't ship. | ⏳ MPP confirm at T004 |
| **A3** historical migration | CONDITIONAL scope; entity list deferred to MPP. | ⏳ MPP |
| **A4** ShotCount semantics | ✅ **Cumulative counter** (Blue Ridge-locked 2026-06-08). | ✅ Decided |
| **A5** per-Cell DefaultScreen + ConfirmationMethod | Needs per-Cell data from MPP. | ⏳ MPP confirm at T005 |
| **A6** AIM Hold/Update contract | Needs Honda/MPP signature + error-recovery detail. | ⏳ MPP/Honda at T006 |
| **A7** label template scope | 3 Flexware templates + Sort-Cage/Hold/Void TBD; couples S-09. | ⏳ MPP at T006 |
| **A8** OI-32 material allocation | "Close as not-reproduced." | ⏳ Ben |
| **A9** OI-33 AIM empty-pool hard-fail | Hard-fail (production stops until pool refills). | ⏳ MPP Ops/IT |

This table IS the MPP workshop agenda. Build proceeds; each ⏳ row is reconciled as MPP answers (tracked in the child tasks T004–T008).

## T003 — Per-table retention classes (B1) ✅ Blue Ridge proposal locked 2026-06-08 (Jacques) · MPP IT confirms · drives FDS-11 amendment

| Retention | Tables |
|---|---|
| **20-year (Honda traceability)** | `Lots.Lot`, `LotGenealogy`, `LotEventLog` (B7 split), `LotStatusHistory`, `LotMovement`, `ContainerSerial` (+`ContainerSerialHistory`), `ShippingLabel`, `Workorder.ConsumptionEvent`, `Workorder.RejectEvent`, `Quality.QualitySample`, `Quality.QualityResult` |
| **7-year (general operational)** | `Audit.OperationLog` (general, post-B7), `Audit.FailureLog`, `Audit.InterfaceLog`, `Audit.ConfigLog`, `Oee.DowntimeEvent`, `Workorder.ProductionEvent`, `Workorder.ProductionEventValue`, `Quality.QualityAttachment` |

Rationale notes: ConsumptionEvent/RejectEvent kept 20yr (consumption = genealogy, reject = part quality history). ProductionEvent/Value at 7yr (highest-volume; durable record lives in LotEventLog/Genealogy; ShotCount is a cumulative die counter). Inspection results 20yr / file attachments 7yr (storage control). This is the **Blue Ridge proposal** — MPP IT negotiates; outcome becomes the FDS-11 retention paragraph at T009. The partition retention windows in `0020` (B2 sliding-window) are set from this table.

## T004 — WorkOrder BIT-flag enumeration (A2) ✅ Adopt-default 2026-06-08 · MPP confirms
Schema builds with the documented flag set (IsCameraProcessingEnabled, IsScaleProcessingEnabled, GroupTargetWeight+tol+UOM, RecipeNumber, TrayQuantity, ReturnableDunnageCode, Customer). MPP confirms which are live; dead flags are dropped from the WorkOrder CREATE before cutover (extra columns are harmless if unused). Buildable now.

## T005 — Workstation DefaultScreen + ConfirmationMethod seeding (A5) ✅ Adopt-default 2026-06-08 · MPP seed owed
Schema: build the per-Workstation `DefaultScreen` (Perspective view path) + `ConfirmationMethod` (Vision/Barcode/Both) columns. **Per-Cell seed VALUES are owed from MPP** (deployment-time seed, not a schema blocker). Drives B11 routing + FDS-10-013.

## T006 — Label template scope (A7/S-09) + AIM Hold/Update contract (A6) ✅ Adopt-default 2026-06-08 · MPP confirms
Build the 3 Flexware templates (CONTAINER / LOT / CONTAINER_HOLD); Sort-Cage/Hold/Void additions TBD with MPP (couples S-09). AIM `PlaceOnHold`/`ReleaseFromHold`/`UpdateAim` proc signatures built against the documented contract; MPP/Honda confirm exact payloads + error-recovery before the AIM integration is exercised.

## T007 — Identifier-sequence cutover + format/reset/rollover (A1/OI-31/S-10) ✅ Format/mechanism locked 2026-06-08 (Jacques) · exact seeds + rollout owed (Ben)
- **Keep MESL/MESI prefix continuity** (NOT mint-new) — operator + Honda format continuity.
- Row-locked `IdentifierSequence_Next` (B6); **start seed ≈ 3,000,000** (integration constraint).
- 9,999,999 rollover policy; no mid-life reset.
- ⏳ Owed: exact per-sequence cutover seed values + rollout shape (single-line / full-cutover / shadow) from **Ben**. Wrong seed → LTT collisions, so this is a cutover-gate (not a build-gate). Reconciles FDS-16-003's +10K-over-Flexware rule against the ~3M floor.

## T008 — UJ-03 sub-LOT split default + UJ-05 serial migration ✅ Decided 2026-06-08 (Jacques) · UJ-05 awaits MPP Quality+Honda affirmation
- **UJ-03:** **NO auto-split default — operator enters all split quantities manually.** ⚠️ This DROPS the prior FDS assumption of an auto-prompt 50/50 even split — flag for FDS/UJ reconciliation at T009 (remove the even-split-default language).
- **UJ-05:** **Update-in-place + `ContainerSerialHistory`** (B10 serial-migration convention). Buildable now; awaits MPP Quality + Honda affirmation before cutover.

## T009 — Phase 0 sign-off GATE ✅ DONE 2026-06-09 — Blocks 1–5 applied to canonical docs; Phase 0 signed off; T010 unblocked

> **Applied 2026-06-09:** Block 1 → Data Model § "Scaling Decisions" (rev 1.9s); Block 2 → FDS-11-009 retention table (FDS rev 1.3a); Block 3 → Plant Floor plan Cross-Cutting **B10** refined; Block 4 → OIR OI-35 **RESOLVED** + UJ-03 changed (T008) + UJ-05 default locked + counts/version (OIR v2.18); Block 5 → Plant Floor plan validation Section 5 resolution banner (C-4/C-5 pinned). Phase 0 (T001–T009) complete. **Arc-2 Phase-1 SQL (migration `0020`) is unblocked** — design spec `docs/superpowers/specs/2026-06-09-arc2-phase1-sql-foundation-design.md`, plan `docs/superpowers/plans/2026-06-09-arc2-phase1-sql-foundation.md`.

Phase 0 decisions (T001–T008) are complete. The blocks below are **insert-ready** — paste into the named canonical doc (DM / FDS / OIR) at your next edit pass; they were staged here (not applied in place) to avoid colliding with the uncommitted parallel edits in those files. Once pasted, Phase 0 is signed off and **Arc-2 Phase 1 (T010+) is unblocked**.

---
### Block 1 → `MPP_MES_DATA_MODEL.md` — NEW section "Scaling Decisions (OI-35)"

> ## Scaling Decisions (OI-35) — signed off 2026-06-08
>
> Normative for all Arc-2 event-table DDL; governs `0020_arc2_phase1_shop_floor_foundation.sql`.
>
> - **B2 Partitioning:** ~14 high-volume Arc-2 event tables use **monthly RANGE partitioning** + sliding-window retention. Partition function + scheme created in `0020` (cannot retrofit to populated tables).
> - **B3 Columnstore:** **Deferred, partition-compatible** — columnstore may be added to aged (>90-day) partitions later with no restructure; not built in MVP.
> - **B4 Genealogy closure:** `Lots.LotGenealogy` materialized as a **closure table** (ancestor/descendant/depth) maintained by genealogy procs — O(1) Honda trace. Created in `0020`.
> - **B5 Materialized quantities:** `Lots.Lot` carries materialized `TotalInProcess` + `InventoryAvailable` (proc-maintained); `Lots.v_LotDerivedQuantities` ships as a **diagnostic fallback view** only.
> - **B6 Identifier sequence:** `Lots.IdentifierSequence_Next` is a **row-locked table** (not SQL `SEQUENCE`) — gap-free, format-controlled, reseedable, 9,999,999 rollover. **Cutover seed ≥ ~3,000,000** (integration constraint); **MESL/MESI** format retained; exact per-sequence seeds set at cutover.
> - **B7 OperationLog split:** `Audit.OperationLog` → 7-yr general `OperationLog` + 20-yr `Lots.LotEventLog` (both created in `0020`; lot-relevant events route to `LotEventLog`).
> - **B8 Filtered indexes:** known hot-subset filtered indexes (active/non-deprecated, open holds, in-process lots) created in `0020`; others added reactively.
> - **B1 Retention:** per the FDS-11 table (Block 2).

---
### Block 2 → `MPP_MES_FDS.md` §11 — retention paragraph

> **Retention.** Honda full-genealogy data is retained **20 years**; general operational/audit data **7 years**, enforced via the monthly sliding-window partition process (OI-35 B2). **20-yr:** `Lots.Lot`, `LotGenealogy`, `LotEventLog`, `LotStatusHistory`, `LotMovement`, `ContainerSerial` (+`ContainerSerialHistory`), `ShippingLabel`, `Workorder.ConsumptionEvent`, `Workorder.RejectEvent`, `Quality.QualitySample`, `Quality.QualityResult`. **7-yr:** `Audit.OperationLog` (general), `FailureLog`, `InterfaceLog`, `ConfigLog`, `Oee.DowntimeEvent`, `Workorder.ProductionEvent`, `ProductionEventValue`, `Quality.QualityAttachment`. Final per-table windows subject to MPP IT confirmation (B1).

---
### Block 3 → FDS / Cross-Cutting — B10 serial-migration convention

> **B10 — Serial migration (Sort Cage, UJ-05).** Re-serialization **updates the container serial in place** and records prior serial(s) in `Lots.ContainerSerialHistory` (one row per superseded serial: timestamp + reason + actor). No new container row is minted. Awaiting MPP Quality + Honda affirmation before cutover; buildable now.

---
### Block 4 → `MPP_MES_Open_Issues_Register.md` — closures

> **OI-35 — Long-horizon scaling/retention/archiving — ✅ RESOLVED 2026-06-08 (Blue Ridge architecture review).** Track B: B2 monthly partitioning + sliding window (CREATE); B3 columnstore deferred (compat); B4 LotGenealogy closure table (CREATE); B5 materialized `TotalInProcess`/`InventoryAvailable` + fallback view (CREATE); B6 row-locked `IdentifierSequence_Next`, seed ~3M, MESL/MESI; B7 OperationLog→7yr + `LotEventLog` 20yr (CREATE); B8 known filtered indexes (CREATE); B1 retention per FDS-11. **Architecture gate CLEARED — Arc-2 Phase-1 SQL unblocked.**
>
> **Track A (customer validation):** gate posture = build on assumed-defaults, MPP confirms in parallel; only S-08 a true blocker. A4 ShotCount = **cumulative** (locked). A1 seed ~3M / keep MESL/MESI (Ben → exact seeds + rollout shape). A2/A5/A6/A7 adopt-default, MPP confirms. A8 (OI-32) close-as-not-reproduced (Ben). A9 (OI-33) hard-fail posture confirmed.
>
> **UJ-03 — ⚠️ CHANGED:** sub-LOT split has **NO auto even-split default**; operator enters all split quantities. Remove the 50/50 even-split-default language from UJ-03 and any FDS reference (e.g. §5/§6 sub-LOT split prose).
> **UJ-05:** update-in-place + `ContainerSerialHistory` (B10).

---
### Block 5 → Plant Floor plan / validation — pin C-4/C-5 partition + CREATE ownership

> **C-4/C-5 (validation report):** `HoldEvent` CREATE = **Phase 7**; `DowntimeEvent` CREATE = **Phase 8**; `ShippingLabel` CREATE = **Phase 6**. **Remove `HoldEvent`/`DowntimeEvent` from the Phase-1 (`0020`) partition list** — each is partitioned in its owning phase's migration.

---
**After pasting Blocks 1–5:** mark T009 Done; Phase 0 signed off; T010 (migration `0020`) is unblocked.
