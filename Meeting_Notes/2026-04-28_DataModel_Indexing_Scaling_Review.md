# Data Model Indexing & Query-Performance Review

**Date:** 2026-04-28 (Decision Gate callout added 2026-04-29)
**Reviewer:** Blue Ridge Automation
**Scope:** `MPP_MES_DATA_MODEL.md` v1.9j against `sql/migrations/versioned/*.sql` index commitments + Arc 2 deferred-table specs
**Lens:** Customer-perspective concern about indexing and query performance at scale

---

## ⚠ Decision Gate — must resolve before Arc 2 Phase 1 SQL build

**Tracked as OIR OI-35** (added 2026-04-29, ⬜ Open / HIGH).

The 20-year retention requirement combined with MPP's observed throughput (~150K LOTs/year derived from Flexware's `IdentifierFormat=1,710,932` baseline after ~10–15 years of operation) projects to per-table volumes of 100M–1B rows on the high-volume audit + event tables. A 20-year blanket retention without architectural mitigations is not tractable on a single SQL Server 2022 instance.

**Decisions deferred but gated** (per Jacques's 2026-04-29 last-responsible-moment posture — defer the call, but Arc 2 Phase 1 SQL build does not commence until resolved):

1. Per-table retention class — push back on 20-year for `Audit.OperationLog` / `InterfaceLog` / `FailureLog` / `Oee.DowntimeEvent` / `Audit.ConfigLog`.
2. Monthly range partitioning + sliding-window automation across ~14 deferred high-volume event tables.
3. Clustered columnstore on partitions older than 90 days.
4. Materialized closure table for `Lots.LotGenealogy` so Honda audits don't recursive-CTE-walk 100M+ rows at year 15.
5. Materialize `TotalInProcess` / `InventoryAvailable` columns onto `Lots.Lot` (supersedes OI-23's view choice at scale; OI-23 stays Resolved — its choice was correct for MVP).
6. `Lots.IdentifierSequence_Next` locking model — explicit `WITH (ROWLOCK, UPDLOCK)` vs replace with SQL Server `SEQUENCE` object.
7. Split `Audit.OperationLog` into 7-year general audit + separate 20-year `Lots.LotEventLog` for traceability events.
8. Filtered indexes on hot subsets (active-LOT, open-pause, available-AIM-pool, banner-active, etc.) — systematic per-table pass.

**Why the gate is hard:** Items 2, 4, 5, 7 must be in the **CREATE migration** for the affected tables — adding partition schemes, closure tables, or materialization columns to populated 100M+ row tables later is operationally expensive (rebuild, log-volume blow-up, downtime window). Items 1, 3, 6, 8 are softer (post-CREATE configurable) but cleaner to lock in upfront.

**Resolution path:** Phase 0 facilitation workshop adds OI-35 as a topic. Internal Blue Ridge architecture review covers items 2–7. MPP IT covers item 1 (retention policy negotiation). Output: data model spec § "Scaling Decisions" pinning the schema-level commitments, drives the Arc 2 Phase 1 migration content.

The remainder of this document (the per-table indexing review) is the input to that conversation. The "What needs to be added" sections below set the **per-table index list** layer; OI-35 sets the **retention / partitioning / materialization** layer. Both feed the Arc 2 Phase 1 migration.

---

## Summary

The data model is in **good shape for Phase 1–8 already-built schemas**. The Audit, Tools, Location, Parts (Item / BOM / Route / QualitySpec), Quality reference tables, and OEE reference tables all have sensible index coverage actually migrated and tested.

The **gap is in the deferred Arc 2 schemas** — specifically the high-volume Lots and Workorder event tables. The data model describes columns but does not commit to indexes. When Arc 2 Phase 1 CREATEs those tables, the migration needs an explicit index list — and the data model spec should pin that list upfront so it doesn't get missed.

Three architectural concerns also need decisions before scale: 20-year audit retention strategy, view materialization criteria for `v_LotDerivedQuantities`, and recursive-CTE depth limits on `LotGenealogy`.

---

## What's already in good shape

### Audit schema (highest-volume hot tables) — fully covered

| Table | Indexes (migrated in `0001_bootstrap_schemas_audit_identity.sql`) |
|---|---|
| `Audit.OperationLog` | `(LoggedAt DESC)`, `(LogEntityTypeId, EntityId, LoggedAt DESC)`, `(UserId, LoggedAt DESC)` |
| `Audit.ConfigLog` | Same three shapes |
| `Audit.InterfaceLog` | `(LoggedAt DESC)`, `(SystemName, LoggedAt DESC)` |
| `Audit.FailureLog` | 4 indexes — including `(ProcedureName, AttemptedAt DESC)` for the "Top Failing Procedures" dashboard tile (FDS-11-004) |

Covers recent-activity, entity-drill, user-drill, and per-system query shapes.

### Plant model (Location schema)

`IX_Location_ParentLocationId`, `IX_Location_LocationTypeDefinitionId`, etc. — supports the recursive-CTE walks for the ISA-95 hierarchy.

### Phase G Tools schema

Each table has a sensible set: filtered uniques on active rows (`UQ_ToolAssignment_ActiveTool`, `UQ_ToolAssignment_ActiveCell`), FK indexes, and `(...DESC)` orderings on history tables.

### Master data (Item / Container / Route / BOM / QualitySpec)

FK indexes on all the join columns plus `EffectiveFrom`-ordered indexes on versioned tables. The BOM-derived eligibility view (FDS-02-012) leans on `IX_Bom_ParentItemId_EffectiveFrom` and `IX_BomLine_ChildItemId` — both already in place.

### Already-spec'd deferred tables

`Lots.PauseEvent` and `Lots.AimShipperIdPool` carry explicit index commitments in the data model spec. `IX_AimShipperIdPool_Available (FetchedAt) WHERE ConsumedAt IS NULL` is exactly the right shape for the FIFO claim under `Container_Complete`.

### `Workorder.ProductionEvent` v1.9 reshape

Already commits to `(LotId, EventAt DESC)` for `LAG()`-derived deltas.

---

## Critical gaps — high-volume Arc 2 deferred tables

These will be the busiest tables in the system once Arc 2 Phase 1 lands. The data model describes columns but doesn't commit to indexes. The migration must add these; the data model spec should pin the commitments upfront so nothing gets missed.

| Table | Missing indexes | Why it matters |
|---|---|---|
| `Lots.LotMovement` | `(LotId, MovedAt DESC)`, `(ToLocationId, MovedAt DESC)` | LOT history; Lot Details screen; shift-end summary; derived-quantities view. The `ToLocationId` shape was already flagged in FDS-09-015 perf note — formalize it. |
| `Lots.LotGenealogy` | `(ParentLotId)`, `(ChildLotId)` | **Honda critical path.** Recursive CTE walks both directions; without these, every hop is a table scan. |
| `Lots.LotStatusHistory` | `(LotId, ChangedAt DESC)` | Status history per LOT — basic Lot Details query. |
| `Lots.LotAttributeChange` | `(LotId, ChangedAt DESC)` | Attribute history per LOT. |
| `Lots.SerializedPart` | `(LotId)`, `(ContainerId) WHERE ContainerId IS NOT NULL` | "Serials from this LOT" (Honda); "serials in this container" (Sort Cage). UNIQUE on `SerialNumber` already covers serial lookup. |
| `Lots.ContainerSerial` | `(ContainerId, ContainerTrayId)`, `(SerializedPartId)` | Container-by-tray fill queries; Sort Cage migration trace. |
| `Lots.ShippingLabel` | `(ContainerId)`, `(AimShipperId)`, plus **two filtered indexes** for FDS-07-006b broadcast: `(...) WHERE PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL` and `(...) WHERE PrintedAt IS NULL AND PrintFailedAt IS NULL` | Container void/reprint; Honda search by Shipper ID; the Gateway broadcast script's 5s sweep. |
| `Lots.Container` | `(LotId)`, `(CurrentLocationId)` | Containers per LOT, containers at location. UNIQUE on `ContainerName` already covers name lookup. |
| `Lots.LotLabel` | `(LotId, PrintedAt DESC)` | Print history per LOT. |
| `Workorder.ConsumptionEvent` | `(SourceLotId, ConsumedAt DESC)`, `(ProducedLotId, ConsumedAt DESC)`, `(WorkOrderOperationId, ConsumedAt DESC)` | Both genealogy directions; WO-level rollup. |
| `Workorder.RejectEvent` | `(LotId, RecordedAt DESC)`, `(DefectCodeId, RecordedAt DESC)` | Rejects per LOT; reject-rate-by-code reports (FDS-12-006). |
| `Workorder.ProductionEvent` | Add `(WorkOrderOperationId, EventAt DESC)` to existing `(LotId, EventAt DESC)` | WO auto-finish (FDS-06-028) needs to sum across all events under a WO. |
| `Workorder.ProductionEventValue` | UNIQUE `(ProductionEventId, DataCollectionFieldId)` already covers reads-by-event; add `(DataCollectionFieldId)` only if "all values of field X across events" reporting is needed | **EAV child of ProductionEvent — added 2026-06-08.** Grows as events × non-promoted fields. Partition-align with `ProductionEvent`. Already structurally sound (`Value` + `NumericValue DECIMAL(18,4)` shadow). |
| `Quality.QualityResult` | `(QualitySampleId)` (all measured attrs for a sample); `(QualitySpecAttributeId, NumericValue)` for SPC/trend over a measured characteristic | **EAV child of QualitySample — added 2026-06-08.** Grows as samples × attrs-per-spec. `NumericValue DECIMAL(18,4)` shadow added in DM v1.9p so SPC/Cpk range queries are indexable rather than CAST-bound. Partition-align with `QualitySample`. |
| `Oee.DowntimeEvent` | `(LocationId, StartedAt DESC)`, `(LocationId) WHERE EndedAt IS NULL`, `(ShiftId, StartedAt DESC)` | Open downtime at a machine; downtime-by-shift reports. |
| `Quality.HoldEvent` | `(LotId) WHERE ReleasedAt IS NULL`, `(ReleasedAt) WHERE ReleasedAt IS NULL` | Active holds per LOT and plant-wide active-hold dashboard. |

---

## Architectural concerns that need decisions before scale

### 1. 20-year audit retention strategy is not spec'd

FDS-11-009 says 20-year retention with 6 months "hot." Without partitioning or an archival job, `Audit.OperationLog` and `Audit.InterfaceLog` will become unmanageable. By year 3 the existing indexes will still work but query plans will degrade meaningfully.

**Recommendation:** spec a partition scheme (by year) or an archival job that moves rows >6 months old to an archive table. Choose one and write it into FDS §11 + the data model spec.

### 2. `Lots.v_LotDerivedQuantities` view (FDS-05-031) — materialization criteria not pinned

The view aggregates `Workorder.ProductionEvent` and `Workorder.ConsumptionEvent` per LOT on every Lot Details screen open. At MPP scale this could be expensive. The spec notes it MAY be replaced by an indexed view or materialized table — but the **criteria** for that promotion aren't pinned.

**Recommendation:** capture query-plan + execution-time benchmarks during Arc 2 Phase 2, with a numeric threshold (e.g., "if p95 > 200ms at production volume, materialize"). Don't promote prematurely; don't ignore until it's a fire.

### 3. `Lots.LotGenealogy` recursive CTE — depth limit not pinned

The recursive CTE walks for Honda traceability. The data model doesn't spec `OPTION (MAXRECURSION N)`. At deep traces (long-running cast → trim → multiple machinings → assembly → containers → ship), default MAXRECURSION 100 would be hit before exhaustion but it's not committed.

**Recommendation:** pin `OPTION (MAXRECURSION 50)` as the default for genealogy-walk procs (~10 production stages × multiple per-stage hops with headroom). Document in proc spec.

### 4. `IdentifierSequence_Next` contention point

The atomic UPDATE on `LastValue` for every LOT and SerializedItem mint is a single-row hot lock. At MPP's mint rate (LOTs hourly, serials per-shot on serialized lines) this is fine — but a volume spike could serialize calls.

**Recommendation:** the proc spec should explicitly use `WITH (UPDLOCK, ROWLOCK)` to scope contention narrowly and call out the contention model in the doc so future readers understand the trade-off.

### 5. `Parts.v_EffectiveItemLocation` (FDS-02-012)

Hits on every scan-in for eligibility checks. The two index dependencies (`Bom.ParentItemId` + `BomLine.ChildItemId`) are already covered by existing indexes. **No action needed**, just noting it was checked.

---

## Lower-risk items to flag for the data model bump

- The data model spec for the deferred Arc 2 tables is structurally inconsistent — some have explicit `**Indexes:**` blocks, most don't. Worth standardizing: every table gets an explicit `**Indexes:**` list, even if the list is just FK indexes + `CreatedAt DESC`.
- `Lots.Container.AimShipperId` is currently `NVARCHAR(50) NULL` with no UNIQUE or index. Honda doesn't reissue Shipper IDs (per UJ-04), so UNIQUE is plausible. Confirm with Jacques — if UNIQUE, the constraint becomes the index; if not, add an index.
- `Lots.ContainerSerial` doesn't have a UNIQUE on `SerializedPartId`. Under the UJ-05 update-in-place model that's correct (one current row per serial after Sort Cage migration), but the spec doesn't make that explicit.

---

## Recommended next action

A deliberate **indexing pass on the deferred Arc 2 tables** before Arc 2 Phase 1 lands. Concrete proposal: a focused working session that adds `**Indexes:**` blocks to every deferred-CREATE table in the data model spec, using the gap table above as the starting list. Output: a v1.9k or v1.10 data model bump that pins Arc 2 Phase 1's index commitments before the migration is written.

The architectural concerns (#1–#3) are decisions, not implementation work — best handled in a separate FDS pass.

---

## Status

- **Findings landed:** this document.
- **Action items:** queued for next data model bump and a separate FDS retention/CTE/view pass.
- **No code or schema changed by this review.**
