# Extended-Property Descriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Push the table and column descriptions that already live in `MPP_MES_DATA_MODEL.md` into `sys.extended_properties` as `MS_Description`, so the database documents itself for SSMS, Ignition, and any schema tool pointed at it.

**Architecture:** A Node generator parses `MPP_MES_DATA_MODEL.md` — whose structure is already perfectly regular (`## N. <Schema> Schema` → `### <Table>` → a `| Column | Type | Constraints | Description |` table) — and emits a **repeatable** migration. Repeatables re-run on every `Reset-DevDatabase` and `Update-Prod`, so regenerating after a doc edit is the whole update path. The generated SQL guards every object with an existence check, so documented-but-not-yet-built tables are skipped rather than failing the deploy.

**Tech Stack:** Node 24 (matching `sql/seeds/gen_locations_mpp.js` precedent), T-SQL, sqlcmd.

## Global Constraints

- **ASCII-only output.** `sqlcmd` reads `.sql` files in the Windows codepage, so an em-dash or arrow becomes mojibake (`â€"`) in the database and then in Ignition. Every emitted string is transliterated to ASCII and byte-scanned before commit. (CLAUDE.md § Conventions → SQL design.)
- **Repeatable, idempotent.** `R__*.sql` re-runs unconditionally on every deploy. Each property is `sp_updateextendedproperty` when present, `sp_addextendedproperty` when not — never a bare add, which errors on the second run.
- **Existence-guarded.** `IF OBJECT_ID(N'<schema>.<table>', 'U') IS NOT NULL` around each table block; `IF COL_LENGTH(N'<schema>.<table>', N'<column>') IS NOT NULL` around each column. The doc describes `Quality.NonConformance`, which does not exist in the database.
- **`MS_Description` only.** No other property name, no other object class than `TABLE` / `COLUMN`.
- **Generated file is committed.** It is a build artifact, but the deploy scripts read from disk and Prod deploys must not require Node.
- Schema-name matching is **case-insensitive**: the doc writes `OEE`, the database schema is `Oee`.
- The generator never connects to a database. Drift is reported by a separate SQL verification step.

---

## Baseline facts (measured 2026-09-03)

| Fact | Value |
|---|---|
| `MS_Description` rows in `MPP_MES_Dev` today | **0** |
| Table sections parsed from the doc | 90 |
| Column rows parsed from the doc | 752 |
| Tables in `MPP_MES_Dev` | 104 |
| Columns in `MPP_MES_Dev` | 821 |
| Doc tables absent from the DB (after case-folding `OEE`→`Oee`) | 1 — `Quality.NonConformance` |
| DB tables absent from the doc | 15, plus `dbo.SchemaVersion` and 2 `test.*` (excluded by design) |

Undocumented DB tables, for the drift report: `Audit.PartitionRetention`,
`Location.PlcDeviceType`, `Location.PrinterFgAssignment`, `Location.SessionPolicy`,
`Location.TerminalPlcDevice`, `Lots.ContainerSerialHistory`, `Lots.LabelTemplate`,
`Lots.LotEventLog`, `Lots.LotGenealogyClosure`, `Oee.ShiftOverride`,
`Parts.ClosureMethodCode`, `Parts.DataCollectionFieldDataType`, `Quality.ChargeToParty`.

---

## File Structure

| File | Responsibility |
|---|---|
| `sql/scripts/gen_extended_properties.js` | Parse the markdown, transliterate, emit SQL, print doc-side stats. Pure — no DB. |
| `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql` | **Generated.** Guarded, idempotent `MS_Description` writes. |
| `sql/tests/03_appuser/…` *(no change)* | — |
| `sql/tests/09_metadata/090_ExtendedProperties.sql` | Asserts the properties actually landed and are ASCII. |
| `notes/2026-09-03_data-model-doc-drift.md` | The drift report — doc↔DB gaps, for follow-up. |

---

### Task 1: The markdown parser

**Files:**
- Create: `sql/scripts/gen_extended_properties.js`

**Interfaces:**
- Produces: `parseDataModel(markdownText) -> { tables: [{schema, table, description, columns: [{name, description}]}], warnings: [string] }`

