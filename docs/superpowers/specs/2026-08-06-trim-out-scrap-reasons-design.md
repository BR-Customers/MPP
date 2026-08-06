# Trim OUT — defect-coded scrap reasons

**Date:** 2026-08-06
**Status:** Design (approved for planning)
**Author:** Blue Ridge Automation

## Problem

At Trim OUT the operator can record a scrap **quantity** but not a **reason**. The gap runs the full stack:

- **UI** (`TrimBody`): a single "Scrap count" number field, no defect-code dropdown.
- **Entity script** (`Workorder.TrimOut.record`): sends only `scrapCount`.
- **Proc** (`Workorder.TrimOut_Record` v1.2): `@ScrapCount` just subtracts from `Lot.PieceCount` and writes **no** defect-coded reject row.

So scrap at Trim OUT is invisible to quality/traceability — there is no defect breakdown, unlike Die Cast, which captures defect-coded scrap lines and writes `Workorder.RejectEvent` rows. Honda genealogy needs the reason, and operators hit real scrap at Trim OUT with nowhere to record it.

## Goal

Let a Trim OUT operator record **one or more defect-coded scrap lines** (reason + quantity) against the LOT being trimmed out, each producing a `RejectEvent` row for traceability and correctly decrementing the LOT, while the remaining good pieces move on to Machining as they do today.

## Approach

**Script-orchestration, reusing the existing `RejectEvent_Record` primitive — no `TrimOut_Record` proc change.** Chosen over extending the proc to keep the SQL surface small and reuse a proven, well-tested reject path. The tradeoff (non-atomicity across the reject + move sequence) is accepted and mitigated (see Edge cases).

UI is a **dynamic add-line** list of scrap rows (add/remove as needed), not a fixed row count.

## UI design (`TrimBody`)

Replace the single "Scrap count" field with a **dynamic scrap-lines section**.

**State** — the parent view owns the list:

- `view.custom.scrapLines`: `[]` — array of `{defectCodeId, quantity}` (default `[]`).
- `view.custom.defectOptions`: bound to `runScript("BlueRidge.Quality.DefectCode.getForDropdown", 0, "TrimOut")` — the Trim-category defect codes (+ plant-wide). Shared by every row (one binding, not one per row).

**Layout:**

