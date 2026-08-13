# Machining OUT reject/defect capture — design (FAT-MACH-140)

**Date:** 2026-08-07
**Author:** Blue Ridge Automation
**FAT row:** FAT-MACH-140
**Brief:** `docs/handoffs/2026-08-07-fat-remediation-handoffs.md` § Brief C
**Status:** approved decision on scrap-decrement (Jacques, 2026-08-07) — see § Decisions

---

## 1. Mission & acceptance

Port the shipped **Trim OUT** multi-reason scrap feature onto **Machining OUT** so an
operator can enter one or more defect codes with reject quantities and, on submit, the
system writes **one `Workorder.RejectEvent` row per defect code** and reduces the scanned
casting's inventory by the scrap total.

**Acceptance (FAT wording):** operator enters ≥1 defect code with a reject qty and submits
→ a `RejectEvent` row per defect code used.

Machining currently captures **zero** defect data: `R__Workorder_MachiningOut_Mint.sql` and
`R__Workorder_MachiningIn_RecordPick.sql` write no rejects, and no Machining ShopFloor view
has a scrap surface.

## 2. Reference implementation (mirror this)

Trim OUT, shipped 2026-08-06 (`R__Workorder_TrimOut_Record.sql` v1.3):

- **Param:** `@ScrapLinesJson NVARCHAR(MAX) = NULL`, shape
  `[{"defectCodeId":<bigint>,"quantity":<int>}, ...]`.
- **Pre-txn validations** (`:106-157`): `ISJSON` guard → `OPENJSON` shred into a
  `@Scrap(DefectCodeId, Quantity)` table variable → `@ScrapTotal = SUM(Quantity)` →
  every `Quantity > 0` → every `DefectCodeId` exists and `DeprecatedAt IS NULL`.
- **In-txn inline fan-out** (`:351-355`): one `Workorder.RejectEvent` per line,
  `ProductionEventId = NULL`, `LotId = @ParentLotId`, LOT decremented **once** by
  `@ScrapTotal` in the move UPDATE (never per-line — avoids double-decrement).
- **NQ** `workorder/TrimOut_Record/query.sql` passes `@ScrapLinesJson = :scrapLinesJson`.
- **Entity** `Workorder/TrimOut/code.py:29` — `convertWrapperObjectToJson(scrapLines)`.
- **UI** `Components/PlantFloor/TrimEntry/ScrapLineRow` + `Views/ShopFloor/TrimBody`
  (repeater + `addScrapLine` / `recomputeGood` / handlers), dropdown bound
  `getForDropdown("TrimOut")`.
- **Tests** `sql/tests/0024_PlantFloor_Movement_Trim/050_TrimOut_Record_validation.sql`
  (multi-line → N rejects; invalid/deprecated → Status 0; non-positive → Status 0;
  malformed JSON → Status 0; empty/absent → zero rejects, no decrement).

## 3. Decisions (made — do not re-litigate)

1. **Scrap charges to `@SourceLotId`** (the scanned FIFO-handle casting LOT), with
   `ProductionEventId = NULL`, one `RejectEvent` row per defect line. (Brief.)
2. **Scrap decrements `@SourceLotId`** — `PieceCount` and `InventoryAvailable` are reduced
   by `@ScrapTotal`, mirroring Trim and die-cast semantics (scrapped castings leave
   inventory). (Jacques, 2026-08-07, resolving the multi-source-FIFO fork the brief left
   open.) The alternative — RejectEvent as a pure quality record with no decrement — was
   considered and **rejected**.
3. **Inline the RejectEvent write** — do **not** call the shared
   `Workorder.RejectEvent_Record`. Calling it would double-decrement (it decrements the
   LOT itself) and nest `INSERT-EXEC` (Msg 3915) inside this mutation proc. Mirror Trim's
   inline `INSERT … SELECT FROM @Scrap`.

## 4. The Machining-specific complication (why this is not a byte-for-byte port)

Trim OUT moves **one** LOT and decrements it **once**. Machining OUT is a **consume-mint**:
its "good" flow already decrements castings via a **multi-source FIFO walk** (`@Consumed =
QtyPer × PieceCount` castings, oldest-first across all eligible castings at the cell), and
it reports a fourth result column `@Available`. The proc is delicate (v2.2 no-negative
FIFO logic bounding each draw by `MIN(InventoryAvailable, PieceCount)`).

Scrap decrements `@SourceLotId` specifically, which is *also* (normally) a member of the
FIFO eligible pool. So scrap and consumption can both draw on `@SourceLotId`, and the
availability math must keep every casting `≥ 0`.

