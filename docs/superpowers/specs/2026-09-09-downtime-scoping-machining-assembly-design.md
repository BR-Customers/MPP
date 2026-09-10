# Downtime Scoping at Machining & Assembly — Design Options

**Date:** 2026-09-09
**Status:** **BLOCKED — awaiting a decision from Jacques. Nothing in this document is implemented.**
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor) — Phase 8 downtime, day-one deployment feedback item 3.
**Shipped alongside (NOT blocked):** die cast machine picker + trim-shop scoping — `Oee.DowntimeScope_ListForTerminal`, migration `R__Oee_DowntimeScope_ListForTerminal.sql`, tests `0026_PlantFloor_Downtime_Shift/120_DowntimeScope_ListForTerminal.sql`.
**Touches if adopted:** `Oee.ufn_ResolveDowntimeScope`, `Oee.ufn_ResolveOeeEquipment`, `Oee.Shift_GetAvailability`, `Oee.ShiftOverride_ListEquipment`, `Oee.ShiftOverride_Create`, `Oee.DowntimeEvent_Start` (B3 invariant), `Oee.DowntimeEvent` rows already in prod.

> ⚠️ **Prod went live 2026-09-09.** Every option below except A and B changes the meaning of `Oee.DowntimeEvent.LocationId`, which is the axis OEE availability is computed on. Read §5 before choosing.

---

## 1. The request

Verbatim, from the day-one deployment feedback:

> "at die cast, the downtime popup needs to have a drop down for machine, at trim shop it needs to be scoped to the Trim shop and **the machining and assembly line it needs to default to the current terminal but have a dropdown to select from all terminals in that machining and assembly line**"

Die cast and trim are unambiguous and are **built and shipped**. The M&A clause is not, because taken literally it moves M&A downtime from **line** granularity to **terminal** granularity — a data-model change with OEE and reporting consequences, not a UI change.

## 2. What the system does today

`Oee.ufn_ResolveDowntimeScope(@CellLocationId)` walks **up** from any cell/terminal to its nearest `WorkCenter` ancestor. For Machining & Assembly that is always the **line**:

```
MA1-5GOR-MIN  (Terminal)  ->  MA1-5GOR  (WorkCenter / ProductionLine)   <- downtime lands here
MA1-5GOR-MOUT (Terminal)  ->  MA1-5GOR
MA1-5GOR-ASER (Terminal)  ->  MA1-5GOR
```

Three consequences follow from that, and all three are load-bearing:

1. **Any terminal on the line sees and acts on the same events.** An operator at Machining IN can end a downtime that the Assembly OUT operator started. That is deliberate — the line is down, not the station.
2. **`Oee.DowntimeEvent_Start` enforces "one open event per `LocationId`" (invariant B3).** At line granularity that means **a line can be down at most once at a time.**
3. **`Oee.ufn_ResolveOeeEquipment` defines "a piece of equipment" as a location that is *self-scoping* under `ufn_ResolveDowntimeScope`** (`ufn_ResolveDowntimeScope(Id) = Id`), minus devices and stores. So the M&A **line is the OEE equipment**; its terminals are not. In Dev that function currently returns **44** equipment rows (22 die cast presses + 21 production lines + 1 inspection line). `Oee.ShiftOverride_ListEquipment` (the picker) and `Oee.ShiftOverride_Create` (the validation) both read it, so it also governs per-equipment shift overrides.

## 3. A fact that settles half the ambiguity

The question "does he mean the line's **terminals** or its **cells/stations**?" has an answer in the data: **there is no station layer under an M&A line.** Every active descendant of a `WorkCenter` in the plant model is a `Terminal` or a `Printer`:

| Definition under a WorkCenter (active, Dev) | Count |
|---|---|
| `Terminal` | 59 |
| `Printer` | 40 |
| `ProductionLine` (one nested line, `AO-OP` under `MA2-6FBCHOP`) | 1 |
| `InspectionStation` (under `INSP-SORT`) | 1 |

So "all terminals in that machining and assembly line" can only mean the **Terminal locations** — `MA1-5GOR-MIN`, `MA1-5GOR-MOUT`, `MA1-5GOR-ASER`, and so on. Terminals per line range from 1 (`MA2-COS`, `MA2-6F9TC`) to 9 (`MA2-RPYCAM2`).

