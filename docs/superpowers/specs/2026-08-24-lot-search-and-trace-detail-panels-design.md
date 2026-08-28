# LOT Search Advanced + Serial / Container Trace Detail Panels — Design

**Date:** 2026-08-24 (rev. 2026-08-25)
**Trigger:** MPP supplied six legacy Productivity-DB report exports (`reference/*.pdf`, 2026-08-24) — the first concrete evidence behind **UJ-19**. Reviewing them against FDS §12 showed the six unbuilt reporting requirements split into two unrelated shapes, and that three of them were already substantially backed in SQL.
**Status:** Draft for review. Schema-validated against migrations `0001`–`0066` and the seeds (§11). Reviewed against the full `ignition-context-pack/` (§9) — three defects in the prior revision corrected, one of which was a latent runtime bug. No open questions and no schema migration in this spec; three items handed to the companion spec (§8). One requirement element is knowingly unmet — the literal *ship date* of FDS-12-002/003, see §2.5.
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

### 2.3 `Lots.Lot_Search` is load-bearing and must not be rewritten

Current signature is `@Query, @LotStatusId, @LotOriginTypeId, @LimitRows` — free text plus two enums, `TOP (@LimitRows)` defaulting to 100.

A blast-radius trace found **three consumers**, two of which the first revision of this spec did not know about:

| Consumer | Coupling | Breaks on |
|---|---|---|
| `sql/tests/0021_PlantFloor_Lot_Lifecycle/077_Lot_Search.sql` | Two hardcoded 15-column `INSERT-EXEC` temp tables | **Result-set width change** |
| `BlueRidge.Lots.Lot.search()` ([code.py:352](../../../ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py)) | Builds a 4-key param dict, hands it to `Common.Db.execList` with no defaulting | **Parameter-list change** |
| `HoldManagement` view ([view.json:406](../../../ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/HoldManagement/view.json)) | Calls `Lot.search(bulkQuery, 1)` **positionally** to fill the bulk-hold LOT picker | Any signature change to `search()` |

Ignition requires a value for every declared named-query parameter, so widening the NQ breaks every existing call. And the `HoldManagement` call is positional, so even an append-only Python signature change is one careless reorder away from silently binding the wrong argument.

**Decision (2026-08-25): build a separate proc.** `Lots.Lot_Search` and its named query are frozen. The new surface is `Lots.Lot_SearchAdvanced` with its own named query and its own entity-script function. Blast radius becomes zero — no existing test, script, or view changes.

The cost is two search procs with overlapping SELECT lists. That is accepted: the alternative trades a duplicated `SELECT` for a live risk to bulk hold placement, and the two have genuinely different jobs — `Lot_Search` is a type-ahead picker, `Lot_SearchAdvanced` is a filtered browse.

### 2.4 `Lots.Container` has no name

FDS-12-003 says *"given a container name or AIM shipper ID"*. `Lots.Container` is `Id BIGINT IDENTITY` plus `ItemId`, `ContainerConfigId`, `CurrentLocationId`, `ContainerStatusCodeId`, `OpenedAt`, `CompletedAt`, `CreatedByUserId`, `RowVersion`. There is no name column and no piece-count column.

**Decision: do not add `ContainerName`.** The container's real-world identity is the AIM `ShipperId` printed on its Honda label (`Lots.ShippingLabel.AimShipperId NVARCHAR(50) NOT NULL`), which the resolver already matches. A second identifier would create a labelling problem on the floor with no offsetting benefit. FDS-12-003's wording is amended to *"container ID or AIM shipper ID"*, and piece count is derived from `Lots.ContainerTray.PartsClosedCount` and `Lots.ContainerSerial`.

### 2.5 There is no ship date anywhere in the schema

FDS-12-002 and FDS-12-003 both list **ship date** in their required output. No such column exists:

