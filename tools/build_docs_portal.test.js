const test = require('node:test');
const assert = require('node:assert');
const { renderShell } = require('./lib/render_shell');

test('renderShell wraps content in nav header + main', () => {
  const html = renderShell({
    activeDoc: 'fds',
    title: 'FDS',
    contentHtml: '<h2>Hello</h2>',
    tocHtml: '<ul><li>Hello</li></ul>',
    sourcePath: 'MPP_MES_FDS.md',
    generatedAt: '2026-05-12T12:00:00Z',
  });
  assert.match(html, /<header/);
  assert.match(html, /href="fds\.html"[^>]*class="[^"]*active/);
  assert.match(html, /<aside[^>]*>[\s\S]*Hello[\s\S]*<\/aside>/);
  assert.match(html, /<main[^>]*>[\s\S]*<h2>Hello<\/h2>[\s\S]*<\/main>/);
  assert.match(html, /MPP_MES_FDS\.md/);
  assert.match(html, /data-active-doc="fds"/);
});

const { buildToc } = require('./lib/build_toc');

test('buildToc nests h3 under h2', () => {
  const html = '<h2 id="a">A</h2><p/><h3 id="a1">A.1</h3><h3 id="a2">A.2</h3><h2 id="b">B</h2>';
  const toc = buildToc(html);
  assert.match(toc, /<a[^>]*href="#a"[^>]*>A<\/a>/);
  assert.match(toc, /<a[^>]*href="#a1"[^>]*>A\.1<\/a>/);
  assert.match(toc, /<a[^>]*href="#b"[^>]*>B<\/a>/);
  // h3s nested under their h2
  const aIdx = toc.indexOf('href="#a"');
  const a1Idx = toc.indexOf('href="#a1"');
  const bIdx = toc.indexOf('href="#b"');
  assert.ok(aIdx < a1Idx && a1Idx < bIdx, 'A.1 should appear between A and B');
});

test('buildToc strips trailing pills/badges from heading text', () => {
  const html = '<h2 id="x">Section <span class="scope-pill scope-mvp">MVP</span></h2>';
  const toc = buildToc(html);
  // pill text excluded from TOC label
  assert.match(toc, /<a[^>]*href="#x"[^>]*>Section\s*<\/a>/);
});

const fs = require('node:fs');
const path = require('node:path');
const { execSync } = require('node:child_process');

const REPO_ROOT = path.resolve(__dirname, '..');
const PORTAL_DIR = path.join(REPO_ROOT, 'docs_portal');

test('buildToc h3-only input emits balanced <li> tags', () => {
  const html = '<h3 id="a">A</h3><h3 id="b">B</h3>';
  const toc = buildToc(html);
  const opens = (toc.match(/<li/g) || []).length;
  const closes = (toc.match(/<\/li>/g) || []).length;
  assert.strictEqual(opens, closes, 'every <li> should have a matching </li>');
  assert.match(toc, /<a[^>]*href="#a"[^>]*>A<\/a>/);
  assert.match(toc, /<a[^>]*href="#b"[^>]*>B<\/a>/);
});

test('buildToc h2-only input emits balanced <li> tags', () => {
  const html = '<h2 id="a">A</h2><h2 id="b">B</h2>';
  const toc = buildToc(html);
  const opens = (toc.match(/<li/g) || []).length;
  const closes = (toc.match(/<\/li>/g) || []).length;
  assert.strictEqual(opens, closes);
});

test('build script emits fds.html with shell + parsed markdown', () => {
  execSync('node tools/build_docs_portal.js', { cwd: REPO_ROOT, stdio: 'pipe' });
  const fdsPath = path.join(PORTAL_DIR, 'fds.html');
  assert.ok(fs.existsSync(fdsPath), 'fds.html should exist');
  const html = fs.readFileSync(fdsPath, 'utf8');
  assert.match(html, /<header class="portal-header"/);
  assert.match(html, /<main[^>]*>[\s\S]*<h1[\s\S]*MPP MES[\s\S]*<\/h1>/i);
});

const { slugify } = require('./lib/slugify');