This matters because a Terminal is an **operator IO device**, not a machine. `ufn_ResolveOeeEquipment`'s header says so in as many words, and excludes Terminals from the OEE equipment set for exactly that reason: *"A terminal is an operator IO device and a rack is a store — neither runs a shift, and neither can have downtime meaningfully attributed to it."* Choosing option C or D below means overturning that judgement, or accepting that "the terminal" is a stand-in for "the station a terminal sits at".

## 4. The options

### Option A — Status quo. No picker at M&A.

The Downtime Manager at an M&A terminal keeps showing the line, with no dropdown (which is what it does today, and what the shipped die-cast/trim work leaves it doing — the picker hides itself when there is only one scope).

- **Cost:** zero. Already true.
- **What it does not solve:** an operator cannot say *which* station on the line stopped, and any station's operator can end any other's event.

### Option B — Attribution, not scope. (Lowest risk.)

Downtime keeps landing on the **line**. Add `Oee.DowntimeEvent.OriginTerminalLocationId BIGINT NULL FK -> Location.Location(Id)`, stamped from the `@TerminalLocationId` the mutation procs **already receive and already write to the audit log** but currently discard on the event row. The Downtime Manager gains a "Station" column and a station filter over the line's terminals, defaulting to the current terminal.

- **Grain:** unchanged. `LocationId` still means "the line".
- **OEE:** completely untouched. `ufn_ResolveOeeEquipment` unchanged, availability unchanged, shift overrides unchanged.
- **B3 invariant:** unchanged — still one open event per line.
- **History:** existing prod rows get `NULL` and read as "station not recorded". No backfill needed, no mixed-grain problem.
- **Effort:** one versioned migration (nullable column + FK), four mutation procs stamp it, `DowntimeEvent_GetByScope` returns it, one UI column + one filter dropdown.
- **What it does not solve:** two stations on one line still cannot be down independently — the second `Start` is rejected by B3.

### Option C — Move the M&A scope to the terminal. (Literal reading.)

`ufn_ResolveDowntimeScope` stops walking up for M&A; an M&A terminal resolves to itself. The picker lists the line's terminals and defaults to the current one.

- **Grain:** changes. `LocationId` means "the station".
- **OEE — this is the problem.** `ufn_ResolveOeeEquipment` admits any self-scoping location that is not a device or a store. Terminals are explicitly excluded as devices, so **M&A would drop out of the OEE equipment set entirely** unless that exclusion is also lifted — and lifting it admits all 59 M&A terminals *plus* the 10 die-cast-area terminals that self-scope today and are excluded on purpose. Either way the OEE equipment set stops meaning what it means now.
- **Per-equipment shift windows do not exist at terminal grain.** `Oee.Shift_GetAvailability` takes `PlannedMinutes` from `Oee.ufn_ShiftWindowForLocation`, and `Oee.ShiftOverride` is authored per equipment. Nothing today authors a window for a terminal.
- **History becomes mixed-grain.** Every existing M&A row sits on a line that the picker would no longer offer. Downtime-by-line reporting across the cutover date silently compares a line-grain past with a station-grain present. Backfilling is not possible — the row does not record which station it came from (that is what Option B adds).
- **B3 invariant:** now per terminal. Several stations on one line can be down simultaneously. That may be exactly what MPP wants, or it may produce a line whose stations sum to more downtime than the shift is long.
- **Effort:** high, and it is a live-data migration decision, not a refactor.

### Option D — Log at the terminal, roll up to the line for OEE. (Middle path.)

`Oee.DowntimeEvent.LocationId` becomes the terminal (as in C), but `ufn_ResolveOeeEquipment` keeps returning **lines**, and `Oee.Shift_GetAvailability` sums downtime over the equipment's **subtree** rather than by exact `LocationId` match.

