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

> **Machining role is set by the OUT-terminal rule** (terminal-mint decision C): a machined SubAssembly identity exists **iff the line has a Machining-OUT terminal** (a `... Machining OUT` Workstation). The two threads land on opposite sides of this rule — which is the whole point of picking them.

### Thread A — 59B Cam-Rocker Holder Set (camera/tray, fan-in, **machining = Advance**)
- The 59B cam-holder lines (`59B Cam Holder Assembly`, `Line 2`, `Line 3`) have Machining **IN** + Assembly workstations but **no Machining OUT** → **no machined SubAssembly identity**; machining is an **Advance** and the set consumes the **castings directly**.
- **Children (10 holder castings, `Component`):** `12231-59B-0000` … `12235-59B-0000` (intake 1-5) + `12241-59B-0000` … `12245-59B-0000` (exhaust 1-5), each OriginMinted at die cast, advanced through Machining IN.
- **Finished good (fan-in Assembly-OUT ConsumeMint):** `1223A-59B -A0002` (Cam-Rocker Holder Set, `FinishedGood`) consuming the 10 holder castings + dowel pins (`90701-5R0-3000`, `90701-5A2-A000`, purchased `Component`).
- Runs on 3 parallel lines (multi-line same-part); Honda customer; camera + tray (`TrayQuantity 2`, `RecipeNumber 1`); die/cavity lot attributes at casting.

**Patterns exercised:** OriginMint (die cast) · Machining **Advance** (no OUT terminal, identity preserved) · Assembly-OUT ConsumeMint (**fan-in, 10→1**) · camera-tray validation · multi-line same-part · purchased-component consumption.

### Thread B — 6NA Fuel Pump (linear, **machining = ConsumeMint**)
> **Line choice driven by OUR model (011), the authority:** the modeled `MA2-5PA` line has *only* Machining-In terminals (no Machining Out), so a 5PA fuel pump can't be the machining-mint thread in our model. The complete fuel-pump line **with** a Machining Out is `MA1-FP6NA` ("Fuel Pump 6na 6vj": MIN→MOUT→AFIN). Thread B therefore uses the **6NA fuel pump** family on `MA1-FP6NA`.

- **Casting (`Component`):** `12270-6NA` (raw cast fuel-pump base, legacy "59B Components"), OriginMinted at die cast.
- **Machined SubAssembly (Machining-OUT ConsumeMint):** legacy reused `12270-6NA` through machining with **no distinct machined part number**, so our model must **synthesize** one — `12270-6NA-M` (`SubAssembly`). *This synthesized part is itself a validation artifact of decision C.*
- **Finished good (Assembly-OUT ConsumeMint at AFIN):** `12270-6NA -0001` (`FinishedGood`) consuming the machined SA + stud bolt (`92900-06014-1B`) + dowel (`94301-08100`).
- Honda customer, linear route: casting `DieCast→MachiningIn→MachiningOut`; SA `AssemblyOut`; FG unrouted.

**Patterns exercised:** OriginMint · **Machining-OUT ConsumeMint** (casting→synthesized machined SubAssembly, the contrast case to Thread A) · Assembly-OUT ConsumeMint (linear 1-child) · synthesized-identity handling for decision C.

### Location mapping — no new locations
Both threads map onto **existing** `011_seed_locations_mpp_plant.sql` lines (the reconciled real plant already collapses legacy Line+WorkCell into WorkCenter): Thread A → `MA2-59B` (`MA2-59B-MIN`, `MA2-59B-AOUT1`); Thread B → `MA1-FP6NA` (`MA1-FP6NA-MIN`, `-MOUT`, `-AFIN`). Castings origin-mint at existing DieCastMachine cells (e.g. `DC3-M01`, `DC2-M01`). The seed adds **no** location rows.

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
   - Casting cell → `DieCast` (`OriginMint`), first step.
   - **Machining role by OUT-terminal rule (decision C):** if the line has a `... Machining OUT` Workstation → a machined `SubAssembly` identity exists, minted at `MachiningOut` (`ConsumeMint`); if legacy has no distinct machined part number, **synthesize** one (`<part>-M`). If the line has only Machining IN → machining is `MachiningIn` (`Advance`), no SubAssembly.
   - Assembly OUT that consumes children → `AssemblyOut` (`ConsumeMint`).
