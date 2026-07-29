# Die Cast LOT: Per-Cavity Open / Accumulate / Release Lifecycle — Design Spec (v2)

**Date:** 2026-07-28
**Author:** Blue Ridge Automation
**Status:** Draft for review (design artifact only — no code/SQL/view changes in this pass).
**Arc / Phase:** Arc 2 (Plant Floor) — Die Cast (was Phase 3).
**Supersedes:** `docs/superpowers/specs/2026-07-23-diecast-lot-open-accumulate-release-design.md`. That draft was walked through segment-by-segment with Jacques on 2026-07-28; **four of its assumptions were wrong** and are corrected here (see §1.1). Keep the 2026-07-23 file as history; this v2 is the authority.
**Affects:** `R__Lots_Lot_Create.sql` die-cast path, `DieCastBody` view + `DieCastEntry` components, `R__Lots_Lot_GetShiftCavityTally.sql`, `R__Lots_Lot_GetWipQueueByLocation.sql`, `R__Workorder_RejectEvent_Record.sql` (verify only), `R__Lots_Lot_GetAttributeHistory.sql`.

---

## 1. Purpose

Redesign die-cast entry from a **one-basket-per-create origin mint** into a **per-cavity LOT open → accumulate → release lifecycle**, where each cavity of a mounted die owns an independent accumulating basket that fills across operators and shifts and is released to storage (its first route movement) when full.

### 1.1 Corrections to the 2026-07-23 draft (locked this session)

| Draft assumption (2026-07-23) | Corrected decision (this spec) |
|---|---|
| **Q1: one accumulator LOT per *die*** (cavity on the event) | **One open LOT per (die, cavity).** A 16-cavity die has **16 open LOTs / 16 LTTs**. Cavity stays a **LOT-level** attribute via the existing `Lot.ToolCavityId` FK. |
| **Q5: basket ceiling is a HARD reject** | **Soft warning.** `Item.MaxLotSize` is the ceiling; on overflow the operator continues via auto-fill / close-and-open-next / continue — never blocked. |
| **§4.5: change `RejectEvent_Record` to suppress auto-close when `Open`** | **Unnecessary — dropped.** Die-cast scrap is **additive** (0042, `ScrapIsAdditive=1`): the reject records but does **not** decrement `PieceCount` and **never** auto-closes. Verified in the proc. |
| **Q3: extend `Workorder.ProductionEvent` with delta columns** | **New dedicated `Workorder.DieCastContribution` table.** A contribution is not a route/production event; a purpose-built ledger is cleaner for the history view, the shift breakdown, and the new dashboard, with zero blast radius on the shared `ProductionEvent`. |

Confirmed as recommended: **Q2** new `Open` `LotStatusCode`; **Q6** LTT assigned at open (pre-printed, scanned); **Q7** `TotalInProcess = 0` during accumulation; **Q4** one-open guard, adapted to **per (tool, cavity)**.

---

## 2. The model (locked)

### 2.1 Lifecycle

```
scan pre-printed LTT
      │
      ▼
  ┌────────┐  record shift output (shots)   ┌────────┐  release (full basket)   ┌────────┐
  │  OPEN  │ ─────────────────────────────▶ │  OPEN  │ ───────────────────────▶ │  GOOD  │ ──▶ route (Trim IN…) ──▶ Closed
  │ pc = 0 │   accumulate good, record scrap │ pc = N │   move cell → storage     │at WHSE │
  └────────┘                                 └────────┘                          └────────┘
      │
      └── void (empty basket, operator, warned) ──▶ Scrap
```

- **Granularity: one open LOT per (Tool, Cavity).** Cavity is stamped on the LOT via the existing `Lot.ToolCavityId` FK (kept — it is already load-bearing in the tally). Each cavity's basket is **independent in inception and closure**; LOTs from the same die do not open or close together.
- **Open** = scan **one pre-printed basket LTT** → open **one** cavity LOT (status `Open`, `PieceCount = 0`). **One open LOT per (tool, cavity) at a time.**
- **Accumulate** = record shift output (§3). The basket holds **good** parts; `PieceCount` grows by net good.
- **Release** (the "close") = move the basket **cell → storage**, flipping `Open → Good`. This is the LOT's **first route movement** — it then surfaces in the Trim IN queue. Release carries a final good + scrap entry for that basket.
- **Void** = an operator may void **their own empty basket** (an `Open` LOT with a scanned LTT, `PieceCount = 0`), with a warn → Continue/Cancel confirm; `Open → Scrap`, freeing the cavity/LTT.