- `Lots.Container` — `OpenedAt`, `CompletedAt`. No `ShippedAt`.
- `Lots.ShippingLabel` — `CreatedAt`, `PrintedAt`, `VoidedAt`, `LastPrintAttemptAt`, `PrintFailedAt`, `BannerAcknowledgedAt`. None is a ship time.
- `Lots.Container_Ship` flips `ContainerStatusCodeId` to `3` (Shipped) and writes an `Audit.OperationLog` row with `LogEventTypeCode = 'ContainerShipped'`. **It persists no timestamp on the entity.** A repo-wide search for `ShippedAt` returns nothing.

**Decision (2026-08-25): use `Lots.Container.CompletedAt`, surfaced as "Completed".** No new column, no dependency on the companion spec.

The field is **labelled "Completed", not "Ship date"**, and that labelling is normative. `CompletedAt` is the moment the container was closed and its Honda label generated — a real traceability fact, just not the moment the truck left. Displaying it under its own name is accurate; displaying it under a "Ship date" heading would not be.

**Consequence, recorded rather than hidden:** the literal *ship date* element of FDS-12-002 and FDS-12-003 is **not met by this spec** and stays open. Container status still distinguishes shipped from complete (`ContainerStatusCodeId = 3`), so the panels show *whether* a container shipped; they do not show *when*. Closing it needs `Lots.Container.ShippedAt DATETIME2(3) NULL` set in `Container_Ship` and backfilled from the `ContainerShipped` audit rows.

**Note for the companion spec:** FDS-12-011 Shipping History is defined as *"shipped containers **by date range**"*. Ranging over `CompletedAt` means ranging over container-close time — the two diverge whenever a completed container waits for a truck. That spec must decide whether that is acceptable for Honda ASN reconciliation.

---

## 3. Design — LOT Search (FDS-12-004)

The existing screen at `/shop-floor/lot-search` is extended in place; the query behind it becomes `Lots.Lot_SearchAdvanced`. It is a **filtered browse**: many rows, pagination, recency-sorted — a different interaction from identifier resolution, which is why the legacy analogue is a printed date-range report.

### 3.1 Why twelve parameters, and why that is not the risk

The count is **12**, not 14. Ten are mandated filters; two are plumbing:

| # | Parameter | Source of the requirement |
|---|---|---|
| 1 | `@Query` | Existing behaviour — free-text scan target (LotName / VendorLotNumber / PartNumber) |
| 2 | `@ItemId` | FDS-12-004 "part number" |
| 3 | `@CreatedFromEt` | FDS-12-004 "date range"; the legacy report is date-range driven |
| 4 | `@CreatedToEt` | FDS-12-004 "date range" |
| 5 | `@ToolId` | FDS-12-004 "die number"; legacy `Die` column |
| 6 | `@ToolCavityId` | FDS-12-004 "cavity number" |
| 7 | `@LocationId` | FDS-12-004 "location" |
| 8 | `@MachineLocationId` | Legacy `Machine` column |
| 9 | `@ShiftId` | Legacy `Shift` column |
| 10 | `@LotStatusId` | FDS-12-004 "status" |
| 11 | `@LotOriginTypeId` | FDS-12-004 "origin type" |
| 12 | `@LimitRows` | Plumbing — pager page size |

**One parameter was cut during this review.** The prior revision carried `@IncludeDescendants BIT`. It is removed: the location filter now **always** walks descendants. Selecting a Cell returns that Cell (a Cell has no children), and selecting an Area returns everything beneath it — which is what someone filtering a search screen by Area means. The exact-match mode had no use case that the hierarchy walk does not already serve, and it was the one parameter whose Ignition `sqlType` was easy to get wrong (`6` = Boolean, not `2` = Integer).

**On the risk itself — the parameter count is not where the bugs come from.** Twelve *named* SQL parameters are individually safe: SQL Server binds by name, every one defaults to `NULL`, and an unsupplied filter is simply inert. Three specific things are dangerous, and each gets a named mitigation:

**(a) Positional argument drift in Python.** This is the real hazard, and it already exists in the codebase — `HoldManagement` calls `Lot.search(bulkQuery, 1)` positionally. A twelve-positional-argument function is one careless insertion away from silently binding a Location id to a Tool id.

