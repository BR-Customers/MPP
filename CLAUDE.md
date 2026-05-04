# MPP MES Replacement Project

## Project Context

Blue Ridge Automation is building a replacement MES for **Madison Precision Products** (Honda Tier 2 die cast aluminum supplier, Madison IN). Replacing the legacy WPF/.NET "Manufacturing Director" MES with an **Ignition Perspective + SQL Server 2022** system.

**Client:** Madison Precision Products, Inc. (Madison, IN)
**Contractor:** Blue Ridge Automation
**Domain:** Aluminum die casting — LOT traceability from raw aluminum through shipping. Honda requires full genealogy for every part.

> **Current document versions, active blockers, recent change narrative, and the next-session briefing live in `PROJECT_STATUS.md`. Read it at session start.**

## Active Blockers

🚨 **OI-35 architecture gate** — long-horizon scaling, retention, and archiving strategy must resolve before Arc 2 Phase 1 SQL build (`0014_arc2_phase1_shop_floor_foundation.sql`) commences. Eight pending architectural decisions; items 2/4/5/7 must be in the CREATE migration. Detail in `PROJECT_STATUS.md`.

## Key Terminology

- **FDS** = Functional Design Specification — Blue Ridge's design document ("how we build it")
- **FRS** = Functional Requirement Specification — Flexware's document ("what it needs to do"). We did NOT write the FRS; we are implementing against it.
- **LOT** = A collection of parts tracked as a unit through the plant, identified by a barcoded LTT (LOT Tracking Ticket)
- **LTT** = LOT Tracking Ticket — physical barcoded label on baskets/containers
- **AIM** = Honda's EDI system for shipping IDs and hold notifications
- **MIP** = Machine Integration Panel — PLC-side handshake interface at assembly stations
- **PD / Productivity Database** = Legacy custom app for production/downtime data entry that MES replaces

## Document Map — Read Order for New Agents

Start here and work down. Each document builds on the previous. Current version numbers and dates are in `PROJECT_STATUS.md`.

| # | Document | What It Is | When to Read |
|---|---|---|---|
| 0 | `README.md` | Project map for humans (and Claude) — folder structure, regeneration workflow | First-time orientation |
| 1 | `MPP_MES_SUMMARY.md` | **Start here.** Master summary: project context, production flow, scope matrix (MVP/CONDITIONAL/FUTURE), data model overview, design decisions, reference doc findings | Always — this is the project index |
| 2 | `MPP_MES_DATA_MODEL.md` | Column-level specification for every table across the 8 schemas. DDL-ready. | When you need to understand or modify the schema |
| 3 | `MPP_MES_FDS.md` | Functional Design Specification — all 15 sections + appendices. Numbered requirements (FDS-XX-NNN), FRS crosswalk, scope tags. Has its own embedded Open Items Register at the bottom. Pre-release revision history lives in `MPP_MES_FDS_CHANGELOG.md`. | When working on design specifications or implementation |
| 4 | `MPP_MES_USER_JOURNEYS.md` | Two narrative arcs (Configuration Tool + Plant Floor "day in the life"). 19 validated assumptions/open decisions with an impact matrix. | When designing screens or understanding operator workflows |
| 5 | `MPP_MES_ERD.html` | Interactive ERD — one tab per schema + master tab, table descriptions, pan/zoom, dark theme | Visual reference for schema relationships |
| 6 | `MPP_MES_Open_Issues_Register.md` (source) + `.docx` (generated) | Sectioned per-OI register. Part A: FDS open items (`OI-XX`). Part B: user journey items (`UJ-XX`). Edit the markdown source only. | When resolving open items or preparing for MPP meetings |
| 7 | `MPP_MES_PHASED_PLAN_CONFIG_TOOL.md` | Phased development plan for the Configuration Tool (Arc 1) — 8 phases covering data model, Ignition Named Queries → stored proc layer, and Perspective frontend. Includes the Stored Procedure Template and Conventions section. | When planning Configuration Tool work or writing stored procedures |
| 7b | `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` | Phased development plan for the Plant Floor (Arc 2) — 9 phases (0–8). Phase 0 has parallel Customer Validation + Architecture Decision tracks. Cross-Cutting Concerns B1–B17 normative. | When planning Plant Floor work |
| 8 | `MPP_MES_TASK_LIST_CONFIG_TOOL.csv` | 100-task derivative of the Config Tool Phased Plan with estimates, dependencies, and status columns. Excel workbook at `MPP_MES_TASK_LIST_CONFIG_TOOL.xlsx`. | When tracking Configuration Tool execution |
| 9 | `sql_best_practices_mes.md` | SQL design conventions and MES-specific patterns. Pre-existing — authored by Jacques. Governs all schema design decisions. | When writing or reviewing SQL |
| 10 | `sql_version_control_guide.md` | SQL version control workflow: migrations, SchemaVersion tracking, dev iteration loop, reset scripts, seed data, deployment process. General-purpose top half + MPP-specific overlay. Companion to doc #9 — #9 covers *what SQL should look like*, #10 covers *how changes flow through environments*. | When writing migrations, setting up dev DBs, onboarding new engineers |
| 11 | `MPP_MES_SEEDING_REGISTRY.md` (source) + `.docx` (generated) | Single source of truth for seed data items sourced from outside Blue Ridge (MPP IT, Quality, Engineering, Honda, vendors). Status legend (Owed → Received → Loaded(Dev) → Verified(Cutover)), per-item detail. **Seed items are NOT design / SQL blockers** — they are deployment-time prerequisites collected in parallel with build. Internal code-table seeds baked into migrations are NOT tracked here. | When MPP delivers data, when assessing what's ready for cutover |

