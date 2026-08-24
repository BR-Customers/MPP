# LOT Search Extension + Serial / Container Trace Detail Panels — Design

**Date:** 2026-08-24
**Trigger:** MPP supplied six legacy Productivity-DB report exports (`reference/*.pdf`, 2026-08-24) — the first concrete evidence behind **UJ-19**. Reviewing them against FDS §12 showed the six unbuilt reporting requirements split into two unrelated shapes, and that three of them were already substantially backed in SQL.
**Status:** Draft for review. Design settled for this spec; two items deferred to the companion spec (§8).
**Scope:** FDS-12-002, FDS-12-003, FDS-12-004. **Not** FDS-12-006 / 12-010 / 12-011 — see §8.

---

## 1. What the legacy exports established

Six PDFs arrived. Five are PD reports; `Search Reject.pdf` is a PD *screen* (breadcrumb, filter row, Search button).

| Export | FDS requirement | Shape |
|---|---|---|
| `Lot Numbers by daterange.pdf` | FDS-12-004 LOT Search | Filtered list, date-range driven |
| `Reject Report.pdf` (15 pp) | FDS-12-006 | Part cross-tab |
| `Reject Summary Report.pdf` | FDS-12-006 | Departmental + customer rollup |
| `Search Reject.pdf` | FDS-12-006 | Transactional drill |
| `Production Detail Report.pdf` | FDS-12-008 / 12-005 | "Daily Casting Report Detail" |
| `Production Detail Report - trim shop.pdf` | FDS-12-008 | Trim variant, grouped by Process |

**Nothing covers Serialized Item Search, Container Search, Hold Status, or Shipping History.** That is structural, not an omission: the PD is a production and scrap transcription system that knows machines, shifts, parts, dies and defect codes. It has no concept of a container, a serial, or a Honda shipper ID, and quality holds live in Intelex.

The six FDS requirements therefore split two ways, and that split governs the delivery:

- **Search surfaces** (this spec) — FDS-12-002, 12-003, 12-004. Interactive Perspective screens, drill-through, CSV export.
- **Aggregate reports** (companion spec) — FDS-12-006, 12-010, 12-011. Reporting-Module PDFs on the existing `/shop-floor/reports` registry.

`Lot Numbers by daterange.pdf` is the only legacy artifact in this spec's scope. It supplies the filter set and the column set; the other five belong to the companion spec.

---

## 2. Findings that shaped the design

### 2.1 `Lots.GlobalTrace_Resolve` already resolves all five identifier types

`notes/2026-07-09_fds-gap-audit.md` records that the trace resolver *"only handles LOTs (serial/container/shipper inputs absent)"*. **That is stale by one day.** `R__Lots_GlobalTrace_Resolve.sql` is dated 2026-07-10 and matches, in order:

1. `Lots.Lot.LotName` exact → `MatchType = 'Lot'`
2. `Lots.SerializedPart.SerialNumber` → `'Serial'` (LotId = `ProducingLotId`)
3. `Lots.Container.Id` on all-numeric input → `'Container'`, expanded to source LOTs
4. `Lots.ShippingLabel.AimShipperId` → `'Shipper'`, same expansion
5. `LotName` LIKE prefix, excluding the exact hit

Capped at 50 rows; multiple rows are the FDS-12-013 disambiguation list. **No resolver work is required.**

### 2.2 But the resolver collapses everything to LOT rows

It returns `MatchType, MatchedEntityId, LotId, LotName, ItemPartNumber, Detail`. Correct for tracing; insufficient for FDS-12-002/003, which want entity-specific payloads. `Lots.SerializedPart_GetBySerial` returns only `Id, SerialNumber, ItemId, ProducingLotId, EtchedAt` — roughly a third of FDS-12-002. No container read exists at all.

### 2.3 `Lots.Lot_Search` is a stub, not a partial implementation

Current signature is `@Query, @LotStatusId, @LotOriginTypeId, @LimitRows` — free text plus two enums, `TOP (@LimitRows)` defaulting to 100. FDS-12-004 requires part number, date range, die, cavity, status, location and origin; the legacy report adds machine and shift. The proc is rewritten, not extended. Its SELECT list and `COUNT(*) OVER() AS TotalCount` pager are sound and are retained.

### 2.4 `Lots.Container` has no name

