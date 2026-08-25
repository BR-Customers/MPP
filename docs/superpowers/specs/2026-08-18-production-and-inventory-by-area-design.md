# Production & Inventory by Area — Design

**Date:** 2026-08-18
**Source:** FAT Day 1 punch list item 4 — *"need a report totaling production by building, daily and current inventory (its own task)"*
**Status:** Draft for review. Two decisions marked **CONFIRM** below; everything else is settled.

---

## 1. What was decided at FAT

| | Decision |
|---|---|
| **"Building"** | **= Area** (Jacques, 2026-08-18). No new location tier. |
| **"Daily"** | **Shift-anchored production day**, running **3rd → 1st → 2nd**. Not a calendar-date cut. |

Both matter. The plant hierarchy is fixed at five ISA-95 tiers — Enterprise → Site → **Area** → WorkCenter → Cell — and every area already hangs directly off `MPP-MAD`:

| Area | Name | Kind |
|---|---|---|
| `DC1`–`DC4` | Die Cast 1–4 | ProductionArea |
| `TRIM1`, `TRIM2` | Trim Shop 1–2 | ProductionArea |
| `MA1`, `MA2` | Machining & Assembly 1–2 | ProductionArea |
| `WHSE` | Warehouse | SupportArea |
| `SHIPIN` / `SHIPOUT` | Shipping IN / OUT | SupportArea |

So the roll-up is *"walk each event's terminal up to its ancestor Area"* — no schema change.

---

## 2. The production day

**Rule: a shift instance belongs to the production day on which it ENDS.**

This derives the whole thing from the schedule with no hardcoded shift names:

| Shift | Runs | Ends | Production day |
|---|---|---|---|
| 3rd | Mon 23:00 → Tue 07:00 | Tue | **Tue** |
| 1st | Tue 07:00 → Tue 15:00 | Tue | **Tue** |
| 2nd | Tue 15:00 → Tue 23:00 | Tue | **Tue** |

That reproduces 3rd → 1st → 2nd exactly, keeps the midnight-spanning 3rd shift with the day it feeds, and needs no `ShiftSchedule.Name` parsing — which matters, because shift names are free text a config user can change.

**Why not `CAST(EventAt AS DATE)`:** a calendar cut splits 3rd shift across two report rows, so Monday would show a partial night and Tuesday a partial night from a *different* shift. That was the failure mode flagged at FAT.

**Implementation.** `Oee.Shift` carries `ActualStart` / `ActualEnd`, and `Oee.Shift_Reconcile` already materializes one row per scheduled instance — so the grouping key exists. The production day is:

```sql
CAST(DATEADD(SECOND, -1, ISNULL(s.ActualEnd, <scheduled end>)) AS DATE)
```

The `-1 second` guards the boundary case where a shift ends exactly at midnight (a 15:00–00:00 2nd shift would otherwise roll into the next day). `ActualEnd` is NULL for the currently-open shift, so it falls back to the scheduled end derived from `ShiftSchedule.StartTime`/`EndTime` — that makes today's in-progress shift report against today rather than vanishing.

> **CONFIRM 1 — does "ends on" match how MPP labels a production day?** The alternative convention labels the day by when 3rd shift *starts* (so the table above would read Monday). Everything downstream is one `DATEADD` either way, but the label must match what the plant calls it.

