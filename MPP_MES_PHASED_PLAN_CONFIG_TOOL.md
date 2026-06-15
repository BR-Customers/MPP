# MPP MES — Phased Development Plan: Configuration Tool

**Document:** MPP-MES-DEVPLAN-CONFIG-001
**Project:** Madison Precision Products MES Replacement
**Prepared By:** Blue Ridge Automation
**Version:** 1.8
**Date:** 2026-06-09

---

## Revision History

| Version | Date | Author | Change Summary |
|---|---|---|---|
| 1.8 | 2026-06-09 | Blue Ridge Automation | **Stored Procedure Template and Conventions reconciled to the live FDS-11-011 output standard.** The shipped procs already conform; this updates the stale documentation. Replaced the `@Status`/`@Message`/`@NewId` **OUTPUT-parameter** contract with the **status-row** pattern: status fields are local variables returned via a single `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId]` result set, emitted on *every* exit path (each validation/business-rule `RETURN`, the success path, and the CATCH). No `OUTPUT` parameters anywhere — the Ignition JDBC driver reads an OUTPUT param as the first result set and silently drops subsequent SELECTs. CATCH now ends with `RAISERROR(@ErrMsg, @ErrSev, @ErrState)` (THROW is not used in this project), after emitting the status row. Rewrote the **Read procs** variation: reads take no `@Status`/`@Message` params and return no status row — they SELECT their rowset directly and an empty result set means "not found". Updated The Contract, The Error Hierarchy, the Full Template (header doc comment + signature + body), and the Code-Review Checklist accordingly. Mirrors `sql/scripts/_TEMPLATE_stored_procedure.sql` v2.0 and the deployed `R__Location_Location_Create.sql`. |
| 0.1 | 2026-04-10 | Blue Ridge Automation | Initial phased plan covering 8 configuration tool phases. Each phase scopes data model, API layer (Named Queries → stored procedures), and Perspective frontend requirements. Conceptual — no SQL scripts produced. |
| 0.2 | 2026-04-10 | Blue Ridge Automation | Reformatted API Layer sections from bulleted lists to tables (Procedure / Parameters / Notes) for Word readability. Added explicit Seed Data tables to Phases 1, 7, and 8 with row counts and source CSVs. No content changes — purely a presentation pass. |
| 0.3 | 2026-04-10 | Blue Ridge Automation | Restructured the phase ordering: new Phase 1 is **Identity & Audit Foundation** (formerly Phase 2), and the old Phase 1 (Plant Model) is now Phase 2. Added 3 shared **audit infrastructure procedures** (`Audit.Audit_LogConfigChange`, `Audit.Audit_LogOperation`, `Audit.Audit_LogInterfaceCall`) that every CRUD proc in every later phase must call instead of writing audit entries inline. Documented the bootstrap admin user (`Id = 1`, inserted via migration script) to break the chicken-and-egg dependency. Added a **Dependencies** column to every API table across all 8 phases — shows which other procs and tables each procedure relies on, plus which mutating procs call `Audit.Audit_LogConfigChange`. Updated cross-cutting concerns to reflect the shared-audit-proc pattern. |
| 0.4 | 2026-04-10 | Blue Ridge Automation | Added **Executed When** and **Output** columns to every API table across all 8 phases. *Executed When* describes the user/system trigger that causes each proc to run (e.g., "Plant Hierarchy Browser expands a tree node", "Admin submits Add User modal", "Plant Floor production code looks up the active route for this LOT"). *Output* documents what each proc returns — rowset shape, scalar type, or rowcount — making the API contract explicit for the engineer building Named Queries. API tables now have 6 columns: Procedure / Parameters / Notes / Dependencies / Executed When / Output. |
| 0.6 | 2026-04-10 | Blue Ridge Automation | **Schema-qualified every table, stored procedure, and `table.column` reference in the document.** Every backtick-delimited DB reference now carries its SQL Server schema prefix: tables become `Location.Location`, `Parts.Item`, `Lots.Lot`, etc.; stored procedures become `Location.Location_Create`, `Parts.Item_Update`, `Audit.Audit_LogConfigChange`, etc.; column references become `Lots.Lot.CurrentLocationId` (schema.table.column). 633 references qualified across all 8 phases via a length-descending pass (longer entity names like `LocationTypeDefinition` processed before shorter ones like `Location` to avoid partial matches). Schemas involved: `Location`, `Parts`, `Lots`, `Workorder`, `Quality`, `Oee`, `Audit`. Prose references and non-DB backticked items (file names, SQL keywords, OPC tag names) were intentionally left alone. Removes all ambiguity for the engineer writing Named Queries and stored procs. |
| 0.5 | 2026-04-10 | Blue Ridge Automation | Major conventions update. Added a **Stored Procedure Template and Conventions** section with the standard output contract (`@Status BIT`, `@Message NVARCHAR(500)`, plus proc-specific outputs), the three-tier error hierarchy (parameter validation / business rule / unexpected exception), transaction boilerplate, audit call placement rules, a full template example with failure logging, a read-proc variation, and a code-review checklist. Introduced **`Audit.FailureLog`** as a fourth audit stream for rejected operations — every validation failure, business-rule rejection, and caught exception in any mutating proc writes here via the new shared **`Audit.Audit_LogFailure`** proc. Updated all four shared audit procs (`Audit.Audit_LogConfigChange`, `Audit.Audit_LogFailure`, `Audit.Audit_LogOperation`, `Audit.Audit_LogInterfaceCall`) to accept **code strings** (`'Location'`, `'Created'`, `'Info'`) instead of integer IDs, removing hard-coded constants from entity procs. Added FailureLog read procs (`Audit.FailureLog_List`, `Audit.FailureLog_GetByEntity`, `Audit.FailureLog_GetTopReasons`, `Audit.FailureLog_GetTopProcs`) and a **Failure Log Browser** frontend view to Phase 1. Updated Cross-Cutting Concern #1 to reflect the shared-proc pattern for both success and failure paths. |
| 0.7 | 2026-04-13 | Blue Ridge Automation | **Sibling sort-order pattern + no drag-and-drop.** Added `Location.Location_MoveUp` / `_MoveDown` procs to Phase 2; `Location.Location_Create` now auto-increments `SortOrder` among siblings; `Location.Location_Deprecate` compacts gaps. Same pattern applied to `Location.LocationAttributeDefinition` (Phase 2), `Parts.RouteStep` via `SequenceNumber` (Phase 5), `Parts.BomLine` (Phase 6), and `Quality.QualitySpecAttribute` (Phase 7). Removed `@SortOrder` / `@SequenceNumber` from all `_Create` / `_Add` and `_Update` parameter lists — ordering is managed exclusively via `_MoveUp` / `_MoveDown`. All `_Remove` / `_Deprecate` procs now compact sibling order on success. Replaced all drag-and-drop UI references with up/down arrow buttons across Plant Hierarchy Browser, Route Builder, BOM Editor, and Quality Spec Editor. |
| 0.8 | 2026-04-13 | Blue Ridge Automation | **Data type standardization.** All PK/FK parameters in the SP template, audit proc signatures, and code examples changed from `INT` to `BIGINT`. `@NewId INT OUTPUT` → `@NewId BIGINT OUTPUT`. `CAST(SCOPE_IDENTITY() AS INT)` → `CAST(SCOPE_IDENTITY() AS BIGINT)`. Read proc example (`Location.Location_Get`) `@Id` changed to `BIGINT`. Audit proc parameter table: `@EntityId INT` → `@EntityId BIGINT`. InterfaceCall proc: `VARCHAR(50)` / `VARCHAR(10)` → `NVARCHAR`. Cross-cutting concern #1 updated. Aligns with Data Model v0.6 (all PKs BIGINT, all VARCHAR → NVARCHAR). |
| 1.7 | 2026-04-21 | Blue Ridge Automation | **AppUser screens and procs realigned to the initials-based security model (OI-06 closed — Phase C of the 2026-04-20 OI review refactor).** Phase 1 User Management spec updated: `AppUser_GetByClockNumber` renamed to `AppUser_GetByInitials` (clock-number form is marked legacy, dropped in Phase G). `AppUser_Create` / `_Update` parameter lists updated — `@Initials` replaces `@ClockNumber`; `@AdAccount` and `@IgnitionRole` are now explicitly nullable to support Operator-class rows with no AD identity. `AppUser_SetPin` removed from the spec (legacy, dropped in Phase G). User Management Perspective view spec rewritten with a Class toggle (Operator / Interactive) on the Add User modal, no PIN field, no PIN Reset view. Config Tool authentication narrative clarifies that Config Tool users are always Interactive class, while the Admin screen maintains both classes. See FDS §4 and Data Model v1.6 AppUser for the canonical design. |
| 1.6 | 2026-04-15 | Blue Ridge Automation | **Phase 8 built and tested.** Migration `0009_phase8_oee_reference.sql` creates 4 Oee tables: `Oee.DowntimeReasonType` (seed-only, 6 fixed rows: Equipment/Miscellaneous/Mold/Quality/Setup/Unscheduled — read-only, no CRUD procs), `Oee.DowntimeReasonCode` (mutable with FKs to Area Location + nullable ReasonType + nullable SourceCode), `Oee.ShiftSchedule` (mutable with `DaysOfWeekBitmask INT` Mon=1…Sun=64 and CHECK 1-127), and `Oee.Shift` (runtime instances — Arc 2 writes, config tool only reads). 13 new stored procs: `DowntimeReasonType_List` (1), `DowntimeReasonCode_{List,Get,Create,Update,Deprecate,BulkLoadFromSeed}` (6), `ShiftSchedule_{List,Get,Create,Update,Deprecate}` (5), `Shift_List` (1). `BulkLoadFromSeed` accepts a JSON array + three area-location parameters (DC/MS/TS → AreaLocationId), generates `Code = DeptCode-NNNN` from zero-padded `ReasonId`, nulls out unmapped `TypeId`, rejects rows with unknown DeptCode or missing required fields, and returns `(Status, Message, InsertedCount, SkippedCount, RejectedCount, RejectedRowsJson)` — idempotent on re-run (existing Codes skipped). +1 `Audit.LogEntityType` row (ShiftSchedule at Id=30; DowntimeReasonCode was already seeded in bootstrap at Id=15). Dev seed updated with Trim Shop Area (Id=13, Code `TRIM`). 5 new test files in `sql/tests/0012_Oee_Reference/`, ~45 new assertions. Full suite now **779/779 passing** across 20 suites. Phase 8 remaining non-SQL work: run `BulkLoadFromSeed` against the 353-row `downtime_reason_codes.csv` once MPP confirms the production DC/MS/TS→Area mapping; backfill nullable `DowntimeReasonTypeId` for the ~25 CSV rows with missing TypeDesc. |
| 1.5 | 2026-04-15 | Blue Ridge Automation | **Production data collection capture — forward-reference to Arc 2.** Updated Phase 5 to note the downstream consumer contract: every `Parts.DataCollectionField` configured on an `Parts.OperationTemplate` via `Parts.OperationTemplateField` is captured at event time in Arc 2 by `Workorder.ProductionEvent` (hot typed columns for GoodCount/NoGoodCount/DieIdentifier/CavityNumber/WeightValue/WeightUomId) + a new `Workorder.ProductionEventValue` child (one row per non-hot field). No Arc 1 scope change — Phase 5 procs and the Operation Template Editor are already correct. Updated "Out of Scope" to flag the Arc 2 `ProductionEvent_Record` proc and `ProductionEventValue` table as the concrete runtime counterpart to the Arc 1 template configuration, so the Arc 2 plan picks up a defined contract. Data model v1.4 + FDS v0.7 carry the full schema + requirement detail. |
| 1.4 | 2026-04-14 | Blue Ridge Automation | **Phase 6 BOM + Phase 5 Draft/Published retrofit.** Migration `0007_bom_and_route_publish.sql` creates `Parts.Bom` + `Parts.BomLine` (both with the three-state lifecycle), and ALTERs `Parts.RouteTemplate` to add `PublishedAt` for consistency. New state model across Bom + RouteTemplate: Draft (editable, invisible to production) → Published (immutable, visible) → Deprecated. `_CreateNewVersion` always creates Drafts. `_Publish` proc is a one-way transition. `_GetActiveForItem` filters `PublishedAt IS NOT NULL`. Child mutations (BomLine / RouteStep procs) reject on published parents. 15 new procs plus 5 retrofit proc updates. `Audit.FailureLog_GetTopReasons` enhanced with optional `@ProcedureName` filter. Added `Bom_WhereUsedByChildItem` to close the frontend/API gap. BomLine self-reference check, one-active-config-per-Item via filtered unique. Test coverage +~100 assertions. Full suite 737/737. |
| 1.3 | 2026-04-14 | Blue Ridge Automation | **Phase 5 built and tested.** Migration `0006_routes_operations_eligibility.sql` creates 5 tables (OperationTemplate with VersionNumber added, OperationTemplateField, RouteTemplate versioned per Item, RouteStep no-soft-delete, ItemLocation with reactivation). 21 new stored procedures across all 5 entities. OperationTemplate uses clone-to-modify versioning (`_CreateNewVersion` duplicates the row + its OperationTemplateField junction rows, preserving historical RouteStep references). RouteTemplate uses time-range + VersionNumber selection via `_GetActiveForItem(@ItemId, @AsOfDate)`. RouteStep manages SequenceNumber via MoveUp/MoveDown + compaction on Remove (hard DELETE since RouteStep has no DeprecatedAt — deprecated parent routes are immutable). ItemLocation `_Add` is idempotent and reactivates a previously deprecated pairing. `_Remove` soft-deletes. 3 test files, ~145 assertions. 637/637 passing. |
| 1.2 | 2026-04-14 | Blue Ridge Automation | **Phase 4 built and tested.** Migration `0005_item_master_container_config.sql` creates `Parts.Item` (full user attribution — `CreatedAt`/`UpdatedAt`/`CreatedByUserId`/`UpdatedByUserId`) and `Parts.ContainerConfig` with OI-02 columns (`ClosureMethod`, `TargetWeight`) added proactively as nullable. 10 new stored procs: `Item_{List,Get,GetByPartNumber,Create,Update,Deprecate}` (6) + `ContainerConfig_{GetByItem,Create,Update,Deprecate}` (4). `PartNumber` and `ItemTypeId` are immutable after create — only way to change them is deprecate + recreate. `UnitWeight` / `WeightUomId` must be paired on Create/Update. Filtered unique index enforces one active ContainerConfig per Item. `Item_Deprecate` has `sys.tables`-guarded dependency checks on Bom, BomLine, RouteTemplate, ItemLocation, ContainerConfig. Bulk-load proc deferred until MPP provides parts-list export format. OI-02 columns noted in the header docs of `ContainerConfig_{GetByItem,Create,Update}` procs. 2 test files, ~80 assertions. Full suite 509/509. Also fixed `Parts.Uom_Deprecate` column reference (was `DefaultUomId`, corrected to `UomId OR WeightUomId` — the Phase 3 proc predated the actual Item schema and had a guessed column name). |
| 1.1 | 2026-04-13 | Blue Ridge Automation | **Phase 3 built and tested.** Migration `0004_phase3_reference_lookups.sql` creates all 16 code tables across 5 schemas with seeded reference data. 41 stored procedures deployed (26 read-only List/Get + 15 mutable CRUD following the `Parts.Uom` canonical template). 4 new test files across `0004_Lots_codes/`, `0005_Quality_codes/`, `0006_Oee_Workorder_codes/`, `0007_Parts_codes/` contributing 117 assertions. Full suite now 440/440 passing. Value decisions documented in Data Model v0.9: `WorkOrderStatus` seeded PascalCased (Created/InProgress/Completed/Cancelled) vs the stale UPPER_SNAKE in the data model; `Lots.LabelTypeCode` seeded with proposed values (Primary/Container/Master/Void) pending MPP shipping-staff validation. |
| 1.0 | 2026-04-13 | Blue Ridge Automation | **Icon column + tree support.** Added `Icon NVARCHAR(100) NULL` to `Location.LocationTypeDefinition` (migration `0003`) — values left NULL at deployment, to be populated via the Config Tool when the `LocationTypeDefinition` CRUD frontend lands. Updated Phase 2 data model table to note Icon column. Added `SortPath` column and depth-first ordering to `Location.Location_GetTree` for single-pass Perspective Tree assembly. Added `Icon` to result sets of `LocationTypeDefinition_List`, `LocationTypeDefinition_Get`, `Location_GetTree`, `Location_Get`, `Location_GetAncestors`, `Location_GetDescendantsOfType`. Added dev seed script (`sql/seeds/seed_locations.sql`) with 12 Location rows spanning all 5 ISA-95 tiers. |
| 0.9 | 2026-04-12 | Blue Ridge Automation | **Data model refactor propagation (4 changes).** (1) Added 8 code tables to Phase 3 replacing free-text enum columns: `Lots.PrintReasonCode`, `Lots.LabelTypeCode`, `Quality.InspectionResultCode`, `Quality.SampleTriggerCode`, `Quality.HoldTypeCode`, `Quality.DispositionCode`, `Oee.DowntimeSourceCode` (read-only pattern), and `Parts.DataCollectionField` (mutable pattern). Updated cross-cutting concern #5 to reflect. (2) Noted that `CreatedByUserId`/`PrintedByUserId` columns are set internally by procs from `@AppUserId` — no separate `@CreatedBy`/`@PrintedBy` params needed (Out of Scope note documents this for Arc 2). (3) `Quality.HoldEvent` retained as single table (place/release lifecycle, same pattern as `DowntimeEvent`) with `HoldTypeCodeId BIGINT FK` replacing free-text `HoldType` — documented in Out of Scope for Arc 2 Plant Floor plan. (4) Replaced `Parts.OperationTemplate` 7 BIT flag parameters with `Parts.DataCollectionField` + `Parts.OperationTemplateField` junction: removed `@CollectsDieInfo` etc. from `_Create`, added `Parts.OperationTemplateField` data model entry and 3 procs (`_ListByTemplate`, `_Add`, `_Remove`) to Phase 5, updated Operation Template Editor frontend. Updated `@SampleTrigger` → `@SampleTriggerCodeId` (FK to `Quality.SampleTriggerCode`) in `Quality.QualitySpecAttribute_Add` and `_Update`. Added new entity types to `Audit.LogEntityType` seed list (HoldEvent, DataCollectionField, OperationTemplateField). |

