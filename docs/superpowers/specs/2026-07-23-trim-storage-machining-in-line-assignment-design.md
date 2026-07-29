# Design Spec — Decouple line assignment from Trim: route all trimmed parts through a neutral Trim Storage; Machining IN assigns the line

**Date:** 2026-07-23
**Author:** Blue Ridge Automation
**Status:** Draft for review
**Arc / Phase:** Arc 2 — Plant Floor (Trim / Phase 4 tail + Machining IN / Phase 5)
**Related:**
- `docs/superpowers/specs/2026-07-07-terminal-mint-model-and-rename-bom-removal-design.md` (route = source of truth; `OperationRoleKind`)
- `docs/superpowers/specs/2026-07-06-machining-in-unworked-arrivals-design.md` (unworked-arrivals pick model)
- `docs/superpowers/specs/2026-06-15-arc2-phase4-movement-trim-sql-design.md` (Trim OUT whole-LOT move)
- CLAUDE.md §"Terminal-mint model", §"Line-resident M&A flow", §"Operation-template resolution"

---

## 1. Summary

Today, **Trim OUT is where the machining line is chosen.** The operator picks a "Destination (Machining line)" from a dropdown and the trimmed LOT is moved directly onto that specific line's `WorkCenter` location; Machining IN then reads its FIFO queue at that same line. This forces the line decision at Trim, before anyone at Machining knows which line will actually have capacity — and it does not match the physical reality confirmed at the customer meeting: **trimmed parts physically stage in a storage area first, and the line is decided when a machine pulls them.**

This spec moves the line-assignment decision downstream:

1. **Trim OUT becomes line-neutral.** The destination dropdown is **removed**. Every trimmed LOT is checked out into a single, neutral **Trim Storage** location. Trim OUT is re-scoped from "close + route to line X" to "**check N lots into Trim Storage**."
2. **Machining IN reads from Trim Storage, filtered by line eligibility.** Each line's Machining IN screen shows the LOTs sitting in Trim Storage whose part is **eligible at that line**. A part eligible for two lines naturally appears in **both** lines' queues; the first line to claim it wins. No special-case branch.
3. **Claiming a LOT at Machining IN moves it from Trim Storage onto the line** (a `LotMovement`), which is exactly what removes it from every other line's Trim-Storage-filtered queue — the concurrency guard falls out of the location model for free.
4. **Relabel:** the Trim checkout counter reads **"lot count"** (count of LOTs checked into Trim Storage) instead of "shot count."

The route model (terminal-mint, `OperationRoleKind`) is unchanged and already supports this: after Trim OUT records its `TrimOut` Advance checkpoint, a casting's next pending route step is `MachiningIn`, so it correctly surfaces in a `MachiningIn`-role queue read regardless of *where* it physically sits. We only change **which location** Machining IN reads (line → Trim Storage) and add an **eligibility filter** to that read.

---

## 2. Locked decisions (from the customer meeting — not re-litigated here)

- **CONFIRMED physical reality:** trimmed parts physically stage in a storage area before moving to a line.
- **UNIFORM model:** ALL trimmed parts are checked out at Trim OUT into a single Trim Storage location. Trim OUT no longer picks a line/destination; the destination dropdown is REMOVED.
- **Machining IN** reads inventory FROM Trim Storage, filtered to the parts ELIGIBLE at that line. The one part eligible for two lines appears in both lines' queues; whichever line claims it first takes it. **No special-case branch.**
- **RELABEL:** the Trim checkout count reads "lot count" instead of "shot count."

Everything below implements these; where the meeting left a mechanism unspecified (single vs per-area storage, claim = move, exact filter placement), this spec resolves it with a recommendation and flags it in §11.

---

## 3. Current-state summary (as-built, ground truth from code)

### 3.1 Trim OUT — `Workorder.TrimOut_Record` (v1.2) + `TrimBody` view

