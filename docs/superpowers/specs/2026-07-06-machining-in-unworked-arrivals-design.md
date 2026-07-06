# Machining IN — "unworked arrivals at the line" (drop the BOM-consumption model)

**Date:** 2026-07-06
**Author:** Blue Ridge Automation (with Jacques)
**Status:** Approved — implement.
**Branch:** `jacques/working`

## Problem

Machining IN's FIFO queue only listed LOTs whose item is the sole `QtyPer=1` child of a
published BOM (`HasRenameBom`), and a pick ran `MachiningIn_PickAndConsume`, which
**consumed** the cast LOT and minted a *new* machined LOT via that BOM (e.g. `5G0-C` → new
`5G0-M`) + genealogy + close-source.

Two problems, per the shop-floor review:
1. **Consumption of the component belongs downstream (Assembly), not at Machining IN.** A
   machining station transforms a part; it does not consume a component into an assembly.
2. The rename-BOM gate made the queue depend on demo BOM wiring that doesn't (and shouldn't)
   exist, so the queue read empty even when LOTs were physically checked into the line.

## New model

Machining IN simply lists **any LOT checked into the line that has had no other events
attributed to it at that line** — i.e. freshly-arrived, not yet worked at any of the line's
stations. Picking a LOT **records a MachiningIn checkpoint on the same LOT** — no new LOT, no
consumption, no genealogy, no close, no item change. The LOT keeps its identity; it now has a
line event, so it leaves the "awaiting" queue and becomes the in-process LOT.

**"Event at the line"** = a `Workorder.ProductionEvent` for the LOT whose `TerminalLocationId`
is the line or a descendant of it. The Trim OUT checkpoint is stamped to the **trim** terminal,
so it does not count; the Machining IN pick stamps to the line's terminal, so it does.

## Changes

### 1. `Lots.Lot_GetWipQueueByLocation` (v2.0) — additive column
Add a computed `HasLineEvent BIT` = *does the LOT have a `Workorder.ProductionEvent` stamped to
a terminal at/under `@LocationId`?* All existing columns (incl. `HasRenameBom`) and behaviour
stay, so the other 6 callers (Assembly ×3, Machining OUT, Trim, PLC) are unaffected. Compute the
line's terminal subtree with a recursive descendants CTE (always, independent of
`@IncludeDescendants`, which still governs only LOT inclusion by `CurrentLocationId`).

### 2. Retire `Workorder.MachiningIn_PickAndConsume`; add `Workorder.MachiningIn_RecordPick`
`MachiningIn_RecordPick(@LotId, @LineLocationId, @AppUserId, @TerminalLocationId)`:
- **Validations (all before `BEGIN TRANSACTION`, FDS-11-011 / Msg-3915):** required params;
  MachiningIn OperationTemplate configured; LOT exists / not-blocked / not-Closed; LOT sits
  at/under `@LineLocationId` (ancestor walk of `CurrentLocationId`); `@TerminalLocationId`
  supplied and is at/under `@LineLocationId` (guarantees the event is attributable to the line
  so the LOT drops off the queue).
- **Mutation:** one `Workorder.ProductionEvent` (MachiningIn template, `TerminalLocationId` =
  the passed terminal, `LotId` = the same LOT, NULL counts) + `Audit.Audit_LogOperation`
  `MachiningInPicked` (Lot subject = the same LOT). `@NewId` slot = the `ProductionEventId`.
- **No** new LOT, ConsumptionEvent, LotGenealogy, source close, or item change.
Delete the `R__Workorder_MachiningIn_PickAndConsume.sql` repeatable + `DROP` the proc.

### 3. Entity `BlueRidge.Workorder.Machining`
Replace `pickAndConsume(...)` with `recordPick(lotId, lineLocationId, appUserId=None,
terminalLocationId=None)` → `workorder/MachiningIn_RecordPick`.

### 4. Machining IN view (`Views/ShopFloor/MachiningIn`) — file-authored, reconcile once in Designer
- `custom.queue` transform → LOTs where **`not HasLineEvent`** (drop the `HasRenameBom` filter).
- `custom.activeMachined` transform → LOTs where **`HasLineEvent`** (already picked / in-process),
  latest.
- Pick flow: the confirm popup message becomes a plain "Start machining LOT X?" (no "rename via
  BOM"), and the confirm handler calls `recordPick(sourceLotId, cell.locationId, appUserId,
  terminal.terminalLocationId)`.

### 5. Tests
- `0024/060_Lot_GetWipQueueByLocation` — extend `#Q`/`#Q2` with `HasLineEvent`; assert an
  unworked arrival is `HasLineEvent=0`, and after a `ProductionEvent` stamped to a terminal
  under the location it flips to `1`.
- `0027/010` — rewrite as `MachiningIn_RecordPick` happy path (event written; same LOT; LOT now
  `HasLineEvent=1` so it leaves the queue).
- `0027/020` — repurpose to `RecordPick` guards (blocked/Closed LOT rejected; not-at-line
  rejected; missing/off-line terminal rejected).
- `0027/030` — delete (BOM-lookup edge cases no longer apply).
- `0027/070`, `0027/090` — add `HasLineEvent` to their `#Q` temp tables; `090` (rework) drives
  the pick through `RecordPick` and asserts the reworked LOT re-appears as an unworked arrival.

## Out of scope (flagged follow-up)
Keep-identity means the LOT stays the cast/component item (`5G0-C`) through machining — no longer
renamed to `5G0-M`. Real component consumption must move to Assembly. The current Machining OUT /
Assembly procs assume the minted machined LOT and will need a follow-up pass. `MachiningPlc`
(Machining OUT auto-complete) takes `queue[0]` and is a no-op until commissioning (`_WATCH` empty)
— left as-is; it should later filter to `HasLineEvent` LOTs.
