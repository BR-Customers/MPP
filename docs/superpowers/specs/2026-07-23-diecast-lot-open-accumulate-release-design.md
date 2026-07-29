# Die Cast LOT: Open / Accumulate / Release Lifecycle — Design Spec

**Date:** 2026-07-23
**Author:** Blue Ridge Automation
**Status:** Draft for review (design artifact only — no code/SQL/view changes in this pass)
**Arc / Phase:** Arc 2 (Plant Floor) — Die Cast (was Phase 3)
**Supersedes behavior in:** `R__Lots_Lot_Create.sql` die-cast origin path, `DieCastBody` view, `R__Lots_Lot_GetShiftCavityTally.sql`

---

## 1. Purpose & Locked Decisions

This spec redesigns the die-cast entry flow from a **one-basket-per-create origin mint** into a
**LOT open / accumulate / release lifecycle**. The change came out of the customer meeting; the
following are **locked** (not re-litigated here):

- **Today** die cast is an `OriginMint`: `DieCastBody` scans an external LTT and
  `Lots.Lot_Create` mints one casting LOT per basket, immediately auto-depositing it to the
  Warehouse (`@DepositToStorage = 1`). The route's first step (a `DieCast` `OriginMint`) is
  "never pending," so the fresh LOT surfaces immediately in the Trim IN queue.
- **New model:** an operator **OPENS** a die-cast LOT at the machine. That LOT stays **OPEN** and
  **ACCUMULATES** pieces contributed by **multiple operators across multiple shifts**.
- The **"close" is NOT a terminal close.** Close == **moving the LOT to a STORAGE location**, which
  **RESUMES the LOT's normal defined route** (Trim, etc.). The lifecycle is:
  **open → accumulate (multi-operator, multi-shift) → release-to-storage (its first route movement).**
- **Accumulation records contribution attribution** — who added how many, when. (The per-terminal
  operator-change audit is a *separate* spec; here we only guarantee each accumulation event
  carries the contributing operator.)

The die-cast LOT is still an **origin-mint identity** — the casting is born at the press. What
changes is that (a) the LOT has a pre-route **accumulating** state, (b) `PieceCount` grows over time
instead of being fixed at mint, and (c) route entry is gated on an explicit **release**, not on
creation. The route model, role-kind classification, and terminal-mint queue rules are **unchanged**
in shape.

---

## 2. Current-State Summary (as built)

### 2.1 Creation path
`DieCastBody.submitCreate` → `BlueRidge.Lots.Lot.create` → **`Lots.Lot_Create`** with
`@DepositToStorage = 1`. Per basket:
1. Validates params/FKs, eligibility (`Parts.v_EffectiveItemLocation` ancestor cascade),
   `PieceCount ≤ Item.MaxLotSize`, die-cast Tool/Cavity (`FDS-05-034`).
2. Die-cast is detected by **`@CellHasActiveTool`** = Manufactured origin **AND** an active
   `Tools.ToolAssignment` on the cell.
3. Requires a scanned external LTT (`@LotName`), format-validated via
   `Lots.ufn_IsValidExternalLtt` (9 digits). D4: caller-supplied LotName is used verbatim and does
   **not** burn the `Lot` identifier sequence.
4. Inserts `Lots.Lot` **status `Good`**, `PieceCount = @PieceCount`, materialized B5 columns
   (`TotalInProcess = 0`, `InventoryAvailable = @PieceCount`), stamps a single `ToolId` +
   `ToolCavityId` (or free-text `CavityNumber` via D2).
5. Writes `LotStatusHistory` (NULL→Good), `LotGenealogyClosure` self-row, first-placement
   `LotMovement` (From=NULL).
6. `@DepositToStorage = 1` → inline system-move to `WHSE` (well-known code), a second `LotMovement`
   (machine→WHSE) + a `LotMoved` audit. Soft-skips if no warehouse configured.

### 2.2 Status & origin codes
`Lots.LotStatusCode` (seed, migration `0004`): `Good`(1, BlocksProduction 0), `Hold`(2, 1),
`Scrap`(3, 1), `Closed`(4, 0). **There is no `Open` status today.**
`Lots.LotOriginType`: `Manufactured`(1), `Received`(2), `ReceivedOffsite`(3).

