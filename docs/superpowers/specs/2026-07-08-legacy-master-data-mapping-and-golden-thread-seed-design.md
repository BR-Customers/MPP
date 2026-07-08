# Legacy Master-Data Mapping & Golden-Thread Seed — Design

**Date:** 2026-07-08
**Author:** Blue Ridge Automation (Jacques + Claude)
**Status:** Draft — for review
**Related:** `sql/scratch/emmd_extract_master_data.sql` (extract), `sql/seeds/020_seed_items.sql` + `029_seed_item_routes.sql` (target precedent), `docs/superpowers/specs/2026-07-07-terminal-mint-model-and-rename-bom-removal-design.md`, memory `project_mpp_legacy_source_system`.

---

## 1. Purpose & Scope

Pull real master/reference data out of the legacy MPP MES (`MES` db on `EXCSRV05`, SparkMES lineage) and turn a representative slice of it into a seed that **exercises every structural pattern of our new 8-schema model** — so we validate the model against real MPP part/BOM/route shapes rather than idealized mock data.

This is **model validation, not data migration.** We deliberately seed two curated *golden threads*, not the full ~340-part catalog. A full-catalog migration is a separate, later exercise.

**In scope:** `location`, `parts` (Item, ItemType, Uom, Bom/BomLine, OperationType/RoleKind, OperationTemplate, RouteTemplate/RouteStep, ItemLocation, ContainerConfig) master/reference data for two product families.

**Out of scope (deferred):** transactional/genealogy tables (`Lot*`, `SerializedItem*`, `*Transaction`, `LotBomComponent`, `VisionSystemEventLog`), OEE/downtime history, the OPC/handshake config in the `EMMD` db, and the full-catalog load.

---

## 2. The two golden threads

Chosen because together they cover **both consume-mint variants, both validation modes, and the dirty-data cases**, at ~35 parts total.

### Thread A — 59B Cam-Rocker Holder Set (camera/tray, fan-in, machining-as-mint)
The 59B family is unusually rich: it contains **both** machining patterns in one program.

- **Individual machined holder** (legacy identity change at machining → **Machining-OUT ConsumeMint**):
  `12231-59B-0000` (casting, `Component`) → `12231-59B-0001` (machined, legacy "59B Finished Goods" → we classify **SubAssembly**). One representative holder (`12231`) plus its 4 intake + 5 exhaust siblings if we want the full set.
- **The assembled set** (fan-in → **Assembly-OUT ConsumeMint**):
  `1223A-59B -A0002` (the Cam-Rocker Holder Set, `FinishedGood`) consuming the 10 holders + dowel pins (`90701-5R0-3000`, `90701-5A2-A000`, purchased `Component`).
- Runs on 3 parallel assembly lines (multi-line same-part); Honda customer; camera + tray (`TrayQuantity 2`, `RecipeNumber 1`); die/cavity lot attributes at casting.

**Patterns exercised:** OriginMint (die cast) · Machining-OUT ConsumeMint (casting→machined SubAssembly) · Assembly-OUT ConsumeMint (fan-in, 10→1) · camera-tray validation · multi-line same-part · purchased-component consumption.

### Thread B — 5PA Fuel Pump (scale/weight, linear, machining-as-advance)
- `12270-5PA` (raw cast fuel-pump base, `Component`) → machined (pass-through, **identity preserved → Machining = Advance**) → `12270-5PA -A0001` (`FinishedGood`) consuming the raw + stud bolt (`92900-06014-1B`) + dowel (`94301-08100`).
- Scale-processed (`IsScaleProcessingEnabled = 1`), Honda customer, linear route.

**Patterns exercised:** OriginMint · Machining **Advance** (no identity change — the contrast case to Thread A's machining mint) · Assembly-OUT ConsumeMint (linear 1-child) · **scale/weight** validation (vs Thread A's camera).

> The two threads deliberately disagree on what machining does — Thread A mints a new identity at Machining OUT, Thread B passes identity through. Both are real in the legacy data, and our route model must represent both via `OperationRoleKind` on the machining step.

