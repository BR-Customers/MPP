# MPP MES — System Summary & Track-and-Trace Requirements

**Project:** Madison Precision Products MES Replacement
**Client:** Madison Precision Products, Inc. (Madison, IN)
**Context:** Tier 2 Honda supplier — aluminum die casting
**Replacing:** Legacy WPF/.NET MES ("Manufacturing Director")
**Based On:** Flexware FRS v1.0 (3/15/2024), annotated by Blue Ridge Automation

---

## Revision History

| Version | Date | Author | Change Summary |
|---|---|---|---|
| 0.1 | 2026-04-02 | Blue Ridge Automation | Initial summary — production flow, scope matrix, data model overview, session notes |
| 0.2 | 2026-04-06 | Blue Ridge Automation | Added FDS status, user journeys reference, scope assessment, session notes |
| 0.3 | 2026-04-09 | Blue Ridge Automation | Added 2026-04-09 session notes with OI/UJ decision table and status roll-up. Added 4 design decisions (terminal as location type, no outbox, WO MVP-lite, warm-up as downtime). Updated FDS status to v0.2. |
| 0.4 | 2026-04-09 | Blue Ridge Automation | UpperCamelCase naming convention applied to all DB references. Merged Department into Area per ISA-95 hierarchy. Added Enterprise level. |
| 0.5 | 2026-04-10 | Blue Ridge Automation | Location model restructured — see FDS v0.4 and Data Model v0.4. `LocationType` reduced to 5 ISA-95 tiers; `LocationTypeDefinition` repurposed as polymorphic kinds; new `LocationAttributeDefinition` for per-kind attribute schemas. |
| 0.6 | 2026-04-22 | Blue Ridge Automation | **Phase E of the 2026-04-20 OI review refactor — design + doc additions for OI-11..23.** 13 items closed as designed: 4 from the 2026-04-20 MPP meeting (OI-11 Casting→Trim rename, OI-12 lineside caps, OI-13 Flexware BOM import, OI-14 admin remove-item) + 9 from the 2026-04-22 legacy-screenshot review (OI-15 Global Track screen, OI-16 auto-finish-on-target WO, OI-17 tray divisibility, OI-18 ItemLocation consumption metadata, OI-19 Country of Origin, OI-20 Scrap Source enum, OI-21 partial start/complete, OI-22 Hold Management screen, OI-23 Lot computed quantities). Data Model v1.7 → v1.8 (5 additive schema changes), FDS v0.9 → v0.10 (new §5.10 Part Identity Change, §12.5 Global Trace Tool, plus requirements across §§1.4/3.1/3.5/3.6/4.3/5.1/5.3/6.8/6.10/8.2/14), User Journeys v0.6 → v0.7 (Casting→Trim identity-change scene + Track tile usage at Sort Cage). 7 discovery items (OI-24..30) parked for MPP input. Phase F (regenerate derived artifacts) and Phase G (SQL migration) queued. |

---

## What the System Needs

MPP produces die-cast aluminum parts primarily for Honda. They are replacing a legacy MES with a modern system. The core mission is **LOT traceability from raw aluminum through shipping** — Honda requires full genealogy for every part.

### The Production Flow

```
Raw Aluminum → Die Cast → Trim/Clean → Machining → Assembly → Delivery/Shipping
                  ↑                        ↑            ↑           ↑
              LOT created            Sub-LOTs created  Parts consumed  AIM shipping
              (LTT tag)              from parent LOTs  into finished   labels printed
                                                       goods
```

Parts can skip stages, repeat stages, or enter mid-stream as "pass-through" parts from external suppliers.

### LOT Creation Paths

| Origin | How It Enters MES | Location |
|---|---|---|
| **Manufactured** | Operator fills basket at die cast, attaches pre-printed LTT tag, scans into MES | Die Cast area |
| **Received** | Pass-through parts arrive from vendor, operator creates LOT with vendor lot info | Receiving Dock |
| **Received Off-Site** | Pass-through parts received at remote warehouse, operator creates LOT via off-site app | Off-site location |

Raw aluminum ingots are **not** tracked in MES (FRS req 3.9.1) — they go through Macola ERP only.

---

## Scope Legend

Each requirement section below is tagged with its scope status per the **MPP Scope Matrix** (project authority):

| Tag | Meaning |
|---|---|
| **`MVP`** | Included in current project scope |
| **`MVP-EXPANDED`** | Included and expanded beyond legacy system capabilities |
| **`CONDITIONAL`** | Included subject to conditions (budget approval, design decision) |
| **`FUTURE`** | Designed for but **not** in current scope — retained for future project phases |

Tables and schemas supporting FUTURE capabilities are kept in the data model to preserve architectural coherence. They will not be implemented, populated, or tested in the current phase but are ready for activation when scope expands.

---

## Primary Track & Trace Requirements

### 1. LOT Lifecycle — `MVP`