The doc's shape, verified against all 90 sections:

```
## 1. Location Schema — `MVP`          <- schema context
### Location                            <- table
Every node in the plant model ...       <- table description (first prose paragraph)
| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |                  <- column, empty description
| ParentLocationId | BIGINT | FK -> Location.Id, NULL | Parent in hierarchy |
```

Rules the parser must implement:
- A `### ` heading is a table only if it matches `^[A-Za-z][A-Za-z0-9_]*$`. Sections such as `### Design Overview`, `### Terminals in the New Model`, and `### ✅ Resolved (v1.8 rev...)` are prose and must be skipped.
- The table description is the first non-empty, non-blockquote, non-table line after the heading. Stop at the first `|` row or the next heading.
- Column rows are `|`-delimited with 4 cells; skip the header row (`| Column |`) and the separator (`|---|`).
- Markdown inside a description is stripped: `**bold**`, `` `code` ``, `[text](link)`.
- An empty description yields no property — do not write an empty `MS_Description`.

- [ ] **Step 1: Write the failing test**

```js
// sql/scripts/gen_extended_properties.test.js
const assert = require("assert");
const { parseDataModel } = require("./gen_extended_properties.js");

const MD = [
  "## 1. Location Schema — `MVP`",
  "### Design Overview",
  "Prose that is not a table.",
  "### Location",
  "Every node in the plant model.",
  "",
  "| Column | Type | Constraints | Description |",
  "|---|---|---|---|",
  "| Id | BIGINT | PK | |",
  "| ParentLocationId | BIGINT | FK, NULL | Parent in **hierarchy** |",
  "",
  "## 6. OEE Schema — `MVP`",
  "### Shift",
  "Shift definitions.",
  "| Column | Type | Constraints | Description |",
  "|---|---|---|---|",
  "| Name | NVARCHAR(50) | NOT NULL | Shift `label` |",
].join("\n");

const out = parseDataModel(MD);

assert.strictEqual(out.tables.length, 2, "two tables, Design Overview skipped");

const loc = out.tables[0];
assert.strictEqual(loc.schema, "Location");
assert.strictEqual(loc.table, "Location");
assert.strictEqual(loc.description, "Every node in the plant model.");
assert.strictEqual(loc.columns.length, 1, "empty descriptions are dropped");
assert.strictEqual(loc.columns[0].name, "ParentLocationId");
assert.strictEqual(loc.columns[0].description, "Parent in hierarchy", "markdown stripped");

const shift = out.tables[1];
assert.strictEqual(shift.schema, "OEE");
assert.strictEqual(shift.columns[0].description, "Shift label");

console.log("parseDataModel: all assertions passed");
```

- [ ] **Step 2: Run it, confirm it fails**

Run: `node sql/scripts/gen_extended_properties.test.js`
Expected: FAIL — `Cannot find module './gen_extended_properties.js'`

- [ ] **Step 3: Implement the parser half of the generator**

Export `parseDataModel` and guard the CLI entry point with `if (require.main === module)` so the test can import without running the generator.

- [ ] **Step 4: Run the test, then parse the real document**

Run: `node sql/scripts/gen_extended_properties.test.js` → all assertions pass
Run: `node sql/scripts/gen_extended_properties.js --stats`
Expected: `90 tables, 752 column rows` with a non-zero count of non-empty descriptions.

- [ ] **Step 5: Commit**

```bash
git add sql/scripts/gen_extended_properties.js sql/scripts/gen_extended_properties.test.js
git commit -m "feat(sql): parse table and column descriptions from the data model doc"
```

---

### Task 2: ASCII transliteration

**Files:**
- Modify: `sql/scripts/gen_extended_properties.js`

**Interfaces:**
- Produces: `toAscii(text) -> string` — lossy but readable; guarantees every output byte is < 0x80.

The doc is full of characters that `sqlcmd` will mangle: `—` (em dash), `→` (arrow),
`·` (middle dot), `✅`, `⚠`, `≥`, curly quotes. CLAUDE.md is explicit that seed and
ZPL strings are ASCII-only for exactly this reason.

