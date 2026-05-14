#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const MarkdownIt = require('markdown-it');
const { renderShell } = require('./lib/render_shell');
const { buildToc } = require('./lib/build_toc');
const headingPermalinks = require('./markdown_plugins/heading_permalinks');
const markdownItAttrs = require('markdown-it-attrs');
const crossDocLink = require('./markdown_plugins/cross_doc_link');
const { parseDmTables } = require('./lib/parse_dm_tables');
const { parseOirMap } = require('./lib/parse_oir_map');
const { buildSearchIndex } = require('./lib/build_search_index');

const REPO_ROOT = path.resolve(__dirname, '..');
const PORTAL_DIR = path.join(REPO_ROOT, 'docs_portal');
const ASSETS_SRC = path.join(__dirname, 'assets');
const ASSETS_DEST = path.join(PORTAL_DIR, 'assets');

const DOCS = [
  { key: 'fds', source: 'MPP_MES_FDS.md', out: 'fds.html', title: 'FDS' },
  { key: 'data-model', source: 'MPP_MES_DATA_MODEL.md', out: 'data-model.html', title: 'Data Model' },
  { key: 'oir', source: 'MPP_MES_Open_Issues_Register.md', out: 'oir.html', title: 'Open Issues Register' },
];

function rmrf(dir) {
  if (fs.existsSync(dir)) fs.rmSync(dir, { recursive: true, force: true });
}

function copyDir(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  if (!fs.existsSync(src)) return;
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dest, entry.name);
    if (entry.isDirectory()) copyDir(s, d);
    else fs.copyFileSync(s, d);
  }
}

function buildMd({ currentDoc, knownTables, reqToOpenOis } = {}) {
  const md = new MarkdownIt({ html: true, linkify: false, typographer: false });
  md.use(markdownItAttrs);
  md.use(headingPermalinks);
  if (currentDoc === 'data-model') {
    md.use(require('./markdown_plugins/schema_table_anchor'), { knownTables: knownTables || new Map() });
  }
  md.use(require('./markdown_plugins/anchor_fds_req'));
  md.use(require('./markdown_plugins/scope_pill'));
  md.use(require('./markdown_plugins/oi_badge'), { reqToOpenOis: reqToOpenOis || new Map() });
  md.use(crossDocLink, { currentDoc, knownTables: knownTables || new Map() });
  return md;
}

function build() {
  rmrf(PORTAL_DIR);
  fs.mkdirSync(PORTAL_DIR, { recursive: true });

  const generatedAt = new Date().toISOString();
  const dmRaw = fs.readFileSync(path.join(REPO_ROOT, 'MPP_MES_DATA_MODEL.md'), 'utf8');
  const knownTables = parseDmTables(dmRaw);
  const oirRaw = fs.readFileSync(path.join(REPO_ROOT, 'MPP_MES_Open_Issues_Register.md'), 'utf8');
  const { reqToOpenOis } = parseOirMap(oirRaw);

  const renderedDocs = [];
  for (const doc of DOCS) {
    const src = path.join(REPO_ROOT, doc.source);
    const raw = fs.readFileSync(src, 'utf8');
    const md = buildMd({ currentDoc: doc.key, knownTables, reqToOpenOis });
    const contentHtml = md.render(raw);
    renderedDocs.push({ key: doc.key, title: doc.title, html: contentHtml });
    const tocHtml = buildToc(contentHtml);
    const html = renderShell({
      activeDoc: doc.key,
      title: doc.title,
      contentHtml,
      tocHtml,
      sourcePath: doc.source,
      generatedAt,
    });
    fs.writeFileSync(path.join(PORTAL_DIR, doc.out), html, 'utf8');
  }

  // Search index
  const { payload } = buildSearchIndex(renderedDocs);
  fs.writeFileSync(
    path.join(PORTAL_DIR, 'search-index.json'),
    JSON.stringify(payload),
    'utf8'
  );

  // Vendor minisearch into assets
  const miniSearchSrc = path.join(REPO_ROOT, 'node_modules', 'minisearch', 'dist', 'umd', 'index.js');
  fs.mkdirSync(ASSETS_DEST, { recursive: true });
  fs.copyFileSync(miniSearchSrc, path.join(ASSETS_DEST, 'minisearch.min.js'));

  // erd.html — iframe wrapper
  const erdHtml = renderShell({
    activeDoc: 'erd',
    title: 'ERD',
    contentHtml: `
      <a class="erd-fullscreen-link" href="../MPP_MES_ERD.html" target="_blank" rel="noopener">Open ERD full screen ↗</a>
      <iframe class="erd-frame" src="../MPP_MES_ERD.html" title="MPP MES ERD"></iframe>
    `,
    tocHtml: '<ul><li><em>Pan + zoom inside the ERD.</em></li></ul>',
    sourcePath: 'MPP_MES_ERD.html',
    generatedAt,
  });
  fs.writeFileSync(path.join(PORTAL_DIR, 'erd.html'), erdHtml, 'utf8');

  // index.html — meta-refresh to fds.html
  fs.writeFileSync(
    path.join(PORTAL_DIR, 'index.html'),
    `<!DOCTYPE html><html><head><meta charset="UTF-8"><meta http-equiv="refresh" content="0; url=fds.html"></head><body><a href="fds.html">Open FDS</a></body></html>`,
    'utf8'
  );

  copyDir(ASSETS_SRC, ASSETS_DEST);

  console.log(`Built ${DOCS.length + 1} pages → ${PORTAL_DIR}`);
}

if (require.main === module) build();

module.exports = { build };
