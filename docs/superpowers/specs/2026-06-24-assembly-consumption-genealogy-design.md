# Assembly Consumption + Genealogy — Design Spec

**Date:** 2026-06-24
**Author:** Blue Ridge Automation
**Status:** Draft — awaiting review
**Scope tag:** MVP (Arc 2 Phase 6, Assembly)

## 1. Problem

The production chain for a finished good is **cast → trim → machine → assemble**:

| Stage | Item | LOT behavior | Genealogy today |
|---|---|---|---|
| Cast | `5G0-C` (Component, "Front Cover Casting") | LOT born | — (origin) |
| Trim | `5G0-C` (same item) | `TrimOut_Record` just **moves** the LOT — no item change, no split, no edge | none (by design) |
| Machine | `5G0-MACH` (FinishedGood, "Machined Front Cover") | Machining-IN **renames** the source LOT into the machined item | ✅ `ConsumptionEvent` + `LotGenealogy` edge (source → machined) written by `MachiningIn_PickAndConsume` |
| Assemble | `5G0` (FinishedGood, "Front Cover Assembly") | Operator fills a container; `Container_Complete` claims AIM + mints a `ShippingLabel` | ❌ **none in the operator path** — no output LOT, no consumption, no edge |

So the **assembly stage is the unwired gap**. `Container_Complete` mints no output LOT, consumes no input material, and writes no genealogy. The tray-close gate added earlier only *checks* that the cell has enough parts (coarse, item-agnostic) — it does not decrement anything.

A separate **serialized** consumption API exists (`Workorder.Consumption.recordWithBomCheck` → `ConsumptionEvent_RecordWithBomCheck`, BOM-checked, ties to a `ContainerSerial`; `SerializedPart.ProducingLotId`) but it is **PLC/MIP-driven** (the `AssemblyPlc` entity) and not exercisable in dev. This spec covers the **operator-driven** path (the non-serialized fill), which is the testable gap.

### 1a. Data defects this surfaces

The seed BOMs model the wrong stages and must be corrected for a coherent chain:

- **Machining rename BOM** is `5G0-MACH ← 5G0` — should be `5G0-MACH ← 5G0-C` (machine the casting, not the finished good).
- **Assembly BOM** is `5G0 ← 5G0-C ×1 + PNA ×2` — should be `5G0 ← 5G0-MACH ×1 + PNA ×2` (assemble from the **machined** part + pins).

### 1b. Structural facts

- All genealogy is **LOT↔LOT** (`LotGenealogy.ChildLotId`, `ConsumptionEvent.ProducedLotId`, `SerializedPart.ProducingLotId`). A `Container` has **no** output-LOT column and `Container_Complete` mints none — so recording container-level genealogy requires giving the container an output LOT.
- `ConsumptionEvent_RecordWithBomCheck` and `LotGenealogy_RecordConsumption` both **return a status row** and are captured via `INSERT-EXEC`; therefore `Container_Complete` (itself a status-row proc) **cannot `EXEC` them** — their logic must be **inlined** (same rule that forces `Lot_Split`/`Lot_Merge` to inline sub-mutations). All rejecting validations run **before** `BEGIN TRANSACTION`; the `CATCH` is the only legal `ROLLBACK` site.
- Both finished goods in the seed (`5G0`, `RPY`) are **serialized**. There is **no non-serialized finished good**, so the operator-testable demo needs one defined (see Decision D1).

## 2. Goal

At `Container_Complete` (operator path), atomically: mint an **output LOT** for the container's finished-good item, **consume** the BOM-child material FIFO from the cell's open input LOTs (decrementing them), record `ConsumptionEvent` + `LotGenealogy` edges (child → output LOT), and link the container to its output LOT.

Resulting full trace: **`ShippingLabel → Container.OutputLotId (finished good) → [edge] machined LOT(s) → [machining edge] cast LOT`.**

Non-goals: changing the serialized/PLC path; redesigning trim; reworking the coarse tray-close gate (it stays as a cheap operator pre-check).

## 3. Design

### 3.1 Schema — migration `0030_arc2_p6_container_output_lot.sql`
- `ALTER TABLE Lots.Container ADD OutputLotId BIGINT NULL;`
- FK → `Lots.Lot(Id)`; filtered index on `OutputLotId WHERE OutputLotId IS NOT NULL`.
- No backfill (existing dev containers predate the feature).

### 3.2 `Container_Complete` (extend `R__Lots_Container_Complete.sql`)
Current proc validates open + full + claims AIM + mints `ShippingLabel` + flips status. Add, **before `BEGIN TRANSACTION`** (validation) and **inside the existing transaction** (mutation):

