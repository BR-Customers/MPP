# Machining OUT — Multi-Source FIFO Consume

**Date:** 2026-07-21
**Status:** Draft (design approved; pending spec review → implementation plan)
**Scope tag:** MVP (Plant Floor / Arc 2)
**Author:** Blue Ridge Automation

---

## 1. Problem

`Workorder.MachiningOut_Mint` consumes castings from a **single** `@SourceLotId` to mint a machined SubAssembly LOT. Two problems surfaced (2026-07-21, Jacques testing):

1. **The over-consume safeguard fails.** Requesting more sub-assemblies than the selected casting has drove the casting's `PieceCount` **negative** (`000000005` → −6, `000000007` → −2) instead of being stopped. A LOT must never be drivable below zero.
2. **No FIFO roll-over.** When the oldest casting is nearly empty, the operator expects the mint to draw the remainder from the **next same-part casting** in the FIFO queue. The proc has no such logic — it only ever draws from the one selected casting.

The correct behavior unifies both: consume across the FIFO queue oldest-first, bounded so nothing goes negative, minting **one** sub-assembly LOT that traces back to **every** casting it drew from.

## 2. Confirmed behavior

Operator requests **N** sub-assemblies at a Machining-OUT terminal:

- Walk the FIFO queue of **same-part castings at that cell, strict oldest-first** (the operator's "Select" highlight is informational only — consumption is always oldest-first, for Honda traceability).
- Consume `QtyPer × N` casting pieces total, draining the oldest casting, then rolling into the next as each empties.
- Each **fully-drained casting Closes**; the last partially-consumed casting stays Good with its remainder.
- Mint **one** SubAssembly LOT of N, named after the **oldest** consumed casting's LTT + `-NN`.
- The minted LOT carries **one `ConsumptionEvent` + one Consumption genealogy edge + closure ancestors per source casting** — so a sub-assembly built from 2 castings has 2 parents in its trace. **Traceability is mandatory.**
- **No casting ever goes negative** — each casting's draw is bounded by its own live available pieces, re-read under the row lock.

**Shortfall (queue can't cover N):**
- Default (`@AllowPartial = 0`): consume nothing, reject, and **return the available count** `@Available` (the max producible = `floor(totalAvailable / QtyPer)`).
- The Machining-OUT view shows a **popup** — *"Only M available — mint M?"* — whose button **re-submits with `@AllowPartial = 1`**, minting `floor(available / QtyPer)` (partial). If not even one sub-assembly is producible (`available < QtyPer`), reject even with `@AllowPartial = 1`.

## 3. Proc redesign — `Workorder.MachiningOut_Mint`

**New / changed parameters:**
- `@SourceLotId` becomes the **FIFO handle** — it identifies the cell (`CurrentLocationId`) and the casting part (`ItemId`) and drives produced-part derivation, but consumption is strict oldest-first across **all** eligible castings at that cell, not just this lot.
- `@AllowPartial BIT = 0` (new) — controls the shortfall path (§2).

**Result shape:** the status row gains a 4th column — `SELECT @Status, @Message, @NewId, @Available` (`@Available` = max producible sub-assemblies given the current queue; lets the UI build the shortfall popup without a second query). **Blast radius of the extra column:** the `INSERT-EXEC` temp-table shapes in every test that captures this proc, the `BlueRidge.Workorder.Machining.mint` wrapper + its auto-print tail (reads `NewId`), and the NQ mapping all read a 3-column result today — each must be updated to the 4-column shape (or the wrapper must tolerate the extra key).

**FIFO source set (the queue the walk consumes):** Good-status LOTs of `ItemId = @SrcItem` at `@SourceLotId`'s location, ordered oldest-first by `CreatedAt`. This MUST match the set the terminal's FIFO queue displays (`Lots.Lot_GetWipQueueByLocation`) — align the exact location scoping (cell vs line/descendants) to that proc at implementation (§7).

**Consumable per casting:** `InventoryAvailable` (respects any in-process). Because `InventoryAvailable ≤ PieceCount`, bounding each draw by it guarantees `PieceCount` cannot go negative. `totalAvailable = SUM(InventoryAvailable)` across the queue.

**Flow:**
1. **Pre-transaction validations (no open txn):** required params; `@PieceCount > 0`; OperationTemplate is a ConsumeMint role; source LOT exists / not blocked / not Closed; derive `@ProducedItemId` (published BOM whose child = `@SrcItem`, parent line-eligible) + `@QtyPer` (as today). Compute `@Consumed = QtyPer × @PieceCount`. Sum `totalAvailable`. If `totalAvailable < @Consumed`:
   - `@AllowPartial = 0` → reject; set `@Available = floor(totalAvailable / QtyPer)`; message *"Only … available."*; return.
   - `@AllowPartial = 1` → set `@PieceCount = floor(totalAvailable / QtyPer)` and `@Consumed = QtyPer × @PieceCount`. If `@PieceCount = 0` → reject (nothing producible).
2. **Transaction:**
   - Mint the SubAssembly LOT of `@PieceCount`, name = oldest-casting-LTT + `-NN` (the `-NN` derivation stays as in the current proc, keyed on the oldest casting's LotName).
   - **FIFO walk:** iterate the eligible castings oldest-first. For each, re-read its `InventoryAvailable`/`PieceCount`/status **under `UPDLOCK, HOLDLOCK`** (serializes concurrent mints; provides the fresh bound). Draw `take = MIN(remaining_needed, casting.InventoryAvailable)`; decrement its `PieceCount` and `InventoryAvailable` by `take`; if it reaches 0 pieces, Close it (+ `LotStatusHistory`). Write one `Workorder.ProductionEvent` (MachiningOut checkpoint, `ShotCount = take`), one `Workorder.ConsumptionEvent` (source → produced), one `Lots.LotGenealogy` Consumption edge (RelationshipTypeId = 3), and closure ancestors from this casting → minted LOT. Subtract `take` from `remaining_needed`; stop when it hits 0.
   - If the walk cannot satisfy `remaining_needed` from the lock-fresh queue (a concurrent mint consumed pieces between the pre-txn sum and the lock) → `RAISERROR` → CATCH → rollback → clean Status 0 (retry). This is the concurrency guard.
   - Audit (`MachiningOutCompleted`); subject = minted LOT; NewValue lists the source castings + per-casting quantities.
3. **INSERT-EXEC safety:** all rejecting validations before `BEGIN TRANSACTION`; sub-mutations inlined; CATCH is the only `ROLLBACK` site; `RAISERROR` not `THROW`; no OUTPUT params.

**Never-negative guarantee:** every draw is `MIN(needed, casting.InventoryAvailable)` against the lock-fresh row, so no casting's `PieceCount` can cross zero. This is the safeguard the earlier single-source proc lacked.

## 4. UI — Machining-OUT view

- Submit calls the mint (as today). On **Status 0 with a shortfall** (message/`@Available` indicating the queue is short), open a confirm **popup**: *"Only M available — mint M?"* with **Mint M** / **Cancel**. **Mint M** re-calls the mint with `@AllowPartial = 1`. Reuse the existing popup pattern (`ConfirmDestructive` / `ConfirmUnsaved` style) rather than a bespoke dialog.
- Keep the client thin — no consumption math in Python; the proc returns `@Available` and does the partial computation.

## 5. Genealogy / traceability

A sub-assembly minted from K castings has **K** `LotGenealogy` Consumption edges (one per casting) and K `ConsumptionEvent` rows (each with the per-casting `PieceCount` drawn), plus closure rows linking every ancestor of every source casting to the minted LOT. Backward trace from the machined LOT reaches all its source castings (and through them, their die-cast provenance). This is a hard requirement.

## 6. Scope

**In scope:** `Workorder.MachiningOut_Mint` rework + the Machining-OUT view shortfall popup + tests.

**Out of scope (flagged):**
- `Workorder.Assembly_CompleteTray` consumes components/sub-assemblies similarly and would want the same FIFO multi-source treatment — **separate follow-on**, not built here.
- **Data repair** of the corrupted `000000005` (−6) and `000000007` (−2) is a separate surgical task (§8).

## 7. Implementation verification points
- The exact FIFO **location scoping** (cell vs line/ancestors, and the pending-step predicate) must match `Lots.Lot_GetWipQueueByLocation` so the mint consumes exactly the set the terminal displays.
- Confirm the historical **`InventoryAvailable` vs `PieceCount` divergence** on `000000005` (InvAvail 0, PieceCount −6) was a symptom of the old un-bounded decrement (not a separate bug); the new per-casting-bounded walk should keep them consistent. Verify on a throwaway repro.
- `ProductionEvent.ShotCount` semantics per casting (pieces drawn from that casting) — confirm against how die-cast/other ProductionEvents populate ShotCount.
- The `-NN` suffix derivation keyed on the **oldest** casting's LotName (reuse the current suffix logic).

## 8. Data repair (separate task)
`000000005` (−6) and `000000007` (−2) hold inconsistent negative counts + phantom sublots from the pre-fix testing. Surgical repair: void the over-consuming sublot(s) + their genealogy, and reset each casting to a consistent, non-negative state. The exact target state (which sublots are legitimate vs phantom) to be confirmed with Jacques before running the repair.

## 9. Testing
- **FIFO across two castings:** queue of 18 (oldest) + 30, mint 24 → draws 18 from the oldest (Closes it) + 6 from the next (stays Good at 24); minted LOT has 2 Consumption parents; oldest is Closed.
- **Exact fit:** mint == oldest casting's pieces → single parent, oldest Closes, no roll-over.
- **Shortfall reject:** queue total 20, mint 24, `@AllowPartial = 0` → Status 0, `@Available = 20`, nothing consumed.
- **Partial mint:** same shortfall, `@AllowPartial = 1` → mints 20, drains the queue, all consumed castings Closed.
- **Not-even-one:** queue total 0 (or < QtyPer), `@AllowPartial = 1` → reject.
- **Never negative:** no casting's PieceCount < 0 in any path.
- **Strict oldest-first:** consumption order is by `CreatedAt` regardless of `@SourceLotId`.
- **Regression:** the existing single-casting `070_MachiningOut_Mint` scenarios (partial mint, close-at-zero, over-mint reject, Consumption-not-Split, `-NN` naming, counter-not-advanced) still hold.

## Revision History

| Date | Change | Author |
|---|---|---|
| 2026-07-21 | Initial design — multi-source FIFO consume at Machining OUT (strict oldest-first, per-casting-bounded no-negative safeguard, partial-on-confirm shortfall, multi-parent genealogy). | Blue Ridge Automation |
