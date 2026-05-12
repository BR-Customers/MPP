'use strict';

const MiniSearch = require('minisearch');

const HEADING_RE = /<h([23])\s+id="([^"]+)"[^>]*>([\s\S]*?)<\/h\1>/g;
const FDS_RE = /<a[^>]+id="(fds-\d{2}-\d{3})"/;
const SCOPE_RE = /<span class="scope-pill scope-([a-z-]+)"/;

function buildSearchIndex(renderedDocs) {
  const docs = [];
  for (const d of renderedDocs) {
    HEADING_RE.lastIndex = 0;
    const sections = [];
    let m;
    while ((m = HEADING_RE.exec(d.html)) !== null) {
      sections.push({ level: Number(m[1]), id: m[2], titleHtml: m[3], offset: m.index });
    }
    for (let i = 0; i < sections.length; i++) {
      const s = sections[i];
      const nextOffset = i + 1 < sections.length ? sections[i + 1].offset : d.html.length;
      const slice = d.html.slice(s.offset, nextOffset);
      const titleText = s.titleHtml
        .replace(/<span class="scope-pill[^"]*"[^>]*>[\s\S]*?<\/span>/g, '')
        .replace(/<a[^>]*class="heading-permalink"[^>]*>[\s\S]*?<\/a>/g, '')
        .replace(/<[^>]+>/g, '')
        .replace(/\s+/g, ' ')
        .trim();
      const bodyText = slice.replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();
      const scopeMatch = SCOPE_RE.exec(s.titleHtml);
      const fdsMatch = FDS_RE.exec(slice);
      docs.push({
        id: `${d.key}.html#${s.id}`,
        doc: d.key,
        title: titleText,
        requirementId: fdsMatch ? fdsMatch[1].toUpperCase() : '',
        scope: scopeMatch ? scopeMatch[1].toUpperCase().replace(/-/g, '-') : '',
        body: bodyText.slice(0, 2000),
      });
    }
  }

  const ms = new MiniSearch({
    fields: ['title', 'requirementId', 'body'],
    storeFields: ['id', 'doc', 'title', 'requirementId', 'scope'],
    searchOptions: {
      boost: { title: 5, requirementId: 8 },
      prefix: true,
      fuzzy: 0.15,
    },
  });
  ms.addAll(docs);

  return {
    docs,
    payload: {
      docs,
      index: JSON.parse(JSON.stringify(ms.toJSON())),
      options: {
        fields: ['title', 'requirementId', 'body'],
        storeFields: ['id', 'doc', 'title', 'requirementId', 'scope'],
      },
    },
  };
}

module.exports = { buildSearchIndex };
