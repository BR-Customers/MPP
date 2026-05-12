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
