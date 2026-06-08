# Plant Floor (Arc 2) Phased Plan — Validation Report

**Date:** 2026-06-08
**Author:** Blue Ridge Automation (validation pass)
**Subject doc:** `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` v1.1 (2026-06-03)
**Validated against:** FDS (current, body rev v1.3), Data Model v1.9o, actual shipped migrations on disk (`sql/migrations/versioned/0001`–`0018`)
**OI-35 posture:** Phase 0 default decisions assumed accepted (closure table B4, monthly partitioning B2, materialized `TotalInProcess`/`InventoryAvailable` B5, `OperationLog` split B7, row-locked `IdentifierSequence_Next` B6). Findings flag where a different OI-35 choice changes the work but do not block on it.

---

## How this was validated

Three independent full-document inventories (Plant Floor plan, FDS plant-floor requirements, Data Model Arc-2 tables) were cross-walked three ways, then **every load-bearing claim was checked against the actual migrations on disk** rather than against the plan's own assertions. The disk check is what surfaced the two blocking findings — the plan's internal claims about what Arc 1 already built are wrong.

**Verdict:** The plan is **structurally sound and ~90% complete** — all 9 phases are fully fleshed out (the "Phases 5–8 are placeholders" note is stale), proc/view/gateway-script inventories are thorough, and the workflow sequencing matches the FDS. But it carries **2 blocking defects** that will break the Phase 1 migration on first run, **3 MVP coverage gaps** with no phase home, and a cluster of internal-consistency drift items. None require re-architecting — they are corrections, additions, and renumbering.

---

## Section 1 — BLOCKING (must fix before any Arc 2 SQL is written)

### B-1 · Migration numbering is entirely consumed — Arc 2 must start at `0019`, not `0014`

The plan assigns `0014`–`0021` to Phases 1–8 and asserts (line 28) that "Arc 1 delivered … 13 versioned migrations (`0001`–`0013`)." **That is false.** Arc 1 actually shipped through **`0018`**:

```
0014_locationattributedefinition_unique_active_name.sql
0015_audit_add_event_type_deleted.sql
0016_parts_bom_unique_draft.sql
0017_qualityspec_attribute_uom_fk.sql
0018_tooltype_compatible_celldef.sql   ← consumed by the Arc-1 Mount-to-Cell work (2026-06-05)
```

Every Arc-2 migration number in the plan collides with an already-applied Arc-1 migration. **Corrected mapping:**

| Phase | Plan says | **Corrected** | Migration name (rename) |
|---|---|---|---|
| 1 | 0014 | **0019** | `0019_arc2_phase1_shop_floor_foundation.sql` |
| 2 | 0015 | **0020** | `0020_arc2_phase2_lot_lifecycle.sql` |
| 3 | 0016 | **0021** | `0021_arc2_phase3_die_cast.sql` |
| 4 | 0017 | **0022** | `0022_arc2_phase4_movement_trim_receiving.sql` |
| 5 | 0018 | **0023** | `0023_arc2_phase5_machining.sql` |
| 6 | 0019 | **0024** | `0024_arc2_phase6_assembly.sql` |
| 7 | 0020 | **0025** | `0025_arc2_phase7_hold_sort_shipping_aim.sql` |
| 8 | 0021 | **0026** | `0026_arc2_phase8_downtime_shift.sql` |

This also resolves the Data Model's acknowledged `0018` collision (DM line 13): the `Parts.OperationTemplate.RequiresSubLotSplit` ALTER that older text pins to `0018` is part of Phase 5 and now lands in **`0023`**.