- LOTs are created at Die Cast (manufactured) or at receiving (pass-through parts, on-site or off-site)
- Each LOT has: Part Number, Piece Count, Weight, Die #, Cavity #, Vendor LOT#, Hold State, Max Piece Count, Origin Type
- LOT IDs are unique, pre-printed on physical LOT Tracking Tickets (LTT), barcoded
- LOTs move through locations in the plant hierarchy: Die Cast → Trim → Machining → Assembly → Delivery
- Every LOT attribute change must be audited (who, when, from which terminal)
- All LOT label prints and reprints are tracked (initial, damaged reprint, split/merge, Sort Cage re-identification)

### 2. Sub-LOT (Split/Merge) — `MVP`

- Parent LOTs split into child Sub-LOTs after machining (configurable default sub-lot size per part)
- Sub-LOTs must maintain parent relationship permanently via genealogy graph
- LOTs can also be merged into new LOTs (business rules TBD by MPP)
- Full genealogy queryable in both directions (parent→child, child→parent) via adjacency list + recursive CTEs
- Partial quality dispositions handled through split: bad parts split off and scrapped, good parts released

### 3. Production & Consumption Tracking — `MVP-EXPANDED`

- As parts are processed at a machine, MES decrements source LOT piece count
- Finished goods are produced into containers/trays
- Each finished good must trace back to every component LOT consumed
- Good count / No-Good count recorded per LOT per operation as immutable production events
- Work orders are auto-generated internally — operators never see them
- Work orders subscribe to an item's predefined route, prescribing the journey through the plant
- Each work order operation tracks the actual location, status, and timing of each route step
- Die number and cavity number are LOT-level attributes (not per production event) since a LOT is produced from a specific die/cavity

### 4. Serialized Parts — `MVP-EXPANDED`

- Some assembly lines serialize individual parts (laser etched)
- Each serial number links back to its source LOT and item permanently
- Serial numbers mapped to specific container tray positions
- Sort Cage workflow requires serial number migration when containers are re-inspected and re-packed

### 5. Container & Shipping — `MVP`

- Finished goods packed into Honda-specified containers with trays
- Container configuration is per-product (parts schema): trays per container, parts per tray, serialized flag, dunnage code
- MES requests shipping IDs from AIM (Honda EDI system) and prints ZPL shipping labels
- Containers can be placed on hold, sent to Sort Cage for re-inspection, re-labeled
- Both LOT labels (LTT) and shipping labels are tracked with full print/void/reprint history

### 6. Quality / Hold System — MIXED SCOPE

**Holds** — `MVP-EXPANDED`
- LOT quality status: GOOD → HOLD → SCRAP → CLOSED (code-table backed, `BlocksProduction` flag drives interlocks)
- Hold prevents further manufacturing operations until released by authorized quality personnel
- Hold can exist without an NCM (precautionary customer complaint)
- Partial dispositions handled via LOT split (split bad parts off, dispose separately, release remainder)

**Inspections** — `MVP`
- Quality specs are versioned (spec-driven schema, not EAV) — production records FK to the spec version active at time of inspection
- ~170 defect codes organized by department (supports both reject tracking and future NCM)

**Sampling** — `CONDITIONAL`
- Quality samples taken from LOTs; results assumed representative of entire LOT
- File attachments (CSV, Excel, PDF, images) supported on samples and non-conformances

**Non-Conformance Management / Failure Analysis** — `FUTURE`
> *NCM/Failure Analysis is not included in current scope per the Scope Matrix. The `NonConformance` table and its relationship to `HoldEvent` are retained in the data model to preserve the design separation between holds and NCMs. When this capability is activated, it provides structured defect disposition (USE_AS_IS, REWORK, SCRAP, RETURN_TO_VENDOR), linking NCMs to specific LOTs and defect codes, with full attachment support. This is the natural second phase of quality management after holds and inspections are operational.*
- Non-conformance and hold are separate concerns — an NCM can exist without a hold (minor defects), and a hold can exist without an NCM (precautionary)
- Non-conformance tracking with ~170 defect codes organized by department

### 7. Plant Model — `MVP`

- ISA-95 hierarchy implemented as a **self-referential `Location` table** with `LocationType` discriminator
- Location types: Site, Area, Department, Line, Machine, Work Cell, Inventory Location — all in one table
- Departments (Die Cast, Trim Shop, Machine Shop, Prod. Control) are a location type, not a separate table
- **Configurable attributes per location type** via `LocationTypeDefinition` + `LocationAttribute` — different work cells or machines can carry different KPI sets (OEE target, cycle time, tonnage, queue depth) without schema changes
- Part-to-location eligibility mapping controls which parts can run on which machines
- ~230 machines across departments
- Supports physical and logical inventory locations (including off-site)
- Receiving Dock, Shipping Dock, Sort Cage, WIP Storage are all location nodes in the hierarchy

### 8. Downtime & OEE — MIXED SCOPE

**Downtime** — `MVP`
- ~660 downtime reason codes by department and type (Equipment, Mold, Quality, Setup, Miscellaneous, Unscheduled)
- Manual and PLC-triggered downtime events per machine (append-only, `EndedAt` null while open)
- Shift schedule support with named patterns and actual shift instances

