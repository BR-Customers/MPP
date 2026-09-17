# OEE-Enabled Locations and Availability Roll-Up — Design Spec

**Date:** 2026-09-16
**Status:** Design, awaiting Jacques's review
**Migration:** `0090_location_is_oee_enabled` (next free number at time of writing — re-check before build)
**Supersedes:** the implicit "self-scoping" equipment rule in `Oee.ufn_ResolveDowntimeScope`
(2026-07-21) and `Oee.ufn_ResolveOeeEquipment` (2026-08-19), and the Area/WorkCenter/Cell branch
logic in `Oee.DowntimeScope_ListForTerminal` (2026-09-09).

---

## 1. Motivation

Downtime is measured differently depending on where it happens:

- **Die cast** — against a press.
- **Trim** — against a trim press.
- **Machining & Assembly** — against the *line*, because every M&A terminal resolves up to its
  WorkCenter.

That last rule is wrong for **6MA Cam Holder Line 1** (`MA2-6MACH`). Physically, Machining In feeds
a conveyor that splits into two assembly conveyors, **A** and **B**. Two operators at the main
Assembly Out terminal (`MA2-6MACH-AOUT3`) each "own" one side. A jam on side A does not stop side
B, and a Machining In stop is often invisible to assembly because of the WIP buffer (a few sets at
each station, a few more on the conveyor).

For traceability it is **one line**, and that must not change: LOTs stay line-resident, terminals
stay zoned to the line, and the location model is not restructured.

What is needed is a way to log downtime against **Machining, side A, side B, or the whole line**,
and to roll those up into a line availability figure that means something.

> The `METTs Assembly Out A/B` terminals (`MA2-6MACH-AOUT1/2`) are *not* the A/B sides. They are
> the terminals used when METTs parts are run — a different type of run. They play no part in this
> design.

### 1.1 How it works today

| Piece | Rule today |
|---|---|
| `Oee.ufn_ResolveDowntimeScope(cell)` | Walk up to the nearest **WorkCenter**; if none, return the cell itself. |
| `Oee.ufn_ResolveOeeEquipment()` | "Equipment" = self-scoping (`ResolveDowntimeScope(Id) = Id`), Cell/WorkCenter tier, not a device or store. |
| `Oee.DowntimeScope_ListForTerminal` | Branches on the terminal's zone tier: Area → equipment cells under it; WorkCenter → the line only; Cell → that cell. |
| `Oee.Shift_GetAvailability` | Per equipment: `(scheduled − ALL downtime) / scheduled`. |

The consequence: a cell placed under an M&A line can **never** be equipment, because it always
resolves up to the line. Side A / side B cannot be expressed without changing a rule, and the rule
is hard-coded in three places.

---

## 2. Decisions

| # | Decision | Source |
|---|---|---|
| D1 | Add **cells under the line** for the downtime units — the same way trim has press cells under the trim Area. No structural change to the location model. | Jacques |
| D2 | A location becomes a downtime / OEE unit only when **explicitly flagged** (opt-in). No rule-based "every equipment cell under a line". | Jacques |
| D3 | The flag is **the** filter every screen uses for downtime location selection. | Jacques |
| D4 | At 6MA the flagged units are **the line, Machining, Assembly A, Assembly B**. | Jacques |
| D5 | Downtime logged **against the line applies to every flagged station under it** — all stations are impacted. | Jacques |
| D6 | Each station computes its own availability; the line reports the **plain mean** of its stations. No capacity weights — WIP buffers make series/parallel weighting meaningless. | Jacques |
| D7 | **Planned downtime shrinks the base**; unplanned downtime reduces availability. | Jacques |
| D8 | "Planned" = `Oee.DowntimeReasonCode.IsExcused = 1`. | **Assumption — confirm** |

---

## 3. Design

### 3.1 The flag

**`Location.Location.IsOeeEnabled BIT NOT NULL DEFAULT 0`.**

Why a column and not a location attribute: attributes in the polymorphic model are declared per
`LocationTypeDefinition`, so an opt-in attribute would need a definition row for every type that can
be equipment (DieCastMachine, TrimPress, CNCMachine, AssemblyStation, ProductionLine,
SerializedAssemblyLine, InspectionStation, …), and every new type would have to remember to add one.
A column is one place, indexable, and trivially filterable. It sits on the **location** (instance),
not the definition — unlike the `IsStockLocation` precedent (0081), which is per type — because
opt-in is per instance (D2).

