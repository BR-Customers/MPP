# Continuous Demo Seed Dataset — Design

**Date:** 2026-07-06
**Status:** Design (awaiting review → implementation plan)
**Branch:** `jacques/working`

## Problem

Dev seed data has no continuity. Two independent pain points:

1. **Siloed transactional smokes.** Five `sql/scratch/smoke_seed_phase{2,3,4,5_7,8}.sql` scripts each **wipe all LOTs and rebuild only their own phase's fixtures** (phase2 uses abstract `A`/`B` LOTs, phase3 uses `MESL`/`SMOKE`, phase5_7 uses `SMK-%`/`5G0-MACH`). Running one destroys another's data, and none of them connect casting → machining → assembly → shipping into a single navigable genealogy. You cannot walk one part end-to-end across the screens.
2. **Bloated product config.** `sql/seeds/020_seed_items.sql` carries a pile of accreted test parts (`5G0`, `5G0-C`, `PNA`, `6MA-HSG`, `RPY`, `5G0-MACH`, `RD-*`, `Flatness`, …) with tangled routes/BOMs/eligibility. It clutters dropdowns and lists and is hard to reason about during end-to-end testing.

**Goal:** a clean, coherent, purpose-built dataset — a small matrix of Honda parts, each exercising a distinct plant flow, connected by real genealogy — that lets an engineer operate every plant-floor screen live *and* trace completed threads, and that stands entirely on its own each run.

## Scope boundary — what is kept vs cleared

**KEPT untouched (the plant + reference layer):**
- Plant location model (`Location.*` — MA1 lines/cells, terminals, printers).
- All code / reference tables (`Lots.LotStatusCode`, `LotOriginType`, `GenealogyRelationshipType`, `Lots.ContainerStatusCode`, `LabelTypeCode`, `Parts.ItemType`, `Parts.OperationType`/`OperationCategory`, UoM, `DataCollectionFieldDataType`, defect codes, downtime reason codes, AIM pool config, `AppUser`, …).
- Tools / dies (`Tools.Tool`, `ToolCavity`, `DieRank`) — equipment, referenced by die-cast LOTs. Existing definitions stay; the demo mounts what the die-cast thread needs.

**CLEARED + purpose-built (the "parts content" layer):**
- `Parts.Item` (the parts), `Parts.Bom` / `Parts.BomLine`, `Parts.ItemLocation` (eligibility), `Parts.ContainerConfig`, `Parts.RouteTemplate` / `Parts.RouteStep`, `Parts.OperationTemplate` (+ its data-collection fields), `Quality.QualitySpec` (+ attributes).

## Architecture — two layers, two lifecycles

| Layer | Lives in | Loaded by | Contents |
|---|---|---|---|
| **Clean parts config** | rewrite `sql/seeds/020_seed_items.sql` + the op-template seeds (`022`/`024`/`026`) | `Reset-DevDatabase` (automatic) | The matrix parts + their routes, BOMs, ContainerConfig, eligibility, operation templates, quality specs. **Zero LOTs.** |
| **Transactional threads** | new `sql/scratch/seed_demo.sql` (+ `Seed-Demo.ps1` wrapper) | run after config load; wired into `Reset-DevDatabase` by default (see below) | Idempotent wipe of all LOT/container/event data, then builds the WIP + completed threads via production procs. Replaces the five `smoke_seed_phase*` silos. |

**Why the split:** the test path (`Reset-DevDatabase` → `Run-Tests`) must run against a LOT-free DB to keep the 1910-assertion suite green, so transactional data cannot live in `sql/seeds`. Config is safe in `sql/seeds` because tests self-fixture around it (see Test Safety).

## The parts matrix (real Honda families)

A small set; each part a distinct flow. Exact part numbers/attribute values are finalized in the implementation plan; the shape is fixed here.

