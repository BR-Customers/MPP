# FDS Congruity Review — 2026-06-25

Audit of the **built application** (SQL procs, Ignition views/entities, seeds, schema) against `MPP_MES_FDS.md`. Focus: the MVP plant-floor execution core (§5–8) + cross-cutting conventions, where the recent Arc 2 Phase 5–7 work concentrated. Sections not deeply line-audited are listed in §E for a follow-up pass.

> **Update 2026-06-25:** **A1 and A2 are FIXED** (verified against a clean reset, suite green 1848/1848). A1 — migration `0030_holdtype_taxonomy_fds0801` re-codes the hold types to Quality / CustomerComplaint / Precautionary. A2 — `020_seed_items` promotes `5G0-MACH` to a master item (ItemType 3) with a rename BOM, and the assembly BOM now consumes it (`5G0 ← 5G0-MACH + PNA`). A3, A4, A5, the §B/§D items, and the §E follow-up remain open.

## A. Confirmed incongruities

| # | Area | FDS | Built | Severity | Note |
|---|---|---|---|---|---|
| A1 | **Hold type taxonomy** | FDS-08-001: hold types SHALL include **QUALITY, CUSTOMER_COMPLAINT, PRECAUTIONARY** | `Quality.HoldTypeCode` seed = **QualityHold, EngineeringHold, CustomerHold** | Low–Med | `EngineeringHold` is not in the FDS; `PRECAUTIONARY` is missing; `CUSTOMER_COMPLAINT` is only loosely `CustomerHold`. Code-table seed deviation — affects hold reporting / any Honda-facing hold classification. |
| A2 | **Assembly BOM stage** | §1.5 / FDS-05-033 chain: cast → trim → **machine → assemble**; assembly consumes the **machined** item | Published BOM `5G0 ← 5G0-C (casting) ×1 + PNA ×2` (master seed `020_seed_items`) | Med | The finished-good assembly BOM consumes the **casting** (`5G0-C`), not the **machined** part (`5G0-MACH`). We corrected the machining-rename BOM (`5G0-MACH ← 5G0-C`) but not this assembly BOM, so the modeled chain is internally inconsistent (assembly would consume a stage that machining already renamed away). Representative seed data — real BOMs come from MPP, but the stage is wrong as shipped. |
| A3 | **Hold Management screen — bulk / filter / nav / elevation** | FDS-08-006 (bulk hold by search), FDS-08-007a (filter by Area/Line/Cell/Part/Type/Placed-By; row → Lot Details; **Place/Release require FDS-04-007 AD elevation**) | Place / Release / open-holds lists work (just completed). **Filter row is unbound; Place is single-LOT/container (no bulk/multi-select); no row→Lot Details nav; Place/Release call the entity directly with no AD-elevation gate.** | Med | Core CRUD works; the MVP-EXPANDED affordances (bulk, search/filter, nav, per-action elevation) are not wired. `ElevationModal` exists + is referenced by the view, so the mechanism is available but not gating place/release. |
| A4 | **Inspection recording** | §8.3 (MVP) FDS-08-011..013: `QualitySample` + `QualityResult` recording, dynamic inspection screen, attachments | Quality **spec management** (Config Tool: `QualitySpec`/`QualitySpecVersion`/`QualitySpecAttribute`) is built; **`QualitySample` and `QualityResult` tables do not exist**; no inspection screen | Med–High | The operator inspection-recording half of MVP §8.3 is not built. Likely a not-yet-reached Arc 2 phase rather than a regression — flagging as an open MVP gap. (Sampling §8.4 is CONDITIONAL, separate.) |
| A5 | **Work Order auto-gen** | FDS-06-022 (MVP-LITE): auto-generate an invisible **Production** WO when production begins on a LOT | `Workorder.WorkOrder` has **0 rows** after die-cast/machining LOT creation; no auto-gen in `Lot_Create` or the production procs | Low | Event tables carry **nullable** `WorkOrderOperationId`, so production functions fully without WOs (by design). But FDS-06-022's auto-gen isn't implemented — every `ProductionEvent`/`ConsumptionEvent` has `WorkOrderOperationId = NULL`. |

