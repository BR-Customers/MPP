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