4. **A route belongs to one part and ends at exactly one ConsumeMint** (its final step). The produced part is derived via BOM child→parent, not stored on the route. Each consumed part carries its own route ending at the shared consume-mint (fan-in = N castings' routes converge on one Assembly-OUT mint).
5. **Finished goods get NO route** (terminal-mint model v2.0): they are born at the Assembly-OUT consume-mint of the parts they consume. Only castings and sub-assemblies carry routes.

`5A2 Casting 1 Work Cell` is the shared plant-wide OriginMint — its ~60 pass-through materials confirm one casting origin feeding every program.

### 3.3 BOM mapping
- **Drop the self-component row.** Every legacy BOM lists its own output Material as a component of itself — skip that line; the legacy `Bom.MaterialID` → our `Parts.Bom.ParentItemId`.
- Legacy BOMs are **flat** (`ParentBomComponentID` always NULL); multi-level structure = chained single-level BOMs via shared Material identity. Map each legacy BOM to one `Parts.Bom` + N `Parts.BomLine` (`ChildItemId`, `QtyPer`, `UomId`=EA default when legacy UOM blank).
- **Version:** legacy `Bom.Version` is free-text and messy (`"10 01"`, `" "`, `"0301"`). Normalize to our integer `VersionNumber` — proposal: collapse all legacy versions of a part to `VersionNumber = 1`, `PublishedAt` set (we only seed the current/active BOM, not history). (Open question 6.1.)

### 3.4 Location mapping — legacy collapses INTO our model (decided 2026-07-08)
Our 5-tier model is authoritative; we do **not** add a tier for legacy. We seed the **real** legacy location subtree for the two threads (so this seed doubles as location-model validation), collapsing legacy's two middle tiers into our one:

| Legacy tier | → Our tier / LocationTypeDefinition |
|---|---|
| Site | Site → `Facility` |
| Area | Area → `ProductionArea` |
| ProductionLine **+** WorkCell | **both collapse → WorkCenter** (line-resident model: LOTs live at the WorkCenter/line) |
| Workstation (`… IN`/`… OUT`, machine name) | Cell → `Terminal` / `CNCMachine` / `DieCastMachine` / `AssemblyStation` (by function) |

- When a legacy Line has multiple WorkCells, all flatten under one WorkCenter and their Workstations become sibling Cells — the WorkCell grouping is dropped (acceptable; our model doesn't carry it).
- `Code`/`Name` derived from legacy names, ASCII-trimmed; `DeprecatedAt` set for any `DO NOT USE` cells we choose to include (or skip them).
- Reuse existing `011_seed_locations_mpp_plant.sql` rows where a thread's Area/line already exists; otherwise add the real 59B / 5PA / shared-casting subtree.
- **Location-model finding to record:** multi-WorkCell lines are the stress case for whether WorkCenter→Cell suffices; flattening validates that it does without a 6th tier.

### 3.5 Data hygiene (ASCII-only, dirty-data filter)
- **ASCII-only** on all Name/Description/dunnage (byte-scan before applying). Legacy `ReturnableDunnageCode` holds mojibake `?????`/`????` — drop or replace with a clean placeholder, never store the corruption.
- **Skip** `DO NOT USE` / `DNU` / `TEMP` / `TBD` / `TODO` parts, cells, and BOMs.
- **Trim trailing spaces** from part numbers (`12270-6NA ` → `12270-6NA`).
- Map legacy UOM (Gram/Kilogram/Pound/Ounce) → our `Parts.Uom` (KG/LB; add G/OZ if a thread needs them — currently only LB/EA are required).

---

## 4. Deliverable

**Append** the two legacy threads to the existing `sql/scratch/seed_jp_validation.sql` (decided 2026-07-08 — they coexist with the synthetic 5G0 fixture, which stays as the minimal smoke fixture). Added as new clearly-bannered sections after the 5G0 block. It:

- Follows the file's existing pattern **verbatim**: idempotent (`IF NOT EXISTS` on natural keys — PartNumber/Code — never hardcoded Ids), ASCII-only, no `USE` (runs against the `-d` session), routes/BOMs built via `Parts.RouteTemplate_Create/SaveAll/Publish` + `Parts.Bom_Create/BomLine_Add/Bom_Publish` (route-legality enforced at publish), eligibility via natural-key-resolved `Parts.ItemLocation` inserts.
- Uses **real legacy part numbers** (trailing-space-trimmed), plus the one synthesized `12270-5PA-M` machined SA (decision C).
- Loads (in order): the thread Locations (real legacy subtree, collapsed per §3.4) → Items → OperationTemplates → Routes → BOMs → ItemLocation.
- Live-LOT/genealogy demo via mutation procs (`Lots.Lot_Create`, `Workorder.MachiningOut_Mint`, `Workorder.Assembly_CompleteTray`, `Workorder.ProductionEvent_Record`) is a **follow-on** section, not the first cut — master-data config lands first.
- Invocation unchanged: `sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/seed_jp_validation.sql`.

**Before editing:** re-read the on-disk `seed_jp_validation.sql` (Jacques may have edited it since `a2858c3`) and append only — never rewrite his 5G0 section.

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

## 6. Decisions & remaining open questions

**Resolved 2026-07-08:**
- **Location strategy** — seed the *real* legacy subtree, collapsing legacy Line+WorkCell → our WorkCenter, Workstations → Cells; our model is authoritative, no new tier (§3.4). Doubles as location-model validation.
- **59B set children** — the set consumes the **castings (Component)** directly: the 59B cam-holder lines have **no Machining-OUT terminal**, so no machined SubAssembly exists (decision C). Matches legacy BOM.
- **Machining role** — set by the OUT-terminal rule per thread: 59B = Advance, 5PA = ConsumeMint (§2, §3.2).
- **Part naming** — use **real legacy part numbers**, trailing-space-trimmed. Plus one synthesized `12270-5PA-M` for the 5PA machined SA.
- **File** — **append to `sql/scratch/seed_jp_validation.sql`**; coexists with the synthetic 5G0 fixture (§4).

**Still open (surface during/after first cut, not blocking):**
1. **BOM version normalization** — collapse legacy free-text versions to a single current `VersionNumber=1` BOM (recommended), or preserve history? *(Recommend collapse; seed current only.)*
2. **Program attribute** — where does `5A2`/`RPY`/`59B` live? New nullable `Parts.Item.Program` column, a code table, or description-only for now? *(Recommend description-only for the seed; a `Program` column is a separate model decision.)*
3. **PassThrough scope** — include an Offsite reship part as a `PassThrough` example, or leave that to `RD-BRKT` in `020`? *(Recommend leave to `RD-BRKT`.)*

---

## 7. Revision History

| Version | Date | Author | Notes |
|---|---|---|---|
| Draft | 2026-07-08 | Jacques + Claude | Initial mapping design from legacy `MES` extract (grids A–G) against target schema (migrations 0002–0036, seeds 011/020/029). |
| Draft r2 | 2026-07-08 | Jacques + Claude | Review decisions: real legacy locations collapse into our model (no new tier); machining role by OUT-terminal rule (59B=Advance, 5PA=ConsumeMint, synth `12270-5PA-M`); real legacy part naming; append to `seed_jp_validation.sql` (coexist). Corrected the Thread A/B machining-role swap. |