**OEE / KPIs** — `FUTURE`
> *OEE and KPIs are not included in current scope per the Scope Matrix. The `OeeSnapshot` table is retained in the data model because it is a natural derivative of the downtime and production event data that IS being collected in MVP. Once downtime tracking is operational, OEE calculation is a scheduled job that materializes snapshots from existing data — no new data capture is required. KPI dashboards are a presentation layer on top of the same foundation.*
- OEE calculated as materialized snapshots per machine per shift (OLTP/OLAP separation — snapshot is derivative, not system of record)

### 9. Audit & Logging — `MVP`

- Every state-changing action logged: user, terminal, timestamp, action, affected entity, old/new values
- Three log types: operations (shop-floor), configuration (admin/engineering), interface (external systems)
- Event types and entity types are **normalized code tables** (not free-text) to prevent drift across Ignition scripts
- Configurable high-fidelity logging for external system interface payloads
- 20-year data retention requirement (6 months online minimum)
- BIGINT PKs on log tables for high-volume append patterns

### 10. Authentication & Authorization — `MVP`

- **Interactive users** (Quality, Supervisor, Engineering, Admin) authenticate via **Active Directory** — `AdAccount` is the identity
- **Operators** do not authenticate — they are identified by **initials** entered at a shop-floor terminal, which pre-populate a defeasible Initials field on every mutation screen (FDS §4)
- Roles are managed in **Ignition's internal identity provider** — no custom RBAC tables in the MES database
- MES stores `AppUser` records (both classes) for audit trail attribution; Operator-class rows carry `AdAccount = NULL` and no Ignition role
- Elevated actions (holds, overrides, scrap, maintenance WOs, admin edits) require a fresh per-action AD prompt — no session-sticky elevation, no clock-number/PIN convenience login (OI-06 closed 2026-04-20)

### 11. External Integrations — MIXED SCOPE

- **AIM** (Honda EDI): GetNextNumber, UpdateAim, PlaceOnHold, ReleaseFromHold — `MVP`
- **PLC/OPC**: Scales (OmniServer), PLCs (TOPServer) — weight verification, part interlock, serial number reads — `MVP`
- **Barcode**: Zebra printers via ZPL, 2D barcode scanners as keyboard wedge — `MVP`
- **Historization/Trending**: Tag history via Ignition Historian — `MVP` (FRS 3.4.10, 5.5.1)
- **SCADA Alarming**: Machine and process alarms — `CONDITIONAL` (FRS 3.4.8)
- **Macola ERP**: CSV import of Items/BOMs, possible production data export — `FUTURE`
- **Intelex**: Existing QC document management — possible future integration via REST API — `FUTURE`
- **SCADA Dashboards/Reporting**: Process data dashboards and reporting — `FUTURE`
- **Maintenance Integration**: No current system — `FUTURE`

---

## Database Architecture

### Design Principles

- **SQL Server 2022 Standard Edition** on Windows Server 2019+
- **Normalize to 3NF** — denormalize deliberately for proven performance needs only
- **Surrogate PKs** (auto-incrementing integers) — natural keys (lot names, part numbers) are unique-indexed columns, not PKs
- **`DeprecatedAt` soft deletes** — nullable timestamp, non-null = inactive
- **`DATETIME2(3)` everywhere** — millisecond precision for event sequencing and cycle time analysis
- **UOM as first-class column** on every quantitative measurement
- **Status fields code-table backed** with FK — no magic integers or free-text
- **Spec versioning** — BOMs, routes, and quality specs are versioned; production records FK to the version active at time of execution
- **Append-only event records** — production events, consumption events, movements, status transitions are immutable
- **Adjacency list + recursive CTEs** for both location hierarchy and LOT genealogy
- **OLTP/OLAP separation** — OEE snapshots are materialized derivatives, not live-computed from normalized tables
- **Historian data stays in Ignition** — tag values are not replicated into the MES SQL layer

### Schema Overview (7 schemas, ~50 tables)

| Schema | Purpose | Key Tables |
|---|---|---|
| **location** | Plant model, terminals, users | `LocationType`, `LocationTypeDefinition`, `Location`, `LocationAttribute`, `Terminal`, `AppUser` |
| **parts** | Item master, BOMs, routes, operations | `Item`, `ItemType`, `Uom`, `Bom`, `BomLine`, `RouteTemplate`, `RouteStep`, `OperationTemplate`, `ItemLocation`, `ContainerConfig` |
| **lots** | LOT lifecycle, genealogy, containers, shipping | `Lot`, `LotOriginType`, `LotStatusCode`, `LotGenealogy`, `GenealogyRelationshipType`, `LotStatusHistory`, `LotMovement`, `LotAttributeChange`, `LotLabel`, `Container`, `ContainerStatusCode`, `ContainerTray`, `SerializedPart`, `ContainerSerial`, `ShippingLabel` |
| **workorder** | Production context, events, consumption | `WorkOrder`, `WorkOrderStatus`, `WorkOrderOperation`, `OperationStatus`, `ProductionEvent`, `ConsumptionEvent`, `RejectEvent` |
| **quality** | Specs, samples, NCM, holds | `DefectCode`, `QualitySpec`, `QualitySpecVersion`, `QualitySpecAttribute`, `QualitySample`, `QualityResult`, `QualityAttachment`, `NonConformance`, `HoldEvent` |
| **oee** | Downtime, shifts, OEE metrics | `DowntimeReasonType`, `DowntimeReasonCode`, `ShiftSchedule`, `Shift`, `DowntimeEvent`, `OeeSnapshot` |
| **audit** | Immutable logging | `LogSeverity`, `LogEventType`, `LogEntityType`, `OperationLog`, `ConfigLog`, `InterfaceLog` |