> **Mitigation — the new entity function takes ONE argument: a filters dict.** There is no twelve-argument signature to mis-order.
> ```python
> def searchAdvanced(filters=None):
>     """filters: dict shaped like _EMPTY_FILTERS. Unknown keys are ignored;
>        absent keys fall back to the _EMPTY_FILTERS default (None / no filter)."""
> ```

**(b) Silent key drift between the view, the wrapper, and the NQ.** Twelve names written in four places (proc signature, `query.sql`, `resource.json` parameters, Python dict) invites a typo that never raises.

> **Mitigation — one canonical shape, declared once.** `_EMPTY_FILTERS` in the entity module is the single source of truth; the view seeds `view.custom.filters` from it and the wrapper builds the NQ dict by iterating it. A key that exists in only one of the four places is caught by the signature-parity test in §7.

**(c) A typo'd filter silently returning too many rows.** A search that quietly ignores a filter looks plausible — the operator sees results and has no reason to suspect one predicate did nothing.

> **Mitigation — explicit named parameters, not a JSON blob.** A `@FiltersJson NVARCHAR(MAX)` parsed with `OPENJSON` would collapse this to one NQ parameter, and the project does use JSON params for `SaveAll`. It is **rejected here**: a misspelled JSON key is silently ignored, whereas a misspelled NQ parameter name raises immediately. For a filter surface, loud failure is worth twelve declarations.

### 3.2 `Lots.Lot_SearchAdvanced`

```
CREATE OR ALTER PROCEDURE Lots.Lot_SearchAdvanced
    @Query             NVARCHAR(100) = NULL,   -- LotName / VendorLotNumber / PartNumber, LIKE
    @ItemId            BIGINT        = NULL,
    @CreatedFromEt     DATE          = NULL,   -- Eastern calendar day, inclusive
    @CreatedToEt       DATE          = NULL,   -- Eastern calendar day, inclusive
    @ToolId            BIGINT        = NULL,
    @ToolCavityId      BIGINT        = NULL,
    @LocationId        BIGINT        = NULL,   -- always includes descendants
    @MachineLocationId BIGINT        = NULL,
    @ShiftId           BIGINT        = NULL,
    @LotStatusId       BIGINT        = NULL,
    @LotOriginTypeId   BIGINT        = NULL,
    @LimitRows         INT           = 100
```

Every filter is null-tolerant (`@X IS NULL OR ...`). One result set (FDS-11-011), `COUNT(*) OVER() AS TotalCount` for the pager, `TOP (@LimitRows)`, ordered `CreatedAt DESC, Id DESC`.

**Date filtering is Eastern calendar days, converted to UTC inside the proc.** The operator picks whole days, exactly as the legacy report reads (*"from 8/18/2026 thru 8/18/2026"*), so both bounds are inclusive `DATE`:

```sql
AND (@CreatedFromEt IS NULL OR l.CreatedAt >= CAST(CAST(@CreatedFromEt AS DATETIME2(3))
        AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)))
AND (@CreatedToEt   IS NULL OR l.CreatedAt <  CAST(CAST(DATEADD(DAY, 1, @CreatedToEt) AS DATETIME2(3))
        AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)))
```

Converting in SQL keeps the rule out of Python and makes it testable. It also avoids the pattern in `Audit.ConfigLog_List`, which displays `LoggedAt` in Eastern via `AT TIME ZONE` but compares `@StartDate` against the raw UTC column — near midnight its filter and its displayed column disagree by the offset. This proc must not inherit that: the displayed `CreatedAt` is Eastern, so the filter is Eastern too.

The location filter uses the recursive-CTE descendant walk already used by `Lots.Lot_GetWipQueueByLocation`, with `OPTION (MAXRECURSION 100)`.

### 3.3 Machine and Shift derivation

Both come from the legacy report, which has one Machine column and one Shift column per LOT. Neither is a column on `Lots.Lot`. **Both resolve from `Workorder.DieCastContribution` — one source, not two.**

