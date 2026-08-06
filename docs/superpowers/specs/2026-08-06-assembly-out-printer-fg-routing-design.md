# Assembly-OUT multi-printer FG routing ("printer cards") — Design

**Date:** 2026-08-06
**Status:** Draft, rev 2 (design approved; revised after tracing the real close/label path —
label = container shipping label dispatched async via `ShippingDispatcher`, not a synchronous
`LotLabel` print; pending written-spec review)
**Origin:** FAT follow-up. Authoritative `MPP_MES_Site` model carries a placeholder Printer
child "add 10 printers" under `MA2-59B-AOUT1` ("METTs Assembly Out", Location Id 158) — the
signal that some assembly-out stations run **many** finished goods through one station and need
a clean way to route each FG's label to its own printer.

## Problem

Today the printer model is **one printer per terminal**: `Location.Terminal_GetPrinter` returns
`TOP 1` of a terminal's child Printers, `onStartup` pins that single printer into
`session.custom.printer`, and **both** label-dispatch paths resolve their endpoint from that one
session printer — LTT labels via `BlueRidge.Lots.LotLabel` and **container shipping labels via
`BlueRidge.Lots.ShippingDispatcher.dispatch`** (the label that prints when an FG box is completed).

Some assembly-out stations (e.g. METTs) box **~10 distinct finished goods** at one station,
each into its own container, **closed By-Count**, each needing its label on a **different
physical printer**. Two things break there:

1. **No per-FG printer routing** — one session printer can't send 10 FGs to 10 printers.
2. **FG-selection ambiguity** — the By-Count close resolves which FG to close via
   `Parts.Item_ListEligibleFinishedGoodsRanked(@LocationId)` (eligible FinishedGoods at the
   station with an active published BOM, ranked by BOM-line satisfiability). With 10 FGs all
   eligible at once, "closest BOM alignment" cannot cleanly say *which* FG the operator is
   boxing.

Both dissolve if the operator interacts with a **card per printer**, each card bound to one FG:
tapping a card selects the FG *and* the printer at once.

## Scope

- **By-Count assembly-out close only.** Vision closure is already implemented and is explicitly
  **out of scope** — no changes, no future-build hooks.
- The card panel activates **only when the station terminal has >1 child Printer**. A
  single-printer station keeps today's exact behavior (session printer + existing FG dropdown) —
  **no regression** for the ~60 single-printer terminals.