### 2.3 Production checkpoints (exist, not wired into the basket flow)
`Workorder.ProductionEvent_Record` + the `CheckpointPanel` view record **cumulative** die-cast shot
checkpoints (`DieCastCheckpointRecorded`). Contract:
- **D1:** `@ShotCount`/`@ScrapCount` are **cumulative** LOT totals, monotonic non-decreasing
  (a value below the prior checkpoint is rejected).
- **D2:** a checkpoint **does NOT mutate** `Lot.InventoryAvailable`/`Lot.TotalInProcess`. Quantities
  move only on consumption/reject.
- Carries `AppUserId` + `TerminalLocationId` attribution and optional `ProductionEventValue`
  children. **No `ToolCavityId` column today.**

### 2.4 Rejects
`Workorder.RejectEvent_Record` **decrements** `Lot.PieceCount` + `Lot.InventoryAvailable`
(floored at 0), TOCTOU-guarded, and **closes the LOT at zero** (`Good`→`Closed`). Reject attribution
is `AppUserId`.

### 2.5 Shift tally
`Lots.Lot_GetShiftCavityTally(@ToolId)` sums, per active `ToolCavity`, the as-cast pieces of LOTs
**`Created` during the open OEE shift** on that tool+cavity (keyed on **`Lot.CreatedAt`** +
`Lot.ToolId`/`ToolCavityId`, which are stamped at creation and immutable). Domain note in the proc
header explicitly states "die-cast LOTs are never in process."

### 2.6 Route-driven WIP queue
`Lots.Lot_GetWipQueueByLocation(@LocationId, @OperationTypeCode, @IncludeDescendants)` returns open
(`LotStatusCode <> 'Closed'`) LOTs at a location whose **lowest-`SequenceNumber` pending** route step
carries the terminal's role. Pending: `Advance` = no matching `ProductionEvent`; `ConsumeMint` =
always pending while open; `OriginMint` = never pending. This is what makes a freshly-created casting
appear in the Trim IN queue.

### 2.7 Move / release primitive
`Lots.Lot_MoveToValidated` is the validated inbound move (eligibility, forward-only route guard,
`MaxParts` cap). The die-cast auto-deposit currently bypasses it (inline system move inside
`Lot_Create`, non-eligibility-gated, because storage is not a production location).

---

## 3. New Data / Identity Model

### 3.1 The "open unit" — one open accumulator LOT per mounted die (RECOMMENDED)

**Recommendation:** the accumulator LOT == the **basket / container being filled** == **one OPEN LOT
per mounted `Tool` (die) at the machine**. Because exactly one die is mounted per die-cast machine at
a time (`Tools.ToolAssignment` with `ReleasedAt IS NULL`), this is effectively **one open LOT per
machine**. Cavity ceases to be a **LOT-level** attribute and becomes a **contribution-level** attribute.

Rationale:
- Physically one die fires **all its cavities on every shot** into one basket; multiple operators and
  shifts feed the same basket until it is full. The basket is the natural unit of identity and the
  physical LTT anchor.
- Cavity-level defect traceability (which Honda genealogy cares about) is preserved by stamping
  `ToolCavityId` on each **contribution** and each **reject**, not on the LOT.

> ### 🚩 OPEN QUESTION Q1 — LOT granularity: per-die basket vs per-cavity LOT
> The recommendation collapses all cavities of a die into one accumulator LOT. The **alternative** is
> **one open LOT per (Tool, Cavity)** — preserving today's LOT-level cavity identity and cavity-scoped
> genealogy, at the cost of N open LOTs per die and N LTTs per shot. **Which does MPP/Honda require for
> genealogy — is per-cavity traceability at the *event* level sufficient, or must each cavity be its own
> LOT/LTT?** This is the single biggest branch in the design; everything downstream (tally, reject
> attribution, release count) follows from it. Recommendation: **per-die basket, cavity on the event.**

### 3.2 New LOT status: `Open` (RECOMMENDED)

Add a fifth `Lots.LotStatusCode`: **`Open`** (`BlocksProduction = 0`). Semantics: the LOT exists and
is accumulating at the press but is **not yet on its route**. It becomes `Good` at release.

Why a status (vs an `OpenedAt`/`ReleasedAt` timestamp pair on `Lot`):
- The WIP queue, `Lot_MoveToValidated`, `ProductionEvent_Record`, and `RejectEvent_Record` all gate on
  `LotStatusCode.Code` already. A new status is a **single, consistent gate** across every consumer:
  the queue excludes `Open` (`sc.Code NOT IN (N'Closed', N'Open')`), so an accumulating LOT never
  surfaces to Trim prematurely.