- **Origin machine** = `DieCastContribution.CellLocationId` (the press). Filter by `EXISTS`; display the press from the LOT's earliest contribution (`MIN(EventAt)`) as `OriginMachineName`.
- **Shift** = `EXISTS` a `DieCastContribution` row with `ShiftId = @ShiftId`. A LOT spanning shifts matches every shift it contributed in. Filter only — not a result column, because it is not single-valued.

**Do not derive the machine from `LotMovement`.** An earlier draft used the `ToLocationId` of the LOT's earliest movement. Migration `0061_diecast_contribution_cell.sql` (2026-08-19) exists precisely to retire that class of derivation: before it, the press was re-derived live through `Lot.ToolId → Tools.ToolAssignment active at EventAt → CellLocationId`, so moving a die to another press months later silently rewrote which press a past contribution belonged to. `CellLocationId` is stamped at write time to make settled attribution immutable. A movement-based derivation reintroduces the same drift.

`CellLocationId` is nullable — a contribution whose die had no active assignment at `EventAt` has no honest answer and stays NULL rather than being guessed. Such rows are excluded from a machine-filtered search, consistent with §3.4.

### 3.4 Origin-conditional filters

`Lot.ToolId` and `Lot.ToolCavityId` are NULL on merged LOTs by design (OI-05 — blended origin cannot denormalize) and on non-cast origins. Origin machine and shift are likewise cast-oriented. Selecting Die, Cavity, Machine or Shift therefore implicitly narrows to die-cast-origin LOTs.

**This is labelled in the UI, not special-cased in SQL** — the four controls sit in a container captioned *"Die Cast origin"*.

`Lots.Lot` also carries legacy `DieNumber` and `CavityNumber` **NVARCHAR** columns, superseded by `ToolId` / `ToolCavityId`. Filter and display the FK-backed pair; the legacy pair is not maintained.

### 3.5 Result columns

Retained from `Lot_Search`: `Origin | Lot Name | Vendor LOT | Part Number | Pcs | Location | Status | Created`.
Added: **Die** (`Tools.Tool.Code`), **Cavity** (`Tools.ToolCavity.CavityNumber`), **Machine** (`OriginMachineName`).

That closes the gap with the legacy `Machine | Shift | Part | Die | LotNo | Quantity | Date` layout. Shift is deliberately absent per §3.3.

### 3.6 Row click to LOT Detail — and the hidden `Id` column it requires

`ia.display.table` fires **`onSelectionChange`**; `onRowClick` does not exist on it and fails silently. Read the row from `props.selection.data`, which is a **list** of row dicts even in single-select mode — index `[0]`, then the field.

**`selection.data` is built from the table's `columns`, not from the raw row.** A field present in `props.data` with no column entry is **absent** from every selection dict. The current table displays `Origin | LotName | VendorLot | PartNumber | Pcs | Location | Status | Created` — **`Id` has no column**, so `selection.data[0]["Id"]` raises `KeyError`.

**Therefore: add an `Id` column with `"visible": false`** (full column schema, like any other). That is the sanctioned way to carry a primary key to a row-action handler — the column makes the field flow into `selection.data` while keeping it out of the rendered table. Without it, row-click navigation cannot work at all.

The guard is `if sel is None`, not `if not sel` — an empty-ish selection object for row 0 is falsy and would make the first row unclickable. Navigation target is `/shop-floor/lot-detail/:lotId`.

### 3.7 CSV export

FRS 3.5.10 requires PDF or Excel export from reporting screens. LOT Search exports the **current filtered result set** as CSV. This is the only export obligation in this spec; the aggregate reports satisfy theirs through the Reporting Module.

The export button lives outside the results panel, so it reaches the table by walking the tree (`self.parent.getChild("ResultsPanel").getChild("ResultsTable")`) — `getSibling` resolves only true siblings and would return `None` here. In practice the handler reads `view.custom.results` and never touches the table at all, which is cheaper and avoids the addressing problem entirely.

### 3.8 Pickled data cleanup

`LotSearch/view.json` carries 33 live Dev rows embedded in `custom.results` as the property default — a Designer save that pickled runtime data. Reset to `[]`, and check `git diff --stat` before committing: a large diff for a small change means Designer re-pickled.