- **Proc** (`sql/migrations/repeatable/R__Workorder_TrimOut_Record.sql`): takes `@ParentLotId, @OperationTemplateId, @ShotCount, @ScrapCount, @DestinationCellLocationId, @SourceLocationId, @AppUserId, @TerminalLocationId`. It:
  1. Validates the destination exists and the **item is eligible at the destination** (`Parts.v_EffectiveItemLocation`, ancestor-cascade).
  2. Guards a **combined `ShotCount + ScrapCount ≤ Lot.PieceCount`** cap and cumulative-monotonic counters.
  3. Writes a closing `Workorder.ProductionEvent` (the `TrimOut` Advance checkpoint) against the whole LOT.
  4. **Moves the whole LOT** to `@DestinationCellLocationId` (a production **line**), decrementing `PieceCount`/`InventoryAvailable` by `@ScrapCount`. No split.
  5. Audits `TrimOutRecorded`.
  - Source-location guard (`@SourceLocationId`) blocks double-checkout: the LOT must sit at/under the Trim zone; after checkout it sits at the line, so a re-scan rejects.
- **View** (`.../ShopFloor/TrimBody/view.json`): two-state (`Check IN` / `Trim OUT`). The OUT panel has a **`DestDropdown`** ("Destination (Machining line)") bound to `custom.destCells` ← `getMachiningDestinationsForDropdown(activeLotId, refreshToken)`; a **shot count** field (prefilled from the selected LOT's `PieceCount`, auto-decrement on scrap via the `scrapCount` onChange), a scrap count field, and a `Trim OUT` button calling `submitTrimOut()`. `submitTrimOut` resolves the `TrimOut` template by role, requires a `destValue`, and posts `parentLotId, operationTemplateId, shotCount, scrapCount, destinationCellLocationId, sourceLocationId`.
- **Inventory** (`custom.trimInventory`): `getWipQueueByLocation(zoneLocationId, includeDescendants=true)` — every open LOT residing at/under the terminal's Trim zone (the route-role split was tried in `6e1c0f19` then reverted in `0f9b278b`; current behavior is "LOTs residing in the shop").

### 3.2 Machining IN — `Workorder.MachiningIn_RecordPick` (v1.0) + `MachiningIn` view

- **Proc** (`sql/migrations/repeatable/R__Workorder_MachiningIn_RecordPick.sql`): takes `@LotId, @LineLocationId, @AppUserId, @TerminalLocationId`. It:
  1. Resolves the `MachiningIn` OperationTemplate off the LOT's route (route-aware by role).
  2. **Requires the LOT to currently sit at/under the LINE** (`@LineLocationId`, ancestor walk) — step 4. This is the guard that must change.
  3. Requires the terminal to sit at/under the line.
  4. Writes ONE `MachiningIn` checkpoint `ProductionEvent` against the SAME LOT (no new LOT, no consumption, no move). Audits `MachiningInPicked`.
- **View** (`.../ShopFloor/MachiningIn/view.json`): `custom.queue` ← `getWipQueueByLocation(cell.locationId, includeDescendants=true, refreshToken, "MachiningIn")`, where `session.custom.cell.locationId` is bound (onStartup) to the terminal's parent **line** (`zoneLocationId`). Row tap → `machiningPick` → confirm popup → `bomRenameResult` → `Machining.recordPick(sourceLotId, cellId, ...)`. (Note: the view still carries legacy "BOM-Driven Rename" copy in labels; that mechanism is already retired — cosmetic only.)

### 3.3 Route-driven queue — `Lots.Lot_GetWipQueueByLocation` (v3.0)

Returns the open LOTs at `@LocationId` (optionally descendants) whose **lowest-`SequenceNumber` pending route step** carries role `@OperationTypeCode`. Pending is per `OperationRoleKind`: `Advance` (pending until a matching `ProductionEvent`), `OriginMint` (never pending), `ConsumeMint` (pending while open). **There is no item-eligibility filter in this proc today** — it is purely location + route-role. After Trim OUT's `TrimOut` checkpoint, a casting's next pending step is `MachiningIn`, so it qualifies for a `"MachiningIn"` read at whatever location it sits.

### 3.4 Eligibility model

- **`Parts.v_EffectiveItemLocation`** (migration `0020`): `(ItemId, LocationId, Source)` from two legs UNION'd — `Direct` (a `Parts.ItemLocation` row) and `BomDerived` (child line on a parent's active published BOM, where the parent is Direct-eligible). Raw configured pairs; the **ancestor-tier cascade** (Cell → WorkCenter → Area → Site) is applied by *callers* via `Location.ufn_AncestorLocationIds(@Loc)`.
- **`Parts.ItemLocation_CheckEligibility(@ItemId, @LocationId)`** — advisory read returning `IsEligible, Path`, ancestor-cascade. Eligibility is authored at **Area + WorkCenter tiers** (`Location_ListForEligibilityPicker` v1.1; terminals/printers excluded).
- The "one part eligible for two lines" case = an item with eligibility rows (Direct or BomDerived) resolving at **two different `WorkCenter` lines**.

