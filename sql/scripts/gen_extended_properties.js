#!/usr/bin/env node
/**
 * Generate MS_Description extended properties from MPP_MES_DATA_MODEL.md.
 *
 * The data model document is the source of truth for what every table and
 * column means. None of that reaches the database, so SSMS, Ignition, and any
 * schema tool pointed at MPP_MES_Dev sees an undocumented schema. This script
 * lifts the prose into sys.extended_properties.
 *
 * Output is a REPEATABLE migration: repeatables re-run unconditionally on
 * every Reset-DevDatabase and Update-Prod, so regenerating after a doc edit is
 * the entire update path. Each property is add-or-update, and every object is
 * existence-guarded, so a table the document describes but the schema does not
 * have yet (Quality.NonConformance) is skipped rather than failing the deploy.
 *
 * Usage:
 *   node sql/scripts/gen_extended_properties.js            # write the migration
 *   node sql/scripts/gen_extended_properties.js --stats    # parse only, report
 *
 * ASCII-only by construction: sqlcmd reads .sql files in the Windows codepage,
 * so an em-dash or arrow becomes mojibake in the database and then in Ignition.
 */

"use strict";

const fs = require("fs");
const path = require("path");

const REPO_ROOT = path.resolve(__dirname, "..", "..");
const DOC_PATH = path.join(REPO_ROOT, "MPP_MES_DATA_MODEL.md");
const OUT_PATH = path.join(
  REPO_ROOT, "sql", "migrations", "repeatable",
  "R__Descriptions_ExtendedProperties.sql"
);

/** Descriptions are documentation, not essays. Long design rationale stays in the doc. */
const MAX_DESCRIPTION = 900;

// ---------------------------------------------------------------------------
// ASCII transliteration
// ---------------------------------------------------------------------------

const ASCII_MAP = {
  "—": "-",   // em dash
  "–": "-",   // en dash
  "−": "-",   // minus sign
  "·": "-",   // middle dot
  "•": "-",   // bullet
  "→": "->",  // rightwards arrow
  "←": "<-",
  "⇒": "=>",
  "“": '"',
  "”": '"',
  "„": '"',
  "‘": "'",
  "’": "'",
  "…": "...",
  " ": " ",   // non-breaking space
  "≥": ">=",
  "≤": "<=",
  "≠": "!=",
  "×": "x",
  "✅": "",    // white heavy check mark
  "⚠": "",    // warning sign
  "❌": "",    // cross mark
  "✓": "",    // check mark
  "️": "",    // variation selector
};

function toAscii(text) {
  let out = String(text === null || text === undefined ? "" : text);
  for (const from of Object.keys(ASCII_MAP)) {
    out = out.split(from).join(ASCII_MAP[from]);
  }
  // Decompose accents to letter + combining mark, then drop anything still
  // outside printable ASCII rather than letting sqlcmd mangle it.
  out = out.normalize("NFKD").replace(/[^\x20-\x7E]/g, "");
  return out.replace(/\s+/g, " ").trim();
}

// ---------------------------------------------------------------------------
// Markdown parsing
// ---------------------------------------------------------------------------

const SCHEMA_HEADING = /^##\s+\d+\.\s+([A-Za-z][A-Za-z0-9_]*)\s+Schema/;
const TABLE_HEADING = /^###\s+(.+?)\s*$/;
const IDENTIFIER = /^[A-Za-z][A-Za-z0-9_]*$/;
const COLUMN_SEPARATOR = /^\|[\s:|-]+\|$/;

/** Strip inline markdown so a description reads as plain prose. */
function stripMarkdown(text) {
  return String(text || "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")   // [label](link) -> label
    .replace(/\*\*([^*]+)\*\*/g, "$1")          // bold
    .replace(/(^|[^*])\*([^*]+)\*/g, "$1$2")    // italic
    .replace(/`([^`]*)`/g, "$1")                // code
    .replace(/<[^>]+>/g, "")                    // stray html
    .trim();
}

function parseDataModel(markdownText) {
  const lines = String(markdownText).split(/\r?\n/);
  const tables = [];
  const warnings = [];

  let schema = null;
  let current = null;
  let inColumnTable = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    const schemaMatch = line.match(SCHEMA_HEADING);
    if (schemaMatch) {
      schema = schemaMatch[1];
      current = null;
      inColumnTable = false;
      continue;
    }

    const headingMatch = line.match(TABLE_HEADING);
    if (headingMatch) {
      inColumnTable = false;
      const name = headingMatch[1].trim();
      // Only a bare identifier is a table. "Design Overview", "Terminals in
      // the New Model" and the "Resolved (v1.8)" notes are prose sections.
      if (schema && IDENTIFIER.test(name)) {
        current = { schema, table: name, description: "", columns: [], line: i + 1 };
        tables.push(current);
      } else {
        current = null;
      }
      continue;
    }

    if (!current) continue;

    const trimmed = line.trim();

    // Column table rows
    if (trimmed.startsWith("|")) {
      if (COLUMN_SEPARATOR.test(trimmed)) continue;
      const cells = trimmed.split("|").slice(1, -1).map((c) => c.trim());
      if (cells.length < 4) continue;
      if (/^column$/i.test(cells[0])) {
        inColumnTable = true;
        continue;
      }
      if (!inColumnTable) continue;
      const name = cells[0].replace(/[`*]/g, "").trim();
      if (!IDENTIFIER.test(name)) continue;
      const description = toAscii(stripMarkdown(cells[3]));
      if (description) {
        current.columns.push({ name, description });
      }
      continue;
    }

    // The table description is the first prose paragraph after the heading.
    if (!current.description && trimmed && !trimmed.startsWith(">")
        && !trimmed.startsWith("#") && !trimmed.startsWith("|")) {
      current.description = toAscii(stripMarkdown(trimmed));
    }
  }

  for (const t of tables) {
    if (!t.description && t.columns.length === 0) {
      warnings.push(`${t.schema}.${t.table} (line ${t.line}): no description and no columns`);
    }
  }

  return { tables, warnings };
}

