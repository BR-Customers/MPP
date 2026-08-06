# Multi-reason scrap capture on Trim OUT

**Date:** 2026-08-05
**Author:** Blue Ridge Automation
**Status:** Approved — ready for implementation plan
**Relates to:** FAT #2. Depends on #1 (defect codes scoped by `OperationCategory` — shipped).

## Problem

Trim OUT captures scrap as a **single count** (`view.custom.scrapCount` → `Workorder.TrimOut_Record
@ScrapCount`), which decrements the LOT but records **no reason**. FAT #2: capture **multiple scrap
reasons** on Trim OUT, each with a quantity, with the reason list **filtered to Trim-shop defect
codes**. The die-cast Record Shift Output already does exactly this (per-LOT `scrapLines[]` →
`Workorder.RejectEvent` rows); Trim OUT should follow the same rails, with the twist that Trim scrap
is **subtractive** (it decrements the LOT) whereas die-cast scrap is additive.

## Decisions (locked)

1. **Reasons replace the bare count.** Scrap on Trim OUT is captured as zero-or-more
   `{defectCodeId, quantity}` lines. When scrap > 0, **at least one reason line is required**.
2. **RejectEvents are attribution; the LOT decrement is a single aggregate.** One
   `Workorder.RejectEvent` row per scrap line (per-reason reporting), and the LOT's
   `PieceCount`/`InventoryAvailable` decrement **once** by the *sum* of line quantities — NOT per-line
   via `RejectEvent_Record` (which would double-decrement). Mirrors `DieCastShiftOutput_Record`'s
   inlined reject inserts (INSERT-EXEC / single-result-set safe).
3. **`@ScrapCount` is replaced by `@ScrapLinesJson`.** The total scrap is derived internally as the
   sum. `TrimOut_Record` is called only from `TrimBody`, so the signature change is contained.
4. **Reason list scoped to Trim** via the #1 infrastructure: `getForDropdown("TrimOut")` → Trim
   category + plant-wide.

## Change surface

### 1. `Workorder.TrimOut_Record` (repeatable proc)
Replace `@ScrapCount INT = NULL` with `@ScrapLinesJson NVARCHAR(MAX) = NULL`
(`[{ "defectCodeId": <bigint>, "quantity": <int> }, ...]`). Keep all other params/behavior.

- **Parse + derive** (before `BEGIN TRANSACTION`): shred `@ScrapLinesJson` via `OPENJSON` into a temp
  table `(DefectCodeId BIGINT, Quantity INT)`; `@ScrapTotal INT = ISNULL(SUM(Quantity), 0)`.
- **Pre-transaction rejecting validations** (all before `BEGIN TRANSACTION`, per FDS-11-011 / Msg-3915):
  - `@ScrapLinesJson` (when non-null) must be valid JSON (`ISJSON`); malformed → clean Status=0.
  - Every line `Quantity > 0`; every `DefectCodeId` exists and is active in `Quality.DefectCode`
    (mirror `DieCastShiftOutput_Record` v1.1's pre-txn defect-code check → clean Status=0, no in-txn
    FK RAISERROR).
  - Existing combined-count guard, now against the sum: `ISNULL(@ShotCount,0) + @ScrapTotal ≤
    Lot.PieceCount`.
  - Existing D1 monotonic + not-blocked + source-location + already-in-Trim-Storage (FAT #22) guards
    unchanged; the ScrapCount monotonic check (if any) is dropped in favor of the per-event model.
- **Inside the transaction** (inline, not EXEC — mirrors the die-cast reject inserts):
  - Insert one `Workorder.RejectEvent (ProductionEventId, LotId, DefectCodeId, Quantity, ChargeToArea,
    Remarks, AppUserId, RecordedAt)` per scrap line. `ProductionEventId` = the Trim OUT checkpoint's
    id if that ordering is convenient, else NULL (attribution is by LotId + Trim OUT context; decide at
    build time and document).
  - Decrement `Lot.PieceCount`/`InventoryAvailable` by `@ScrapTotal` once (replacing today's
    `@ScrapCount` decrement), under the existing `UPDLOCK/HOLDLOCK`.
  - Closing `ProductionEvent` checkpoint + whole-LOT move to Trim Storage: unchanged (the checkpoint's
    `ScrapCount` column, if written, carries `@ScrapTotal`).
- Audit `TrimOutRecorded` Description notes scrap total + reason count.

### 2. NQ + entity script
- `workorder/TrimOut_Record` NQ: swap `:scrapCount` → `:scrapLinesJson` (String), update `resource.json`.
- `BlueRidge.Workorder.TrimOut.record`: accept `scrapLines` (list of `{defectCodeId, quantity}`) in
  `data`, `system.util.jsonEncode` it to `scrapLinesJson`; drop `scrapCount`.

### 3. UI — `TrimBody` (Designer, existing view)
- Replace the single **Scrap count** field (`ScrapField` / `ScrapCountInput` / `view.custom.scrapCount`)
  with a **scrap-lines repeater**: `view.custom.scrapLines = [{defectCodeId, quantity}]`; each row a
  Trim-scoped reason dropdown (`getForDropdown("TrimOut")`) + quantity input + a remove (up/down not
  needed) button; an **+ Add scrap reason** button; a **Total scrap** label = `Σ quantity`.
- `submitTrimOut` builds `data["scrapLines"]` from `view.custom.scrapLines` (dropping blank rows) and
  calls `TrimOut.record`. Reset clears the repeater. Keep the "Lot count + scrap together cannot
  exceed the LOT's pieces; scrap is deducted from the LOT" helper text.
- Reuse the die-cast reject-line UI conventions (a small embedded row view + flex-repeater) where they
  exist, to stay consistent.

### 4. Tests — extend `sql/tests/0024_PlantFloor_Movement_Trim/050_TrimOut_Record_validation.sql`
- Multi-line scrap: N lines → N `Workorder.RejectEvent` rows for the LOT, and `Lot.PieceCount`
  decremented by exactly `Σquantity` (one aggregate, not N×).
- Invalid/deprecated `defectCodeId` in a line → Status=0, no rows written.
- `shots + Σscrap > PieceCount` → Status=0; boundary (`= PieceCount`) passes.
- Empty/absent `@ScrapLinesJson` → succeeds, zero RejectEvents, no decrement (scrap-free Trim OUT).
- Non-positive quantity in a line → Status=0.

## Out of scope
- Die-cast scrap (already multi-reason).
- Machining/Assembly scrap surfaces (future; same pattern when built).
- Reason-code taxonomy — reuses the #1 defect codes + Trim category filter as-is.

## Verification
On a throwaway DB: a Trim OUT with two scrap reasons (e.g. `140` Stuck Media ×3, `144` White-Rust ×2)
against a 20-piece LOT records two RejectEvent rows and leaves the LOT at 15 pieces at Trim Storage;
the Trim OUT screen's reason dropdown lists only Trim + plant-wide codes; a scrap line with a die-cast
code is not selectable (filtered out).