- [ ] **Step 1: Write the failing test**

Append to `gen_extended_properties.test.js`:

```js
const { toAscii } = require("./gen_extended_properties.js");

assert.strictEqual(toAscii("Cell — WorkCenter"), "Cell - WorkCenter");
assert.strictEqual(toAscii("FK → Location.Id"), "FK -> Location.Id");
assert.strictEqual(toAscii("a · b"), "a - b");
assert.strictEqual(toAscii("✅ Resolved"), "Resolved");
assert.strictEqual(toAscii("“quoted” and ‘single’"), '"quoted" and \'single\'');
assert.strictEqual(toAscii("≥ 5"), ">= 5");
assert.ok(!/[^\x00-\x7F]/.test(toAscii("Ω≈ç√∫˜µ")), "no byte above 0x7F survives");
console.log("toAscii: all assertions passed");
```

- [ ] **Step 2: Run, confirm failure** — `toAscii is not a function`.

- [ ] **Step 3: Implement**

```js
const ASCII_MAP = {
  "—": "-", "–": "-", "−": "-",     // em/en dash, minus
  "·": "-", "•": "-",                     // middle dot, bullet
  "→": "->", "←": "<-", "⇒": "=>",
  "“": '"', "”": '"', "„": '"',
  "‘": "'", "’": "'",
  "…": "...", " ": " ",
  "≥": ">=", "≤": "<=", "≠": "!=", "×": "x",
  "✅": "", "⚠": "", "❌": "", "✓": "",
};

function toAscii(text) {
  let out = String(text == null ? "" : text);
  for (const [from, to] of Object.entries(ASCII_MAP)) {
    out = out.split(from).join(to);
  }
  // Strip anything still non-ASCII rather than letting sqlcmd mangle it.
  out = out.normalize("NFKD").replace(/[^\x20-\x7E]/g, "");
  return out.replace(/\s+/g, " ").trim();
}
```

- [ ] **Step 4: Run the test** → all assertions pass

- [ ] **Step 5: Commit**

```bash
git add sql/scripts/gen_extended_properties.js sql/scripts/gen_extended_properties.test.js
git commit -m "feat(sql): ASCII transliteration for extended-property text"
```

---

### Task 3: Emit the repeatable migration

**Files:**
- Modify: `sql/scripts/gen_extended_properties.js`
- Create (generated): `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql`

**Interfaces:**
- Produces: `emitSql(parsed) -> string`

Shape of each emitted block — the `EXISTS` check is what makes it repeatable, and the
`OBJECT_ID` / `COL_LENGTH` guards are what let the doc describe things the schema does
not have yet:

```sql
IF OBJECT_ID(N'[Location].[Location]', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID(N'[Location].[Location]')
                 AND minor_id = 0 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty
             @name = N'MS_Description', @value = N'Every node in the plant model.',
             @level0type = N'SCHEMA', @level0name = N'Location',
             @level1type = N'TABLE',  @level1name = N'Location';
    ELSE
        EXEC sys.sp_addextendedproperty
             @name = N'MS_Description', @value = N'Every node in the plant model.',
             @level0type = N'SCHEMA', @level0name = N'Location',
             @level1type = N'TABLE',  @level1name = N'Location';

    IF COL_LENGTH(N'[Location].[Location]', N'ParentLocationId') IS NOT NULL
    BEGIN
        ...same add/update pair with @level2type = N'COLUMN'...
    END
END
GO
```

- [ ] **Step 1: Write the failing test**

```js
const { emitSql } = require("./gen_extended_properties.js");

const sql = emitSql({ tables: [{
  schema: "Location", table: "Location", description: "Every node.",
  columns: [{ name: "ParentLocationId", description: "Parent in hierarchy" }],
}]});

assert.ok(sql.includes("IF OBJECT_ID(N'[Location].[Location]', 'U') IS NOT NULL"));
assert.ok(sql.includes("COL_LENGTH(N'[Location].[Location]', N'ParentLocationId')"));
assert.ok(sql.includes("sp_addextendedproperty"));
assert.ok(sql.includes("sp_updateextendedproperty"));
assert.ok(!/[^\x00-\x7F]/.test(sql), "emitted SQL is pure ASCII");

// A single quote in a description must not break out of the literal.
const quoted = emitSql({ tables: [{
  schema: "S", table: "T", description: "the operator's badge", columns: [],
}]});
assert.ok(quoted.includes("the operator''s badge"), "single quotes doubled");
console.log("emitSql: all assertions passed");
```