**Guard:** the flag may be set only on **Cell** or **WorkCenter** tier locations whose definition is
not a device or store (`Terminal`, `Printer`, `Scale`, `InventoryLocation`). Enforced in the
Location create/update procs, not in Python.

**Backfill (in the migration):** set `IsOeeEnabled = 1` for every row the *current*
`Oee.ufn_ResolveOeeEquipment()` returns, evaluated against live data at migration time, **before**
the function is redefined. Day one is a no-op:

- every die cast press, every trim press, every M&A line → flagged;
- the seed row `66B - Ins` (an InspectionStation under `66B-TC`) → **not** flagged, because it
  does not self-scope today either. (Its name "Terminal" versus type InspectionStation looks like a
  separate data issue; out of scope.)

Because the backfill reads live data, the same migration is correct in Dev and prod, including any
cells MPP has added through the Config Tool.

**Config Tool:** a checkbox "OEE / downtime enabled" in the Plant Hierarchy editor, shown for
eligible locations. `Location.Location_Create` / `Location_Update` gain an `@IsOeeEnabled`
parameter; the audit JSON includes it.

### 3.2 The 6MA cells

Three new Cell-tier locations under `MA2-6MACH`, all flagged:

| Code (proposed) | Name (proposed — MPP's wording wins) | Definition |
|---|---|---|
| `MA2-6MACH-MI` | Machining | CNCMachine |
| `MA2-6MACH-ASM-A` | Assembly A | AssemblyStation |
| `MA2-6MACH-ASM-B` | Assembly B | AssemblyStation |

- **Dev:** added to `sql/seeds/011_seed_locations_mpp_plant.sql`, flagged.
- **Prod:** created through the Config Tool after the release. Not seeded by the migration — the
  location authority is `MPP_MES_Site`.
- No terminal moves, no LOT moves, no eligibility rows. These cells are downtime units only.

### 3.3 Resolution rules

**`Oee.ufn_ResolveOeeEquipment()`** becomes: flagged and not deprecated. Same output columns. The
tier / definition exclusions move to the flag guard (3.1), so the function is a plain filter.
`ShiftOverride_ListEquipment` and `ShiftOverride_Create` keep reading it unchanged — the new 6MA
cells become overridable equipment automatically.

**`Oee.ufn_ResolveDowntimeScope(@Loc)`** becomes: the **nearest flagged location at or above**
`@Loc`; if none, `@Loc` itself (preserves today's fallback). Its only remaining use is the dropdown
default (3.4); it is no longer the definition of equipment.

**New `Oee.ufn_OeeAncestors(@Loc)`** (inline TVF): the flagged strict ancestors of a location. Used
by the roll-up (3.5) to apply line downtime to stations (D5).

> Filename ordering: functions get no deferred name resolution (Msg 4121), and repeatables deploy in
> filename order. A function called by another function must sort before its caller — check names
> before building.

### 3.4 The downtime location dropdown

**`Oee.DowntimeScope_ListForTerminal`** returns the **flagged locations in the terminal's zone
subtree, zone included**, deprecated excluded, ordered by `SortOrder` then `Code`. The
Area/WorkCenter/Cell branching is removed.

| Terminal | Zone | Rows |
|---|---|---|
| `MA2-6MACH-AOUT3` | `MA2-6MACH` (flagged) | the line, Machining, Assembly A, Assembly B |
| Other M&A line terminal | its line (flagged) | the line only — **unchanged** |
| `DC1-T1` (shared) | `DC1` (Area, not flaggable) | every flagged press under DC1 — **unchanged** |
| `DC1-M01-T1` (dedicated) | `DC1-M01` (flagged) | that press — **unchanged** |
| `TRIM1-T1` | `TRIM1` | the flagged trim presses — **unchanged** |
| Fallback / unregistered | Facility | **nothing** — unchanged |

One behavioural difference: an Area with **no** flagged cells used to return the Area itself (the
original "scoped to the Trim shop" rule). Trim presses now exist as cells and are flagged by the
backfill, so this does not occur at MPP today. After this change such an Area returns nothing; a
shop-level unit would be a new design question (Areas are not flaggable).

**Default selection (`IsDefault`)** changes:

1. Exactly one row → that row.
2. Else, if the session's active cell resolves (3.3) to a returned row **that has no flagged
   descendants** → that row. This keeps die cast behaviour: the press picked on the Die Cast screen
   is preselected.
3. Otherwise → **no default**; the operator must choose.

Rule 2's leaf restriction is the point: at 6MA the session cell *is* the line, and preselecting it
would silently turn a side-A jam into a whole-line stop charged to every station (D5).

### 3.5 Availability roll-up

`Oee.Shift_GetAvailability` is rewritten. Per shift, for every flagged location `L`:

**Leaf** (no flagged descendants):

1. **Window** — `Oee.ufn_ShiftWindowForLocation(L, …)`, override-aware, as today.
2. **Events** — non-voided events on `L` **plus** events on every location in
   `ufn_OeeAncestors(L)` (D5), each clipped to the window.
3. **Merge by time.** Overlapping intervals are unioned so a minute counts once. A minute covered by
   any **planned** event is planned; the remaining covered minutes are unplanned.
4. `BaseMinutes = WindowMinutes − PlannedDowntimeMinutes`;
   `Availability = (BaseMinutes − UnplannedDowntimeMinutes) / BaseMinutes`, floored at 0, NULL when
   `BaseMinutes = 0`.

**Roll-up** (has flagged descendants):

- `Availability` = the **unweighted mean** of its **nearest flagged descendants** (no flagged
  location between them and `L`). NULL children are excluded; all NULL → NULL.
- Its own events are **not** counted again — they are already inside every child via step 2.
- Nests: a roll-up child contributes its own mean.
- Minute columns on a roll-up row report its window and its **own** events only (for display), and
  the row carries `IsRollup = 1` so no consumer sums them.

**Worked example** — 480-min shift, 30-min lunch on the line (planned), Machining 5 min unplanned,
Assembly A 40 min unplanned:

| Unit | Base | Unplanned | Availability |
|---|---|---|---|
| Machining | 450 | 5 | 98.9% |
| Assembly A | 450 | 40 | 91.1% |
| Assembly B | 450 | 0 | 100.0% |
| **Line** | — | — | **96.7%** (mean) |

A 20-min unplanned line stop would come off all three stations and lower the line by the full
20 / 450 ≈ 4.4 points.

**Result set** — today's columns kept, with these changes:

| Column | Change |
|---|---|
| `PlannedMinutes` | **Kept, meaning unchanged** — the scheduled window. Legacy name; do not reuse it for planned *downtime*. |
| `PlannedDowntimeMinutes` | **New** — merged planned minutes. |
| `UnplannedDowntimeMinutes` | **New** — merged unplanned minutes. |
| `BaseMinutes` | **New** — `PlannedMinutes − PlannedDowntimeMinutes`. |
| `DowntimeMinutes` / `UnexcusedDowntimeMinutes` | Kept; now merged totals. |
| `RunMinutes` | `BaseMinutes − UnplannedDowntimeMinutes`. |
| `Availability` | **Meaning changes** — base-shrinking formula (D7), or the mean for a roll-up. |
| `IsRollup`, `ParentLocationId` | **New** — for tree display. |

**Blast radius of the formula change:** the only consumer found is
`BlueRidge.Oee.ShiftOverride.availability` / `availabilityOrEmpty`
(`ignition/projects/Core/ignition/script-python/BlueRidge/Oee/ShiftOverride/code.py`), and no view
references either today, so no screen shows a changed number. `_EMPTY_AVAILABILITY` gains the new
keys (fully-shaped default rule).

### 3.6 Write-side validation

`Oee.DowntimeEvent_Start`, `_RecordHistorical` and `_RecordApproximate` **reject** a location that
is not flagged: *"<Code> is not enabled for downtime."*

The caller inventory shows this **cannot ship on its own**:

| Writer | Location it passes | Effect of the rule |
|---|---|---|
| Downtime Manager popup (`Components/Popups/DowntimeManager`) | a row from `DowntimeScope_ListForTerminal` | Fine — always flagged. |
| Downtime Entry (`/shop-floor/downtime`, `Views/ShopFloor/DowntimeEntry`) | any row of `Location.listByTier('Cell')` — which **includes Terminals** and **excludes lines** | Would reject most choices. Must switch to the flagged list. |
| End of Shift (`/shop-floor/end-of-shift`, `Views/ShopFloor/EndOfShiftEntry`) → `Oee.EndOfShiftEntry_Submit` | the same `listByTier('Cell')` list; the proc **inserts `DowntimeEvent` directly**, bypassing `_Start` | Not covered unless the proc gets the same check. Lines are not selectable, so M&A breaks can't be logged against a line today. |
| `BlueRidge.Oee.DowntimePlc` watcher | `_WATCH[].cellLocationId` | `_WATCH` is empty (pre-commissioning); no effect today. Commissioning must use flagged locations. |

So the build includes:

- Downtime Entry and End of Shift take their location dropdown from a **flagged-location list**
  (`DowntimeScope_ListForTerminal` when on a registered terminal; a new `Oee.OeeLocation_List`
  otherwise). These are **existing views → Designer edits**, per the file-edit boundary.
- `Oee.EndOfShiftEntry_Submit` gets the same flagged check.
- With D5, a break logged against the line counts against every station on it — the intended
  outcome for lunch.

Events already recorded against unflagged locations are **not** modified; they simply do not count
toward availability (they don't today either).

### 3.7 Downtime Manager reads

`Oee.DowntimeEvent_GetByScope` with `@IncludeDescendants = 1` already returns events on the scope
and its children, so a line-scoped view at 6MA lists line, Machining, A and B events together. No
SQL change; confirm the popup shows each row's unit name.

`UX_DowntimeEvent_OneOpenPerLocation` needs no change: the line, A and B are different locations,
so any combination can be down at once.

---

## 4. Side effects to verify

- **`Location.Terminal_ListContextCells`** returns every non-Terminal/Printer Cell under the
  terminal's parent, so the three new cells will appear in any cell picker for a 6MA terminal. M&A
  dedicated screens bind the cell to the zone (`Terminal.bindsCellToZone`), so this is probably
  invisible — **verify in a live session**, don't assume.
- **`Location.Location_ListCellsForArea`** — same shape; check its callers.
- **Parts eligibility / WIP queue** — the new cells have no eligibility rows and no terminals, and
  `Lot_GetWipQueueByLocation` and move eligibility anchor on the terminal's zone, so no change is
  expected. Confirm with the existing test suites.

---

## 5. Testing

SQL tests (INSERT-EXEC pattern):

- **Flag guard** — create/update rejects the flag on Terminal, Printer, Scale, InventoryLocation,
  Area and Site locations.
- **Backfill** — after the migration, the flagged set equals the pre-migration self-scoping set
  (on a DB built at the prior migration state).
- **Dropdown** — the six rows of the 3.4 table, and the three default rules.
- **Write validation** — `_Start`, `_RecordHistorical`, `_RecordApproximate` and
  `EndOfShiftEntry_Submit` reject an unflagged location and accept a flagged one.
- **Roll-up** — the 3.5 worked example exactly; a line stop applied to all stations; a line event
  overlapping a station event counted once; planned overlapping unplanned counted as planned; a
  zero-base child excluded from the mean; a two-level nested roll-up.
- **Regression** — die cast press and plain M&A line availability equal today's figure when there
  are no planned events.

---

## 6. Out of scope

- **Performance and quality.** OEE here is availability only. When the full product is added,
  decide whether the line takes the mean of station OEE or the product of mean factors.
- **Per-side production counts.** Both sides tray into the shared `AOUT3` terminal, so nothing
  records which side a tray came from. Fine for downtime (the operator picks the side); a real
  design question for per-station performance later.
- **Capacity weighting** of stations — rejected (D6).
- **The `66B - Ins` naming/type mismatch** — noted, not fixed.
- **A shop-level (Area) downtime unit** — not flaggable by design (3.4).

---

## 7. Open items

1. **D8** — confirm `IsExcused` is exactly MPP's "planned downtime".
2. **Names and codes** for the three 6MA cells, from MPP.
3. **Prod creation** of the 6MA cells — who does it, and when relative to the release.
4. **Prod preview gate** — list what the backfill will flag, and every `DowntimeEvent` in the last
   30 days whose location will **not** be flagged, so affected Downtime Entry / End of Shift users
   are known before the window.
