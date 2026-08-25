# LOT Search Extension + Serial / Container Trace Detail Panels — Design

**Date:** 2026-08-24
**Trigger:** MPP supplied six legacy Productivity-DB report exports (`reference/*.pdf`, 2026-08-24) — the first concrete evidence behind **UJ-19**. Reviewing them against FDS §12 showed the six unbuilt reporting requirements split into two unrelated shapes, and that three of them were already substantially backed in SQL.
**Status:** Draft for review. Schema-validated 2026-08-25 against migrations `0001`–`0066` and the seeds (§11) — three corrections applied. No open questions and no schema changes in this spec; three items handed to the companion spec (§8). One requirement element is knowingly unmet — the literal *ship date* of FDS-12-002/003, see §2.5.
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

**Decision: do not add `ContainerName`.** The container's real-world identity is the AIM `ShipperId` printed on its Honda label, which the resolver already matches (`Lots.ShippingLabel.AimShipperId NVARCHAR(50) NOT NULL`). A second identifier would create a labelling problem on the floor with no offsetting benefit. FDS-12-003's wording is amended to *"container ID or AIM shipper ID"*, and piece count is derived in the read from `Lots.ContainerTray.PartsClosedCount` and `Lots.ContainerSerial`.

### 2.5 There is no ship date anywhere in the schema

FDS-12-002 and FDS-12-003 both list **ship date** in their required output. No such column exists:

- `Lots.Container` — `OpenedAt`, `CompletedAt`. No `ShippedAt`.
- `Lots.ShippingLabel` — `CreatedAt`, `PrintedAt`, `VoidedAt`, `LastPrintAttemptAt`, `PrintFailedAt`, `BannerAcknowledgedAt`. None is a ship time.
- `Lots.Container_Ship` flips `ContainerStatusCodeId` to `3` (Shipped) and writes an `Audit.OperationLog` row with `LogEventTypeCode = 'ContainerShipped'`. **It persists no timestamp on the entity.** A repo-wide search for `ShippedAt` returns nothing.

So the only record of when a container shipped is an audit row — recoverable, but audit is a log rather than a queryable business dimension, and it falls under the 20-year retention and partitioning regime.

**Decision (2026-08-25): use `Lots.Container.CompletedAt`, surfaced as "Completed".** No new column, no dependency on the companion spec, and this spec ships complete.

The field is **labelled "Completed", not "Ship date"**, and that labelling is normative. `CompletedAt` is the moment the container was closed and its Honda label generated, which is a real and useful traceability fact — it is simply not the moment the truck left. Displaying it under its own name is accurate; displaying it under a "Ship date" heading would not be, and Honda traceability output is the wrong place to blur that.

**Consequence, recorded rather than hidden:** the literal *ship date* element of FDS-12-002 and FDS-12-003 is therefore **not met by this spec** and stays open. Container status still distinguishes shipped from complete (`ContainerStatusCodeId = 3`), so the panels show *whether* a container shipped; they do not show *when*. If MPP or Honda later require the actual ship timestamp, the fix is `Lots.Container.ShippedAt DATETIME2(3) NULL` set in `Container_Ship` and backfilled from the `ContainerShipped` audit rows.

**Note for the companion spec:** FDS-12-011 Shipping History is defined as *"shipped containers **by date range**"*. Ranging over `CompletedAt` means ranging over container-close time, not ship time — the two diverge whenever a completed container waits for a truck. That spec should decide explicitly whether that is acceptable for Honda ASN reconciliation or whether it needs `ShippedAt`.

---

## 3. Design — LOT Search (FDS-12-004)

Stays a standalone screen at `/shop-floor/lot-search`. It is a **filtered browse**: many rows, pagination, recency-sorted. That is a different interaction from identifier resolution, and it is why the legacy analogue is a printed date-range report.

### 3.1 `Lots.Lot_Search` rewrite

