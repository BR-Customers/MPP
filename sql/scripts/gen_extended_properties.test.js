"use strict";

const assert = require("assert");
const { parseDataModel, toAscii, emitSql } = require("./gen_extended_properties.js");

// ---------------------------------------------------------------------------
// parseDataModel
// ---------------------------------------------------------------------------

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
  "### ✅ Resolved (v1.8): something",
  "Not a table either.",
  "",
  "## 6. OEE Schema — `MVP`",
  "### Shift",
  "Shift definitions.",
  "| Column | Type | Constraints | Description |",
  "|---|---|---|---|",
  "| Name | NVARCHAR(50) | NOT NULL | Shift `label` |",
].join("\n");

const out = parseDataModel(MD);

assert.strictEqual(out.tables.length, 2, "Design Overview and the Resolved note are skipped");

const loc = out.tables[0];
assert.strictEqual(loc.schema, "Location");
assert.strictEqual(loc.table, "Location");
assert.strictEqual(loc.description, "Every node in the plant model.");
assert.strictEqual(loc.columns.length, 1, "columns with an empty description are dropped");
assert.strictEqual(loc.columns[0].name, "ParentLocationId");
assert.strictEqual(loc.columns[0].description, "Parent in hierarchy", "markdown stripped");

const shift = out.tables[1];
assert.strictEqual(shift.schema, "OEE");
assert.strictEqual(shift.table, "Shift");
assert.strictEqual(shift.columns[0].description, "Shift label");

console.log("parseDataModel: OK");

// ---------------------------------------------------------------------------
// toAscii
// ---------------------------------------------------------------------------

assert.strictEqual(toAscii("Cell — WorkCenter"), "Cell - WorkCenter");
assert.strictEqual(toAscii("FK → Location.Id"), "FK -> Location.Id");
assert.strictEqual(toAscii("a · b"), "a - b");
assert.strictEqual(toAscii("✅ Resolved"), "Resolved");
assert.strictEqual(toAscii("“quoted” and ‘single’"), '"quoted" and \'single\'');
assert.strictEqual(toAscii("≥ 5"), ">= 5");
assert.ok(!/[^\x00-\x7F]/.test(toAscii("Ω≈ç√∫˜µ")),
  "no byte above 0x7F survives");
assert.strictEqual(toAscii("  spaced   out  "), "spaced out");

console.log("toAscii: OK");

// ---------------------------------------------------------------------------
// emitSql
// ---------------------------------------------------------------------------

const sql = emitSql({
  tables: [{
    schema: "Location", table: "Location", description: "Every node.",
    columns: [{ name: "ParentLocationId", description: "Parent in hierarchy" }],
  }],
});

assert.ok(sql.includes("IF OBJECT_ID(N'[Location].[Location]', 'U') IS NOT NULL"),
  "table existence guard");
assert.ok(sql.includes("COL_LENGTH(N'[Location].[Location]', N'ParentLocationId')"),
  "column existence guard");
assert.ok(sql.includes("sp_addextendedproperty"), "add branch");
assert.ok(sql.includes("sp_updateextendedproperty"), "update branch");
assert.ok(sql.includes("@level2type = N'COLUMN'"), "column level");
assert.ok(!/[^\x00-\x7F]/.test(sql), "emitted SQL is pure ASCII");

const quoted = emitSql({
  tables: [{ schema: "S", table: "T", description: "the operator's badge", columns: [] }],
});
assert.ok(quoted.includes("the operator''s badge"), "single quotes are doubled");

const longDesc = emitSql({
  tables: [{ schema: "S", table: "T", description: "x ".repeat(2000), columns: [] }],
});
const literal = longDesc.match(/@value = N'([^']*(?:''[^']*)*)'/)[1];
assert.ok(literal.length <= 900, "long descriptions are capped, got " + literal.length);
assert.ok(literal.endsWith("..."), "capped descriptions are elided");

const empty = emitSql({
  tables: [{ schema: "S", table: "T", description: "", columns: [] }],
});
assert.ok(!empty.includes("[S].[T]"), "a table with nothing to say emits nothing");

console.log("emitSql: OK");
console.log("\nall assertions passed");
