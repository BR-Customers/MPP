# Arc 2 Phase 4 — Movement + Trim + Receiving: SQL Foundation — Design

**Date:** 2026-06-15
**Status:** Draft for review
**Scope:** The **SQL foundation** for Phase 4 — migration `0023` (audit-lookup seeds), a location-dependent OperationTemplate seed file, **six net-new stored procedures**, and the `0023_PlantFloor_Movement_Trim` test suite. The Perspective views (Movement Scan component, Trim Station IN/OUT, Receiving Dock), the Core Named Queries / entity scripts, and the `LttZplDispatcher` gateway script are a **separate front-end + gateway spec** (the deferred follow-on), consistent with the Phase 1/2/3 SQL-first pattern.

## 1. Source of truth

- **Phased plan** — `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` § "Phase 4 — Movement + Trim + Receiving" (the authoritative narrative + API table). Task list `MPP_MES_TASK_LIST_PLANT_FLOOR.csv` (the Phase 4 SQL subset).
- **FDS** — **FDS-02-009** (destination by scan or dropdown), **FDS-02-012** (ItemLocation eligibility = Direct ∪ BomDerived, with the cascade Cell → WorkCenter → Area → Site and the reject message), **FDS-06-006** (Trim OUT 1:1 whole-LOT move; no split at Trim), **FDS-05-033** (part-identity rename is at Machining IN, **not** Trim — Trim is yield-loss only), **FDS-03-017a** (cumulative checkpoint; a missed checkpoint does not compound), **OI-12** (`Item.MaxParts` per-Item cap), **FRS 2.2.3** (weight-based piece-count estimation), **FRS 5.6.1 / Scope Matrix row 3** (receiving pass-through parts = MVP).
- **Data Model** — `Lots.Lot` (`CurrentLocationId`, `PieceCount`, `LotStatusId`, `ItemId`), `Lots.LotMovement`, `Workorder.ProductionEvent`, `Parts.Item.MaxParts`, `Parts.v_EffectiveItemLocation`.
- **SQL conventions** — `sql_best_practices_mes.md`, `sql_version_control_guide.md`, the `_TEMPLATE_stored_procedure.sql`, and the project memories on FDS-11-011 (single result set), the INSERT-EXEC / Msg-3915 inline-sub-mutation rule, audit readability, and the Arc 2 LOT test teardown FK order.

## 2. Reconciliation to shipped SQL — what already exists (reuse, do not rebuild)

Verified against the repo on disk (2026-06-15):

- **`Lots.Lot_MoveTo`** (generic move) — params `@LotId, @ToLocationId, @AppUserId, @TerminalLocationId`; validates blocked-status only; writes the `LotMovement` row + updates `Lot.CurrentLocationId`; audits `LotMoved`. It does **not** enforce eligibility or MaxParts. **Left untouched** — Phase 4 adds a *validated* sibling (§4) rather than altering the shared proc, so Area-resolution moves and future callers (Sort Cage) are not over-constrained.
- **`Lots.Lot_Create`** — already accepts `@VendorLotNumber`, `@MinSerialNumber`, `@MaxSerialNumber`, `@LotOriginTypeId`, NULL Tool/Cavity. **Receiving needs no net-new mutation proc** — it is a `Lot_Create` call with `LotOriginType='Received'`, audited as `LotCreated`.
- **`Lots.Lot_Get`** (`@LotId` / `@LotName`), **`Parts.Item_Get` / `Item_GetByPartNumber`** (already surface `MaxParts`), **`Lots.Lot_AssertNotBlocked`**, **`Lots.Lot_Update`** (Phase 2 — piece-count correction with `LotAttributeChange`), **`Workorder.ProductionEvent_Record`** + **`Workorder.RejectEvent_Record`** (Phase 3). **Trim IN's checkpoint and reject reuse the Phase 3 procs unchanged** (§5).
- **`Parts.v_EffectiveItemLocation`** (built in `0020`) — the Direct ∪ BomDerived eligibility view the new eligibility read wraps.
- **Audit high-water (post-Phase-3 cleanup):** `Audit.LogEventType` max = **33**, `Audit.LogEntityType` max = **46**. `LotMoved` LogEventType already seeded (Phase 1, referenced by `Lot_MoveTo`). Next migration number is **`0023`**.

