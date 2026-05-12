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