### 3.5 Location model

- **`Location.LocationType`** — 5 fixed ISA-95 tiers (read-only): Enterprise(0) / Site(1) / Area(2) / WorkCenter(3) / Cell(4).
- **`Location.LocationTypeDefinition`** — 16 seeded kinds (CRUDable). Relevant: `ProductionArea`(3, Area), `SupportArea`(4, Area), `ProductionLine`(5, WorkCenter), `Terminal`(7, Cell), `TrimPress`(10, Cell), `InventoryLocation`(14, Cell), `Printer`(16, Cell).
- **`Location.Location`** — adjacency list. Real plant seeded by `sql/seeds/011_seed_locations_mpp_plant.sql`.
- **Existing storage precedent:** `WHSE` (Warehouse, `SupportArea` DefId 4, parented at the `MPP-MAD` Site) — "WIP / cast storage — all die cast goes here prior to Trim"; die-cast LOTs already auto-deposit there (`Lot_Create @DepositToStorage`). `SHIPIN` / `SHIPOUT` are sibling `SupportArea`s. This is the direct model for a Trim Storage location.
- Trim shops: `TRIM1` / `TRIM2` (`ProductionArea`) each with a shared `Terminal` and `TrimPress` cells. Machining lines: `MA1-*`, `MA2-*` `ProductionLine` WorkCenters, each with a `Machining In` (and other) `Terminal` cells.

---

## 4. Trim Storage location model

### 4.1 What it is

A neutral staging **Area** where all trimmed LOTs land at Trim OUT and from which every Machining IN line draws. It parallels `WHSE`: a `SupportArea` (Area tier) under the `MPP-MAD` Site.

- **`LocationTypeDefinition`:** reuse **`SupportArea`** (DefId 4). No new type kind is needed — Trim Storage is a support/staging area exactly like Warehouse/Shipping. (Do **not** invent a new DefId unless the customer wants Trim-Storage-specific attributes.)
- **Tier:** Area (`HierarchyLevel = 2`), so eligibility and ancestor walks behave predictably and it never collides with the WorkCenter-tier line queues.

### 4.2 Single facility-wide vs one per area/building — **RECOMMENDATION: single facility-wide** (flagged, §11-Q1)

- **Recommended:** ONE facility-wide `TRIMSTORE` Area under `MPP-MAD`. Rationale: the whole point of the change is a *neutral* buffer decoupled from any particular trim shop or machining building; a single location makes "eligible at this line" the *only* filter that matters and keeps the two-lines-share-a-part behavior trivially uniform. It mirrors `WHSE` (also single, facility-wide).
- **Alternative (per-area):** `TRIMSTORE-A` / `TRIMSTORE-B` if the plant physically stages trimmed parts near each machining building and a line should only see its building's buffer. This is a **data/config choice, not a schema choice** — the same code supports N storage locations if the read/claim procs accept a `@StorageLocationId` (or resolve it from config) rather than hard-coding one. **Recommend building the code to accept a storage-location parameter** so single vs per-area stays a seeding decision, and default to the single facility-wide instance.

### 4.3 Seeding

Add to `sql/seeds/011_seed_locations_mpp_plant.sql` (and regen source `gen_locations_mpp.js` if used), in the `=== Storage ===` block next to `WHSE`:

```sql
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIMSTORE')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 4, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'),
           N'Trim Storage', N'TRIMSTORE', N'Neutral staging for trimmed LOTs prior to Machining IN line assignment', 12;
```

`Reset-DevDatabase.ps1` re-runs seeds, so Dev picks it up; cutover adds it via the standard location-config path. **`TRIMSTORE` must exist before Trim OUT can run** — add a config-existence guard (see §7.1).

