# Assembly-OUT multi-printer FG routing ("printer cards") — Design

**Date:** 2026-08-06
**Status:** Draft (design approved in brainstorm; pending written-spec review)
**Origin:** FAT follow-up. Authoritative `MPP_MES_Site` model carries a placeholder Printer
child "add 10 printers" under `MA2-59B-AOUT1` ("METTs Assembly Out", Location Id 158) — the
signal that some assembly-out stations run **many** finished goods through one station and need
a clean way to route each FG's label to its own printer.

## Problem

Today the printer model is **one printer per terminal**: `Location.Terminal_GetPrinter` returns
`TOP 1` of a terminal's child Printers, `onStartup` pins that single printer into
`session.custom.printer`, and every FG label from the terminal dispatches ZPL to that one
endpoint (`BlueRidge.Lots.LotLabel.printLabel` → `_dispatchAfterRender`).

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

4. **Close + mint:** unchanged — `Workorder.Assembly_CompleteTray(@FinishedGoodItemId, @PieceCount,
   @CellLocationId, @ClosureMethod='ByCount', @AppUserId, @TerminalLocationId)` via
   `BlueRidge.Workorder.Assembly.completeTray(...)`. The card supplies `@FinishedGoodItemId`
   (its bound FG) and the entered `@PieceCount`.

## Label routing — override, don't replace

`BlueRidge.Lots.LotLabel.printLabel(...)` / `_dispatchAfterRender(...)` gain an **optional explicit
printer override** (`printerLocationId`). When provided, the endpoint/model resolve from that
printer (via `Location.Terminal_GetPrinter`-style lookup by the printer's own Id, or a small
`Printer_GetById` read) instead of `session.custom.printer`. When omitted — every existing call
site (single-printer terminals, Machining, Trim, reprint) — behavior is **byte-for-byte
unchanged**: the session printer is used.

- Card-close passes the card's `PrinterLocationId`.
- Networked printer → ZPL over TCP (as today). Hardwired / no endpoint → the existing fail-soft
  path returns `{Status:0, "no endpoint"}` and toasts; **the FG LOT + LotLabel row still exist**,
  so it is a reprint, never a lost traceability record.

## UI — the printer-card panel (setup **and** run, one screen)

Lives in the assembly-out By-Count surface (`Views/ShopFloor/AssemblyNonSerialized`). When the
station terminal has >1 child Printer, the existing single FG dropdown is replaced by the card
panel; otherwise the current dropdown flow is untouched.

- **One card per child Printer**, ordered by `SortOrder`. Each card shows: printer Code/Name; the
  **assigned FG** (PartNumber + Description) or an "Unassigned" state; Endpoint + the FAT #14
  **Validate endpoint** action; a piece-count field; a **Close** button.
- **Setup gestures:**
  - **Reorder** cards with up/down arrow buttons (no drag, per project convention) — writes
    `SortOrder` only.
  - **Assign / swap** the FG on a card: pick from the station's eligible FGs
    (`Item_ListEligibleFinishedGoodsRanked`). Choosing an FG already on another card **swaps** the
    two (the panel maintains the bijection). **Save** persists via `PrinterFgAssignment_SaveAll`.
  - **Auto-load seed:** first open with no saved rows pre-seeds each card with an eligible FG as a
    *suggestion the operator confirms/adjusts* — never a silent routing rule. A saved layout is
    restored on subsequent opens.
- **Run gesture (close-from-card):** operator boxes an FG → taps its card → enters the count →
  **Close** → `completeTray(FinishedGoodItemId=card.ItemId, pieceCount, …, closureMethod="ByCount")`
  → on success the FG label prints to **that card's printer** (routing override). Tapping the card
  *is* the FG selection, so the 10-FG ambiguity never arises.

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
- **Label routing:** a test/assertion that `_dispatchAfterRender` with an override targets the
  **override** endpoint, and that omitting it still uses `session.custom.printer` (no regression).
- **Close-from-card + panel:** manual smoke in the app (render cards, assign/swap/reorder+save,
  close a card → LOT minted + label to the correct printer; single-printer station unchanged).

## Out of scope / non-goals

- Vision (or any non-By-Count) closure routing — already implemented, untouched.
- Config-app authoring of the FG↔printer binding — the run-time panel is the only editor.
- Multi-terminal / line-wide printer pools — printers are the current terminal's children.
- Optimistic locking on the assignment table.

## Migration / deployment notes

- New versioned migration for `Location.PrinterFgAssignment` (next free number — confirm ≥ `0052`
  at implementation; other in-flight FAT work reserves `0051`).
- New repeatable procs (`PrinterFgAssignment_ListForStation`, `_SaveAll`) + Core NQs.
- `LotLabel` override is additive (default-None param) — no call-site churn.
- Applies to live `MPP_MES_Dev` idempotently; the "add 10 printers" placeholder at METTs is a
  **data** task for MPP (add the real child printers via the config app, now that #14 supports
  multiple printers per location).
