# Terminal Mint Model & Rename-BOM Removal — Design Spec

**Date:** 2026-07-07
**Status:** Draft — awaiting Jacques review
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor) — Machining & Assembly flow correction. Unwinds the "rename-BOM" thread and re-bases terminal FIFO / part identity on the route.
**Supersedes / corrects:** FDS-05-032, FDS-05-033 (Trim→Machining rename via 1-line BOM), FDS-06-007 (Machining IN rename), and the `HasRenameBom` discriminator in `Lots.Lot_GetWipQueueByLocation` (v2.0). Related working notes: `notes/2026-07-06_working-notes.md` (route-step cascade; FIFO-vs-coupling seam).

---

## 1. Motivation

The Machining & Assembly flow accreted a **rename-BOM** mechanism that is now incoherent and must be unwound.

**Where it came from.** FDS-05-033 needed to represent the casting→machined part-number change (`6MA-C` Component → `6MA-M` SubAssembly) as a Honda-traceable event. Rather than a dedicated transform table, it reused BOM + `ConsumptionEvent`: give the machined Item a **1-line BOM** whose only child is the casting, and at **Machining IN** "consume" the casting to "produce" a new machined LOT (`MachiningIn_PickAndConsume`).

**Why it is now broken.** Commits `348762e`/`1e46c60` ("Machining IN = unworked arrivals, drop BOM consumption") ripped the consumption out of Machining IN — `RecordPick` keeps identity and mints nothing; the machined LOT is minted at Machining OUT. But the 1-line rename-BOM **survived as a vestige**: `Lots.Lot_GetWipQueueByLocation` v2.0 repurposed it into a `HasRenameBom` flag used only to *guess* "is this a casting that gets machined?" for the Machining IN queue. The thing it existed for (minting at IN) is gone; what remains is a fragile discriminator that couples queue membership to BOM shape and part identity.

**The deeper problem it exposed.** Terminal FIFO membership currently keys off part-type + BOM-shape hints instead of the route. With all inventory line-resident (LOTs live at the parent line; terminals zone up to it), there is **no explicit rule** for which of a line's terminals a LOT should appear at — it is derived per-screen and under-specified (only Machining IN has a concrete hint). See the 2026-07-06 working note "how does a line-resident LOT know which terminal FIFO to appear in."

This spec replaces the whole thread with a route-driven model.

---

## 2. Decisions locked (from brainstorming)

These were resolved in dialogue and are the foundation of the design:

1. **Route is the single source of truth** for which terminals act on a part and in what order. Part-type drops out of queue logic; `HasRenameBom` dies.
2. **Terminals are either _advance_ or _mint_.** Advance = stamp an event on an existing LOT, no consumption, no new LOT. Mint = birth a new part-number LOT by consuming input(s) per the produced part's BOM.
3. **Machining IN is pure advance** — it stamps a machining event on the casting LOT. It consumes nothing and mints nothing. ("New lots are not created there.")
4. **SubAssembly identity is earned by a Machining OUT terminal (decision "C").** A distinct machined-part LOT exists **iff** the route routes the casting through a Machining OUT step — which is authored only when the line has a Machining OUT terminal. On a sparser line the casting rides straight through to Assembly, and the FG's BOM lists the casting directly.
5. **Mint target is BOM-derived, disambiguated by route + existing line config, operator-overridable** (approach "C"). BOM says *what to consume* and *which parent*; route + `ItemLocation` direct-eligibility say *where a part is born* and narrow candidates; the operator confirms/overrides.
6. **Assembly OUT presents an eligible-FG dropdown** with a **ranked default**: order eligible FGs by (BOM component-lines satisfied by ready line inventory, descending), tie-broken by earliest-arriving satisfying WIP (FIFO, ascending); preselect the top row. Computed in a SQL read proc, not Python.
7. **Mint quantity is flexible and operator-chosen** — the input LOT's size has no bearing. Prefills to `Item.DefaultSubLotQty`, operator overrides; the input is a decrementing consumption pool that stays open until exhausted, then closes. Repeatable.
8. **Genealogy in the standard flow is `Consumption`-only.** Each mint writes `Consumption` edge(s) from consumed input LOT(s) to the new output LOT. No `Split` at mint terminals.
9. **The sublot framework is retained but demoted to an _exception_ path** — genuine same-part-number divisions (quality dispositions, holds, logistics). It is removed from the standard M&A flow, not deleted from the system.