### Data Flow Summary

```
PLAN LAYER (what should happen)
    Parts.Item → Parts.RouteTemplate → Parts.RouteStep → Parts.OperationTemplate
    "This product follows this route, collecting this data at each stop"

EXECUTION LAYER (what is happening)
    Workorder.WorkOrder → Workorder.WorkOrder_operation
    "This LOT is being processed at this location, at this step"

EVIDENCE LAYER (what did happen — immutable)
    Workorder.ProductionEvent    "This many good/bad parts came out"
    Workorder.ConsumptionEvent   "These source LOTs were consumed to make this output"
    Workorder.RejectEvent        "Here's why the bad parts were bad"

TRACEABILITY LAYER (the permanent record)
    Lots.Lot → Lots.Lot_genealogy        "Parent/child relationships from splits, merges, consumption"
    Lots.Lot → Lots.Lot_movement         "Where this LOT has been"
    Lots.Lot → Lots.Lot_status_history   "Quality status transitions"
    Lots.Lot → Lots.SerializedPart      "Individual serial numbers traced to source LOTs"
    Lots.Container → Lots.ShippingLabel "What shipped to Honda, with AIM shipper IDs"
```

### Cross-Schema Relationships

The schemas form a dependency graph:

```
location (foundation — everything references this)
    ↑
parts (master data — defines what and how)
    ↑
lots (LOT lifecycle — the core tracking entity)
    ↑
workorder (production execution — links lots to routes and machines)
    ↑
quality (quality management — specs, samples, holds against lots)

oee (downtime + metrics — references location and shifts)

audit (logging — references location for user/terminal/machine attribution)
```

### Key Design Decisions

| Decision | Rationale |
|---|---|
| Self-referential `Location` table instead of separate site/area/line/machine tables | One table, one hierarchy. Location types are data, not schema. Adding a Work Cell level doesn't require a migration. |
| `LocationTypeDefinition` + `LocationAttribute` for configurable KPIs | Different machines/cells can have different attribute sets. OEE targets, cycle times, queue depths are all definition-driven. No nullable columns cluttering the location table. |
| Areas replace departments in ISA-95 hierarchy | Departments cross-cut physical boundaries. They're just another node in the hierarchy, referenced by the same `LocationId` FK as any other location. |
| AD + Ignition roles instead of custom RBAC tables | Authentication is AD's job. Role management is Ignition's job. MES stores user records for audit attribution only. |
| Terminals as a location type, not a separate table | Terminals are shared (fewer than machines). Operator scans a machine barcode to resolve context. Terminal config (IP, printer, scanner) stored as `LocationAttribute`. Eliminates a table and aligns with the ISA-95 self-referential hierarchy. (OI-08, 2026-04-09) |
| Direct external calls + logging, no event outbox | FRS requires logging of interface activity (3.17.4), not an outbox pattern. External calls made directly from Ignition scripting layer with results logged to `InterfaceLog`. Simpler architecture. (OI-01, 2026-04-09) |
| Work orders included but hidden (MVP-lite) | Auto-generated behind the scenes, operators never see or interact with WOs. No WO screens. Production events function independently via nullable FKs. (OI-07, 2026-04-09) |
| Warm-up shots as downtime sub-category | Warm-up time tracked as downtime (reason_type = Setup) with shot count on the downtime event. Separates warm-up from production activity. (UJ-14, 2026-04-09) |
| `LotOriginType` on LOT | Distinguishes manufactured vs. received vs. received-offsite LOTs for filtering and reporting without inspecting creation context. |
| `LotLabel` table | Tracks every LTT barcode print/reprint. Required for initial labels, damaged reprints, split/merge labels, Sort Cage re-identification. |
| Die/cavity on LOT, not on production_event | A LOT is one part from one die and cavity. Production events are batch counts — storing a single cavity on a multi-cavity production event doesn't make sense. |
| Separate `NonConformance` and `HoldEvent` | An NCM can exist without a hold (minor defects logged but not blocking). A hold can exist without an NCM (precautionary). The FK between them is nullable. |
| Spec-driven quality attributes instead of EAV | `QualitySpecVersion` + `QualitySpecAttribute` defines what to measure per item/operation. Results validate against it. Versioned so historical records are unambiguous. |
| Normalized `LogEventType` and `LogEntityType` | Prevents free-text drift across Ignition scripts writing to audit tables. One vocabulary, one source of truth. |
| Materialized OEE snapshots | Availability × Performance × Quality computed per machine per shift by scheduled job. The normalized event tables are the system of record; the snapshot is a derivative. |

---

## Scope Assessment

### Scope Matrix Cross-Reference (Authority: `reference/MPP_Scope_Matrix.xlsx`)