test('slugify lowercases, hyphenates, strips punctuation', () => {
  assert.strictEqual(slugify('5.9 Sub-LOT Split'), '5-9-sub-lot-split');
  assert.strictEqual(slugify('FDS-05-009 SHALL …'), 'fds-05-009-shall');
  assert.strictEqual(slugify('Parts.OperationTemplate'), 'parts-operationtemplate');
});

test('slugify de-dupes within a document', () => {
  const seen = new Map();
  assert.strictEqual(slugify('X', seen), 'x');
  assert.strictEqual(slugify('X', seen), 'x-2');
  assert.strictEqual(slugify('X', seen), 'x-3');
});

const MdLib = require('markdown-it');
const headingPermalinks = require('./markdown_plugins/heading_permalinks');

test('heading_permalinks adds id + permalink anchor to h2/h3', () => {
  const md = new MdLib();
  md.use(headingPermalinks);
  const html = md.render('## My Section\n\n### Sub one\n');
  assert.match(html, /<h2[^>]*id="my-section"/);
  assert.match(html, /<a[^>]*class="heading-permalink"[^>]*href="#my-section"/);
  assert.match(html, /<h3[^>]*id="sub-one"/);
});

test('heading_permalinks de-dupes within a render pass', () => {
  const md = new MdLib();
  md.use(headingPermalinks);
  const html = md.render('## Same\n\n## Same\n');
  assert.match(html, /id="same"/);
  assert.match(html, /id="same-2"/);
});