**Validation (pre-txn):**
1. Resolve the container item's **active published BOM** (`PublishedAt NOT NULL, DeprecatedAt NULL`). If none → reject `'No active BOM for <item>; cannot record assembly consumption.'`
2. For each BOM child line, compute `needed = QtyPer × @Target` and sum the cell's open LOTs of that child item. If any child is short → reject `'Insufficient <child> at cell to assemble container (<avail> of <needed>).'`

**Mutation (in-txn, after the AIM claim / ShippingLabel insert):**
3. **Mint output LOT** (inlined `Lot_Create`): `ItemId = container item`, `PieceCount = @Target`, `CurrentLocationId = cell`, `LotOriginTypeId = Production`, `LotName` from `IdentifierSequence_Next`; write the `LotStatusHistory` born-row + `LotMovement` (From=NULL) + `LotEventLog` mirror, exactly as `Lot_Create` does.
4. For each BOM child line, **FIFO-consume** `needed` from the cell's open child LOTs (oldest `CreatedAt` first): decrement `PieceCount`; when a LOT reaches 0 set status `Closed` + `LotStatusHistory`. For each source LOT touched, inline:
   - `INSERT Workorder.ConsumptionEvent (SourceLotId, ProducedLotId=outputLot, ConsumedItemId, ProducedItemId, PieceCount, LocationId, AppUserId, TerminalLocationId, ConsumedAt)`.
   - `INSERT Lots.LotGenealogy` consumption edge (child → output LOT) + B4 closure rows (mirror `LotGenealogy_RecordConsumption`).
5. `UPDATE Lots.Container SET OutputLotId = <outputLot>` (alongside the existing status/CompletedAt update).

Audit: existing `ContainerCompleted` event stays; the output LOT's creation + each consumption already emit their own `LotEventLog`/`ConsumptionEvent` records.

### 3.3 Entity / view
- `Container.complete` entity wrapper unchanged (same result shape; `OutputLotId` is internal).
- No view change required; the Non-Serialized screen's existing "Confirm Completion" drives it.

### 3.4 Seed (`smoke_seed_phase5_7.sql`)
- Correct the **machining rename BOM** → `5G0-MACH ← 5G0-C ×1`.
- Correct/define the **assembly BOM** → finished good `← 5G0-MACH ×1 + PNA ×2`.
- Define a **non-serialized finished good** for the operator demo (Decision D1) with a published BOM `← 5G0-MACH + PNA`, a non-ser `ContainerConfig`, and an open container at `MA1-COMPBR-AOUT`.
- Stage the **BOM-child input LOTs** (machined `5G0-MACH` + `PNA`) at that cell with qty ≥ `QtyPer × target`.
- Keep the existing coarse availability LOTs only as needed; the precise check now lives in `Container_Complete`.

### 3.5 Tests
- **New `0028/075_Container_Complete_consumes_bom.sql`**: open a non-ser assembly container, stage child LOTs, complete → assert (a) Status 1, (b) `OutputLotId` set + output LOT `PieceCount = target`, (c) each child LOT decremented by `QtyPer × target` (and closed if depleted), (d) one `ConsumptionEvent` + one `LotGenealogy` edge per consumed source LOT (child → output), (e) the genealogy tree from the output LOT reaches the machined + cast ancestors.
- **New rejection case**: stage a short child → complete rejects, container stays Open, **no** output LOT, **no** partial decrement (full rollback).
- **Update `040/050/060`**: their `P6-ASM-TEST` item now needs a published BOM + staged child LOTs at the cell, or they reject on the new BOM check.
- Re-run full suite; expect green except the known pre-existing `010_Parts_codes_crud`.

## 4. Open decisions (please confirm on review)

- **D1 — Non-serialized finished good for the demo.** Both real finished goods are serialized. Options: (a) define a representative non-ser finished good (e.g. `5G0-NS`, BOM `← 5G0-MACH + PNA`) purely for the operator-testable demo — recommended; (b) make an existing non-ser item (`6MA-HSG`?) a finished good with a BOM; (c) you provide the real non-ser finished-good part + BOM.
- **D2 — Upstream BOM corrections.** Fix the machining-rename (`5G0-MACH ← 5G0-C`) and assembly (`← 5G0-MACH`) BOMs in the seed now (recommended, for a coherent end-to-end trace), or leave them and only wire the assembly consumption against whatever BOM exists.
- **D3 — Tray-close gate.** Leave the coarse item-agnostic availability gate as a cheap pre-check (recommended), or replace it with the precise per-BOM-child check (then the precise check lives in two places).

## 5. Risks
- `Container_Complete` becomes a larger orchestrating proc; inlining (not `EXEC`-ing) the mint + consumption + genealogy is mandatory (INSERT-EXEC rule) and is the main implementation care-point.
- FIFO consumption across multiple partial child LOTs must decrement deterministically and close-at-zero without leaving negative `PieceCount`.
- Existing complete/ship tests assume a container with no BOM; they must gain a BOM + staged children or they regress (caught by the suite).