## 3. Migration `0023_arc2_phase4_movement_trim_receiving.sql` — audit lookups only

Versioned migration, `SchemaVersion` row + idempotent guards, **no tables, no ALTERs**. ASCII-only Name/Description (sqlcmd Windows-codepage mojibake guard).

1. **`Audit.LogEventType`** (manual Ids, reconciled against the real high-water 33):
   - **34** `TrimCheckpointRecorded`
   - **35** `TrimOutRecorded`
   - (`LotMoved` already exists — not re-seeded. No new `LogEntityType` — `Lot`, `ProductionEvent`, `RejectEvent` all exist.)
2. **No `ReceivingScan` event** (Confirm A, §6): Receiving writes no `ProductionEvent`; its audit is `Lot_Create`'s `LotCreated`. The vestigial `ReceivingScan` OperationTemplate / `ReceivingScanRecorded` LogEventType from the phased-plan draft are **dropped**.

### 3.1 Location-dependent OperationTemplate seed → a SEED file, not the migration

`Parts.OperationTemplate.AreaLocationId` is a NOT-NULL FK to `Location.Location`, and the plant hierarchy is itself loaded by a **seed** (`011_seed_locations_mpp_plant.sql`) that runs **after** all versioned migrations (the exact constraint that pushed Phase 3's `DieCastShot` template into `sql/seeds/022`). Therefore the `TrimIn` / `TrimOut` OperationTemplates live in **`sql/seeds/023_seed_trim_operation_templates.sql`**, which runs after the location seed and binds `AreaLocationId` to the Trim Shop Area (resolve by Code, fall back to the first active Area-tier Location). Two-state versioned entity (`VersionNumber=1`, `DeprecatedAt IS NULL` = active/published — `OperationTemplate` carries no `PublishedAt`). Idempotent on `Code`. **Confirm C (§6): `TrimIn` / `TrimOut` seed with NO `OperationTemplateField` children** — Trim checkpoints use the promoted `ProductionEvent.ShotCount` / `ScrapCount` columns only (no weight capture at Trim unless MPP later elects it).

## 4. Stored procedures (net-new)

All follow FDS-11-011 (single result set; `@Status`/`@Message`/`@NewId` locals; no OUTPUT params), three-tier `RAISERROR` error handling, schema-qualified refs, and the audit-readability convention (`Audit.ufn_MidDot()`, `Audit.ufn_TruncateActivity()`, `JSON_QUERY`-wrapped resolved-FK Old/New JSON). Per the INSERT-EXEC / Msg-3915 rule, **every rejecting validation runs before `BEGIN TRANSACTION`**, sub-mutations are **inlined** (never `EXEC`'d), and `CATCH` is the only `ROLLBACK` site.

### 4.1 Reads (advisory — drive UI pre-commit feedback)

- **`Parts.ItemLocation_CheckEligibility @ItemId BIGINT, @LocationId BIGINT`** → single row `IsEligible BIT, Path NVARCHAR(20)` (`'Direct'` / `'BomDerived'` / `NULL`). Thin wrapper over `v_EffectiveItemLocation` (which already encodes the Cell → WorkCenter → Area → Site cascade). `@LocationId` is a generic location id (works at Cell *or* Area resolution — Trim IN resolves at the Trim Shop Area). The UI renders the FDS-02-012 reject message on `IsEligible=0`.
- **`Parts.Item_GetMaxParts @ItemId BIGINT`** → single row `MaxParts INT NULL`. Dedicated thin read for the scan flow (the cap is also surfaced by `Item_Get`; kept separate per the plan's API table).
- **`Lots.Lot_GetCellLineQuantity @LocationId BIGINT, @ItemId BIGINT`** → single row `ExistingPieceCount INT`. Sums `PieceCount` across **open** LOTs (`LotStatusCode <> 'Closed'`) of `@ItemId` whose `CurrentLocationId = @LocationId`. (Generic location id despite the "CellLine" name — sums at whatever tier the destination is.)
- **`Lots.Lot_GetWipQueueByLocation @LocationId BIGINT, @IncludeDescendants BIT = 0`** → rowset: the open LOTs whose `CurrentLocationId = @LocationId` (or whose location is a descendant of `@LocationId` when `@IncludeDescendants=1`), in **arrival order** — ordered by the LOT's latest `LotMovement.MovedAt ASC` (joined, since `Lot` carries no denormalized `LastMovementAt`). Columns: LOT header (`Id`, `LotName`, `ItemId` + resolved Part No./Name, `PieceCount`, `LotStatusId` + Code) plus `LastMovementAt`. **Consumed by Phase 5 Machining IN** (FIFO pick). Empty rowset = no WIP.

### 4.2 `Lots.Lot_MoveToValidated`

```
@LotId BIGINT, @ToLocationId BIGINT, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL
→ Status, Message
```

The server-authoritative inbound move — the Movement Scan pattern's commit step (decision in §5.1). All validations **before** `BEGIN TRANSACTION`:

1. Required params present; LOT exists.
2. **Not-blocked** — inlined mirror of `Lot_AssertNotBlocked` (read `LotStatusCode.BlocksProduction` + terminal `Closed`; reject with the status-named message). Inlined, not `EXEC`'d, because this proc is captured via INSERT-EXEC.
3. **Eligibility (FDS-02-012)** — the LOT's `ItemId` must resolve at `@ToLocationId` via `v_EffectiveItemLocation` (Direct ∪ BomDerived). On miss, reject with the FDS-02-012 message.
4. **MaxParts cap (OI-12)** — if `Item.MaxParts IS NOT NULL`, reject when `ExistingPieceCount (open LOTs of this Item at @ToLocationId) + LOT.PieceCount > MaxParts`. **`MaxParts NULL = uncapped`** — this is how Area-resolution moves (Trim IN) and Items without a cap stay unconstrained without a tier special-case.

Then, in one transaction, **inline** the move (mirror of `Lot_MoveTo`): insert `LotMovement (FromLocationId = current, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)`, update `Lot.CurrentLocationId`, and audit `LotMoved` (`Lot` entity → routes to `LotEventLog`; resolved From/To Location FK JSON, readable Description). The generic `Lot_MoveTo` is left for non-scan callers.

### 4.3 `Workorder.TrimOut_Record`

```
@ParentLotId BIGINT, @OperationTemplateId BIGINT,
@ShotCount INT = NULL, @ScrapCount INT = NULL,
@DestinationCellLocationId BIGINT,
@AppUserId BIGINT, @TerminalLocationId BIGINT = NULL
→ Status, Message, ProductionEventId
```

The Trim OUT 1:1 **whole-LOT** move (FDS-06-006). All validations before `BEGIN TRANSACTION`: required params; LOT exists; not-blocked (inlined); destination **eligibility** (the LOT's Item must resolve at `@DestinationCellLocationId` via `v_EffectiveItemLocation`) — **no MaxParts at TrimOut** (Confirm B, §6: the destination is a FIFO-queue deposit, not a lineside cap; matches test `050`); counter sanity (non-negative); D1 cumulative-monotonic guard mirrored from `ProductionEvent_Record` (new counters ≥ the LOT's prior cumulative).

Then, in one transaction:
1. **Inline** the closing `ProductionEvent` insert (mirror of `ProductionEvent_Record` — `OperationTemplateId = TrimOut`, the final cumulative `ShotCount`/`ScrapCount`, `EventAt = SYSUTCDATETIME()`). Capture `@ProductionEventId = SCOPE_IDENTITY()`.
2. **Inline** the whole-LOT move to `@DestinationCellLocationId` (mirror of `Lot_MoveTo` — `LotMovement` + `Lot.CurrentLocationId`). The parent LOT **stays whole and open** — no split, no children, no `LotGenealogy` / closure rows. This places the LOT in the destination line's FIFO queue (read by Phase 5 via `Lot_GetWipQueueByLocation`).
3. Audit `TrimOutRecorded` (resolved destination Location + ProductionEvent FK JSON, readable Description). The LOT retains its cast/trim `ItemId` until the Machining IN rename (Phase 5).

`@ProductionEventId` is returned in the `NewId` slot.

## 5. Workflow composition (how the procs assemble — for the front-end spec)

### 5.1 Movement Scan pattern (inbound)
UI orchestration, three advisory reads then one authoritative commit: `Lot_Get(@LotName)` → `ItemLocation_CheckEligibility` (gate + message) → `Item_GetMaxParts` + `Lot_GetCellLineQuantity` (show remaining capacity) → **`Lot_MoveToValidated`** (the commit re-checks all of it server-side, so the rule cannot be bypassed even if a caller skips the reads).

### 5.2 Trim IN
`Lot_MoveToValidated` to the **Trim Shop Area** (Trim is tracked at Area resolution), **then** `ProductionEvent_Record` with the `TrimIn` template and **carried-forward** cumulative counters (Trim adds no shots). Equal counters pass P3's monotonic guard (it rejects only `< prior`). Two UI-orchestrated calls, not atomic — acceptable because a missed checkpoint does not compound (FDS-03-017a). Optional piece-count correction via `Lot_Update` (Phase 2, `LotAttributeChange` audit); scrap via `RejectEvent_Record` (Phase 3) — trim is yield loss, no rename, no genealogy edge.

### 5.3 Trim OUT
Single destination (scan or dropdown, FDS-02-009) → `TrimOut_Record` (§4.3). No multi-destination / split UX (that machinery is Phase 5 Machining OUT).

### 5.4 Receiving
`Lot_Create` with `@LotOriginTypeId='Received'`, `@CurrentLocationId=(Receiving Dock)`, NULL Tool/Cavity, `@VendorLotNumber`, `@MinSerialNumber`/`@MaxSerialNumber` (supplier serial range, validated later by Phase 6 Assembly `ConsumptionEvent`). No net-new SQL.

## 6. Design decisions (confirmed at review 2026-06-15)

- **D-MOVE — enforcement model: validated-move proc + advisory reads (CONFIRMED).** `Lot_MoveToValidated` enforces eligibility + MaxParts + not-blocked server-side and performs the move atomically; the three read procs remain for responsive UI feedback. Aligns with `feedback_no_business_logic_in_python` (the OI-12 cap and FDS-02-012 eligibility are domain rules, enforced in the proc, not the UI). Costs one proc beyond the plan's literal list; the generic `Lot_MoveTo` is untouched.
- **Confirm A — drop `ReceivingScan` (CONFIRMED).** Receiving writes no `ProductionEvent`; `LotCreated` is its audit. No `ReceivingScan` OperationTemplate, no `ReceivingScanRecorded` event.
- **Confirm B — no MaxParts at TrimOut (CONFIRMED).** `TrimOut_Record` validates destination eligibility + not-blocked only; the destination is a FIFO-queue deposit.
- **Confirm C — no data-collection fields on Trim templates (CONFIRMED).** `TrimIn` / `TrimOut` use the promoted `ShotCount`/`ScrapCount` columns; zero `OperationTemplateField` children.
- **MaxParts NULL = uncapped** is the uniform rule (no destination-tier special-casing); it is what keeps Area-resolution Trim IN moves unconstrained.

## 7. Conventions

- ASCII-only seed strings (byte-scan before applying). OperationTemplates via the active-version pattern in a **seed** file (location FK), not the migration.
- Mutations are status-row procs → their NQs (front-end spec) need `attributes.type:"Query"`.
- Append-only event/movement tables; no soft-delete. Validations before `BEGIN TRANSACTION`; `CATCH` is the only `ROLLBACK` site (INSERT-EXEC / Msg-3915 rule). Sub-mutations (move, closing checkpoint, not-blocked guard) **inlined**, never `EXEC`'d — each inline block commented as a mirror of its source-of-truth proc (`Lot_MoveTo`, `Lot_AssertNotBlocked`, `ProductionEvent_Record`).
- Audit Description follows `SUBJECT · CATEGORY · ACTION` with resolved-FK JSON; `Lot`-entity audits route to `LotEventLog`, `Workorder`-entity audits to `OperationLog`.

## 8. Test coverage — `sql/tests/0023_PlantFloor_Movement_Trim/`

| File | Covers |
|---|---|
| `010_ItemLocation_CheckEligibility.sql` | Direct match (`Path='Direct'`); BomDerived match; cascade Cell → WorkCenter → Area → Site; ineligible (no path) → `IsEligible=0, Path=NULL`. |
| `020_Item_GetMaxParts_and_Lot_GetCellLineQuantity.sql` | `MaxParts` read (set + NULL); sum-by-location-by-Item correct across multiple open LOTs; Closed LOTs excluded from the sum. |
| `030_MoveToValidated.sql` | Eligible move succeeds + `LotMovement` row + `Lot.CurrentLocationId` updated + `LotMoved` audit; MaxParts overflow rejects (OI-12 message); ineligible destination rejects (FDS-02-012 message); blocked LOT rejects; `MaxParts NULL` move is uncapped. |
| `040_TrimOut_Record_move_whole.sql` | `TrimOut_Record` moves the whole LOT to the destination; closing `ProductionEvent` written (cumulative counters, `TrimOut` template); `LotMovement` row written; LOT visible via `Lot_GetWipQueueByLocation`; parent stays open — no split, no children, no closure rows. |
| `050_TrimOut_Record_validation.sql` | Missing destination rejects; non-eligible destination rejects; blocked LOT rejects; counter regression (`< prior cumulative`) rejects. |
| `060_Lot_GetWipQueueByLocation.sql` | Arrival-order (latest `MovedAt ASC`); Closed LOTs excluded; `@IncludeDescendants=1` rolls up child locations; empty = no rows. |
| `070_Receiving_pass_through.sql` | `Lot_Create` with `LotOriginType='Received'`; vendor lot number captured; serial range captured; NULL Tool/Cavity. |

Target **55–75 assertions**. INSERT-EXEC into temp tables matching each SELECT shape; FK-safe teardown (`LotEventLog`/`OperationLog` → `LotMovement` → `ProductionEvent`/`RejectEvent` → closure → genealogy → `Lot`, per `feedback_arc2_lot_test_teardown_fk_order`). Suite stays green alongside the existing total.

## 9. Phase 4 SQL complete when

- Migration `0023` applied (LogEventType 34/35); seed `023` loads the `TrimIn`/`TrimOut` OperationTemplates (no fields).
- `ItemLocation_CheckEligibility`, `Item_GetMaxParts`, `Lot_GetCellLineQuantity`, `Lot_GetWipQueueByLocation`, `Lot_MoveToValidated`, `TrimOut_Record` delivered; `Lot_MoveTo` / `Lot_Create` confirmed reusable (untouched).
- `0023_PlantFloor_Movement_Trim` suite passes (target 55–75); full suite green.

## 10. Out of scope (→ front-end + gateway spec)

The four Perspective views (Movement Scan embedded component, Trim Station IN, Trim Station OUT, Receiving Dock); the Core Named Queries fronting the six procs (mutations `type:"Query"`); the Core entity-script modules; the page-config routes + HomeRouter tiles; and the **`LttZplDispatcher`** gateway script (consumes the Phase 2 `LotLabel_Print` `system.util.sendMessage` events → assembles ZPL → dispatches to the terminal's Zebra → writes the print-ack back to `LotLabel`). These are the second Phase 4 spec.
