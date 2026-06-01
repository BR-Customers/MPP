# SQL Database Design Best Practices
### With MES / Manufacturing Layer Extensions

---

## Core Relational Design

- **Normalize to at least 3NF** — eliminate redundant data by separating concerns into related tables. Denormalize deliberately and only for proven performance needs.
- **One table, one entity** — each table should represent a single, well-defined concept (`work_order`, not `work_order_and_parts`).
- **Use surrogate primary keys** — prefer auto-incrementing integers or UUIDs over natural keys (part numbers, WO numbers, lot IDs) which change during engineering revisions, WO reissues, and lot splits.
- **Enforce referential integrity** — always define foreign keys explicitly. Application logic is not a substitute for DB-layer constraint enforcement.

---

## Naming Conventions

- Use `snake_case`, singular nouns for tables (`customer`, `work_order`), and descriptive column names (`created_at`, not `dt`).
- Prefix foreign keys consistently: `customer_id` in `order` references `id` in `customer`.
- Avoid reserved words and abbreviations that obscure meaning.
- In manufacturing contexts, disambiguate similar concepts explicitly: `planned_qty`, `actual_qty`, `rejected_qty` — never just `quantity`.

---

## Data Types & Constraints

- **Choose the smallest appropriate type** — `TINYINT` vs `BIGINT`, `VARCHAR(50)` vs `TEXT`. This affects storage and index efficiency.
- **Apply NOT NULL by default** — only allow NULLs when absence of a value is meaningfully distinct from zero or empty string.
- **Use CHECK constraints** to enforce domain rules at the DB layer (`quantity > 0`, `actual_start >= planned_start`).
- Store dates as `DATE` / `DATETIME2(3)` or better. Millisecond precision is relevant for cycle time analysis and event sequencing.
- Store money and measurements as `DECIMAL(x,y)` — never `FLOAT` for anything requiring exact precision.
- **Unit of measure is a first-class column**, not an implicit assumption. `quantity DECIMAL(10,3)` without a UOM column is a multi-site bug waiting to happen.
- **Status fields should be code-table backed** — a `work_order_status_id` FK to a `status_code` table is auditable and extensible. Avoid magic integers or free-text status strings.

---

## Indexing

- Index every foreign key column and any column frequently used in `WHERE`, `JOIN`, or `ORDER BY` clauses.
- Avoid over-indexing — each index carries write overhead. Profile before adding.
- Use **composite indexes** strategically; column order matters (align with actual query filter patterns).
- Write **sargable** queries — avoid wrapping indexed columns in functions (`WHERE YEAR(created_at) = 2025` defeats an index; use a range instead).
- Regularly review and drop unused indexes.

---

## Relationships & Integrity

- Model **many-to-many** relationships through a junction table with its own PK and explicit FKs to both sides.
- Specify `ON DELETE` / `ON UPDATE` behavior explicitly (`CASCADE`, `RESTRICT`, `SET NULL`) — never leave it implicit.
- Avoid EAV (Entity-Attribute-Value) as a first-choice design. Where dynamic attributes are unavoidable (user-configured fields, variable inspection attributes by part family), prefer:
  - **JSONB columns** (PostgreSQL) — flexible with indexing support
  - **Specification-driven schema** — a `quality_spec` table defines expected attributes per part/operation; results validate against it
  - A **materialized flat layer** if EAV is inherited from a source system you don't control

---

## Soft Deletes & Record Lifecycle

- Prefer **soft deletes** over hard deletes for any record with downstream dependencies or audit significance. Use a `deprecated_at` timestamp (nullable; non-null = inactive) rather than a boolean flag, as it carries the *when* automatically.
- In regulated manufacturing contexts (IATF 16949, FDA 21 CFR Part 11), soft delete is the minimum. Some contexts require append-only records with a separate invalidation entry — hard deletes of production records are generally prohibited.
- **Effective specifications are a soft-delete pattern.** When a recipe, inspection plan, or quality spec changes, the prior version is deprecated — not deleted or overwritten. Production records carry a FK to the spec version that was active at time of execution. Querying what spec governed a given lot is then a simple FK lookup, not a temporal reconstruction problem.

  ```sql
  -- Spec version table with soft delete
  CREATE TABLE quality_spec_version (
      id              INT PRIMARY KEY,
      spec_id         INT NOT NULL REFERENCES quality_spec(id),
      version_number  INT NOT NULL,
      effective_from  DATETIME2 NOT NULL,
      deprecated_at   DATETIME2 NULL,        -- NULL = currently active
      created_by      VARCHAR(100) NOT NULL,
      created_at      DATETIME2 NOT NULL DEFAULT GETDATE()
  );

  -- Production record points to the version active at run time
  CREATE TABLE inspection_result (
      id                      INT PRIMARY KEY,
      work_order_id           INT NOT NULL REFERENCES work_order(id),
      quality_spec_version_id INT NOT NULL REFERENCES quality_spec_version(id),
      ...
  );
  ```

---

## Auditability