FDS-12-003 says *"given a container name or AIM shipper ID"*. `Lots.Container` is `Id BIGINT IDENTITY` plus `ItemId`, `ContainerConfigId`, `CurrentLocationId`, `ContainerStatusCodeId`, `OpenedAt`, `CompletedAt`, `CreatedByUserId`, `RowVersion`. There is no name column and no piece-count column.

**Decision: do not add `ContainerName`.** The container's real-world identity is the AIM `ShipperId` printed on its Honda label, which the resolver already matches. A second identifier would create a labelling problem on the floor with no offsetting benefit. FDS-12-003's wording is amended to *"container ID or AIM shipper ID"*, and piece count is derived in the read.

---

## 3. Design — LOT Search (FDS-12-004)

Stays a standalone screen at `/shop-floor/lot-search`. It is a **filtered browse**: many rows, pagination, recency-sorted. That is a different interaction from identifier resolution, and it is why the legacy analogue is a printed date-range report.

### 3.1 `Lots.Lot_Search` rewrite

```
CREATE OR ALTER PROCEDURE Lots.Lot_Search
    @Query              NVARCHAR(100) = NULL,  -- LotName / VendorLotNumber / PartNumber, LIKE (retained)
    @ItemId             BIGINT        = NULL,  -- exact part
    @CreatedFromUtc     DATETIME2(3)  = NULL,
    @CreatedToUtc       DATETIME2(3)  = NULL,
    @ToolId             BIGINT        = NULL,  -- Die
    @ToolCavityId       BIGINT        = NULL,  -- Cavity
    @LocationId         BIGINT        = NULL,  -- current location
    @IncludeDescendants BIT           = 1,     -- hierarchy walk under @LocationId
    @MachineLocationId  BIGINT        = NULL,  -- origin machine (see 3.2)
    @ShiftId            BIGINT        = NULL,  -- see 3.2
    @LotStatusId        BIGINT        = NULL,
    @LotOriginTypeId    BIGINT        = NULL,
    @LimitRows          INT           = 100
```

Every filter is null-tolerant (`@X IS NULL OR ...`), matching the existing body's idiom. One result set, `COUNT(*) OVER() AS TotalCount`, `TOP (@LimitRows)`.

Date parameters are **UTC** and named so. `CreatedAt` is already converted to Eastern at the boundary in the SELECT via `AT TIME ZONE`; the view converts operator-entered dates to UTC before the call so the filter and the displayed column agree.

### 3.2 Machine and Shift derivation

Both come from the legacy report, which has one Machine column and one Shift column per LOT. Neither is a column on `Lots.Lot`, so both are derived, and both are defined narrowly to stay deterministic:

- **Origin machine** = `ToLocationId` of the LOT's earliest `Lots.LotMovement` row — the `(none) -> Machine 01 (DC1-M01)` edge visible in LOT Detail history. One value per LOT. Surfaced as a result column `OriginMachineName`; filtered by `@MachineLocationId`.
- **Shift** = `EXISTS` a `Workorder.DieCastContribution` row for the LOT with `ShiftId = @ShiftId`. A LOT spanning shifts matches every shift it contributed in. Filter only — not a result column, because it is not single-valued.

### 3.3 Origin-conditional filters

`Lot.ToolId` and `Lot.ToolCavityId` are NULL on merged LOTs by design (OI-05 — blended origin cannot denormalize) and on non-cast origins. Origin machine and shift are likewise cast-oriented. Selecting Die, Cavity, Machine or Shift therefore implicitly narrows to die-cast-origin LOTs.

**This is labelled in the UI, not special-cased in SQL.** The four controls sit in a visually grouped block captioned *"Die Cast origin"*.

### 3.4 Result columns

Retained: `Origin | Lot Name | Vendor LOT | Part Number | Pcs | Location | Status | Created`.
Added: **Die** (`Tools.Tool.Code`), **Cavity** (`Tools.ToolCavity.CavityNumber`), **Machine** (`OriginMachineName`).

That closes the gap with the legacy `Machine | Shift | Part | Die | LotNo | Quantity | Date` layout. Shift is deliberately absent per §3.2.

### 3.5 Row click to LOT Detail

