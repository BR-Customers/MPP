const SCHEMAS = ['Location', 'Parts', 'Lots', 'Workorder', 'Quality', 'Oee', 'Tools', 'Audit'];

function parseDmTables(markdown) {
  const lines = markdown.split(/\r?\n/);
  const result = new Map();        // "Schema.Table" -> anchor slug
  let currentSchema = null;
  for (const line of lines) {
    const h2 = /^##\s+\d+\.\s+(\w+)\s+Schema/i.exec(line);
    if (h2) {
      const schema = SCHEMAS.find((s) => s.toLowerCase() === h2[1].toLowerCase());
      if (schema) currentSchema = schema;
      continue;
    }
    if (!currentSchema) continue;
    const h3 = /^###\s+([A-Za-z][A-Za-z0-9_]*)\s*$/.exec(line.replace(/<.+$/, '').trim());
    if (!h3) continue;
    const table = h3[1];
    const key = `${currentSchema}.${table}`;
    if (!result.has(key)) result.set(key, `${currentSchema.toLowerCase()}-${table.toLowerCase()}`);
  }
  return result;
}

module.exports = { parseDmTables, SCHEMAS };