| # | Area | Sub-Area | Scope Status | Data Model Coverage | FRS Ref |
|---|---|---|---|---|---|
| 1 | Implementation | Production / Asset Model | **MVP** | `Location` schema | — |
| 2 | Implementation | Data Migration | **CONDITIONAL** | Operational (80hr quote) | 3.6.0 |
| 3 | Production | Receiving (pass-through) | **MVP** | `LotOriginType` RECEIVED | 2.1.1 |
| 4 | Production | Work Orders | **CONDITIONAL** | `workorder` schema | 3.1.5, 3.10.0 |
| 5 | Production | Scheduling | **FUTURE** | No tables — not designed | 3.12.1 |
| 6 | Production | Inventory / WIP | **MVP** | `Lot` + `LotMovement` | — |
| 7 | Production | Lot Control | **MVP** | `Lots` schema | — |
| 8 | Quality | Inspections | **MVP** | `QualitySpec` + `QualityResult` | — |
| 9 | Quality | Sampling | **CONDITIONAL** | `QualitySample` | 2.1.9, 3.16.0 |
| 10 | Quality | No-go Part Inventory | **FUTURE** | No tables — not designed | — |
| 11 | Quality | Holds (expanded) | **MVP-EXPANDED** | `HoldEvent` | 2.1.8, 3.16.10 |
| 12 | Quality | Leak Tests | **FUTURE** | No tables — not designed | — |
| 13 | Quality | Torque Checks | **FUTURE** | No tables — not designed | — |
| 14 | Quality | NCM / Failure Analysis | **FUTURE** | `NonConformance` table retained | — |
| 15 | Performance | Production Data Acquisition | **MVP-EXPANDED** | `ProductionEvent`, `RejectEvent` | 3.5.4 |
| 16 | Performance | OEE | **FUTURE** | `OeeSnapshot` table retained | — |
| 17 | Performance | Downtime | **MVP** | `DowntimeEvent` + reason codes | 3.15.0 |
| 18 | Performance | KPIs | **FUTURE** | Derivative of MVP data | — |
| 19 | Traceability | Produced Parts Tracking | **MVP** | `LotGenealogy` + events | — |
| 20 | Traceability | Pass-through Parts Tracking | **MVP** | `LotOriginType`; full workflow FUTURE | 2.1.12, 5.6.4 |
| 21 | Traceability | Raw Material Tracking | **FUTURE** | Excluded per FRS 3.9.1 | — |
| 22 | Traceability | Serialization (expanded) | **MVP-EXPANDED** | `SerializedPart` + `ContainerSerial` | 2.1.10 |
| 23 | Traceability | Part Replacement | **MVP** | Container re-pack workflow | — |
| 24 | Traceability | Shipping Holds | **MVP** | `Container` HOLD status | — |
| 25 | Maintenance | Work Orders | **FUTURE** | No tables — not designed | — |
| 26 | Maintenance | Tool Life | **MVP** | **GAP — no table yet** (FRS 5.6.6) | 5.6.6 |
| 27 | Integrations | ERP (Macola) | **FUTURE** | `InterfaceLog` ready | — |
| 28 | Integrations | SCADA | **FUTURE** | No tables — Ignition-side | — |
| 29 | Integrations | Quality (Intelex) | **FUTURE** | `InterfaceLog` ready | 5.6.7 |
| 30 | Integrations | Shipping (AIM) | **MVP** | `ShippingLabel` + `InterfaceLog` | — |
| 31 | Integrations | Maintenance | **FUTURE** | No tables — not designed | — |
| 32 | Integrations | Production DB | **CONDITIONAL** | `InterfaceLog` | 3.14.0, 5.6.6 |
| 33 | Integrations | Plc Connections | **MVP** | `InterfaceLog` | — |
| 34 | SCADA | Process Data Dashboards | **FUTURE** | No tables — Ignition-side | — |
| 35 | SCADA | Historization / Trending | **MVP** | Ignition Historian (not MES SQL) | 3.4.10, 5.5.1 |
| 36 | SCADA | Process Reporting | **FUTURE** | Expanded scope noted | 3.5.14 |
| 37 | SCADA | Alarming | **CONDITIONAL** | Ignition-side | 3.4.8 |

### Summary Counts

| Status | Count | Notes |
|---|---|---|
| **MVP / MVP-EXPANDED** | 17 | Core deliverables |
| **CONDITIONAL** | 5 | Require budget approval or design decision |
| **FUTURE** | 15 | Designed for but not current scope |

### Known Gaps

| Gap | Scope Status | Action Required |
|---|---|---|
| **Tool Life tracking** | MVP (FRS 5.6.6) | No table in data model — needs design (location_attribute or dedicated table) |
| **Pass-through full workflow** | MVP entry, FUTURE tracking | Receiving is supported; full in-plant tracking workflow deferred |
| **Scheduling** | FUTURE | No tables designed — entirely future phase |
| **No-go Part Inventory** | FUTURE | No tables designed — requires scope definition |
| **Leak Tests / Torque Checks** | FUTURE | May be operation_template attributes or quality_spec extensions when activated |

### Spark Dependency Register

From the original Spark analysis:

| | Count | Notes |
|---|---|---|
| Total Section 3 requirements | 146 | |
| Directly Spark-coupled | 3 | Restated for Blue Ridge stack |
| Architectural platform gaps to design | 15 | Addressed by the 7-schema data model |
| Platform-agnostic requirements | ~138 | Implementable directly |
| Entire sections that are Spark-only | 4 | Section 5, Appendix G, J, K — reference only |