- No config-app UI for the binding — it is created and edited entirely from the run-time panel
  (self-teaching). The config app's per-printer Endpoint / ConnectionKind / Validate work
  (FAT #14) is reused as-is on each card.

## Core model

A finished good is bound to a printer **by identity** — `ItemId ↔ PrinterLocationId` — one FG per
printer, one printer per FG within a station (a strict 1:1). The binding is what routes a label;
**card display order is cosmetic and never affects routing.** This is the deliberate guard
against a fragile *positional* map (where adding/removing/reordering a printer would silently
send labels to the wrong physical box — a mislabel/containment defect on a Honda-traceable line).

## Data model

New table **`Location.PrinterFgAssignment`**:

| Column | Type | Notes |
|---|---|---|
| `Id` | `BIGINT IDENTITY` PK | surrogate |
| `PrinterLocationId` | `BIGINT` FK → `Location.Location(Id)` | the child Printer (DefId 16). **UNIQUE** (one FG per printer) |
| `ItemId` | `BIGINT` FK → `Parts.Item(Id)` | the assigned FinishedGood |
| `SortOrder` | `INT` | card display order (cosmetic) |
| `CreatedAt` / `LastEditedAt` | `DATETIME2(3)` UTC | `GETUTCDATETIME()` |
| `CreatedByAppUserId` / `LastEditedByAppUserId` | `BIGINT` FK → `AppUser(Id)` | attribution |

- **One FG per printer** — DB-enforced by `UNIQUE(PrinterLocationId)`.
- **One printer per FG per station** — enforced in the `_SaveAll` proc (it rejects a payload that
  assigns the same `ItemId` to two of the station's printers), *not* by a DB index: `ItemId` is
  only unique *within* a station, and a station is "the printers under one terminal", which a
  single-column index cannot express. The panel's swap semantics already preserve this bijection;
  the proc is the backstop.
- No `DeprecatedAt`: rows are hard-managed by the SaveAll reconcile (a printer with no FG has no
  row; removing an assignment deletes the row). This table is small (printers per station) and
  fully derived from the current panel state.

The assignment references cross-schema (`Location` → `Parts.Item`), consistent with existing
`Parts.ItemLocation` → `Location.Location`.

## Stored procedures / named queries

All follow FDS-11-011 (no OUTPUT params; status-row mutations) and the audit Description
convention. NQs live in Core (`named-query/location/…`).

1. **`Location.PrinterFgAssignment_ListForStation(@StationTerminalLocationId)`** — read. One row
   per **child Printer** of the terminal (LEFT JOIN the assignment so unassigned printers appear),
   projecting: `PrinterLocationId`, printer `Code`/`Name`, `Endpoint`, `ConnectionKind`,
   `AssignedItemId` (nullable), FG `PartNumber`/`Description` (nullable), `SortOrder`. Ordered by
   `SortOrder, printer Id`. Empty set = terminal has no printers. This is the card list.

2. **`Location.PrinterFgAssignment_SaveAll(@StationTerminalLocationId, @AppUserId, @AssignmentsJson)`**
   — bundled mutation (per the project SaveAll pattern). `@AssignmentsJson` = desired-state array
   `[{PrinterLocationId, ItemId|null, SortOrder}]`. Reconciles: upsert rows with a non-null
   `ItemId`, delete rows whose `ItemId` is now null, rewrite `SortOrder`. Rejects (Status=0) if:
   a `PrinterLocationId` isn't a child Printer of the station; an `ItemId` isn't a FinishedGood
   eligible at the station; or the same `ItemId` appears on two printers. Emits one
   `Audit.ConfigLog` row. Returns the status row.

3. **Eligible-FG source:** reuse existing `Parts.Item_ListEligibleFinishedGoodsRanked(@LocationId)`
   for the "assignable FGs" picker and the auto-load seed. (`@LocationId` = the station's
   zone/cell that FG eligibility is scoped to, resolved from the session terminal — the same
   location the current By-Count dropdown already passes.)

4. **Tray mint (unchanged):** `Workorder.Assembly_CompleteTray(@FinishedGoodItemId, @PieceCount,
   @CellLocationId, @ClosureMethod='ByCount', @AppUserId, @TerminalLocationId)` via
   `BlueRidge.Workorder.Assembly.completeTray(...)` mints each tray LOT for the card's FG into that
   FG's open container. **No label prints on a tray mint** — that was never a print point.

5. **`Location.Printer_GetById(@PrinterLocationId)`** — read. Returns `{LocationId, Code, Endpoint,
   Model, ConnectionKind}` for one Printer so a dispatch can resolve a target endpoint from a
   printer id. (`Location.Terminal_GetPrinter` resolves a Terminal's `TOP 1` child printer — it
   cannot resolve a *specific* printer by id.)

## Label routing — the box shipping label, derived at dispatch

**Correction to the naive assumption.** The label that physically prints for a boxed FG is the
**container shipping label**, not a per-mint LTT label. `Lots.Container_Complete` (a proc, no TCP)
*generates* the `ShippingLabel` + AIM shipper; the ZPL is dispatched separately by
`BlueRidge.Lots.ShippingDispatcher.dispatch(aimShipperId, terminalLocationId)`, which resolves the
printer from `session.custom.printer`. (A `PrintFailureGateway` sweep re-fires stranded labels but
is a deferred skeleton.)

**Change:** `ShippingDispatcher.dispatch` gains an optional **`printerLocationId` override**. When
provided, the endpoint is **derived at dispatch** from `Location.Printer_GetById(printerLocationId)`
rather than the session printer; when omitted, behavior is **unchanged** (session printer) for every
other caller (Shipping dock, PLC path, sweep). The by-count card's **Complete (box)** action passes
the card's `PrinterLocationId`.

This also **closes a current gap**: the operator container-Complete path does not dispatch
synchronously today (the view's Complete handler only calls `Container.complete`). The card path
will call `Container.complete`, then — on success — `ShippingDispatcher.dispatch(aimShipperId,
terminalLocationId, printerLocationId=card.PrinterLocationId)`.

- Networked printer → ZPL over TCP (as today). Hardwired / no endpoint → the existing fail path
  leaves `ShippingLabel.PrintedAt` NULL (a stranded label) and toasts — the container +
  shipping-label rows still exist, so it is re-dispatchable, never a lost traceability record.
- **Async sweep (future, out of scope):** when `PrintFailureGateway` is commissioned it will derive
  the same target from the stranded label's **container FG → `PrinterFgAssignment` at the station**.
  No sweep code or resolver proc is built here; the `printerLocationId` override is the seam it will
  use.

## UI — the printer-card panel (setup **and** run, one screen)

Lives in the assembly-out By-Count surface (`Views/ShopFloor/AssemblyNonSerialized`). When the
station terminal has >1 child Printer, the existing single FG dropdown is replaced by the card
panel; otherwise the current dropdown flow is untouched.

- **One card per child Printer**, ordered by `SortOrder`. Each card shows: printer Code/Name; the
  **assigned FG** (PartNumber + Description) or an "Unassigned" state; the FG's **open-container
  fill** (accumulated / target trays, from `Container_GetOpenByCell`); Endpoint + the FAT #14
  **Validate endpoint** action; a tray piece-count field with **Complete Tray**; and a **Complete
  (box)** action shown when that FG's container is full.
- **Setup gestures:**
  - **Reorder** cards with up/down arrow buttons (no drag, per project convention) — writes
    `SortOrder` only.
  - **Assign / swap** the FG on a card: pick from the station's eligible FGs
    (`Item_ListEligibleFinishedGoodsRanked`). Choosing an FG already on another card **swaps** the
    two (the panel maintains the bijection). **Save** persists via `PrinterFgAssignment_SaveAll`.
  - **Auto-load seed:** first open with no saved rows pre-seeds each card with an eligible FG as a
    *suggestion the operator confirms/adjusts* — never a silent routing rule. A saved layout is
    restored on subsequent opens.
- **Run gesture (close-from-card):** the operator works entirely within an FG's card. Per boxed
  tray: enter the piece count → **Complete Tray** → `completeTray(FinishedGoodItemId=card.ItemId,
  pieceCount, …, closureMethod="ByCount")` mints the tray LOT into that FG's open container (no
  print). When the container fills: **Complete (box)** → `Container.complete(container.Id, …)` then
  `ShippingDispatcher.dispatch(aimShipperId, terminalLocationId, printerLocationId=card.PrinterLocationId)`
  prints the box's shipping label to **that card's printer**. Acting on the card *is* the FG
  selection, so the 10-FG ambiguity never arises. (Each FG keeps its own open container at the cell —
  `Container_GetOpenByCell` already returns a list.)

## Edge cases

- **1:1 is the expected setup** (10 FGs ↔ 10 printers). If **eligible FGs > printers**, the
  un-carded FGs appear in an "Unassigned FGs" list; an operator must assign one onto a card before
  it can be closed (no silent drop). **Spare printers** simply show an empty card.
- **Printer or FG added/removed:** the panel reconciles on load — a new child Printer = empty card;
  a removed printer's assignment row is cleaned by the next SaveAll; an FG no longer eligible greys
  out. Never silently re-routes.
- **Endpoint health:** each card's Validate action (FAT #14) lets setup catch a dead/mistyped
  endpoint before the run; a Hardwired card is labelled "cannot validate here."
- **Concurrency:** the panel is shared station setup; last-write-wins on SaveAll is acceptable for
  this low-frequency setup action (no optimistic-lock requirement in v1).

## Testing

- **SQL:** `PrinterFgAssignment_ListForStation` (unassigned printers appear; FG join) and
  `_SaveAll` (assign, swap keeps 1:1, reorder rewrites only SortOrder, reject non-child printer /
  non-eligible FG / duplicate FG). TDD red→green on a throwaway DB.
- **`Printer_GetById`:** returns the right endpoint/model for a printer id; empty set for an unknown
  id.
- **Label routing:** `ShippingDispatcher.dispatch` with a `printerLocationId` targets that printer's
  endpoint (via `Printer_GetById`), and omitting it still resolves `session.custom.printer` (no
  regression to Shipping-dock / PLC callers). Verified gateway-side (the socket path can't be
  asserted in a pure SQL test — assert endpoint *resolution*, smoke the actual dispatch).
- **Close-from-card + panel:** manual smoke in the app (render cards, assign/swap/reorder+save;
  Complete Tray mints into the FG's container; Complete box → shipping label to the correct printer;
  single-printer station unchanged).

## Out of scope / non-goals

- Vision (or any non-By-Count) closure routing — already implemented, untouched.
- Config-app authoring of the FG↔printer binding — the run-time panel is the only editor.
- Multi-terminal / line-wide printer pools — printers are the current terminal's children.
- Optimistic locking on the assignment table.

## Migration / deployment notes

- New versioned migration for `Location.PrinterFgAssignment` (next free number — confirm ≥ `0052`
  at implementation; other in-flight FAT work reserves `0051`).
- New repeatable procs (`PrinterFgAssignment_ListForStation`, `_SaveAll`, `Printer_GetById`) + Core NQs.
- `ShippingDispatcher.dispatch` gains a `printerLocationId=None` default param — additive, no
  churn to Shipping-dock / PLC callers.
- Applies to live `MPP_MES_Dev` idempotently; the "add 10 printers" placeholder at METTs is a
  **data** task for MPP (add the real child printers via the config app, now that #14 supports
  multiple printers per location).