### 2.2 `Open` status

Add a fifth `Lots.LotStatusCode`: **`Open`** (`BlocksProduction = 0`), appended Id (1–4 unchanged). Semantics: the LOT exists and accumulates at the press but is **not on its route**. Single status-keyed gate across every consumer (queue, move, contribute, release), matching the existing `LotStatusCode`-keyed guards including `Lot_AssertNotBlocked`. The WIP queue excludes it (`sc.Code NOT IN ('Closed','Open')`), so an accumulating basket never surfaces to Trim prematurely.

---

## 3. Shift-output entry (the accumulate action) — Shape 1

The operator reads the machine HMI shot count at (or after) end of shift and enters output at the die-cast terminal. **The entry is time-decoupled** — available any time — but is *reported against a shift* (§3.3).

### 3.1 Screen shape (Shape 1 — die-wide, cavity-lot rows)

One screen, driven by the **mounted die**:
- A single **gross shot count** entry (die-wide — one machine cycle = one part in every cavity), entered **once**.
- A body listing every **open cavity-lot** as a row (plus any lot **closed mid-shift** for a cavity, pre-populated from its close — §3.4). Each row shows: cavity, computed **good** (beside the gross), and a **scrap flex repeater** for that cavity.
- A **"Register shot loss"** button (§3.2).
- Delta entry (increment), never cumulative.

### 3.2 Arithmetic (basket = good; scrap additive)

Per cavity, for the reporting shift:

```
good(cavity) = grossShots − shotLosses − Σ scrap(cavity)
```

- **`grossShots`** — the die-wide HMI shot count (same for every cavity).
- **`shotLosses`** — whole-shot losses logged via the **Register shot loss** button (a lost cycle produced no good part in *any* cavity: short shot, cold shot, etc.). N shot losses fan **N scrap across every active cavity's open lot** (each with the shot-level defect reason).
- **`scrap(cavity)`** — per-cavity scrap rows: **{ reason (`Quality.DefectCode`), quantity }**. Cavity is **implied by the lot row** (no cavity picker). Multiple rows per cavity allowed.
- **The basket receives `good` only** (decision A). Scrap is recorded **additively** in `Workorder.RejectEvent` (die-cast `ScrapIsAdditive = 1`, already built) for yield/defect metrics — it never decrements `PieceCount`, so there is no double-subtraction. The gross is shown for reference beside the computed good.

The operator never does subtraction: they enter gross + itemize scrap/losses; the screen computes and displays good; the system persists good as the contribution.

### 3.3 Shift reference frame

- The reporting period is an **`Oee.Shift` instance** (`ActualStart`/`ActualEnd`, single-open invariant).
- **Default shift** on the entry screen:
  - If entry occurs **within the first hour of the current shift's `ActualStart`** → default to the **previous (just-ended) shift**, clearly labeled ("Reporting: Shift B, ended 6:00 AM").
  - Otherwise → default to the **current open shift**.
  - It is a **default, not a lock** — the operator may pick another shift.
  - If **no shift is open** (gap / dev) → fall back to the **most recently ended** shift.

### 3.4 Multi-lot-per-cavity auto-breakdown

A cavity's basket may fill and be released mid-shift, with a new basket opened after. So a shift's shots for that cavity can span **more than one LOT**. The split is made **deterministic by capturing each basket's totals at its close** (§4.4):

- A LOT **closed mid-shift** already carries its final good + scrap (entered at release). At end-of-shift it is shown **pre-populated** (reference/audit), not re-entered.
- The **still-open** LOT for that cavity receives the **remainder**: `good(open) = good(cavity, shift) − Σ good(cavity's closed-this-shift lots)`.
- The proposed split is **auto-computed and displayed, overridable**, with a **guard rail**: a released/closed LOT cannot be credited more than it recorded at close.