## Reference Material

| Location | Contents |
|---|---|
| `reference/MPP_FRS_Draft.pdf` | **Source FRS PDF** (Flexware v1.0, 6.7 MB). Use `pdftotext -table` for extracting tabular appendices. Page indexes: A=73-80, B=81-86, C=87-91, D=92-105, E=106-110, F=111-114, G=115-143. |
| `mpp_frs_md/` | 22 annotated FRS markdown files (older extract). Lower fidelity than `pdftotext -table` directly from PDF — prefer the PDF source for tabular content. |
| `mpp_frs_md/SPARK_DEPENDENCY_REGISTER.md` | Analysis of SparkMES dependencies and Blue Ridge design decisions for each |
| `reference/MPP_Scope_Matrix.xlsx` | **Scope authority** — the definitive in/out boundary. 37 rows: MVP, CONDITIONAL, FUTURE. |
| `reference/Excel Prod Sheets.xlsx` | Paper production sheet templates (what MES replaces) |
| `reference/MS1FM-*.xlsx` (11 files) | Line-specific production sheets with defect codes and shipping label tracking |
| `reference/5GO_AP4_Automation_Touchpoint_Agreement.pdf` | PLC integration spec — MIP touch points, handshake flows |
| `reference/Manufacturing_Director_Technical_Manual.md` | 2009 Flexware technical manual converted from PDF (converter at `reference/scripts/convert_mdtm_to_md.js`) |
| `reference/seed_data/` | **Seed data CSVs** extracted from FRS Appendices B/C/D/E. 876 rows total — machines (209), opc_tags (161), downtime_reason_codes (353), defect_codes (153). README + parse_warnings inside. |
| `reference/seed_data.xlsx` | Auto-generated Excel workbook with all 4 seed CSVs as sheets (filter/sort UI). Regenerate via `node reference/seed_data/build_seed_workbook.js`. |

## Architecture at a Glance