- **Grain:** changes at the event, is preserved at the report.
- **OEE:** equipment set unchanged (44 rows); availability keeps its current denominator and its current meaning; shift overrides keep working.
- **B3 invariant:** per terminal, same as C — independent station downtime becomes possible.
- **The trap to name up front: overlapping minutes double-count.** If Machining IN and Assembly OUT are both down 20:00–20:30, a naive subtree `SUM(DurationMinutes)` charges the line 60 minutes of downtime for a 30-minute stoppage, and availability can go **negative**. The roll-up has to be an **interval union** over the subtree, not a sum. That is real work in `Shift_GetAvailability`, which already does time-overlap arithmetic against the shift window and would now need overlap arithmetic *between events too*.
- **History:** the same mixed-grain problem as C at the event level, but reporting is insulated because the roll-up reads descendants — the existing line-grain rows sit at the root of their own subtree and still count. This is the one option where **history keeps reading correctly**.
- **Effort:** medium-high. One-line change to the resolver, a genuinely careful change to the availability proc, plus the picker.

## 5. Recommendation

**Ship nothing here until Jacques answers question 1 below.** If forced to pick blind:

> **Recommend Option B now, and Option D only if MPP confirms they want stations to go down independently.**

Reasoning:

- Option B delivers the *visible* half of the request — "which station", defaulting to the current terminal — with **zero** risk to OEE, zero migration of live data, and no mixed-grain history. It is reversible.
- Option B is also a **prerequisite for doing C or D well later**: once `OriginTerminalLocationId` is being stamped, the historical rows carry the station, and a later move to station grain has something to backfill from. Doing D first throws that away permanently.
- Option D is the right *destination* if the operational need is real (two stations down at once), but it is a change to how a live OEE number is computed, six days into production. It wants its own spec, its own cutover section, and a decision about the double-counting rule that only MPP can make (does a line with two stations down for the same 30 minutes report 30 minutes down, or 60?).
- Option C is not recommended in any scenario: it takes the OEE consequences of D without the mitigation.

## 6. Questions for Jacques (and, through him, MPP)

1. **Do two stations on one M&A line need to be able to be "down" independently at the same time?**
   - *No* → Option B. Done, low risk.
   - *Yes* → Option D, and it needs its own cutover plan.
2. **Should OEE availability at M&A be reported per station, or stay per line?** Every answer other than "stay per line" means `Oee.ufn_ResolveOeeEquipment`, `Oee.ShiftOverride` and `Oee.Shift_GetAvailability` are all in scope, and there is no per-terminal shift window today.
3. **If a line's stations are down for overlapping periods, what is the line's downtime?** The union of the intervals (30 min for two stations both down 20:00–20:30), or the sum (60 min)? Union is almost certainly right, and is the harder implementation.
4. **Is "terminal" the right noun, or does MPP mean a physical station that the plant model does not have yet?** There is no cell layer under an M&A line — only Terminals and Printers (§3). If MPP thinks in terms of stations that are not 1:1 with HMIs, the fix may be a **plant-model** change (add `AssemblyStation` / `CNCMachine` cells under the lines) rather than a downtime change — and then the shipped die-cast rule handles M&A automatically, because `Oee.DowntimeScope_ListForTerminal` already returns "the equipment cells beneath the zone" whenever any exist.

**Question 4 is worth asking first.** If MPP models real stations under the M&A lines, none of options B/C/D are needed: the code shipped today already offers a per-machine dropdown the moment equipment cells appear beneath a zone, and `ufn_ResolveOeeEquipment` would admit those cells as equipment on its existing rules.

---

## 7. What was shipped on 2026-09-09 (context, not part of this decision)

`Oee.DowntimeScope_ListForTerminal(@TerminalLocationId, @ActiveCellLocationId)` resolves a terminal to the downtime units its operator may log against, keyed entirely on the tier of the terminal's **zone** (its immediate parent):

| Zone tier | Example | Rows returned |
|---|---|---|
| `WorkCenter` | `MA1-5GOR-MIN` → `MA1-5GOR` | the line (1 row) — **M&A behaviour unchanged** |
| `Cell` | `DC1-M01-T1` → `DC1-M01` | that press (1 row) |
| `Area` **with** equipment cells | `DC1-T1` → `DC1` | all 11 presses; default = the operator's active cell, else none |
| `Area` **without** equipment cells | `TRIM1-T1` → `TRIM1` | the trim shop itself |
| `Site` (fallback terminal) | `FALLBACK-TERMINAL` → `MPP-MAD` | **nothing** — never plant-wide downtime |

The Downtime Manager popup hides its picker when there is only one scope, so M&A and trim operators see no new control; die cast operators get an 11-entry machine dropdown. Adopting Option B changes none of this. Adopting C or D changes the first row of that table only.