`ia.display.table` fires **`onSelectionChange`**, not `onRowClick` — the latter is silent. Read the row through `props.selection.data`; navigate to `/shop-floor/lot-detail/:lotId` with the row's `Id`.

The guard must be `if sel is None: return`, **not** `if not sel:` — an empty-ish selection object for row 0 is falsy and would make the first row unclickable.

### 3.6 CSV export

FRS 3.5.10 requires PDF or Excel export from reporting screens. LOT Search exports the **current filtered result set** as CSV. This is the only export obligation in this spec; the aggregate reports satisfy theirs through the Reporting Module.

### 3.7 Pickled data cleanup

`BlueRidge/Views/ShopFloor/LotSearch/view.json` carries 33 live Dev rows embedded in `custom.results` as the property default — a Designer save that pickled runtime data. Reset to `[]`. Verify with `git diff --stat` before committing that the diff is proportionate to the change.

---

## 4. Design — Serial and Container as Global Trace detail panels (FDS-12-002 / 12-003)

These are **identifier lookups**: one input, one entity, drill to detail. That is what `/shop-floor/trace` already is. Building them as standalone screens would mean three search boxes calling one resolver and diverging over time.

Implementation: two new read procs, dispatched off the `MatchType` the resolver already returns, rendered as panels on the existing Global Trace surface. A scanned serial then behaves identically whether the operator arrived from the Track tile or from a menu entry named "Serialized Item Search".

### 4.1 `Lots.SerializedPart_GetTraceDetail @SerialNumber`

One row satisfying FDS-12-002: serial, item, producing LOT, production date/time, operator, machine, container, AIM shipper ID, ship date. Sourced from `SerializedPart` joined through `ProducingLotId` to the LOT's production events, and through `ContainerSerial` to `Container` and `ShippingLabel`.

`Lots.SerializedPart_GetBySerial` is retained unchanged — it has existing callers and a narrower contract.

### 4.2 `Lots.Container_GetTraceDetail @ContainerId`

FDS-12-003: item, piece count, source LOTs, serials, container status, ship date, hold history. Piece count is derived from `ContainerTray` and `ContainerSerial`. Hold history reads `Quality.HoldEvent` for the container.

**One result set only** (FDS-11-011). The serial list and hold history are separate sibling reads called by the panel, not a second result set.

### 4.3 Empty-result convention

Empty result set means not found. No invented 404, no OUTPUT parameters (FDS-11-011).

### 4.4 Bound custom properties

Every `view.custom.*` property the panels read gets a fully-shaped default, and each binding source returns a fully-shaped empty object on the not-found path rather than `None` — the default only guards first paint, and a `None` return overwrites it and produces a Component Error on nested reads.

---

## 5. SQL work

| Object | Action |
|---|---|
| `Lots.Lot_Search` | Rewrite — 13 parameters (§3.1) |
| `Lots.SerializedPart_GetTraceDetail` | New read |
| `Lots.Container_GetTraceDetail` | New read |
| `Lots.SerializedPart_GetBySerial` | Unchanged |
| `Lots.GlobalTrace_Resolve` | Unchanged |

No migration is required by this spec. All three procs are repeatable (`R__`) reads.

---

## 6. Perspective work

| Resource | Action |
|---|---|
| `BlueRidge/Views/ShopFloor/LotSearch` | Add 8 filter controls, 3 result columns, `onSelectionChange` navigation, CSV export, reset pickled `custom.results` |
| `BlueRidge/Views/ShopFloor/GlobalTrace` | Add serial and container detail panels, dispatched on `MatchType` |
| Named queries | `lots/Lot_Search` (params extended), `lots/SerializedPart_GetTraceDetail`, `lots/Container_GetTraceDetail` — all in **Core** |

Existing views are edited in **Designer**, not by file edit. New named queries and Python are file-edited, then `.\scan.ps1`.

---

## 7. Testing

- **SQL:** per-proc test files under `sql/tests/`, INSERT-EXEC into a temp table matching the SELECT shape. `Lot_Search` needs one case per filter plus a combined case, an origin-conditional case (merged LOT with NULL Tool returns under no Die filter and is excluded under any Die filter), and a `TotalCount` correctness case across a pager boundary.
- **Perspective:** row-0 click must navigate (the `if not sel` regression), and each detail panel must render an empty state without a Component Error. The in-app browser can render-verify and fire buttons but cannot commit input bindings — filter submission is verified via SQL against the proc, not through the browser.