The requirements are implementable. The 7-schema data model addresses the 15 architectural platform gaps that SparkMES would have provided as built-ins.

---

---

## Session Notes — 2026-04-02

### What We Built This Session

1. **Read and digested all 22 FRS markdown documents** (Flexware v1.0 annotated by Blue Ridge)
2. **Designed a 7-schema, ~50-table data model** for the MES SQL backend:
   - `Location` — self-referential ISA-95 plant hierarchy with configurable attributes via `LocationTypeDefinition` + `LocationAttribute`
   - `Parts` — items, BOMs (versioned), routes (versioned), operation templates, container configs
   - `Lots` — LOT lifecycle, genealogy (adjacency list), movements, containers, serialized parts, shipping labels
   - `workorder` — auto-generated internal WOs, production events, consumption events, reject events
   - `quality` — spec-driven inspections (versioned), non-conformance, hold events (separate from NCM)
   - `Oee` — downtime events, reason codes, shift schedules, materialized OEE snapshots
   - `audit` — normalized log_event_type / log_entity_type code tables, three log types (operation, config, interface)
3. **Created three deliverables:**
   - `MPP_MES_ERD.html` — interactive ERD generated from the live `MPP_MES_Dev` schema by SchemaGen: one tab per schema plus cross-schema overview/focus tabs, stored-procedure and table-dependency graphs, table/column documentation read from SQL Server extended properties, pan/zoom, SVG export, dark/light/print themes
   - `MPP_MES_DATA_MODEL.md` — full column-level specification for every table (DDL-ready)
   - `MPP_MES_SUMMARY.md` — this document
4. **Read and analyzed all reference** (14 files — see findings below)

### Key Design Decisions Made

| Decision | Rationale |
|---|---|
| Self-referential `Location` instead of separate site/area/line/machine tables | One table, one hierarchy. Adding a Work Cell or Department level is data, not schema. |
| `LocationTypeDefinition` + `LocationAttribute` | Different machines/cells can have different KPI sets without schema changes. Spec-driven, not EAV. |
| Departments are a `LocationType`, not a separate table | They cross-cut physical boundaries — just another node in the hierarchy. |
| AD + Ignition roles, no custom RBAC tables | Authentication is AD's job. Roles are Ignition's job. MES stores `AppUser` for audit attribution only. |
| `LotOriginType` (MANUFACTURED, RECEIVED, RECEIVED_OFFSITE) | Distinguishes how LOTs entered MES without inspecting creation context. |
| `LotLabel` table | Tracks every LTT barcode print/reprint — initial, damaged, split/merge, Sort Cage. |
| Die/cavity on `Lot`, not on `ProductionEvent` | A LOT is one part from one die/cavity. Production events are batch counts — single cavity on a multi-cavity event doesn't make sense. |
| Separate `NonConformance` and `HoldEvent` | NCM can exist without hold (minor defects). Hold can exist without NCM (precautionary). Nullable FK between them. |
| Partial quality dispositions via LOT split | Split bad parts off, dispose separately, release remainder. Genealogy tracks the split permanently. |
| Normalized `LogEventType` and `LogEntityType` | Prevents free-text drift across Ignition scripts writing to audit tables. |
| Materialized OEE snapshots | OLTP/OLAP separation — computed per machine per shift by scheduled job, not live-queried from normalized tables. |

### Reference Document Findings

#### MPP_Scope_Matrix.xlsx — Project Scope Authority

This is the definitive in/out scope boundary. Critical for the FDS.

| Status | Items |
|---|---|
| **Included** | Plant model, Inventory/WIP, Lot Control, Inspections, Holds (expanded), Production Data Acquisition (expanded), Downtime, Produced Parts Tracking, Serialization (expanded), Part Replacement, Shipping Holds, AIM integration, PLC connections, Historization |
| **Included Conditionally** | Data Migration (80hr quote for MD + ProdDB), Work Orders, Sampling |
| **Not Included (designed for but not MVP)** | Scheduling, No-go part inventory tracking, Leak Tests, Torque Checks, NCM/Failure Analysis, OEE, KPIs, Raw Material Tracking, Maintenance WOs, ERP integration, SCADA integration, Quality (Intelex) integration, Process dashboards, Process reporting |
| **Future** | Scheduling, Leak Tests, Torque Checks, Pass-through tracking, Raw Material Tracking, ERP (Macola), Quality (Intelex), SCADA dashboards |

**Important:** OEE, NCM/Failure Analysis, and KPIs are **Not Included** in current scope. Our schema supports them (tables exist), but the FDS should mark them as future capability, not MVP deliverables.

#### Excel Prod Sheets.xlsx — Paper Production Sheet Templates

Templates for the paper forms currently used on the shop floor. These are what MES replaces. Three die cast variants (1-part, 4-part, 6-part) plus a Trim Shop sheet. Every field maps to our data model:

| Paper Field | Maps To |
|---|---|
| Part Name, Macola#, Die#, Machine#, Cavity | `Lot` + `Item` |
| Shots (total, good, warmup, no-good) | `ProductionEvent` |
| Rejects (QAS code, reason, amount) | `RejectEvent` |
| Downtime (reason, minutes) | `DowntimeEvent` |
| LOT Tag#, Cavity#, Qty | `Lot` |
| Shipping Label ID, Quantity, Auditor | `ShippingLabel` + `Container` |
| Runtime calculation | `Shift` + `OeeSnapshot` |

#### MS1FM-xxxx files (11 files) — Line-Specific Production Sheets

Tailored production sheets for specific lines: 5G0 Assembly, 5G0 Machining, RPY Cam Holder, 5BA R/S, 6B2 Assembly Sets, 59B/5PA Fuel Pump, 6MA Cam Holder, 6FB Cam Holder. These show the exact data entry fields per line — valuable for designing the Perspective UI screens and validating operation templates.

Key lines with **EDI shipping label tracking sheets** (up to 120 labels per sheet): MS1FM-1028 (Fuel Pump Inspection), MS1FM-1281 (6FB Assembly), MS1FM-0934 (RPY/5BA/6B2 Assembly Sets), MS1FM-0925 (5G0 Assembly).

#### 5GO_AP4 Automation Touchpoint Agreement — PLC Integration Spec

Defines the **exact handshake protocol** between assembly machines and MES via Machine Integration Panels (MIP). Two transaction patterns:

| Pattern | Lines | Serial Numbers | Key Touch Points |
|---|---|---|---|
| **Serialized (5GO)** | 5GO Assembly Fronts/Rears | Yes — laser etched, read via MIP | DataReady, PartSN, PartValid, ContainerCount |
| **LOT-tracked (PNA)** | PNA Assembly Out | No serial numbers | DataReady, PartValid, ContainerCount |

Touch points: `DataReady` (PLC→MES trigger), `TransInProc` (MES handshake), `PartSN` (serial number string), `PartValid` (MES validation result back to PLC), `HardwareInterlockEnable`, `MESInterlockEnable`, `WatchDog`, `ContainerCount`, `PartType`, `AlarmMsg`.

Container lifecycle is automated in this flow: MES creates containers, fills them part-by-part, closes and prints labels when full. Maps directly to our `Container` + `ContainerSerial` + `ShippingLabel` tables.

MES alarms identified: Low Inventory Level, Invalid PartSN, Duplicate PartSN.

---

## Session Notes — 2026-04-06

### What We Built This Session

1. **Completed FDS v0.1 working draft** (`MPP_MES_FDS.md`) — all 15 sections plus appendices, covering system architecture, plant model, master data, LOT lifecycle, production execution, container management, quality, downtime/OEE, audit, auth, integrations, reporting, data retention, and deployment
2. **Created User Journeys document** with two narrative arcs (die cast LOT creation through shipping, and pass-through receiving through assembly) and 19 validated assumptions
3. **Created Open Issues Register** (`MPP_MES_Open_Issues_Register.docx`) — Word document consolidating all open items (OI-01 through OI-10) requiring MPP input or design decisions

---

## Session Notes — 2026-04-09

### What We Built This Session

1. **Added FRS/FDS reference numbers to Open Issues Register** — Every OI and UJ item now has traceable references back to FRS sections, FDS requirements, Spark Dependencies, and supporting documents (Appendix C OPC tags, DCFM paper sheets, Touchpoint Agreement, etc.)
2. **Jacques reviewed all 29 open items and provided design decisions** — 4 resolved, 10 flagged for customer validation, 6 flagged for internal review with Ben, 9 remain open pending stakeholder input
3. **Propagated decisions across all 5 documents** — FDS, Data Model, User Journeys, Summary, and ERD updated with consistent status tags (✅ Resolved, 🔶 Pending Validation/Review, ⬜ Open)

### Key Decisions Made (2026-04-09)

| Decision | Status | Impact |
|---|---|---|
| External calls: direct + logging, no outbox (OI-01) | ✅ Resolved | Simplified architecture — removed outbox pattern from FDS §1.4, §1.6 |
| Shared terminals with machine barcode scan (OI-08/UJ-12) | ✅ Resolved | `Terminal` table eliminated, TERMINAL becomes `LocationType`, event tables carry `TerminalLocationId` + `LocationId` |
| Multi-part lines: one part at a time (OI-09/UJ-15) | ✅ Resolved | Operator selects LOT for consumption; no mixed-part containers |
| Off-site receiving: online, no concerns (UJ-06) | ✅ Resolved | Standard Perspective via VPN |
| WOs included but hidden, MVP-lite (OI-07) | 🔶 Pending Customer | Scope tag changed from CONDITIONAL to MVP-LITE |
| Vision conflict: auto-hold + supervisor override (OI-04) | 🔶 Pending Customer | New workflow added to FDS §10.3 |
| Initials-based operator identity; per-action AD elevation; no clock # or PIN (OI-06/UJ-01) | ✅ Resolved (2026-04-20) | FDS §4 rewritten end-to-end; `AppUser` gains `Initials` column, `AdAccount` made nullable; Config Tool User Management updated |
| Auto-split into 2 even sublots at machining (UJ-03) | 🔶 Pending Internal | FDS §5.4 rewritten |
| Warm-up shots as downtime sub-category (UJ-14) | 🔶 Pending Internal | `ShotCount` added to `DowntimeEvent` |
| Hardware interlock bypass flag (UJ-16) | 🔶 Pending Internal | Two placement options documented in data model |
| LOT creation: first scan creates record (UJ-02) | 🔶 Pending Customer | Confirms existing FDS-05-002 |
| Material verification: BOM check (UJ-09) | 🔶 Pending Customer | FDS-06-011 updated |