- `Open` must **not** block production the way `Hold`/`Scrap` do (`BlocksProduction = 0`), because
  contributions and rejects are recorded *against* an open LOT. The queue/route exclusion is a separate
  predicate from `BlocksProduction`.

Lifecycle transitions (all recorded in `LotStatusHistory`):
```
(none) --open--> Open --release--> Good --...route...--> Closed
                  │
                  └--void/scrap (supervisor)--> Scrap
```

> ### 🚩 OPEN QUESTION Q2 — `Open` status vs timestamp gate
> Recommendation is a new `Open` `LotStatusCode`. Alternative: keep birth-status `Good` and add
> `Lot.OpenedAt`/`Lot.ReleasedAt`, gating the queue on `ReleasedAt IS NOT NULL`. The status approach
> touches more read paths but is the cleaner single gate given the existing status-keyed guards.
> **Confirm the status-code approach is acceptable** (it adds one seed row; no existing status Ids change).

### 3.3 Accumulation ledger — extend `Workorder.ProductionEvent` (RECOMMENDED)

Each piece contribution is an **append-only event** that (a) records attribution + cavity + delta and
(b) **increments** the LOT's materialized B5 quantity. Reuse the existing
`Workorder.ProductionEvent` table as the ledger, extended by a small migration:

- `+ ToolCavityId BIGINT NULL FK → Tools.ToolCavity` — the cavity this contribution came from
  (nullable for D2 manual-cavity / whole-die contributions).
- `+ PieceDelta INT NULL` — the **incremental** good pieces added by this contribution (distinct from
  the legacy cumulative `ShotCount`/`ScrapCount` columns).

The contribution is written by a **new recorder proc** (§4.2) with **delta** semantics that mutates
`Lot.PieceCount`/`InventoryAvailable`. The legacy `ProductionEvent_Record` (cumulative, D2 no-qty)
is **retired from the die-cast flow** but left intact for any non-accumulation checkpoint use.

> ### 🚩 OPEN QUESTION Q3 — reuse `ProductionEvent` (delta columns) vs a new `Workorder.DieCastContribution` table
> Extending `ProductionEvent` keeps one ledger and reuses attribution/value-child plumbing, but mixes
> **cumulative** (legacy D1/D2) and **delta** (new) row semantics in one table — readers must know which
> proc wrote a row. A dedicated `Workorder.DieCastContribution` table is semantically cleaner but
> duplicates plumbing and needs its own audit/value children. Recommendation: **extend `ProductionEvent`**
> and standardize the die-cast flow on delta rows (`PieceDelta` populated, cumulative columns optional).
> Note: this intersects the **top-of-`PROJECT_STATUS.md` "converge operation-template methodology" TODO** —
> the die-cast recorder should resolve its `OperationTemplate` by ROLE (`getActiveTemplateIdForLot`/
> `ForRoute` with `'DieCast'`), never by code.

### 3.4 `Lot` column impacts