---

## 3. The model

### 3.1 Terminal taxonomy

Every terminal interaction (= route step) is one of:

| Kind | What it does | Consumes | Mints | Genealogy | Examples |
|---|---|---|---|---|---|
| **Advance** | Stamps a `ProductionEvent` on the LOT; LOT proceeds to its next route step | nothing | nothing | none | Trim, **Machining IN**, Assembly IN, CNC |
| **Consume-mint** | Stamps a `ProductionEvent`; mints a new **parent** part LOT by consuming this LOT (+ co-inputs per the parent's BOM) | this LOT + BOM co-inputs | parent part LOT | `Consumption` (input → output) | **Machining OUT**, **Assembly OUT** |
| **Origin-mint** | Births this route's own part from raw stock (no upstream LOT consumed) | raw material | this route's part | (origin) | **Die Cast** |

Origin-mint (Die Cast) is largely upstream of this cleanup and is called out only for completeness; the redesign centers on Advance and Consume-mint on the M&A line.

### 3.2 Route as the single source of truth — the uniform queue rule

Each terminal has an `OperationType` **role**. The FIFO at a terminal of role **R** is:

> the line-resident, open LOTs whose **lowest-`SequenceNumber` unsatisfied route step** has role **R**.

A route step is "satisfied" when a `Workorder.ProductionEvent` exists for the LOT against the step's `OperationTemplateId` (both already exist: `ProductionEvent` FKs `OperationTemplateId`; steps carry `SequenceNumber`). So the queue query becomes: *walk the LOT's active route in sequence, find the first step with no matching `ProductionEvent`; if that step's role = my terminal's role, the LOT is in my queue.*

This is **one mechanism for all terminals**, advance and mint alike. It replaces the whole `HasRenameBom` / part-type discrimination. It is literally "route is the source of truth."

- **Advance step reached:** the terminal stamps the event; the LOT's next unsatisfied step advances to the following terminal.
- **Consume-mint step reached:** the LOT is the *input* waiting to be consumed here. The terminal consumes it (§3.4) and its route ends (it is fully consumed / closes when the pool is exhausted).

### 3.3 Decision "C" expressed purely as route authoring

The presence of a Machining OUT step on the casting's route is the **single knob** that creates a SubAssembly:

- **Line with a Machining OUT terminal** — casting route `[DieCast, Trim, MachiningIn, MachiningOut]`. The casting's final step is `MachiningOut` (consume-mint) → it appears in the Machining OUT queue → minting births the `SubAssembly`. The SubAssembly's own route (`[AssemblyIn, AssemblyOut]` or `[AssemblyOut]`) then governs it.
- **Line without a Machining OUT terminal** — casting route `[DieCast, Trim, MachiningIn, AssemblyOut]`. The casting's final step is `AssemblyOut` → it appears directly in the Assembly OUT queue → minting births the `FinishedGood`, consuming the casting. No SubAssembly, no intermediary BOM.

There is no separate "does this line sublot / is this a sub-assembly part" flag. It falls out of which steps the route carries, which is authored to match the line's terminals. This is the resolution to the "how do I manage sub-assembly parts / when does the intermediary config apply" confusion.

### 3.4 Mint-target derivation (approach "C")

At a consume-mint terminal (role R, line L), when the operator acts on a ready input LOT:

1. **Candidate produced parts** = Items configured as *produced at L* (`ItemLocation` **direct eligibility** — already maintained per FDS-02-012 "Engineering configures direct eligibility only for produced finished goods and sub-assemblies") whose **active BOM consumes** the ready input LOT's Item.
2. **Auto-derive when unambiguous.** The machining SubAssembly case yields exactly one candidate (the machined part whose single-line BOM consumes the casting) → mint it, no prompt.
3. **Rank + prompt when multiple** (Assembly OUT on a multi-product line): present the eligible-FG dropdown, preselect per the ranked-default rule (decision 6), operator confirms/overrides.
4. **Mint:** create a new output LOT of the chosen part (its own LTT), consume the operator-entered quantity (× BOM `QtyPer`) from the ready input LOT(s), write `Consumption` genealogy, decrement inputs, close any input that reaches zero.

BOM remains the single source of the parent↔child relationship (no `OutputItemId` on route steps → no drift). The **former "rename BOM" data survives — legitimately** — as the SubAssembly's real production BOM, now used at the Machining OUT *mint*, not as a Machining IN hint.

### 3.5 Flexible mint quantity

The mint quantity is operator-entered per action, prefilled from `Item.DefaultSubLotQty` (a suggestion, never a constraint; `DefaultSubLotQty` is a naming leftover of the sublot framing — reinterpret as "default mint quantity", rename optional). The input LOT is a decrementing pool: a 200-pc casting can be minted 20 at a time, or 200 at once, across repeated mints, until exhausted → closed. No coupling to input size, no fixed sublot size.

### 3.6 Genealogy — `Consumption`-only in the standard flow

Every standard-flow mint writes `Consumption` edges (input LOT → output LOT) and a `Workorder.ConsumptionEvent` (`ConsumedItemId` / `ProducedItemId` / quantity). No `Split` / sublot relationship is written on the M&A path. Multiple output LOTs from one input are simply multiple independent `Lot_Create` + `Consumption` edges — **not** sublots of each other.

### 3.7 Sublot framework — retained as exception only

The `Lots.Lot_Split` machinery and the `Split` genealogy relationship are **kept** for genuine same-part-number divisions that do *not* change part identity (e.g. splitting a held LOT for a quality disposition, or dividing a LOT for logistics). They are **removed from the standard M&A mint path**. Rationale (Jacques): a great exception, not a standard. The design must verify no standard M&A step depends on `Split` after the rewrite; if a residual standard use is found, it is reworked to a mint or flagged.

### 3.8 Mint outputs are line-resident — no intra-line destination move

Because all inventory is line-resident (LOTs live at the parent line; terminals zone up to it), a minted output LOT is created **at the line** and simply appears at the next terminal via the queue rule (§3.2) — there is **no intra-line cell-to-cell move** and **no destination selection** at a mint terminal. This retires the current Machining OUT "destination cell" dropdown (`getCellsForDropdownByNamePrefix("Assembly")`) entirely rather than rewiring it: the minted SubAssembly is line-resident and its next unsatisfied route step surfaces it at Assembly IN/OUT automatically. Cross-**area** handoffs that genuinely change location (e.g. Trim OUT choosing which Machining line to deposit at) keep their destination pick; intra-line mints do not.

### 3.9 Current-state divergences this redesign closes

The audit confirmed the built flow diverges from this model in ways worth stating explicitly, so the plan targets them:

- **Machining OUT today is a _split_, not a _mint_.** `MachiningOut_RecordSplit` splits an **externally pre-minted** machined LOT into sub-LOTs with `Split` genealogy (`RelationshipTypeId=1`) and builds **no casting→machined edge** — the demo seed even notes "cast LOTs are NOT genealogy-linked to the machined LOTs." Under this design Machining OUT **mints** the machined SubAssembly by **consuming** the casting (`Consumption` genealogy), which closes that genealogy gap. This is the central backend rework.
- **The WIP-queue read carries two ad-hoc discriminators** (`HasRenameBom` + `HasLineEvent`). The route-driven next-unsatisfied-step rule (§3.2) **replaces both**.
- **The "rename BOMs" are not deleted — they are reinterpreted.** The 1-line BOMs (`6MA-M←6MA-C`, `5G0-M←5G0-C`) stop being a Machining-IN discriminator and become the SubAssembly's **real production BOM**, consumed at the Machining OUT mint.

---

## 4. Schema & config changes

1. **`OperationType` role-kind — ADOPTED (Jacques, 2026-07-07).** Add a role-kind classification to `Parts.OperationType` distinguishing **Advance** vs **Mint**, via a small code-table-backed FK per house convention: new `Parts.OperationRoleKind` (seed `Advance`, `Mint`) + `Parts.OperationType.OperationRoleKindId BIGINT NOT NULL FK`. Seed mapping:

   | OperationType | RoleKind |
   |---|---|
   | `DieCast` | Mint *(origin-mint; die-cast build out of scope — §8/Q4)* |
   | `TrimIn`, `TrimOut` | Advance |
   | `MachiningIn` | Advance |
   | `MachiningOut` | **Mint** |
   | `AssemblyIn` | Advance |
   | `AssemblyOut` | **Mint** |
   | `CNC` | Advance |

   Origin-mint (`DieCast`) vs consume-mint (`MachiningOut`/`AssemblyOut`) is a *behavioral* distinction owned by the screen, not a third code value — two kinds suffice. The role-kind enables **route validation** (a route must terminate at a mint step except a top-level FG; a mint step's produced part must have a satisfiable BOM) and the `ItemType`→role gate (§4.2).
2. **`ItemType` → role gating (design hook, may be separate task).** With route as source of truth, the existing-but-unbuilt `ItemType`→allowed-role constraint gains teeth: a `FinishedGood`'s route cannot start with `DieCast`; a `Component` casting cannot be authored as the *output* of `AssemblyOut`; etc. Enforced in SQL (per the no-business-logic-in-Python rule). Scope: hook defined here; enforcement may land as a dependent task.
3. **BOM authoring consequence (config, not schema).** On lines without a Machining OUT terminal, the FG's BOM lists the **casting** (not a machined SubAssembly) as its component. On lines with one, the SubAssembly's BOM lists the casting and the FG's BOM lists the SubAssembly. No schema change — a config/seed authoring rule.
4. **No new part type.** The `Casting` type floated in discussion is **not** added — route + BOM carry the distinction.

---

## 5. Cleanup Inventory (verified 2026-07-07)

Audited exhaustively across SQL, Ignition, and docs. Action legend: **DELETE** (remove) · **REWORK** (substantive behavior change) · **REWRITE** (doc/narrative) · **ADD** (new) · **VERIFY** (confirm still-correct, no expected change) · **DECISION** (gated on an §7 open question).

### 5.1 Backend — SQL

| # | File · object | Action | What |
|---|---|---|---|
| B1 | `sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql` | **REWORK** | Drop `HasRenameBom` (and the `HasLineEvent` proxy); replace the "all line WIP + hints" shape with the route-driven **next-unsatisfied-step-role = R** filter (role param or per-terminal read). Core change. |
| B2 | `sql/migrations/repeatable/R__Workorder_MachiningIn_RecordPick.sql` | **VERIFY** | Already pure advance (stamps `ProductionEvent`, no consume/mint/genealogy). Confirm no residual rename. |
| B3 | `sql/migrations/repeatable/R__Workorder_MachiningOut_RecordSplit.sql` | **REWORK** | From "split an externally-minted machined LOT (`Split` genealogy, no cast→machined edge)" to **consume-mint**: consume operator-qty from the casting, mint the SubAssembly LOT, write `Consumption` genealogy (casting→machined). Remove intra-line destination param (§3.8). Likely rename (`MachiningOut_Mint`). |
| B4 | `sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql` | **VERIFY / minor** | Already mints FG + `Consumption` genealogy (`RelationshipTypeId=3`). Confirm it aligns with the ranked-FG default and the uniform mint model. |
| B5 | *new* `Parts/*` read proc — ranked eligible-FG list | **ADD** | Returns eligible FGs at the cell + `IsRecommended` per the ranked-default rule (decision 6). Backs the Assembly OUT dropdown. |
| B6 | *new* `Parts/*` read — "next unsatisfied route step" | **ADD** | Resolves a LOT's lowest-`SequenceNumber` route step with no matching `ProductionEvent`; feeds B1 and any destination logic. |
| B7 | `R__Workorder_MachiningOut_AutoComplete.sql` · `sql/migrations/versioned/0019_location_coupled_downstream_cell.sql` (`CoupledDownstreamCellLocationId`) · LogEventType `44` (MachiningOutAutoMoved) in `0027_arc2_phase5_machining.sql` · tests `0027…/040,050,060` | **DELETE** (Jacques: retire) | Retire the cell-resident auto-couple path entirely: drop the `MachiningOut_AutoComplete` proc, the `CoupledDownstreamCellLocationId` column (new versioned migration to drop it; leave 0019 immutable), the `MachiningOutAutoMoved` audit event, and the coupled/uncoupled AutoComplete tests. Its only purpose was the cell→cell auto-move, which §3.8 (line-resident mints) eliminates. Any future PLC-triggered *mint* is a separate concern, not this auto-move. |
| B8 | `R__Lots_Lot_Split.sql` + `Split` (`RelationshipTypeId=1`) | **REWORK scope** | Retain the proc, but remove its **standard-path** use (B3 stops emitting `Split`). Document as exception-only (quality/holds/logistics). Audit every `LotGenealogy` insert for correct `RelationshipTypeId`. |
| B9 | `sql/scratch/seed_demo.sql` | **REWORK** | Rename BOMs (step 3, `6MA-M←6MA-C`, `5G0-M←5G0-C`) **kept** but reinterpreted as SubAssembly production BOMs; rebuild the machining thread to mint at OUT via B3 (authentic casting→machined `Consumption`), removing the external `Lot_Create` of the machined LOT and the "not genealogy-linked" gap. Update comments (rename-hint lines ~150–156). |
| B10 | `sql/seeds/026_seed_machining_operation_templates.sql` | **REWRITE** | Comment still cites `MachiningIn_PickAndConsume`; repoint to `MachiningIn_RecordPick`. Confirm `RequiresSubLotSplit` seeding fits the new mint model (§4). |
| B11 | Old proc-name references `MachiningIn_PickAndConsume` (comments/tests in `R__Workorder_MachiningIn_RecordPick.sql`, `026_seed…`, `seed_demo.sql`, `0028…/077_…`, `0009…/060_…`) | **REWRITE** | Grep + scrub stale name; confirm no orphaned proc definition remains. |
| B12 | Tests — `0027_PlantFloor_Machining/*` (esp. `010`,`020`,`070`,`075`,`080`,`090`,`100`), `0028_PlantFloor_Assembly/*`, `0024_PlantFloor_Movement_Trim/060_Lot_GetWipQueueByLocation.sql`, `0021_PlantFloor_Lot_Lifecycle/020_Lot_Split.sql` | **REWORK / VERIFY** | Rewrite `Lot_GetWipQueueByLocation` assertions (drop `HasRenameBom`/`HasLineEvent`, assert route-driven queue); rewrite MachiningOut tests for consume-mint + `Consumption` genealogy; delete/mark AutoComplete tests (`040/050/060`) per B7; mark `Lot_Split` test exception-only. New tests per §9. |

### 5.2 Ignition — views, entity scripts, Named Queries

| # | File · symbol | Action | What |
|---|---|---|---|
| U1 | `…/ShopFloor/MachiningOutSplit/view.json` (line ~41 `not r.get("HasRenameBom")`; line ~21 `getCellsForDropdownByNamePrefix("Assembly")`) | **REWORK** | Delete the `HasRenameBom` filter; delete the hardcoded Assembly **destination dropdown** (§3.8 — mints are line-resident); repoint the queue to the route-driven read. This screen becomes the Machining OUT **mint** UI (operator qty, prefilled `DefaultSubLotQty`). |
| U2 | `Core/…/BlueRidge/Workorder/Machining/code.py` — `recordSplit()` / `autoComplete()` / `recordPick()` | **REWORK / VERIFY** | `recordPick()` already correct (advance). Rework `recordSplit()` → mint call (B3), returning new SubAssembly LOT id(s). `autoComplete()` fate tied to B7. |
| U3 | `…/ShopFloor/MachiningIn/view.json` | **VERIFY** | Repoint queue binding to route-driven read (B1); confirm no `HasLineEvent`/rename assumptions remain client-side. |
| U4 | `…/ShopFloor/AssemblyNonSerialized/view.json` (`selectedFinishedGoodItemId`, dropdown binding) + `Core/…/Workorder/Assembly/code.py` — `getEligibleFinishedGoodsForDropdown()`, `handleTrayComplete()`, `completeTray()` | **REWORK / ADD** | FG dropdown → bind to the ranked read (B5); default-select the recommended row; `handleTrayComplete()` falls back to top-ranked when none selected. Keep the ranking in SQL, not Python (house rule). |
| U5 | `Core/ignition/named-query/lots/Lot_GetWipQueueByLocation/query.sql` + `Core/…/BlueRidge/Lots/Lot/code.py::getWipQueueByLocation()` | **REWORK** | Mirror B1's result shape; the 6 consuming views (`MachiningIn`, `MachiningOutSplit`, `AssemblyIn`, `AssemblyNonSerialized`, `AssemblySerialized`, `TrimBody`) then filter by the route-driven fields instead of rename/type hints. |
| U6 | `Core/ignition/named-query/workorder/{MachiningOut_RecordSplit,MachiningIn_RecordPick,Assembly_CompleteTray}/query.sql` | **REWORK / VERIFY** | Track their procs (B3/B2/B4); update the MachiningOut NQ name/return shape if the proc is renamed to a mint. |
| U7 | *new* `Core/ignition/named-query/parts/…` — next-step + ranked-FG reads | **ADD** | NQ fronts for B5/B6. Per project topology, all NQs live in Core only. |
| U8 | `Core/…/Parts/Item/code.py`, `Core/…/Parts/Bom/code.py` | **VERIFY** | Grep for any `RenameBom`/split-at-machining-out client references; scrub if present. |
| U9 | `…/ShopFloor/TrimBody/view.json` + `Location/Location/code.py::getMachiningDestinationsForDropdown()` | **VERIFY** | Trim OUT keeps its cross-area destination pick (which Machining line) — that is a legitimate location-changing handoff, distinct from the intra-line mint (§3.8). Confirm unaffected. |
| U10 | `…/AssemblySerialized/view.json` + `Core/…/Workorder/AssemblyPlc/code.py` | **VERIFY** | Serialized/MIP path already `Consumption`-based; confirm alignment; no code change until commissioning. |

### 5.3 Documentation

| # | File · location | Action |
|---|---|---|
| D1 | `MPP_MES_FDS.md` — **FDS-06-007** (Machining IN rename) & **FDS-05-033** (Trim→Machining 1-line-BOM rename) | **REWRITE** — Machining IN is pure advance; the rename/consumption moves to the Machining OUT **mint**. Primary touchpoints. |
| D2 | `MPP_MES_FDS.md` — **FDS-06-008** (split / auto-couple), **FDS-05-009/-022/-024** (sublot-at-Machining-OUT), **FDS-05-032**, **FDS-06-006**, **FDS-06-020/021** (assembly genealogy), **FDS-01-013** (BOM cutover) | **REWRITE** — reframe split→mint, `Consumption`-only genealogy, sublot-as-exception, coupling fate (per §7 Q2), rename-BOMs-become-production-BOMs. |
| D3 | `MPP_MES_DATA_MODEL.md` — `CoupledDownstreamCellLocationId`, `Item.DefaultSubLotQty` (→ default mint qty), `OperationTemplate.RequiresSubLotSplit`, `ConsumptionEvent.ProducedLotId`, the §2 Trim→Machining narrative; add `OperationType` role-kind if adopted (§4.1) | **REWRITE** — reinterpret/relabel per the mint model; note `Split` demotion and BOM authoring rule. |
| D4 | `MPP_MES_USER_JOURNEYS.md` — 10:00am Machining scene + Machining-OUT path + UJ-03 decision; `MPP_MES_SUMMARY.md` — OI-11 notes; `PROJECT_STATUS.md` — proc list (`PickAndConsume`), reconciliation notes | **REWRITE** — narrate advance-at-IN / mint-at-OUT / `Consumption`-only. |
| D5 | `MPP_MES_TASK_LIST_PLANT_FLOOR.csv` (T103, T110, T111), `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` (Phase 5 Machining IN/OUT sections, proc signatures, test cases, OI-11) | **REWRITE** — retitle the `PickAndConsume` proc + drop the rename modal; align Phase 5 to the mint model. |
| D6 | `docs/superpowers/specs/2026-07-06-machining-in-unworked-arrivals-design.md` | **SUPERSEDE** — mark superseded by this spec (it is the intermediate half-unwound state that introduced `HasRenameBom`). |
| D7 | Prior specs referencing the old thread — `2026-07-02-machining-assembly-plant-floor-flow-design.md`, `2026-06-24-assembly-consumption-genealogy-design.md`, `2026-06-15-arc2-phase4-movement-trim-sql-design.md`, `2026-04-23-arc2-model-revisions.md`, `2026-05-20-item-master-boms-design.md` | **REWRITE / cross-ref** — annotate the stale rename-at-IN / 1-line-BOM references to point here. |
| D8 | Revision-history row on **every** edited doc (house rule) + this spec cross-referenced as the new baseline | **ADD** |

### 5.4 Scope note on the inventory

Items marked **VERIFY** are expected no-change confirmations (Machining IN, Assembly serialized/MIP, Container/Consumption procs, Trim OUT destination) — they are in the list so the plan proves them, not to imply edits. B7 (coupling) is now a firm **DELETE** per the resolved decisions (§7). The three **REWORK** cores are: **B1** (route-driven queue), **B3/U1/U2** (Machining OUT split→mint), and **U4/B5** (ranked FG default). `U2::autoComplete()` and the `MachiningOut_AutoComplete` NQ are deleted with B7.

---

## 6. Data-flow walkthroughs

**Full M&A line (Machining IN, OUT, Assembly IN, OUT):**
1. Casting LOT (200 pc) arrives at line, carrying its DieCast + Trim events. Next unsatisfied step = `MachiningIn` → **Machining IN queue**.
2. Operator picks it → advance: stamp machining `ProductionEvent`. Next unsatisfied step = `MachiningOut` → **Machining OUT queue**.
3. Operator mints 20 machined parts → derive SubAssembly (single BOM candidate), `Lot_Create` a 20-pc `6MA-M` LOT, `Consumption` edge (casting→machined), casting decrements to 180 (stays open, still in Machining OUT queue for the remainder). Repeat as desired.
4. The new `6MA-M` LOT's next unsatisfied step = `AssemblyIn` → **Assembly IN queue** (advance/verify).
5. `6MA-M` next step = `AssemblyOut` → **Assembly OUT queue**. Operator confirms FG (ranked default `6MA`), mints FG consuming `6MA-M` (+ `PIN-A`) per the FG BOM; `Consumption` edges; tray/FG completion.

**Sparse line (Machining IN + Assembly OUT only):**
1. Casting arrives → next step `MachiningIn` → **Machining IN queue**; advance stamps the machining event.
2. Casting's next step = `AssemblyOut` (no Machining OUT step authored) → **Assembly OUT queue**.
3. Operator mints FG (ranked default), consuming the **casting directly** per the FG BOM. No SubAssembly ever exists.

---

## 7. Decisions (resolved 2026-07-07) + remaining question

**Resolved by Jacques:**

1. **`OperationType` role-kind** — **ADD** the Advance/Mint classification (§4.1).
2. **`CoupledDownstreamCellLocationId` + cell-resident auto-couple** — **RETIRE** entirely (§5 B7).
3. **`Split` residual check** — **CONFIRMED**: no *standard* M&A step needs same-part `Split`; `Lot_Split` stays as an exception-only path (holds/quality/logistics) (§3.7).
4. **Origin-mint (Die Cast) scope** — **CONFIRMED** out of scope; the casting-birth path is unchanged here (§8).

**Still open — Q5, `ItemType` → role gating (scope):** Do we build the *guard-rail* that stops an engineer from authoring an illegal route — enforced in this effort, or deferred to a follow-up? See §4.2 for what the gate is; a recommended split (minimal structural validation now, full `ItemType`×role matrix later) is pending Jacques's call.

---

## 8. Out of scope / non-goals

- The Die Cast and Trim workflows themselves (only their route-step representation matters here).
- The Config-Tool route-step editor Category→Operation cascade UX (tracked separately in the 2026-07-06 working note; this spec assumes route authoring can express advance/mint sequences).
- Serialized-line PLC handshake internals (FDS-06-010) beyond aligning its consumption to the `Consumption`-only genealogy rule.
- Any change to holds / quality disposition behavior beyond confirming they are the `Split`/sublot exception home.

---

## 9. Testing strategy (design level)

- **Queue rule:** unit tests over `Lot_GetWipQueueByLocation` (rewritten) asserting a LOT appears at exactly the terminal whose role = its next-unsatisfied-step role, across full and sparse routes; a fully-satisfied LOT appears at its consume-mint terminal only.
- **Advance:** Machining IN stamps an event and creates/consumes nothing (piece counts and LOT count unchanged; the LOT's next step advances).
- **Consume-mint:** Machining OUT mint creates a new SubAssembly LOT of the operator quantity, decrements the casting, writes one `Consumption` edge + `ConsumptionEvent`, closes the casting only at zero; repeatable partial mints.
- **Derivation:** single-candidate auto-mint (machining); multi-candidate ranked default + override (assembly); ranked-default ordering (satisfied-lines desc, FIFO asc) including zero-match (1(c)) and multiple-match (2(b)).
- **Sparse line:** casting consumed directly into FG at Assembly OUT; no SubAssembly LOT created.
- **Regression:** no `HasRenameBom` references remain; `Split`/sublot not exercised on the standard path; genealogy chain (casting → machined → FG) is authentic and Honda-traceable.
- Full `Run-Tests` green.

---

## 10. Revision history

| Date | Author | Change |
|---|---|---|
| 2026-07-07 | Blue Ridge (with Claude) | Initial draft — terminal mint model, route-as-source-of-truth queue rule, rename-BOM removal, decision "C", BOM-derived mint targets, flexible quantity, `Consumption`-only genealogy, sublot demoted to exception. |