```
CREATE OR ALTER PROCEDURE Lots.Lot_Search
    @Query              NVARCHAR(100) = NULL,  -- LotName / VendorLotNumber / PartNumber, LIKE (retained)
    @ItemId             BIGINT        = NULL,  -- exact part
    @CreatedFromEt      DATE          = NULL,  -- Eastern calendar day, inclusive
    @CreatedToEt        DATE          = NULL,  -- Eastern calendar day, inclusive
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

**Date filtering is Eastern calendar days, converted to UTC inside the proc.** The operator picks whole days, exactly as the legacy report reads (*"from 8/18/2026 thru 8/18/2026"*), so the parameters are `DATE` and both bounds are inclusive. The proc converts to a half-open UTC instant range:

```sql
AND (@CreatedFromEt IS NULL OR l.CreatedAt >= CAST(CAST(@CreatedFromEt AS DATETIME2(3))
        AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)))
AND (@CreatedToEt   IS NULL OR l.CreatedAt <  CAST(CAST(DATEADD(DAY, 1, @CreatedToEt) AS DATETIME2(3))
        AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)))
```

Converting in SQL rather than in the view keeps the rule out of Python and makes it directly testable. It also avoids the bug pattern in `Audit.ConfigLog_List`, which displays `LoggedAt` in Eastern via `AT TIME ZONE` but compares `@StartDate` against the raw UTC column — so near midnight its filter and its displayed column disagree by the UTC offset. `Lot_Search` must not inherit that: the displayed `CreatedAt` is Eastern, so the filter is Eastern too.

### 3.2 Machine and Shift derivation

Both come from the legacy report, which has one Machine column and one Shift column per LOT. Neither is a column on `Lots.Lot`, so both are derived. **Both resolve from `Workorder.DieCastContribution` — one source, not two.**

- **Origin machine** = `Workorder.DieCastContribution.CellLocationId` (the press). Filter by `EXISTS` on `@MachineLocationId`; display the press from the LOT's earliest contribution (`MIN(EventAt)`) as `OriginMachineName`.
- **Shift** = `EXISTS` a `Workorder.DieCastContribution` row with `ShiftId = @ShiftId`. A LOT spanning shifts matches every shift it contributed in. Filter only — not a result column, because it is not single-valued.

**Do not derive the machine from `LotMovement`.** An earlier draft used the `ToLocationId` of the LOT's earliest movement — the `(none) -> Machine 01 (DC1-M01)` edge visible in LOT Detail history. Migration `0061_diecast_contribution_cell.sql` (2026-08-19) exists precisely to retire that class of derivation: before it, the press was re-derived live through `Lot.ToolId -> Tools.ToolAssignment active at EventAt -> CellLocationId`, so moving a die to another press months later silently rewrote which press a past contribution belonged to. `CellLocationId` is stamped at write time to make settled attribution immutable. Deriving the machine from movement history would reintroduce a weaker version of the same drift.

`CellLocationId` is nullable — a contribution whose die had no active assignment at `EventAt` has no honest answer and stays NULL rather than being guessed. Such rows are excluded from a machine-filtered search, consistent with §3.3.

Note also that `Lots.Lot` carries legacy `DieNumber` and `CavityNumber` **NVARCHAR** columns, superseded by `ToolId` / `ToolCavityId`. Filter and display the FK-backed columns; the legacy pair is not maintained.

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

One row satisfying FDS-12-002: serial, item, producing LOT, production date/time, operator, machine, container, AIM shipper ID, container status, and **Completed** (`Container.CompletedAt`, per §2.5). Sourced from `SerializedPart` joined through `ProducingLotId` to the LOT's production events, and through `ContainerSerial` to `Container` and `ShippingLabel`.

`Lots.SerializedPart_GetBySerial` is retained unchanged — it has existing callers and a narrower contract.

### 4.2 `Lots.Container_GetTraceDetail @ContainerId`

FDS-12-003: item, piece count, source LOTs, serials, container status, **Completed** (`Container.CompletedAt`, per §2.5), hold history. Piece count is derived from `ContainerTray.PartsClosedCount` and `ContainerSerial`. Hold history reads `Quality.HoldEvent` filtered on `ContainerId`.

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

**`ChargeToParty` code table — decided 2026-08-25.** The legacy splits the remaining 13 plant-wide codes into *Non-Specific Supplier* (the 6 HSP codes) and *Non-Specific MPP* (Prod. Control + Quality Control), a distinction migration `0048` collapsed into a single NULL bucket. Resolution: add a `ChargeToParty` code table FK'd from `Quality.DefectCode`, seeded `DieCast`, `TrimShop`, `MachineShop`, `DieMaintenance`, `MppNonSpecific`, `SupplierNonSpecific`, backfilled from the `DeptDesc` column still present in `reference/seed_data/defect_codes.csv`.

This keeps responsibility (who is charged) orthogonal to process (`OperationCategory`, which drives reject-screen filtering — a different job), and gives the supplier-chargeback row a real home. The alternatives — non-process rows on `Parts.OperationCategory`, or one merged Non-Specific row — were rejected: the first pollutes a taxonomy that is load-bearing for routes and the Production Line Performance report, and the second discards the only bucket with money attached.

**Decide the Shipping History date basis** per §2.5. This spec uses `Container.CompletedAt` and needs no new column. FDS-12-011 ranges over *shipped* containers by date, so the companion spec must decide whether close-time is an acceptable proxy for Honda ASN reconciliation or whether it needs `Lots.Container.ShippedAt` (set in `Container_Ship`, backfilled from `ContainerShipped` audit rows).

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

---

## 11. Schema validation record

Validated 2026-08-25 against the reset path (`sql/migrations/versioned/0001`–`0066` plus `sql/seeds/`), not the data-model document. `MPP_MES_DATA_MODEL.md` was found stale in three places (§10) and was not used as a source.

**Confirmed as specified:**

| Claim | Source |
|---|---|
| `Lots.Lot` — `LotName`, `ItemId`, `LotOriginTypeId`, `LotStatusId`, `PieceCount`, `VendorLotNumber`, `ToolId`, `ToolCavityId`, `CurrentLocationId`, `CreatedAt` | `0020` |
| `Lots.LotMovement` — `FromLocationId` NULL on first placement, `ToLocationId`, `MovedAt` | `0020` |
| `Tools.ToolCavity.CavityNumber INT`; `Tools.Tool.Code` | `0010` |
| `Quality.HoldEvent.ContainerId` with `CK_HoldEvent_LotXorContainer` — container holds are modelled | `0029` |
| `Lots.ShippingLabel.AimShipperId NVARCHAR(50) NOT NULL` | `0029` |
| `Lots.ContainerTray.PartsClosedCount`, `Lots.ContainerSerial.SerializedPartId` — piece-count sources | `0028` |
| `Lots.ContainerTray.FinishedGoodLotId` added by ALTER; used by `GlobalTrace_Resolve` expansion | `0034` |
| Descendant walk = recursive CTE on `Location.Location.ParentLocationId` | `R__Lots_Lot_GetWipQueueByLocation` |
| `Workorder.RejectEvent` has no location column; `RejectEvent_Record` takes `@TerminalLocationId` marked audit-only | `0020`, `R__Workorder_RejectEvent_Record` |
| `Quality.DefectCode.OperationCategoryId` replaced `AreaLocationId` | `0048` |

**Corrected during validation:**

1. **Origin machine** moved from `LotMovement` derivation to `DieCastContribution.CellLocationId` (§3.2) — migration `0061` added that column expressly to stop live re-derivation of the press.
2. **Ship date** has no column anywhere (§2.5). New finding. Resolved 2026-08-25 by using `Container.CompletedAt` labelled "Completed"; the literal ship-date element of FDS-12-002/003 stays open, and the date basis for FDS-12-011 is handed to the companion spec.
3. **Legacy `Lot.DieNumber` / `Lot.CavityNumber`** NVARCHAR columns exist and are superseded; the spec now states explicitly that the FK-backed pair is filtered and displayed (§3.2).