### Open Items Status Summary

As of 2026-04-22 the Open Issues Register is at v2.6 with 49 items total (30 Part A + 19 Part B). See `MPP_MES_Open_Issues_Register.md` for the authoritative status.

| Status | Count |
|---|---|
| ✅ Resolved | 9 (OI-01, OI-03, OI-06, OI-11; UJ-01, UJ-06, UJ-12, UJ-15, + partial-addenda closes) |
| 🔶 In Review | 9 (OI-02, OI-04, OI-05, OI-07, OI-08, OI-09, OI-12; UJ-02, UJ-03, UJ-14) |
| ⬜ Open | 30 (includes OI-13, OI-14, OI-15..OI-30, and 12 Part B UJ items) |
| Superseded | 1 (OI-10 rolled into Phase B Tools schema) |

> **Note (2026-04-22):** The 2026-04-20 MPP review and the 2026-04-22 legacy-MES screenshot review together reshaped Part A from 10 items to 30. Phase E closed OI-11..23 as *designed* — then a design review moved OI-11 fully to ✅ Resolved (no schema needed: Casting → Trim rename is a 1-line BOM consumption, not a new table). OI-24..30 (7 discovery items) remain parked for MPP input and will be brought to the next MPP review as a consolidated question set. Phase G SQL migration 0010 landed 2026-04-22 (Tools schema + 2 code tables + 3 Parts ALTERs; 779/779 tests still pass). The phased execution plan is in `memory/project_mpp_oi_refactor.md`.

---

## FDS Status

The Blue Ridge Automation **Functional Design Specification (FDS)** v0.2 working draft is **updated** as of 2026-04-09. The FDS covers all 15 sections plus appendices, with design decisions from the 2026-04-09 review session propagated inline.

- **Document:** `MPP_MES_FDS.md`
- **Open Items:** 3 of 10 OI items resolved; 4 pending customer validation; 1 pending internal review; 2 remain open. See `MPP_MES_Open_Issues_Register.docx` (v2.2) for full status with FRS references.

### Remaining Tasks

1. **Complete FDS appendices** — appendices are currently placeholder references; populate with machine lists, downtime codes, defect codes, OPC tags, and touch points
2. **Review additional images/flow documents** — Jacques mentioned more visuals available to reference
3. **Map scope matrix rows to FDS sections** — each row in the scope matrix becomes a traceable design item
4. **Map production sheet fields to FDS requirements** — each paper field becomes a data capture specification
5. **Incorporate touchpoint agreement flows** into the PLC integration section
6. **Validate data model against FDS** — ensure every design specification is supported by the schema
7. **Address conditional scope items** — Data Migration (80hr quote), Work Orders, Sampling need design decisions
8. **Identify FDS sections that need MPP input** — business rules for LOT merge, sub-lot sizes, container configs, shift patterns
9. **Strip `DieNumber`/`CavityNumber` off `ProductionEvent`** in the ERD HTML (done in data model doc, still in workorder ERD diagram — verify)
10. **Fix Master ERD rendering** — verify all 8 tabs render after duplicate entity-pair fixes
11. **Resolve 10 open items in the FDS Open Items Register (OI-01 through OI-10)**

---

## Related Documents

| Document | Purpose |
|---|---|
| `MPP_MES_ERD.html` | Interactive ERD generated from the live `MPP_MES_Dev` schema by SchemaGen — per-schema and cross-schema tabs, proc dependency graphs, DB-sourced documentation, pan/zoom |
| `MPP_MES_DATA_MODEL.md` | Detailed data model reference — all tables, columns, types, and relationships |
| `sql_best_practices_mes.md` | SQL design conventions and MES-specific patterns guiding the schema design |
| `mpp_frs_md/` | Annotated FRS source documents (Flexware v1.0, 22 files) |
| `mpp_frs_md/SPARK_DEPENDENCY_REGISTER.md` | Spark dependency analysis and Blue Ridge design decision register |
| `reference/MPP_Scope_Matrix.xlsx` | Project scope authority — in/out/conditional/future |
| `reference/Excel Prod Sheets.xlsx` | Paper production sheet templates (what MES replaces) |
| `reference/MS1FM-*.xlsx` (11 files) | Line-specific production sheets with defect codes and shipping label tracking |
| `reference/5GO_AP4_Automation_Touchpoint_Agreement.md` | Plc integration spec — touch points, handshake flows, MIP architecture |
| `MPP_MES_FDS.md` | Functional Design Specification v0.1 working draft — all 15 sections + appendices |
| `MPP_MES_Open_Issues_Register.docx` | Consolidated open items and design decisions requiring MPP input |
