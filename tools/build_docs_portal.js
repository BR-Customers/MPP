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

const REPO_ROOT = path.resolve(__dirname, '..');
const PORTAL_DIR = path.join(REPO_ROOT, 'docs_portal');
const ASSETS_SRC = path.join(__dirname, 'assets');
const ASSETS_DEST = path.join(PORTAL_DIR, 'assets');

const DOCS = [
  { key: 'fds', source: 'MPP_MES_FDS.md', out: 'fds.html', title: 'FDS' },
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

  const dmRaw = fs.readFileSync(path.join(REPO_ROOT, 'MPP_MES_DATA_MODEL.md'), 'utf8');
  const knownTables = parseDmTables(dmRaw);

  const oirRaw = fs.readFileSync(path.join(REPO_ROOT, 'MPP_MES_Open_Issues_Register.md'), 'utf8');
  const { reqToOpenOis } = parseOirMap(oirRaw);

  const generatedAt = new Date().toISOString();

  for (const doc of DOCS) {
    const src = path.join(REPO_ROOT, doc.source);
    const raw = fs.readFileSync(src, 'utf8');
    const md = buildMd({ currentDoc: doc.key, knownTables, reqToOpenOis });
    const contentHtml = md.render(raw);
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

  // Asset copy (empty in this task; populated in Phase 3+)
  copyDir(ASSETS_SRC, ASSETS_DEST);

  console.log(`Built ${DOCS.length} doc(s) → ${PORTAL_DIR}`);
}

if (require.main === module) build();

module.exports = { build };