---

## Purpose

This document scopes the **Configuration Tool** half of the MES build (Arc 1 from `MPP_MES_USER_JOURNEYS.md`). The Configuration Tool is the engineering- and admin-facing application that engineers, supervisors, and IT staff use to set up the plant model, item master, BOMs, routes, quality specs, and reference codes **before any LOT moves on the shop floor**.

It is intentionally separated from the Plant Floor build (Arc 2). Per the open-issues analysis on 2026-04-10, **none of the 29 open issues are blocking on Configuration Tool decisions** — Arc 1 is unblocked and can proceed in parallel with Arc 2 customer/Ben validation work.

This document is **conceptual ideation**, not implementation:
- No SQL scripts are produced.
- Stored procedures are listed by name and signature, not implemented.
- Ignition Perspective screens are described in functional terms, not designed.
- Effort estimates are deliberately omitted — these will come during planning with the new collaborator.

---

## Architecture Pattern

### Ignition vs. .NET — what's different about the API layer

In a traditional .NET MES application, the API layer would be a REST/gRPC service exposing CRUD endpoints, with an ORM (Entity Framework, Dapper) talking to the database. Authentication would be middleware, audit logging would be cross-cutting filters, and the frontend (React, Angular, WPF) would consume JSON.

In the Ignition Perspective architecture, **the "API layer" is Ignition Named Queries**:

- Each CRUD operation is an Ignition **Named Query** defined in the Gateway.
- Each Named Query is a **parameterized call to a stored procedure** in SQL Server. We never embed inline SQL in Perspective views or Gateway scripts (parameterization is non-negotiable per the security guidance in `sql_best_practices_mes.md`).
- The stored procedure is where business logic, validation, soft-delete logic, and audit logging live. The procedure writes a row to `Audit.ConfigLog` for every mutation it performs.
- Perspective views invoke Named Queries via `system.db.runNamedQuery()` (Gateway scripts) or via the **Named Query Binding** on a Perspective component (UI-driven).
- Authentication for the Configuration Tool itself is handled by Ignition's built-in identity provider (AD + Ignition roles). Configuration Tool users are always **interactive users** (Engineering, Admin, etc., per FDS §4) — operators never use this tool. The currently authenticated user's `AppUserId` is read from the session and passed to every stored procedure for audit attribution. The Admin screens for `Location.AppUser` management also create and maintain **operator-class** rows (no AD account, initials-only, per FDS-04-010), so the Config Tool is the administrative home for both identity classes even though only interactive users log in.
- The `terminal_location_id` for Configuration Tool work is typically the engineering workstation's `Location.Location` record (Cell-tier, definition = `Terminal`, parented under a `SupportArea` or office area).

**Standard Named Query → Stored Procedure mapping:**

| Operation | Named Query name | Stored Procedure | Notes |
|---|---|---|---|
| List | `<Entity>.List` | `<Entity>_List` | Optional filter parameters; returns rows |
| Get one | `<Entity>.Get` | `<Entity>_Get` | Single row by Id |
| Create | `<Entity>.Create` | `<Entity>_Create` | Returns new Id; writes ConfigLog row |
| Update | `<Entity>.Update` | `<Entity>_Update` | Validates, writes ConfigLog row |
| Soft-delete | `<Entity>.Deprecate` | `<Entity>_Deprecate` | Sets `DeprecatedAt`; writes ConfigLog row |
| New version | `<Entity>.CreateNewVersion` | `<Entity>_CreateNewVersion` | For versioned entities (BOMs, routes, quality specs) |

**Stored procedure naming convention:** `<Entity>_<Action>` — no Microsoft `sp_` prefix (avoids name-resolution overhead reserved for system procs). Pascal-case matching the table names per the project naming convention.

> **Note on `sql_best_practices_mes.md`:** That doc still references `snake_case` and `deprecated_at` lowercase. It predates the 2026-04-09 naming convention change to UpperCamelCase. It needs a refresh pass before the new collaborator starts — schedule that as a follow-up task.

---

## Cross-Cutting Concerns (Apply to Every Phase)

These rules apply to every entity in every phase. The plan does not repeat them per phase.

1. **Audit attribution via shared procs.** Every Create/Update/Deprecate stored procedure takes `@AppUserId BIGINT` and calls one of the shared audit procs defined in Phase 1:
   - **On success:** call `Audit.Audit_LogConfigChange` to write a row to `Audit.ConfigLog` (inside the transaction — rolls back with the data if anything fails).
   - **On business-rule rejection:** call `Audit.Audit_LogFailure` to write a row to `Audit.FailureLog` with the reason, the procedure name, and a JSON snapshot of the input parameters. This creates an ongoing record of what operators and engineers are trying to do that isn't working — invaluable for UX improvement and root-cause analysis.
   - **On unexpected exception** (CATCH block): also call `Audit.Audit_LogFailure` — but *outside* the rolled-back transaction, then emit the status row and `RAISERROR(@ErrMsg, @ErrSev, @ErrState)` (THROW is not used in this project) to surface the exception to Ignition.

   The shared procs are the single source of truth for how audit entries are written — entity-specific procs never touch `Audit.ConfigLog` or `Audit.FailureLog` directly. A future change to the audit schema touches only the shared procs, not 100+ entity procs.
2. **Soft delete only.** Hard `DELETE` is forbidden for any table with downstream references. Use `DeprecatedAt` (set non-null to deactivate). Procedures should validate that an entity has no active dependents before deprecating.
3. **Versioning where applicable.** BOMs, route templates, quality specs, and operation templates all carry `VersionNumber` + `EffectiveFrom` + `DeprecatedAt`. Production records reference the version that was active at the time, not the latest.
4. **No reference loops.** Validate parent-child relationships server-side (e.g., a `Location.Location.ParentLocationId` cannot equal its own `Id`, and the chain cannot cycle).
5. **Code-table-backed status.** Any status, type, disposition, trigger, or result field is an FK to a code table, not a free-text column or magic integer. Seven new code tables (`Lots.PrintReasonCode`, `Lots.LabelTypeCode`, `Quality.InspectionResultCode`, `Quality.SampleTriggerCode`, `Quality.HoldTypeCode`, `Quality.DispositionCode`, `Oee.DowntimeSourceCode`) replace former free-text enum columns across the data model.
6. **Parameterized procedure calls.** Named Queries always use named parameters. No string concatenation, no dynamic SQL on the Perspective side.
7. **Optimistic locking** on Update procedures: pass `@RowVersion` (or `@UpdatedAt`) and the procedure rejects the update if it doesn't match. Prevents lost updates from concurrent edits.
8. **Server-side validation.** Validation lives in the stored procedure, not just the Perspective form. The frontend may pre-validate for UX, but the proc is the authority.
9. **`Location.AppUser` and audit infrastructure exist before any other phase.** Phase 1 establishes the bootstrap admin user (`Id = 1`, inserted via the migration script) and the shared audit procs. No CRUD work in Phases 2–8 can be written until Phase 1 is complete.
10. **Perspective permissions.** Each Configuration Tool screen is gated by an Ignition role (Engineering, Admin). Operators cannot reach Configuration screens — enforced at the Perspective view security level, not just hidden.

---

## Stored Procedure Template and Conventions

Every stored procedure written in this project — in the Configuration Tool, the Plant Floor build, and anywhere else — follows the same structural template. This section is the authoritative reference. When the new collaborator writes their first proc, they copy this template and fill in the blanks.

### The Contract

**No `OUTPUT` parameters anywhere (FDS-11-011).** The Ignition JDBC driver reads an `OUTPUT` parameter as the first result set and silently drops every `SELECT` after it — so a proc that returns status via `OUTPUT` params *and* a data rowset will lose the rowset. Instead, every mutation proc declares its status fields as **local variables** and returns them as a **single status-row result set** via a final `SELECT`.

Every **mutation** proc returns exactly one status-row result set:

| Result Column | Type | Purpose |
|---|---|---|
| `Status` | `BIT` | `1` on success, `0` on failure. |
| `Message` | `NVARCHAR(500)` | Human-readable status message. On success: a short confirmation. On failure: a user-friendly reason. |
| *(proc-specific)* | various | E.g., `NewId BIGINT` for Create/Add procs only. Drop it from Update/Deprecate/Publish procs. |

`@Status`, `@Message`, and (Create/Add) `@NewId` are **local variables** initialized to the failure defaults, never `OUTPUT` params. Every exit path — each validation/business-rule `RETURN`, the success path, and the CATCH — ends with `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId];`. `Status` is read by the caller to branch success/failure; `Message` is surfaced directly in the Perspective UI on error.

**Read procs** take NO `@Status` / `@Message` params and emit NO status row — they `SELECT` their data rowset directly. An empty result set means "not found" (do not invent a 404 status row). One result set per proc.

### The Error Hierarchy

Errors fall into three tiers. Each is handled differently:

| Tier | Example | Handling |
|---|---|---|
| **Parameter validation** | NULL where required, missing FK target, bad range | Set `@Status = 0`, set friendly `@Message`, call `Audit.Audit_LogFailure`, `RETURN`. **No transaction started.** No exception thrown. |
| **Business rule violation** | Duplicate code, deprecate-with-dependents, stale data, optimistic-lock mismatch | Same as above: `@Status = 0`, friendly `@Message`, call `Audit.Audit_LogFailure`, `RETURN`. No exception thrown. |
| **Unexpected exception** | Deadlock, trigger failure, constraint violation from corrupt data, NULL in unexpected place | Caught by CATCH: rollback if transaction open, set `@Status = 0`, capture `ERROR_MESSAGE()` in `@Message`, call `Audit.Audit_LogFailure` *outside the rolled-back transaction*, emit the status row, then **`RAISERROR(@ErrMsg, @ErrSev, @ErrState)`** (THROW is not used in this project) to surface the exception to Ignition. |

**Why the distinction?** Business-rule rejections are expected behavior — the UI needs to show them gracefully (e.g., "Cannot deprecate: active dependents exist"). Unexpected exceptions are bugs or infrastructure problems — the UI should show a generic error and Ignition's logs should capture the stack for debugging.

### Transaction Boilerplate