**Also fix the test-suite namespace.** The plan numbers Arc-2 test suites `0014_PlantFloor_Foundation/`…`0021_…`, but Arc-1 test suites already occupy `0001`–`0019` (per plan line 638's own parenthetical). Renumber Arc-2 test suites to start after the last Arc-1 suite (verify the actual `sql/tests/` high-water mark — likely `0020+`).

### B-2 · `Lots.Lot` and five core lifecycle tables are never CREATEd — the plan assumes Arc 1 built them, but it didn't

This is the most consequential finding. **`Lots.Lot` does not exist.** No `CREATE TABLE Lots.Lot` appears in any shipped migration — Arc 1's `0004` created only the Lots *code/lookup* tables (`LotOriginType`, `LotStatusCode`, `ContainerStatusCode`, `GenealogyRelationshipType`, `PrintReasonCode`, `LabelTypeCode`). Yet the plan's Phase 1 (line 415) says:

> **ALTERs (Arc 2 Phase 1):** `Lots.Lot` ADD `ToolId`, `ToolCavityId` …

You cannot `ALTER` a table that was never created. Phase 1's migration will fail on this statement. The same omission hits the entire core LOT event set — the plan's Phase 1 "New tables" list (lines 395–403) and Phase 2's (which lists only `PauseEvent`) **never CREATE**:

| Table | Written by (proc) | Plan's CREATE home | Reality |
|---|---|---|---|
| `Lots.Lot` | `Lot_Create` (P1) | "ALTER" (P1) ❌ | **does not exist — must CREATE** |
| `Lots.LotGenealogy` | `Lot_Split`/`Lot_Merge`/`RecordConsumption` (P2) | none | **does not exist — must CREATE** |
| `Lots.LotStatusHistory` | `Lot_UpdateStatus` (P1/P2) | none | **does not exist — must CREATE** |
| `Lots.LotMovement` | `Lot_MoveTo` (P1) | none | **does not exist — must CREATE** |
| `Lots.LotAttributeChange` | `Lot_UpdateAttribute` (P2) | none | **does not exist — must CREATE** |
| `Lots.LotLabel` | `LotLabel_Print` (P2) | none | **does not exist — must CREATE** |

**Fix:** Phase 1's migration must **CREATE `Lots.Lot`** (with `ToolId`/`ToolCavityId` columns built in from the start — not as an ALTER) plus `LotStatusHistory` and `LotMovement` (used by Phase 1 procs). Phase 2's migration must **CREATE `LotGenealogy`, `LotAttributeChange`, `LotLabel`** (used by Phase 2 procs). The Data Model already specifies all six fully (DM §3, lines 505–654) and correctly tags them "CREATE deferred to Arc 2 Phase 1/2" — it is only the **plan** that mis-describes them as pre-existing. The OI-35 partitioning/closure/materialized-column decisions (B-2/B-4/B-5) attach to these CREATEs, reinforcing that they must be genuine CREATEs in Phase 1, not ALTERs.

---

## Section 2 — MVP COVERAGE GAPS (FDS requirements with no phase home)

### G-1 · Inspection recording (FDS-08-011, -012, -013) — entirely unbuilt

`Quality.QualitySample`, `Quality.QualityResult`, and `Quality.QualityAttachment` are MVP, runtime-captured (operator/inspector enters inspection results against a published spec), and confirmed **absent from every shipped migration**. The plan mentions none of them — no table CREATE, no proc, no view. FDS-08-011 (sample + per-attribute result + overall pass/fail + log), -012 (failed-inspection alert, no auto-hold), and -013 (file attachments) have no owner.

**Recommendation:** Add an inspection-recording slice to **Phase 7** (it already owns Quality/Hold) or stand up a small dedicated phase. Tables: `QualitySample`, `QualityResult`, `QualityAttachment`. Procs: `QualitySample_Record`, `QualitySample_GetByLot`, attachment metadata writer. One operator view (Inspection Entry) + one read view. ~8–12 tasks.

### G-2 · Controlled Run Tag (FDS-10-011, -10-012) — missing from plan AND schema

The CRT workflow is MVP: a LOT flagged `Lot.CrtActive` triggers 200%-inspection on downstream operations, with a `MissedCrtInspect` re-run rule and dedicated audit event types; release path is Quality-release OR Controlled-Run-Tag with supervisor AD elevation. **`CrtActive` does not exist on `Lots.Lot` in the Data Model** (grep: zero hits for `CrtActive`/`Controlled Run`/`CRT` in DM), and the plan never mentions it.

**Recommendation:** This needs a **Data Model bump first** (`Lot.CrtActive BIT`, possibly a `CrtInspection` tracking shape, + `LogEventType` rows), then a plan slice. Schema hook belongs in Phase 1's `Lots.Lot` CREATE; the workflow (downstream 200% inspect prompt, missed-inspect re-run) belongs in Phase 6 (assembly/inspection) and Phase 7 (hold/release). Flag to Jacques: confirm CRT is in-scope for MVP before sizing — it spans several phases. ~6–10 tasks if confirmed.

### G-3 · Reporting suite incl. Global Trace Tool (FDS-12-001..015) — deferred to an unscoped workstream

The plan (lines 1783–1784, 1812) **explicitly punts** all reporting to a "separate Reporting workstream … Ignition Reporting module," coupled to open item **UJ-19**. But FDS-12 tags **15 reporting requirements MVP**, including the **Global Trace Tool** (FDS-12-012/013/014 — "Track home tile, any context, read-only," the primary Honda traceability surface) and the **LOT Genealogy Report** (FDS-12-001 — *the* Honda deliverable). Phase 2 delivers the interactive screens (LOT Detail, LOT Search, Genealogy Viewer) but none of the **reports** (Die Shot, Rejects, Downtime, Production, Shipping history) or the Global Trace Tool.

This is a **scope decision, not a bug** — but it is a large MVP surface sitting outside the 9 phases with no estimate. **Recommendation:** either (a) add a Phase 9 (Reporting + Global Trace) once UJ-19 names the four PD reports, or (b) formally re-tag the report subset as post-MVP in the Scope Matrix with MPP sign-off. The Global Trace Tool specifically should NOT wait on UJ-19 (it reads existing event tables) — pull it forward into Phase 7 or a dedicated slice. Flag to Jacques.

> **Correctly deferred (no action):** `Oee.OeeSnapshot` and `Quality.NonConformance` are FUTURE per Scope Matrix; the plan defers them appropriately (line 1783).

---

## Section 3 — INTERNAL-CONSISTENCY DEFECTS (plan self-contradictions / drift)

| # | Defect | Location | Fix |
|---|---|---|---|
| C-1 | **Stale "Phases 5–8 are placeholders awaiting review" note** — all four are fully fleshed out (equal depth to 0–4; closing sections present). | line 11 | Delete the v1.0a in-progress note. |
| C-2 | **Phase 4 dependency contradiction** — Phase Map table lists Phase 4 deps as "1,2,3"; Phase 4 prose says it "no longer depends on Phase 2" (Trim OUT moves whole, no split). | table line 261 vs prose line 997 | Correct the table: Phase 4 deps = **1, 3**. |
| C-3 | **Phase 6↔7 cross-dependency missing from table** — Phase 6 calls `AimShipperIdPool_Claim`, which lives in Phase 7's migration; the dependency table's Phase 6 row omits Phase 7. | table line 263 vs prose lines 1286–1288 | Add the sequencing note to the table, or split `AimShipperIdPool*` schema CREATE into Phase 6's migration. |
| C-4 | **`DowntimeEvent` / `HoldEvent` CREATE-phase ambiguity** — Phase 1 partitions them (assumes they exist); Phase 7/8 say "CREATE … if not already in Phase 1." Neither table exists today, so ownership must be pinned. | lines 407, 1465, 1659 | Decide explicitly: CREATE `HoldEvent` in Phase 7, `DowntimeEvent` in Phase 8; remove them from Phase 1's partition list **or** move their CREATE to Phase 1. (Recommend: CREATE in owning phase; partition there.) |
| C-5 | **`Lots.ShippingLabel` CREATE phase never stated** — Phase 6's `Container_Complete` inserts it; Phase 7 reads it as "(Phase 6)"; but Phase 6's "New tables" list omits it. | lines 1296–1299, 1362, 1477 | Add `ShippingLabel` to Phase 6's CREATE list (or Phase 7, before its first writer — confirm order). |
| C-6 | **Phase 7 "all five Gateway scripts" miscount** — parenthetical lists six (Topup, AlarmMonitor, AimHoldHandler, AimUpdateHandler, PrintFailureSafetySweep, PrintFailureBroadcaster). | line 1639 | "six." |
| C-7 | **Doc-version drift** — header cites FDS v0.11m / DM v1.9l; body's v1.1 revision mirrors FDS v1.3; current DM is v1.9o. PROJECT_STATUS lists FDS as v1.0 while the FDS body has advanced to v1.3 — the status table is itself stale. | plan lines 7, 19; DM v1.9o | Re-stamp the plan header to FDS v1.3 / DM v1.9o; reconcile PROJECT_STATUS's FDS version. |
| C-8 | **Two Arc-2 VIEWs easy to miss** — `Parts.v_EffectiveItemLocation` (DM line 270, "Arc 2 Phase 1") and `Lots.v_LotDerivedQuantities` (DM line 478, "Arc 2 Phase 2"). The latter is conditional on **not** electing OI-35 B5; under the assumed defaults (B5 elected → materialized columns) it ships as a diagnostic fallback only. | DM 270, 478 | Add `v_EffectiveItemLocation` CREATE to Phase 1, `v_LotDerivedQuantities` to Phase 2 (as fallback view alongside the materialized columns). |
| C-9 | **`ContainerSerial.HardwareInterlockBypassed` is prose-only** in the Data Model (described line 716, absent from the column table 704–714). A literal build off the column table would miss it. | DM 716 | Ensure Phase 6 `ContainerSerial` CREATE includes `HardwareInterlockBypassed BIT NOT NULL DEFAULT 0`; fold the column into the DM table at next bump. |

---

## Section 4 — FDS → Phase coverage matrix (MVP plant-floor)

✅ covered · ⚠️ gap/decision · — n/a

| FDS topic (reqs) | Phase | Status |
|---|---|---|
| Operator session / terminal routing / initials / elevation (FDS-02-008..013, 04-001..010) | 1 | ✅ |
| Identifier sequence (FDS-16-001..003) | 1 | ✅ |
| LOT core / status / genealogy / pause (FDS-05-001..038, 05-013..021) | 1 + 2 | ✅ (after B-2 CREATE fix) |
| Die Cast (FDS-05-004, 06-001..003) | 3 | ✅ |
| Move / Trim (FDS-05-007/008, 06-004..006) | 4 | ✅ |
| Machining / FIFO / sub-LOT split / rename (FDS-05-009..011/022/024/029/033, 06-007..009) | 5 | ✅ |
| Assembly / MIP / part-identity (FDS-06-010..013, 10-001..005/009/010/013) | 6 | ✅ |
| Container / tray closure / packing (FDS-03-017..021, 06-014, 07-001..005) | 6 | ✅ |
| Reject / scrap (FDS-06-017..019/023a) | 3/5/6 | ✅ |
| Work orders / auto-finish (FDS-06-022..030) | 1 + 6 | ✅ |
| Hold / NCM-less holds / bulk hold (FDS-08-001..007a) | 7 | ✅ |
| Sort cage / serial migration (FDS-07-017..019) | 7 | ✅ |
| Shipping / AIM / labels / pool (FDS-07-006..016, 13-001..003, 10-008) | 6 + 7 | ✅ |
| Downtime (FDS-09-001..005) | 8 | ✅ |
| Shift / end-of-shift time entry (FDS-09-009..015) | 1 + 8 | ✅ |
| Audit / retention (FDS-11) | 1 + cross-cutting | ✅ |
| **Inspection recording (FDS-08-011..013)** | — | ⚠️ **G-1 gap** |
| **Controlled Run Tag (FDS-10-011/012)** | — | ⚠️ **G-2 gap (schema + plan)** |
| **Reporting + Global Trace Tool (FDS-12-001..015)** | "workstream" | ⚠️ **G-3 deferred (MVP tension)** |

---

## Section 5 — Recommended actions, in order

1. **Renumber** all Arc-2 migrations `0014→0019` … `0021→0026` and test suites; fix plan line 28 ("0001–0018"). *(B-1)*
2. **Convert** Phase 1's `Lots.Lot` ALTER into a full CREATE (Tool/Cavity columns inline); add `LotStatusHistory` + `LotMovement` CREATEs to Phase 1 and `LotGenealogy` + `LotAttributeChange` + `LotLabel` to Phase 2. *(B-2)*
3. **Pin** `HoldEvent` (Phase 7), `DowntimeEvent` (Phase 8), `ShippingLabel` (Phase 6) CREATE ownership; remove them from Phase 1's partition list or move CREATE forward. *(C-4, C-5)*
4. **Decide scope** on G-1 (inspection), G-2 (CRT — needs DM bump), G-3 (reporting/Global Trace) — these are the three items that need a Jacques/MPP call before they can be sized confidently. The task list below includes G-1 and the Global Trace slice of G-3 as concrete tasks (recommended in-scope); G-2 is listed as a gated stub pending the schema decision.
5. **Sweep** the consistency defects C-1/2/3/6/7/8/9 at the next plan bump (mechanical edits).
6. Adopt OI-35 defaults into the Phase 1 migration content (closure table, partitioning, materialized columns, `OperationLog` split) per the assumed posture.

---

## Section 6 — What's solid (no action)

- All 9 phases are fully specified; proc/view/gateway-script/test inventories are complete and internally coherent.
- Workflow sequencing matches the FDS post-relocation (sub-LOT split at Machining OUT, Trim whole-LOT 1:1, Trim→Machining rename at Machining IN).
- Cross-Cutting Concerns B1–B17 are normative and well-formed; the Gateway-script-async + audit-bracketing contract is sound.
- Seeding Registry phase-coupling (S-01..S-11) is correctly mapped; only S-08 is a true (override-able) blocker.
- The B13 (Tool/Cavity system-of-record on `Lot`, never duplicated on events) and B14 (checkpoint-shape `ProductionEvent`) decisions are consistent with the Data Model.

---

*Companion artifact: `MPP_MES_TASK_LIST_PLANT_FLOOR.csv` — fine-grained task breakdown built on the corrected plan (migrations `0019`–`0026`, B-2 CREATEs folded in, G-1 + Global Trace included, G-2 stubbed pending schema decision).*