### 4.4 How Trim Storage interacts with eligibility

Trim Storage is a neutral buffer — **items are NOT made eligible at `TRIMSTORE`.** Eligibility stays authored at the machining lines (WorkCenters) and areas, exactly as today. The Trim OUT deposit into `TRIMSTORE` therefore must **drop the destination-eligibility gate** (there is no line to check yet). The eligibility check moves entirely to Machining IN (read filter + claim gate), which is the whole intent of the feature.

---

## 5. Changed Trim OUT flow + UI

### 5.1 Proc — `Workorder.TrimOut_Record` v2.0

**Behavior:** "check this LOT into Trim Storage" — same closing checkpoint + whole-LOT move + scrap decrement, but the destination is **always Trim Storage**, chosen by the proc, not the operator.

Changes vs v1.2:
- **Remove `@DestinationCellLocationId`** from the signature (or keep it optional and ignored — see migration-compat note). The destination is resolved internally:
  ```sql
  DECLARE @TrimStoreId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIMSTORE' AND DeprecatedAt IS NULL);
  IF @TrimStoreId IS NULL  -- reject: Trim Storage not configured
  ```
  (If per-area storage is chosen in §11-Q1, resolve `@TrimStoreId` from the Trim zone's configured storage instead — but keep it a single lookup the operator never sees.)
- **Drop the destination-eligibility gate** (step 5 in v1.2): Trim Storage is neutral; there is no line to check. Retain the destination-exists guard against `@TrimStoreId`.
- **Keep** the source-location double-checkout guard, the combined `ShotCount + ScrapCount ≤ PieceCount` cap, the cumulative-monotonic guard, the scrap decrement, and the `TrimOut` closing `ProductionEvent` (still needed so the route advances to `MachiningIn`).
- Audit description changes from "OUT to <line>" to "OUT to Trim Storage."

**Counter semantics unchanged at the row level** — the `TrimOut` `ProductionEvent` still records `ShotCount`/`ScrapCount` for that LOT. The "lot count" relabel (§5.3) is a **screen-level** rename of what the operator sees, not a change to per-LOT counters. See §8 / §11-Q4.

> INSERT-EXEC / Msg-3915 discipline is preserved verbatim from v1.2 (all rejects before `BEGIN TRANSACTION`, inlined mutations, CATCH-only rollback).

### 5.2 UI — remove the destination dropdown

In `.../ShopFloor/TrimBody/view.json`, OUT panel (`OutFormCol`):
- **Delete** the `DestField` container (`DestLabel` + `DestDropdown`) and the `custom.destValue` / `custom.destCells` custom props + their bindings (`getMachiningDestinationsForDropdown`).
- **`submitTrimOut()`** drops the `dest` resolution + null-check and the `destinationCellLocationId` payload key. It now posts only `parentLotId, operationTemplateId, shotCount|lotCount, scrapCount, sourceLocationId`.
- Panel copy: "Trim OUT — close + route" → "**Trim OUT — check into Trim Storage**"; "Whole-LOT move — no split at Trim." stays; the "choose the production line" sub-copy is removed.
- The `Location.getMachiningDestinationsForDropdown` script wrapper + `Location.Location_ListMachiningDestinations` proc become **unused by Trim** (leave the proc in place; it may still serve reporting/other callers — verify with a usage grep before deleting, §7).

### 5.3 UI — "lot count" relabel

The OUT panel's count field label changes from **"Shot count"** to **"Lot count"** and its help text is reworded. **Two interpretations** (resolve in §11-Q4):
- **(A) Pure relabel (recommended, lowest-risk):** the field still captures the same per-LOT good-piece number that feeds the `TrimOut` `ProductionEvent`; only the visible label/word changes ("Lot count" as the customer's term for the checked-out quantity). No proc change to counting.
- **(B) True count-of-LOTs:** if the customer means Trim OUT should batch-check *multiple* LOTs at once and display "N lots checked in," that is a **multi-select batch checkout** — a larger change (multi-row select in the OUT pick list, a loop/set-based proc, a returned `LotsChecked` count). Recommend deferring (B) unless the meeting explicitly wanted batch checkout; ship (A) now.

The header/prefill logic (`resolveOutScan`, `trimLotSelected` handler) that prefills `shotCount = PieceCount` is retained under whichever interpretation; rename the `custom.shotCount` prop to `custom.lotCount` only if doing a clean pass (cosmetic; keep the DB param name stable to avoid churn).

---

## 6. Changed Machining IN queue + claim

### 6.1 Queue read — filter Trim Storage by line eligibility

**Problem:** `Lot_GetWipQueueByLocation` reads by location + role but has **no eligibility filter**. Reading `TRIMSTORE` with role `MachiningIn` would return *every* trimmed LOT in storage — not just the ones this line can run. We need "at Trim Storage, next-pending = MachiningIn, **AND eligible at THIS line**."

**RECOMMENDATION (flagged §11-Q3):** add a dedicated read proc rather than overloading the generic queue proc, because the eligibility predicate is line-specific and the generic proc is called from many screens:

**New proc `Lots.Lot_GetTrimStorageQueueForLine`**
```
@LineLocationId     BIGINT,          -- the machining line (WorkCenter) this terminal serves
@StorageLocationId  BIGINT = NULL    -- Trim Storage; NULL => resolve TRIMSTORE by code
```
Returns the same column shape as `Lot_GetWipQueueByLocation` (so the view's row transform is unchanged): open LOTs whose `CurrentLocationId` is at/under `@StorageLocationId`, whose lowest-`SequenceNumber` pending route step has role `MachiningIn`, **and** whose `ItemId` resolves in `Parts.v_EffectiveItemLocation` at `@LineLocationId` or any ancestor (`ufn_AncestorLocationIds`). Ordered FIFO by arrival (`LotMovement.MovedAt ASC`).

Implementation = `Lot_GetWipQueueByLocation`'s v3.0 `NextStep`/pending logic, with `@LocationId := @StorageLocationId, @IncludeDescendants := 1, @OperationTypeCode := 'MachiningIn'`, plus one extra `AND EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation eil WHERE eil.ItemId = l.ItemId AND eil.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@LineLocationId)))`.

> Alternative considered: add an optional `@EligibleAtLocationId` param to `Lot_GetWipQueueByLocation`. Rejected as the default recommendation because it complicates a proc consumed by Trim/Assembly/inventory reads; a separate, purpose-named proc keeps the concern isolated. Either is acceptable — call out in review.

### 6.2 Claim — move from Trim Storage onto the line, then checkpoint

**`Workorder.MachiningIn_RecordPick` v2.0** changes the location guard and adds a move:

- **Step 4 guard flips:** the LOT must currently sit **at/under Trim Storage** (`@StorageLocationId`, resolve `TRIMSTORE` by code if not passed), **not** at/under the line. If the LOT is no longer at Trim Storage → reject "already claimed by another line" (this is the concurrency loser's message).
- **Re-validate eligibility (authoritative gate):** `Parts.v_EffectiveItemLocation` for the LOT's item at `@LineLocationId` (ancestor cascade), mirroring the read filter — never trust the client. Reject "not eligible at this line" if absent.
- **New mutation (inside the txn, before the checkpoint):** an inlined whole-LOT move `TRIMSTORE → @LineLocationId` (mirror of `Lot_MoveTo`): update `Lot.CurrentLocationId = @LineLocationId`, insert a `LotMovement (from=storage, to=line)`. This is the **claim**: once the LOT sits on Line A it is gone from Trim Storage, so §6.1's storage-filtered read for Line B no longer returns it.
  - **Forward-only guard:** the move is Trim Storage → line, which is forward on the route; reuse `Lot_MoveToValidated`'s operation-aware forward-only predicate (commit `2260b2bb`) or inline the equivalent so a mis-scan can't move it backward.
- **Keep** the existing `MachiningIn` route-template resolution + the `MachiningIn` checkpoint `ProductionEvent` (now the LOT is on the line, and its next pending step advances past `MachiningIn`).
- Terminal-at/under-line guard: keep.

Net: **one atomic proc** does claim-move + checkpoint. The audit gains the move (or emit both `LotMoved` and `MachiningInPicked`; recommend a single `MachiningInPicked` whose `NewValue` includes the from/to locations to stay one-event-per-pick).

### 6.3 Machining IN view rebinding

In `.../ShopFloor/MachiningIn/view.json`:
- `custom.queue` binding: `getWipQueueByLocation(cell.locationId, ...)` → **`getTrimStorageQueueForLine(cell.locationId, ...)`** (new script wrapper `BlueRidge.Lots.Lot.getTrimStorageQueueForLine`), where `cell.locationId` remains the terminal's line (`zoneLocationId`). The row transform is unchanged (same columns).
- The pick path (`machiningPick` → confirm → `recordPick`) is unchanged at the call site; `recordPick` now performs the claim-move server-side. Consider dropping the legacy "BOM-Driven Rename" confirm copy (cosmetic).
- Subtitle/queue copy: "Whole cast/trim LOTs moved here at Trim OUT (1:1)…" → "Trimmed LOTs staged in Trim Storage, filtered to parts this line can run. Pick to claim onto this line."
- `custom.activeMachined` (reads `MachiningOut` role at the cell) is unrelated and unchanged.

---

## 7. SQL surface

### 7.1 New

| Object | Kind | Purpose |
|---|---|---|
| `TRIMSTORE` location seed | seed row in `011_seed_locations_mpp_plant.sql` | The neutral Trim Storage Area (SupportArea, under MPP-MAD). |
| `Lots.Lot_GetTrimStorageQueueForLine` | repeatable proc | Trim-Storage LOTs, next-pending = MachiningIn, eligible at the line. Read proc: no status row (FDS-11-011). |
| `lots/Lot_GetTrimStorageQueueForLine` | Named Query (Core) | Ignition access to the read proc (`type: Query`). |

### 7.2 Changed

| Object | Change |
|---|---|
| `Workorder.TrimOut_Record` → v2.0 | Destination = Trim Storage (resolved internally); drop `@DestinationCellLocationId` (or ignore); drop destination-eligibility gate; add TRIMSTORE-exists reject; audit copy. |
| `Workorder.MachiningIn_RecordPick` → v2.0 | Location guard flips line → Trim Storage; add eligibility re-validation at line; add inlined forward-only claim-move Trim Storage → line inside the txn; audit copy. |
| `workorder/TrimOut_Record` NQ + `BlueRidge.Workorder.TrimOut.record` | Drop `destinationCellLocationId` from the param map. |
| `workorder/MachiningIn_RecordPick` NQ + `BlueRidge.Workorder.Machining.recordPick` | Unchanged signature (line + terminal); server now claim-moves. Optionally pass an explicit `@storageLocationId` if per-area storage (§11-Q1). |

### 7.3 Possibly retired (verify usage first)

- `Location.Location_ListMachiningDestinations` + `lots`/`location` NQ + `BlueRidge.Location.Location.getMachiningDestinationsForDropdown` — Trim no longer calls these. **Grep for other callers** before removing; if only Trim used them, deprecate (leave proc, delete the dropdown binding). Do not delete blindly.

### 7.4 Migration-compat note

`TrimOut_Record` is captured via `INSERT … EXEC` by its tests. Changing its parameter list is safe (repeatable proc, `CREATE OR ALTER`) but **all callers and test fixtures must update together** in the same commit. If you prefer zero call-site churn, keep `@DestinationCellLocationId BIGINT = NULL` in the signature and simply ignore it — but recommend removing it for clarity since the concept is gone.

---

## 8. Ignition surface

- **`TrimBody/view.json`:** remove `DestField`/`DestDropdown`, `custom.destValue`, `custom.destCells` + binding; edit `submitTrimOut()` (drop dest); relabel "Shot count" → "Lot count" + help copy; panel headers. (Existing-view edit → Designer, per the file-edit boundary; or careful file edit + `scan.ps1` on the new-prop deletions.)
- **`MachiningIn/view.json`:** rebind `custom.queue` to the new wrapper; update queue/subtitle copy; optionally strip legacy rename copy.
- **Core scripts:** add `BlueRidge.Lots.Lot.getTrimStorageQueueForLine` (thin wrapper, mirrors `getWipQueueByLocation`); edit `BlueRidge.Workorder.TrimOut.record` param map. `BlueRidge.Workorder.Machining.recordPick` unchanged unless passing storage id.
- **No new components.** `Trim/InventoryRow`, `Machining/QueueRow`, `MovementScan` unchanged (the Trim IN scan-in path that stages castings into the Trim shop is untouched).
- After any resource change: `.\scan.ps1` (memory: gateway scan required; no restart).

---

## 9. Edge cases

1. **The two-line part (uniform, no branch).** An item eligible at both Line A and Line B has one LOT in Trim Storage. §6.1's read returns it in **both** queues (each read filters by its own line's eligibility, both match). First claim (§6.2) moves it onto its line; the other line's next read no longer sees it (it's no longer at Trim Storage). Uniform behavior — no special case.
2. **Concurrent claim race.** Two terminals tap the same LOT within the same instant. The claim proc's move is inside a transaction; the **second** transaction re-reads `CurrentLocationId` and finds it no longer at Trim Storage (or the row-versioned guard fails) → rejects with "already claimed by another line." Recommend an explicit re-check of `CurrentLocationId = @StorageLocationId` *inside* the txn under `UPDLOCK` (or a conditional `UPDATE … WHERE CurrentLocationId = @StorageLocationId` and check `@@ROWCOUNT`) so the loser gets a clean rejection, never a double-move. (Mirror the `TrimOut_Record` source-guard idea, but re-assert it transactionally.)
3. **LOT held/blocked while in Trim Storage.** A Hold placed after Trim OUT: the read proc already filters `LotStatusCode <> 'Closed'` and the claim proc keeps the `BlocksProduction` guard, so a held LOT is not claimable until released. It still *appears* greyed if the view chooses to show holds (as the current queue does via `holdCount`).
4. **Part eligible at NO line.** A trimmed LOT whose item has no machining-line eligibility sits in Trim Storage and appears in **no** Machining IN queue → stranded. Surface it on a supervisor/inventory view (out of scope here) or flag as config error. Note in §11-Q5.
5. **Scrap at Trim OUT.** Unchanged — scrap still decrements the LOT before it lands in storage; the stored quantity is the real remaining count.
6. **Re-scan / double checkout at Trim OUT.** The source-location guard still blocks: after checkout the LOT sits at Trim Storage (not the Trim zone), so a second OUT from the Trim terminal rejects.
7. **Fallback terminal.** A machining terminal on an unregistered IP has `zoneLocationId` = the whole Facility. §6.1 filters by eligibility at that (Facility) location → cascade would match broadly and the queue would over-list. Mitigation is the existing terminal-context fix (subtitle "Madison Facility" is the tell); the read proc should treat a non-WorkCenter `@LineLocationId` defensively (e.g. return empty or the view guards on a real line). Flag §11-Q6.
8. **Per-area storage (if chosen).** If §11-Q1 goes per-area, a line must read the correct storage instance; resolve storage from the line's building/config, and Trim OUT must deposit into the storage matching the Trim shop. The single-instance recommendation avoids this entirely.

---

## 10. Phased TDD implementation plan

Serial, on `jacques/working`. SQL is TDD (write failing test → proc → green); Ignition is file-author/Designer + `scan.ps1`. Validate against a throwaway `MPP_MES_Test` (never destructively reset Dev).

**Phase 0 — Seed + fixtures**
- Add `TRIMSTORE` to `011_seed_locations_mpp_plant.sql` (+ regen source if applicable). Extend the SQL test fixtures (routes/eligibility) so at least one item is eligible at two lines (the two-line case) and the plant has `TRIMSTORE`.
- Verify `Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Test -SkipDemoSeed` builds clean with the new location.

**Phase 1 — Trim OUT v2.0 (deposit to Trim Storage)**
- Tests (`sql/tests/0024_PlantFloor_Movement_Trim/…`): happy path deposits the LOT at `TRIMSTORE` (assert `CurrentLocationId`), writes the `TrimOut` checkpoint, decrements scrap; reject when `TRIMSTORE` missing; **no** destination param needed; double-checkout still blocked; combined-cap + monotonic guards still hold. Update `050_TrimOut_Record_validation.sql` (drop destination-eligibility assertions).
- Implement `TrimOut_Record` v2.0. Green.

**Phase 2 — Machining IN read (Trim-Storage + eligibility filter)**
- Tests: `Lot_GetTrimStorageQueueForLine` returns a trimmed LOT for a line it's eligible at; returns it for **both** lines when eligible at both; excludes a LOT not eligible at the line; excludes LOTs not at Trim Storage; excludes closed/pre-TrimOut LOTs; FIFO order. (Extend `0027_PlantFloor_Machining` or `0024`.)
- Implement the read proc + Core NQ. Green.

**Phase 3 — Machining IN claim v2.0 (claim-move + eligibility gate + race)**
- Tests: pick moves the LOT `TRIMSTORE → line` (assert `CurrentLocationId` + `LotMovement`), writes the `MachiningIn` checkpoint; **second** pick of the same LOT (now on a line) rejects "already claimed"; pick of a LOT not eligible at the line rejects; forward-only guard holds; held LOT rejects. Simulate the race via the transactional re-check (`@@ROWCOUNT` on the conditional move).
- Implement `MachiningIn_RecordPick` v2.0. Green. **Run the full suite** on `MPP_MES_Test`.

**Phase 4 — Ignition rebinding**
- `TrimBody`: remove destination dropdown + props, edit `submitTrimOut`, relabel "Lot count" + copy.
- `MachiningIn`: rebind queue to `getTrimStorageQueueForLine`, copy.
- Core scripts: add `getTrimStorageQueueForLine`; edit `TrimOut.record` param map. `scan.ps1`.

**Phase 5 — Designer smoke + cleanup**
- Smoke: Trim OUT checks a LOT into Trim Storage (no line picker); the LOT appears at Machining IN on every eligible line; claiming on one line removes it from the other; the two-line part behaves; scrap decrement; double-checkout block.
- Grep + retire/deprecate `Location_ListMachiningDestinations` if Trim was its only caller. Update FDS-06-006 / FDS-05-xxx prose (Trim OUT no longer routes to a line) + Data Model notes. Regenerate docs.

---

## 11. Open questions (with recommendations)

- **Q1 — Single facility-wide Trim Storage vs one per area/building?** *Recommend: single facility-wide `TRIMSTORE`* (mirrors `WHSE`; makes eligibility the only filter; keeps the two-line case trivial). **Build the read/claim procs to accept a `@StorageLocationId` so per-area stays a pure seeding decision** if the customer later wants it. Needs the customer's confirmation of physical staging layout.
- **Q2 — Does "claim" = a `LotMovement` from Trim Storage onto the line?** *Recommend: yes.* The move is the mechanism that removes the LOT from every other line's queue (no extra locking scheme needed for the common case), and it matches the physical act of a machine pulling the basket. Confirmed as the design here; flag only if the customer wants LOTs to *stay* in storage and be logically (not physically) assigned.
- **Q3 — Where is the line-eligibility filter applied?** *Recommend: both* — in a **new read proc** `Lot_GetTrimStorageQueueForLine` (so operators only see runnable parts) **and** re-validated in the **claim proc** (authoritative, never trust the client). Open sub-question: new proc vs an `@EligibleAtLocationId` param on `Lot_GetWipQueueByLocation` — recommend the new proc to keep the shared queue proc simple.
- **Q4 — "Lot count" vs "shot count": relabel only, or true count-of-LOTs (batch checkout)?** *Recommend: (A) pure relabel now* (visible word changes; per-LOT `ProductionEvent` counters unchanged), and treat **(B) multi-LOT batch checkout** as a separate follow-up only if the meeting actually meant "check several LOTs into storage in one action." Needs the customer to confirm which they meant.
- **Q5 — Trimmed part eligible at NO machining line = stranded in Trim Storage.** How should this surface? *Recommend:* a supervisor/inventory view over Trim Storage residents with no eligible line (out of scope for this spec) or a config-lint. Confirm desired handling.
- **Q6 — Fallback / non-line terminal at Machining IN.** With eligibility filtering by the terminal's `zoneLocationId`, a fallback terminal (zone = Facility) would over-list. *Recommend:* the read proc returns empty unless `@LineLocationId` resolves to a real WorkCenter, and the view guards on a bound line (leaning on the existing terminal-context fix). Confirm acceptable.
- **Q7 — Retire `Location_ListMachiningDestinations`?** Pending a usage grep; retire the Trim binding regardless, deprecate the proc only if no other caller.
```