- **Platform:** Ignition Gateway (Perspective for UI, Tag Historian for time-series, Gateway Scripts for background processing)
- **Database:** SQL Server 2022 Standard Edition. **8 schemas:** `location`, `parts`, `lots`, `workorder`, `quality`, `oee`, `tools`, `audit`.
- **Auth:** Active Directory + Ignition roles. Initials-based attribution for shop-floor operators (no AD account); per-action AD elevation for protected actions. No custom RBAC tables.
- **PLC/OPC:** OmniServer (scales), TOPServer (assembly PLCs), Cognex (vision). MIP handshake for serialized lines.
- **External:** AIM (Honda EDI), Zebra printers via ZPL. Direct calls logged to `Audit.InterfaceLog`. Gateway-script-async dispatch (FDS-01-014).
- **Design patterns:** ISA-95 hierarchy with polymorphic three-tier location model (`LocationType` → `LocationTypeDefinition` → `LocationAttributeDefinition`), adjacency list genealogy, spec-driven quality, three-state versioning (Draft/Published/Deprecated) on BOMs/routes/operation templates/quality specs, append-only event tables, `DeprecatedAt` soft deletes, `BIGINT IDENTITY` surrogate `Id` PKs everywhere.

## Scope Boundaries

| Status | Count | Rule |
|---|---|---|
| **MVP / MVP-EXPANDED** | 17 | Build and deliver |
| **CONDITIONAL** | 5 | Build only if MPP approves (Work Orders, Data Migration, Sampling, SCADA Alarming) |
| **FUTURE** | 15 | Schema supports it, but do NOT implement, populate, or test. Tables may exist as placeholders. |

When in doubt about scope, check `reference/MPP_Scope_Matrix.xlsx` — it is the authority.

## Conventions

### SQL design

Follow `sql_best_practices_mes.md` and `sql_version_control_guide.md`:

- `UpperCamelCase` tables and columns
- `BIGINT IDENTITY` surrogate `Id` PKs everywhere; `BIGINT` for FKs
- `NVARCHAR` (never `VARCHAR`)
- `DATETIME2(3)` everywhere; `DECIMAL` not `FLOAT`
- All enum/status columns code-table backed with FK — no magic integers, no free-text
- User attribution via `BIGINT FK → AppUser.Id`
- Append-only events; `DeprecatedAt` soft deletes
- Versioned entities (BOM, RouteTemplate, OperationTemplate, QualitySpec) carry `VersionNumber` + `PublishedAt` + `DeprecatedAt`

### Stored procedure template

`sql/scripts/_TEMPLATE_stored_procedure.sql`. Three-tier error hierarchy. `RAISERROR` (not `THROW`) in CATCH blocks with nested TRY/CATCH for failure logging. Schema-qualify all DB references. `EXEC` parameters must be literals or `@variables` — never inline `CAST` / arithmetic / `CASE`.

### Ignition JDBC compatibility (FDS-11-011)

Stored procedures **SHALL NOT** use `OUTPUT` parameters — the Ignition JDBC driver reads them as the first result set and ignores subsequent SELECTs.

- **Read procs:** No OUTPUT params. Empty result set = not found (no invented 404).
- **Mutation procs:** `@Status`, `@Message`, `@NewId` are local variables. Every exit path ends with `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;` (drop `@NewId AS NewId` for Update / Deprecate).
- **Audit writers (`Audit.Audit_Log*`):** Emit no result set — they run inside mutation-proc transactions; emitting would break INSERT-EXEC + ROLLBACK.
- **One result set per proc.** If two were returned in legacy design, drop the second and use the sibling List proc.
- **Test pattern:** INSERT-EXEC into a temp table matching the SELECT shape, assert against the temp table.

### UI

No drag-and-drop anywhere — up/down arrow buttons for all sortable lists.

### FDS conventions

- Requirements numbered `FDS-XX-NNN` (section-sequence)
- RFC 2119 keywords: SHALL, SHALL NOT, SHOULD, MAY, FUTURE
- Every section + table tagged MVP, MVP-EXPANDED, CONDITIONAL, or FUTURE
- Upstream FRS crosswalk in parentheses, e.g., `(FRS 3.9.6)`

### Doc generation

All markdown docs have bordered + alternating-row styled Word versions. Regenerate via `pandoc <file>.md -o <file>.docx --reference-doc=reference.docx && node style_docx_tables.js <file>.docx`.

### Git commits

Omit `Co-Authored-By: Claude` trailer.