## B. Known / already-tracked

| # | Area | Status |
|---|---|---|
| B1 | **Displayed timestamps not all ET** (§1.7 / convention: all displayed = Eastern) | Many read procs return raw UTC `*At` columns (`Lot_Get`, `Oee.Shift_GetActive`, …; no `AT TIME ZONE` cast). **Tracked as OI-36** ("refactor sweep of remaining UTC-displaying reads") in CLAUDE.md. Not a new finding. |
| B2 | **Coupled / PLC auto-move assembly path** (FDS-06-008) | Operator scan-in path built (Assembly IN); the coupled `CoupledDownstreamCellLocationId` auto-move is **deferred pending Jacques** (decided this session). |

## C. Verified-compliant (spot-checks that passed)

- **FDS-11-011 (no proc OUTPUT params):** the `OUTPUT` hits in `*_Deprecate` procs are `sp_executesql` internals (`@cnt INT OUTPUT` inside dynamic SQL), not stored-proc OUTPUT params. Compliant.
- **FDS-08-002 (held LOT blocks production):** the production procs (`MachiningIn_PickAndConsume`, `MachiningOut_*`, `TrimOut_Record`, `ProductionEvent_Record`, `RejectEvent_Record`, `Assembly_ScanIn`) check `Lot_AssertNotBlocked` / `BlocksProduction`.
- **FDS-07-006a/b, FDS-07-010 (AIM topup + print dispatch/sweep):** `BlueRidge.Lots.AimPoolGateway` + `PrintFailureGateway` Gateway scripts exist (scaffolded; AIM `GetNextNumber` and Zebra send are integration stubs in dev).
- **FDS-04-007 (elevation mechanism):** `BlueRidge/Components/PlantFloor/ElevationModal` + `Location.AppUser_AuthenticateAd` exist (mechanism present; see A3 for where it's not yet wired).
- **§7.3–7.7 shipping / AIM / sort cage:** `ShippingLabel_Void`/`_Reprint`, `Container_Ship`, `AimShipperIdPool_Claim`/`_Topup`/`_GetDepth`, `AimPoolConfig`, `SortCage_MigrateSerial` + `ContainerSerialHistory` all present.
- **Per-tray assembly consumption (FDS-06-013/014):** `ContainerTray_Close` emits per-component `ConsumptionEvent` into the container (built this session; suite green 1848/1848).

## D. Needs verification (flagged, not conclusively determined)

- **Defect-code reject entry on production screens** (FDS-06-001 reject entry filtered to area / FDS-08-017): `DieCastEntry` has no `DefectCode` reference — reject-by-defect-code entry may not be surfaced on the production screens. Worth confirming against each production screen.
- **A3 elevation:** confirm whether any place/release path routes through `ElevationModal` (the view references it once) vs the direct entity call seen in the button scripts.

## E. Not deeply audited this pass (recommended follow-up)

§1 Architecture, §2 Plant Model, §3 Master Data, §4 Identity/Elevation (depth), §9 Downtime/OEE, §10 PLC Integration (mostly integration/FUTURE), §11 Logging/Retention, §12–16. The proc inventory shows coverage (Location 44, Parts 77, Oee 27, Tools 48, etc.), so these appear built; a line-by-line requirement crosswalk was out of scope for this pass.

## Recommended next actions (for discussion — no changes made)
1. **A1** — reconcile `HoldTypeCode` seed with FDS-08-001 (decide the canonical taxonomy with MPP/Quality).
2. **A2** — correct the assembly BOM to consume the machined item (or confirm the real MPP BOM), so the cast→machine→assemble chain is consistent end to end.
3. **A3** — decide scope for Hold screen bulk/filter/nav + whether place/release must elevate now.
4. **A4** — confirm where MVP inspection recording sits in the phase plan.