---

## 2.5 Existing precedent — `seed_jp_validation.sql`

Jacques already committed (`a2858c3`, re-authored 2026-07-07) a working, terminal-mint-compliant validation seed at `sql/scratch/seed_jp_validation.sql`. It builds a **synthetic** 5G0 family (`5G0-c` Component → `5G0-SA` SubAssembly → `5G0-FG` FinishedGood + `21001 pin`) entirely through the production procs, with route-legality enforced at publish:

- Items guarded by PartNumber; `Parts.OperationTemplate` rows (`DC-A`/`T-IN-A`/`T-Out-A`/`M-In-A`/`M-Out-A`/`A-Out-A`) joined to `OperationType` by role Code. **Note:** `OperationTemplate` has a `RequiresSubLotSplit` column (used here) not surfaced in the schema recon.
- Routes via `Parts.RouteTemplate_Create` → `RouteTemplate_SaveAll` (steps as `FOR JSON PATH`) → `RouteTemplate_Publish`. Casting route `DieCast→TrimIn→TrimOut→MachiningIn→MachiningOut` (MachiningOut mints the SA); SA route `AssemblyOut` (mints the FG); FG unrouted.
- BOMs via `Parts.Bom_Create` → `BomLine_Add` → `Bom_Publish`. Eligibility via direct `Parts.ItemLocation` inserts, natural-key resolved.

**Consequence:** the seed *harness* is solved and proven. This design does **not** reinvent it — the two golden threads are expressed in the **same proc-driven, idempotent, natural-key pattern**. What the legacy threads add over the synthetic 5G0 family:
1. **Real MPP part numbers, BOMs, and routes** (the point of the exercise — validate against real data, not mock).
2. **Fan-in genealogy** — the 59B set consumes ~10 children at one Assembly-OUT mint, vs. the synthetic FG's single SA child.
3. **Machining-advance vs machining-mint contrast** — Thread B passes identity through machining (Advance) where the synthetic 5G0 (and Thread A) mint at Machining OUT.
4. **Camera-tray + scale** validation modes and dirty-data cases.

## 3. Transform rules (reusable legacy → new mapping)