| Part | ItemType | Flow it exercises | End state |
|---|---|---|---|
| **`6MA` Cam Holder** (primary) | Finished Good | die-cast (tool/cavity) → trim → machine (**extract-one** sublots) → **non-serialized assembly** (`Assembly_CompleteTray` mints FG LOT + consumes BOM FIFO) → container → **shipped** | WIP staged at **every terminal** (live-operable) **plus** one thread carried to shipped |
| **`5G0` Front Cover** (serialized variant) | Finished Good | die-cast → machine → **serialized assembly** (mint `SerializedPart`s + place into a container tray) | mid-flow at serial placement (FG-LOT completion is the deferred A4) |
| **`RD-*` Pass-Through** (bracket) | Pass-Through | received on the dock → (no processing) → shipped | one on the receiving dock + one shipped |

Each finished-good part carries the genealogy chain (die casting is the lot-origin; the built procs do not lot-track upstream raw aluminum, so the chain begins at the cast LOT):

```
CAST LOT  (origin Manufactured, Tool T?, cavity ?)
  └─ MACHINED LOT           (MachiningIn_PickAndConsume: cast consumed → machined produced)
       ├─ sublot -01  ┐     (MachiningOut_RecordSplit extract-one)
       └─ sublot -02  ┴──── consumed FIFO into → FG LOT (tray)   (Assembly_CompleteTray)
                                                    └─ Container → shipped (AIM shipper id)
```

**Config per finished-good part:** an `OperationTemplate` sequence forms the `RouteTemplate` (die-cast → trim → machining-in → machining-out → assembly-in → assembly-out), a published `Bom` (FG ← machined component ×N, plus at least one purchased component on the primary part to exercise multi-line BOM + the inventory popup), a `ContainerConfig` (trays-per-container × parts-per-tray; `IsSerialized` set only on `5G0`), `ItemLocation` eligibility at the relevant cells/lines, and a `QualitySpec` with a couple of attributes on the primary part.

**Operation templates** are rebuilt cleanly but **preserve the canonical codes the tests depend on** (`DieCastShot`, `TrimOut`, `MachiningIn`, `MachiningOut`, `AssemblyIn`, plus whatever the assembly-out/role set requires), classified by `OperationType` per the Spec 1 restructure.

## Cross-cutting exercisers

Sprinkled onto the threads so no screen is empty and every code path has data:

- A **paused** LOT on the `6MA` thread (`LotPause_Place`) → Paused-LOT indicator + resume.
- An **active hold** on a `5G0` LOT (`Hold_Place`) → Hold management + the hold-blocks-production guard.
- A **reject / defect** recorded at `6MA` machining (`RejectEvent_Record`) → defect/scrap trail on LOT history.
- A **downtime** event on a line (`DowntimeEvent_Start`) → downtime + supervisor screens.
- Component stock LOTs staged at the assembly cell for the primary part so the **inventory check-in popup** and a **live tray completion** both have data.

Result: LOT Detail, LOT Search, Genealogy Viewer, Containers, Holds, Pauses, Shipping, Downtime, Machining IN/OUT, Assembly, and the Inventory popup all render from connected data.

## Build mechanism