Implementation: a **read proc computes the proposed breakdown** (pure SQL — "no business logic in Python"); the UI shows it and allows override; the **write proc persists the confirmed per-lot deltas + scrap** (§4.2). This keeps the math in SQL and the write clean.

---

## 4. SQL surface

All procs follow project conventions: no `OUTPUT` params (FDS-11-011); single terminal status row `SELECT @Status, @Message[, @NewId]`; all rejecting validations **before** `BEGIN TRANSACTION` (Msg-3915 / INSERT-EXEC rule); `RAISERROR` (not `THROW`) in CATCH; **inline** (not `EXEC`) any sub-mutation that would pollute the single result set; audit `SUBJECT · CATEGORY · ACTION` with resolved-name FK JSON; UTC via `SYSUTCDATETIME()`, ET at read boundaries. Operation template resolved by **role** (`DieCast`), never by template code.

### 4.1 `Lots.DieCastLot_Open` (new)
Mint one accumulator LOT in status `Open`, `PieceCount = 0`.
- **Params:** `@ItemId, @CurrentLocationId (die-cast cell), @ToolId, @ToolCavityId, @LotName (scanned LTT), @AppUserId, @TerminalLocationId`.
- **Validations (pre-txn):** required params; Item / location / AppUser exist; **die-cast gate** (active `Tools.ToolAssignment` for `@ToolId` on the cell); `@ToolCavityId` belongs to `@ToolId` and is `Active`; **LTT required + `ufn_IsValidExternalLtt` + unique**; route has a `DieCast`-role `OperationTemplate` (SQL-enforced no-run gate); **one-open-per-(tool,cavity) guard** — reject if an `Open` LOT already exists for `(@ToolId, @ToolCavityId)`.
- **Mutation:** INSERT `Lot` (status `Open`, `PieceCount 0`, `InventoryAvailable 0`, `TotalInProcess 0`, `ToolId`+`ToolCavityId` set, `LotName` verbatim — no sequence burn); `LotStatusHistory` (NULL→Open); `LotGenealogyClosure` self-row; first-placement `LotMovement` (From=NULL, at the cell — **no storage deposit**). Audit `DieCastLotOpened`. Structurally reuses most of `Lot_Create`; implemented as a focused new proc (keeps the widely-tested `Lot_Create` contract stable).

### 4.2 Shift-output recording (new — read + write pair)
**Read — `Workorder.DieCast_GetShiftOutputBreakdown`** (pure computation, one result set):
- **Params:** `@ToolId, @ShiftId, @GrossShots INT`.
- **Returns:** one row per relevant cavity-lot (open + closed-this-shift): `ToolCavityId, CavityNumber, LotId, LotName, IsOpen, PriorGoodThisShift, ProposedGood, ProposedIsOverridable, MaxHeadroom (MaxLotSize − PieceCount)`. Encodes §3.4's breakdown + the soft-ceiling headroom.