These rules generalize beyond the two threads (they'd drive a future full-catalog load).

### 3.1 ItemType derivation
Legacy has only `MaterialClass` (program × coarse type), `IsFinishedGood`, `IsSupplyPart`. Our `Parts.ItemType` = {RawMaterial, Component, SubAssembly, FinishedGood, PassThrough}. Derivation, grounded in the `020_seed_items` precedent (`6MA-C`=Component, `6MA-M`=SubAssembly, `6MA`=FinishedGood, `PIN-A`=Component, `RD-BRKT`=PassThrough):

| Legacy signal | → ItemType |
|---|---|
| `IsSupplyPart = 1` (dowel pins, bolts, o-rings, steel balls) | **Component** (purchased) |
| Casting / RAW part (`-0000` / ` RAW` / `IsFinishedGood=0`, produced at a Casting cell) | **Component** |
| Machined intermediate that is **consumed as a BOM child** of another part (`-0001`, `-J000`, machined variant) | **SubAssembly** |
| `IsFinishedGood=1` **and never a BOM child** of another part (terminal/shippable) | **FinishedGood** |
| `Offsite` part MPP receives & reships without transformation | **PassThrough** |
| Aluminum ingot / bulk raw metal | **RawMaterial** (none present in the two threads) |

**Program** (`5A2`/`RPY`/`59B`/…) is parsed from the part number / MaterialClass and stored as a *separate* attribute, **not** as ItemType. (Open question 6.4: where — a new `Program` attribute column vs. description-only.)

The "is it ever a BOM child?" test resolves the legacy mislabel where machined holders carry `MaterialClass = "59B Finished Goods"` but are really sub-assemblies.

### 3.2 Route derivation from `WorkCellMaterial`
Legacy has no route table; the route is implicit in `WorkCellMaterial` (materials per cell + `IsConsumptionPoint`). Algorithm per target part:

1. Find every WorkCell whose `WorkCellMaterial` references the part (or its casting/FG identity).
2. Order those cells by **process stage** parsed from Area/Line/Cell names: Casting → Machining (IN→OUT) → Assembly (IN→OUT).
3. Emit a `RouteTemplate` (`ItemId` = the part) with `RouteStep`s referencing the matching `OperationTemplate` (by Code), assigning `OperationType`:
   - Casting cell → `DieCast` (`OriginMint`).
   - Machining OUT where the part-number **changes** (casting→machined child) → `MachiningOut` (`ConsumeMint`). Where identity is **preserved** → `MachiningIn`/`MachiningOut` as **Advance**.
   - Assembly OUT that consumes children → `AssemblyOut` (`ConsumeMint`).
4. **Finished goods get NO route** (terminal-mint model v2.0): they are born at their sub-assembly's Assembly-OUT consume-mint. Only castings and sub-assemblies carry routes.

`5A2 Casting 1 Work Cell` is the shared plant-wide OriginMint — its ~60 pass-through materials confirm one casting origin feeding every program.

### 3.3 BOM mapping
- **Drop the self-component row.** Every legacy BOM lists its own output Material as a component of itself — skip that line; the legacy `Bom.MaterialID` → our `Parts.Bom.ParentItemId`.
- Legacy BOMs are **flat** (`ParentBomComponentID` always NULL); multi-level structure = chained single-level BOMs via shared Material identity. Map each legacy BOM to one `Parts.Bom` + N `Parts.BomLine` (`ChildItemId`, `QtyPer`, `UomId`=EA default when legacy UOM blank).
- **Version:** legacy `Bom.Version` is free-text and messy (`"10 01"`, `" "`, `"0301"`). Normalize to our integer `VersionNumber` — proposal: collapse all legacy versions of a part to `VersionNumber = 1`, `PublishedAt` set (we only seed the current/active BOM, not history). (Open question 6.1.)

### 3.4 Location mapping
The legacy plant (18 areas, ~60 lines) dwarfs our seeded demo plant (`DC1-3`, `MA1-*`). Two options (Open question 6.2):
- **(Recommended) Remap threads onto the existing demo plant** — run Thread A on a full-process line (`MA1-FPRPY`: MIN→MOUT→AFIN) and Thread B on another, reusing `011_seed_locations_mpp_plant.sql` locations. Keeps the location seed stable; sufficient for model validation.
- **(Fidelity)** Add real 59B + 5PA areas/lines/cells to the location seed. More faithful, heavier, and not needed to validate the model.

### 3.5 Data hygiene (ASCII-only, dirty-data filter)
- **ASCII-only** on all Name/Description/dunnage (byte-scan before applying). Legacy `ReturnableDunnageCode` holds mojibake `?????`/`????` — drop or replace with a clean placeholder, never store the corruption.
- **Skip** `DO NOT USE` / `DNU` / `TEMP` / `TBD` / `TODO` parts, cells, and BOMs.
- **Trim trailing spaces** from part numbers (`12270-6NA ` → `12270-6NA`).
- Map legacy UOM (Gram/Kilogram/Pound/Ounce) → our `Parts.Uom` (KG/LB; add G/OZ if a thread needs them — currently only LB/EA are required).

---

## 4. Deliverable

A **new sibling** scratch file `sql/scratch/seed_legacy_threads.sql` (NOT an edit of `seed_jp_validation.sql` — Jacques owns and actively edits that; a sibling avoids clobbering concurrent work and keeps the synthetic 5G0 fixture intact). It:

- Follows `seed_jp_validation.sql`'s pattern **verbatim**: idempotent (`IF NOT EXISTS` on natural keys — PartNumber/Code — never hardcoded Ids), ASCII-only, no `USE` (runs against the `-d` session), routes/BOMs built via `Parts.RouteTemplate_Create/SaveAll/Publish` + `Parts.Bom_Create/BomLine_Add/Bom_Publish` (route-legality enforced at publish), eligibility via natural-key-resolved `Parts.ItemLocation` inserts.
- Loads the two threads' Items → OperationTemplates → Routes → BOMs → ItemLocation, ordered items-before-routes (RouteStep resolves OperationTemplate by Code).
- **Optionally** demos the flow end-to-end by calling the real mutation procs (`Lots.Lot_Create`, `Workorder.MachiningOut_Mint`, `Workorder.Assembly_CompleteTray`, `Workorder.ProductionEvent_Record`) so mint/route/genealogy logic is exercised — not raw inserts. (Master-data config first; live-LOT demo is a follow-on.)
- Invocation mirrors his: `sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/seed_legacy_threads.sql`.

Validation gate: after seeding, the derived routes must pass `Parts.RouteTemplate_Publish` legality (non-FinishedGood routes end at a ConsumeMint; ≤1 ConsumeMint, last; OriginMint first) — a real test of both the seed and the model.

---

## 5. What this validates in the model

- **Adjacency/closure genealogy** ← legacy flat-BOM-chains map cleanly onto parent/child, confirming the shape.
- **`OperationRoleKind` on the route step** ← Thread A (machining mint) vs Thread B (machining advance) prove the route step must carry the role, not the location.
- **Terminal-mint model** ← Machining-OUT consume-mint (A) and Assembly-OUT consume-mint (both) against real part-number-change data; FGs unrouted.
- **Derived ItemType + Program-as-attribute** ← 34 program×type classes collapse into 5 ItemTypes + a program attribute.
- **Camera-tray vs scale validation** ← Thread A (tray) and Thread B (scale) exercise both `ContainerConfig.ClosureMethod` paths (`ByVision`/`ByCount` vs weight).
- **Dirty-data resilience** ← ASCII/mojibake/DNU/trailing-space handling proves constraints survive real MPP data.

---

## 6. Open questions for review

1. **BOM version normalization** — collapse legacy free-text versions to a single `VersionNumber=1` current BOM (recommended), or attempt to preserve legacy version history?
2. **Location strategy** — remap threads onto the existing demo plant (recommended) vs. seed real 59B/5PA lines?
3. **59B set BOM inconsistency** — the legacy `1223A-59B -A0002` set BOM consumes the **`-0000` castings** directly, while separate `-0001` machined-holder products also exist. Does the set consume castings (as legacy says) or should we model it consuming the machined SubAssemblies? This changes whether the set's children are Component or SubAssembly.
4. **Program attribute** — where does `5A2`/`RPY`/`59B` live in our model? New nullable `Parts.Item.Program` column, a code table, or description-only for now?
5. **PassThrough scope** — do we include any Offsite reship parts as a `PassThrough` example, or leave that to `RD-BRKT` already in `020`?
6. **File placement** — new `sql/scratch/seed_legacy_threads.sql` sibling (recommended, keeps `seed_jp_validation.sql` + the 8-item demo intact), vs. extending an existing seed.
7. **Part-naming convention** — use the **real legacy part numbers** (`12231-59B-0000`, `1223A-59B -A0002`, `12270-5PA -A0001`) for fidelity, or Jacques's abstracted style (`5G0-c`/`-SA`/`-FG`)? Real numbers are the point of grounding in legacy data, but carry spaces/hyphens; recommend real numbers, trimmed of trailing spaces, since the model must tolerate them anyway.
8. **Relationship to `seed_jp_validation.sql`** — do the legacy threads **supersede** the synthetic 5G0 fixture (Jacques migrates to real data) or **coexist** (synthetic stays as the minimal smoke fixture, legacy threads as the richer validation set)? Affects whether any test fixtures referencing the synthetic parts need updating.

---

## 7. Revision History

| Version | Date | Author | Notes |
|---|---|---|---|
| Draft | 2026-07-08 | Jacques + Claude | Initial mapping design from legacy `MES` extract (grids A–G) against target schema (migrations 0002–0036, seeds 011/020/029). |
