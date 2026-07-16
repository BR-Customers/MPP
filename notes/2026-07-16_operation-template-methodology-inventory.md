# Operation-template execution methodology — inventory & audit

**Date:** 2026-07-16
**Why:** The Trim OUT / Machining OUT / Machining IN "template missing" bugs revealed
that the same concept — *resolve the OperationTemplate for a step and record its
event* — is implemented several different ways. This is an inventory of every
operation step, how it resolves its template, and how it executes, so we can
converge on a single abstract methodology.

## Inventory (per OperationType role)

| # | Step (role) | Entry screen → call path | Template resolution — **where** & **how** | Execution proc | Event / pattern |
|---|---|---|---|---|---|
| 1 | **DieCast** (OriginMint) | DieCastBody.`submitCreate` → `Lot.create` → `Lot_Create` | **View Python**, route-aware `getActiveTemplateIdForRoute(item,"DieCast")` — used only as a **GATE** (existence check); the template id is **not** passed to `Lot_Create` | `Lot_Create` | OriginMint. No ProductionEvent / no template on the event |
| 2 | **DieCastShot** (data-collection checkpoint) | DieCastEntry/CheckpointPanel binding → `ProductionEvent.record` | **View binding**, **CODE-MATCH** `getActiveTemplateIdByCode("DieCastShot")` ⚠️ (only surviving code-match) | `ProductionEvent_Record` (receives `@OperationTemplateId`) | Checkpoint |
| 3 | **TrimIn** (Advance) | TrimBody/MovementScan → `trimInMoved` → `ProductionEvent.recordTrimInCheckpoint` | **Core Python recorder**, route-aware `getActiveTemplateIdForRoute(lot.item,"TrimIn")` | MovementScan move **+** `ProductionEvent_Record` | Move + Advance checkpoint |
| 4 | **TrimOut** (Advance/close) | TrimBody.`submitTrimOut` → `TrimOut.record` | **View Python**, route-aware `getActiveTemplateIdForLot(lot,"TrimOut")` *(fixed 2026-07-16)* | `TrimOut_Record` (receives `@OperationTemplateId`) | Closing ProductionEvent + route + move |
| 5 | **MachiningIn** (Advance) | MachiningIn → `bomRenameResult` → `Machining.recordPick` | **Inside the SQL proc**, route-aware *(fixed 2026-07-16)* | `MachiningIn_RecordPick` (resolves internally) | Advance checkpoint (ProductionEvent) |
| 6 | **MachiningOut** (ConsumeMint) | MachiningOutSplit binding → `Machining.mint` | **View binding**, route-aware `getActiveTemplateIdForLot(parentLot,"MachiningOut")` *(fixed 2026-07-16)* | `MachiningOut_Mint` (receives `@OperationTemplateId`, **validates ConsumeMint role**) | ConsumeMint (ConsumptionEvent + MachiningOut ProductionEvent) |
| 7 | **AssemblyIn** | AssemblyIn → `Assembly.scanIn` | **NONE** — no template resolved | `Assembly_ScanIn` | **Move only** — LotMovement, **no ProductionEvent checkpoint** |
| 8 | **AssemblyOut** (ConsumeMint) | Assembly → `Assembly.completeTray` | **NONE** — no template resolved | `Assembly_CompleteTray` | ConsumeMint (mints FG Lot + ConsumptionEvent) — **no OperationTemplate at all** |

## The inconsistencies (five axes)

**Axis 1 — WHICH LAYER resolves the template:** view Python (1, 4) · view binding
(2, 6) · Core Python recorder (3) · inside the SQL proc (5) · nobody (7, 8). Five
different layers for one concept.

**Axis 2 — HOW it resolves:** route-aware by item (1, 3) · route-aware by lot
(4, 6) · route-aware in SQL (5) · **code-match** (2 ⚠️) · not resolved (7, 8).

**Axis 3 — Does the execution proc RECEIVE or RESOLVE the template:** receives a
`@OperationTemplateId` param (2, 4, 6) · resolves it internally (5) · neither (7, 8).

**Axis 4 — Do "IN"/Advance steps record a checkpoint?** TrimIn (3) and MachiningIn
(5) record a ProductionEvent checkpoint; **AssemblyIn (7) is move-only** — no
checkpoint. → Confirm whether the route-driven queue needs an AssemblyIn Advance
event to progress, or Assembly intentionally advances differently.

**Axis 5 — Do ConsumeMints validate a template?** MachiningOut (6) receives +
validates a ConsumeMint OperationTemplate; **AssemblyOut (8) mints with no
template**. → Two consume-mints, two different contracts.

## Recommendation — single abstract methodology

**Resolve the template in ONE place, the same way, for every step: a single SQL
function `Parts.ufn_OperationTemplateForLotRole(@LotId, @RoleCode)`** (route-aware:
LOT → item → latest non-deprecated route → step of that OperationType role),
called by **each execution proc**. Then:

1. **Views/Python stop resolving templates.** They pass only `lotId` (+ the proc
   already knows its own role). Retire the per-screen `getActiveTemplateIdByCode` /
   `getActiveTemplateIdForLot` / `getActiveTemplateIdForRoute` calls from the
   execution path. (Keep a thin read wrapper only where a screen needs the id
   *pre-flight* for a UI gate, e.g. the Die Cast "can this part run" check.)
2. **Every "record"/"mint" proc resolves internally** via the function — the
   MachiningIn pattern generalized. `TrimOut_Record`, `MachiningOut_Mint`,
   `ProductionEvent_Record` change from *receiving* `@OperationTemplateId` to
   *resolving* it from `@LotId` + their known role.
3. **Close the gaps** (design decisions for Jacques): (a) should AssemblyIn record
   an AssemblyIn Advance checkpoint like MachiningIn? (b) should AssemblyOut resolve
   + validate an AssemblyOut ConsumeMint template like MachiningOut? (c) is
   DieCastShot a genuine *named* template (justifying by-code lookup) or should it
   also be route-role-resolved?

This puts template resolution in the SQL layer (matches the no-business-logic-in-
Python rule), makes every operation proc self-contained (given a LOT it finds its
own template), and eliminates all five axes of divergence.

## Status of the bugs that exposed this
- Trim OUT / Machining OUT (view lookups) — FIXED (getActiveTemplateIdForLot).
- Machining IN (SQL code-match) — FIXED (route-aware in proc).
- Remaining code-match: DieCastShot (CheckpointPanel) — flagged, not fixed.
- Convergence to the single methodology above — NOT started (this inventory is step 1).