test('buildToc strips heading_permalink anchors', () => {
  const html = '<h2 id="x">Section <a class="heading-permalink" href="#x" aria-label="Permalink">#</a></h2>';
  const toc = buildToc(html);
  assert.match(toc, /<a[^>]*href="#x"[^>]*>Section\s*<\/a>/);
  // Permalink # must NOT appear in the label text
  assert.doesNotMatch(toc, />\s*Section\s*#\s*</);
});

test('heading_permalinks preserves an existing id (markdown-it-attrs cooperation)', () => {
  const md = new MdLib();
  const markdownItAttrs = require('markdown-it-attrs');
  md.use(markdownItAttrs);
  md.use(headingPermalinks);
  const html = md.render('## My Heading {#explicit-anchor}\n');
  assert.match(html, /<h2[^>]*id="explicit-anchor"/);
  assert.match(html, /<a[^>]*class="heading-permalink"[^>]*href="#explicit-anchor"/);
  // The slug-based id should NOT appear
  assert.doesNotMatch(html, /id="my-heading"/);
});

const anchorFdsReq = require('./markdown_plugins/anchor_fds_req');

test('anchor_fds_req wraps **FDS-XX-NNN** in an anchor', () => {
  const md = new MdLib();
  md.use(anchorFdsReq);
  const html = md.render('Some text **FDS-05-009** more text.');
  assert.match(html, /<a[^>]*id="fds-05-009"[^>]*>[\s\S]*FDS-05-009[\s\S]*<\/a>/);
  assert.match(html, /<strong>FDS-05-009<\/strong>/);
});

test('anchor_fds_req leaves plain text matches alone', () => {
  const md = new MdLib();
  md.use(anchorFdsReq);
  const html = md.render('See FDS-05-009 for details.');
  assert.doesNotMatch(html, /id="fds-05-009"/);
});

const scopePill = require('./markdown_plugins/scope_pill');

test('scope_pill renders backticked MVP/CONDITIONAL/etc. as colored spans', () => {
  const md = new MdLib();
  md.use(scopePill);
  for (const tag of ['MVP', 'MVP-EXPANDED', 'CONDITIONAL', 'FUTURE']) {
    const html = md.render(`Scope: \`${tag}\` here`);
    const cls = `scope-${tag.toLowerCase()}`;
    assert.match(html, new RegExp(`<span class="scope-pill ${cls}">${tag}</span>`));
  }
});

test('scope_pill leaves unrelated inline code alone', () => {
  const md = new MdLib();
  md.use(scopePill);
  const html = md.render('Path: `Parts.Item`');
  assert.match(html, /<code>Parts\.Item<\/code>/);
  assert.doesNotMatch(html, /scope-pill/);
});

const { parseDmTables } = require('./lib/parse_dm_tables');

test('parseDmTables extracts Schema.TableName from Data Model headings', () => {
  const sample = `# Data Model
## 2. Location Schema
### Location
### LocationAttribute
## 3. Parts Schema
### OperationTemplate
### ContainerConfig
## 4. Lots Schema
### Lot
`;
  const map = parseDmTables(sample);
  assert.ok(map.has('Location.Location'));
  assert.ok(map.has('Parts.OperationTemplate'));
  assert.ok(map.has('Parts.ContainerConfig'));
  assert.ok(map.has('Lots.Lot'));
  assert.strictEqual(map.get('Parts.OperationTemplate'), 'parts-operationtemplate');
});

const crossDocLink = require('./markdown_plugins/cross_doc_link');

test('cross_doc_link rewrites bare FDS-XX-NNN, OI-XX, UJ-XX, Schema.Table', () => {
  const md = new MdLib();
  md.use(crossDocLink, {
    currentDoc: 'fds',
    knownTables: new Map([['Parts.OperationTemplate', 'parts-operationtemplate']]),
  });
  let html = md.render('See FDS-05-009 and OI-35 and UJ-04.');
  assert.match(html, /<a[^>]*href="#fds-05-009"[^>]*>FDS-05-009<\/a>/);   // within-doc anchor on FDS
  assert.match(html, /<a[^>]*href="oir\.html#oi-35"[^>]*>OI-35<\/a>/);
  assert.match(html, /<a[^>]*href="oir\.html#uj-04"[^>]*>UJ-04<\/a>/);

  html = md.render('See Parts.OperationTemplate column.');
  assert.match(html, /<a[^>]*href="data-model\.html#parts-operationtemplate"[^>]*>Parts\.OperationTemplate<\/a>/);
});

test('cross_doc_link styles (FRS X.Y) as a tag, no link', () => {
  const md = new MdLib();
  md.use(crossDocLink, { currentDoc: 'fds', knownTables: new Map() });
  const html = md.render('(FRS 3.9.6)');
  assert.match(html, /<span class="frs-ref">\(FRS 3\.9\.6\)<\/span>/);
});

test('cross_doc_link skips text inside existing links and code', () => {
  const md = new MdLib();
  md.use(crossDocLink, { currentDoc: 'fds', knownTables: new Map() });
  const html = md.render('Code: `OI-35` and link: [OI-35](https://example.com)');
  // Inside code: untouched
  assert.match(html, /<code>OI-35<\/code>/);
  // Inside link: untouched
  assert.match(html, /<a href="https:\/\/example\.com">OI-35<\/a>/);
  // Should NOT have wrapped either with the cross-doc href
  assert.doesNotMatch(html, /<a[^>]*href="oir\.html#oi-35"[^>]*>OI-35<\/a><\/code>/);
});

const { parseOirMap } = require('./lib/parse_oir_map');

test('parseOirMap collects open OIs and maps requirements to them', () => {
  const sample = `# OIR
## OI-35 Architecture Decision Gate
**Status:** Open

Affects FDS-11-011 and FDS-05-009.

## OI-12 MaxParts relocation
**Status:** Resolved

Affects FDS-05-009.

## OI-32 Material allocation
**Status:** Open

Affects FDS-08-001.
`;
  const { openIds, reqToOpenOis } = parseOirMap(sample);
  assert.deepStrictEqual([...openIds].sort(), ['OI-32', 'OI-35']);
  assert.deepStrictEqual(reqToOpenOis.get('FDS-11-011').sort(), ['OI-35']);
  assert.deepStrictEqual(reqToOpenOis.get('FDS-05-009').sort(), ['OI-35']);  // OI-12 is Resolved, excluded
  assert.deepStrictEqual(reqToOpenOis.get('FDS-08-001').sort(), ['OI-32']);
});

const oiBadge = require('./markdown_plugins/oi_badge');

test('oi_badge appends 🔓 OI-XX after **FDS-XX-NNN** when in the open map', () => {
  const md = new MdLib();
  md.use(require('./markdown_plugins/anchor_fds_req'));
  md.use(oiBadge, { reqToOpenOis: new Map([['FDS-05-009', ['OI-35']]]) });
  const html = md.render('**FDS-05-009** SHALL …');
  assert.match(html, /<a[^>]*class="oi-badge"[^>]*href="oir\.html#oi-35"[^>]*>🔓 OI-35<\/a>/);
});

test('oi_badge does not badge requirements without open OIs', () => {
  const md = new MdLib();
  md.use(require('./markdown_plugins/anchor_fds_req'));
  md.use(oiBadge, { reqToOpenOis: new Map() });
  const html = md.render('**FDS-05-009** SHALL …');
  assert.doesNotMatch(html, /oi-badge/);
});

test('heading_permalinks: h4 FDS-XX-NNN heading gets fds-XX-NNN id', () => {
  const md = new MdLib();
  md.use(headingPermalinks);
  const html = md.render('#### FDS-05-009 — Some Title\n');
  assert.match(html, /<h4[^>]*id="fds-05-009"/);
  // Permalink chip points at the canonical anchor
  assert.match(html, /<a[^>]*class="heading-permalink"[^>]*href="#fds-05-009"/);
});

test('heading_permalinks: non-FDS h4 falls back to slugify', () => {
  const md = new MdLib();
  md.use(headingPermalinks);
  const html = md.render('#### Plain h4 title\n');
  assert.match(html, /<h4[^>]*id="plain-h4-title"/);
});

test('oi_badge fires on h4 FDS headings with open OIs', () => {
  const md = new MdLib();
  md.use(headingPermalinks);
  md.use(oiBadge, { reqToOpenOis: new Map([['FDS-05-009', ['OI-35']]]) });
  const html = md.render('#### FDS-05-009 — Some Title\n');
  assert.match(html, /<a[^>]*class="oi-badge"[^>]*href="oir\.html#oi-35"[^>]*>🔓 OI-35<\/a>/);
});

const schemaTableAnchor = require('./markdown_plugins/schema_table_anchor');

test('schema_table_anchor rewrites h3 ids inside a Schema section', () => {
  const md = new MdLib();
  md.use(require('./markdown_plugins/heading_permalinks'));
  md.use(schemaTableAnchor, {
    knownTables: new Map([
      ['Parts.OperationTemplate', 'parts-operationtemplate'],
      ['Parts.ContainerConfig', 'parts-containerconfig'],
    ]),
  });
  const src = [
    '## 3. Parts Schema',
    '',
    '### OperationTemplate',
    '',
    'Some prose.',
    '',
    '### ContainerConfig',
    '',
    'More prose.',
  ].join('\n');
  const html = md.render(src);
  assert.match(html, /<h3[^>]*id="parts-operationtemplate"/);
  assert.match(html, /<h3[^>]*id="parts-containerconfig"/);
});

test('build emits all four target HTMLs', () => {
  execSync('node tools/build_docs_portal.js', { cwd: REPO_ROOT, stdio: 'pipe' });
  for (const name of ['fds.html', 'data-model.html', 'oir.html', 'erd.html', 'index.html']) {
    assert.ok(fs.existsSync(path.join(PORTAL_DIR, name)), `${name} should exist`);
  }
});

test('erd.html iframes the standalone ERD file', () => {
  const html = fs.readFileSync(path.join(PORTAL_DIR, 'erd.html'), 'utf8');
  assert.match(html, /<iframe[^>]+src="\.\.\/MPP_MES_ERD\.html"/);
  assert.match(html, /erd-fullscreen-link/);
});

test('index.html redirects to fds.html', () => {
  const html = fs.readFileSync(path.join(PORTAL_DIR, 'index.html'), 'utf8');
  assert.match(html, /<meta http-equiv="refresh" content="0;\s*url=fds\.html"/i);
});

test('data-model.html contains schema-prefixed anchors', () => {
  const html = fs.readFileSync(path.join(PORTAL_DIR, 'data-model.html'), 'utf8');
  assert.match(html, /id="parts-operationtemplate"/);
  assert.match(html, /id="lots-shippinglabel"/);
});

const { buildSearchIndex } = require('./lib/build_search_index');

test('buildSearchIndex extracts section-level entries with doc + scope + body', () => {
  const renderedDocs = [
    {
      key: 'fds',
      title: 'FDS',
      html: '<h2 id="s1">Section One <span class="scope-pill scope-mvp">MVP</span></h2><p>Body of section one mentioning <a id="fds-05-009">FDS-05-009</a>.</p><h2 id="s2">Section Two</h2><p>Stuff.</p>',
    },
  ];
  const { docs } = buildSearchIndex(renderedDocs);
  assert.strictEqual(docs.length, 2);
  const first = docs.find((d) => d.id === 'fds.html#s1');
  assert.strictEqual(first.doc, 'fds');
  assert.strictEqual(first.title, 'Section One');
  assert.strictEqual(first.scope, 'MVP');
  assert.match(first.body, /Body of section one/);
  assert.strictEqual(first.requirementId, 'FDS-05-009');
});

test('build_docs_portal emits search-index.json with >= 200 entries', () => {
  execSync('node tools/build_docs_portal.js', { cwd: REPO_ROOT, stdio: 'pipe' });
  const raw = JSON.parse(fs.readFileSync(path.join(PORTAL_DIR, 'search-index.json'), 'utf8'));
  assert.ok(raw.docs.length >= 200, `expected >=200 entries, got ${raw.docs.length}`);
  assert.ok(raw.index, 'serialized MiniSearch index present');
  assert.ok(raw.options, 'MiniSearch options present');
});

test('build_docs_portal copies minisearch.min.js into assets', () => {
  assert.ok(fs.existsSync(path.join(PORTAL_DIR, 'assets', 'minisearch.min.js')));
});

test('end-to-end: key anchors resolve in generated HTML', () => {
  execSync('node tools/build_docs_portal.js', { cwd: REPO_ROOT, stdio: 'pipe' });
  const fds = fs.readFileSync(path.join(PORTAL_DIR, 'fds.html'), 'utf8');
  const dm = fs.readFileSync(path.join(PORTAL_DIR, 'data-model.html'), 'utf8');
  const oir = fs.readFileSync(path.join(PORTAL_DIR, 'oir.html'), 'utf8');

  // Known requirement that exists in v1.0 FDS
  assert.match(fds, /id="fds-05-009"/);
  // Schema-prefixed DM anchors
  assert.match(dm, /id="parts-operationtemplate"/);
  assert.match(dm, /id="lots-shippinglabel"/);
  // OI-35 anchor — heading_permalinks now canonicalizes to bare oi-XX id
  assert.match(oir, /id="oi-35"/);
  // UJ anchors also canonicalize
  assert.match(oir, /id="uj-05"/);
});

test('OI badge appears on at least one FDS requirement', () => {
  const fds = fs.readFileSync(path.join(PORTAL_DIR, 'fds.html'), 'utf8');
  assert.match(fds, /class="oi-badge"/, 'expected at least one inline OI badge on FDS page');
});

test('search-index.json size budget < 500 KB uncompressed', () => {
  const stat = fs.statSync(path.join(PORTAL_DIR, 'search-index.json'));
  assert.ok(stat.size < 500 * 1024, `search-index.json grew to ${stat.size} bytes`);
});

test('cross-doc OI links from FDS resolve to canonical OIR anchors', () => {
  const fds = fs.readFileSync(path.join(PORTAL_DIR, 'fds.html'), 'utf8');
  const oir = fs.readFileSync(path.join(PORTAL_DIR, 'oir.html'), 'utf8');
  // Find every cross-doc OI href in FDS, then verify the matching anchor exists in OIR
  const hrefs = [...fds.matchAll(/href="oir\.html#([\w-]+)"/g)].map((m) => m[1]);
  assert.ok(hrefs.length > 0, 'expected at least one cross-doc OI href in FDS');
  const unique = [...new Set(hrefs)];
  for (const slug of unique) {
    assert.match(oir, new RegExp(`id="${slug}"`), `OIR must have id="${slug}" for FDS cross-doc link`);
  }
});

test('oi_badge generates correct href for UJ items (not oi-uj-XX)', () => {
  const md = new MdLib();
  md.use(headingPermalinks);
  md.use(oiBadge, { reqToOpenOis: new Map([['FDS-07-018', ['UJ-05']]]) });
  const html = md.render('#### FDS-07-018 — Sort Cage Scope Boundary\n');
  assert.match(html, /href="oir\.html#uj-05"/);
  assert.doesNotMatch(html, /href="oir\.html#oi-uj-05"/);
});