---

## 8. Decisions carried to the companion spec

Settled in the 2026-08-24 session, belonging to the aggregate-reports spec:

**Persist scrap location on `RejectEvent`.** `Workorder.RejectEvent` has no location column, while sibling tables `ProductionEvent` and `ConsumptionEvent` both carry `TerminalLocationId`. `Workorder.RejectEvent_Record` **already accepts `@TerminalLocationId`**, commented `-- audit-only; no column on RejectEvent`: the caller passes it and it is written only to the audit log. Add `TerminalLocationId BIGINT NULL FK -> Location.Location(Id)` plus one line in the proc's INSERT, and backfill historical rows once from the last `LotMovement` before `RecordedAt`.

Deriving at read time was rejected. `Lot.CurrentLocationId` is mutable and drifts — a casting scrapped at Die Cast then moved to Trim and Machining would report as Machining, the exact failure mode FDS-02-002a exists to prevent. Last-movement-before-`RecordedAt` is point-in-time correct but is a correlated lookup per reject row against a partitioned table on every run.

**Departmental scrap derives from `DefectCodeId`.** Migration `0048` (2026-08-04) dropped `DefectCode.AreaLocationId` and replaced it with `OperationCategoryId` (DieCast / Trim / MachiningAssembly, NULL = plant-wide). The legacy Departmental Scrap block maps onto it directly: Die Cast 59 codes, Machine Shop 75, Trim Shop 6. `RejectEvent.ChargeToArea` is derived rather than entered — in every row of `Search Reject.pdf` the ChargeTo equals the defect code's home department, with no override observed.

**Open question for that spec:** the legacy splits the remaining 13 plant-wide codes into *Non-Specific Supplier* (the 6 HSP codes) and *Non-Specific MPP* (Prod. Control + Quality Control), a distinction migration `0048` collapsed into a single NULL bucket. Three options were tabled — a `ChargeToParty` code table FK'd from `DefectCode` (recommended), non-process rows on `Parts.OperationCategory`, or reporting one merged Non-Specific row. **Not yet decided.**

---

## 9. Out of scope

- **Production schedule attainment.** `Required Qty`, `Planned Qty` and `Good Qty Percent` on `Production Detail Report.pdf` are schedule-driven and the production schedule is a Phase 2 item. Those columns are deferred. They belong to FDS-12-008 / 12-005, so no report in this spec or the companion is blocked. The observation stands as evidence for **OI-34** but is not actioned.
- **OEE availability.** Where OEE is involved, a shift is treated as having run if a production event occurred on the line, and the whole shift counts as planned uptime. Consistent with FDS-09-009. FDS §9 additionally expands the window backwards to the earliest event on an early start; the two disagree by that overhang. Neither affects this spec — reject and search denominators are produced counts, not planned — so it is recorded and left for the OEE work.
- FDS-12-006 Rejects, FDS-12-010 Hold Status, FDS-12-011 Shipping History — companion spec.

---

## 10. Documentation corrections owed

1. **`MPP_MES_FDS.md:411`** asserts `Quality.RejectEvent.LocationId` is location-anchored. Wrong schema (`Workorder`) and the column has never existed. Correct when §8's column lands.
2. **`MPP_MES_DATA_MODEL.md:1148`** still documents `DefectCode.AreaLocationId`, dropped by migration `0048`. Replace with `OperationCategoryId`.
3. **`MPP_MES_DATA_MODEL.md:1102`** documents `RejectEvent.ChargeToArea` as *"Area responsible for the reject"*. Restate as derived-from-defect-code, and add `TerminalLocationId` when it lands.
4. **`notes/2026-07-09_fds-gap-audit.md`** claims the trace resolver handles only LOTs. Superseded by the 2026-07-10 proc revision — annotate rather than delete.
5. **FDS-12-003** wording: *"container name"* to *"container ID"* per §2.4.
6. **UJ-19 / OI-30.** These six exports are the first real evidence. UJ-19's recommended direction still cites *"UJ-11's recommended phased rollout"*, but UJ-11 closed 2026-04-27 as **Option A, all-at-once hard cutover**. The recommendation is stale and the transition-shape half of UJ-19 is answered; only enumeration remains open.