- `PieceCount` starts at `0` on open and grows per contribution (materialized truth for "pieces in the
  basket"). The `PieceCount > 0` guard in `Lot_Create` is **relaxed for the open path** (open with 0).
- `Lot.ToolId` is stamped at open (the mounted die). `Lot.ToolCavityId` becomes **NULL** for a
  per-die accumulator (cavity lives on the events). `MaxPieceCount`/`Item.MaxLotSize` becomes the
  **basket capacity ceiling** enforced on *cumulative accumulation*, not on a single create.
- `LotOriginTypeId = Manufactured` unchanged.

---

## 4. State Transitions & SQL Surface

All procs follow project conventions: no `OUTPUT` params (FDS-11-011); single terminal status row
`SELECT @Status, @Message[, @NewId]`; all rejecting validations **before** `BEGIN TRANSACTION`
(Msg-3915 / INSERT-EXEC rule); `RAISERROR` (not `THROW`) in CATCH; inline (not EXEC) any sub-mutation
that would pollute the single result set; audit Description in `SUBJECT · CATEGORY · ACTION` shape with
resolved-name FK JSON. Timestamps stored UTC via `SYSUTCDATETIME()`, displayed ET at read boundaries.

### 4.1 `Lots.DieCastLot_Open` (new)
**Responsibility:** mint the accumulator LOT in status `Open` with `PieceCount = 0`.
- **Params:** `@ItemId, @CurrentLocationId (the die-cast cell), @ToolId, @LotName (scanned LTT),
  @AppUserId, @TerminalLocationId`. (No `@PieceCount`; no `@ToolCavityId` at LOT level under Q1
  recommendation.)
- **Validations (pre-transaction):** required params; Item exists/not deprecated; location exists;
  AppUser exists; **die-cast gate** (active `ToolAssignment` for `@ToolId` on the cell, mirroring
  `@CellHasActiveTool`); **LTT required + `ufn_IsValidExternalLtt` + uniqueness** (same rules as
  today's die-cast create); route has a `DieCast`-role `OperationTemplate` (the current
  `getActiveTemplateIdForRoute(itemId,'DieCast')` no-run gate, enforced in SQL); **one-open-per-tool**
  guard — reject if an `Open` LOT already exists for `@ToolId` (see Q4).
- **Mutation:** INSERT `Lot` (status `Open`, `PieceCount 0`, `InventoryAvailable 0`, `ToolId` set,
  `ToolCavityId NULL`, `LotName = @LotName` verbatim — no sequence burn); `LotStatusHistory`
  (NULL→Open); `LotGenealogyClosure` self-row; first-placement `LotMovement` (From=NULL, at the cell —
  **no storage deposit yet**). Audit `LotCreated` (new event subtype `DieCastLotOpened`, see §4.6).
- **Structurally reuses** most of `Lot_Create`; recommended to implement as a focused new proc rather
  than overload `Lot_Create` with an `@Open` mode (keeps the widely-tested create contract stable).

### 4.2 `Workorder.DieCastContribution_Record` (new)
**Responsibility:** append one contribution to an open LOT and increment its materialized quantity.
- **Params:** `@LotId, @OperationTemplateId (resolved by DieCast role), @PieceDelta INT,
  @ToolCavityId BIGINT NULL, @ShotCount INT NULL, @ScrapCount INT NULL, @ScrapSourceId NULL,
  @WeightValue/@WeightUomId NULL, @FieldValuesJson NULL, @AppUserId, @TerminalLocationId`.
- **Validations (pre-transaction):** required params; LOT exists and is **`Open`** (reject if `Good`/
  `Closed`/blocked — you can only accumulate into an open basket); `@PieceDelta > 0`; cavity (when
  supplied) belongs to `@ToolId` and is `Active`; **basket ceiling** — `PieceCount + @PieceDelta ≤
  MaxPieceCount` (Item.MaxLotSize) when the ceiling is set (see Q5); FK checks; JSON shape.
- **Mutation (atomic, row-locked LOT):** INSERT `ProductionEvent` (`PieceDelta`, `ToolCavityId`,
  `AppUserId` = **contributing operator**, `EventAt = SYSUTCDATETIME()`, `TerminalLocationId`) + optional
  `ProductionEventValue` children; `UPDATE Lots.Lot SET PieceCount += @PieceDelta, InventoryAvailable
  += @PieceDelta` (concurrency-safe increment, mirror the RejectEvent TOCTOU pattern). Audit
  `DieCastPieceContributed`. **Attribution guarantee:** the contributing operator is the row's
  `AppUserId`, so multi-operator baskets have a full per-contribution operator trail.

### 4.3 `Lots.DieCastLot_Release` (new) — the "close" action
**Responsibility:** end accumulation and hand the LOT to its route by moving it to storage.
- **Params:** `@LotId, @StorageLocationId BIGINT NULL (default resolve `WHSE`), @AppUserId,
  @TerminalLocationId`.
- **Validations (pre-transaction):** LOT exists and is **`Open`**; `PieceCount > 0` (cannot release an
  empty basket); storage location exists (resolve well-known `WHSE` when NULL; soft-skip semantics are
  **not** appropriate here — release *must* land somewhere, so a missing warehouse is a hard reject,
  unlike the create-time soft-skip).
- **Mutation (atomic):** `LotStatusHistory` Open→**Good**; `UPDATE Lot SET LotStatusId = Good,
  CurrentLocationId = @StorageLocationId`; `LotMovement` (cell→storage); audit `DieCastLotReleased`
  (+ a `LotMoved` movement audit). After commit the LOT is `Good` at storage; its next pending route
  step (`TrimIn` `Advance`) makes it appear in the Trim WIP queue — i.e. release **is** the first route
  movement, exactly as locked. This reuses the deposit mechanics already proven inside `Lot_Create`'s
  `@DepositToStorage` block, relocated into an explicit proc.

### 4.4 `Lots.Lot_GetWipQueueByLocation` (change)
Exclude `Open` LOTs from every queue: change the open-LOT predicate from `sc.Code <> N'Closed'` to
`sc.Code NOT IN (N'Closed', N'Open')`. This is the one queue-visibility change that keeps accumulating
baskets out of Trim until released. (The `NextStep` CTE join uses the same status filter — update both
references.)

### 4.5 `Lots.Lot_GetShiftCavityTally` (change) + reject interaction
- **Repoint the shift window from `Lot.CreatedAt` to event time.** Under accumulation a LOT opened in
  shift A and fed in shift B has pieces belonging to **both** shifts, so the tally must sum
  **`ProductionEvent` contributions** (`EventAt >= @ShiftStart`, grouped by `ToolCavityId`) rather than
  whole-LOT `PieceCount` by `Lot.CreatedAt`. Good/scrap per cavity derive from `PieceDelta` and reject
  rows joined by event time. This is a real semantic change to the right-rail KPIs.
- **`RejectEvent_Record` close-at-zero:** today a reject that drives `PieceCount` to 0 flips the LOT to
  `Closed`. For an **`Open`** LOT this is wrong — a basket transiently at 0 during accumulation must stay
  `Open`. **Change:** suppress the auto-close when `LotStatusCode = 'Open'` (only `Good` LOTs auto-close
  at zero). Reject attribution + cavity (`ToolCavityId`) still recorded.

### 4.6 Migrations & seeds
- **Versioned migration** `00NN_diecast_open_accumulate`:
  - `INSERT Lots.LotStatusCode (Open, BlocksProduction 0)` — new Id (append; do not renumber 1–4).
  - `ALTER Workorder.ProductionEvent ADD ToolCavityId BIGINT NULL FK, PieceDelta INT NULL` (idempotent
    guards per repo convention).
  - `Audit.LogEventType` seeds: `DieCastLotOpened`, `DieCastPieceContributed`, `DieCastLotReleased`
    (Id-or-Code guarded, per the PLC-merge collision lesson).
- **Repeatables:** the three new procs above, plus edits to
  `R__Lots_Lot_GetWipQueueByLocation.sql`, `R__Lots_Lot_GetShiftCavityTally.sql`,
  `R__Workorder_RejectEvent_Record.sql`.

---

## 5. Ignition Surface (high level)

### 5.1 Named Queries (Core only — `project_mpp_nq_core_topology`)
- `lots/DieCastLot_Open` (type `Query` — status-row proc).
- `workorder/DieCastContribution_Record` (type `Query`).
- `lots/DieCastLot_Release` (type `Query`).
- `lots/Lot_GetOpenByTool` (new read — the currently-open accumulator(s) for the mounted die, with
  running `PieceCount`, `OpenedAt`, contributor count).
- Existing `lots/Lot_GetShiftCavityTally` + `lots/Lot_GetWipQueueByLocation` NQs unchanged in
  signature; their procs change underneath.

### 5.2 Entity scripts (`BlueRidge.Lots.Lot`, `BlueRidge.Workorder.*`)
- `Lot.openDieCast(...)`, `Lot.releaseDieCast(...)`, `DieCast.addContribution(...)` — thin,
  **inert glue** (pass ids, render result) per the "no business logic in Python" rule. Resolve the
  `DieCast` `OperationTemplate` by role (`OperationTemplate.getActiveTemplateIdForLot/ForRoute`), never
  by code.
- `Lot.getOpenByTool(toolId)`.

### 5.3 `DieCastBody` view rework
Replace the single "New LOT" create form with a three-mode surface:
1. **Open LOT** — scan LTT + pick Item + (auto) Tool → **Open** button → `DieCastLot_Open`. The
   no-die-cast-template warning + operator gate (InitialsEntry popup) carry over.
2. **Accumulate** — an "Add pieces" panel (piece delta + cavity + optional shots/scrap) that calls
   `DieCastContribution_Record` and refreshes the running total. The contributing operator is
   `session.custom.appUserId` at submit time (already switchable via the existing InitialsEntry popup),
   satisfying the attribution requirement.
3. **Release to storage** — a **Release** button on the open LOT (with a `ConfirmCreateLot`-style
   confirm) → `DieCastLot_Release`. This is the "close."
- A small **Currently Open** list (usually one row) bound to `Lot.getOpenByTool` with running
  `PieceCount` + contributor count + `OpenedAt` (ET).
- Right-rail tally + reject panel stay, repointed to the event-time tally (§4.5). `RejectPanel`
  continues to charge the open LOT and now records cavity per reject.
- `CheckpointPanel` (cumulative) is retired from this flow or repurposed; do not wire it alongside the
  new delta contribution.
- **Edit boundary:** `DieCastBody` is an **existing** view → edits happen in **Designer**, not file
  edits (per `feedback_ignition_view_edit_boundary`). File-authoring is fine for the **new** NQs and
  Python script modules; run `.\scan.ps1` after.

---

## 6. Edge Cases

1. **Abandoned open LOT across shifts / end of run** — a basket left open when the die is torn down.
   Needs a **supervisor Release or Void** affordance. Recommend: block tool release while an `Open` LOT
   exists on that tool (Q4), plus a supervisor-elevated `DieCastLot_Release`/void path.
2. **Two open LOTs on one die** — prevented by the one-open-per-tool guard in `DieCastLot_Open`
   (Q4). If MPP wants parallel baskets (e.g. sorting good vs suspect during a trial), relax to N.
3. **Release with zero pieces** — rejected (`PieceCount > 0` guard).
4. **Reject to transient zero during accumulation** — LOT stays `Open` (§4.5), does not auto-close.
5. **Basket ceiling reached** — contribution beyond `MaxPieceCount` rejected (Q5); operator releases
   the full basket and opens a new one.
6. **Item change mid-accumulation** — disallowed; Item is fixed at open. (No proc accepts a new Item on
   contribute/release.)
7. **Tool released / re-mounted mid-open** — see Q4; the open LOT must be resolved (released or voided)
   before the die is torn down, or explicitly orphan-handled.
8. **Concurrency** — two operators contributing to the same open LOT: the materialized increment is a
   single row-locked `UPDATE ... SET PieceCount += @PieceDelta` inside the txn (no read-modify-write in
   app code), mirroring the RejectEvent TOCTOU guard.
9. **Missing warehouse at release** — hard reject (unlike the create-time soft-skip), because release
   must land the LOT somewhere on the route path.
10. **LTT uniqueness / re-scan** — the existing `UQ_Lot_LotName` backstop still applies; `DieCastLot_Open`
    keeps the friendly pre-check.
11. **Backward move after release** — already handled by `Lot_MoveToValidated`'s forward-only route
    guard; release lands the LOT at storage as its first route position.

---

## 7. Open Questions (consolidated)

| # | Question | Recommendation |
|---|----------|----------------|
| **Q1** | LOT granularity: **per-die basket** (cavity on the event) vs **per-cavity LOT** (per-cavity LTT/genealogy). Biggest branch — everything follows from it. | **Per-die basket**, cavity stamped on each contribution + reject. Confirm Honda genealogy is satisfied by event-level cavity. |
| **Q2** | New `Open` `LotStatusCode` vs `OpenedAt`/`ReleasedAt` timestamp gate. | **New `Open` status** (single status-keyed gate across queue/move/reject). |
| **Q3** | Accumulation ledger: extend `Workorder.ProductionEvent` (delta columns) vs new `Workorder.DieCastContribution` table. | **Extend `ProductionEvent`** with `PieceDelta` + `ToolCavityId`; standardize die-cast on delta rows. |
| **Q4** | One open LOT per die (guard tool teardown) vs allow N parallel baskets. | **One open per tool**; block tool release while an `Open` LOT exists; supervisor void/release for teardown. |
| **Q5** | Basket capacity ceiling on **cumulative** accumulation — is `Item.MaxLotSize` the per-basket cap, and is it a hard reject or a soft warning? | Enforce `PieceCount + delta ≤ MaxLotSize` as a **hard cap** when set; NULL = uncapped. Confirm the column's meaning (it is also "parts per basket" prefill today). |
| **Q6** | LTT assignment timing: **at open** vs **at release**. | **At open** (the label is the physical anchor operators feed). If MPP labels only at release, open mints a server LotName and the LTT binds at release (needs a rename/attach step). |
| **Q7** | Does opening/accumulating write to `TotalInProcess` (B5) in addition to `PieceCount`/`InventoryAvailable`? Die-cast historically kept `TotalInProcess = 0`. | Keep `TotalInProcess = 0` during accumulation; treat the basket as available inventory once released. Confirm against OEE/inventory reads. |

---

## 8. Phased TDD Implementation Plan

Each phase is red→green SQL TDD (INSERT-EXEC into a temp table matching the SELECT shape, assert
against it) on a throwaway `MPP_MES_Test`, then Ignition. **Serialize** SQL + NQ work; only the view
rework is a candidate for parallel authoring, and it is Designer work (not file-parallelizable).

- **Phase 0 — Foundation (migration).** New versioned migration: seed `Open` status; add
  `ProductionEvent.ToolCavityId` + `PieceDelta`; seed 3 audit `LogEventType`s. Tests: migration applies
  clean on a fresh reset; status/columns/seeds present; existing suites still green (no status-Id
  renumber).
- **Phase 1 — Open.** `Lots.DieCastLot_Open` + tests: opens status `Open`, `PieceCount 0`, LTT
  validated + unique, die-cast gate, one-open-per-tool guard, route-has-DieCast-template gate,
  status-history/closure/movement rows written, **not** on the WIP queue.
- **Phase 2 — Accumulate.** `Workorder.DieCastContribution_Record` + tests: increments
  `PieceCount`/`InventoryAvailable`; append-only row carries contributing `AppUserId` + cavity;
  multi-contribution running total; rejects on non-Open LOT, non-positive delta, over-ceiling, bad
  cavity; concurrency increment correctness.
- **Phase 3 — Release + queue.** `Lots.DieCastLot_Release` + `Lot_GetWipQueueByLocation` `Open`
  exclusion + tests: Open→Good + move-to-storage; empty-basket reject; missing-warehouse hard reject;
  **queue visibility** — Open LOT invisible to Trim, released LOT visible at storage in the Trim IN
  queue (the end-to-end assertion that release == first route movement).
- **Phase 4 — Reject + tally.** `RejectEvent_Record` no-auto-close-when-Open + `Lot_GetShiftCavityTally`
  event-time repoint + tests: reject on Open decrements but keeps Open; tally sums cross-shift
  contributions by `EventAt` and cavity; scrap-inclusive KPIs.
- **Phase 5 — Ignition backend.** Core NQs + inert entity glue (`openDieCast`/`addContribution`/
  `releaseDieCast`/`getOpenByTool`), role-based template resolution. `.\scan.ps1`.
- **Phase 6 — `DieCastBody` view rework (Designer).** Open / Accumulate / Release surface + Currently-
  Open list + repointed tally/reject. Designer smoke: open a basket, two operators contribute across a
  simulated shift boundary, reject a few, release, confirm it lands in the Trim IN queue.
- **Phase 7 — Edge cases + docs.** Tool-teardown guard + supervisor void/release; FDS-05 (die-cast) +
  Data Model updates (`LotStatusCode` Open, `ProductionEvent` columns, lifecycle prose), changelog rows;
  regenerate `.docx`.

**End-to-end acceptance:** a die-cast basket opens on a mounted die, accumulates pieces from ≥2
operators across ≥2 shifts (each contribution attributed), tolerates a reject without closing, and on
Release moves to storage and surfaces in Trim IN — with the shift tally and audit trail correct
throughout.

---

## 9. Convention Compliance Checklist

- **FDS-11-011:** no `OUTPUT` params; single status-row per mutation proc; read procs return one result
  set (empty = not found).
- **Msg-3915 / INSERT-EXEC:** all rejecting validations before `BEGIN TRANSACTION`; sub-mutations
  inlined; CATCH is the only ROLLBACK site; `RAISERROR` not `THROW`.
- **NQ typing:** status-row procs → NQ `type: "Query"`; audit writers emit no result set.
- **Audit:** `SUBJECT · CATEGORY · ACTION` Description via `ufn_MidDot`/`ufn_TruncateActivity`;
  resolved-name FK JSON (`{Id, Code, Name}`) in Old/NewValue.
- **Time:** store UTC (`SYSUTCDATETIME()`), display ET (`AT TIME ZONE`) at read boundaries.
- **Codes/enums:** `Open` is a code-table-backed status FK — no magic integers. Operation template
  resolved by **role** (`DieCast`), never by template code.
- **No business logic in Python:** all lifecycle rules live in the three SQL procs; Perspective/entity
  scripts are inert glue.
- **Ignition edit boundary:** new NQs/scripts file-authored + `scan.ps1`; existing `DieCastBody` edited
  in Designer.
- **Seeds:** any string values ASCII-only; append new status/audit Ids (no renumber).
```