### 4.1 Non-negativity mechanics

- **Pre-txn guard (source covers scrap):** the scanned casting must hold at least the
  scrap total —
  `MIN(@SrcInventoryAvailable, @SrcPieceCount) >= @ScrapTotal`
  — else reject (`Status 0`, nothing written). This is the Machining analogue of Trim's
  combined-cap guard (`ShotCount + Scrap ≤ PieceCount`).
- **Availability accounts for scrap:** compute `@SrcEligible BIT` = is `@SourceLotId` in
  the FIFO eligible set (same predicate as `@TotalAvail`: Good/non-blocking, `InvAvail>0`,
  `PieceCount>0`, lowest-`SequenceNumber` pending route step = this MachiningOut ConsumeMint
  step). Then
  `@NetAvail = @TotalAvail - (CASE WHEN @SrcEligible = 1 THEN @ScrapTotal ELSE 0 END)`
  and the shortfall check, the reported `@Available = FLOOR(@NetAvail / @QtyPer)`, and the
  `@AllowPartial` reduction all use `@NetAvail` in place of `@TotalAvail`.
  (When `@SourceLotId` is not eligible — an unusual handle — scrap still decrements it via
  the guard above, but it never contributed to the pool, so it must not be subtracted.)
- **In-txn ordering:** immediately after `BEGIN TRANSACTION`, and **before** building the
  FIFO `@Queue` / minting / walking:
  1. Decrement `@SourceLotId` `PieceCount` and `InventoryAvailable` by `@ScrapTotal`.
  2. If that drives `@SourceLotId` `PieceCount` to `0`, close it (set `LotStatusId = Closed`
     + a `LotStatusHistory` row, mirroring the walk's close-on-zero — reason
     `'Closed by Machining OUT scrap (fully scrapped).'`).
  3. Fan out one `Workorder.RejectEvent` per `@Scrap` line
     (`ProductionEventId = NULL, LotId = @SourceLotId, Remarks = 'Machining OUT scrap'`).

  Because the FIFO walk reads each casting **lock-fresh** (`WITH (UPDLOCK, HOLDLOCK)`,
  bounded by `MIN(InvAvail, PieceCount)`) and `@Queue` is built after the scrap decrement,
  the walk naturally sees the post-scrap counts and can never over-draw. A casting the
  scrap step closed is excluded from `@Queue` (Good-status predicate).

### 4.2 What does NOT change

- The FIFO walk, per-casting `ProductionEvent` (`ShotCount = @take`, `ScrapCount = NULL`),
  `ConsumptionEvent`, `LotGenealogy(RelationshipTypeId=3)` + closure logic, and the mint
  naming (`<oldest-remaining-casting-LTT>-NN`) are untouched except that "oldest remaining"
  is naturally computed after the scrap decrement.
- Scrap is **not** written onto any `ProductionEvent.ScrapCount` — there is no single
  checkpoint event at Machining OUT; scrap lives entirely in `RejectEvent` (matches the
  `ProductionEventId = NULL` attribution model).

## 5. Layer-by-layer changes

### 5.1 SQL — `R__Workorder_MachiningOut_Mint.sql`

- New optional param `@ScrapLinesJson NVARCHAR(MAX) = NULL` (append to signature so the
  positional callers/tests keep working; add to `@Params` audit JSON as
  `LEFT(@ScrapLinesJson, 2000)`).
- Extend the `@SourceLotId` fetch (currently `@SrcItem, @SrcLoc, @Blocks, @SrcStatusCode`)
  to also select `@SrcPieceCount = l.PieceCount, @SrcInvAvail = l.InventoryAvailable`.
- Add pre-txn scrap parse + validations (mirror Trim) using the proc's existing
  `GOTO Reply` reject idiom (four-column result row incl. `@Available`):
  ISJSON; OPENJSON → `@Scrap`; `@ScrapTotal`; qty>0; DefectCode active; source-covers-scrap.
- Compute `@SrcEligible` and `@NetAvail`; use `@NetAvail` in the shortfall / `@Available` /
  partial branch.
- In-txn (right after `BEGIN TRANSACTION`): scrap decrement + close-if-0 + RejectEvent
  fan-out (§4.1).
- Extend the audit `@Activity` description to append scrap when present, e.g.
  `… Minted <pn> (<P> pcs, consumed <C> from <N> casting(s), scrapped <S> (<R> reason[s]))`,
  ASCII-only, via `Audit.ufn_TruncateActivity`. Optionally add `ScrapPieceCount` to
  `@NewValue` JSON for parity.
- Header comment: bump version, document the scrap addition + the decrement/availability
  rationale (§4).

