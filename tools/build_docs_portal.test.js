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

test('build script emits fds.html with shell + parsed markdown', () => {
  execSync('node tools/build_docs_portal.js', { cwd: REPO_ROOT, stdio: 'pipe' });
  const fdsPath = path.join(PORTAL_DIR, 'fds.html');
  assert.ok(fs.existsSync(fdsPath), 'fds.html should exist');
  const html = fs.readFileSync(fdsPath, 'utf8');
  assert.match(html, /<header class="portal-header"/);
  assert.match(html, /<main[^>]*>[\s\S]*<h1[\s\S]*MPP MES[\s\S]*<\/h1>/i);
});