- A flex **repeater** over `scrapLines`; each instance renders a small row component (reason dropdown + qty input + remove button).
- An **"+ Add scrap line"** button appends `{defectCodeId: null, quantity: ""}` to `scrapLines`.
- **Good (shotCount) auto-derives, read-only** = `lotPieceCount − Σ(scrapLines[].quantity)`, recomputed whenever a line changes (replaces today's single-field `onChange` derive).
- Scrap is optional — an empty `scrapLines` list is a clean whole-LOT trim out, exactly as today.

**Row component** (`BlueRidge/Components/PlantFloor/TrimEntry/ScrapLineRow`, new):

- Params (input-only): `index`, `defectCodeId`, `quantity`, and `defectOptions` (passed down so the row need not re-query).
- Reason dropdown (`props.options` ← `params.defectOptions`) + qty text/numeric input + remove (trash) button.
- Per the embed-params-input-only rule, the row does **not** write back through params. On change / remove it sends a **page-scoped** message to the parent:
  - `trimScrapLineChanged` `{index, defectCodeId, quantity}`
  - `trimScrapLineRemoved` `{index}`
- Parent `customMethods` handle those messages, mutate `view.custom.scrapLines` as a whole-array write, and recompute good.

**Pattern references:** the config-tool editable-list pattern (parent owns the array, rows message back — Routes/BOM step lists) and Die Cast `CavityLotRow` for the scrap-line shape. No drag-and-drop; scrap lines are unordered so no up/down arrows are needed — add and remove only.

## Backend flow (`Workorder.TrimOut.record`)

`submitTrimOut` (view) builds `scrapLines` from `view.custom.scrapLines` (dropping empty/zero rows) and passes them to `TrimOut.record`, which orchestrates:

1. **Rejects first** — for each scrap line with `quantity > 0`:
   `RejectEvent_Record(@LotId, @DefectCodeId, @Quantity, @OperationTypeCode='TrimOut', @AppUserId, @TerminalLocationId)`.
   Each call decrements `Lot.PieceCount` and writes the defect-coded reject row. `@ProductionEventId` is `NULL` (no trim checkpoint exists yet at this point — acceptable; the column is nullable).
2. **Move** — if good (`= lotPieceCount − Σscrap`) `> 0`:
   `TrimOut_Record(@ParentLotId, @OperationTemplateId, @ShotCount=good, @ScrapCount=NULL, @DestinationCellLocationId, @SourceLocationId, @AppUserId, @TerminalLocationId)` — records the closing checkpoint and moves the (now-decremented) LOT to Machining.

`TrimOut_Record` is **unchanged**; we simply stop passing `@ScrapCount` (rejects own the decrement now), so there is no double-subtraction. Rejects-first means the LOT carries its true remaining count into the Machining FIFO.

**Data shape into `TrimOut.record`:** the view derives `good` exactly as it derives `shotCount` today (`lotPieceCount − Σscrap`) and passes it, alongside the scrap lines:

```
{
  parentLotId, operationTemplateId,
  sourceLocationId, destinationCellLocationId,   # as today
  shotCount: good,                               # = lotPieceCount - Σscrap (view-derived, as today)
  scrapLines: [ {defectCodeId, quantity}, ... ]  # NEW; replaces the scalar scrapCount
}
```

## Edge cases & validation

- **Require a reason:** any line with `quantity > 0` must have a `defectCodeId`, and vice-versa. Client-gated before submit (toast + abort).
- **Σ scrap ≤ lotPieceCount** (so good ≥ 0). Client-gated; `RejectEvent_Record` also enforces server-side (PieceCount cannot go below zero). UI helper text updated from the old "lot count + scrap ≤ pieces" to "scrap cannot exceed the LOT's pieces; scrap is deducted from the LOT."
- **100% scrap** (good = 0): the rejects close the LOT at `PieceCount 0` (`RejectEvent_Record` sets `LotStatusCode 'Closed'`); the script **skips the `TrimOut_Record` move** (nothing goes to Machining) and toasts "LOT fully scrapped at Trim OUT — closed."
- **Non-atomicity (accepted tradeoff of script-orchestration):** rejects apply per-line before the move. On any mid-sequence failure the script stops, bumps `refreshToken` to re-read the LOT, and toasts "partially recorded — verify LOT." Mitigations: full client-side validation up front (reasons present, Σscrap ≤ pieces) and locking the submit button during execution make a mid-sequence failure unlikely. If full atomicity is later required, the fallback is to extend `TrimOut_Record` to take the scrap-lines JSON and inline the reject writes in one transaction.

## Testing

- **SQL** (`RejectEvent_Record` and `TrimOut_Record` already have suites): add a Trim-OUT-with-scrap integration test asserting, for a LOT of P pieces with scrap lines summing to S:
  - `Lot.PieceCount` decremented by S; one `RejectEvent` row per line with the right `DefectCodeId`/`Quantity` and Trim operation context;
  - the LOT moved to the Machining destination with `PieceCount = P − S`;
  - the closing `ProductionEvent` (`TrimOutRecorded`) recorded with `ShotCount = P − S`;
  - **100%-scrap** case: LOT `Closed`, no move, no `TrimOutRecorded` checkpoint.
- **Dropdown scope:** confirm `getForDropdown(0, "TrimOut")` returns Trim-category codes (140–145) + plant-wide, not the full ~155-code list. (Verify `Parts.OperationType.Code = 'TrimOut'` resolves to the Trim `OperationCategory`.)

## Files touched

- `ignition/projects/MPP/.../Views/ShopFloor/TrimBody/view.json` — scrap-lines section, `scrapLines`/`defectOptions` custom props, add-line + message-handler customMethods, good-derive, updated `submitTrimOut`.
- `ignition/projects/MPP/.../Components/PlantFloor/TrimEntry/ScrapLineRow/` — **new** row component (+ `resource.json`).
- `ignition/projects/Core/.../script-python/BlueRidge/Workorder/TrimOut/code.py` — `record` accepts `scrapLines`, orchestrates `RejectEvent_Record` per line then `TrimOut_Record`.
- `sql/tests/...` — new Trim-OUT-with-scrap integration test.

## Out of scope

- Extending `TrimOut_Record` (atomic proc path) — fallback only.
- Scrap reasons at other steps (Trim IN, Machining, Assembly) — this spec is Trim OUT only.
- Any change to Die Cast scrap (already defect-coded).