Every mutating proc starts with:

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
```

- `NOCOUNT ON` — suppresses the "x rows affected" messages (Ignition doesn't need them and they add overhead).
- `XACT_ABORT ON` — automatic rollback on runtime errors. Safety net for any error that escapes our TRY/CATCH (extremely rare, but cheap insurance).

Every mutation is wrapped in an explicit `BEGIN TRANSACTION` / `COMMIT TRANSACTION`, with the success audit call (`Audit.Audit_LogConfigChange`) **inside** the transaction so it rolls back atomically with the data on any failure.

The CATCH handler's `Audit.Audit_LogFailure` call is wrapped in its own nested `TRY/CATCH` so a failure in the failure-logger itself doesn't mask the original error.

### Audit Call Placement Rules

| Call | When | Placement |
|---|---|---|
| `Audit.Audit_LogConfigChange` | Mutation succeeded | **Inside** the transaction, just before `COMMIT`. Atomic with the data. |
| `Audit.Audit_LogFailure` (from validation path) | Parameter or business-rule failure | Before the `RETURN`. No transaction active, so it commits standalone. |
| `Audit.Audit_LogFailure` (from CATCH) | Caught exception | **After** `ROLLBACK`, wrapped in nested TRY/CATCH to prevent masking. |

### Full Template

```sql
-- =============================================
-- Procedure:   Location.Location_Create
-- Author:      <name>
-- Created:     2026-04-XX
-- Version:     1.0
--
-- Description:
--   Creates a new Location row under the specified parent. Validates
--   LocationTypeDefinition and parent existence. Enforces Code uniqueness.
--   Logs success to Audit.ConfigLog or failure to Audit.FailureLog.
--
-- Parameters (input):
--   @LocationTypeDefinitionId BIGINT   - FK to LocationTypeDefinition. Required.
--   @ParentLocationId BIGINT NULL      - FK to Location. NULL only for the Enterprise root.
--   @Name NVARCHAR(200)                - Display name. Required.
--   @Code NVARCHAR(50)                 - Short identifier. Required. Must be unique among active rows.
--   @Description NVARCHAR(500) NULL    - Optional description.
--   @AppUserId BIGINT                  - User performing the action. Required for audit attribution.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--   (No OUTPUT params — values are returned via SELECT per FDS-11-011.)
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationTypeDefinition
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Error Handling:
--   - Validation/business-rule failures: @Status=0, @Message set, Audit_LogFailure,
--     status-row SELECT, RETURN.
--   - CATCH handler: rollback, @Status=0, @Message captured, Audit_LogFailure,
--     status-row SELECT, RAISERROR.
--
-- Change Log:
--   2026-04-XX - 1.0 - Initial version
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_Create
    @LocationTypeDefinitionId BIGINT,
    @ParentLocationId          BIGINT         = NULL,
    @Name                      NVARCHAR(200),
    @Code                      NVARCHAR(50),
    @Description               NVARCHAR(500)  = NULL,
    @AppUserId                 BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Result variables (returned via SELECT instead of OUTPUT)
    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    -- Capture input for failure-log snapshots
    DECLARE @ProcName NVARCHAR(200) = N'Location.Location_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @LocationTypeDefinitionId AS LocationTypeDefinitionId,
                @ParentLocationId         AS ParentLocationId,
                @Name                     AS Name,
                @Code                     AS Code,
                @Description              AS Description
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @LocationTypeDefinitionId IS NULL OR @Name IS NULL OR @Code IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.LocationTypeDefinition
                       WHERE Id = @LocationTypeDefinitionId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated LocationTypeDefinitionId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location', @EntityId = NULL,
                @LogEventTypeCode = N'Created', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @ParentLocationId IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM Location.Location WHERE Id = @ParentLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated ParentLocationId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location', @EntityId = NULL,
                @LogEventTypeCode = N'Created', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Business rule checks
        -- ====================
        IF EXISTS (SELECT 1 FROM Location.Location WHERE Code = @Code AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'A location with this Code already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location', @EntityId = NULL,
                @LogEventTypeCode = N'Created', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        INSERT INTO Location.Location
            (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, CreatedAt)
        VALUES
            (@LocationTypeDefinitionId, @ParentLocationId, @Name, @Code, @Description, GETUTCDATE());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- Success audit INSIDE the transaction — rolls back atomically with the data
        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Location',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = N'Location created: ' + @Name + N' (' + @Code + N')',
            @OldValue          = NULL,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Location created successfully.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        -- Capture error details BEFORE the nested TRY/CATCH clears the error context
        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId   = NULL;

        -- Failure log OUTSIDE the rolled-back transaction
        -- Wrap in nested TRY/CATCH so a log-write failure doesn't mask the real error
        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow; we're already in a bad state and shouldn't mask the original exception
        END CATCH

        -- Emit the status row, then re-raise so Ignition logs it as a critical exception
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
```

> The deployed `R__Location_Location_Create.sql` (v2.x) additionally emits a human-readable `Audit.ConfigLog.Description` narrative and resolved-FK `OldValue`/`NewValue` JSON. See `sql_best_practices_mes.md` § Audit Log Description Convention. The template above keeps the audit payload minimal to keep the focus on the OUTPUT-contract + error mechanics.

### Variations

**Read procs** — no transaction, no success audit, and **no `@Status` / `@Message` params or status row**. A read proc simply `SELECT`s its data rowset; an **empty result set means "not found"** (do not invent a 404 status row). One result set per proc.

```sql
CREATE OR ALTER PROCEDURE Location.Location_Get
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT l.Id, l.LocationTypeDefinitionId, l.ParentLocationId, l.Name, l.Code, l.Description
    FROM Location.Location l
    WHERE l.Id = @Id AND l.DeprecatedAt IS NULL;
END
GO
```

**Note on read failure logging:** Reads return only their data rowset; there is no status row to populate, and parameter-validation failures on reads generally should *not* be written to `Audit.FailureLog` — it creates too much noise from minor UI bugs and typo queries. An empty result set is the canonical "not found" signal. (Override at the author's discretion only if a specific read proc has valuable failure signal — but never add `@Status`/`@Message` OUTPUT params.)

**Update/Deprecate procs** follow the same structure as Create, with these differences:
- Additional pre-transaction check: the target row must exist and not be deprecated
- Capture `@OldValue` from the current row state before mutating (for the audit entry)
- For Deprecate: check for active dependents in referencing tables before proceeding
- Use optimistic locking (`@RowVersion` or `@UpdatedAt` parameter) on Updates to prevent lost updates

### Checklist for Code Review

When reviewing a new stored procedure, the reviewer should confirm:

- [ ] Header comment block is filled in (author, created, version, description, all parameters documented)
- [ ] `SET NOCOUNT ON` and `SET XACT_ABORT ON` at the top
- [ ] No `OUTPUT` parameters (FDS-11-011) — the Ignition JDBC driver drops SELECTs after an OUTPUT param
- [ ] `@Status` / `@Message` [/ `@NewId` for Create/Add] declared as locals + initialized to failure defaults at the top
- [ ] Every exit path (each validation `RETURN`, success, CATCH) emits the status-row `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId]`
- [ ] `@ProcName` and `@Params` locals captured once, reused in every audit call
- [ ] Parameter validation runs BEFORE `BEGIN TRANSACTION`
- [ ] Business rule checks run BEFORE `BEGIN TRANSACTION`
- [ ] Every validation failure path: sets `@Message`, calls `Audit.Audit_LogFailure`, `RETURN`s
- [ ] The mutation is wrapped in `BEGIN TRANSACTION` / `COMMIT TRANSACTION`
- [ ] `Audit.Audit_LogConfigChange` is called INSIDE the transaction, before `COMMIT`
- [ ] CATCH handler: `ROLLBACK` if `@@TRANCOUNT > 0`, set error output, nested-TRY `Audit.Audit_LogFailure`, status-row `SELECT`, `RAISERROR(@ErrMsg, @ErrSev, @ErrState)`
- [ ] `@Status = 1` and friendly `@Message` set only on the success path
- [ ] Every `EXEC Audit_LogFailure` uses named parameters (not positional) — clarity over brevity
- [ ] `@FailureReason` passed to `Audit.Audit_LogFailure` matches the `@Message` returned to the caller (consistency)

---

## Phase Map and Dependencies

```
Phase 1 (Identity & Audit Foundation — AppUser, Audit infrastructure procs)
  └──→ Phase 2 (Plant Model & Location Schema)
        └──→ Phase 3 (Reference Lookups)
              ├──→ Phase 4 (Item Master & Container Config)
              │     ├──→ Phase 5 (Process Definition: Routes & Operations)
              │     │     └──→ Phase 6 (BOM Management)
              │     └──→ Phase 7 (Quality Configuration)
              └──→ Phase 8 (Operations Reference Data: Downtime, Shifts, OPC)
```

Phases 1, 2, and 3 are **foundation** and must run in order. **Phase 1 is the new bedrock** — the audit infrastructure procs (`Audit.Audit_LogConfigChange` etc.) must exist before any other CRUD proc can be written, since every Create/Update/Deprecate proc in every later phase calls them. Phases 4–8 can be parallelized once 1–3 are done; the only hard dependency among them is Phase 6 (BOMs) needing Phase 4 (Items).

**Bootstrap problem solved:** The very first `Location.AppUser` row (a system/admin account, `Id = 1`) is inserted directly via the deployment migration script — not via `Location.AppUser_Create` — to break the chicken-and-egg dependency on `@AppUserId` for audit attribution. All subsequent admin accounts are created by this bootstrap user.

---

## Phase 1 — Identity & Audit Foundation

**Goal:** Establish the audit log infrastructure and the `Location.AppUser` table. Every other phase calls into this — every Create/Update/Deprecate proc anywhere in the system invokes one of the shared audit procs defined here. Without this phase, no other CRUD work can be written.

**Dependencies:** None. This is the bedrock.

**Status:** Unblocked. **Must be the first thing built.**

### Bootstrap Note

The very first `Location.AppUser` row (a system/admin account) is inserted directly via the deployment migration script — not via `Location.AppUser_Create` — to break the chicken-and-egg dependency on `@AppUserId` for audit attribution. By convention, this row has `Id = 1`, `AdAccount = 'system.bootstrap'`, and `IgnitionRole = 'Admin'`. All subsequent admin accounts are created by this bootstrap user.

The audit lookup tables (`Audit.LogSeverity`, `Audit.LogEventType`, `Audit.LogEntityType`) are also seeded by the migration script, since the audit infrastructure procs need them to exist before they can write any rows.

### Data Model

| Table | Role |
|---|---|
| `Location.AppUser` | One row per MES user. Two identity classes (FDS §4): Interactive users (Quality/Supervisor/Engineering/Admin) backed by AD accounts; Operator users with initials only (no AD, no PIN). All classes carry `Initials` and stamp events via `AppUserId`. Referenced for audit attribution everywhere. |
| `Audit.LogSeverity` | Code table: Info, Warning, Error, Critical. Seeded. |
| `Audit.LogEventType` | Code table: Created, Updated, Deprecated, LotCreated, LotMoved, ProductionRecorded, etc. Seeded with the initial set, extensible. |
| `Audit.LogEntityType` | Code table: Location, Item, Lot, BOM, AppUser, HoldEvent, DataCollectionField, OperationTemplateField, etc. Seeded from the entity table list. |
| `Audit.ConfigLog` | Destination for **successful** Configuration Tool mutations. Every config mutation writes here via `Audit.Audit_LogConfigChange` (inside the transaction, atomic with the data). |
| `Audit.OperationLog` | Destination for plant-floor mutations (used by Arc 2, but the proc lives here). Every shop-floor action writes via `Audit.Audit_LogOperation`. |
| `Audit.InterfaceLog` | Destination for external system calls (AIM, Zebra, Macola, etc.). Every external call writes via `Audit.Audit_LogInterfaceCall`. |
| `Audit.FailureLog` | Destination for **attempted but rejected** operations — parameter failures, business-rule violations, caught exceptions. Every mutating proc writes here via `Audit.Audit_LogFailure` on any failure path. Tracked separately from `Audit.ConfigLog` because the query pattern is different ("top rejection reasons this week," "which procs fail most") and the writes happen outside the rolled-back transaction. |

### Audit Infrastructure Procedures

These are the **shared audit procs** that every other CRUD proc in the system calls. They are the single source of truth for how audit entries are written. If the audit schema changes, these are the only procs that change — everything else just keeps calling them.

All four procs accept **code strings** (`@LogEntityTypeCode`, `@LogEventTypeCode`, `@LogSeverityCode`) rather than IDs. Each proc resolves the codes to IDs internally via the seeded lookup tables. This keeps caller code self-documenting — entity procs write `N'Location', N'Created', N'Info'` instead of hard-coded integers or inline subqueries.

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Audit.Audit_LogConfigChange` | `@AppUserId, @LogEntityTypeCode NVARCHAR(50), @EntityId INT, @LogEventTypeCode NVARCHAR(50), @LogSeverityCode NVARCHAR(20) = 'Info', @Description NVARCHAR(500), @OldValue NVARCHAR(MAX) NULL, @NewValue NVARCHAR(MAX) NULL` | Writes one row to `Audit.ConfigLog` for a **successful** mutation. **Called by every Create/Update/Deprecate proc in every Configuration Tool phase — inside the transaction, atomic with the data.** | `Audit.ConfigLog`, `Audit.LogEntityType`, `Audit.LogEventType`, `Audit.LogSeverity`, `Location.AppUser` | Inside a Configuration Tool mutation proc, right before `COMMIT TRANSACTION` | Scalar: new `Audit.ConfigLog.Id` (BIGINT). Typically ignored by callers. |
| `Audit.Audit_LogFailure` | `@AppUserId, @LogEntityTypeCode NVARCHAR(50), @EntityId INT NULL, @LogEventTypeCode NVARCHAR(50), @FailureReason NVARCHAR(500), @ProcedureName NVARCHAR(200), @AttemptedParameters NVARCHAR(MAX) NULL` | Writes one row to `Audit.FailureLog` for an **attempted but rejected** operation. **Called by every validation-failure path and every CATCH handler in every mutating proc.** | `Audit.FailureLog`, `Audit.LogEntityType`, `Audit.LogEventType`, `Location.AppUser` | From validation failure paths (before `RETURN`) and from CATCH handlers (after `ROLLBACK`, wrapped in nested TRY/CATCH) | Scalar: new `Audit.FailureLog.Id` (BIGINT). Typically ignored by callers. |
| `Audit.Audit_LogOperation` | `@AppUserId, @TerminalLocationId, @LocationId, @LogEntityTypeCode NVARCHAR(50), @EntityId INT, @LogEventTypeCode NVARCHAR(50), @LogSeverityCode NVARCHAR(20) = 'Info', @Description NVARCHAR(500), @OldValue NVARCHAR(MAX) NULL, @NewValue NVARCHAR(MAX) NULL` | Writes one row to `Audit.OperationLog` for a **successful** plant-floor mutation. Called by every Arc 2 build mutation (LOT creation, movement, production recording, holds, etc.). **Defined here, used in the Plant Floor phased plan.** | `Audit.OperationLog`, `Location.Location`, `Location.AppUser`, audit lookups | Inside any Plant Floor mutation proc (Arc 2), right before `COMMIT TRANSACTION` | Scalar: new `Audit.OperationLog.Id` (BIGINT). Typically ignored by callers. |
| `Audit.Audit_LogInterfaceCall` | `@SystemName NVARCHAR(50), @Direction NVARCHAR(10), @LogEventTypeCode NVARCHAR(50), @Description NVARCHAR(500), @RequestPayload NVARCHAR(MAX) NULL, @ResponsePayload NVARCHAR(MAX) NULL, @ErrorCondition NVARCHAR(200) NULL, @IsHighFidelity BIT = 0` | Writes one row to `Audit.InterfaceLog`. Called by every AIM, Zebra, Macola, or Intelex call. Per FRS 3.17.4, `@IsHighFidelity` controls whether the full request/response payloads are stored or just the metadata. | `Audit.InterfaceLog`, audit lookups | Inside any external-system call wrapper (before and/or after the HTTP/API request) | Scalar: new `Audit.InterfaceLog.Id` (BIGINT). Typically ignored by callers. |