// ---------------------------------------------------------------------------
// SQL emission
// ---------------------------------------------------------------------------

function sqlLiteral(text) {
  let value = toAscii(text);
  if (value.length > MAX_DESCRIPTION) {
    value = value.slice(0, MAX_DESCRIPTION - 3).replace(/\s+\S*$/, "") + "...";
  }
  return "N'" + value.replace(/'/g, "''") + "'";
}

function propertyBlock(indent, value, schema, table, column) {
  const pad = " ".repeat(indent);
  const level2 = column
    ? `,\n${pad}                 @level2type = N'COLUMN', @level2name = N'${column}'`
    : "";
  const minor = column ? `COLUMNPROPERTY(OBJECT_ID(N'[${schema}].[${table}]'), N'${column}', 'ColumnId')` : "0";
  const args =
    `@name = N'MS_Description', @value = ${value},\n` +
    `${pad}                 @level0type = N'SCHEMA', @level0name = N'${schema}',\n` +
    `${pad}                 @level1type = N'TABLE',  @level1name = N'${table}'${level2}`;

  return (
    `${pad}IF EXISTS (SELECT 1 FROM sys.extended_properties\n` +
    `${pad}           WHERE major_id = OBJECT_ID(N'[${schema}].[${table}]')\n` +
    `${pad}             AND minor_id = ${minor}\n` +
    `${pad}             AND name = N'MS_Description')\n` +
    `${pad}    EXEC sys.sp_updateextendedproperty ${args};\n` +
    `${pad}ELSE\n` +
    `${pad}    EXEC sys.sp_addextendedproperty ${args};\n`
  );
}

function emitSql(parsed) {
  const out = [];
  out.push("-- ============================================================");
  out.push("-- Repeatable:  R__Descriptions_ExtendedProperties.sql");
  out.push("-- Author:      Blue Ridge Automation");
  out.push("-- Description: MS_Description extended properties for every table");
  out.push("--              and column documented in MPP_MES_DATA_MODEL.md.");
  out.push("--");
  out.push("--              GENERATED FILE -- DO NOT EDIT BY HAND.");
  out.push("--              Regenerate with:");
  out.push("--                  node sql/scripts/gen_extended_properties.js");
  out.push("--");
  out.push("--              Every object is existence-guarded, so a table the");
  out.push("--              document describes but the schema does not carry");
  out.push("--              yet is skipped instead of failing the deploy. Each");
  out.push("--              property is add-or-update, so re-running is a");
  out.push("--              no-op -- which is what makes it repeatable.");
  out.push("--");
  out.push("--              ASCII-only: sqlcmd reads .sql in the Windows");
  out.push("--              codepage, so non-ASCII text would land as mojibake.");
  out.push("-- ============================================================");
  out.push("SET NOCOUNT ON;");
  out.push("GO");
  out.push("");

  let tableCount = 0;
  let columnCount = 0;

  for (const t of parsed.tables) {
    const hasTableDesc = Boolean(t.description);
    if (!hasTableDesc && t.columns.length === 0) continue;

    const qualified = `[${t.schema}].[${t.table}]`;
    out.push(`-- ${t.schema}.${t.table}`);
    out.push(`IF OBJECT_ID(N'${qualified}', 'U') IS NOT NULL`);
    out.push("BEGIN");

    if (hasTableDesc) {
      out.push(propertyBlock(4, sqlLiteral(t.description), t.schema, t.table, null).trimEnd());
      tableCount++;
    }

    for (const col of t.columns) {
      out.push("");
      out.push(`    IF COL_LENGTH(N'${qualified}', N'${col.name}') IS NOT NULL`);
      out.push("    BEGIN");
      out.push(propertyBlock(8, sqlLiteral(col.description), t.schema, t.table, col.name).trimEnd());
      out.push("    END");
      columnCount++;
    }

    out.push("END");
    out.push("GO");
    out.push("");
  }

  out.push(`-- ${tableCount} table descriptions, ${columnCount} column descriptions`);
  out.push("");
  return out.join("\n");
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function main() {
  const markdown = fs.readFileSync(DOC_PATH, "utf8");
  const parsed = parseDataModel(markdown);

  const withDesc = parsed.tables.filter((t) => t.description).length;
  const columns = parsed.tables.reduce((sum, t) => sum + t.columns.length, 0);

  console.log(`Parsed ${DOC_PATH}`);
  console.log(`  table sections        : ${parsed.tables.length}`);
  console.log(`  with a description    : ${withDesc}`);
  console.log(`  column descriptions   : ${columns}`);
  for (const w of parsed.warnings) console.log(`  [warn] ${w}`);

  if (process.argv.includes("--stats")) return;

  const sql = emitSql(parsed);
  const nonAscii = Buffer.from(sql, "utf8").filter((b) => b > 127).length;
  if (nonAscii > 0) {
    console.error(`REFUSING TO WRITE: ${nonAscii} non-ASCII bytes in generated SQL`);
    process.exit(1);
  }

  fs.writeFileSync(OUT_PATH, sql, { encoding: "ascii" });
  console.log(`\nWrote ${OUT_PATH}`);
  console.log(`  ${(sql.length / 1024).toFixed(0)} KB, ASCII verified`);
}

module.exports = { parseDataModel, toAscii, emitSql, stripMarkdown };

if (require.main === module) main();