- **Built with the production procs, not raw INSERTs** — `Lot_Create`, `MachiningIn_PickAndConsume`, `MachiningOut_RecordSplit`, `Assembly_CompleteTray`, `Container_Open`/`_Complete`, `LotPause_Place`, `Hold_Place`, `RejectEvent_Record`, `DowntimeEvent_Start`, `SerializedPart_Mint` / `ContainerSerial_Add`, etc. This guarantees genealogy/closure, consumption events, audit trail, and materialized quantities are real and self-consistent (not hand-faked rows that drift from proc behaviour). Raw INSERT is used only for the initial received pass-through / staged-stock LOTs where a proc path does not exist.
- **Idempotent wipe-then-build.** The script's header block deletes all transactional data in FK-safe order (consumption events → genealogy/closure → movements/status-history/attribute-changes → shipping labels/serials/trays/containers → production/downtime/hold/pause events → LOTs → `LotEventLog`), then rebuilds. Re-runnable any number of times; leaves the clean config intact.
- **Everything resolved by code, never hardcoded Id** — parts by `PartNumber`, locations by `Code`, users by initials — so the seed survives identity reseeds.
- **Volume: minimal + readable** — roughly 2–3 threads per part (one completed, the rest staged WIP), enough to populate every list/dropdown without clutter. Not hundreds of rows.
- **Prints a "what to smoke" checklist** at the end: per screen, the URL + which cell/operator to use + the action to perform (mirrors the existing smoke scripts' guides).

## Delivery + integration into the default flow

- **New:** `sql/scratch/seed_demo.sql` (the consolidated builder) + `Seed-Demo.ps1` (thin wrapper mirroring `Seed-SmokeData.ps1`; resolves paths, invokes sqlcmd with the required flags `-b -I -C`).
- **`Reset-DevDatabase.ps1` runs the demo seed by default.** Add a `-SkipDemoSeed` switch (default-on behaviour): after the config seeds load, unless `-SkipDemoSeed` is passed, it runs `seed_demo.sql`. So the everyday `.\Reset-DevDatabase.ps1` produces the full clean environment (clean config + demo threads) in one command.
- **`Run-Tests.ps1` opts out.** Its Reset invocation (currently `& $ResetScript -ServerInstance … -DatabaseName …`) gains `-SkipDemoSeed`, so the test path stays LOT-free and the suite is unaffected.
- **Retire the silos:** delete `sql/scratch/smoke_seed_phase{2,3,4,5_7,8}.sql` and `smoke_cleanup_phase2.sql` (superseded). Keep `Seed-SmokeData.ps1` only if still referenced; otherwise fold it into `Seed-Demo.ps1`.

Run model:
```
.\Reset-DevDatabase.ps1                 → clean config + demo threads   (default; work/smoke)
.\Reset-DevDatabase.ps1 -SkipDemoSeed   → clean config only, zero LOTs
.\Run-Tests.ps1                         → uses -SkipDemoSeed internally → 1910 green
.\Seed-Demo.ps1                         → re-seed threads without a full reset
```

## Test safety

Verified during design: of **165 test files, none depend on the seeded product parts** — they all self-fixture (each test INSERTs its own `P5-MACH-TEST` / `P6-CT-*` parts, tests against them, and deletes them). The single grep hit (`050_ufn_TruncateActivity.sql`) is a **string literal** (`'5G0 · Eligibility · +DIECAST'` as sample truncation text), not a data dependency. The tests' only shared dependencies are plant locations, code tables, and operation-template **codes** — all preserved.

**Guarantee:** rebuild the parts config while preserving the operation-template codes verbatim, then run the full suite once to confirm it stays **1910 green with zero test edits**. If any test unexpectedly regresses, fix it as part of the config-rewrite task (not expected).

## Out of scope

- Upstream raw-aluminum lot-linking (the built die-cast flow originates the cast LOT; it does not consume a raw-material LOT).
- Serialized-assembly FG-LOT completion (deferred A4 — the `5G0` thread stops at serial placement).
- High-volume / load data (a separate load-testing harness spec already exists).
- Any Ignition view changes (this is data + scripts only).

## Implementation outline (for the plan)

1. **Rewrite the clean parts config** in `sql/seeds/020_seed_items.sql` (+ `022`/`024`/`026` op-templates) — the matrix parts, routes, BOMs, ContainerConfig, eligibility, quality specs; preserve op-template codes. Run `Reset-DevDatabase -SkipDemoSeed` + `Run-Tests` → confirm 1910 green.
2. **Write `seed_demo.sql`** — idempotent transactional wipe + build the threads via production procs, with the cross-cutting exercisers and the "what to smoke" printout.
3. **Wire delivery** — `-SkipDemoSeed` switch on `Reset-DevDatabase.ps1`; `Run-Tests.ps1` opts out; `Seed-Demo.ps1` wrapper; delete the `smoke_seed_phase*` silos.
4. **Smoke** — `.\Reset-DevDatabase.ps1` then walk the printed checklist across the screens.