---

## 4. Design — Serial and Container as Global Trace detail panels (FDS-12-002 / 12-003)

These are **identifier lookups**: one input, one entity, drill to detail. That is what `/shop-floor/trace` already is. Building them as standalone screens would mean three search boxes calling one resolver and diverging over time.

Implementation: new read procs dispatched off the `MatchType` the resolver already returns, rendered as panels on the existing Global Trace surface. A scanned serial then behaves identically whether the operator arrived from the Track tile or a menu entry named "Serialized Item Search".

For a `'Shipper'` match, `MatchedEntityId` is the shipping-label row; the container panel is still the destination, reached via that label's `ContainerId`.

### 4.1 `Lots.SerializedPart_GetTraceDetail @SerialNumber`

One row: `SerialNumber, ItemId, ItemPartNumber, ProducingLotId, ProducingLotName, EtchedAt, ProducedAt, OperatorName, MachineName, ContainerId, ContainerStatusCode, AimShipperId, CompletedAt`.

Sourced from `SerializedPart` joined through `ProducingLotId` to the LOT's most recent `ProductionEvent` (operator via `Location.AppUser.DisplayName`, machine via `TerminalLocationId`), and through `ContainerSerial` to `Container` and `ShippingLabel`. A container may carry several non-void labels over its life (reprints, voids) — take the most recent non-void one.

`Lots.SerializedPart_GetBySerial` is retained unchanged; it has existing callers and a narrower contract.

### 4.2 `Lots.Container_GetTraceDetail @ContainerId` + two siblings

`Container_GetTraceDetail` returns one row: `ContainerId, ItemId, ItemPartNumber, ContainerStatusCode, PieceCount, SerialCount, SourceLotCount, OpenedAt, CompletedAt, AimShipperId, OpenHoldCount, TotalHoldCount`.

Piece count sums `ContainerTray.PartsClosedCount`. Source LOTs are counted the way `GlobalTrace_Resolve` expands a container: `ContainerTray.FinishedGoodLotId` (migration `0034`) UNIONed with `ContainerSerial → SerializedPart.ProducingLotId`.

**One proc returns one result set** (FDS-11-011), so the two collections are siblings:

- `Lots.Container_ListSerials @ContainerId` — `SerializedPartId, SerialNumber, TrayPosition, ProducingLotId, ProducingLotName`.
- `Quality.Hold_ListByContainer @ContainerId` — full hold **history**, open and released. The existing `Quality.Hold_GetOpenByContainer` filters `ReleasedAt IS NULL` and cannot serve FDS-12-003's "hold history"; `Quality.HoldEvent` carries `ContainerId` under a `CK_HoldEvent_LotXorContainer` check, so container holds are already modelled.

### 4.3 Empty-result and shaped-default conventions

Empty result set means not found — no invented 404, no OUTPUT parameters.

Every `view.custom.*` property the panels read gets a fully-shaped default in the view's `custom` block: `[]` for anything iterated or measured with `len()`, a dict carrying every accessed key for anything traversed by nested path.

**The default is only the first-paint guard.** Once a binding evaluates, its result *replaces* the default — so the binding's **source** must itself always return the fully-shaped object, including on the not-found path. Return an `_EMPTY_*` shape, never `None` or `{}`. Where a script caller needs to branch on absence, pair a `None`-returning `getX` with a binding-only `getXOrEmpty`.

### 4.4 Panel visibility

Both panels are children of a flex container, so conditional visibility binds **`position.display`** (`display: none`, removed from layout) — never `meta.visible`, which leaves the hidden panel occupying flex space.

---

## 5. SQL work

| Object | Action |
|---|---|
| `Lots.Lot_SearchAdvanced` | **New** — 12 parameters (§3.1–3.2) |
| `Lots.SerializedPart_GetTraceDetail` | **New** |
| `Lots.Container_GetTraceDetail` | **New** |
| `Lots.Container_ListSerials` | **New** |
| `Quality.Hold_ListByContainer` | **New** |
| `Lots.Lot_Search` | **Frozen — not touched** (§2.3) |
| `Lots.SerializedPart_GetBySerial` | Unchanged |
| `Lots.GlobalTrace_Resolve` | Unchanged |