**Events with no shift.** `Workorder.ProductionEvent` has no `ShiftId`; events are attributed to a shift by timestamp containment (`EventAt` between the instance's start and end). An event falling in a schedule gap therefore lands in **no** shift. The report SHALL surface those in an explicit **"Unassigned"** bucket rather than dropping them — this is the same silent-disappearance failure mode already identified for `Oee.DowntimeEvent.ShiftId` (punch list item 5), and it must not be repeated here.

---

## 3. What counts as "production"

The terminal-mint model means areas do structurally different things, so a single naive measure under-reports:

- **Die Cast** (`OriginMint`) mints a casting LOT.
- **Machining OUT / Assembly OUT** (`ConsumeMint`) consume and mint a new identity.
- **Trim IN/OUT, Machining IN, Assembly IN** (`Advance`) move an existing LOT forward and **mint nothing**.

Counting minted LOTs alone would report **zero production for both Trim shops**, which is obviously wrong.

**Decision: production = pieces credited at whatever step occurred in that Area**, taken from `Workorder.ProductionEvent` (one row per recorded step), rolled up by the event's `TerminalLocationId` → ancestor Area:

| Step role | Pieces credited |
|---|---|
| Mint (`OriginMint` / `ConsumeMint`) | the minted LOT's `PieceCount` |
| Advance | the LOT's `PieceCount` at the time of the event |

Scrap comes from `ProductionEvent.ScrapCount` on the same rows.

**This is throughput, not unique units.** A casting passes Die Cast, Trim, Machining and Assembly, and is counted once in each — that is what "production by building" means operationally, and the report must say so on its face so nobody sums the Area column and calls it plant output. The **Plant total** line is therefore *not* a sum of the area rows; it is the count at the finishing step (`AssemblyOut`) only.

> **CONFIRM 2 — is throughput-per-area the number MPP wants?** The alternative is pieces *minted* per area, which is smaller, non-double-counting, and sums to plant output — but reports Trim as zero. My read is that a plant manager asking for "production by building" wants to see each building's activity, i.e. throughput. Worth one sentence of confirmation.

**Die Cast note.** Die-cast entry is a per-cavity Open → accumulate → release lifecycle (migration `0045`, `Workorder.DieCastContribution`). Pieces are credited at **release**, when the LOT is minted — so a cavity left open across a shift boundary credits the shift it was *released* in, not the one it accumulated in. That is consistent with every other step and needs no special case, but it is worth knowing when a die-cast number looks lumpy.

---

## 4. Current inventory

Distinct from production: a **point-in-time snapshot**, not shift-anchored and not historical.

- Source: `Lots.Lot` where the status does not block production, rolled up by `CurrentLocationId` → ancestor Area.
- Quantity: the materialized `Lots.Lot.InventoryAvailable` (B5), not a recomputed `SUM(PieceCount)` — it is already maintained and is the number every other surface shows.
- Includes `WHSE` / `SHIPIN` / `SHIPOUT`, which carry real stock, so the section covers **Support areas too**, not just Production areas.

**The report SHALL label this "as of <render time>", not as of the selected production day.** There is no inventory history in the model — `Lots.Lot` holds only current state — so a report run for last Tuesday shows *today's* inventory alongside *last Tuesday's* production. Presenting that without a label would be actively misleading.

> Genuine historical inventory would need either a nightly snapshot table or reconstruction from `Lots.LotEventLog`. Out of scope; noted so the limitation is a known one rather than a surprise.

---

## 5. Deliverables

### 5.1 SQL — two read procs

Both follow FDS-11-011: no `OUTPUT` params, one result set, empty rowset = no data. Timestamps converted to Eastern at the read boundary per the project timestamp convention.

**`Oee.Production_GetByAreaForDay(@ProductionDate DATE)`**

One row per (Area × Shift), plus the Unassigned bucket:

| Column | Notes |
|---|---|
| `AreaLocationId`, `AreaCode`, `AreaName` | ancestor Area of the event's terminal |
| `ShiftId`, `ShiftName`, `ShiftStartEt`, `ShiftEndEt` | NULL / `'Unassigned'` for the gap bucket |
| `ShiftOrdinal` | sort key: 3rd = 1, 1st = 2, 2nd = 3, Unassigned = 9 |
| `PiecesProduced`, `PiecesScrapped` | per §3 |
| `EventCount` | operator-visible sanity check |

Uses `Location.ufn_AncestorLocationIds(TerminalLocationId)` joined to the Area tier (`LocationType.HierarchyLevel = 2`) for the roll-up — the existing inline TVF, so it inlines into the plan.

**`Lots.Inventory_GetByArea()`**

One row per Area holding stock:

| Column | Notes |
|---|---|
| `AreaLocationId`, `AreaCode`, `AreaName`, `AreaKind` | Production vs Support |
| `LotCount`, `PiecesAvailable` | `SUM(InventoryAvailable)` |
| `HeldLotCount`, `HeldPieces` | broken out — held stock is physically present but not available |

### 5.2 Tests

New `sql/tests/0026_PlantFloor_Downtime_Shift/` (shift-adjacent) or a fresh directory, covering:

- production day boundary — an event at 23:59 in 3rd shift and one at 00:01 lands on the **same** production day;
- a shift ending exactly at midnight does not roll forward;
- an event in a schedule gap appears in the Unassigned bucket, is **not** dropped;
- roll-up: an event at a Cell-tier terminal three levels down credits the right Area;
- an open (`ActualEnd IS NULL`) shift still reports;
- inventory: held LOTs are counted in `HeldPieces` and excluded from `PiecesAvailable`.

### 5.3 Report

New Reporting Module report **`Production & Inventory by Area`**, authored per `ignition-context-pack/10_reporting_module.md` and the global `ignition-reporting` skill.

- **Parameter:** `ProductionDate` (date; defaults to the current production day).
- **Layout:** header (production day + shift bounds) → **Production by Area × Shift** matrix with a day-total column and a scrap column → **Plant total at finishing step** → **Current inventory by Area**, labelled as-of render time.
- Registered in `BlueRidge.Reports.registry()` with `kind: "date"` param so the existing landing-page picker drives it — no new picker machinery.

**Gotchas that already cost hours on this report family** (from the overlay — do not rediscover):

1. A report resolves by its internal `setTitle`; the folder name MUST match it, or you get *"Enter a valid report in the source property"*.
2. `L.esc` every layout literal — a raw `&` throws `RMException` at **render** time, surfaced as a generic "invalid report". Validate the layout XML parses before deploying.
3. Never hand the Report Viewer an empty `params` dict.
4. `scan.ps1` **does** reload a changed report `data.bin` — no gateway restart.

---

## 6. Scope boundaries

**In:** the two procs, their tests, the report, the registry entry.

**Out:**
- Historical inventory (needs a snapshot table — see §4).
- OEE availability/performance; this is a production **count** report, not OEE.
- Any change to the existing `Inventory` or `Production Line Performance` reports, which stay as they are.
- The `ShiftId IS NULL` guard on `Oee.DowntimeEvent_Start` — related, but it belongs to punch list item 5.

---

## 7. Sequencing

1. `Oee.Production_GetByAreaForDay` + tests.
2. `Lots.Inventory_GetByArea` + tests.
3. Report authoring + render-verify.
4. Registry + landing-page wiring.

Steps 1–2 are independent and testable with no Ignition involvement. Step 3 needs a live gateway — **note that the local gateway's Perspective client trial is currently expired**, so render-verification is blocked until it is reset.

---

## 8. Open items

| | Item | Needs |
|---|---|---|
| **CONFIRM 1** | Production day labelled by the shift it **ends** in (§2) | Jacques / MPP |
| **CONFIRM 2** | Production = **throughput per area** (double-counts across areas by design) rather than pieces minted (§3) | Jacques / MPP |

Neither blocks starting: both are a one-line change at the top of `Production_GetByAreaForDay`, and the tests are written against whichever is chosen.

---

## Revision History

| Date | Rev | Change |
|---|---|---|
| 2026-08-18 | 1.0 | Initial draft from FAT day-1 item 4. |