- Add **`created_at`, `updated_at`, and `created_by`** columns to every table. In manufacturing, `updated_by` should also be captured.
- Store the **effective specification at time of production** via FK to the versioned spec record — never just a FK to the current/latest spec. If a recipe changes mid-run, the historical record must be unambiguous.
- Timestamp precision should be `DATETIME2(3)` minimum. Millisecond-level resolution is relevant for cycle time measurement, event sequencing, and alarm correlation.

---

## Audit Log Description Convention

Every audit-writing proc — every `EXEC Audit.Audit_LogConfigChange` call site — emits a human-readable narrative `Description` and resolved-name `OldValue` / `NewValue` JSON. Convention is project-wide; new procs inherit it; existing procs migrate as touched.

Full design + per-category catalog: `docs/superpowers/specs/2026-05-28-audit-readability-refactor-design.md`.

### Description shape

```
<SUBJECT> · <CATEGORY?> · <ACTION>
```

- **Subject** — the human-readable thing being changed (PartNumber + Description, Code + Name, Location Code + Name, etc.) resolved at write time from the row's FK references.
- **Category** — sub-area being changed. Only present for compound editors (Item Master sub-sections: Identity / Container Config / Routes / BOMs / Quality Specs / Eligibility). Atomic entities (Downtime Code, Defect Code, Location) omit it — their Subject already conveys the category.
- **Action** — what specifically happened. Multi-change actions concatenated with `; `.

Separator is the middle dot `·` (U+00B7). **Use `Audit.ufn_MidDot()` rather than `NCHAR(183)` literal** — keeps separator consistent across procs and dodges sqlcmd-codepage round-trip mangling.

### Verb / symbol vocabulary

| Form | Symbol | When to use |
|---|---|---|
| Added | `+` | Inline within multi-change Action prose: `+DIECAST; -DC-401` |
| Removed | `-` | Inline within multi-change Action prose |
| Updated | `~` | Inline within multi-change Action prose |
| Created | (verb) | Single-state transition (new entity itself): `5G0 — Front Cover (Component) · Created` |
| Deprecated | (verb) | Single-state transition (entity soft-deleted) |
| Published | (verb) | Versioned-entity Draft → Published transition |
| Reordered | (verb) | `SortOrder` change |
| Moved | (verb) | `ParentLocationId` / parent change |

### Field-diff notation

Inline field changes use `Field old→new`:

```
~DC-501 IsConsumptionPoint false→true
~5G0 Description "Old desc" → "New desc"
~CASTING qty 1 → 2
```

- Bare scalars unquoted (`false→true`, `1 → 2`).
- Strings quoted with `"..."`.
- `NULL` rendered as literal `null` (unquoted).
- Multi-field diffs comma-separated: `IsConsumptionPoint false→true, MinQuantity null→0`.

### Truncation + readability rules

Large change sets degrade gracefully:

| Rule | Threshold | Behavior |
|---|---|---|
| Per-operation specifics cap | 3 specifics | Show 3, then `+N more` (or `-N more` / `~N more` per op) |
| Operation order | always | Adds first, then Updates, then Removes |
| Total Description cap | 500 chars | `Audit.ufn_TruncateActivity(@text)` applies the cap with `…` (U+2026) suffix |
| Bundled-save trailer | always | Append `; <N> rows` or `; <N> lines` so the reader sees the total even when ops are summarized |

The truncation only affects the at-a-glance `Description` cell on the AuditLog table. The full diff lives in `OldValue` / `NewValue` JSON, never truncated, surfaced via the `ConfigChangeDetail` popup on row click.

### `OldValue` / `NewValue` JSON: resolved-name FKs

Every FK in the JSON expands from bare-ID to a named tuple:

| Column | Old shape | New shape |
|---|---|---|
| `LocationId: 3` | `3` | `{Id: 3, Code: "DIECAST", Name: "Die Cast"}` |
| `ItemId: 1` | `1` | `{Id: 1, PartNumber: "5G0", Description: "Front Cover Assembly"}` |
| `UomId: 1` | `1` | `{Id: 1, Code: "EA", Name: "Each"}` |
| `AppUserId: 5` | `5` | `{Id: 5, Initials: "JPGS", DisplayName: "Jacques Potgieter"}` |

Scalar columns (BIT, INT, NVARCHAR, DATETIME2) stay scalars — only FKs expand.

Implementation pattern: subquery-as-property-value via `FOR JSON PATH`:

```sql
SET @NewValue = (
    SELECT
        il.Id,
        (SELECT l.Id, l.Code, l.Name FROM Location.Location l WHERE l.Id = il.LocationId
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)   AS Location,
        il.IsConsumptionPoint,
        il.MinQuantity, il.MaxQuantity, il.DefaultQuantity
    FROM @Incoming il
    -- ...
    FOR JSON PATH
);
```

Cost is paid once per write, not once per read. Audit rows stay stable across later renames / deprecations — the names are frozen at write time.

### Why this matters