No migration. All five new procs are repeatable (`R__`) reads.

---

## 6. Ignition work

### 6.1 Named queries — all in `Core`

| Path | Parameters |
|---|---|
| `lots/Lot_SearchAdvanced` | 12, per §3.1 |
| `lots/SerializedPart_GetTraceDetail` | `serialNumber` |
| `lots/Container_GetTraceDetail` | `containerId` |
| `lots/Container_ListSerials` | `containerId` |
| `quality/Hold_ListByContainer` | `containerId` |

`resource.json` must be **`version: 2`** — Designer 8.3.5 NPEs opening a `version: 1` NQ resource. `attributes.type` is `"Query"` (these return datasets). `query.sql` stays a thin `EXEC` wrapper.

**`sqlType` is Designer's own enum, not `java.sql.Types`.** The codes needed here:

| sqlType | Designer name | Used for |
|---|---|---|
| `3` | Int8 | every `BIGINT` id |
| `7` | String | `@Query`, `serialNumber` |
| `8` | DateTime | `createdFromEt`, `createdToEt` |
| `2` | Int4 | `limitRows` |

Anything copied from a JDBC reference (`-5`, `-9`) is wrong and will be rewritten on the next Designer save.

### 6.2 The three-layer rule

**View → Entity script → `Common.Db` → `system.db`.** Views call entity scripts only; only `Common.Db.*` touches `system.db.*`. A view calling `system.db.runNamedQuery` directly is the "mixing direct `system.db` calls with entity-script abstractions" anti-pattern — it leaves no single place for logging, audit-user injection, or retry, and the prior revision of this spec committed exactly that error.

New functions in `BlueRidge.Lots.Lot`:

```python
_EMPTY_FILTERS = {
    "query": None, "itemId": None, "createdFromEt": None, "createdToEt": None,
    "toolId": None, "toolCavityId": None, "locationId": None,
    "machineLocationId": None, "shiftId": None, "lotStatusId": None,
    "lotOriginTypeId": None, "limitRows": 100,
}

def searchAdvanced(filters=None): ...
def handleSearch(view): ...      # view-facing one-liner target
def exportCsv(rows): ...
```

`BlueRidge.Lots.SerializedPart` and `BlueRidge.Lots.Container` gain the trace-detail reads and a `loadTraceDetail(matchType, matchedEntityId, serialNumber)` dispatcher.

**Inline event scripts cap at 1–3 lines.** Every view handler in this design is a one-liner delegating to an entity script — the multi-line handlers in the prior revision are factored out.

### 6.3 Date picker → `DATE` parameter

`ia.input.date-time-input` `props.value` is a **numeric millisecond timestamp**, not a string — initialising `view.custom.filters.createdFromEt` with `"2026-08-18"` produces a binding-type mismatch and the picker will not render. Its `props.format` uses **Moment.js** tokens (`YYYY-MM-DD`); the expression-language `parseDate` in the same component uses **Java** tokens. Two format languages, one component.

The entity script floors the millis to a date before the NQ call (`system.date.midnight(...)`), so the proc receives a clean `DATE`.

> **Stated assumption:** `system.date.midnight` floors in the session's timezone. The plant runs `session.props.timeZoneId` = Eastern, so this agrees with the proc's Eastern-day semantics. If a session ever runs in another timezone the floor would be off by the offset — out of scope here, noted so it is not a silent surprise.

### 6.4 Views — Designer only