**Write — `Workorder.DieCastShiftOutput_Record`** (status row):
- **Params:** `@ShiftId, @LinesJson NVARCHAR(MAX) = [{lotId, pieceDelta (net good), scrapLines:[{defectCodeId, quantity}]}], @ShotLossJson NVARCHAR(MAX) = [{defectCodeId, quantity}], @ToolId, @AppUserId, @TerminalLocationId`.
- **Validations (pre-txn):** each `lotId` exists and is `Open`; `pieceDelta ≥ 0`; scrap/shot-loss `DefectCode`s valid; JSON shape; cavity of each lot is active on `@ToolId`; shift exists.
- **Mutation (atomic, per line):** INSERT `Workorder.DieCastContribution` (`PieceDelta` = net good, `ShiftId`, `AppUserId` = contributing operator, `EventAt`, `TerminalLocationId`); `UPDATE Lots.Lot SET PieceCount += @PieceDelta, InventoryAvailable += @PieceDelta` (row-locked increment, mirror the RejectEvent TOCTOU pattern); INSERT the scrap `RejectEvent` rows **inlined** (additive path — record only, no decrement, no close; mirror of `RejectEvent_Record`'s `@Additive=1` branch) with the `DieCast` op-type context; shot-loss lines fan an additive `RejectEvent` to **each active cavity's open lot**. Audit `DieCastPieceContributed` (entity `Lot`) per contribution. **All sub-mutations inlined** — the proc returns a status row and is INSERT-EXEC-captured, so it cannot `EXEC` `RejectEvent_Record` or a contribution proc.
- **Soft ceiling:** if a `pieceDelta` would exceed `MaxHeadroom`, the proc does **not** reject — it records what was submitted (the UI has already resolved auto-fill / close-and-open-next / continue). The ceiling is UI-side guidance; the proc trusts the confirmed lines.

### 4.3 `Lots.DieCastLot_Release` (new) — the "close"
End accumulation; hand the LOT to its route via a storage move, capturing final good + scrap.
- **Params:** `@LotId, @StorageLocationId BIGINT NULL (resolve `WHSE` when NULL), @FinalPieceDelta INT NULL (a last good top-up), @ScrapLinesJson NVARCHAR(MAX) NULL, @ShiftId, @AppUserId, @TerminalLocationId`.
- **Validations (pre-txn):** LOT exists and is `Open`; after applying `@FinalPieceDelta`, `PieceCount > 0` (cannot release an empty basket — that path is Void); storage location exists (**hard reject** when missing — release must land on the route path; unlike the create-time soft-skip).
- **Mutation (atomic):** apply the optional final contribution + scrap (inlined, as §4.2); `LotStatusHistory` Open→**Good**; `UPDATE Lot SET LotStatusId = Good, CurrentLocationId = @StorageLocationId`; `LotMovement` (cell→storage); audit `DieCastLotReleased` (+ `LotMoved`). After commit: `Good` at storage; next pending route step (`TrimIn` `Advance`) surfaces it in the Trim WIP queue.

### 4.4 `Lots.DieCastLot_Void` (new)
Void an empty basket. `@LotId, @AppUserId, @TerminalLocationId`. Validates LOT is `Open` **and** `PieceCount = 0`; `Open → Scrap` + `LotStatusHistory` + audit `DieCastLotVoided`. Operator-permitted (UI shows the warn → Continue/Cancel).

### 4.5 Read/reporting changes
- **`Lots.Lot_GetWipQueueByLocation`** — exclude `Open`: `sc.Code NOT IN ('Closed','Open')` (both the main predicate and the `NextStep` CTE join).
- **`Lots.Lot_GetShiftCavityTally`** — **rework + bug-fix.** It currently (v1.1) sums `PieceCount + rejected quantity`, the *old subtractive* assumption, which **double-counts scrap now that die-cast is additive** (0042). Repoint to the per-cavity-LOT model: per active cavity, the running **good** (`Lot.PieceCount` of that cavity's open + this-shift lots) and the **scrap** (from `RejectEvent` for those lots, additive). Shift window from `Oee.Shift` per §3.3.
- **`Lots.Lot_GetOpenByTool`** (new read) — the currently-open accumulator LOT per cavity for the mounted die, with running `PieceCount`, `OpenedAt` (ET), contributor count. Feeds the "Currently Open" list.
- **`Lots.Lot_GetAttributeHistory`** — add **Stream 10 `Contribution`**: a `UNION ALL` branch over `Workorder.DieCastContribution` (`Added <n> pc (<shift>)`), joined to `Oee.Shift`/`ShiftSchedule` for the label. Additive, zero change to existing streams; per-cavity LOTs keep each timeline clean (a LOT shows only its own contributions).

### 4.6 Data model / migration
Versioned migration `00NN_diecast_per_cavity_lifecycle`:
- `INSERT Lots.LotStatusCode ('Open', BlocksProduction 0)` — new Id (append; no renumber of 1–4).
- `CREATE TABLE Workorder.DieCastContribution (Id BIGINT IDENTITY PK, LotId BIGINT NOT NULL FK → Lots.Lot, ShiftId BIGINT NULL FK → Oee.Shift, PieceDelta INT NOT NULL, AppUserId BIGINT NOT NULL FK → Location.AppUser, TerminalLocationId BIGINT NULL FK → Location.Location, EventAt DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME())`; indexes `IX (LotId)` (history) and `IX (ShiftId, LotId)` (dashboard/breakdown).
- `Audit.LogEventType` seeds (Id-or-Code guarded, next free ids): `DieCastLotOpened`, `DieCastPieceContributed`, `DieCastLotReleased`, `DieCastLotVoided`. No new `LogEntityType` — contributions/opens/releases audit under entity `Lot`.
- ASCII-only seeds; idempotent guards.

`TotalInProcess` stays `0` throughout accumulation; the basket becomes available inventory only at release.

---

## 5. Ignition surface

### 5.1 Named queries (Core only)
`lots/DieCastLot_Open`, `workorder/DieCastShiftOutput_Record`, `workorder/DieCast_GetShiftOutputBreakdown`, `lots/DieCastLot_Release`, `lots/DieCastLot_Void`, `lots/Lot_GetOpenByTool` (all `type: "Query"` for status-row/read procs). `Lot_GetShiftCavityTally` / `Lot_GetWipQueueByLocation` NQ signatures unchanged; procs change underneath.

### 5.2 Entity scripts (inert glue only)
`BlueRidge.Lots.Lot.openDieCast / releaseDieCast / voidDieCast / getOpenByTool`; `BlueRidge.Workorder.DieCast.getShiftOutputBreakdown / recordShiftOutput / registerShotLoss`. Thin — pass ids, render results; resolve the `DieCast` `OperationTemplate` by role (`getActiveTemplateIdForLot/ForRoute`), never by code. No business logic in Python.

### 5.3 `DieCastBody` view rework (Designer — existing view)
Replace the single "New LOT" create form with the lifecycle surface:
1. **Open** — scan a pre-printed LTT + pick Item + (auto) Tool + Cavity → **Open** button → `DieCastLot_Open`. Carry over the no-die-cast-template warning + InitialsEntry operator gate.
2. **Record shift output (Shape 1)** — die-wide gross shot entry + shift picker (defaulted per §3.3); a repeater of open cavity-lot rows, each showing computed good and a **scrap flex repeater** (reason + qty); a **Register shot loss** button; soft-ceiling inline warning with **auto-fill / close-and-open-next (release → scan next LTT → open) / continue**. Submit → breakdown read (pre-fill/override) → `DieCastShiftOutput_Record`.
3. **Release** — a **Release** button per open basket (with a final good + scrap entry, `ConfirmCreateLot`-style confirm) → `DieCastLot_Release`. **Close-and-open-next** chains release → prompt scan next pre-printed LTT → `DieCastLot_Open`.
4. **Void** — a **Void** button on an empty open basket → warn (Continue/Cancel) → `DieCastLot_Void`.
- **Currently Open** list bound to `Lot.getOpenByTool` (running `PieceCount`, contributor count, `OpenedAt` ET).
- Right-rail tally repointed to the reworked `Lot_GetShiftCavityTally` (per-cavity good + scrap, no double-count). `RejectPanel` folds into the per-cavity scrap repeater; `CheckpointPanel` (cumulative) is **retired** from this flow.
- **Edit boundary:** `DieCastBody` is an **existing** view → Designer edits, not file edits. New NQs/scripts file-authored + `scan.ps1`.

### 5.4 Production Dashboard (NEW requirement — separate deliverable)
A dashboard to **view and print a shift production report** off `DieCastContribution` (+ `RejectEvent` for scrap), joined to `Oee.Shift` and `Lot`→`Tool`/cavity. **Scope deferred** (by-machine vs plant-total — Jacques undecided). Called out here so the ledger design serves it; its own spec/plan when scoped.

---

## 6. Edge cases

1. **Basket fills mid-shift** → close-and-open-next (release + scan next LTT); the shift breakdown (§3.4) splits the shift's shots across the closed + new lot deterministically from the close totals.
2. **Empty/abandoned basket at teardown** → operator Void (warned).
3. **Two open baskets on one cavity** → prevented by the one-open-per-(tool,cavity) guard.
4. **Reject to transient zero** → cannot happen for die-cast (additive scrap never decrements).
5. **Shot loss** → fans additive scrap across every active cavity's open lot; reduces computed good everywhere.
6. **Concurrency** (two operators on one basket) → row-locked `UPDATE … PieceCount += delta` inside the txn (no app-side read-modify-write).
7. **Missing warehouse at release** → hard reject.
8. **LTT re-scan / uniqueness** → `UQ_Lot_LotName` backstop + friendly pre-check in `DieCastLot_Open`.
9. **Override of the auto-breakdown** → allowed, but a closed lot cannot be credited beyond its recorded close totals (guard rail).
10. **Entry after shift end** → §3.3 first-hour default targets the just-ended shift; overridable.

---

## 7. Phased TDD implementation plan

SQL is red→green TDD (INSERT-EXEC into a temp table matching the SELECT shape) on a throwaway `MPP_MES_Test`; Ignition after. Serialize SQL + NQ; only the view is a (Designer) parallel candidate.

- **Phase 0 — Foundation (migration):** `Open` status; `Workorder.DieCastContribution` table + indexes; 4 audit `LogEventType`s. Tests: applies clean on reset; status/table/seeds present; existing suites green (no status-Id renumber).
- **Phase 1 — Open:** `DieCastLot_Open` + tests (status `Open`, pc 0, LTT valid+unique, die-cast + cavity-active gates, one-open-per-(tool,cavity), route-has-DieCast gate, rows written, **not** on WIP queue).
- **Phase 2 — Record + breakdown:** `DieCast_GetShiftOutputBreakdown` (read) + `DieCastShiftOutput_Record` (write) + tests (net-good increment; additive scrap recorded without decrement; shot-loss fan-out; multi-lot breakdown + override + guard rail; concurrency increment; contribution carries operator + shift).
- **Phase 3 — Release + Void + queue:** `DieCastLot_Release` (Open→Good + move + final entry; empty/missing-WHSE rejects) + `DieCastLot_Void` + `Lot_GetWipQueueByLocation` `Open` exclusion + tests (queue invisible while Open; visible at storage in Trim IN after release — the end-to-end "release == first route movement" assertion).
- **Phase 4 — Tally + history:** `Lot_GetShiftCavityTally` rework (per-cavity good + additive scrap, double-count fixed) + `Lot_GetAttributeHistory` Stream 10 + `Lot_GetOpenByTool` + tests.
- **Phase 5 — Ignition backend:** Core NQs + inert entity glue, role-based template resolution. `scan.ps1`.
- **Phase 6 — `DieCastBody` rework (Designer):** the Open / Shape-1 record / Release / Void surface + Currently-Open list + repointed tally. Smoke: open baskets on several cavities, record a die-wide shift across a shift boundary with per-cavity scrap + a shot loss, close one basket mid-shift, confirm the end-of-shift breakdown pre-fills, release, confirm Trim IN appearance.
- **Phase 7 — Production Dashboard (separate, once scoped) + docs:** FDS-05 + Data Model updates (`Open` status, `DieCastContribution`, lifecycle prose), changelog, `.docx`.

**End-to-end acceptance:** per-cavity baskets open by scan on a mounted die; a die-wide shift output records net good per cavity (gross − scrap − shot losses) with per-cavity scrap itemized and additive; a basket that fills mid-shift closes with its totals and the end-of-shift split auto-reconciles; release moves each basket to storage and surfaces it in Trim IN; the shift tally and LOT history are correct and scrap is never double-counted.

---

## 8. Open / deferred items

- **Production Dashboard scope** — by-machine vs plant-total (Jacques undecided). Deferred to its own spec.
- **Exact `DieCastContribution` audit JSON + index tuning** — finalized during Phase 0/2.
- **`DieCastShiftOutput_Record` JSON contracts** (`@LinesJson`/`@ShotLossJson` exact shape) — finalized with the Phase 2 tests.

---

## 9. Revision history
| Version | Date | Author | Change |
|---|---|---|---|
| 2.0 | 2026-07-28 | Blue Ridge Automation | Full rewrite from the 2026-07-23 draft after a segment-by-segment walkthrough with Jacques. Per-cavity LOT granularity; Shape-1 die-wide entry; additive-scrap arithmetic (basket = good); dedicated `DieCastContribution` table; release-with-scrap + shift-anchored auto-breakdown; Void; Register-shot-loss; soft ceiling; `TotalInProcess = 0`; new Production Dashboard requirement. Corrected four wrong assumptions from the prior draft (§1.1). |