- **No DB JOINs at read time.** The AuditLog UI and the `ConfigChangeDetail` popup never JOIN to `Parts.Item` / `Location.Location` / etc. to render a row.
- **Stable across deprecation.** If a Location is later renamed or deprecated, the audit row still shows the name as it was when the change happened.
- **One-line readable narratives.** `5G0 — Front Cover Assembly · Eligibility · +DIECAST; -DC-401; 4 rows` reads as a sentence; bare-ID JSON does not.

### Reference

- Per-category Description catalog with worked examples for every existing audit surface: spec §5
- Auditor user flow (scan → click → popup): spec §6.3
- Backport plan + effort per slice: spec §8
- Implementation plan: `docs/superpowers/plans/2026-05-28-audit-readability-refactor.md`

---

## ISA-95 / MES Schema Considerations

- **Model equipment hierarchy separately from production order hierarchy** — they evolve independently. A line reconfiguration should not require restructuring your work order history.
- The ISA-95 hierarchy (`Enterprise → Site → Area → Work Center → Work Unit`) maps naturally to normalized FK-linked tables. Maintain this hierarchy explicitly; don't flatten it prematurely.
- **Genealogy (track and trace) is a graph problem in relational clothing.** Model it deliberately:

  | Approach | Best For |
  |---|---|
  | Adjacency list (parent FK) | Standard case; traverse with recursive CTEs |
  | Closure table | Fast traversal reads, higher write complexity |
  | Nested sets | Read-heavy, infrequent structural changes |

  For most MES implementations, **adjacency list + recursive CTEs** is the right starting point — it is standard SQL, maintainable, and sufficient for automotive traceability query patterns.

- **Specification-driven quality schemas** (as described above under Soft Deletes) handle the variable-attribute problem in manufacturing without resorting to EAV.

---

## Time-Sensitive & Process Data

- **Tag historian data belongs in a purpose-built historian**, not in a relational table. In Ignition-based systems, the built-in historian handles tag value storage. Do not replicate historian data into your MES SQL layer — query it via the Ignition Tag Historian tables or Reporting module when needed.
- For **time-sensitive transactional data that lives outside the historian** (cycle time records, OEE event logs, alarm/downtime events, batch phase transitions), store at millisecond precision and index on timestamp + equipment FK. Keep these tables lean — archive aggressively on a rolling window if volume demands it.
- **Event records are append-only by nature** — model them that way. A downtime event has a `started_at` and a `ended_at`; updates to an open event update `ended_at` only. Never overwrite historical event start times.

---

## OLTP vs. Analytical Separation

Transactional and analytical workloads have opposing design goals. Serving both from one schema is the root of most MES reporting performance problems.

```
ISA-95 Normalized Core (OLTP — MES transactions, genealogy, quality)
        ↓  [scheduled ETL, dbt, or triggered materialization]
   Flat Reporting Layer (OEE tables, shift summaries, quality roll-ups)
        ↓
   BI / Reporting Consumers (Ignition Reporting, Power BI, Sepasoft)
```

- OEE is the canonical example: computing Availability × Performance × Quality from normalized production, downtime, and quality event tables in real time is expensive. Materialize on a shift or hourly boundary.
- The flat reporting layer is not a design compromise — it is **OLTP/OLAP separation applied to the shop floor**, and it is correct architecture.
- Treat the materialized layer as a derivative: it is never the system of record. The normalized core is.

---

## Security

- Apply **least-privilege** access — MES application service accounts need only the permissions required (`SELECT`, `INSERT`, `UPDATE` on specific tables). No `DBA` or `db_owner` for application accounts.
- Never store plaintext passwords. Hash and salt at the application layer.
- Parameterize all queries. String-concatenated SQL in Ignition scripts is a vulnerability, not a convenience.

---

## Version Control & Migration

- Treat schema changes as code — use a migration tool (Flyway, Liquibase, EF Core Migrations) and commit migrations to source control.
- Never apply ad-hoc schema changes directly in production. All changes go through a tested, reviewed migration path.
- In manufacturing, coordinate schema migrations with production schedules. A migration that locks a table mid-shift is a downtime event.

---

## Summary: MES-Specific Additions to Standard Best Practices

| Concern | Guidance |
|---|---|
| Spec versioning | Soft-delete pattern; production FKs point to version active at run time |
| Historian / tag data | Use Ignition historian; do not replicate into relational MES tables |
| Time-sensitive transactional data | `DATETIME2(3)` minimum; append-only event records; index on timestamp + equipment |
| Genealogy / traceability | Adjacency list + recursive CTEs as default; escalate to closure table if traversal performance demands it |
| Variable quality attributes | Specification-driven schema preferred over EAV; JSONB if on PostgreSQL |
| Reporting performance | Materialized flat layer above ISA-95 normalized core; never serve OLTP and OLAP from one schema |
| Audit / regulatory | Soft deletes minimum; append-only invalidation for FDA contexts; `created_by` / `updated_by` on all tables |
| Equipment hierarchy | Model independently from production order hierarchy |
| UOM | First-class column on every quantitative measurement |
| Status fields | Code-table backed with FK; no magic integers or free-text |
