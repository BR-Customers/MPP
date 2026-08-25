'use strict';

const MiniSearch = require('minisearch');

const HEADING_RE = /<h([23])\s+id="([^"]+)"[^>]*>([\s\S]*?)<\/h\1>/g;
const FDS_RE = /<a[^>]+id="(fds-\d{2}-\d{3})"/;
const SCOPE_RE = /<span class="scope-pill scope-([a-z-]+)"/;

// Stored fields are PLAIN TEXT: they are what MiniSearch tokenizes and what
// portal.js escapes before injecting. Stripping tags is not enough — the
// rendered HTML still carries entities (`&amp;`, `&lt;`, `&#39;`, …). Leaving
// them in double-escapes at render time (a heading "LOT Lifecycle & Genealogy"
// showed up in results as "LOT Lifecycle &amp; Genealogy") and pollutes the
// index with junk tokens like "amp". Decode after stripping, never before —
// decoding first would let entity-encoded angle brackets forge a tag.
const NAMED_ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
  hellip: '…', mdash: '—', ndash: '–', rsquo: '’',
  lsquo: '‘', ldquo: '“', rdquo: '”', middot: '·',
  rarr: '→', larr: '←', times: '×', deg: '°',
};

function decodeEntities(text) {
  return text.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, (whole, body) => {
    if (body[0] === '#') {
      const code = body[1] === 'x' || body[1] === 'X'
        ? parseInt(body.slice(2), 16)
        : parseInt(body.slice(1), 10);
      // Reject non-characters and anything outside the Unicode range.
      if (!Number.isFinite(code) || code < 0x20 || code > 0x10ffff) return whole;
      return String.fromCodePoint(code);
    }
    const named = NAMED_ENTITIES[body.toLowerCase()];
    return named === undefined ? whole : named;
  });
}

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
      const titleHtmlStripped = s.titleHtml
        .replace(/<span class="scope-pill[^"]*"[^>]*>[\s\S]*?<\/span>/g, '')
        .replace(/<a[^>]*class="heading-permalink"[^>]*>[\s\S]*?<\/a>/g, '')
        .replace(/<[^>]+>/g, '');
      const titleText = decodeEntities(titleHtmlStripped)
        .replace(/\s+/g, ' ')
        .trim();
      const bodyText = decodeEntities(slice.replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
      const scopeMatch = SCOPE_RE.exec(s.titleHtml);
      const fdsMatch = FDS_RE.exec(slice);
      docs.push({
        id: `${d.key}.html#${s.id}`,
        doc: d.key,
        title: titleText,
        requirementId: fdsMatch ? fdsMatch[1].toUpperCase() : '',
        scope: scopeMatch ? scopeMatch[1].toUpperCase().replace(/-/g, '-') : '',
        body: bodyText.slice(0, 800),
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
