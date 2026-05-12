const { SCHEMAS } = require('../lib/parse_dm_tables');

module.exports = function schemaTableAnchor(md, opts = {}) {
  const knownTables = opts.knownTables || new Map();
  const installer = (state) => {
    let currentSchema = null;
    for (let i = 0; i < state.tokens.length; i++) {
      const tok = state.tokens[i];
      if (tok.type !== 'heading_open') continue;
      const inline = state.tokens[i + 1];
      if (!inline || inline.type !== 'inline') continue;
      const text = inline.content.replace(/<[^>]+>/g, '').trim();

      if (tok.tag === 'h2') {
        const m = /^\d+\.\s+(\w+)\s+Schema/i.exec(text);
        if (m) {
          const schema = SCHEMAS.find((s) => s.toLowerCase() === m[1].toLowerCase());
          currentSchema = schema || null;
        } else if (/^[\d.]+\s/.test(text)) {
          currentSchema = null;          // numbered non-schema section
        }
        continue;
      }
      if (tok.tag !== 'h3' || !currentSchema) continue;

      const tableName = (text.match(/^([A-Za-z][A-Za-z0-9_]*)/) || [])[1];
      if (!tableName) continue;
      const key = `${currentSchema}.${tableName}`;
      const slug = knownTables.get(key);
      if (!slug) continue;
      tok.attrSet('id', slug);

      // Also re-point the permalink anchor (added by heading_permalinks) to the new slug.
      if (inline.children) {
        const last = inline.children[inline.children.length - 1];
        if (last && last.type === 'html_inline' && /class="heading-permalink"/.test(last.content)) {
          last.content = last.content.replace(/href="#[^"]+"/, `href="#${slug}"`);
        }
      }
    }
  };
  // Run AFTER heading_permalinks (which is core.ruler.push, runs last) — so we replace the id it set.
  try { md.core.ruler.after('heading_permalinks', 'schema_table_anchor', installer); }
  catch (_) { md.core.ruler.push('schema_table_anchor', installer); }
};