`LotSearch` and `GlobalTrace` both already exist, so both are edited in **Designer**, not by file edit. Designer's GSON writer escapes `=`, `'`, `<`, `>`, `&` as six-character unicode literals, and its in-memory model conflicts with on-disk changes.

New table columns must carry the **full ~25-key column schema** — `header` is an object (`{title, justify, align, style}`), never a bare string; a string there breaks the whole table. Copy an existing column object and change `field`, `header.title`, `width`, `visible`.

---

## 7. Testing

**SQL** — per-proc files under `sql/tests/`, `INSERT-EXEC` into a temp table matching the SELECT shape. `Lot_SearchAdvanced` needs: one case per filter plus a combined case; an Eastern-day boundary case (a LOT written at 01:00 UTC must be found on the *prior* Eastern day and absent from the UTC day); an origin-conditional case (a NULL-`ToolId` LOT returns unfiltered and is excluded by any `@ToolId`); and a `TotalCount` case across a pager boundary. Each container sibling asserts its count agrees with the corresponding count column on `Container_GetTraceDetail`.

**Signature parity** — one test asserts that the proc's parameter list, the NQ's `parameters[]`, and `_EMPTY_FILTERS` carry the same twelve names. This is the guard against the key-drift risk in §3.1(b); without it, a filter can go silently inert.

**Regression** — `Lot_Search`, `077_Lot_Search.sql`, and the `HoldManagement` bulk picker must all be untouched and still pass. That is the whole point of §2.3, and the full suite run is the evidence.

**Perspective** — row-0 click must navigate (the `if not sel` trap **and** the missing-`Id`-column trap), and each detail panel must render an empty state with no Component Error.

> The in-app browser renders Perspective views and fires buttons but **cannot commit input bindings** — dropdowns, date pickers and text fields will not take a value through it. Verify filter behaviour via SQL against the proc; use the browser for render and row-click only.

---

## 8. Handed to the companion spec

**Persist scrap location on `RejectEvent`.** `Workorder.RejectEvent` has no location column, while `ProductionEvent` and `ConsumptionEvent` both carry `TerminalLocationId`. `Workorder.RejectEvent_Record` **already accepts `@TerminalLocationId`**, commented `-- audit-only; no column on RejectEvent`. Add `TerminalLocationId BIGINT NULL FK → Location.Location(Id)` plus one line in the INSERT, and backfill once from the last `LotMovement` before `RecordedAt`. Read-time derivation was rejected: `Lot.CurrentLocationId` drifts (a casting scrapped at Die Cast then moved to Trim and Machining would report as Machining — the failure FDS-02-002a exists to prevent), and last-movement-before-`RecordedAt` is a correlated lookup per reject row against a partitioned table on every run.

**Departmental scrap derives from `DefectCodeId`.** Migration `0048` (2026-08-04) dropped `DefectCode.AreaLocationId` for `OperationCategoryId` (DieCast / Trim / MachiningAssembly, NULL = plant-wide). The legacy Departmental Scrap block maps directly: Die Cast 59 codes, Machine Shop 75, Trim Shop 6. `RejectEvent.ChargeToArea` is derived rather than entered — in every row of `Search Reject.pdf` the ChargeTo equals the defect code's home department, with no override observed.

**`ChargeToParty` code table — decided 2026-08-25.** The legacy splits the remaining 13 plant-wide codes into *Non-Specific Supplier* (the 6 HSP codes) and *Non-Specific MPP* (Prod. Control + Quality Control), a distinction `0048` collapsed into one NULL bucket. Resolution: a `ChargeToParty` code table FK'd from `Quality.DefectCode`, seeded `DieCast`, `TrimShop`, `MachineShop`, `DieMaintenance`, `MppNonSpecific`, `SupplierNonSpecific`, backfilled from the `DeptDesc` column still present in `reference/seed_data/defect_codes.csv`. This keeps responsibility orthogonal to process (`OperationCategory` drives reject-screen filtering — a different job) and gives supplier chargeback a real home.

**Decide the Shipping History date basis** per §2.5 — `CompletedAt` versus a new `Container.ShippedAt`.

---

## 9. Ignition context-pack review record

Reviewed 2026-08-25 against all ten files of `ignition-context-pack/`. Three defects in the prior revision were corrected:

1. **Latent runtime bug — row-click would have raised `KeyError`.** `selection.data` carries only fields with a defined column, and `Id` is not displayed. Fixed by adding a `visible: false` `Id` column (§3.6). This would have shipped and failed on the first click.
2. **Three-layer-rule violation.** The prior revision had the view calling `system.db.runNamedQuery` directly, and multi-line inline handlers well past the 1–3 line cap. Both are named anti-patterns. Fixed in §6.2.
3. **Wrong `sqlType`.** `includeDescendants` was typed `2` (Int4) for a `BIT`; the correct code is `6` (Boolean). Moot now — the parameter was cut in §3.1 — but the enum table in §6.1 records the correct codes.

Also folded in: `position.display` over `meta.visible` (§4.4); NQ `version: 2` (§6.1); the full ~25-key table-column schema (§6.4); `date-time-input` millisecond values and its two format languages (§6.3); `getSibling` resolving only true siblings (§3.7).

---

## 10. Documentation corrections owed

*(Assigned to a separate agent; not actioned here.)*

1. **`MPP_MES_FDS.md:411`** asserts `Quality.RejectEvent.LocationId` is location-anchored. Wrong schema (`Workorder`) and the column has never existed.
2. **`MPP_MES_DATA_MODEL.md:1148`** still documents `DefectCode.AreaLocationId`, dropped by `0048`. Replace with `OperationCategoryId`.
3. **`MPP_MES_DATA_MODEL.md:1102`** describes `RejectEvent.ChargeToArea` as "Area responsible for the reject". Restate as derived-from-defect-code; add `TerminalLocationId` when it lands.
4. **`notes/2026-07-09_fds-gap-audit.md`** claims the trace resolver handles only LOTs — superseded by the 2026-07-10 revision. Annotate, don't delete.
5. **FDS-12-003** wording: *"container name"* → *"container ID"* per §2.4.
6. **UJ-19 / OI-30.** These six exports are the first real evidence. UJ-19's recommended direction still cites *"UJ-11's recommended phased rollout"*, but UJ-11 closed 2026-04-27 as **Option A, all-at-once hard cutover**. The recommendation is stale and the transition-shape half of UJ-19 is answered; only enumeration remains open.

---

## 11. Schema validation record

Validated 2026-08-25 against the reset path (`sql/migrations/versioned/0001`–`0066` plus `sql/seeds/`), not the data-model document, which was found stale in three places (§10).

| Claim | Source |
|---|---|
| `Lots.Lot` — `LotName`, `ItemId`, `LotOriginTypeId`, `LotStatusId`, `PieceCount`, `VendorLotNumber`, `ToolId`, `ToolCavityId`, `CurrentLocationId`, `CreatedAt`, plus legacy `DieNumber` / `CavityNumber` | `0020` |
| `Lots.LotMovement` — `FromLocationId` NULL on first placement, `ToLocationId`, `MovedAt` | `0020` |
| `Workorder.DieCastContribution.CellLocationId` (nullable, write-time press stamp) | `0061` |
| `Tools.ToolCavity.CavityNumber INT`; `Tools.Tool.Code` | `0010` |
| `Quality.HoldEvent.ContainerId` with `CK_HoldEvent_LotXorContainer` | `0029` |
| `Lots.ShippingLabel.AimShipperId NVARCHAR(50) NOT NULL`; no ship timestamp | `0029` |
| `Lots.ContainerTray.PartsClosedCount`; `Lots.ContainerSerial.SerializedPartId` | `0028` |
| `Lots.ContainerTray.FinishedGoodLotId` | `0034` |
| `Location.AppUser.DisplayName NVARCHAR(200) NOT NULL` | AppUser CREATE |
| Descendant walk = recursive CTE on `Location.Location.ParentLocationId` | `R__Lots_Lot_GetWipQueueByLocation` |
| `Workorder.RejectEvent` has no location column; `RejectEvent_Record` takes `@TerminalLocationId` marked audit-only | `0020`, `R__Workorder_RejectEvent_Record` |
| `Quality.DefectCode.OperationCategoryId` replaced `AreaLocationId` | `0048` |

**Corrected during validation:** origin machine moved from `LotMovement` to `DieCastContribution.CellLocationId` (§3.3); ship date found absent everywhere (§2.5); legacy `DieNumber` / `CavityNumber` identified as superseded (§3.4).