### API Layer (Named Queries → Stored Procedures)

**`Location.AppUser`** (full CRUD + lookup variants):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Location.AppUser_List` | `@IncludeDeprecated BIT = 0` | Active users by default | `Location.AppUser` | User Management screen loads | Rowset: `Location.AppUser` rows |
| `Location.AppUser_Get` | `@Id` | | `Location.AppUser` | Edit User modal opens | Rowset (0-1): one `Location.AppUser` row |
| `Location.AppUser_GetByAdAccount` | `@AdAccount` | Session resolution at AD login for interactive users | `Location.AppUser` | User opens a Perspective session and Ignition resolves their AD identity | Rowset (0-1): one `Location.AppUser` row |
| `Location.AppUser_GetByInitials` | `@Initials` | Shop-floor stamp lookup — resolves initials to an `AppUserId` on every mutation screen | `Location.AppUser` | Operator enters/confirms initials on a shop-floor terminal (Arc 2 usage) | Rowset (0-1): one `Location.AppUser` row |
| `Location.AppUser_Create` | `@AdAccount NVARCHAR(100) NULL, @DisplayName, @Initials, @IgnitionRole NVARCHAR(100) NULL, @AppUserId` | `@AppUserId` is the admin creating the row. Operator rows pass `@AdAccount = NULL` and `@IgnitionRole = NULL`; interactive rows supply both. | `Location.AppUser`, calls `Audit.Audit_LogConfigChange` | Admin submits Add User modal | Scalar: new `Location.AppUser.Id` (BIGINT) |
| `Location.AppUser_Update` | `@Id, @DisplayName, @Initials, @IgnitionRole NVARCHAR(100) NULL, @AppUserId` | AdAccount is not editable after creation (tie-break between classes) | `Location.AppUser`, calls `Audit.Audit_LogConfigChange` | Admin saves Edit User form | Rowcount (0 on optimistic-lock mismatch) |
| `Location.AppUser_Deprecate` | `@Id, @AppUserId` | Rejects if active records reference this user as creator | `Location.AppUser`, calls `Audit.Audit_LogConfigChange` | Admin clicks Deprecate on a user row | Rowcount (0 if rejected due to active dependents) |

> **Legacy procs (deferred removal in Phase G):** The Phase 1–8 live schema still carries `ClockNumber` and `PinHash` columns on `Location.AppUser` and still exposes `AppUser_GetByClockNumber` and `AppUser_SetPin`. The design as of 2026-04-21 no longer uses them — they will be dropped in the Phase G Tool & Security migration alongside the columns. New UI work SHALL use `AppUser_GetByInitials` exclusively.

**Audit lookup tables** (read-only after seeding):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Audit.LogSeverity_List` | — | Info, Warning, Error, Critical | `Audit.LogSeverity` | Audit Log Browser filter dropdown loads | Rowset: `Audit.LogSeverity` rows |
| `Audit.LogEventType_List` | — | ConfigChanged, LotCreated, LotMoved, ProductionRecorded, etc. | `Audit.LogEventType` | Audit Log Browser filter dropdown loads | Rowset: `Audit.LogEventType` rows |
| `Audit.LogEntityType_List` | — | Location, Item, Lot, BOM, AppUser, etc. | `Audit.LogEntityType` | Audit Log Browser filter dropdown loads | Rowset: `Audit.LogEntityType` rows |

**`Audit.ConfigLog`** (read-only from the Configuration Tool — written only by `Audit.Audit_LogConfigChange`):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Audit.ConfigLog_List` | `@StartDate, @EndDate, @LogEntityTypeCode NVARCHAR(50) NULL, @AppUserId NULL` | Paged, filterable | `Audit.ConfigLog`, `Location.AppUser`, `Audit.LogEntityType` | Audit Log Browser loads or user changes filters | Rowset: `Audit.ConfigLog` rows joined to `Location.AppUser.DisplayName` and `Audit.LogEntityType.Name` |
| `Audit.ConfigLog_GetByEntity` | `@LogEntityTypeCode NVARCHAR(50), @EntityId BIGINT` | "Show me everything ever changed about this Item / Location / BOM" | `Audit.ConfigLog` | User clicks "View Audit History" on any Configuration Tool screen | Rowset: `Audit.ConfigLog` rows for one entity, ordered newest first |

**`Audit.FailureLog`** (read-only from the Configuration Tool — written only by `Audit.Audit_LogFailure`):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Audit.FailureLog_List` | `@StartDate, @EndDate, @LogEntityTypeCode NVARCHAR(50) NULL, @AppUserId NULL, @ProcedureName NVARCHAR(200) NULL` | Paged, filterable by entity/user/proc | `Audit.FailureLog`, `Location.AppUser`, `Audit.LogEntityType` | Failure Log Browser loads or user changes filters | Rowset: `Audit.FailureLog` rows joined to `Location.AppUser.DisplayName` and `Audit.LogEntityType.Name` |
| `Audit.FailureLog_GetByEntity` | `@LogEntityTypeCode NVARCHAR(50), @EntityId BIGINT` | "Show me every rejected attempt to modify this specific entity" | `Audit.FailureLog` | User clicks "View Rejection History" on any Configuration Tool screen | Rowset: `Audit.FailureLog` rows for one entity, ordered newest first |
| `Audit.FailureLog_GetTopReasons` | `@StartDate, @EndDate, @LogEntityTypeCode NVARCHAR(50) NULL` | Aggregation: group by `FailureReason` and count. Answers "what are the top rejection reasons this week?" | `Audit.FailureLog` | Failure Log Browser's "Top Reasons" dashboard tile loads | Rowset: `FailureReason`, `Count`, ordered by count DESC |
| `Audit.FailureLog_GetTopProcs` | `@StartDate, @EndDate` | Aggregation: group by `ProcedureName` and count. Answers "which procs are failing the most?" | `Audit.FailureLog` | Failure Log Browser's "Top Procs" dashboard tile loads | Rowset: `ProcedureName`, `Count`, ordered by count DESC |

### Frontend (Perspective Views)

| View | Purpose |
|---|---|
| **User Management** | Admin-only. List of `Location.AppUser` rows with filter (active/deprecated) and class indicator (Operator vs Interactive). Add User modal: **Class** toggle (Operator / Interactive). For Operator class: Initials, Display Name. For Interactive class: AD Account, Initials, Display Name, Ignition Role. Edit User modal: same fields (class not editable post-creation) plus "Deprecate" action. No PIN field — PINs have been retired from the design as of FDS v0.8. |
| **Audit Log Browser** | Admin-only. Filterable view of `Audit.ConfigLog` (successful changes) with filters for entity type, user, date range. Click a row to expand and see the old/new values diff. Deep-linkable from every other Config Tool screen ("View audit history for this Item"). |
| **Failure Log Browser** | Admin-only. Filterable view of `Audit.FailureLog` (rejected attempts) with filters for entity type, user, procedure name, date range. Includes dashboard tiles for "Top Rejection Reasons" and "Top Failing Procedures" over a configurable time window. Click a row to see the JSON snapshot of the attempted parameters. Deep-linkable from every other Config Tool screen ("View rejection history for this Item"). Primary audience: Blue Ridge and MPP engineering doing root-cause analysis on repeated failures. |

### Phase 1 complete when

- The bootstrap `Location.AppUser` row exists (`Id = 1`, system account)
- The audit lookup tables are seeded (severity, event types, entity types)
- The 4 audit infrastructure procs (`Audit.Audit_LogConfigChange`, `Audit.Audit_LogFailure`, `Audit.Audit_LogOperation`, `Audit.Audit_LogInterfaceCall`) are deployed and tested, using the code-string signatures
- `Audit.FailureLog` table exists with its indexes
- The full `Location.AppUser` CRUD is wired through Named Queries — and every mutating proc calls `Audit.Audit_LogConfigChange` on success and `Audit.Audit_LogFailure` on every validation/business-rule/exception path
- Admin can create a real engineering admin user via the User Management screen
- Admin can browse the success audit log via the Audit Log Browser
- Admin can browse the failure log via the Failure Log Browser, including the Top Reasons and Top Procs dashboard tiles
- Every later phase's CRUD proc template **must** follow the Stored Procedure Template above — success via `Audit.Audit_LogConfigChange`, every failure path via `Audit.Audit_LogFailure`

---

## Phase 2 — Plant Model & Location Schema

**Goal:** Stand up the three-tier polymorphic location model and load the seed machine list. Without this, nothing else can be physically configured.

**Dependencies:** Phase 1 (audit infrastructure procs and at least one `Location.AppUser` for `@AppUserId` attribution).

**Status:** Unblocked once Phase 1 is complete.

### Data Model

Tables involved (all from the `Location.Location` schema, per `MPP_MES_DATA_MODEL.md` §1):

| Table | Role |
|---|---|
| `Location.LocationType` | The 5 ISA-95 tiers (Enterprise, Site, Area, WorkCenter, Cell). Seeded at deployment, read-only thereafter. |
| `Location.LocationTypeDefinition` | Polymorphic kinds within a tier (Terminal, DieCastMachine, CNCMachine, ProductionArea, etc.). Seeded with initial set, extensible by Engineering role. Carries an `Icon` column (Perspective icon path, e.g., `material/precision_manufacturing`) used by the Plant Hierarchy Browser tree. |
| `Location.LocationAttributeDefinition` | Per-kind attribute schema (e.g., `Tonnage` for `DieCastMachine`, `IpAddress` for `Terminal`). |
| `Location.Location` | Instances. Self-referential via `ParentLocationId`. Every row references one `Location.LocationTypeDefinition`. |
| `Location.LocationAttribute` | Attribute values per location. FK enforces that the attribute definition belongs to the location's own definition. |

**Seed data to load:**