### 5.2 NQ — `workorder/MachiningOut_Mint/query.sql`

Add `@ScrapLinesJson = :scrapLinesJson` to the `EXEC`. NQ stays `type:"Query"` (status-row
shape unchanged: `Status, Message, NewId, Available`).

### 5.3 Entity — `BlueRidge/Workorder/Machining/code.py`

`mint(...)` gains a `scrapLines=None` argument; JSON-encode it via
`BlueRidge.Common.Util.convertWrapperObjectToJson(scrapLines)` into
`params["scrapLinesJson"]` (mirror `TrimOut/code.py:29`). No domain logic added — thin glue
only. Auto-print-label behaviour after a successful mint is unchanged.

### 5.4 View — `Views/ShopFloor/MachiningOutSplit/view.json`

Direct port of the TrimBody scrap surface (single-lane `view.json` edit + `.\scan.ps1`):

- Custom props `scrapLines` (list) + `defectOptions` (dropdown options), pre-shaped
  defaults (`[]`) per the pre-declare-bound-custom-props rule.
- `defectOptions` bound to `getForDropdown("MachiningOut")` — resolves the
  `MachiningAssembly` defect category + plant-wide codes.
- A flex-repeater of `ScrapLineRow` (reuse the existing
  `Components/PlantFloor/TrimEntry/ScrapLineRow`, or clone to a
  `MachiningEntry/ScrapLineRow` if the page-message type strings must differ — decide during
  build; reuse preferred to avoid a duplicate component).
- The four handler methods ported from TrimBody: `addScrapLine`, remove-line,
  defect/qty change, and `recomputeGood` (if the Machining surface shows a good-count).
- Submit passes the assembled `scrapLines` into `Machining.mint(...)`.

### 5.5 Tests — `sql/tests/0027_PlantFloor_Machining/`

New file mirroring Trim's `050_*validation.sql`, e.g.
`080_MachiningOut_Mint_scrap.sql`, reusing the `070_MachiningOut_Mint.sql` fixture pattern
(casting `5G0-c`, SubAssembly `5G0-SA`, line `MA1-5GOF-MOUT`, pre-stamped past
DieCast/TrimIn/TrimOut/MachiningIn so next-pending = MachiningOut):

1. **Multi-line scrap** — 2 distinct active defect codes → mint succeeds, **2 RejectEvent
   rows** on `@SourceLotId`, all with `ProductionEventId IS NULL`.
2. **Decrement** — `@SourceLotId` `PieceCount`/`InventoryAvailable` reduced by `@ScrapTotal`
   (in addition to any consumption), never negative.
3. **Invalid/deprecated defect code** → Status 0, zero rejects, no decrement.
4. **Non-positive qty** (`0` and `-1`) → Status 0, "quantity must be positive".
5. **Malformed JSON** → Status 0, "not valid JSON", no decrement.
6. **Empty/absent `@ScrapLinesJson`** → mint succeeds, zero rejects, no scrap decrement
   (scrap-free Machining OUT unchanged — regression guard).
7. **Source-covers-scrap guard** — scrap total exceeding the scanned casting's
   `MIN(InvAvail,PieceCount)` → Status 0.
8. **Availability net of scrap** — with scrap on an eligible `@SourceLotId`, `@Available`
   and the shortfall check reflect `@TotalAvail − @ScrapTotal`.

FK-safe teardown mirrors `070` (delete `RejectEvent`/`ProductionEvent`/`ConsumptionEvent`/
genealogy/closure/movement/status-history before the LOTs; keep the seed BOM).

## 6. Out of scope

- `MachiningIn_RecordPick` scrap (Machining IN is a pure advance checkpoint; the FAT row is
  Machining OUT).
- The `Parts.ufn_OperationTemplateForLotRole` resolver convergence and the Assembly latent
  bugs (separate PROJECT_STATUS TODO).
- Any change to the shared `RejectEvent_Record` proc.

## 7. Constraints (CLAUDE.md)

FDS-11-011 (no OUTPUT params; the proc already ends every path with
`SELECT @Status, @Message, @NewId, @Available`; NQ `type:"Query"`). INSERT-EXEC / Msg-3915
(all rejects before `BEGIN TRANSACTION`; inline the RejectEvent write; the only `ROLLBACK`
is in `CATCH`). Audit Description convention + resolved-name FK JSON. No business logic in
Python. ASCII-only strings. Ignition file-edit boundary (view edit while Designer closed →
`.\scan.ps1`). Work on `jacques/working`, explicit staging. No new versioned migration
(repeatable proc + NQ + view + tests only).