- [ ] **Step 2: Run, confirm failure** — `emitSql is not a function`.

- [ ] **Step 3: Implement `emitSql` and the CLI**

Escape by doubling `'`. Cap each description at 900 characters with a trailing `...`
(the `CoupledDownstreamCellLocationId` description is several thousand characters of
design rationale; `sql_variant` accepts up to 7500 bytes but a paragraph is not a
tooltip). Write a file header matching the repo's migration-header convention.

- [ ] **Step 4: Generate, byte-scan, and apply**

Run: `node sql/scripts/gen_extended_properties.js`
Run: `python -c "d=open(r'sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql','rb').read(); bad=[b for b in d if b>127]; print('non-ascii bytes:', len(bad))"`
Expected: `non-ascii bytes: 0`

Run: `sqlcmd -S localhost -d MPP_MES_Dev -C -I -b -i sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql`
Expected: exit 0, no errors.

Run it a **second time** — expected: exit 0, no errors (proves idempotence).

- [ ] **Step 5: Verify the properties landed**

```sql
SELECT COUNT(*) AS TableDescriptions
FROM sys.extended_properties WHERE name = 'MS_Description' AND minor_id = 0;
SELECT COUNT(*) AS ColumnDescriptions
FROM sys.extended_properties WHERE name = 'MS_Description' AND minor_id > 0;
```
Expected: ~89 table descriptions (90 doc tables less `Quality.NonConformance`) and several hundred column descriptions.

- [ ] **Step 6: Commit**

```bash
git add sql/scripts/gen_extended_properties.js sql/scripts/gen_extended_properties.test.js sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql
git commit -m "feat(sql): generate MS_Description extended properties from the data model doc"
```

---

### Task 4: Drift report and a regression test

**Files:**
- Create: `sql/tests/09_metadata/090_ExtendedProperties.sql`, `notes/2026-09-03_data-model-doc-drift.md`

**Interfaces:**
- Consumes: the applied extended properties from Task 3.

- [ ] **Step 1: Write the test**

Follow the existing `sql/tests/` conventions (see `sql/tests/03_appuser/046_AppUser_Pin_lookups.sql` for the assertion style). Assert:
1. At least 80 table-level `MS_Description` rows exist.
2. At least 300 column-level rows exist.
3. No `MS_Description` value contains a byte above 0x7F —
   `WHERE CAST(value AS NVARCHAR(MAX)) COLLATE Latin1_General_BIN2 LIKE '%[^ -~]%'` returns zero rows.
4. `Location.AppUser.Pin` carries a description mentioning leading zeros — a canary
   proving the highest-value documentation actually made the trip.

- [ ] **Step 2: Run the suite**

Run: `powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test`
Expected: all tests pass, exit 0.

- [ ] **Step 3: Write the drift report**

`notes/2026-09-03_data-model-doc-drift.md` records the two gaps found while building
this, so they become real follow-ups rather than a footnote:
- 15 DB tables with no `###` section in `MPP_MES_DATA_MODEL.md` (listed above).
- 1 doc table with no DB object: `Quality.NonConformance`.
- The `OEE` vs `Oee` heading-case mismatch, now handled case-insensitively but worth
  fixing at the source.

- [ ] **Step 4: Regenerate the ERD and confirm the payoff**

Run SchemaGen against `MPP_MES_Dev`. Expected: the header's comment count goes from 0
to several hundred, and every schema tab's Documentation section is populated.

- [ ] **Step 5: Commit**

```bash
git add sql/tests/09_metadata/090_ExtendedProperties.sql notes/2026-09-03_data-model-doc-drift.md
git commit -m "test(sql): assert extended-property coverage; record data model doc drift"
```