| Table | Source | Rows | Notes |
|---|---|---|---|
| `Location.LocationType` | hard-coded | 5 | Enterprise, Site, Area, WorkCenter, Cell |
| `Location.LocationTypeDefinition` | hard-coded | ~15 | Organization, Facility, ProductionArea, SupportArea, ProductionLine, InspectionLine, Terminal, DieCastMachine, CNCMachine, TrimPress, AssemblyStation, SerializedAssemblyLine, InspectionStation, InventoryLocation, Scale |
| `Location.LocationAttributeDefinition` | hard-coded | ~20 | Per definition: Tonnage, NumberOfCavities, RefCycleTimeSec on `DieCastMachine`; IpAddress, DefaultPrinter, HasBarcodeScanner on `Terminal`; etc. |
| `Location.Location` (Enterprise) | hard-coded | 1 | Madison Precision Products, Inc. |
| `Location.Location` (Site) | hard-coded | 1 | Madison facility |
| `Location.Location` (Area) | hard-coded | 5 | Die Cast, Trim Shop, Machine Shop, Production Control, Quality Control |
| `Location.Location` (Cell) | `reference/seed_data/machines.csv` | 209 | Machines mapped to Cell-tier definitions by process (DieCast# → `DieCastMachine`, MS Machine → `CNCMachine`, etc.) |
| `Location.LocationAttribute` | from `machines.csv` columns | ~600 | Tonnage, RefCycleTimeSec, NumberOfCavities per Cell where present |

### API Layer (Named Queries → Stored Procedures)

**`Location.LocationType`** (read-only — seeded at deployment):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Location.LocationType_List` | — | Returns all 5 tiers | `Location.LocationType` | Engineering opens a form that needs a tier dropdown (e.g., creating a new LocationTypeDefinition) | Rowset: 5 `Location.LocationType` rows |
| `Location.LocationType_Get` | `@Id` | Single tier | `Location.LocationType` | Rarely called directly; mostly used via joins from other procs | Rowset (0-1): one `Location.LocationType` row |

**`Location.LocationTypeDefinition`** (full CRUD):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Location.LocationTypeDefinition_List` | `@LocationTypeId NULL` | Optional filter by tier | `Location.LocationTypeDefinition`, `Location.LocationType` | Location Type Definition Editor loads; Add Location modal populates its kind dropdown | Rowset: `Location.LocationTypeDefinition` rows with tier name |
| `Location.LocationTypeDefinition_Get` | `@Id` | | `Location.LocationTypeDefinition` | Engineering opens a definition for editing | Rowset (0-1): one definition row |
| `Location.LocationTypeDefinition_Create` | `@LocationTypeId, @Code, @Name, @Description, @AppUserId` | Returns new `Id` | `Location.LocationType` (FK), calls `Audit.Audit_LogConfigChange` | Engineering submits "New Definition" in the Editor | Scalar: new `Location.LocationTypeDefinition.Id` (INT) |
| `Location.LocationTypeDefinition_Update` | `@Id, @Name, @Description, @AppUserId` | `LocationTypeId` is immutable after create | calls `Audit.Audit_LogConfigChange` | Engineering saves changes to a definition | Rowcount |
| `Location.LocationTypeDefinition_Deprecate` | `@Id, @AppUserId` | Rejects if any active `Location.Location` references it | reads `Location.Location`, calls `Audit.Audit_LogConfigChange` | Engineering clicks Deprecate on a definition | Rowcount (0 if rejected due to active dependents) |

**`Location.LocationAttributeDefinition`** (full CRUD, scoped to a parent definition):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Location.LocationAttributeDefinition_ListByDefinition` | `@LocationTypeDefinitionId` | Attribute schema for one kind | `Location.LocationAttributeDefinition` | Engineering opens a definition in the Editor; Location Details Panel renders the dynamic attribute form | Rowset: attribute definition rows |
| `Location.LocationAttributeDefinition_Get` | `@Id` | | `Location.LocationAttributeDefinition` | Edit Attribute form opens | Rowset (0-1): one attribute definition row |
| `Location.LocationAttributeDefinition_Create` | `@LocationTypeDefinitionId, @AttributeName, @DataType, @IsRequired, @DefaultValue, @Uom, @Description, @AppUserId` | Auto-assigns `SortOrder` = MAX(sibling SortOrder) + 1 within the definition. New attributes always appear last. | `Location.LocationTypeDefinition` (FK), calls `Audit.Audit_LogConfigChange` | Engineering adds an attribute to a definition | Scalar: new `Location.LocationAttributeDefinition.Id` (INT) |
| `Location.LocationAttributeDefinition_Update` | `@Id, @AttributeName, @DataType, @IsRequired, @DefaultValue, @Uom, @Description, @AppUserId` | Does **not** change `SortOrder` — use `_MoveUp` / `_MoveDown` for reordering | calls `Audit.Audit_LogConfigChange` | Engineering edits an attribute | Rowcount |
| `Location.LocationAttributeDefinition_MoveUp` | `@Id, @AppUserId` | Swaps `SortOrder` with the nearest sibling attribute above within the same `LocationTypeDefinitionId`. No-op if already first. | `Location.LocationAttributeDefinition`, calls `Audit.Audit_LogConfigChange` | Engineering clicks the up-arrow on an attribute row in the Definition Editor | Rowcount (0 if already first) |
| `Location.LocationAttributeDefinition_MoveDown` | `@Id, @AppUserId` | Swaps `SortOrder` with the nearest sibling attribute below within the same `LocationTypeDefinitionId`. No-op if already last. | `Location.LocationAttributeDefinition`, calls `Audit.Audit_LogConfigChange` | Engineering clicks the down-arrow on an attribute row in the Definition Editor | Rowcount (0 if already last) |
| `Location.LocationAttributeDefinition_Deprecate` | `@Id, @AppUserId` | Rejects if any `Location.LocationAttribute` references it. On success, compacts sibling `SortOrder` values to close the gap. | reads `Location.LocationAttribute`, calls `Audit.Audit_LogConfigChange` | Engineering removes an attribute from a definition | Rowcount (0 if rejected) |

**`Location.Location`** (full CRUD + tree queries):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Location.Location_List` | `@ParentLocationId NULL, @LocationTypeDefinitionId NULL` | Children and/or filtered by kind; ordered by `SortOrder` ASC | `Location.Location`, `Location.LocationTypeDefinition` | Plant Hierarchy Browser expands a tree node to list its children | Rowset: `Location.Location` rows with definition name, tier, and `SortOrder` |
| `Location.Location_GetTree` | `@RootLocationId` | Recursive CTE: full hierarchy from a root down | `Location.Location` (recursive) | Plant Hierarchy Browser initial load from the Enterprise root, or a deep refresh | Rowset: all descendant `Location.Location` rows with `Depth` and materialized path |
| `Location.Location_GetAncestors` | `@LocationId` | Recursive CTE: from this location up to root | `Location.Location` (recursive) | Breadcrumb navigation renders the path from root to the selected node | Rowset: ancestor `Location.Location` rows ordered root→current |
| `Location.Location_GetDescendantsOfType` | `@LocationId, @LocationTypeId` | E.g., "all Cells under the Die Cast Area" | `Location.Location` (recursive), `Location.LocationTypeDefinition` | Eligibility Map Editor loads Cells for an area; Plant Floor looks up eligible machines (Arc 2 usage) | Rowset: matching descendant `Location.Location` rows |
| `Location.Location_Get` | `@Id` | Returns location + all current `Location.LocationAttribute` values | `Location.Location`, `Location.LocationAttribute`, `Location.LocationAttributeDefinition` | User clicks a tree node to load its details panel | Rowset: one `Location.Location` row plus a second rowset of its attribute values, OR a single joined rowset with one row per attribute |
| `Location.Location_Create` | `@LocationTypeDefinitionId, @ParentLocationId, @Name, @Code, @Description, @AppUserId` | Auto-assigns `SortOrder` = MAX(sibling SortOrder) + 1 for the given `@ParentLocationId`. New children always appear last. | `Location.LocationTypeDefinition` (FK), `Location.Location` (parent FK), calls `Audit.Audit_LogConfigChange` | Engineering submits Add Location modal | Scalar: new `Location.Location.Id` (INT) |
| `Location.Location_Update` | `@Id, @Name, @Code, @Description, @AppUserId` | Does **not** change `SortOrder` — use `_MoveUp` / `_MoveDown` for reordering | calls `Audit.Audit_LogConfigChange` | Engineering saves Location Details Panel changes | Rowcount |
| `Location.Location_MoveUp` | `@Id, @AppUserId` | Swaps `SortOrder` with the nearest active sibling above (lower `SortOrder`). No-op if already first. Updates both rows atomically. | `Location.Location`, calls `Audit.Audit_LogConfigChange` | Engineering clicks the up-arrow on a child node in the Plant Hierarchy Browser | Rowcount (0 if already first) |
| `Location.Location_MoveDown` | `@Id, @AppUserId` | Swaps `SortOrder` with the nearest active sibling below (higher `SortOrder`). No-op if already last. Updates both rows atomically. | `Location.Location`, calls `Audit.Audit_LogConfigChange` | Engineering clicks the down-arrow on a child node in the Plant Hierarchy Browser | Rowcount (0 if already last) |
| `Location.Location_Deprecate` | `@Id, @AppUserId` | Rejects if active `Lots.Lot.CurrentLocationId` or `Lots.LotMovement` references exist. On success, compacts sibling `SortOrder` values to close the gap. | reads `Lots.Lot`, `Lots.LotMovement`, calls `Audit.Audit_LogConfigChange` | Engineering clicks Deprecate on a location node | Rowcount (0 if rejected) |

**`Location.LocationAttribute`** (per-instance values):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Location.LocationAttribute_GetByLocation` | `@LocationId` | All current values for one location | `Location.LocationAttribute`, `Location.LocationAttributeDefinition` | Loading the Location Details Panel's attribute form | Rowset: attribute rows joined to their definitions (name, data type, UOM, required flag) |
| `Location.LocationAttribute_Set` | `@LocationId, @LocationAttributeDefinitionId, @AttributeValue, @AppUserId` | Upsert; validates definition belongs to location's kind | `Location.Location`, `Location.LocationAttributeDefinition`, calls `Audit.Audit_LogConfigChange` | User saves a changed attribute value in the Details Panel (one call per changed attribute) | Rowcount |
| `Location.LocationAttribute_Clear` | `@LocationId, @LocationAttributeDefinitionId, @AppUserId` | Remove value; rejects if `IsRequired` | `Location.LocationAttributeDefinition`, calls `Audit.Audit_LogConfigChange` | User clears a non-required attribute | Rowcount (0 if rejected) |

**Seed loading** (one-time):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Location.Location_BulkLoadMachinesFromSeed` | `@CsvData NVARCHAR(MAX), @AppUserId` | Loads `machines.csv`. Alternative: Ignition Gateway script calling `Location.Location_Create` per row. | calls `Location.Location_Create` per row (transitively `Audit.Audit_LogConfigChange`) | Engineer runs the Bulk Seed Loader screen during initial deployment (one-time) | Scalar: count of rows inserted, or a result set summarizing inserts/failures |

### Frontend (Perspective Views)

| View | Purpose |
|---|---|
| **Plant Hierarchy Browser** | Tree component (Perspective Tree or custom recursive accordion) showing the plant model from Enterprise → Site → Area → WorkCenter → Cell, ordered by `SortOrder` at each level. Click a node to load its details in a side panel. Each child row has **up/down arrow buttons** to reorder among siblings (calls `Location.Location_MoveUp` / `_MoveDown`). No drag-and-drop. |
| **Location Details Panel** | Right-side drawer triggered by selecting a tree node. Shows Name, Code, Description, Type/Definition (read-only after create), Parent (read-only after create), and a **dynamic attributes form** rendered from the location's `Location.LocationAttributeDefinition` set. Save invokes `Location.Location_Update` and `Location.LocationAttribute_Set` for each changed attribute. |
| **Add Location Modal** | Triggered from a tree node's context menu. Form: select a `Location.LocationTypeDefinition` (dropdown filtered by what's valid as a child of the parent's tier), enter Name, Code, Description. Submit invokes `Location.Location_Create`. |
| **Location Type Definition Editor** | Engineering/Admin only. List of all `Location.LocationTypeDefinition` rows grouped by `Location.LocationType`. Add/edit definitions, with an embedded sub-table of `Location.LocationAttributeDefinition` rows (the attribute schema). |
| **Bulk Seed Loader** | One-time-use screen (or Gateway script) for loading `machines.csv` into `Location.Location` rows. Shows a preview table from the CSV, lets the engineer map process types to definitions (e.g., MachDesc starting with "DieCast" → `DieCastMachine`), and triggers the bulk load. |

### Phase 2 complete when

- 5 `Location.LocationType` rows seeded
- ~15 `Location.LocationTypeDefinition` rows seeded with their attribute schemas
- The MPP plant tree exists from Enterprise root down to all 209 machines
- Tonnage, cycle time, and NumberOfCavities attribute values from `machines.csv` are loaded as `Location.LocationAttribute` rows
- Engineering can browse the tree, click a machine, and see/edit its attributes
- Engineering can add a new `Location.LocationTypeDefinition` (e.g., "TestStand" if a new kind is needed)
- Every mutation lands in `Audit.ConfigLog` with the authenticated user's `AppUserId` recorded

---

## Phase 3 — Reference Lookups

**Goal:** Stand up the small fixed code tables that everything else FKs to. These are mostly seed-once-and-forget.

**Dependencies:** Phase 2 (need `Location.AppUser` for audit attribution on the few that allow user-managed rows).

**Status:** Unblocked. Small phase — could be one engineer-day of CRUD scaffolding.

### Data Model

| Table | Role | Mutability |
|---|---|---|
| `Parts.Uom` | Units of measure (EA, LB, KG, IN, MM, PCS, etc.) | Engineering can add new ones |
| `Parts.ItemType` | Raw Material, Component, Sub-Assembly, Finished Good, Pass-Through | Mostly fixed; rarely extended |
| `Lots.LotOriginType` | Manufactured, Received, ReceivedOffsite | Fixed; seeded only |
| `Lots.LotStatusCode` | Good, Hold, Scrap, Closed | Fixed; seeded only |
| `Lots.ContainerStatusCode` | Open, Complete, Shipped, Hold, Void | Fixed; seeded only |
| `Lots.GenealogyRelationshipType` | Split, Merge, Consumption | Fixed; seeded only |
| `Workorder.OperationStatus` | Pending, InProgress, Completed, Skipped | Fixed; seeded only |
| `Workorder.WorkOrderStatus` | (per the workorder schema) | Fixed; seeded only |
| `Lots.PrintReasonCode` | Why a label was printed: Initial, Reprint, Replacement, etc. | Fixed; seeded only |
| `Lots.LabelTypeCode` | Label format: LTT, ShippingLabel, ContainerLabel, etc. | Fixed; seeded only |
| `Quality.InspectionResultCode` | Overall sample result: Pass, Fail, Conditional, etc. | Fixed; seeded only |
| `Quality.SampleTriggerCode` | What triggered an inspection sample: FirstPiece, LastPiece, Hourly, Random, etc. | Fixed; seeded only |
| `Quality.HoldTypeCode` | Reason category for holds: QualityHold, EngineeringHold, CustomerHold, etc. | Fixed; seeded only |
| `Quality.DispositionCode` | Resolution of a non-conformance: UseAsIs, Rework, Scrap, ReturnToSupplier, etc. | Fixed; seeded only |
| `Oee.DowntimeSourceCode` | How a downtime event was sourced: Operator, PLC, System, etc. | Fixed; seeded only |
| `Parts.DataCollectionField` | Canonical list of data collection fields that can be assigned to operation templates: CollectsDieInfo, CollectsCavityInfo, CollectsWeight, CollectsGoodCount, CollectsBadCount, RequiresMaterialVerification, RequiresSerialNumber, etc. | Engineering can add new ones |

### API Layer (Named Queries → Stored Procedures)

Each table follows one of two standard patterns based on whether engineering can extend it.

**Read-only pattern** (`Lots.LotOriginType`, `Lots.LotStatusCode`, `Lots.ContainerStatusCode`, `Lots.GenealogyRelationshipType`, `Workorder.OperationStatus`, `Workorder.WorkOrderStatus`, `Lots.PrintReasonCode`, `Lots.LabelTypeCode`, `Quality.InspectionResultCode`, `Quality.SampleTriggerCode`, `Quality.HoldTypeCode`, `Quality.DispositionCode`, `Oee.DowntimeSourceCode`):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `<Entity>_List` | — | Returns all rows | `<Entity>` table | Reference Data Manager tab loads; dropdown populates on any other screen needing this code table (e.g., LOT status dropdown on plant-floor screens) | Rowset: all `<Entity>` rows |
| `<Entity>_Get` | `@Id` | Single row | `<Entity>` table | Detail view of a specific row (rare) | Rowset (0-1): one `<Entity>` row |

**Mutable pattern** (`Parts.Uom`, `Parts.ItemType`, `Parts.DataCollectionField` — engineering can add new entries):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `<Entity>_List` | `@IncludeDeprecated BIT = 0` | | `<Entity>` table | Reference Data Manager tab loads; dropdown population on other screens (Item Master needs Uom + ItemType) | Rowset: `<Entity>` rows |
| `<Entity>_Get` | `@Id` | | `<Entity>` table | Edit modal opens | Rowset (0-1): one row |
| `<Entity>_Create` | `@Code, @Name, @Description, @AppUserId` | Returns new `Id` | calls `Audit.Audit_LogConfigChange` | Admin submits Add modal | Scalar: new `<Entity>.Id` (INT) |
| `<Entity>_Update` | `@Id, @Name, @Description, @AppUserId` | `Code` is immutable | calls `Audit.Audit_LogConfigChange` | Admin saves Edit form | Rowcount |
| `<Entity>_Deprecate` | `@Id, @AppUserId` | Rejects on active dependents | reads referencing tables, calls `Audit.Audit_LogConfigChange` | Admin clicks Deprecate | Rowcount (0 if rejected) |

### Frontend (Perspective Views)

| View | Purpose |
|---|---|
| **Reference Data Manager** | A single screen with tabs (or a dropdown selector) for each of the lookup tables. Each tab is a simple list-with-edit grid. Read-only tables show a disabled "Add" button and an info note explaining they're seeded. |

This phase is intentionally minimal. The frontend is a generic CRUD grid that loads its columns from a config block per entity. Engineering rarely visits this screen — it's a "set it and forget it" phase.

### Phase 3 complete when

- All listed tables exist with their seed data loaded (including the 7 new code tables: `Lots.PrintReasonCode`, `Lots.LabelTypeCode`, `Quality.InspectionResultCode`, `Quality.SampleTriggerCode`, `Quality.HoldTypeCode`, `Quality.DispositionCode`, `Oee.DowntimeSourceCode`, plus the mutable `Parts.DataCollectionField`)
- The Reference Data Manager screen lists every table and lets engineering CRUD the mutable ones (`Parts.Uom`, `Parts.ItemType`, `Parts.DataCollectionField`)
- Audit log entries appear for any mutations on `Parts.Uom`, `Parts.ItemType`, or `Parts.DataCollectionField`

---

## Phase 4 — Item Master & Container Config

**Goal:** The "what we make" master data. Every part number that MPP produces or receives.

**Dependencies:** Phase 1 (locations referenced by `Parts.ItemLocation` later), Phase 2 (audit), Phase 3 (UOM, ItemType).

**Status:** Unblocked.

### Data Model

| Table | Role |
|---|---|
| `Parts.Item` | The master part list. Each row is one MPP part number. Carries description, item type, default sub-lot quantity, max lot size, unit weight, UOM, optional Macola cross-reference. |
| `Parts.ContainerConfig` | Per-finished-good packing rules: trays per container, parts per tray, serialized flag, dunnage code, customer code. Note OI-02 may add `ClosureMethod` and `TargetWeight` columns. |

### API Layer (Named Queries → Stored Procedures)

**`Parts.Item`**:

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Parts.Item_List` | `@ItemTypeId NULL, @SearchText NULL, @IncludeDeprecated BIT = 0` | Filterable list | `Parts.Item`, `Parts.ItemType`, `Parts.Uom` | Item Master List loads; Item Picker component loads | Rowset: `Parts.Item` rows joined to `Parts.ItemType.Name` and `Parts.Uom.Code` |
| `Parts.Item_Get` | `@Id` | | `Parts.Item` | Item Editor opens | Rowset (0-1): one `Parts.Item` row |
| `Parts.Item_GetByPartNumber` | `@PartNumber` | For BOM/route construction lookups | `Parts.Item` | BOM/route construction validates a typed or scanned part number; Plant Floor validates a scanned source LOT's part (Arc 2 usage) | Rowset (0-1): one `Parts.Item` row |
| `Parts.Item_Create` | `@PartNumber, @ItemTypeId, @Description, @MacolaPartNumber, @DefaultSubLotQty, @MaxLotSize, @UomId, @UnitWeight, @WeightUomId, @AppUserId` | Returns new `Id` | `Parts.ItemType` (FK), `Parts.Uom` (FK), calls `Audit.Audit_LogConfigChange` | Engineering submits New Item form | Scalar: new `Parts.Item.Id` (INT) |
| `Parts.Item_Update` | `@Id, @Description, @MacolaPartNumber, @DefaultSubLotQty, @MaxLotSize, @UomId, @UnitWeight, @WeightUomId, @AppUserId` | `PartNumber` and `ItemTypeId` are immutable — to change, deprecate and recreate | `Parts.Uom` (FK), calls `Audit.Audit_LogConfigChange` | Engineering saves Item Editor changes | Rowcount |
| `Parts.Item_Deprecate` | `@Id, @AppUserId` | Rejects if active `Parts.Bom`, `Parts.RouteTemplate`, `Parts.ItemLocation`, or `Parts.ContainerConfig` references exist | reads `Parts.Bom`, `Parts.RouteTemplate`, `Parts.ItemLocation`, `Parts.ContainerConfig`, calls `Audit.Audit_LogConfigChange` | Engineering clicks Deprecate on an item | Rowcount (0 if rejected) |

**`Parts.ContainerConfig`**:

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Parts.ContainerConfig_GetByItem` | `@ItemId` | Usually one config per item | `Parts.ContainerConfig` | Container Config tab opens in Item Editor; Plant Floor container lifecycle needs the packing rules (Arc 2 usage) | Rowset (0-1): one `Parts.ContainerConfig` row |
| `Parts.ContainerConfig_Create` | `@ItemId, @TraysPerContainer, @PartsPerTray, @IsSerialized, @DunnageCode, @CustomerCode, @AppUserId` | OI-02 may add `@ClosureMethod` and `@TargetWeight` | `Parts.Item` (FK), calls `Audit.Audit_LogConfigChange` | Engineering saves a new container config for a finished good | Scalar: new `Parts.ContainerConfig.Id` (INT) |
| `Parts.ContainerConfig_Update` | `@Id, @TraysPerContainer, @PartsPerTray, @IsSerialized, @DunnageCode, @CustomerCode, @AppUserId` | | calls `Audit.Audit_LogConfigChange` | Engineering edits an existing container config | Rowcount |
| `Parts.ContainerConfig_Deprecate` | `@Id, @AppUserId` | | calls `Audit.Audit_LogConfigChange` | Engineering removes a container config | Rowcount |

### Frontend (Perspective Views)

| View | Purpose |
|---|---|
| **Item Master List** | Filterable table of all items: search by part number, filter by item type, toggle deprecated visibility. Columns: PartNumber, Description, ItemType, UOM, MacolaPartNumber, UnitWeight, DefaultSubLotQty. Click a row to open the Item Editor. |
| **Item Editor** | Form view for create/update. Layout: left column = required fields (PartNumber, ItemType, UOM); right column = optional (Macola ref, weight, sub-lot qty, max lot size). Bottom: tabs for "Container Config", "BOM" (Phase 6 link), "Routes" (Phase 5 link), "Quality Specs" (Phase 7 link), "Audit History". |
| **Container Config Sub-tab** | Embedded in Item Editor. For finished goods only — disable for raw materials and components. Form fields: trays per container, parts per tray, serialized flag, dunnage code, customer code. |
| **Item Picker (reusable component)** | Modal/inline picker used throughout the rest of the Configuration Tool (BOMs, routes, eligibility map). Searchable by part number or description. Returns the `Parts.Item.Id`. |

### Phase 4 complete when

- Every existing MPP part number is loaded into `Parts.Item` (initial load — manual via the Item Editor or bulk-load if MPP has an Excel export)
- Every finished good has a `Parts.ContainerConfig` record
- Engineering can create a new part, edit an existing one, deprecate one no longer in production
- The Item Picker component is reusable from the rest of the Configuration Tool

---

## Phase 5 — Process Definition: Routes & Operations

**Goal:** Define how each part flows through the plant — which operations, in what order, at which areas, collecting what data.

**Dependencies:** Phase 1 (Locations and Areas), Phase 4 (Items), Phase 2 (audit).

**Status:** Unblocked.

### Data Model

| Table | Role |
|---|---|
| `Parts.RouteTemplate` | The route header per item. Versioned. Each row links one `Parts.Item` to a route version. |
| `Parts.RouteStep` | The ordered steps in a route. Each step references an `Parts.OperationTemplate`. |
| `Parts.OperationTemplate` | The reusable definition of an operation: name, area. Versioned independently of routes. Data collection fields are configured separately via the `Parts.OperationTemplateField` junction table (no hardcoded BIT flags). |
| `Parts.OperationTemplateField` | Junction table linking an `Parts.OperationTemplate` to one or more `Parts.DataCollectionField` rows. Each row represents a data collection field configured for that template, with an `IsRequired` flag. Soft-deletable via `DeprecatedAt`. |
| `Parts.ItemLocation` | The eligibility map: which items can run on which Cells. |

Note: per FDS-03-009, route steps do **not** prescribe a specific machine — they reference an `Parts.OperationTemplate` which has an `AreaLocationId`, and the operator picks the Cell at runtime from the `Parts.ItemLocation` eligibility set.

### API Layer (Named Queries → Stored Procedures)

**`Parts.OperationTemplate`** (versioned):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Parts.OperationTemplate_List` | `@AreaLocationId NULL, @ActiveOnly BIT = 1` | Filter by area | `Parts.OperationTemplate`, `Location.Location` | Operation Template Library loads; Route Builder dropdown populates when adding a step | Rowset: `Parts.OperationTemplate` rows joined to area name |
| `Parts.OperationTemplate_Get` | `@Id` | | `Parts.OperationTemplate` | Engineering opens a template in the Editor | Rowset (0-1): one template row |
| `Parts.OperationTemplate_Create` | `@Name, @AreaLocationId, @AppUserId` | Creates version 1. Data collection fields configured separately via `Parts.OperationTemplateField` after creation. | `Location.Location` (Area FK), calls `Audit.Audit_LogConfigChange` | Engineering submits New Template form | Scalar: new `Parts.OperationTemplate.Id` (INT) |
| `Parts.OperationTemplate_CreateNewVersion` | `@ParentOperationTemplateId, @EffectiveFrom, @AppUserId` | New version preserves the previous. Copies `Parts.OperationTemplateField` rows from the parent version. | reads `Parts.OperationTemplate`, `Parts.OperationTemplateField`; calls `Audit.Audit_LogConfigChange` | Engineering clicks "Save as New Version" | Scalar: new version `Parts.OperationTemplate.Id` (INT) |
| `Parts.OperationTemplate_Deprecate` | `@Id, @AppUserId` | Soft-deletes a specific version | reads `Parts.RouteStep`, calls `Audit.Audit_LogConfigChange` | Engineering deprecates a template version | Rowcount (0 if rejected due to active route steps) |

**`Parts.OperationTemplateField`** (junction: which data collection fields are configured for a template):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Parts.OperationTemplateField_ListByTemplate` | `@OperationTemplateId` | Active fields for one template | `Parts.OperationTemplateField`, `Parts.DataCollectionField` | Operation Template Editor loads field configuration | Rowset: fields joined to `Parts.DataCollectionField` name/code |
| `Parts.OperationTemplateField_Add` | `@OperationTemplateId, @DataCollectionFieldId, @IsRequired, @AppUserId` | | `Parts.OperationTemplate` (FK), `Parts.DataCollectionField` (FK), calls `Audit.Audit_LogConfigChange` | Engineering adds a data collection field to a template | Scalar: new `Parts.OperationTemplateField.Id` (BIGINT) |
| `Parts.OperationTemplateField_Remove` | `@Id, @AppUserId` | Soft-deletes via `DeprecatedAt` | calls `Audit.Audit_LogConfigChange` | Engineering removes a field from a template | Rowcount |

**`Parts.RouteTemplate`** (versioned):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Parts.RouteTemplate_ListByItem` | `@ItemId, @ActiveOnly BIT = 1` | Usually one active route per item | `Parts.RouteTemplate` | Route Builder opens for an item; Item Editor's Routes tab loads | Rowset: `Parts.RouteTemplate` rows ordered by version |
| `Parts.RouteTemplate_Get` | `@Id` | Returns route header + steps in order | `Parts.RouteTemplate`, `Parts.RouteStep`, `Parts.OperationTemplate` | Opening a specific route version in the Route Builder | Rowset: one route header + joined rowset of ordered steps with operation names |
| `Parts.RouteTemplate_GetActiveForItem` | `@ItemId, @AsOfDate DATETIME2 = NULL` | Picks version active at a given moment | `Parts.RouteTemplate` | Plant Floor production code looks up "what route governs this LOT right now?" (Arc 2 usage) | Rowset (0-1): one active route header |
| `Parts.RouteTemplate_Create` | `@ItemId, @Name, @EffectiveFrom, @AppUserId` | Empty route, version 1 | `Parts.Item` (FK), calls `Audit.Audit_LogConfigChange` | Engineering creates a first route for an item | Scalar: new `Parts.RouteTemplate.Id` (INT) |
| `Parts.RouteTemplate_CreateNewVersion` | `@ParentRouteTemplateId, @EffectiveFrom, @AppUserId` | Copies steps from prior version | reads `Parts.RouteTemplate`, `Parts.RouteStep`; calls `Audit.Audit_LogConfigChange` | Engineering clicks "New Version" in Route Builder | Scalar: new version `Parts.RouteTemplate.Id` (INT) |
| `Parts.RouteTemplate_Deprecate` | `@Id, @AppUserId` | | calls `Audit.Audit_LogConfigChange` | Engineering deprecates a route version | Rowcount |

**`Parts.RouteStep`**:

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Parts.RouteStep_ListByRoute` | `@RouteTemplateId` | | `Parts.RouteStep`, `Parts.OperationTemplate` | Route Builder displays steps for the current route | Rowset: `Parts.RouteStep` rows joined to operation name, ordered by `SequenceNumber` |
| `Parts.RouteStep_Add` | `@RouteTemplateId, @OperationTemplateId, @AppUserId` | Auto-assigns `SequenceNumber` = MAX(sibling SequenceNumber) + 1 within the route. New steps always appear last. | `Parts.RouteTemplate` (FK), `Parts.OperationTemplate` (FK), calls `Audit.Audit_LogConfigChange` | Engineering adds a step in Route Builder | Scalar: new `Parts.RouteStep.Id` (INT) |
| `Parts.RouteStep_Update` | `@Id, @OperationTemplateId, @AppUserId` | Does **not** change `SequenceNumber` — use `_MoveUp` / `_MoveDown` for reordering | `Parts.OperationTemplate` (FK), calls `Audit.Audit_LogConfigChange` | Engineering edits a step's operation | Rowcount |
| `Parts.RouteStep_MoveUp` | `@Id, @AppUserId` | Swaps `SequenceNumber` with the nearest sibling step above (lower `SequenceNumber`) within the same `RouteTemplateId`. No-op if already first. | `Parts.RouteStep`, calls `Audit.Audit_LogConfigChange` | Engineering clicks the up-arrow on a step row in the Route Builder | Rowcount (0 if already first) |
| `Parts.RouteStep_MoveDown` | `@Id, @AppUserId` | Swaps `SequenceNumber` with the nearest sibling step below (higher `SequenceNumber`) within the same `RouteTemplateId`. No-op if already last. | `Parts.RouteStep`, calls `Audit.Audit_LogConfigChange` | Engineering clicks the down-arrow on a step row in the Route Builder | Rowcount (0 if already last) |
| `Parts.RouteStep_Remove` | `@Id, @AppUserId` | On success, compacts sibling `SequenceNumber` values to close the gap. | calls `Audit.Audit_LogConfigChange` | Engineering removes a step from a route | Rowcount |

**`Parts.ItemLocation`** (eligibility map):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Parts.ItemLocation_ListByItem` | `@ItemId` | "Where can this part run?" | `Parts.ItemLocation`, `Location.Location` | Item Editor's Eligibility tab loads; Plant Floor validates a machine selection for a LOT (Arc 2 usage) | Rowset: `Location.Location` rows eligible for this item |
| `Parts.ItemLocation_ListByLocation` | `@LocationId` | "What parts can run on this machine?" | `Parts.ItemLocation`, `Parts.Item` | Eligibility Map Editor loads machine column; Plant Floor machine screen shows available parts (Arc 2 usage) | Rowset: `Parts.Item` rows eligible on this location |
| `Parts.ItemLocation_Add` | `@ItemId, @LocationId, @AppUserId` | | `Parts.Item` (FK), `Location.Location` (FK), calls `Audit.Audit_LogConfigChange` | Engineering checks a cell in the Eligibility Map matrix | Rowcount (1 if inserted, 0 if already existed) |
| `Parts.ItemLocation_Remove` | `@ItemId, @LocationId, @AppUserId` | | calls `Audit.Audit_LogConfigChange` | Engineering unchecks a cell in the Eligibility Map matrix | Rowcount |

### Frontend (Perspective Views)

| View | Purpose |
|---|---|
| **Operation Template Library** | List of all operation templates grouped by Area. Add new template button. Click a template to see/edit its configurable data collection fields. Shows version history for each template. |
| **Route Builder** | Master-detail view tied to an Item. Left: list of routes for the item with version dropdown. Right: ordered list of steps, each showing the operation template name and its area. Each step row has **up/down arrow buttons** to reorder (calls `Parts.RouteStep_MoveUp` / `_MoveDown`), plus buttons to insert/remove steps. No drag-and-drop. "New Version" button creates a new route version (preserving the old). |
| **Eligibility Map Editor** | Two-pane view: items on the left, locations on the right, with a center matrix showing which items are eligible at which Cells. Click a cell in the matrix to toggle eligibility. Filter both lists by area or part type. |
| **Operation Template Editor** | Form view triggered from the Library. Name, description, area dropdown (filtered to Area-tier locations). Below the header: a **Data Collection Fields** grid listing the `Parts.DataCollectionField` rows assigned to this template (via `Parts.OperationTemplateField`). Each row shows the field name, `IsRequired` toggle, and a remove button. An "Add Field" picker lets engineering select from the canonical `Parts.DataCollectionField` list. "Save as new version" creates a fresh version (copies field assignments). |

### Phase 5 complete when

- Every active MPP item has at least one `Parts.RouteTemplate` with at least one `Parts.RouteStep`
- The `Parts.ItemLocation` eligibility map is populated for every item-cell combination MPP runs
- Engineering can create a new route version when an existing route changes — old production records still reference the old version
- Operators (in Phase 4 of the Plant Floor build) will be able to query "which Cells can run this Item?" via `Parts.ItemLocation_ListByItem`

> **Forward-reference — Arc 2 (Plant Floor).** The `Parts.OperationTemplateField` rows an engineer configures here define the runtime data-collection contract. When a LOT passes through an operation on the shop floor, Arc 2's `Workorder.ProductionEvent_Record` proc SHALL (per FDS-03-017a): (1) write one `Workorder.ProductionEvent` header carrying `OperationTemplateId` plus hot typed columns (GoodCount, NoGoodCount, DieIdentifier, CavityNumber, WeightValue + WeightUomId) for fields promoted from `DataCollectionField`; (2) write one `Workorder.ProductionEventValue` child per non-hot field configured on the template; (3) reject on missing `IsRequired = 1` fields; (4) reject on attempts to double-write a hot-column field into the child table. No Arc 1 proc changes — but the Phase 5 Operation Template Editor is what drives what Arc 2 captures. The Arc 2 plan (separate document) owns the write proc and the plant-floor screen.

---

## Phase 6 — BOM Management

**Goal:** Versioned bills of material. Required for assembly operations to validate material consumption.

**Dependencies:** Phase 4 (Items).

**Status:** Unblocked.

### Data Model

| Table | Role |
|---|---|
| `Parts.Bom` | Header table. One row per `(ParentItemId, VersionNumber)`. Versioned. |
| `Parts.BomLine` | Component lines. Each row = one component item with quantity per parent. |

### API Layer (Named Queries → Stored Procedures)

**`Parts.Bom`** (versioned):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Parts.Bom_ListByParentItem` | `@ParentItemId, @ActiveOnly BIT = 1` | All BOM versions for a parent item | `Parts.Bom` | BOM tab opens in Item Editor; BOM Editor version selector loads | Rowset: `Parts.Bom` rows ordered by version |
| `Parts.Bom_Get` | `@Id` | Header + all lines in sort order | `Parts.Bom`, `Parts.BomLine`, `Parts.Item` | Opening a BOM version in the BOM Editor | Rowset: one `Parts.Bom` header + joined rowset of `Parts.BomLine` rows with child item names |
| `Parts.Bom_GetActiveForItem` | `@ParentItemId, @AsOfDate DATETIME2 = NULL` | Picks version active at a given moment | `Parts.Bom` | Plant Floor assembly validates material against the BOM active at run time (Arc 2 usage) | Rowset (0-1): one active `Parts.Bom` header |
| `Parts.Bom_Create` | `@ParentItemId, @VersionNumber, @EffectiveFrom, @AppUserId` | Empty BOM, no lines | `Parts.Item` (FK), calls `Audit.Audit_LogConfigChange` | Engineering creates a first BOM for an item | Scalar: new `Parts.Bom.Id` (INT) |
| `Parts.Bom_CreateNewVersion` | `@ParentBomId, @EffectiveFrom, @AppUserId` | Copies all lines from the prior version | reads `Parts.Bom`, `Parts.BomLine`; calls `Audit.Audit_LogConfigChange` | Engineering clicks "New Version" in the BOM Editor | Scalar: new version `Parts.Bom.Id` (INT) |
| `Parts.Bom_Deprecate` | `@Id, @AppUserId` | | calls `Audit.Audit_LogConfigChange` | Engineering deprecates a BOM version | Rowcount |

**`Parts.BomLine`**:

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Parts.BomLine_ListByBom` | `@BomId` | | `Parts.BomLine`, `Parts.Item`, `Parts.Uom` | BOM Editor renders the component lines for the active version | Rowset: `Parts.BomLine` rows joined to child item name and UOM code, ordered by `SortOrder` |
| `Parts.BomLine_Add` | `@BomId, @ChildItemId, @QtyPer, @UomId, @AppUserId` | Auto-assigns `SortOrder` = MAX(sibling SortOrder) + 1 within the BOM. New lines always appear last. | `Parts.Bom` (FK), `Parts.Item` (FK), `Parts.Uom` (FK), calls `Audit.Audit_LogConfigChange` | Engineering adds a component line via the Item Picker | Scalar: new `Parts.BomLine.Id` (INT) |
| `Parts.BomLine_Update` | `@Id, @QtyPer, @UomId, @AppUserId` | Does **not** change `SortOrder` — use `_MoveUp` / `_MoveDown` for reordering | `Parts.Uom` (FK), calls `Audit.Audit_LogConfigChange` | Engineering edits qty per or UOM | Rowcount |
| `Parts.BomLine_MoveUp` | `@Id, @AppUserId` | Swaps `SortOrder` with the nearest sibling line above within the same `BomId`. No-op if already first. | `Parts.BomLine`, calls `Audit.Audit_LogConfigChange` | Engineering clicks the up-arrow on a BOM line in the BOM Editor | Rowcount (0 if already first) |
| `Parts.BomLine_MoveDown` | `@Id, @AppUserId` | Swaps `SortOrder` with the nearest sibling line below within the same `BomId`. No-op if already last. | `Parts.BomLine`, calls `Audit.Audit_LogConfigChange` | Engineering clicks the down-arrow on a BOM line in the BOM Editor | Rowcount (0 if already last) |
| `Parts.BomLine_Remove` | `@Id, @AppUserId` | On success, compacts sibling `SortOrder` values to close the gap. | calls `Audit.Audit_LogConfigChange` | Engineering removes a component line | Rowcount |

### Frontend (Perspective Views)

| View | Purpose |
|---|---|
| **BOM Editor** | Master-detail view tied to an Item (linked from the Item Editor in Phase 4). Left: BOM version selector with effective dates. Right: editable grid of `Parts.BomLine` rows ordered by `SortOrder` — child item picker (reuses the Phase 4 Item Picker), quantity per, UOM. Each line has **up/down arrow buttons** to reorder (calls `Parts.BomLine_MoveUp` / `_MoveDown`). No drag-and-drop. "New Version" button copies the current BOM and bumps the version. |
| **BOM Comparison** | View two versions of the same BOM side-by-side, showing line-level diffs (added, removed, changed quantities). Useful before activating a new version. |
| **Where-Used Report** | "Show me every BOM that uses this child item." Useful when deprecating a part — engineering can see what would be impacted. |

### Phase 6 complete when

- Every assembled MPP product has at least one BOM with at least one component line
- Engineering can create a new BOM version when a design change happens, and the old version is preserved
- The Where-Used report is functional

---

## Phase 7 — Quality Configuration

**Goal:** Define quality specifications and load defect codes. Quality specs are versioned per item/operation; defect codes are reference data.

**Dependencies:** Phase 1 (Areas referenced by defect codes), Phase 4 (Items referenced by quality specs), Phase 5 (Operation Templates optionally referenced by quality specs).

**Status:** Unblocked.

### Data Model

| Table | Role |
|---|---|
| `Quality.QualitySpec` | Header per spec — name, optional item, optional operation template. |
| `Quality.QualitySpecVersion` | Versioned spec body. |
| `Quality.QualitySpecAttribute` | The measurable attributes per spec version: name, data type, target value, lower limit, upper limit, UOM, sample trigger (FK to `Quality.SampleTriggerCode`). |
| `Quality.DefectCode` | Reference list: code, description, area, excused flag. Loaded from `defect_codes.csv` (153 rows). |

**Seed data to load:**

| Table | Source | Rows | Notes |
|---|---|---|---|
| `Quality.DefectCode` | `reference/seed_data/defect_codes.csv` | 153 | Codes 100–145 by department: Die Cast, Trim Shop, Machine Shop, Production Control, Quality Control, HSP. Includes `IsExcused` flag. |

### API Layer (Named Queries → Stored Procedures)

**`Quality.QualitySpec`** (header):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Quality.QualitySpec_List` | `@ItemId NULL, @OperationTemplateId NULL` | Filter by item or operation | `Quality.QualitySpec` | Quality Spec Library loads; Item Editor's Quality Specs tab loads | Rowset: `Quality.QualitySpec` rows |
| `Quality.QualitySpec_Get` | `@Id` | Header + active version + attributes | `Quality.QualitySpec`, `Quality.QualitySpecVersion`, `Quality.QualitySpecAttribute` | Opening a spec in the Editor | Rowset: one `Quality.QualitySpec` header + joined rowsets for active version and its attributes |
| `Quality.QualitySpec_Create` | `@Name, @ItemId NULL, @OperationTemplateId NULL, @AppUserId` | | `Parts.Item` (FK, optional), `Parts.OperationTemplate` (FK, optional), calls `Audit.Audit_LogConfigChange` | Engineering creates a new quality spec | Scalar: new `Quality.QualitySpec.Id` (INT) |
| `Quality.QualitySpec_Deprecate` | `@Id, @AppUserId` | | calls `Audit.Audit_LogConfigChange` | Engineering deprecates a spec | Rowcount |

**`Quality.QualitySpecVersion`** (versioned body):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Quality.QualitySpecVersion_ListBySpec` | `@QualitySpecId` | | `Quality.QualitySpecVersion` | Quality Spec Editor version dropdown loads | Rowset: `Quality.QualitySpecVersion` rows ordered by version |
| `Quality.QualitySpecVersion_GetActive` | `@QualitySpecId, @AsOfDate DATETIME2 = NULL` | Picks version active at a given time | `Quality.QualitySpecVersion` | Plant Floor inspection screen loads "what spec governs this inspection right now?" (Arc 2 usage) | Rowset (0-1): one active version row |
| `Quality.QualitySpecVersion_Create` | `@QualitySpecId, @VersionNumber, @EffectiveFrom, @AppUserId` | Empty version | `Quality.QualitySpec` (FK), calls `Audit.Audit_LogConfigChange` | Engineering creates a first version of a spec | Scalar: new `Quality.QualitySpecVersion.Id` (INT) |
| `Quality.QualitySpecVersion_CreateNewVersion` | `@ParentVersionId, @EffectiveFrom, @AppUserId` | Copies attributes from prior version | reads `Quality.QualitySpecVersion`, `Quality.QualitySpecAttribute`; calls `Audit.Audit_LogConfigChange` | Engineering clicks "New Version" in the Spec Editor | Scalar: new version `Quality.QualitySpecVersion.Id` (INT) |
| `Quality.QualitySpecVersion_Deprecate` | `@Id, @AppUserId` | | calls `Audit.Audit_LogConfigChange` | Engineering deprecates a spec version | Rowcount |

**`Quality.QualitySpecAttribute`**:

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Quality.QualitySpecAttribute_ListByVersion` | `@QualitySpecVersionId` | | `Quality.QualitySpecAttribute`, `Parts.Uom` | Spec Editor renders the attribute grid for the active version | Rowset: attribute rows joined to UOM code, ordered by `SortOrder` |
| `Quality.QualitySpecAttribute_Add` | `@QualitySpecVersionId, @AttributeName, @DataType, @TargetValue, @LowerLimit, @UpperLimit, @UomId, @SampleTriggerCodeId, @AppUserId` | Auto-assigns `SortOrder` = MAX(sibling SortOrder) + 1 within the version. New attributes always appear last. | `Quality.QualitySpecVersion` (FK), `Parts.Uom` (FK), `Quality.SampleTriggerCode` (FK), calls `Audit.Audit_LogConfigChange` | Engineering adds a measurable attribute to a spec version | Scalar: new `Quality.QualitySpecAttribute.Id` (INT) |
| `Quality.QualitySpecAttribute_Update` | `@Id, @AttributeName, @DataType, @TargetValue, @LowerLimit, @UpperLimit, @UomId, @SampleTriggerCodeId, @AppUserId` | Does **not** change `SortOrder` — use `_MoveUp` / `_MoveDown` for reordering | `Parts.Uom` (FK), `Quality.SampleTriggerCode` (FK), calls `Audit.Audit_LogConfigChange` | Engineering edits an attribute's target/limits | Rowcount |
| `Quality.QualitySpecAttribute_MoveUp` | `@Id, @AppUserId` | Swaps `SortOrder` with the nearest sibling attribute above within the same `QualitySpecVersionId`. No-op if already first. | `Quality.QualitySpecAttribute`, calls `Audit.Audit_LogConfigChange` | Engineering clicks the up-arrow on an attribute row in the Spec Editor | Rowcount (0 if already first) |
| `Quality.QualitySpecAttribute_MoveDown` | `@Id, @AppUserId` | Swaps `SortOrder` with the nearest sibling attribute below within the same `QualitySpecVersionId`. No-op if already last. | `Quality.QualitySpecAttribute`, calls `Audit.Audit_LogConfigChange` | Engineering clicks the down-arrow on an attribute row in the Spec Editor | Rowcount (0 if already last) |
| `Quality.QualitySpecAttribute_Remove` | `@Id, @AppUserId` | On success, compacts sibling `SortOrder` values to close the gap. | calls `Audit.Audit_LogConfigChange` | Engineering removes an attribute from a spec version | Rowcount |

**`Quality.DefectCode`** (full CRUD + bulk seed):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Quality.DefectCode_List` | `@AreaLocationId NULL, @IncludeDeprecated BIT = 0` | Filter by area | `Quality.DefectCode`, `Location.Location` | Defect Code Manager loads; Plant Floor reject entry populates its defect dropdown filtered to the current area (Arc 2 usage) | Rowset: `Quality.DefectCode` rows joined to area name |
| `Quality.DefectCode_Get` | `@Id` | | `Quality.DefectCode` | Edit modal opens | Rowset (0-1): one defect code row |
| `Quality.DefectCode_Create` | `@Code, @Description, @AreaLocationId, @IsExcused, @AppUserId` | | `Location.Location` (Area FK), calls `Audit.Audit_LogConfigChange` | Engineering adds a new defect code | Scalar: new `Quality.DefectCode.Id` (INT) |
| `Quality.DefectCode_Update` | `@Id, @Description, @AreaLocationId, @IsExcused, @AppUserId` | `Code` is immutable | `Location.Location` (Area FK), calls `Audit.Audit_LogConfigChange` | Engineering edits a defect code | Rowcount |
| `Quality.DefectCode_Deprecate` | `@Id, @AppUserId` | | reads `Workorder.RejectEvent`, calls `Audit.Audit_LogConfigChange` | Engineering deprecates a defect code | Rowcount |
| `Quality.DefectCode_BulkLoadFromSeed` | `@CsvData NVARCHAR(MAX), @AppUserId` | Initial load from `defect_codes.csv` | calls `Quality.DefectCode_Create` per row (transitively `Audit.Audit_LogConfigChange`) | Engineer clicks "Bulk Load" during initial deployment (one-time) | Scalar: count of rows inserted |

### Frontend (Perspective Views)

| View | Purpose |
|---|---|
| **Quality Spec Library** | List of all specs with filters by item, by operation. Click to open the editor. |
| **Quality Spec Editor** | Master-detail view. Left: spec header + version selector. Right: editable grid of attributes ordered by `SortOrder` (name, data type, target, lower limit, upper limit, UOM, sample trigger code dropdown populated from `Quality.SampleTriggerCode`). Each attribute row has **up/down arrow buttons** to reorder (calls `Quality.QualitySpecAttribute_MoveUp` / `_MoveDown`). No drag-and-drop. "New Version" button. |
| **Defect Code Manager** | List of all defect codes grouped by area. Filter by area, search by code or description. Add/edit/deprecate codes. Bulk-load button (one-time) for the seed CSV. |

### Phase 7 complete when

- 153 defect codes from `defect_codes.csv` are loaded into `Quality.DefectCode`
- Engineering has created at least one quality spec for the highest-volume items
- The spec versioning workflow is verified — production records will FK to the active version at run time

---

## Phase 8 — Operations Reference Data

**Goal:** Load downtime reason codes, configure shift schedules, and catalog OPC tags. Mostly seed loading from the CSVs we extracted.

**Dependencies:** Phase 1 (Areas referenced by downtime codes), Phase 2 (audit).

**Status:** Unblocked.

### Data Model

| Table | Role |
|---|---|
| `Oee.DowntimeReasonType` | The 6 fixed types: Equipment, Miscellaneous, Mold, Quality, Setup, Unscheduled. Seeded. |
| `Oee.DowntimeReasonCode` | The ~660 reason codes (353 active rows in our CSV) by area and type. Loaded from `downtime_reason_codes.csv`. |
| `Oee.ShiftSchedule` | Named shift patterns: First Shift 6am–2pm M-F, Second Shift 2pm–10pm, Weekend OT, etc. |
| `Oee.Shift` | Actual instances created from schedules (this is mostly populated at runtime; configuration tool only manages the schedules). |
| (no SQL table for OPC tags) | OPC tag catalog from `opc_tags.csv` drives Ignition OPC connection configuration, not a SQL table. |

**Seed data to load:**

| Table | Source | Rows | Notes |
|---|---|---|---|
| `Oee.DowntimeReasonType` | hard-coded | 6 | Equipment, Miscellaneous, Mold, Quality, Setup, Unscheduled |
| `Oee.DowntimeReasonCode` | `reference/seed_data/downtime_reason_codes.csv` | 353 | DC=86, MS=242, TS=25. **Note:** ~25 rows have empty `TypeId` per `parse_warnings.md` — engineering must assign types before go-live. |
| (Ignition OPC config) | `reference/seed_data/opc_tags.csv` | 161 | Drives Ignition OPC connection config (OmniServer + TOPServer), not a SQL table. 71 Omni + 90 TOP rows. |

### API Layer (Named Queries → Stored Procedures)

**`Oee.DowntimeReasonType`** (read-only — seeded):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Oee.DowntimeReasonType_List` | — | Returns 6 fixed types | `Oee.DowntimeReasonType` | Downtime Reason Code Manager filter dropdown loads; Plant Floor downtime entry screen populates its type dropdown (Arc 2 usage) | Rowset: 6 `Oee.DowntimeReasonType` rows |

**`Oee.DowntimeReasonCode`** (full CRUD + bulk seed):

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Oee.DowntimeReasonCode_List` | `@AreaLocationId NULL, @DowntimeReasonTypeId NULL, @IncludeDeprecated BIT = 0` | Filter by area and/or type | `Oee.DowntimeReasonCode`, `Location.Location`, `Oee.DowntimeReasonType` | Downtime Reason Code Manager loads; Plant Floor operator picks a reason code filtered to their area (Arc 2 usage) | Rowset: `Oee.DowntimeReasonCode` rows joined to area name and type name |
| `Oee.DowntimeReasonCode_Get` | `@Id` | | `Oee.DowntimeReasonCode` | Edit modal opens | Rowset (0-1): one reason code row |
| `Oee.DowntimeReasonCode_Create` | `@Code, @Description, @AreaLocationId, @DowntimeReasonTypeId, @IsExcused, @AppUserId` | | `Location.Location` (Area FK), `Oee.DowntimeReasonType` (FK), calls `Audit.Audit_LogConfigChange` | Engineering adds a new downtime code | Scalar: new `Oee.DowntimeReasonCode.Id` (INT) |
| `Oee.DowntimeReasonCode_Update` | `@Id, @Description, @AreaLocationId, @DowntimeReasonTypeId, @IsExcused, @AppUserId` | | `Location.Location` (Area FK), `Oee.DowntimeReasonType` (FK), calls `Audit.Audit_LogConfigChange` | Engineering edits a downtime code (including assigning a type to a previously untyped row) | Rowcount |
| `Oee.DowntimeReasonCode_Deprecate` | `@Id, @AppUserId` | | reads `Oee.DowntimeEvent`, calls `Audit.Audit_LogConfigChange` | Engineering deprecates a downtime code | Rowcount |
| `Oee.DowntimeReasonCode_BulkLoadFromSeed` | `@CsvData NVARCHAR(MAX), @AppUserId` | Initial load from `downtime_reason_codes.csv` | calls `Oee.DowntimeReasonCode_Create` per row (transitively `Audit.Audit_LogConfigChange`) | Engineer clicks "Bulk Load" during initial deployment (one-time) | Scalar: count of rows inserted |

**`Oee.ShiftSchedule`**:

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Oee.ShiftSchedule_List` | `@ActiveOnly BIT = 1` | | `Oee.ShiftSchedule` | Shift Schedule Editor loads; Plant Floor shift context resolution at login (Arc 2 usage) | Rowset: `Oee.ShiftSchedule` rows |
| `Oee.ShiftSchedule_Get` | `@Id` | | `Oee.ShiftSchedule` | Edit modal opens | Rowset (0-1): one shift schedule row |
| `Oee.ShiftSchedule_Create` | `@Name, @StartTime, @EndTime, @DaysOfWeek, @EffectiveFrom, @AppUserId` | | calls `Audit.Audit_LogConfigChange` | Engineering adds a new shift schedule | Scalar: new `Oee.ShiftSchedule.Id` (INT) |
| `Oee.ShiftSchedule_Update` | `@Id, @Name, @StartTime, @EndTime, @DaysOfWeek, @EffectiveFrom, @AppUserId` | | calls `Audit.Audit_LogConfigChange` | Engineering edits a shift schedule | Rowcount |
| `Oee.ShiftSchedule_Deprecate` | `@Id, @AppUserId` | | reads `Oee.Shift`, calls `Audit.Audit_LogConfigChange` | Engineering deprecates a shift schedule | Rowcount |

### Frontend (Perspective Views)

| View | Purpose |
|---|---|
| **Downtime Reason Code Manager** | List grouped by area, with filter by type. Add/edit/deprecate codes. Bulk-load button (one-time) for seed CSV. Note the parse warning about ~25 codes with empty `TypeId` — those should be flagged in the UI for engineering to assign types before going live. |
| **Shift Schedule Editor** | List of named shift schedules with start/end times, days of week, effective date. Calendar-style preview for the next 2 weeks. |
| **OPC Tag Reference** | A read-only browser of `opc_tags.csv` content. NOT a SQL table — this view loads the CSV directly or pulls it from the Ignition resource folder. Helps engineering see what tags are defined for OmniServer/TOPServer when setting up new lines or troubleshooting. |

### Phase 8 complete when

- 6 `Oee.DowntimeReasonType` rows seeded
- 353 `Oee.DowntimeReasonCode` rows loaded from the CSV
- Engineering has reviewed and assigned types to the ~25 codes with empty `TypeId` (per `parse_warnings.md`)
- At least the 3 standard MPP shift schedules are defined (First, Second, Weekend OT)
- The OPC Tag Reference is browseable as documentation

---

## Out of Scope

Items intentionally excluded from this Configuration Tool plan:

- **All Plant Floor screens** (Arc 2): LOT creation, production recording, downtime entry, hold management (`Quality.HoldEvent` — place/release lifecycle), quality sampling (`Quality.QualitySample`, `Quality.NonConformance`), sort cage, etc. — covered by a separate Phased Plan to be written. Note: the data model refactors (code-table FKs for `@InspectionResultCodeId`, `@SampleTriggerCodeId`, `@DispositionCodeId`, `@HoldTypeCodeId`; `@AppUserId`-based `CreatedByUserId`/`PrintedByUserId` attribution) will shape those Arc 2 procs when that plan is written. In particular, the production-recording screen and its `Workorder.ProductionEvent_Record` proc own the **data-collection capture contract** defined by Phase 5 of this plan (see Phase 5 "Forward-reference" callout and FDS-03-017a): header with `OperationTemplateId` + hot typed columns + one `Workorder.ProductionEventValue` child per non-hot `Parts.DataCollectionField` configured on the template.
- **Reporting**: production reports, downtime reports, OEE roll-ups. These are a separate effort that consumes data from the configured master.
- **External integrations**: Macola (FUTURE), Intelex (FUTURE), AIM (Plant Floor concern, not Configuration Tool).
- **PLC integration setup**: TOPServer/OmniServer connection config lives in Ignition's OPC settings, not the Configuration Tool. The OPC Tag Reference (Phase 8) is documentation, not configuration.
- **Tool Life tracking** (OI-10): Open question on whether it's `Location.LocationAttribute` or a dedicated table. Once resolved, it slots into Phase 1 (if attribute) or a new sub-phase under Phase 1 (if dedicated table).
- **WO management screens** (OI-07): Resolved as MVP-Lite — auto-generated, invisible to operators, no WO screens. The `workorder` schema tables exist and Plant Floor production code populates them, but the Configuration Tool has no `Workorder.WorkOrder_Create` proc or screen.
- **Audit Log advanced search**: Phase 2 covers basic browsing. Saved searches, scheduled audit reports, and compliance exports are a future enhancement.

---

## Open Items That Could Affect This Plan

None of these block Phase 1 from starting, but they should be tracked and may shift scope when resolved:

- **OI-02 (Weight container closure):** If MPP confirms the recommendation, Phase 4 (Container Config) gets two new fields: `ClosureMethod` and `TargetWeight`. The procs and screen forms add those fields. Small impact.
- **OI-05 (LOT merge business rules):** If the rules end up configurable, a new sub-phase appears (likely under Phase 6 or as a Phase 7 addition) to define and store merge rule sets. If hard-coded, no Configuration Tool impact.
- **OI-10 (Tool Life tracking):** Determines whether tool-life data lands in `Location.LocationAttribute` (Phase 1, no extra work) or a new dedicated `ToolLife` table (new sub-phase under Phase 1).
- **`sql_best_practices_mes.md` refresh:** That document still references `snake_case` and `deprecated_at` lowercase from before the 2026-04-09 naming convention change. It needs an update before the new collaborator starts following it as a guide.

---

## Related Documents

| Document | Relevance |
|---|---|
| `MPP_MES_USER_JOURNEYS.md` | Arc 1 narrative — the configuration tool experience this plan builds toward |
| `MPP_MES_DATA_MODEL.md` | Authoritative table and column reference for every entity in this plan |
| `MPP_MES_FDS.md` | Numbered functional requirements; this plan implements §2 (Plant Model), §3 (Master Data), §4 (Auth), §8.8 (Quality Spec Management), §9.4 (Shifts) |
| `MPP_MES_ERD.html` | Visual schema reference |
| `reference/seed_data/` | CSVs for Phase 1, 7, 8 bulk-load steps (machines, defect codes, downtime codes, OPC tags) |
| `reference/seed_data/parse_warnings.md` | Notes on partial machine rows (Phase 1) and untyped downtime codes (Phase 8) that need engineering review |
| `sql_best_practices_mes.md` | Referenced for soft-delete pattern, versioning pattern, code-table-backed status. Note: needs UpperCamelCase update before collaborator onboarding. |
